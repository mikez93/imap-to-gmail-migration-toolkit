# Email Migration Lessons Learned
## HostGator to Google Workspace via imapsync

### Date: September 26, 2025
### Account: test@example.com (Test Migration)

## Key Discoveries

### 1. imapsync Deletion Behavior ⚠️
**CRITICAL:** imapsync is **additive-only** by default
- Does NOT sync deletions from source to destination
- Messages deleted on source after initial sync will remain on destination
- To sync deletions, must use `--delete2` flag (risky!)
- **Recommendation:** Run final sync immediately before MX cutover to minimize discrepancies

### 2. Google App Password Format
**Issue:** App passwords from Google include spaces for readability
- Given format: `abcd efgh ijkl mnop`
- Required format: `abcdefghijklmnop` (no spaces)
- **Solution:** Always remove spaces from Google app passwords before use

### 3. Memory Management on macOS
**Problem:** Exit code 137 indicates Out-of-Memory (OOM) killer
- Large mailboxes (1.5GB+) consume significant RAM
- Default 8MB buffer can exhaust memory on consumer hardware
- Multiple attempts kept failing at ~5,000-9,000 messages

**Solutions Implemented:**
1. Close memory-intensive applications (freed 24GB RAM)
2. Reduce buffer size from 8MB to 4MB: `--buffersize 4096000`
3. Add memory-saving flags:
   - `--nofoldersizes` (skip folder size calculations)
   - `--nofoldersizesatend` (skip final size report)
   - `--maxlinelength 10000` (limit line processing)

### 4. Gmail-Specific Requirements
**Essential Exclusions to Prevent Duplicates:**
```bash
--exclude '\\[Gmail\\]/All Mail'
--exclude '\\[Gmail\\]/Important'
--exclude '\\[Gmail\\]/Starred'
```
- Gmail's virtual folders cause duplicate messages
- "All Mail" contains copies of everything
- Must escape brackets in folder names

### 5. Resumability Is Robust
**Discovery:** imapsync handles interruptions gracefully
- Uses IMAP UIDs for tracking
- Automatically skips already-transferred messages
- Multiple parallel attempts don't cause corruption
- Can safely restart after failures

## Technical Configuration That Works

### Optimal imapsync Command
```bash
imapsync \
  --host1 mail.example.com \
  --user1 test@example.com \
  --password1 'SourcePassword' \
  --ssl1 \
  --host2 imap.gmail.com \
  --user2 test@example.com \
  --password2 'GoogleAppPasswordNoSpaces' \
  --ssl2 \
  --syncinternaldates \
  --useuid \
  --automap \
  --addheader \
  --exclude '\\[Gmail\\]/All Mail' \
  --exclude '\\[Gmail\\]/Important' \
  --exclude '\\[Gmail\\]/Starred' \
  --buffersize 4096000 \
  --tmpdir /tmp/imapsync_tmp \
  --sep1 '.' \
  --sep2 '/' \
  --logfile migrate/logs/migration_$(date +%Y%m%d_%H%M%S).log
```

### Performance Metrics
- **Transfer Rate:** 1.5-1.6 msgs/s (optimal with 4MB buffer)
- **Data Rate:** ~100-106 KiB/s
- **Memory Usage:** ~350MB for imapsync process
- **Time Estimate:** ~2.5 hours for 15,361 messages (1.58GB)

## Process Improvements

### Pre-Migration Checklist
1. ✅ Verify source/destination credentials
2. ✅ Generate Google app passwords (remove spaces!)
3. ✅ Test with single account first
4. ✅ Check available RAM (need 2GB+ free)
5. ✅ Create log directory structure
6. ✅ Close unnecessary applications

### Monitoring Best Practices
1. **Check Process Status:**
   ```bash
   ps aux | grep imapsync
   ```

2. **Monitor Real-Time Progress:**
   ```bash
   tail -f LOG_imapsync/migrate/logs/[logfile].log | grep -E "msg|ETA|left"
   ```

3. **Track Specific Metrics:**
   ```bash
   # Messages remaining
   grep "msgs left" [logfile] | tail -1

   # Current transfer rate
   grep "msgs/s" [logfile] | tail -1

   # ETA
   grep "ETA:" [logfile] | tail -1
   ```

