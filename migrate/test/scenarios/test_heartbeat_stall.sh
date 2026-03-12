#!/usr/bin/env sh

# test_heartbeat_stall.sh - Test heartbeat stall detection

# Source test environment
. "$(dirname "$0")/../harness.sh"

echo "Test: Heartbeat stall detection"
echo "Expected: Stall detected and process restarted"
echo ""

# Use stall behavior
export STUB_BEHAVIOR="stall"
export HEARTBEAT_TTL=8  # Short TTL for testing

start_migration "stall"

echo "Initial PID: $MIGRATION_PID"
acct_safe=$(echo "$DST_USER" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g')
hb_file="$HEARTBEAT_DIR/${acct_safe}.hb"

# Verify heartbeat file exists
sleep 3
if [ ! -f "$hb_file" ]; then
    echo "ERROR: Heartbeat file not created"
    exit 1
fi

echo "Heartbeat file created: $hb_file"

# Wait for heartbeat to become stale
echo "Waiting for heartbeat to become stale (TTL: ${HEARTBEAT_TTL}s)..."
sleep $((HEARTBEAT_TTL + CHECK_INTERVAL + 2))

# Check if stall was detected
if grep -q '"event":"stall_detected"' "$STATE_DIR/watchdog.jsonl" 2>/dev/null; then
    echo "SUCCESS: Stall detected in JSON log"

    # Check if process was killed and restarted
    if ! kill -0 "$MIGRATION_PID" 2>/dev/null; then
        echo "SUCCESS: Stalled process was terminated"

        # Wait for restart
        if wait_for_restart "$DST_USER" 5; then
            echo "SUCCESS: Process restarted after stall"
            exit 0
        else
            echo "FAILURE: Process not restarted after stall"
            exit 1
        fi
    else
        echo "WARNING: Stalled process still running"
        # Kill it manually for cleanup
        kill -KILL "$MIGRATION_PID" 2>/dev/null || true
        exit 1
    fi
else
    echo "FAILURE: Stall not detected"
    # Kill stalled process for cleanup
    kill -KILL "$MIGRATION_PID" 2>/dev/null || true
    exit 1
fi
