#!/usr/bin/env sh

# imapsync_stub.sh - Test stub that simulates imapsync behavior
# Used for fast testing of watchdog and monitoring systems
# Control behavior via STUB_BEHAVIOR environment variable

# Parse command line arguments for key parameters
LOG_FILE=""
USER1=""
USER2=""

# Simple argument parser
while [ $# -gt 0 ]; do
    case "$1" in
        --logfile)
            LOG_FILE="$2"
            shift 2
            ;;
        --user1)
            USER1="$2"
            shift 2
            ;;
        --user2)
            USER2="$2"
            shift 2
            ;;
        --passfile1|--passfile2)
            # Ignore password files for stub
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Ensure log file is specified
if [ -z "$LOG_FILE" ]; then
    LOG_FILE="/tmp/imapsync_stub_$$.log"
fi

# Create log directory if needed
LOG_DIR=$(dirname "$LOG_FILE")
mkdir -p "$LOG_DIR"

# Write initial log entry
{
    echo "Starting imapsync stub simulation"
    echo "User1: $USER1"
    echo "User2: $USER2"
    echo "Behavior: ${STUB_BEHAVIOR:-default}"
    echo "PID: $$"
    echo "Time: $(date)"
    echo ""
} > "$LOG_FILE"

# Simulate based on behavior
case "${STUB_BEHAVIOR:-default}" in
    exit_code:*)
        # Extract exit code from STUB_BEHAVIOR=exit_code:N
        CODE="${STUB_BEHAVIOR#exit_code:}"
        echo "Messages found: 1000" >> "$LOG_FILE"
        echo "Messages copied: 950" >> "$LOG_FILE"
        echo "Messages skipped: 50" >> "$LOG_FILE"
        echo "Total bytes transferred: 100.5 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value $CODE" >> "$LOG_FILE"
        exit "$CODE"
        ;;

    stall)
        # Simulate a stalled process (stops writing but stays alive)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 5000" >> "$LOG_FILE"
        echo "Messages copied: 2500" >> "$LOG_FILE"
        echo "Stalling now (process will hang)..." >> "$LOG_FILE"
        # Sleep forever to simulate stall
        while true; do
            sleep 3600
        done
        ;;

    kill_after:*)
        # Extract seconds from STUB_BEHAVIOR=kill_after:N
        SECS="${STUB_BEHAVIOR#kill_after:}"
        echo "Running migration (will be killed in ${SECS}s)..." >> "$LOG_FILE"

        # Start background killer
        (
            sleep "$SECS"
            kill -KILL $$
        ) &

        # Simulate normal operation until killed
        COUNT=0
        while true; do
            COUNT=$((COUNT + 100))
            echo "Messages copied: $COUNT" >> "$LOG_FILE"
            echo "msg SOURCE/folder1/$COUNT {...} copied to DEST/folder1/$COUNT" >> "$LOG_FILE"
            sleep 1
        done
        ;;

    memory_hog)
        # Simulate high memory usage (allocate arrays)
        echo "Running migration with high memory usage..." >> "$LOG_FILE"

        # Allocate memory in shell (crude but effective)
        BIG_DATA=""
        for i in $(seq 1 1000000); do
            BIG_DATA="${BIG_DATA}XXXXXXXXXX"
            if [ $((i % 10000)) -eq 0 ]; then
                echo "Messages copied: $i" >> "$LOG_FILE"
            fi
        done

        echo "Exiting with return value 0" >> "$LOG_FILE"
        exit 0
        ;;

    partial_success)
        # Simulate partial success (exit code 11)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 1000" >> "$LOG_FILE"
        echo "Messages copied: 800" >> "$LOG_FILE"
        echo "Messages skipped: 100" >> "$LOG_FILE"
        echo "ERR: Some messages failed to copy" >> "$LOG_FILE"
        echo "ERR: Connection timeout on folder INBOX.Archive" >> "$LOG_FILE"
        echo "Total bytes transferred: 85.2 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 11" >> "$LOG_FILE"
        exit 11
        ;;

    network_error)
        # Simulate network error (exit code 74)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 500" >> "$LOG_FILE"
        echo "Messages copied: 123" >> "$LOG_FILE"
        echo "ERROR: Network is unreachable" >> "$LOG_FILE"
        echo "ERROR: Connection reset by peer" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 74" >> "$LOG_FILE"
        exit 74
        ;;

    rate_limit)
        # Simulate rate limiting (throttled but still succeeds)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 2000" >> "$LOG_FILE"
        COUNT=0
        for i in 1 2 3 4 5 6 7 8 9 10; do
            COUNT=$((COUNT + 50))
            echo "Messages copied: $COUNT" >> "$LOG_FILE"
            echo "WARNING: Rate limit reached, throttling..." >> "$LOG_FILE"
            sleep 2
        done
        echo "Total bytes transferred: 250.0 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 0" >> "$LOG_FILE"
        exit 0
        ;;

    gmail_quota)
        # Simulate Gmail quota exceeded (exit code 162)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 5000" >> "$LOG_FILE"
        echo "Messages copied: 1200" >> "$LOG_FILE"
        echo "ERROR: Account exceeded command or bandwidth limits" >> "$LOG_FILE"
        echo "ERROR: NO [OVERQUOTA] Account exceeded command or bandwidth limits. q]" >> "$LOG_FILE"
        echo "Total bytes transferred: 450.0 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 162" >> "$LOG_FILE"
        exit 162
        ;;

    quick_success)
        # Quick successful run (5 seconds)
        echo "Running migration..." >> "$LOG_FILE"
        echo "Messages found: 100" >> "$LOG_FILE"

        for i in 20 40 60 80 100; do
            echo "Messages copied: $i" >> "$LOG_FILE"
            echo "From folder [INBOX] to [INBOX]" >> "$LOG_FILE"
            sleep 1
        done

        echo "Messages skipped: 0" >> "$LOG_FILE"
        echo "Total bytes transferred: 12.5 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 0" >> "$LOG_FILE"
        exit 0
        ;;

    *)
        # Default: run for 10 seconds then exit successfully
        echo "Running migration (default mode)..." >> "$LOG_FILE"
        echo "Messages found: 500" >> "$LOG_FILE"

        COUNT=0
        for i in $(seq 1 10); do
            COUNT=$((COUNT + 50))
            echo "Messages copied: $COUNT" >> "$LOG_FILE"
            echo "msg SOURCE/INBOX/$COUNT {...} copied to DEST/INBOX/$COUNT" >> "$LOG_FILE"
            echo "Current folder: INBOX ($COUNT/500)" >> "$LOG_FILE"
            sleep 1
        done

        echo "Messages skipped: 0" >> "$LOG_FILE"
        echo "Total bytes transferred: 52.3 MB" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        echo "Exiting with return value 0" >> "$LOG_FILE"
        exit 0
        ;;
esac