#!/usr/bin/env sh

# harness.sh - Fast feedback test harness for migration watchdog system
# Runs 5 key test scenarios and reports PASS/FAIL

# Detect if we're being sourced (from scenario scripts) or run directly
# When sourced, $0 is the scenario script, so we need to find harness.sh's real location
if [ -n "$BASH_SOURCE" ]; then
    # Bash - use BASH_SOURCE
    HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # POSIX sh - check if we're in scenarios subdir
    _check_dir="$(cd "$(dirname "$0")" && pwd)"
    if [ "$(basename "$_check_dir")" = "scenarios" ]; then
        HARNESS_DIR="$(dirname "$_check_dir")"
    else
        HARNESS_DIR="$_check_dir"
    fi
fi

TEST_DIR="$HARNESS_DIR"
BASE_DIR="$(dirname "$TEST_DIR")"
RESULTS_DIR="${RESULTS_DIR:-$TEST_DIR/results_$(date +%s)}"
export RESULTS_DIR
mkdir -p "$RESULTS_DIR"

# Configuration (scoped to test run)
STATE_DIR="${STATE_DIR:-$RESULTS_DIR/state}"
HEARTBEAT_DIR="$STATE_DIR/heartbeats"
export STATE_DIR
export HEARTBEAT_DIR
export WDOG_STATE_DIR="$STATE_DIR"

# Test configuration
export IMAPSYNC_BIN="$BASE_DIR/scripts/imapsync_stub.sh"
export SRC_HOST="test.example.com"
export SRC_USER="test@source.com"
export SRC_PASS="testpass"
export DST_HOST="test.gmail.com"
export DST_USER="test@destination.com"
export DST_PASS="testpass"
export CHECK_INTERVAL=2
export RESTART_MODE=auto
export HEARTBEAT_TTL=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Track results
PASSED=0
FAILED=0

# Ensure clean state
cleanup_state() {
    echo "Cleaning up state..."
    pkill -f migration_watchdog 2>/dev/null || true
    pkill -f imapsync_stub 2>/dev/null || true
    rm -rf "$STATE_DIR"/*
    rm -rf "$HEARTBEAT_DIR"/*
    mkdir -p "$STATE_DIR"
    mkdir -p "$HEARTBEAT_DIR"
    mkdir -p "$RESULTS_DIR"
}

# Start watchdog in background
start_watchdog() {
    echo "Starting watchdog..."
    "$BASE_DIR/migration_watchdog.sh" -r > "$RESULTS_DIR/watchdog.log" 2>&1 &
    WATCHDOG_PID=$!
    sleep 3  # Let it initialize
    if ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        echo -e "${RED}Failed to start watchdog${NC}"
        cat "$RESULTS_DIR/watchdog.log"
        exit 1
    fi
    echo "Watchdog started (PID: $WATCHDOG_PID)"
}

# Stop watchdog
stop_watchdog() {
    if [ -n "$WATCHDOG_PID" ]; then
        echo "Stopping watchdog..."
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
}

# Start a test migration
start_migration() {
    behavior="$1"
    export STUB_BEHAVIOR="$behavior"
    mkdir -p "$RESULTS_DIR"
    cd "$BASE_DIR/scripts"
    ./imapsync_cmd.sh > "$RESULTS_DIR/migration_${behavior}.log" 2>&1 &
    MIGRATION_PID=$!
    cd - > /dev/null
    sleep 2  # Let it start
    echo "Started migration with behavior: $behavior (PID: $MIGRATION_PID)"
}

# Wait for restart
wait_for_restart() {
    account="$1"
    timeout="$2"
    acct_safe=$(echo "$account" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._-]/_/g')

    echo "Waiting up to ${timeout}s for restart..."
    start=$(date +%s)
    while true; do
        now=$(date +%s)
        elapsed=$((now - start))

        if [ "$elapsed" -gt "$timeout" ]; then
            return 1
        fi

        # Check if new PID exists and is different
        if [ -f "$STATE_DIR/${acct_safe}.pid" ]; then
            new_pid=$(cat "$STATE_DIR/${acct_safe}.pid")
            if [ -n "$new_pid" ] && [ "$new_pid" != "$MIGRATION_PID" ] && kill -0 "$new_pid" 2>/dev/null; then
                echo "Restart detected! New PID: $new_pid"
                return 0
            fi
        fi

        sleep 1
    done
}

# Run test scenario
run_test() {
    test_name="$1"
    test_script="$2"

    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}Running: $test_name${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"

    if sh "$test_script" > "$RESULTS_DIR/${test_name}.log" 2>&1; then
        echo -e "${GREEN}✓ PASS: $test_name${NC}"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo -e "${RED}✗ FAIL: $test_name${NC}"
        echo "  See: $RESULTS_DIR/${test_name}.log"
        tail -10 "$RESULTS_DIR/${test_name}.log"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# Main test execution
main() {
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}    MIGRATION WATCHDOG TEST HARNESS${NC}"
    echo -e "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Test directory: $RESULTS_DIR"
    echo ""

    # Run test scenarios
    for scenario in "$TEST_DIR/scenarios"/*.sh; do
        if [ -f "$scenario" ]; then
            cleanup_state
            start_watchdog
            name=$(basename "$scenario" .sh)
            run_test "$name" "$scenario"
            stop_watchdog
        fi
    done

    # Summary
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Test Summary:${NC}"
    echo -e "  ${GREEN}Passed: $PASSED${NC}"
    echo -e "  ${RED}Failed: $FAILED${NC}"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}✓ All tests passed!${NC}"
        echo ""
        echo "Test artifacts: $RESULTS_DIR"
        return 0
    else
        echo -e "${RED}${BOLD}✗ Some tests failed${NC}"
        echo ""
        echo "Review logs in: $RESULTS_DIR"
        return 1
    fi
}

# Handle cleanup on exit (only when running main)
# Run main only when executed directly, not when sourced by scenario scripts
_harness_is_sourced() {
    # Check if this script is being sourced vs executed
    if [ -n "$BASH_SOURCE" ]; then
        [ "${BASH_SOURCE[0]}" != "$0" ]
    else
        # POSIX: check if we're in the scenarios directory
        [ "$(basename "$(dirname "$0")")" = "scenarios" ]
    fi
}

if ! _harness_is_sourced; then
    trap 'stop_watchdog; cleanup_state' EXIT INT TERM
    main "$@"
fi
