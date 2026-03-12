#!/usr/bin/env bash

# run_batch.sh - Orchestrate parallel batch migrations
# Usage: ./run_batch.sh migration_map.csv [options]

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BATCH_DIR="${BASE_DIR}/config/batches"
LOG_DIR="${BASE_DIR}/logs"
REPORT_DIR="${BASE_DIR}/reports"
WORKER_SCRIPT="${SCRIPT_DIR}/imapsync_worker.sh"

# Default values
CONCURRENCY=3
BATCH_SIZE=10
DRY_RUN=false
RESUME_FROM=""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Usage function
usage() {
    cat <<EOF
Usage: $0 CSV_FILE [OPTIONS]

Run batch email migration from CSV file

Arguments:
  CSV_FILE              Path to migration CSV file

Options:
  -c, --concurrency N   Number of parallel migrations (default: 3)
  -b, --batch-size N    Users per batch (default: 10)
  -d, --dry-run        Test mode without actual migration
  -r, --resume BATCH    Resume from specific batch number
  -h, --help           Show this help message

Examples:
  # Run with default settings
  $0 migration_map.csv

  # Run with 5 parallel workers, 20 users per batch
  $0 migration_map.csv -c 5 -b 20

  # Dry run to test configuration
  $0 migration_map.csv --dry-run

  # Resume from batch 3 after failure
  $0 migration_map.csv --resume 3
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
            -b|--batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -r|--resume)
                RESUME_FROM="$2"
                shift 2
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

# Setup directories
setup_directories() {
    echo -e "${BLUE}Setting up directories...${NC}"
    mkdir -p "$BATCH_DIR" "$LOG_DIR" "$REPORT_DIR"

    # Create timestamp for this run
    RUN_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    RUN_LOG_DIR="${LOG_DIR}/batch_${RUN_TIMESTAMP}"
    RUN_REPORT="${REPORT_DIR}/batch_${RUN_TIMESTAMP}.csv"
    mkdir -p "$RUN_LOG_DIR"

    echo "  Batch directory: $BATCH_DIR"
    echo "  Log directory: $RUN_LOG_DIR"
    echo "  Report file: $RUN_REPORT"
}

# Split CSV into batches
split_csv_file() {
    echo -e "${BLUE}Splitting CSV into batches...${NC}"

    # Clean old batch files
    rm -f "${BATCH_DIR}"/batch_*.csv

    # Run split script
    if ! python3 "${SCRIPT_DIR}/split_csv.py" "$CSV_FILE" \
        --batch-size "$BATCH_SIZE" \
        --output-dir "$BATCH_DIR"; then
        echo -e "${RED}Failed to split CSV${NC}" >&2
        exit 1
    fi

    # Count batch files
    BATCH_FILES=(${BATCH_DIR}/batch_*.csv)
    NUM_BATCHES=${#BATCH_FILES[@]}

    echo -e "${GREEN}Created $NUM_BATCHES batch files${NC}"
}

# Create worker script
create_worker_script() {
    cat >"$WORKER_SCRIPT" <<'EOF'
#!/usr/bin/env bash

# imapsync_worker.sh - Process single user from CSV
# Usage: ./imapsync_worker.sh batch.csv row_num log_dir

set -euo pipefail

BATCH_CSV="$1"
ROW_NUM="$2"
LOG_DIR="$3"
DRY_RUN="${4:-false}"

# Extract user data from CSV
USER_DATA=$(awk -F',' "NR==${ROW_NUM}" "$BATCH_CSV")
if [[ -z "$USER_DATA" ]]; then
    echo "No data found at row $ROW_NUM" >&2
    exit 1
fi

# Parse CSV fields
IFS=',' read -r SRC_USER SRC_PASS DST_USER DST_PASS <<< "$USER_DATA"

# Export environment variables for imapsync_cmd.sh
export SRC_HOST="${SRC_HOST:-mail.example.com}"
export DST_HOST="${DST_HOST:-imap.gmail.com}"
export SRC_USER
export SRC_PASS
export DST_USER
export DST_PASS
export DRY_RUN
export LOG_DIR

# Run imapsync
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting migration for $DST_USER"

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"${SCRIPT_DIR}/imapsync_cmd.sh"
EXIT_CODE=$?

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed $DST_USER with exit code: $EXIT_CODE"

# Record result
echo "$DST_USER,$EXIT_CODE,$(date '+%Y-%m-%d %H:%M:%S')" >> "${LOG_DIR}/results.csv"

exit $EXIT_CODE
EOF

    chmod +x "$WORKER_SCRIPT"
    echo -e "${GREEN}Created worker script${NC}"
}

# Process single batch
process_batch() {
    local batch_file="$1"
    local batch_num="$2"

    echo ""
    echo -e "${BLUE}Processing Batch $batch_num/$NUM_BATCHES: $(basename "$batch_file")${NC}"

    # Count users in batch (excluding header)
    local num_users=$(($(wc -l < "$batch_file") - 1))
    echo "  Users in batch: $num_users"

    # Create row numbers for parallel processing (skip header)
    seq 2 $((num_users + 1)) | \
    parallel -j "$CONCURRENCY" --eta --joblog "${RUN_LOG_DIR}/batch_${batch_num}.joblog" \
        "$WORKER_SCRIPT" "$batch_file" {} "$RUN_LOG_DIR" "$DRY_RUN"

    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}Batch $batch_num completed successfully${NC}"
    else
        echo -e "${YELLOW}Batch $batch_num completed with some failures (check logs)${NC}"
    fi

    return 0  # Continue even if some users failed
}

