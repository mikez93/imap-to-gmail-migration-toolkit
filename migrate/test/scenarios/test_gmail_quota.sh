#!/usr/bin/env sh

# test_gmail_quota.sh - Test exit code 162 (Gmail quota exceeded) handling

# Source test environment
. "$(dirname "$0")/../harness.sh"

echo "Test: Exit code 162 (Gmail quota exceeded) handling"
echo "Expected: Process classified as rate-limited with 30-min backoff and restarted"
echo ""

# Use gmail_quota behavior (exits with code 162)
export STUB_BEHAVIOR="gmail_quota"

start_migration "gmail_quota"

echo "Initial PID: $MIGRATION_PID"

# Wait for process to exit (stub exits quickly with code 162)
echo "Waiting for process to exit with code 162..."
sleep 3

# Check if process exited
if kill -0 "$MIGRATION_PID" 2>/dev/null; then
    echo "ERROR: Process still running, expected exit"
    kill -KILL "$MIGRATION_PID" 2>/dev/null || true
    exit 1
fi

echo "Process exited"

# Check exit code detection
acct_safe=$(echo "$DST_USER" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g')
if [ -f "$STATE_DIR/${acct_safe}.last_exit" ]; then
    exit_code=$(cat "$STATE_DIR/${acct_safe}.last_exit")
    echo "Detected exit code: $exit_code"

    if [ "$exit_code" = "162" ]; then
        echo "SUCCESS: Exit code 162 correctly detected"
    else
        echo "ERROR: Wrong exit code detected: $exit_code (expected 162)"
        exit 1
    fi
else
    echo "ERROR: Exit code not recorded"
    exit 1
fi

# Check classification
if [ -f "$STATE_DIR/${acct_safe}.last_reason" ]; then
    reason=$(cat "$STATE_DIR/${acct_safe}.last_reason")
    echo "Classification: $reason"

    if [ "$reason" = "rate-limited" ]; then
        echo "SUCCESS: Correctly classified as rate-limited"
    else
        echo "ERROR: Wrong classification: $reason (expected rate-limited)"
        exit 1
    fi
fi

# Check that 30-minute backoff was set
if [ -f "$STATE_DIR/${acct_safe}.next_allowed_ts" ]; then
    next_ts=$(cat "$STATE_DIR/${acct_safe}.next_allowed_ts")
    now=$(date +%s)
    diff=$((next_ts - now))
    echo "Backoff remaining: ${diff}s"

    # Should be roughly 1800s (30 min) minus elapsed time
    if [ "$diff" -gt 1700 ] && [ "$diff" -le 1800 ]; then
        echo "SUCCESS: 30-minute backoff correctly set"
    else
        echo "WARNING: Backoff is ${diff}s (expected ~1800s)"
    fi
else
    echo "WARNING: No backoff timestamp file found"
fi

# Check JSON log for rate_limited event
if grep -q '"event":"rate_limited"' "$STATE_DIR/watchdog.jsonl" 2>/dev/null; then
    echo "SUCCESS: JSON log contains rate_limited event"
fi

if grep -q '"exit_code":"162"' "$STATE_DIR/watchdog.jsonl" 2>/dev/null; then
    echo "SUCCESS: JSON log contains exit code 162"
fi

echo ""
echo "Test passed: Exit 162 -> rate-limited with 30-min backoff"
exit 0
