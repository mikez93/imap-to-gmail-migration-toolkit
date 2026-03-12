#!/usr/bin/env bash

# test_single.sh - Test migration on a single mailbox
# Usage: ./test_single.sh

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="${BASE_DIR}/logs/test"

# Test configuration
TEST_REPORT="${BASE_DIR}/reports/test_$(date +%Y%m%d_%H%M%S).txt"

# Interactive setup
interactive_setup() {
    echo "========================================="
    echo "Single Mailbox Migration Test"
    echo "========================================="
    echo ""
    echo "This tool will help you test the migration process on a single mailbox"
    echo "before running the full batch migration."
    echo ""

    # Source server details
    echo -e "${CYAN}Source Server Configuration:${NC}"
    read -p "Source IMAP host (e.g., mail.oldhost.com): " SRC_HOST
    read -p "Source email address: " SRC_USER
    read -sp "Source password: " SRC_PASS
    echo ""

    # Destination server details
    echo ""
    echo -e "${CYAN}Destination Server Configuration:${NC}"
    read -p "Destination IMAP host (default: imap.gmail.com): " DST_HOST
    DST_HOST="${DST_HOST:-imap.gmail.com}"
    read -p "Destination email address: " DST_USER
    echo ""
    echo "For Gmail, you need an App Password (not your regular password)"
    echo "Generate one at: https://myaccount.google.com/apppasswords"
    read -sp "Destination app password: " DST_PASS
    echo ""

    # Test options
    echo ""
    echo -e "${CYAN}Test Options:${NC}"
    read -p "Run in dry-run mode first? (recommended) [y/n]: " dry_run_choice

    # Export for imapsync_cmd.sh
    export SRC_HOST
    export SRC_USER
    export SRC_PASS
    export DST_HOST
    export DST_USER
    export DST_PASS
    export LOG_DIR
}

# Test source connectivity
test_source_connection() {
    echo ""
    echo -e "${BLUE}Testing source server connection...${NC}"

    # Use openssl to test IMAP connection
    if timeout 5 openssl s_client -connect "$SRC_HOST:993" -quiet 2>/dev/null | grep -q "OK"; then
        echo -e "${GREEN}  ✓ Connected to $SRC_HOST on port 993 (IMAPS)${NC}"
    else
        echo -e "${YELLOW}  ⚠ Could not connect to $SRC_HOST:993, trying port 143...${NC}"
        if timeout 5 openssl s_client -connect "$SRC_HOST:143" -quiet -starttls imap 2>/dev/null | grep -q "OK"; then
            echo -e "${GREEN}  ✓ Connected to $SRC_HOST on port 143 (IMAP+STARTTLS)${NC}"
        else
            echo -e "${RED}  ✗ Failed to connect to $SRC_HOST${NC}"
            return 1
        fi
    fi

    # Test authentication using imapsync --justlogin
    echo -e "${BLUE}Testing source authentication...${NC}"
    if imapsync --host1 "$SRC_HOST" --user1 "$SRC_USER" --password1 "$SRC_PASS" --ssl1 \
                --justlogin 2>/dev/null; then
        echo -e "${GREEN}  ✓ Successfully authenticated to source server${NC}"
    else
        echo -e "${RED}  ✗ Authentication failed on source server${NC}"
        echo "    Please check your username and password"
        return 1
    fi
}

# Test destination connectivity
test_destination_connection() {
    echo ""
    echo -e "${BLUE}Testing destination server connection...${NC}"

    # Gmail always uses port 993
    if [[ "$DST_HOST" == "imap.gmail.com" ]]; then
        if timeout 5 openssl s_client -connect "$DST_HOST:993" -quiet 2>/dev/null | grep -q "OK"; then
            echo -e "${GREEN}  ✓ Connected to Gmail IMAP${NC}"
        else
            echo -e "${RED}  ✗ Failed to connect to Gmail${NC}"
            return 1
        fi

        # Check for app password hint
        echo ""
        echo -e "${YELLOW}  Note: Gmail requires:${NC}"
        echo "    1. IMAP enabled in Gmail settings"
        echo "    2. App Password (not regular password)"
        echo "    3. Less secure app access OR 2FA with app password"
    fi

    # Test authentication
    echo -e "${BLUE}Testing destination authentication...${NC}"
    if imapsync --host2 "$DST_HOST" --user2 "$DST_USER" --password2 "$DST_PASS" --ssl2 \
                --justlogin 2>/dev/null; then
        echo -e "${GREEN}  ✓ Successfully authenticated to destination server${NC}"
    else
        echo -e "${RED}  ✗ Authentication failed on destination server${NC}"
        echo "    For Gmail: Make sure you're using an App Password"
        return 1
    fi
}

