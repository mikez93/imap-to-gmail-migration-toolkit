#!/usr/bin/env python3
"""
Delete all messages in dirty Gmail folders to prepare for clean resync.

Reads the folder audit TSV, identifies dirty folders, connects to Gmail IMAP,
and deletes all messages in each dirty folder. Messages go to Gmail Trash
(auto-deleted after 30 days, or empty trash manually).

After running this, resume migration with start_migration.sh to resync
these folders from source using --useheader 'Message-Id'.
"""

import imaplib
import os
import sys
import time
from datetime import datetime

# Configuration
GMAIL_HOST = 'imap.gmail.com'
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Folders to skip (special Gmail mappings or handled manually)
SKIP_FOLDERS = {
    'INBOX',
    'INBOX.Sent',
    'INBOX.Sent Messages',
    'INBOX.INBOX.Sent',
    'INBOX.Junk',
    'INBOX.spam',
    'INBOX.Trash',
}


def parse_args():
    """Parse command-line arguments."""
    import argparse
    parser = argparse.ArgumentParser(
        description='Delete all messages in dirty Gmail folders to prepare for clean resync.')
    parser.add_argument('user', help='Gmail address (e.g., user@example.com)')
    parser.add_argument('--dry', action='store_true', help='Dry run — show what would be deleted')
    parser.add_argument('--tsv', default=None,
                        help='Path to folder audit TSV (default: ../logs/folder_audit_results.tsv)')
    parser.add_argument('--cred-file', default=None,
                        help='Path to Gmail credential file (default: ~/.imapsync/credentials/<user>/pass2)')
    return parser.parse_args()


def resolve_paths(args):
    """Resolve credential and TSV paths from arguments."""
    user = args.user
    sanitized = user.replace('@', '_at_')
    cred_file = args.cred_file or os.path.expanduser(f'~/.imapsync/credentials/{sanitized}/pass2')
    tsv_file = args.tsv or os.path.join(SCRIPT_DIR, '..', 'logs', 'folder_audit_results.tsv')
    log_file = os.path.join(SCRIPT_DIR, '..', 'logs',
                            f'cleanup_dirty_folders_{datetime.now():%Y%m%d_%H%M%S}.log')
    return cred_file, tsv_file, log_file


def host1_to_gmail_name(host1_name):
    """Convert Host1 folder name (INBOX.X.Y) to Gmail IMAP name (X/Y)."""
    if host1_name == 'INBOX':
        return 'INBOX'
    # Strip INBOX. prefix
    if host1_name.startswith('INBOX.'):
        name = host1_name[6:]  # Remove 'INBOX.'
    else:
        name = host1_name
    # Replace . separator with /
    return name.replace('.', '/')


def log(msg, logf=None):
    """Print and optionally log a message."""
    ts = datetime.now().strftime('%H:%M:%S')
    line = f'[{ts}] {msg}'
    print(line)
    if logf:
        logf.write(line + '\n')
        logf.flush()