## Common Issues & Solutions

| Issue | Symptom | Solution |
|-------|---------|----------|
| Memory exhaustion | Exit code 137 | Reduce buffer size, close apps |
| Auth failure | "NO [AUTHENTICATIONFAILED]" | Remove spaces from app password |
| Duplicates in Gmail | Same message appears multiple times | Exclude [Gmail]/All Mail |
| Slow transfer | < 1 msg/s | Check network, reduce buffer |
| Missing folders | Folders not created on Gmail | Use --automap flag |
| Date issues | Wrong received dates | Use --syncinternaldates |

## Recovery Procedures

### If Migration Fails Mid-Process:
1. Note the last message number transferred
2. Check available memory/disk space
3. Review error in log file
4. Simply restart the same command - it will resume
5. Consider reducing buffer size if memory issues persist

### Multiple Stuck Processes:
```bash
# Find all imapsync processes
ps aux | grep imapsync

# Kill stuck processes (use actual PID)
kill -9 [PID]

# Clear cache if corrupted
rm -rf /tmp/imapsync_tmp/imapsync_cache
```

## Migration Statistics

### Test Migration Results
- **Account:** test@example.com
- **Total Messages:** 15,361
- **Total Size:** 1.578 GB
- **Folders:** 9 (including INBOX)
- **Largest Message:** 22.7 MB
- **Migration Attempts:** 4 (3 failed, 1 successful)
- **Total Time:** ~2.5 hours (with interruptions)

### Folder Mapping
| Source (HostGator) | Destination (Gmail) |
|--------------------|---------------------|
| INBOX | INBOX |
| INBOX.Sent | [Gmail]/Sent Mail |
| INBOX.Drafts | [Gmail]/Drafts |
| INBOX.Trash | [Gmail]/Trash |
| INBOX.spam | [Gmail]/Spam |
| INBOX.Junk | [Gmail]/Spam |
| INBOX.Archive | Archive |
| INBOX.1 | 1 |
| INBOX.Inbox Backup 2023-07-06 | Inbox Backup 2023-07-06 |

## Recommendations for Production

1. **Schedule migrations during off-hours** to minimize user disruption
2. **Run test migration 1 week before cutover** to identify issues
3. **Perform final sync within 1 hour of MX change** to minimize gaps
4. **Document all passwords securely** before starting
5. **Have rollback plan ready** in case of critical issues
6. **Monitor first 24 hours closely** after cutover
7. **Keep source mailboxes for 30 days** as backup

### 6. Gmail 500 MB/day IMAP Upload Limit (2026-03-12)
**Discovery:** Gmail enforces a hard ~500 MB/day IMAP upload limit per account. A user's 93K-message mailbox (~4.5 GB) hit this within the first session, triggering exit code 162 ("Account exceeded command or bandwidth limits").

**Compounding factors:**
- `--useheader 'Message-Id'` issues an IMAP SEARCH per message per folder, burning command quota
- Watchdog restarts compound the problem: each restart re-authenticates and re-scans folders from scratch
- No throttling was in place despite being documented in PERFORMANCE_TUNING.md

**Solutions Implemented:**
1. Throttling defaults on all sync paths (100 KB/s, 300 MB burst, 2 msgs/s)
2. `--throttle gentle|moderate|aggressive` presets in start_migration.sh
3. Exit 162 = `rate-limited` classification with 30-min deferred backoff
4. Background backfill script (`backfill_sync.sh`) with 5 non-overlapping age windows
5. Daily launchd schedule for multi-day backfill under quota
6. MAX_RESTARTS bumped to 12 with extended backoff (up to 30 min)

**Key insight:** For large mailboxes, you must plan for multi-day migration. The backfill approach (gentle throttle + age windows + daily schedule) is the only reliable path under Gmail's quota.

## Next Steps

1. ✅ Complete test migration for test@example.com
2. ⏳ Verify all messages transferred correctly
3. ⏳ Test email functionality in Gmail
4. ⏳ Create batch migration plan for remaining users
5. ⏳ Schedule maintenance window for production migration
6. ⏳ Prepare user communication templates

---

**Document Version:** 1.0
**Last Updated:** September 26, 2025, 9:17 AM PDT
**Author:** Migration Team with AI Assistant