# Count messages in source
analyze_source_mailbox() {
    echo ""
    echo -e "${BLUE}Analyzing source mailbox...${NC}"

    local analysis_log="${LOG_DIR}/analysis_$(date +%Y%m%d_%H%M%S).log"

    # Run imapsync in dry mode to get folder list and counts
    imapsync --host1 "$SRC_HOST" --user1 "$SRC_USER" --password1 "$SRC_PASS" --ssl1 \
             --justfolders --dry 2>&1 | tee "$analysis_log" | while read line; do
        if echo "$line" | grep -q "Folder "; then
            echo "  $line"
        fi
    done

    # Extract summary
    echo ""
    echo "Source Mailbox Summary:"
    echo "  User: $SRC_USER"

    # Try to get folder count
    local folder_count=$(grep -c "Folder " "$analysis_log" 2>/dev/null || echo "unknown")
    echo "  Folders found: $folder_count"

    # Estimate total messages (this is approximate)
    echo ""
    echo -e "${YELLOW}  Note: Full message count requires scanning all folders${NC}"
}

# Run test migration
run_test_migration() {
    local dry_run="$1"

    echo ""
    if [[ "$dry_run" == "true" ]]; then
        echo -e "${BLUE}Running DRY RUN test (no actual migration)...${NC}"
        export DRY_RUN=true
    else
        echo -e "${BLUE}Running ACTUAL migration test...${NC}"
        export DRY_RUN=false
    fi

    # Create test log directory
    mkdir -p "$LOG_DIR"

    # Run migration
    "${SCRIPT_DIR}/imapsync_cmd.sh"
    local exit_code=$?

    return $exit_code
}

