# IMAP to Gmail Migration Toolkit

**Start it Friday evening. Check Monday morning. Your mail is migrated.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell](https://img.shields.io/badge/Shell-Bash%2FPOSIX-green.svg)]()
[![Docker](https://img.shields.io/badge/Docker-Supported-blue.svg)]()

---

imapsync will ruin your weekend.

It will consume 80GB of RAM on your Mac and you won't notice until your machine is on its knees. It will silently duplicate every message in your mailbox if you use `--useuid` on a re-run. Gmail will rate-limit you at 500MB/day with exit code 162 and imapsync will dutifully retry forever, accomplishing nothing. You'll set it running on Friday night and find it dead on Saturday morning with no explanation in the logs.

This toolkit exists because all of those things happened during a real production migration from IMAP to Google Workspace. It wraps imapsync with a watchdog, Docker containment, rate-limit awareness, and enough hard-won knowledge to let you start a migration and walk away.

## What this solves

| The problem | What this toolkit does |
|---|---|
| imapsync leaks 80GB+ RAM on Apple Silicon ([GitHub #312](https://github.com/imapsync/imapsync/issues/312)) | Auto-detects macOS, routes through Docker with 8GB memory ceiling |
| Gmail rate-limits at 500MB/day per account, imapsync retries forever | Detects exit code 162, backs off 30 minutes automatically |
| Process crashes at 3 AM, nobody restarts it | Heartbeat watchdog with 12 auto-restarts and exponential backoff (1m -> 2m -> 5m -> 15m -> 30m) |
| Re-runs with `--useuid` create thousands of duplicate messages | Uses `--useheader 'Message-Id'` by default -- reliable across mixed-import scenarios |
| 90K-message mailbox exceeds daily upload quota in one session | Age-window backfill splits migration into time windows, tracks state per-window |
| No visibility into multi-day migration progress | Real-time dashboard auto-discovers processes, shows memory trends, death summaries |

## Quick start

```bash
# 1. Clone the toolkit
git clone https://github.com/mikez93/imap-to-gmail-migration-toolkit.git
cd imap-to-gmail-migration-toolkit/migrate

# 2. Pull Docker image (required on macOS)
docker pull gilleslamiral/imapsync

# 3. Set up credentials for an account
./setup_credentials.sh user@yourdomain.com

# 4. Test with a dry run
./start_migration.sh user@yourdomain.com --src-host mail.yourdomain.com --dry-run

# 5. Run the real migration
./start_migration.sh user@yourdomain.com --src-host mail.yourdomain.com
```

That's it. The system handles Docker, watchdog, heartbeats, restarts, and throttling automatically.

## Architecture

```
You run:
  ./start_migration.sh user@domain.com --src-host mail.yourdomain.com
       |
       v
  [Reset state: clear stale restarts, old heartbeats]
  [Load credentials from ~/.imapsync/credentials/]
  [Detect OS: macOS -> Docker | Linux -> native]
       |
       v
  +------------------+    +-------------------+
  | Watchdog         |    | Heartbeat Sidecar |
  | - Memory monitor |    | - Updates .hb     |
  | - Stall detect   |    |   every 5 seconds |
  | - Auto-restart   |    +-------------------+
  | - Backoff logic  |              |
  +--------+---------+              |
           |                        |
           v                        v
  +----------------------------------------+
  | imapsync (via Docker on macOS)         |
  | - Throttled transfers                  |
  | - Message-Id deduplication             |
  | - Gmail folder exclusions              |
  | - Incremental (resumes where it left)  |
  +----------------------------------------+
           |
     [If crash/OOM/stall]
           |
           v
  Watchdog detects within 60s via heartbeat
  -> Checks policy file (auto/monitor/never)
  -> Restarts with exponential backoff
  -> Up to 12 attempts before giving up
  -> Rate-limited (exit 162)? Forces 30-min wait
```

## Everything imapsync won't tell you about Gmail migration

This section is useful even if you don't use this toolkit. These are real problems encountered during a production migration, with specific fixes.

### The IMAP root prefix problem

If your source server uses `.` as a separator (Dovecot, Courier), folders appear as `INBOX.SentMail`, `INBOX.Drafts`, etc. Without `--sep1 . --sep2 /`, imapsync creates Gmail labels like `INBOX/INBOX.SentMail` instead of just `SentMail`.

**Fix**: Always use `--sep1 . --sep2 /` when migrating from a dot-separator server to Gmail. This toolkit does this by default.

### Gmail flattens your folder hierarchy into labels

Gmail doesn't have real folders -- it has labels. When imapsync creates nested structures, you get labels like `INBOX/Subfolder/Sub-subfolder`. These aren't wrong, but they look messy in Gmail's sidebar. The `INBOX.` prefix from your source server often leaks through as part of the label name.

**Fix**: Use `--automap` to let imapsync map standard folders (Sent, Drafts, Trash) to Gmail's equivalents. Combined with the separator flags, this gives you clean labels.

### `--useuid` will create thousands of duplicates

imapsync's default `--useuid` flag tracks messages by their IMAP UID. This works fine for a single run. But if you re-run (and you will -- migrations crash), the UIDs may differ between sessions, causing imapsync to re-transfer everything as "new" messages.

In one real incident, this created 10,100 duplicate messages across 15 folders.

**Fix**: Use `--useheader 'Message-Id'` instead. This matches messages by their Message-Id header, which is stable across sessions and even works when messages were previously imported by Google's own IMAP migration tool. Slower than UID-based matching, but reliable.

### App Passwords have invisible spaces

When Google generates an App Password, it displays it with spaces: `abcd efgh ijkl mnop`. If you copy-paste this with spaces into imapsync, authentication fails with an unhelpful error.

**Fix**: Remove ALL spaces: `abcdefghijklmnop`. The `setup_credentials.sh` script validates this automatically.

### `[Gmail]/All Mail` will duplicate every message

Gmail's `[Gmail]/All Mail` is a virtual folder containing every message in your account. If imapsync syncs it, every message gets transferred twice -- once from its actual folder, once from All Mail.

**Fix**: Exclude Gmail's virtual folders:
```
--exclude '\[Gmail\]/All Mail'
--exclude '\[Gmail\]/Important'
--exclude '\[Gmail\]/Starred'
```
This toolkit applies these exclusions by default.

### The macOS memory leak is catastrophic and undocumented

imapsync on Apple Silicon (M1/M2/M3/M4) has a memory leak that can consume 80GB+ of RAM. The process doesn't crash -- it just grows until your machine swaps to disk and becomes unusable. This is specific to the Perl runtime on ARM macOS.

The issue is tracked in [imapsync #312](https://github.com/imapsync/imapsync/issues/312) but has no fix in imapsync itself.

**Fix**: Run imapsync inside Docker with a memory ceiling:
```bash
docker run --memory=8g gilleslamiral/imapsync ...
```
This toolkit auto-detects macOS and routes through Docker automatically. On Linux, it runs natively (no memory leak).

### Gmail rate limiting is silent

Gmail enforces a ~500MB/day IMAP upload limit per account. When you hit it, imapsync gets a `NO [ALERT] Account exceeded command or bandwidth limits` error and exits with code 162. Without special handling, most wrappers either retry immediately (accomplishing nothing) or give up permanently.

**Fix**: The watchdog recognizes exit code 162 as a rate-limit event and backs off for 30 minutes before retrying. For large mailboxes, use the backfill system:
```bash
./scripts/backfill_sync.sh user@domain.com --throttle gentle
```
This splits the migration into 5 age-based windows and transfers ~400MB/day per window, staying under the limit.

### Large mailboxes need multi-day strategies

A mailbox with 90K+ messages and 20 years of email cannot be migrated in one session. You'll hit the daily upload quota, the process will crash from accumulated state, or your network will drop.

**Fix**: The backfill system (`backfill_sync.sh`) divides the mailbox into time windows:
- Window 1: Messages from the last 60 days
- Window 2: 60-180 days
- Window 3: 180-365 days
- Window 4: 1-3 years
- Window 5: 3+ years

Each window tracks its own completion state. You can run one window per day, or schedule them via cron/launchd. The toolkit includes a launchd example for automated daily backfills.

## Configuration

### Environment variables

```bash
# Required
SRC_HOST=mail.yourdomain.com      # Source IMAP server
DST_HOST=imap.gmail.com           # Destination (always imap.gmail.com)

# Performance tuning
BUFFER_SIZE=4194304               # 4MB buffer (default, good for 32GB RAM)
MAX_BYTES_PER_SECOND=100000       # 100 KB/s throttle (moderate default)
MAX_BYTES_AFTER=300000000         # Start throttling after 300 MB
DOCKER_MEMORY_LIMIT=8g           # Docker container memory ceiling

# Migration control
DRY_RUN=true                      # Test without transferring
MAX_AGE_DAYS=30                   # Only messages from last 30 days
MIN_AGE_DAYS=60                   # Only messages older than 60 days
```

Or use a `.env` file (see `.env.example`).

### Throttle presets

| Preset | Speed | Daily throughput | Use case |
|--------|-------|-----------------|----------|
| `gentle` | 50 KB/s | ~400 MB/day | Background backfill, staying under quota |
| `moderate` | 100 KB/s | ~800 MB/day | Default for most migrations |
| `aggressive` | No limit | Unlimited | Small mailboxes only |

```bash
./start_migration.sh user@domain.com --src-host mail.yourdomain.com --throttle gentle
```

### CLI flags

```bash
./start_migration.sh user@domain.com --src-host mail.yourdomain.com [OPTIONS]

  --dry-run              Test without transferring messages
  --src-host HOST        Source IMAP server hostname
  --max-age DAYS         Only sync messages from the last N days
  --min-age DAYS         Only sync messages older than N days
  --throttle PRESET      Throttle preset: gentle | moderate | aggressive
```

## Monitoring

The toolkit includes three monitoring tools designed to run in separate terminal windows:

```bash
# Launch all three at once (macOS)
./launch_triple_terminal.sh

# Or run individually:
./migration_watchdog.sh -r          # Watchdog with auto-restart
./universal_monitor.sh              # Real-time dashboard
tail -F /var/tmp/migration_watchdog/watchdog.log  # Log stream
```

### Universal Monitor features

- Auto-discovers all running imapsync processes (no configuration)
- Runtime, messages transferred, current folder
- Memory usage with trend arrows (up/down/stable)
- Per-session counters (messages and MB since process start)
- Recent completions with death timestamps and exit codes
- 5-second auto-refresh

### Watchdog features

- Heartbeat enforcement: detects frozen processes when heartbeat files stop updating
- Exit code classification: success (0), retryable (11), OOM (137), user-stop (143), rate-limited (162)
- Exponential backoff: 1m -> 2m -> 5m -> 15m -> 30m between restarts
- Per-account policy files (`auto` / `monitor` / `never`)
- JSON event stream for auditing (`watchdog.jsonl`)

## Troubleshooting

| Issue | Detection | Fix |
|---|---|---|
| OOM Kill (Exit 137) | Process dies, high memory in logs | On macOS: ensure Docker is running. On Linux: increase container memory |
| Docker not running | "Cannot connect to Docker daemon" | Start Docker Desktop before running migrations |
| Stalled migration | No log updates for 5+ minutes | Check heartbeat file; set policy to `auto` |
| Authentication failure | "NO LOGIN failed" | Verify App Password has no spaces; re-run `setup_credentials.sh` |
| Duplicate messages | Messages appear twice in Gmail | Exclude `[Gmail]/All Mail`; use `--useheader 'Message-Id'` (both are defaults) |
| Rate limiting (Exit 162) | "Account exceeded command or bandwidth limits" | Use `--throttle gentle`; use `backfill_sync.sh` for large mailboxes |
| Network drops | "Connection reset by peer" | Built-in: `--reconnectretry 20` retries per connection |
| Folder mapping issues | Wrong labels in Gmail | Check `--sep1` and `--sep2` match your source server's separator |

### Emergency controls

```bash
# Stop a specific account gracefully
touch /var/tmp/migration_watchdog/user_at_domain.com.stop

# Check restart policy
cat /var/tmp/migration_watchdog/user_at_domain.com.policy

# Set policy (auto = watchdog restarts, never = no restarts)
echo "auto" > /var/tmp/migration_watchdog/user_at_domain.com.policy
```

## Testing

The toolkit includes a regression test harness with 6 scenarios that verify watchdog behavior using a stub imapsync (no real mail server needed):

```bash
cd migrate/test
./harness.sh
```

| Scenario | What it tests |
|---|---|
| SIGTERM | Graceful shutdown handling |
| SIGKILL | Ungraceful kill recovery |
| Heartbeat stall | Frozen process detection |
| Exit code 11 | Retryable failure restart |
| Memory limit | RSS threshold enforcement |
| Gmail quota | Exit 162 rate-limit backoff |

## Credential management

Credentials are stored locally in `~/.imapsync/credentials/` with strict file permissions (`chmod 600`). They are never logged, committed, or passed as command-line arguments.

```bash
# Set up credentials (interactive, validates format)
./setup_credentials.sh user@domain.com

# Test credentials against IMAP servers
./setup_credentials.sh user@domain.com --test

# View existing credentials (masked)
./setup_credentials.sh user@domain.com --show
```

Google Workspace requires App Passwords for IMAP access. See `migrate/docs/GOOGLE_AUTH_SETUP.md` for setup instructions.

## Batch migration

For migrating multiple accounts:

```bash
# Create a migration map CSV
cp migrate/templates/basic_migration.csv migration_map.csv
# Edit with your accounts (see template for format)

# Run batch migration (3 concurrent accounts)
./scripts/run_batch.sh migration_map.csv -c 3
```

## Python supervisor (optional)

An optional Python CLI provides database-backed migration tracking:

```bash
pip install -r requirements.txt
python migrate.py status     # Show all migration status
python migrate.py observe    # Live observation mode
```

## Project structure

```
migrate/
  start_migration.sh          # Main entry point
  setup_credentials.sh        # Credential management
  migration_watchdog.sh       # Heartbeat-aware watchdog
  universal_monitor.sh        # Real-time dashboard
  launch_triple_terminal.sh   # Multi-terminal launcher (macOS)
  scripts/
    imapsync_cmd.sh           # Core imapsync wrapper
    backfill_sync.sh          # Age-window backfill
    run_batch.sh              # Parallel batch migration
    final_delta.sh            # Post-cutover incremental sync
    test_single.sh            # Interactive single-account testing
  test/
    harness.sh                # Regression test harness
    scenarios/                # 6 test scenarios
  templates/                  # CSV templates, config examples
  docs/                       # Detailed guides
supervisor/                   # Python monitoring CLI (optional)
```

## Requirements

- **Bash** 4+ (or any POSIX shell for core scripts)
- **Docker** (required on macOS for memory containment; optional on Linux)
- **imapsync** (installed natively on Linux, or via Docker image `gilleslamiral/imapsync`)
- **Python 3.8+** (optional, for supervisor CLI)

## License

MIT License. See [LICENSE](LICENSE).

This toolkit uses [imapsync](https://imapsync.lamiral.info/) by Gilles Lamiral, which is distributed under the "No Limit Public License."

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
