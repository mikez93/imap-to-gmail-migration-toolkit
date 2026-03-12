#!/usr/bin/env bash

# final_delta.sh - Run final incremental sync after MX cutover
# Usage: ./final_delta.sh migration_map.csv [options]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${BASE_DIR}/logs/final_delta"
REPORT_DIR="${BASE_DIR}/reports"

# Default values
CONCURRENCY=2  # Lower concurrency for final pass
MAX_AGE_DAYS=7  # Only sync messages from last week by default
DELETE_MODE=false
CHECK_ONLY=false
PRIORITY_USERS=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Usage function
usage() {
    cat <<EOF
Usage: $0 CSV_FILE [OPTIONS]

Run final incremental sync after MX cutover to Gmail

Arguments:
  CSV_FILE              Path to migration CSV file

Options:
  -c, --concurrency N   Number of parallel syncs (default: 2)
  -a, --max-age DAYS   Only sync messages newer than N days (default: 7)
  -d, --delete         Enable deletion sync (DANGEROUS - test first!)
  -p, --priority LIST  Comma-separated list of priority users to sync first
  -k, --check-only     Check for new messages without syncing
  -h, --help           Show this help message

Examples:
  # Run final delta for all users (messages from last 7 days)
  $0 migration_map.csv

  # Sync only messages from last 2 days
  $0 migration_map.csv --max-age 2

  # Priority sync for specific users first
  $0 migration_map.csv --priority "ceo@company.com,sales@company.com"

  # Check how many messages would be synced
  $0 migration_map.csv --check-only

WARNING: The --delete option will DELETE messages from Gmail that were
         deleted from the source. Only use after thorough testing!
EOF
}

# Parse arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    CSV_FILE="$1"
    shift

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--concurrency)
                CONCURRENCY="$2"
                shift 2
                ;;
            -a|--max-age)
                MAX_AGE_DAYS="$2"
                shift 2
                ;;
            -d|--delete)
                DELETE_MODE=true
                shift
                ;;
            -p|--priority)
                PRIORITY_USERS="$2"
                shift 2
                ;;
            -k|--check-only)
                CHECK_ONLY=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
}

# Validate environment
check_cutover_status() {
    echo -e "${BLUE}Checking MX cutover status...${NC}"

    # Check if MX records point to Google (simplified check)
    if command -v dig >/dev/null 2>&1; then
        # Extract domain from first user in CSV
        local test_domain=$(awk -F',' 'NR==2 {print $3}' "$CSV_FILE" | cut -d'@' -f2)

        if [[ -n "$test_domain" ]]; then
            echo "  Checking MX records for: $test_domain"
            local mx_records=$(dig +short MX "$test_domain" 2>/dev/null | head -3)

            if echo "$mx_records" | grep -qi "google\|gmail"; then
                echo -e "${GREEN}  ✓ MX records point to Google${NC}"
            else
                echo -e "${YELLOW}  ⚠ MX records may not point to Google yet:${NC}"
                echo "$mx_records" | sed 's/^/    /'
                echo ""
                read -p "Continue anyway? (yes/no): " confirm
                if [[ "$confirm" != "yes" ]]; then
                    echo "Aborting - please complete MX cutover first"
                    exit 1
                fi
            fi
        fi
    else
        echo -e "${YELLOW}  ⚠ Cannot verify MX records (dig not installed)${NC}"
    fi
}