# Verify migration
verify_migration() {
    echo ""
    echo -e "${BLUE}Verifying migration results...${NC}"

    # Find the latest log file
    local latest_log=$(ls -t "${LOG_DIR}"/*.log 2>/dev/null | head -1)

    if [[ -f "$latest_log" ]]; then
        echo "  Analyzing log: $(basename "$latest_log")"

        # Extract key metrics
        local messages_found=$(grep -oP 'Messages found:\s+\K\d+' "$latest_log" 2>/dev/null || echo "0")
        local messages_copied=$(grep -oP 'Messages copied:\s+\K\d+' "$latest_log" 2>/dev/null || echo "0")
        local messages_skipped=$(grep -oP 'Messages skipped:\s+\K\d+' "$latest_log" 2>/dev/null || echo "0")
        local errors=$(grep -c "ERR" "$latest_log" 2>/dev/null || echo "0")

        echo ""
        echo "Migration Results:"
        echo "  Messages found: $messages_found"
        echo "  Messages copied: $messages_copied"
        echo "  Messages skipped: $messages_skipped"
        echo "  Errors: $errors"

        if [[ $errors -gt 0 ]]; then
            echo ""
            echo -e "${YELLOW}Errors found in migration:${NC}"
            grep "ERR" "$latest_log" | head -5 | while read line; do
                echo "  $line"
            done
            echo "  (See full log for all errors)"
        fi

        # Check for common issues
        echo ""
        echo "Checking for common issues:"

        if grep -q "Gmail/All Mail" "$latest_log" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Gmail 'All Mail' folder properly excluded${NC}"
        fi

        if grep -q "X-imapsync" "$latest_log" 2>/dev/null; then
            echo -e "${GREEN}  ✓ Migration headers added for tracking${NC}"
        fi

        if [[ $messages_copied -eq 0 ]] && [[ $messages_found -gt 0 ]]; then
            echo -e "${YELLOW}  ⚠ No messages copied (might be intentional if re-running)${NC}"
        fi
    else
        echo -e "${RED}  No log file found${NC}"
    fi
}

# Generate test report
generate_test_report() {
    echo ""
    echo -e "${BLUE}Generating test report...${NC}"

    mkdir -p "$(dirname "$TEST_REPORT")"

    {
        echo "Single Mailbox Migration Test Report"
        echo "====================================="
        echo "Date: $(date)"
        echo ""
        echo "Configuration:"
        echo "  Source: $SRC_USER@$SRC_HOST"
        echo "  Destination: $DST_USER@$DST_HOST"
        echo ""

        # Add log file analysis
        local latest_log=$(ls -t "${LOG_DIR}"/*.log 2>/dev/null | head -1)
        if [[ -f "$latest_log" ]]; then
            echo "Results from: $(basename "$latest_log")"
            grep -E "(Messages found|Messages copied|Messages skipped|Total bytes)" "$latest_log" || true
            echo ""

            # Check for errors
            local error_count=$(grep -c "ERR" "$latest_log" 2>/dev/null || echo "0")
            echo "Errors encountered: $error_count"

            if [[ $error_count -gt 0 ]]; then
                echo ""
                echo "First 10 errors:"
                grep "ERR" "$latest_log" | head -10
            fi
        fi

        echo ""
        echo "Next Steps:"
        echo "1. Review the results above"
        echo "2. Check Gmail to verify folders and messages appear correctly"
        echo "3. If successful, proceed with batch migration using:"
        echo "   ./run_batch.sh migration_map.csv"

    } > "$TEST_REPORT"

    echo -e "${GREEN}  Report saved to: $TEST_REPORT${NC}"
}

# Main test flow
main() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
    __  ___      _ __   ______          __
   /  |/  /___ _(_) /  /_  __/__  _____/ /_
  / /|_/ / __ `/ / /    / / / _ \/ ___/ __/
 / /  / / /_/ / / /    / / /  __(__  ) /_
/_/  /_/\__,_/_/_/    /_/  \___/____/\__/

EOF
    echo -e "${NC}"

    # Interactive setup
    interactive_setup

    # Connection tests
    echo ""
    echo "========================================="
    echo "Running Connection Tests"
    echo "========================================="

    if ! test_source_connection; then
        echo -e "${RED}Source connection test failed. Please check your settings.${NC}"
        exit 1
    fi

    if ! test_destination_connection; then
        echo -e "${RED}Destination connection test failed. Please check your settings.${NC}"
        exit 1
    fi

    # Analyze source
    analyze_source_mailbox

    # Ask to proceed
    echo ""
    read -p "Proceed with test migration? [y/n]: " proceed
    if [[ "$proceed" != "y" ]]; then
        echo "Test cancelled"
        exit 0
    fi

    # Run migration test
    if [[ "$dry_run_choice" == "y" ]]; then
        # Dry run first
        run_test_migration true
        local dry_exit=$?

        echo ""
        if [[ $dry_exit -eq 0 ]]; then
            echo -e "${GREEN}Dry run completed successfully!${NC}"
            read -p "Run actual migration now? [y/n]: " do_actual
            if [[ "$do_actual" == "y" ]]; then
                run_test_migration false
            fi
        else
            echo -e "${YELLOW}Dry run encountered issues (exit code: $dry_exit)${NC}"
            echo "Please review the logs before proceeding."
        fi
    else
        # Direct migration
        run_test_migration false
    fi

    # Verify results
    verify_migration

    # Generate report
    generate_test_report

    # Final summary
    echo ""
    echo "========================================="
    echo "Test Complete"
    echo "========================================="
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. Log into Gmail and verify:"
    echo "   - Folders appear as labels"
    echo "   - Messages are present with correct dates"
    echo "   - No unexpected duplicates"
    echo ""
    echo "2. If everything looks good, create your migration CSV:"
    echo "   cp migrate/config/migration_map_template.csv migration_map.csv"
    echo "   (Edit with your user list)"
    echo ""
    echo "3. Run the batch migration:"
    echo "   ./scripts/run_batch.sh migration_map.csv"
    echo ""
    echo "Logs saved in: $LOG_DIR"
    echo "Report saved to: $TEST_REPORT"
}

# Check for required tools
check_dependencies() {
    local missing=()

    command -v imapsync >/dev/null 2>&1 || missing+=("imapsync")
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required tools: ${missing[*]}${NC}"
        echo "Install with:"
        echo "  sudo apt-get install imapsync openssl"
        exit 1
    fi
}

# Run checks and main
check_dependencies
main