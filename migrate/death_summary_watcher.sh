#!/usr/bin/env bash

# death_summary_watcher.sh - Watch for new death summary files and display them
# Split out from launch_triple_terminal.sh to avoid AppleScript quoting issues

STATE_DIR="${STATE_DIR:-/var/tmp/migration_watchdog}"
DEATH_TAIL_LINES="${WDOG_DEATH_TAIL_LINES:-100}"

LAST_SUMMARY=""
while true; do
    F=$(ls -t "$STATE_DIR"/*.death_summary 2>/dev/null | head -1)
    if [ -n "$F" ] && [ "$F" != "$LAST_SUMMARY" ]; then
        echo
        echo "=== Last Death Summary ==="
        cat "$F"
        LF=$(sed -n 's/^tail_file=//p' "$F")
        if [ -n "$LF" ] && [ -f "$LF" ]; then
            echo "--- Log tail at death ---"
            tail -n "$DEATH_TAIL_LINES" "$LF"
            echo
        fi
        LAST_SUMMARY="$F"
    fi
    sleep 5
done