# Create delta sync worker
create_delta_worker() {
    local worker_script="${SCRIPT_DIR}/delta_worker.sh"

    cat >"$worker_script" <<'EOF'
#!/usr/bin/env bash

set -euo pipefail

# Arguments
USER_LINE="$1"
LOG_DIR="$2"
MAX_AGE_DAYS="$3"
DELETE_MODE="$4"
CHECK_ONLY="$5"

# Parse CSV line
IFS=',' read -r SRC_USER SRC_PASS DST_USER DST_PASS <<< "$USER_LINE"

# Setup environment for imapsync
export SRC_HOST="${SRC_HOST:-mail.example.com}"
export DST_HOST="${DST_HOST:-imap.gmail.com}"
export SRC_USER
export SRC_PASS
export DST_USER
export DST_PASS
export MAX_AGE_DAYS
export LOG_DIR

# Timestamp for logging
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
echo "[$TIMESTAMP] Processing delta for $DST_USER (last $MAX_AGE_DAYS days)"

if [[ "$CHECK_ONLY" == "true" ]]; then
    # Just check for new messages
    export DRY_RUN=true
    echo "  Running in CHECK mode - no changes will be made"
fi

if [[ "$DELETE_MODE" == "true" ]]; then
    export DELETE_MODE=true
    echo "  DELETE mode enabled - deletions will be synced"
fi

# Run imapsync with delta parameters
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"${SCRIPT_DIR}/imapsync_cmd.sh"
EXIT_CODE=$?

# Report result
STATUS="UNKNOWN"
if [[ $EXIT_CODE -eq 0 ]]; then
    STATUS="SUCCESS"
elif [[ $EXIT_CODE -eq 11 ]]; then
    STATUS="PARTIAL"
else
    STATUS="FAILED"
fi

echo "$DST_USER,$STATUS,$TIMESTAMP,$EXIT_CODE" >> "${LOG_DIR}/delta_results.csv"

exit $EXIT_CODE
EOF

    chmod +x "$worker_script"
}

# Process priority users first
process_priority_users() {
    if [[ -z "$PRIORITY_USERS" ]]; then
        return 0
    fi

    echo ""
    echo -e "${MAGENTA}Processing priority users first...${NC}"

    # Convert comma-separated list to array
    IFS=',' read -ra PRIORITY_ARRAY <<< "$PRIORITY_USERS"

    for priority_user in "${PRIORITY_ARRAY[@]}"; do
        # Find user in CSV
        local user_line=$(grep "^[^,]*,[^,]*,$priority_user," "$CSV_FILE" 2>/dev/null || true)

        if [[ -n "$user_line" ]]; then
            echo -e "${BLUE}  Syncing priority user: $priority_user${NC}"
            "${SCRIPT_DIR}/delta_worker.sh" \
                "$user_line" \
                "$LOG_DIR" \
                "$MAX_AGE_DAYS" \
                "$DELETE_MODE" \
                "$CHECK_ONLY"
        else
            echo -e "${YELLOW}  Warning: Priority user not found in CSV: $priority_user${NC}"
        fi
    done

    echo -e "${GREEN}Priority users completed${NC}"
}

# Process all remaining users
process_all_users() {
    echo ""
    echo -e "${BLUE}Processing all users (excluding priority users)...${NC}"

    # Skip header and priority users
    local temp_csv="/tmp/delta_users_$$.csv"
    head -1 "$CSV_FILE" > "$temp_csv"  # Copy header

    # Add non-priority users
    tail -n +2 "$CSV_FILE" | while IFS=',' read -r src_user src_pass dst_user dst_pass; do
        if [[ -z "$PRIORITY_USERS" ]] || ! echo "$PRIORITY_USERS" | grep -q "$dst_user"; then
            echo "$src_user,$src_pass,$dst_user,$dst_pass" >> "$temp_csv"
        fi
    done

    # Count users
    local num_users=$(($(wc -l < "$temp_csv") - 1))
    echo "  Users to process: $num_users"

    # Process in parallel
    tail -n +2 "$temp_csv" | \
    parallel -j "$CONCURRENCY" --eta --line-buffer \
        "${SCRIPT_DIR}/delta_worker.sh" \
        {} \
        "$LOG_DIR" \
        "$MAX_AGE_DAYS" \
        "$DELETE_MODE" \
        "$CHECK_ONLY"

    rm -f "$temp_csv"
}

