# Troubleshooting Guide

## Centralized Problem Resolution

This guide consolidates troubleshooting information from all project documentation to help you quickly resolve issues during email migration.

## Table of Contents

1. [Authentication Issues](#authentication-issues)
2. [Connection Problems](#connection-problems)
3. [Performance Issues](#performance-issues)
4. [Memory Management](#memory-management)
5. [Migration Failures](#migration-failures)
6. [Monitoring Issues](#monitoring-issues)
7. [Security Issues](#security-issues)
8. [Common Error Codes](#common-error-codes)
9. [Emergency Procedures](#emergency-procedures)

## Authentication Issues

### Google App Password Problems

#### Symptom: "NO LOGIN failed" or "Authentication failed"
**Root Cause**: Incorrect app password format or 2FA not enabled

**Solutions**:

1. **Verify 2FA is enabled**:
   ```bash
   # Check in Google Admin Console
   # Go to Security → 2-Step Verification
   # Must be ON for app passwords to work
   ```

2. **Remove spaces from app password**:
   ```bash
   # Google provides: "abcd efgh ijkl mnop"
   # Use: "abcdefghijklmnop"
   ```

3. **Generate new app password**:
   - Go to https://myaccount.google.com/apppasswords
   - Select "Mail" and "Other (custom name)"
   - Enter "Email Migration"
   - Copy password without spaces

4. **Test authentication directly**:
   ```bash
   imapsync \
     --host2 imap.gmail.com \
     --user2 "user@example.com" \
     --password2 "apppasswordnospaces" \
     --ssl2 \
     --justlogin
   ```

#### Symptom: "Less secure app access blocked"
**Root Cause**: Google's security policies blocking access

**Solutions**:

1. **Enable less secure apps (temporary)**:
   ```bash
   # In Google Admin Console:
   # Security → Basic settings → Less secure apps
   # Set to "Allow users to manage their access"
   ```

2. **Use app passwords instead** (recommended):
   - Follow app password generation steps above

3. **Service account setup** (for large organizations):
   - See [GOOGLE_AUTH_SETUP.md](GOOGLE_AUTH_SETUP.md)

### Source Server Authentication

#### Symptom: "Connection refused" or "NO LOGIN failed" on source
**Root Cause**: Incorrect credentials or server configuration

**Solutions**:

1. **Verify IMAP is enabled**:
   ```bash
   # For HostGator/cPanel:
   # Login to cPanel → Email → Email Accounts
   # Ensure IMAP is enabled for the account
   ```

2. **Check server settings**:
   ```bash
   # Test connection manually
   telnet mail.example.com 993
   openssl s_client -connect mail.example.com:993
   ```

3. **Verify credentials**:
   ```bash
   # Test with password file (more secure)
   echo "password" > .temp_pass
   chmod 600 .temp_pass
   imapsync --host1 mail.example.com --user1 user@example.com \
            --passfile1 .temp_pass --ssl1 --justlogin
   rm -f .temp_pass
   ```

## Connection Problems

### Network Connectivity Issues

#### Symptom: "Connection reset by peer" or "Connection timed out"
**Root Cause**: Network issues, firewall, or server problems

**Solutions**:

1. **Check basic connectivity**:
   ```bash
   # Test DNS resolution
   nslookup mail.example.com

   # Test TCP connection
   telnet mail.example.com 993

   # Test SSL connection
   openssl s_client -connect mail.example.com:993 -servername mail.example.com
   ```

2. **Check firewall settings**:
   ```bash
   # Verify ports are open
   sudo ufw status
   sudo iptables -L

   # Check if IMAP ports are listening
   sudo netstat -tlnp | grep :993
   ```

3. **Test with different connection methods**:
   ```bash
   # Try without SSL first (less secure)
   imapsync --host1 mail.example.com --user1 user --password1 pass \
            --port1 143 --nossl1 --justlogin

   # Then with SSL
   imapsync --host1 mail.example.com --user1 user --password1 pass \
            --port1 993 --ssl1 --justlogin
   ```

### Gmail Rate Limiting

#### Symptom: "User-rate limit exceeded" or "Quota exceeded"
**Root Cause**: Gmail API limits exceeded

**Solutions**:

1. **Use throttle presets** (recommended):
   ```bash
   # Gentle preset for large mailboxes / background backfill
   ./start_migration.sh user@example.com --throttle gentle

   # Moderate (default) for normal migrations
   ./start_migration.sh user@example.com --throttle moderate
   ```

2. **Reduce concurrency**:
   ```bash
   # Instead of 6 parallel migrations
   ./run_batch.sh migration_map.csv -c 3

   # Or even fewer
   ./run_batch.sh migration_map.csv -c 1
   ```

3. **Monitor rate limit status**:
   ```bash
   # Check Gmail API usage in Admin Console
   # Apps → Google Workspace → Gmail → User rate limits
   ```

#### Symptom: Exit code 162 ("Account exceeded command or bandwidth limits")
**Root Cause**: Gmail's 500 MB/day IMAP upload limit or command quota exceeded

**Solutions**:

1. **Auto-handled by watchdog**: Exit 162 is classified as `rate-limited`. The watchdog forces a 30-minute backoff then retries on the next cycle.

2. **Reduce throughput with throttle presets**:
   ```bash
   ./start_migration.sh user@example.com --throttle gentle
   # gentle = 50 KB/s, 200 MB burst cap, 1 msg/s
   ```

3. **Use the backfill script for large mailboxes**:
   ```bash
   # Splits sync into 5 age windows, runs one per session
   ./scripts/backfill_sync.sh user@example.com --throttle gentle
   ```

4. **Check backfill state**:
   ```bash
   cat /var/tmp/migration_watchdog/<account>.backfill_state
   ```

## Performance Issues

### Slow Transfer Rates

#### Symptom: Transfer rate < 1 msg/s or < 100 KiB/s
**Root Cause**: Various factors affecting performance

**Solutions**:

1. **Check current performance**:
   ```bash
   # Monitor real-time progress
   tail -f migrate/logs/*.log | grep -E "msgs/s|KiB/s|ETA"

   # Check system resources
   top -p $(pgrep imapsync)
   ```

2. **Optimize buffer settings**:
   ```bash
   # For 32GB RAM system
   export BUFFER_SIZE=4194304  # 4MB

   # For 64GB RAM system
   export BUFFER_SIZE=33554432 # 32MB

   # For testing only (high memory usage)
   export BUFFER_SIZE=134217728 # 128MB
   ```

3. **Enable fast I/O**:
   ```bash
   # Add to imapsync command
   --fastio1 --fastio2
   ```

4. **Use RAM disk for temporary files**:
   ```bash
   # Create RAM disk
   sudo mkdir -p /dev/shm/imapsync
   sudo mount -t tmpfs -o size=8G tmpfs /dev/shm/imapsync

   # Use in migration
   --tmpdir /dev/shm/imapsync
   ```

### High Memory Usage

#### Symptom: Process killed or "Out of memory" errors
**Root Cause**: Buffer size too large for available RAM

**Solutions**:

1. **Check memory usage**:
   ```bash
   # Monitor memory consumption
   ps aux | grep imapsync | awk '{print $2, $6/1024"MB"}'

   # Check system memory
   free -h
   ```

2. **Reduce buffer size**:
   ```bash
   # Safe settings by RAM size:
   # 16GB system: 2MB buffer
   export BUFFER_SIZE=2097152

   # 32GB system: 4MB buffer (recommended)
   export BUFFER_SIZE=4194304

   # 64GB system: 8-32MB buffer
   export BUFFER_SIZE=8388608
   ```

3. **Close memory-intensive applications**:
   ```bash
   # Free up RAM before migration
   # Close browsers, IDEs, other memory users
   ```

4. **Enable memory monitoring**:
   ```bash
   # Start watchdog with memory limits
   ./migration_watchdog.sh -r -m 40960  # 40GB limit
   ```

## Migration Failures

### Exit Code Reference

| Exit Code | Status | Description | Action Required |
|-----------|--------|-------------|-----------------|
| 0 | SUCCESS | Migration completed successfully | None |
| 11 | PARTIAL | Some messages failed to transfer | Check logs, retry if needed |
| 137 | KILLED | Process killed (usually OOM) | Reduce buffer size or increase memory |
| 143 | TERMINATED | SIGTERM or user stop | Restart allowed if no `.stop` file and policy permits |
| 74,75 | NETWORK | Network-related errors | Check connectivity, retry |
| 111 | SYSTEM | System error | Check system resources |
| 162 | RATE-LIMITED | Gmail quota exceeded (500 MB/day IMAP limit) | Watchdog auto-handles: 30-min backoff then retry |
| (unknown) | FATAL | Exit code missing/unparseable | Inspect logs and fix root cause |

### Common Migration Errors

#### "Couldn't create folder" Errors
**Root Cause**: Folder name conflicts or special characters

**Solutions**:

1. **Enable automatic folder mapping**:
   ```bash
   # Already enabled in scripts, but verify
   grep "automap" scripts/imapsync_cmd.sh
   ```

2. **Check folder separators**:
   ```bash
   # Source usually uses "."
   --sep1 .

   # Gmail uses "/"
   --sep2 /
   ```

3. **Manual folder mapping**:
   ```bash
   # Map specific problematic folders
   --regextrans2 "s/old_folder/new_folder/"
   ```

#### "Message too large" Errors
**Root Cause**: Messages exceed size limits

**Solutions**:

1. **Check message size limits**:
   ```bash
   # Gmail limit is 50MB
   --maxsize 52428800  # 50MB in bytes
   ```

2. **Find large messages**:
   ```bash
   # Check source for large messages
   find /path/to/mail -name "*.eml" -size +50M
   ```

3. **Exclude large messages**:
   ```bash
   # Skip messages over 25MB
   --maxsize 26214400
   ```

#### "Duplicate messages" in Gmail
**Root Cause**: Gmail virtual folders included in migration

**Solutions**:

1. **Verify exclusions are active**:
   ```bash
   # Must exclude these folders
   grep "exclude.*Gmail" scripts/imapsync_cmd.sh
   ```

2. **Expected exclusions**:
   ```bash
   --exclude '\\[Gmail\\]/All Mail'
   --exclude '\\[Gmail\\]/Important'
   --exclude '\\[Gmail\\]/Starred'
   ```

3. **Check for duplicates after migration**:
   ```bash
   # Search for duplicate subjects in Gmail
   # Manual verification required
   ```

## Monitoring Issues

### Watchdog Not Starting

#### Symptom: "No active imapsync process found"
**Root Cause**: No migrations running or process detection issues

**Solutions**:

1. **Verify migrations are running**:
   ```bash
   ps aux | grep -E "imapsync" | grep -v grep
   ```

2. **Confirm restart metadata exists**:
   ```bash
   ls -la /var/tmp/migration_watchdog/*.manifest
   ```

3. **Verify watchdog state dir and logs**:
   ```bash
   ls -la /var/tmp/migration_watchdog/
   tail -50 /var/tmp/migration_watchdog/watchdog.log
   ```

### Universal Monitor Not Showing Progress

#### Symptom: Monitor shows "No active migrations" but processes exist
**Root Cause**: Process detection regex mismatch

**Solutions**:

1. **Check process names**:
   ```bash
   # Look for exact process pattern
   ps aux | grep -i sync
   ```

2. **Verify log files exist**:
   ```bash
   # Default log location from imapsync_cmd.sh
   ls -la migrate/logs/
   # Legacy log locations (if used)
   ls -la LOG_imapsync/migrate/logs/
   ```

3. **Run monitor with explicit log dirs**:
   ```bash
   LOG_DIRS=\"migrate/logs LOG_imapsync/migrate/logs\" ./universal_monitor.sh
   ```

### Memory Monitoring False Alarms

#### Symptom: Watchdog reports high memory but system shows normal usage
**Root Cause**: RSS vs VSZ confusion or shared memory calculation

**Solutions**:

1. **Check actual memory usage**:
   ```bash
   # RSS (Resident Set Size) is what matters
   ps -o pid,rss,vsz,command -p $(pgrep imapsync)

   # Check system memory
   free -h
   ```

2. **Adjust memory limits**:
   ```bash
   # Increase limit if needed
   ./migration_watchdog.sh -r -m 51200  # 50GB

   # Or decrease for constrained systems
   ./migration_watchdog.sh -r -m 20480  # 20GB
   ```

3. **Monitor memory trends**:
   ```bash
   # Watch memory over time
   watch -n 5 'ps aux | grep imapsync | awk "{sum+=\$6} END {print \"Total: \" sum/1024 \" MB\"}"'
   ```

## Security Issues

### Credential Exposure

#### Symptom: Passwords visible in logs or process lists
**Root Cause**: Improper credential handling

**Solutions**:

1. **Use the default restartable mode**:
   ```bash
   # imapsync_cmd.sh uses passfiles by default
   export MAKE_RESTARTABLE=true
   ./scripts/imapsync_cmd.sh
   ```

2. **Use password files**:
   ```bash
   # ✅ Secure method
   echo "password" > .temp_pass
   chmod 600 .temp_pass
   imapsync --passfile1 .temp_pass
   rm -f .temp_pass

   # ❌ Insecure method
   imapsync --password1 "visible_password"
   ```

2. **Check for credential leaks**:
   ```bash
   # Search logs for passwords
   grep -r "password\|pass" migrate/logs/ | grep -v "REDACTED"

   # Check process environment
   cat /proc/$(pgrep imapsync)/environ | tr '\0' '\n' | grep -i pass
   ```

3. **Clean up exposed credentials**:
   ```bash
   # Clear bash history
   history -c && history -w

   # Clear environment variables
   unset SRC_PASS DST_PASS
   ```

### File Permission Issues

#### Symptom: "Permission denied" or files not accessible
**Root Cause**: Incorrect file permissions

**Solutions**:

1. **Check file permissions**:
   ```bash
   # Migration CSV should be 600
   ls -la migration_map.csv

   # Password files should be 600
   ls -la ~/.imapsync/credentials/*/pass1 ~/.imapsync/credentials/*/pass2
   ```

2. **Fix permissions**:
   ```bash
   # Secure migration CSV
   chmod 600 migration_map.csv

   # Secure password files
   chmod 600 ~/.imapsync/credentials/*/pass1 ~/.imapsync/credentials/*/pass2

   # Secure scripts
   chmod 755 scripts/*.sh
   ```

3. **Check directory permissions**:
   ```bash
   # Ensure log directory is writable
   ls -ld migrate/logs/
   chmod 755 migrate/logs/
   ```

## Common Error Codes

### imapsync Exit Codes

| Code | Meaning | Typical Cause | Resolution |
|------|---------|---------------|------------|
| 0 | Success | Migration completed | None needed |
| 11 | Partial failure | Some messages failed | Check logs, retry if critical |
| 74 | Connection failed | Network/server issue | Check connectivity |
| 75 | Authentication failed | Wrong credentials | Verify passwords |
| 111 | System error | Resource exhaustion | Check memory/disk |
| 137 | Killed (OOM) | Out of memory | Reduce buffer size |
| 143 | Terminated | SIGTERM or user stop | Restart if policy allows and no `.stop` file |
| 162 | Rate-limited | Gmail IMAP quota exceeded | Auto-retried after 30-min backoff; use `--throttle gentle` to prevent |

### Watchdog Exit Codes

Deprecated: the watchdog does not expose stable exit codes; use `/var/tmp/migration_watchdog/watchdog.log` and `watchdog.jsonl` for diagnostics. The table below is retained for historical reference only.

| Code | Meaning | Description | Action |
|------|---------|-------------|--------|
| 0 | Normal | Monitoring completed | None |
| 1 | Error | Configuration or permission error | Check logs |
| 2 | Restart failed | Could not restart migration | Manual intervention |

## Emergency Procedures

### Stop All Migrations

#### Immediate Stop
```bash
# Stop specific account
touch /var/tmp/migration_watchdog/admin_at_example.com.stop

# Stop all imapsync processes
pkill -f imapsync

# Stop watchdog
pkill -f migration_watchdog
```

#### Graceful Stop
```bash
# Send termination signal
kill -TERM $(pgrep imapsync)

# Wait for graceful shutdown
sleep 10

# Force kill if needed
kill -KILL $(pgrep imapsync) 2>/dev/null || true
```

### Recovery from System Crash

#### Resume After Reboot
```bash
# 1. Check what was running
ls -la /var/tmp/migration_watchdog/*.pid

# 2. Check migration status
tail -50 migrate/logs/*.log | grep -E "Exiting|ETA|copied"

# 3. Resume migrations
./scripts/imapsync_cmd.sh  # Will resume automatically

# 4. Restart monitoring
./launch_triple_terminal.sh
```

#### Data Recovery
```bash
# 1. Check for corrupted state files
ls -la /var/tmp/migration_watchdog/

# 2. Clear corrupted state if needed
rm -f /var/tmp/migration_watchdog/*.pid
rm -f /var/tmp/migration_watchdog/*.manifest

# 3. Restart with fresh state
unset MAKE_RESTARTABLE
./scripts/imapsync_cmd.sh
```

### Emergency Rollback

#### If Migration Goes Wrong
```bash
# 1. Stop all migrations immediately
pkill -f imapsync

# 2. Document current state
ls -la migrate/logs/ | tail -10

# 3. Check Gmail for issues
# Manual verification required

# 4. Consider reverse migration (Gmail → Source)
# Swap source and destination in CSV
# Run imapsync in reverse direction
```

## Diagnostic Commands

### Quick Health Check
```bash
# System resources
echo "=== SYSTEM STATUS ==="
free -h
df -h
uptime

# Running processes
echo "=== MIGRATION PROCESSES ==="
ps aux | grep -E "imapsync|migration_watchdog|universal_monitor" | grep -v grep

# Network connectivity
echo "=== NETWORK CHECK ==="
ping -c 3 imap.gmail.com
telnet imap.gmail.com 993

# Log status
echo "=== LOG STATUS ==="
ls -la migrate/logs/ | tail -5
tail -1 migrate/logs/*.log
```

### Detailed Diagnostics
```bash
# Create diagnostic report
cat > diagnostic_report.txt << EOF
=== DIAGNOSTIC REPORT ===
Date: $(date)
System: $(uname -a)
Memory: $(free -h)
Disk: $(df -h | grep -E "(Filesystem|/dev/)")
Processes: $(ps aux | grep -E "imapsync|migration" | wc -l)
Logs: $(ls migrate/logs/*.log | wc -l)
Watchdog State: $(ls /var/tmp/migration_watchdog/ 2>/dev/null | wc -l)
Recent Errors: $(grep -l "ERROR\|FAILED" migrate/logs/*.log | wc -l)
EOF

cat diagnostic_report.txt
```

### Performance Analysis
```bash
# Analyze transfer rates
echo "=== PERFORMANCE ANALYSIS ==="
for log in migrate/logs/*.log; do
    echo "=== $log ==="
    grep "copied to" "$log" | tail -5
    grep "ETA" "$log" | tail -1
    echo
done

# Memory usage over time
echo "=== MEMORY USAGE ==="
ps aux | grep imapsync | awk '{print $2, $6/1024"MB", $3"%"}'

# Network statistics
echo "=== NETWORK STATS ==="
ifstat -i eth0 1 5 | tail -1
```

## Getting Help

### Self-Service Troubleshooting

1. **Check the logs first**:
   ```bash
   # Most recent logs
   ls -t migrate/logs/*.log | head -3

   # Search for errors
   grep -i "error\|failed\|exception" migrate/logs/*.log
   ```

2. **Verify system resources**:
   ```bash
   # Memory and CPU
   top -bn1 | head -20

   # Disk space
   df -h

   # Network connectivity
   ping -c 3 imap.gmail.com
   ```

3. **Test basic functionality**:
   ```bash
   # Test single account
   ./scripts/test_single.sh

   # Test authentication
   imapsync --host2 imap.gmail.com --user2 user --password2 pass --ssl2 --justlogin
   ```

### Community Support

- **GitHub Issues**: [Report bugs and request features](https://github.com/your-org/email-migration-toolkit/issues)
- **GitHub Discussions**: [Ask questions and share knowledge](https://github.com/your-org/email-migration-toolkit/discussions)
- **Documentation**: Check the comprehensive guides in `docs/`

### Professional Support

For critical migrations or complex issues:

1. **Review all documentation** in the `docs/` directory
2. **Test thoroughly** in a non-production environment
3. **Have rollback plan** ready before starting
4. **Monitor closely** during initial migration

## Prevention

### Best Practices to Avoid Issues

1. **Test before production**:
   ```bash
   # Always test with single account first
   ./scripts/test_single.sh

   # Test with small batch
   ./scripts/run_batch.sh test_users.csv -c 1
   ```

2. **Monitor from the start**:
   ```bash
   # Launch monitoring immediately
   ./launch_triple_terminal.sh

   # Set up alerts for failures
   ./migration_watchdog.sh -r
   ```

3. **Use conservative settings initially**:
   ```bash
   # Start with safe defaults
   export BUFFER_SIZE=4194304  # 4MB
   export MAX_PARALLEL=3       # 3 concurrent

   # Increase gradually if stable
   ```

4. **Regular checkpoints**:
   ```bash
   # Check progress every hour
   tail -20 migrate/logs/*.log | grep -E "copied|ETA|ERROR"

   # Verify system resources
   free -h; echo "---"; ps aux | grep imapsync
   ```

## Quick Reference

### Most Common Issues & Solutions

| Problem | Quick Fix | Command |
|---------|-----------|---------|
| Authentication failed | Remove spaces from app password | `sed 's/ //g' password.txt` |
| Out of memory | Reduce buffer size | `export BUFFER_SIZE=4194304` |
| Rate limited | Reduce concurrency | `./run_batch.sh csv -c 2` |
| Connection drops | Add retry options | `--reconnectretry1 20` |
| Folder errors | Enable automap | Already in scripts |
| Duplicates | Check exclusions | `grep "exclude.*Gmail" scripts/*` |

### Emergency Commands
```bash
# Stop everything
pkill -f imapsync; pkill -f migration_watchdog

# Check status
ps aux | grep -E "imapsync|migration_watchdog"

# Resume safely
./scripts/imapsync_cmd.sh  # Will resume automatically
```

---

**Remember**: Always test thoroughly before production migrations, and have a rollback plan ready!

## Document Version

- **Version**: 1.1
- **Last Updated**: 2026-03-12
- **Maintainer**: Migration Team

For updates or corrections, please refer to the latest version in the repository.