# Generate final report
generate_report() {
    echo ""
    echo -e "${BLUE}Generating migration report...${NC}"

    # Initialize report
    echo "user,status,timestamp,batch,log_file" > "$RUN_REPORT"

    # Aggregate results from all batches
    if [[ -f "${RUN_LOG_DIR}/results.csv" ]]; then
        while IFS=',' read -r user exit_code timestamp; do
            status="UNKNOWN"
            if [[ "$exit_code" == "0" ]]; then
                status="SUCCESS"
            elif [[ "$exit_code" == "11" ]]; then
                status="PARTIAL"
            else
                status="FAILED"
            fi

            # Find log file for user
            log_file=$(find "$RUN_LOG_DIR" -name "*${user}*" -type f | head -1 || echo "")

            echo "$user,$status,$timestamp,,$log_file" >> "$RUN_REPORT"
        done < "${RUN_LOG_DIR}/results.csv"
    fi

    # Count results
    local total=$(tail -n +2 "$RUN_REPORT" | wc -l)
    local success=$(grep -c ",SUCCESS," "$RUN_REPORT" || true)
    local partial=$(grep -c ",PARTIAL," "$RUN_REPORT" || true)
    local failed=$(grep -c ",FAILED," "$RUN_REPORT" || true)

    echo ""
    echo "========================================="
    echo "Migration Summary"
    echo "========================================="
    echo "Total users: $total"
    echo -e "${GREEN}Successful: $success${NC}"
    echo -e "${YELLOW}Partial: $partial${NC}"
    echo -e "${RED}Failed: $failed${NC}"
    echo ""
    echo "Report saved to: $RUN_REPORT"
    echo "Logs saved to: $RUN_LOG_DIR"
    echo "========================================="
}

# Check dependencies
check_dependencies() {
    local missing=()

    command -v imapsync >/dev/null 2>&1 || missing+=("imapsync")
    command -v parallel >/dev/null 2>&1 || missing+=("parallel")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required dependencies: ${missing[*]}${NC}" >&2
        echo "Install with:"
        echo "  sudo apt-get install imapsync parallel python3"
        exit 1
    fi
}

# Main execution
main() {
    echo "========================================="
    echo "Email Migration Batch Runner"
    echo "========================================="

    # Parse arguments
    parse_args "$@"

    # Validate CSV file
    if [[ ! -f "$CSV_FILE" ]]; then
        echo -e "${RED}Error: CSV file not found: $CSV_FILE${NC}" >&2
        exit 1
    fi

    # Check dependencies
    check_dependencies

    # Setup
    setup_directories
    split_csv_file
    create_worker_script

    # Initialize results file
    echo "user,exit_code,timestamp" > "${RUN_LOG_DIR}/results.csv"

    # Display configuration
    echo ""
    echo "Configuration:"
    echo "  CSV file: $CSV_FILE"
    echo "  Concurrency: $CONCURRENCY parallel workers"
    echo "  Batch size: $BATCH_SIZE users per batch"
    echo "  Dry run: $DRY_RUN"
    if [[ -n "$RESUME_FROM" ]]; then
        echo "  Resuming from batch: $RESUME_FROM"
    fi

    echo ""
    read -p "Start migration? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Migration cancelled"
        exit 0
    fi

    # Process batches
    echo ""
    echo -e "${BLUE}Starting batch processing...${NC}"

    for i in "${!BATCH_FILES[@]}"; do
        batch_num=$((i + 1))

        # Handle resume
        if [[ -n "$RESUME_FROM" ]] && [[ $batch_num -lt $RESUME_FROM ]]; then
            echo "Skipping batch $batch_num (already processed)"
            continue
        fi

        process_batch "${BATCH_FILES[$i]}" "$batch_num"

        # Small delay between batches
        if [[ $batch_num -lt $NUM_BATCHES ]]; then
            echo "Waiting 5 seconds before next batch..."
            sleep 5
        fi
    done

    # Generate report
    generate_report

    echo ""
    echo -e "${GREEN}Batch migration completed!${NC}"
}

# Run main function
main "$@"