# Generate delta report
generate_delta_report() {
    echo ""
    echo -e "${BLUE}Generating delta sync report...${NC}"

    local report_file="${REPORT_DIR}/delta_$(date +%Y%m%d_%H%M%S).csv"

    # Create report header
    echo "user,status,timestamp,messages_found,messages_copied,messages_skipped" > "$report_file"

    # Process results
    if [[ -f "${LOG_DIR}/delta_results.csv" ]]; then
        while IFS=',' read -r user status timestamp exit_code; do
            # Find log file for detailed stats
            local log_file=$(find "$LOG_DIR" -name "*${user}*" -type f | head -1 || echo "")

            if [[ -f "$log_file" ]]; then
                local messages_found=$(grep -oP 'Messages found:\s+\K\d+' "$log_file" 2>/dev/null || echo "0")
                local messages_copied=$(grep -oP 'Messages copied:\s+\K\d+' "$log_file" 2>/dev/null || echo "0")
                local messages_skipped=$(grep -oP 'Messages skipped:\s+\K\d+' "$log_file" 2>/dev/null || echo "0")
            else
                local messages_found="unknown"
                local messages_copied="unknown"
                local messages_skipped="unknown"
            fi

            echo "$user,$status,$timestamp,$messages_found,$messages_copied,$messages_skipped" >> "$report_file"
        done < "${LOG_DIR}/delta_results.csv"
    fi

    # Summary statistics
    echo ""
    echo "========================================="
    echo "Final Delta Sync Summary"
    echo "========================================="
    echo "Sync period: Last $MAX_AGE_DAYS days"
    echo "Delete mode: $DELETE_MODE"

    if [[ -f "$report_file" ]]; then
        local total=$(tail -n +2 "$report_file" | wc -l)
        local success=$(grep -c ",SUCCESS," "$report_file" || true)
        local partial=$(grep -c ",PARTIAL," "$report_file" || true)
        local failed=$(grep -c ",FAILED," "$report_file" || true)

        echo ""
        echo "Users processed: $total"
        echo -e "${GREEN}Successful: $success${NC}"
        echo -e "${YELLOW}Partial: $partial${NC}"
        echo -e "${RED}Failed: $failed${NC}"
    fi

    echo ""
    echo "Report: $report_file"
    echo "Logs: $LOG_DIR"
    echo "========================================="

    # Check for failures
    if [[ ${failed:-0} -gt 0 ]]; then
        echo ""
        echo -e "${RED}WARNING: Some users failed to sync!${NC}"
        echo "Please check the logs for details and consider re-running for failed users."
    fi
}

# Main execution
main() {
    echo "========================================="
    echo "Final Delta Sync Tool"
    echo "========================================="
    echo "Run this AFTER MX records point to Gmail"
    echo ""

    # Parse arguments
    parse_args "$@"

    # Validate CSV
    if [[ ! -f "$CSV_FILE" ]]; then
        echo -e "${RED}Error: CSV file not found: $CSV_FILE${NC}" >&2
        exit 1
    fi

    # Setup directories
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOG_DIR="${LOG_DIR}_${TIMESTAMP}"
    mkdir -p "$LOG_DIR" "$REPORT_DIR"

    # Initialize results file
    echo "user,status,timestamp,exit_code" > "${LOG_DIR}/delta_results.csv"

    # Check cutover status
    check_cutover_status

    # Display configuration
    echo ""
    echo "Configuration:"
    echo "  CSV file: $CSV_FILE"
    echo "  Concurrency: $CONCURRENCY workers"
    echo "  Max age: $MAX_AGE_DAYS days"
    echo "  Delete mode: $DELETE_MODE"
    echo "  Check only: $CHECK_ONLY"

    if [[ "$DELETE_MODE" == "true" ]]; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║           WARNING: DELETE MODE ENABLED             ║${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}║  This will DELETE messages from Gmail that were   ║${NC}"
        echo -e "${RED}║  deleted from the source server!                  ║${NC}"
        echo -e "${RED}║                                                    ║${NC}"
        echo -e "${RED}║  Make sure you have:                              ║${NC}"
        echo -e "${RED}║  1. Tested on a single account first              ║${NC}"
        echo -e "${RED}║  2. Have backups of critical mailboxes            ║${NC}"
        echo -e "${RED}║  3. Understand this is IRREVERSIBLE               ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════╝${NC}"
        echo ""
        read -p "Type 'DELETE' to confirm: " confirm
        if [[ "$confirm" != "DELETE" ]]; then
            echo "Delete mode cancelled"
            exit 1
        fi
    fi

    echo ""
    read -p "Start final delta sync? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Delta sync cancelled"
        exit 0
    fi

    # Create worker script
    create_delta_worker

    # Process priority users first
    process_priority_users

    # Process all remaining users
    process_all_users

    # Generate report
    generate_delta_report

    echo ""
    if [[ "$CHECK_ONLY" == "true" ]]; then
        echo -e "${BLUE}Check completed - no changes were made${NC}"
    else
        echo -e "${GREEN}Final delta sync completed!${NC}"
    fi
}

# Run main
main "$@"