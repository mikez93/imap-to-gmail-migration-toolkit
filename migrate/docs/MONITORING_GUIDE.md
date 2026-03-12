# Migration Monitoring Guide

Last updated: 2026-03-12

This guide documents the current monitoring and watchdog behavior. Legacy notes are preserved in `migrate/docs/archives/MONITORING_GUIDE_legacy.md`.

## Quick Start (Recommended)
```bash
cd /path/to/migration-toolkit/migrate
./launch_triple_terminal.sh
```
This opens:
- `migration_watchdog.sh` (watchdog)
- `tail -F` on watchdog logs
- `universal_monitor.sh` (dashboard)

## Running Multiple Accounts Simultaneously

Each account runs in its own terminal window. The first `start_migration.sh` starts the shared watchdog; subsequent ones detect it and share it.

```bash
# Terminal 1 — starts watchdog, runs first account
cd /path/to/migration-toolkit/migrate
./start_migration.sh user2@example.com --throttle moderate

# Terminal 2 — wait ~5 seconds, then run second account
cd /path/to/migration-toolkit/migrate
./start_migration.sh admin@example.com --throttle moderate
```

**How the shared watchdog works:**
- The watchdog auto-discovers all running imapsync processes (no hardcoded account list)
- It monitors heartbeats, memory, and exit codes for every account it finds
- When any terminal exits, it checks if other migrations are still running — the watchdog is only killed when the **last** migration finishes
- Gmail's 500 MB/day IMAP upload limit is per-account, so simultaneous migrations don't share quota

## Universal Monitor (Dashboard)
```bash
cd /path/to/migration-toolkit/migrate
./universal_monitor.sh
```
What it shows (per account):
- PID, RSS memory, CPU
- Messages copied, speed, total MiB
- Current folder
- Heartbeat age and trend arrows

Key defaults (override via env vars):
- `REFRESH_INTERVAL=5`
- `STATE_DIR=/var/tmp/migration_watchdog`
- `HEARTBEAT_TTL=300`

## Watchdog (Heartbeat + Auto-Restart)
Monitor-only by default:
```bash
cd /path/to/migration-toolkit/migrate
./migration_watchdog.sh
```
Enable auto-restart:
```bash
./migration_watchdog.sh -r
```

Restart eligibility requires:
- A restart manifest (`/var/tmp/migration_watchdog/<account>.manifest`)
- Policy allows restart (`.policy` file = `auto`)
- No `.stop` file present

`imapsync_cmd.sh` defaults to `MAKE_RESTARTABLE=true` and `WDOG_WRITE_MANIFEST=true`. Set `MAKE_RESTARTABLE=false` only if you explicitly want inline passwords and no restarts.

### Policies and Stop Files
```bash
# Allow restarts for a specific account
echo "auto" > /var/tmp/migration_watchdog/admin_at_example.com.policy

# Block all restarts for an account
touch /var/tmp/migration_watchdog/admin_at_example.com.stop
```

### Heartbeat Behavior (Critical)
- Heartbeat files live in `/var/tmp/migration_watchdog/heartbeats/`.
- The heartbeat value is the log file mtime (epoch seconds). It only advances when the imapsync log updates.
- If heartbeat age exceeds TTL (default 300s) and auto-restart is enabled, the watchdog restarts immediately.

### Exit Codes and Status
The watchdog parses the last `Exiting with return value` line from the log.
- `0`: complete (no restart)
- `11`, `74`, `75`, `111`: retryable (restart if allowed)
- `137`: OOM (restart if allowed, but investigate memory)
- `143`: user stop (restart if allowed and no `.stop` file)
- `162`: rate-limited (Gmail quota exceeded; forces 30-min backoff then retries)
- Unknown: treated as fatal (no restart)

The `rate-limited` status is triggered by Gmail's "Account exceeded command or bandwidth limits" error. The watchdog forces a 30-minute backoff before the next retry, regardless of the normal backoff schedule. This prevents rapid reconnect-and-fail cycles that waste quota.

### Backoff Sequence
Restart backoff escalates: **1m → 2m → 5m → 15m → 30m**. Rate-limited (exit 162) always forces 30 minutes regardless of position in the sequence.

Maximum restart attempts: **12** (increased from 6 to support multi-day backfill scenarios).

### Throttle Presets
Use `--throttle` with `start_migration.sh` to control throughput:

| Preset | Bytes/s | Burst Cap | Msgs/s | Use Case |
|--------|---------|-----------|--------|----------|
| `gentle` | 50 KB/s | 200 MB | 1 | Background backfill |
| `moderate` | 100 KB/s | 300 MB | 2 | Default (no flag needed) |
| `aggressive` | No limit | No limit | No limit | Small mailboxes only |

### Docker-Aware Restarts
On macOS, restart manifests now store Docker execution context (`USE_DOCKER`, `DOCKER_IMAGE`, `DOCKER_MEMORY_LIMIT`). When the watchdog restarts a process, it replays using Docker if the original run used Docker. This prevents reintroducing the macOS Perl memory leak on restarts.

### Backfill Monitoring
For accounts using `backfill_sync.sh`:
```bash
# Check backfill progress
cat /var/tmp/migration_watchdog/<account>.backfill_state

# Check if a backfill is running (lock file)
ls /var/tmp/migration_watchdog/<account>.backfill_lock

# View launchd schedule status
launchctl list | grep backfill
```

## Logs and State Files
Primary locations:
- Watchdog log: `/var/tmp/migration_watchdog/watchdog.log`
- JSON events: `/var/tmp/migration_watchdog/watchdog.jsonl`
- imapsync logs: `migrate/logs/`

State file naming uses `_at_` (example: `admin_at_example.com.manifest`). Legacy `_` filenames are still read for compatibility.

## Debug Checklist (When a Migration Dies)
1. Check exit code:
   ```bash
   rg -n "Exiting with return value" migrate/logs/*.log
   ```
2. Check watchdog log:
   ```bash
   tail -50 /var/tmp/migration_watchdog/watchdog.log
   ```
3. Check JSON events:
   ```bash
   tail -20 /var/tmp/migration_watchdog/watchdog.jsonl
   ```
4. Verify heartbeat age:
   ```bash
   ls -la /var/tmp/migration_watchdog/heartbeats/
   ```
5. Confirm policy and manifest:
   ```bash
   ls /var/tmp/migration_watchdog/*.manifest
   cat /var/tmp/migration_watchdog/*.policy
   ```

## Supervisor (Read-Only Observer)
The Python supervisor tracks processes and writes to SQLite for reporting.
```bash
cd /path/to/migration-toolkit
./migrate.py status
./migrate.py supervise --interval 5 --mode observe
```

## Configuration Summary
Environment variables recognized by the watchdog and monitor:
- `STATE_DIR`, `HEARTBEAT_DIR`, `HEARTBEAT_TTL`
- `CHECK_INTERVAL`, `MEMORY_LIMIT_MB`, `MAX_RESTARTS`
- `RESTART_MODE` (`monitor` or `auto`)

See `docs/SYSTEM_OVERVIEW.md` for the full system layout and defaults.