def main():
    args = parse_args()
    GMAIL_USER = args.user
    DRY_RUN = args.dry
    CRED_FILE, TSV_FILE, LOG_FILE = resolve_paths(args)

    # Read password
    if not os.path.exists(CRED_FILE):
        print(f'ERROR: Credential file not found: {CRED_FILE}')
        print(f'Set up credentials first: ./setup_credentials.sh {GMAIL_USER}')
        sys.exit(1)
    with open(CRED_FILE) as f:
        password = f.read().strip()

    # Read dirty folders from TSV
    dirty_folders = []
    tsv_path = os.path.abspath(TSV_FILE)
    if not os.path.exists(tsv_path):
        print(f'ERROR: TSV file not found: {tsv_path}')
        sys.exit(1)

    with open(tsv_path) as f:
        header = f.readline()  # Skip header
        for line in f:
            parts = line.strip().split('\t')
            if len(parts) >= 5 and parts[4] == 'DIRTY (has duplicates)':
                folder_name = parts[0]
                if folder_name not in SKIP_FOLDERS:
                    dirty_folders.append({
                        'host1': folder_name,
                        'gmail': host1_to_gmail_name(folder_name),
                        'h1_msgs': int(parts[1]),
                        'h2_msgs': int(parts[2]),
                        'excess': int(parts[3]),
                    })

    mode = 'DRY RUN' if DRY_RUN else 'LIVE'
    print(f'=== Gmail Dirty Folder Cleanup ({mode}) ===')
    print(f'Folders to clean: {len(dirty_folders)}')
    print(f'Total excess messages: {sum(f["excess"] for f in dirty_folders)}')
    print(f'Log file: {LOG_FILE}')
    print()

    if not DRY_RUN:
        print('This will DELETE all messages in these folders on Gmail.')
        print('Messages go to Gmail Trash (auto-deleted after 30 days).')
        print('The migration resync will recreate them from source.')
        resp = input('Continue? (yes/no): ')
        if resp.strip().lower() != 'yes':
            print('Cancelled.')
            sys.exit(0)

    # Open log
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    logf = open(LOG_FILE, 'w')
    log(f'Cleanup started - {mode} mode', logf)
    log(f'Folders: {len(dirty_folders)}', logf)

    # Connect to Gmail
    log('Connecting to Gmail IMAP...', logf)
    M = imaplib.IMAP4_SSL(GMAIL_HOST)
    M.login(GMAIL_USER, password)
    log('Connected and authenticated.', logf)

    # Process each dirty folder
    cleaned = 0
    skipped = 0
    errors = 0
    total_deleted = 0

    for i, folder in enumerate(dirty_folders, 1):
        gmail_name = folder['gmail']
        # Quote the folder name for IMAP
        try:
            status, data = M.select(f'"{gmail_name}"')
        except Exception as e:
            log(f'  [{i}/{len(dirty_folders)}] ERROR selecting "{gmail_name}": {e}', logf)
            errors += 1
            continue

        if status != 'OK':
            log(f'  [{i}/{len(dirty_folders)}] NOT FOUND: "{gmail_name}" (skipped)', logf)
            skipped += 1
            continue

        msg_count = int(data[0])
        if msg_count == 0:
            log(f'  [{i}/{len(dirty_folders)}] EMPTY: "{gmail_name}" (skipped)', logf)
            skipped += 1
            M.close()
            continue

        if DRY_RUN:
            log(f'  [{i}/{len(dirty_folders)}] WOULD DELETE {msg_count} msgs in "{gmail_name}" '
                f'(h1={folder["h1_msgs"]}, h2={folder["h2_msgs"]}, excess={folder["excess"]})', logf)
            M.close()
            cleaned += 1
            total_deleted += msg_count
        else:
            try:
                # Mark all messages for deletion
                M.store('1:*', '+FLAGS', '\\Deleted')
                # Expunge (moves to Trash in Gmail)
                M.expunge()
                M.close()
                log(f'  [{i}/{len(dirty_folders)}] DELETED {msg_count} msgs from "{gmail_name}" '
                    f'(excess was {folder["excess"]})', logf)
                cleaned += 1
                total_deleted += msg_count
            except Exception as e:
                log(f'  [{i}/{len(dirty_folders)}] ERROR deleting from "{gmail_name}": {e}', logf)
                errors += 1
                try:
                    M.close()
                except:
                    pass

        # Brief pause to avoid Gmail rate limiting
        if not DRY_RUN and i % 10 == 0:
            time.sleep(1)

    M.logout()

    # Summary
    log('', logf)
    log('=== SUMMARY ===', logf)
    log(f'Mode: {mode}', logf)
    log(f'Folders processed: {cleaned}', logf)
    log(f'Folders skipped: {skipped}', logf)
    log(f'Errors: {errors}', logf)
    log(f'Total messages {"would be " if DRY_RUN else ""}deleted: {total_deleted}', logf)
    log(f'Log: {LOG_FILE}', logf)

    logf.close()
    print(f'\nDone. Log saved to: {LOG_FILE}')


if __name__ == '__main__':
    main()
