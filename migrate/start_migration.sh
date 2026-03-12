#!/usr/bin/env bash

# start_migration.sh - THE ONLY WAY TO RUN MIGRATIONS
# =====================================================
# This script is the MANDATORY entry point for all email migrations.
# It automatically handles:
#   - State reset (clears exhausted restarts, stale heartbeats)
#   - Policy configuration (enables auto-restart)
#   - Watchdog startup (memory management + auto-recovery)
#   - Migration execution (with heartbeat sidecar)
#   - Graceful shutdown and status reporting
#
# Usage:
#   ./start_migration.sh user@example.com
#   ./start_migration.sh user@example.com --dry-run
#
# NEVER run imapsync directly or use standalone scripts like sync_*.sh
# Those bypass memory management, heartbeats, and auto-recovery.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/tmp/migration_watchdog"
HEARTBEAT_DIR="$STATE_DIR/heartbeats"
CRED_DIR="$HOME/.imapsync/credentials"

# Domain defaults for your organization
DEFAULT_SRC_HOST="mail.example.com"
DEFAULT_DST_HOST="imap.gmail.com"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Track background processes for cleanup
WATCHDOG_PID=""

usage() {
    cat <<EOF
${BOLD}start_migration.sh - The ONLY way to run migrations${NC}

Usage: $0 <email@domain.com> [options]

Options:
  --dry-run                  Test without transferring messages
  --max-age DAYS             Only migrate messages newer than DAYS
  --min-age DAYS             Only migrate messages older than DAYS
  --throttle PRESET          Throttle preset: gentle|moderate|aggressive
  --src-host HOST            Source IMAP host (default: $DEFAULT_SRC_HOST)
  --dst-host HOST            Destination IMAP host (default: $DEFAULT_DST_HOST)
  --help                     Show this help

Throttle presets:
  gentle      50 KB/s, throttle after 200 MB, 1 msg/s (backfill-safe, ~400 MB/day)
  moderate    100 KB/s, throttle after 300 MB, 2 msgs/s (default)
  aggressive  No limits (small mailboxes only)

Examples:
  $0 admin@example.com
  $0 admin@example.com --dry-run
  $0 admin@example.com --max-age 30
  $0 admin@example.com --throttle gentle

This script automatically:
  ✓ Resets stale state files (exhausted restarts, old heartbeats)
  ✓ Sets auto-restart policy
  ✓ Starts the watchdog for memory management + auto-recovery
  ✓ Launches imapsync with heartbeat sidecar
  ✓ Monitors and restarts on failure up to 12 times

${RED}NEVER run imapsync directly or use sync_*.sh scripts.${NC}
${RED}They bypass all the robust infrastructure.${NC}
EOF
    exit 1
}

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2
}

# Cleanup function for graceful shutdown
cleanup() {
    echo ""
    
    # Guard against early trap before variables are set
    if [[ -z "${ACCOUNT:-}" ]] || [[ -z "${ACCOUNT_SAFE:-}" ]]; then
        echo "Exiting (early termination)"
        return 0
    fi
    
    log "Shutting down..."
    
    # Stop watchdog if we started it AND no other migrations are still running
    if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        local other_count
        other_count=$(pgrep -f "imapsync.*--host1" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$other_count" -gt 0 ]]; then
            log "Watchdog kept alive — $other_count other migration(s) still running"
        else
            log "Stopping watchdog (PID $WATCHDOG_PID)..."
            kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
            wait "$WATCHDOG_PID" 2>/dev/null || true
        fi
    fi
    
    # Show final status
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Migration Status for $ACCOUNT${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    
    if [[ -f "$STATE_DIR/${ACCOUNT_SAFE}.last_exit" ]]; then
        exit_code=$(cat "$STATE_DIR/${ACCOUNT_SAFE}.last_exit")
        case "$exit_code" in
            0)   echo -e "Status: ${GREEN}COMPLETED SUCCESSFULLY${NC}" ;;
            11)  echo -e "Status: ${YELLOW}PARTIAL SUCCESS (some errors)${NC}" ;;
            137) echo -e "Status: ${RED}KILLED (OOM or signal)${NC}" ;;
            143) echo -e "Status: ${YELLOW}STOPPED BY USER${NC}" ;;
            *)   echo -e "Status: ${RED}FAILED (exit code $exit_code)${NC}" ;;
        esac
    fi
    
    if [[ -f "$STATE_DIR/${ACCOUNT_SAFE}.restarts" ]]; then
        restarts=$(cat "$STATE_DIR/${ACCOUNT_SAFE}.restarts")
        echo "Restart attempts: $restarts/12"
    fi
    
    # Find latest log
    latest_log=$(ls -t "$SCRIPT_DIR/logs/${ACCOUNT_SAFE}"_*.log 2>/dev/null | head -1)
    if [[ -n "$latest_log" ]]; then
        echo "Latest log: $latest_log"
        echo ""
        echo "Last few lines:"
        tail -5 "$latest_log" 2>/dev/null || true
    fi
    
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
}

# Sanitize account name for filenames
sanitize_account() {
    echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'
}

# Check if credentials exist
check_credentials() {
    local account="$1"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    if [[ ! -f "$cred_path/pass1" ]]; then
        error "Source password not found: $cred_path/pass1"
        echo ""
        echo "Create it with:"
        echo "  mkdir -p $cred_path"
        echo "  echo 'SOURCE_PASSWORD' > $cred_path/pass1"
        echo "  chmod 600 $cred_path/pass1"
        return 1
    fi
    
    if [[ ! -f "$cred_path/pass2" ]]; then
        error "Destination password not found: $cred_path/pass2"
        echo ""
        echo "Create it with:"
        echo "  echo 'GOOGLE_APP_PASSWORD_NO_SPACES' > $cred_path/pass2"
        echo "  chmod 600 $cred_path/pass2"
        return 1
    fi
    
    return 0
}

# Reset stale state for account
reset_state() {
    local account_safe="$1"
    
    log "Resetting stale state for $ACCOUNT..."
    
    # Remove exhausted restart counter
    rm -f "$STATE_DIR/${account_safe}.restarts" 2>/dev/null || true
    rm -f "$STATE_DIR/${account_safe}.backoff_idx" 2>/dev/null || true
    rm -f "$STATE_DIR/${account_safe}.next_allowed_ts" 2>/dev/null || true
    
    # Remove stale PID file
    rm -f "$STATE_DIR/${account_safe}.pid" 2>/dev/null || true
    
    # Remove old death snapshots
    rm -f "$STATE_DIR/${account_safe}.death_summary" 2>/dev/null || true
    rm -f "$STATE_DIR/${account_safe}.death_tail" 2>/dev/null || true
    rm -f "$STATE_DIR/${account_safe}.last_exit" 2>/dev/null || true
    rm -f "$STATE_DIR/${account_safe}.last_reason" 2>/dev/null || true
    
    # Remove stale heartbeat
    rm -f "$HEARTBEAT_DIR/${account_safe}.hb" 2>/dev/null || true

    # Remove old restart manifest (prevents watchdog from racing to restart
    # from a stale manifest while we're launching a fresh migration)
    rm -f "$STATE_DIR/${account_safe}.manifest" 2>/dev/null || true

    log "State reset complete"
}

# Set auto-restart policy
set_policy() {
    local account_safe="$1"
    
    log "Setting auto-restart policy..."
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    echo "auto" > "$STATE_DIR/${account_safe}.policy"
    chmod 600 "$STATE_DIR/${account_safe}.policy"
}

# Start watchdog in background
start_watchdog() {
    log "Starting watchdog with auto-restart mode..."
    
    # Verify watchdog script exists
    if [[ ! -x "$SCRIPT_DIR/migration_watchdog.sh" ]]; then
        error "migration_watchdog.sh not found or not executable at $SCRIPT_DIR/"
        return 1
    fi
    
    # Check if watchdog is already running (use bracket trick to avoid matching grep itself)
    if pgrep -f "[m]igration_watchdog\.sh" > /dev/null 2>&1; then
        warn "Watchdog already running, using existing instance"
        return 0
    fi
    
    # Start watchdog in background
    cd "$SCRIPT_DIR"
    RESTART_MODE=auto CHECK_INTERVAL=10 ./migration_watchdog.sh -r >> "$STATE_DIR/watchdog.log" 2>&1 &
    WATCHDOG_PID=$!
    
    # Verify it started
    sleep 1
    if ! kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        error "Watchdog failed to start!"
        return 1
    fi
    
    log "Watchdog started (PID $WATCHDOG_PID)"
}

# Run the migration
run_migration() {
    local account="$1"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    # Verify imapsync_cmd.sh exists
    if [[ ! -x "$SCRIPT_DIR/scripts/imapsync_cmd.sh" ]]; then
        error "imapsync_cmd.sh not found or not executable at $SCRIPT_DIR/scripts/"
        return 1
    fi
    
    log "Starting migration for $account..."
    echo ""
    
    # Export environment variables for imapsync_cmd.sh
    export SRC_HOST="$SRC_HOST"
    export SRC_USER="$account"
    export SRC_PASS="$(cat "$cred_path/pass1")"
    export DST_HOST="$DST_HOST"
    export DST_USER="$account"
    export DST_PASS="$(cat "$cred_path/pass2")"
    export MAKE_RESTARTABLE=true
    export WDOG_WRITE_MANIFEST=true
    export WDOG_STATE_DIR="$STATE_DIR"
    export HEARTBEAT_DIR="$HEARTBEAT_DIR"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        export DRY_RUN=true
        warn "DRY RUN MODE - no messages will be transferred"
    fi
    
    if [[ -n "$MAX_AGE_DAYS" ]]; then
        export MAX_AGE_DAYS="$MAX_AGE_DAYS"
        log "Filtering to messages newer than $MAX_AGE_DAYS days"
    fi

    if [[ -n "$MIN_AGE_DAYS" ]]; then
        export MIN_AGE_DAYS="$MIN_AGE_DAYS"
        log "Filtering to messages older than $MIN_AGE_DAYS days"
    fi
    
    # Run the migration
    cd "$SCRIPT_DIR/scripts"
    ./imapsync_cmd.sh
    local exit_code=$?
    
    # Clear sensitive env vars (imapsync_cmd.sh already wrote them to passfiles)
    unset SRC_PASS DST_PASS 2>/dev/null || true
    
    return $exit_code
}

# Apply throttle preset to environment variables
apply_throttle_preset() {
    local preset="$1"
    case "$preset" in
        gentle)
            export MAX_BYTES_PER_SECOND=50000         # 50 KB/s
            export MAX_BYTES_AFTER=200000000           # Throttle after 200 MB
            export MAX_MSGS_PER_SECOND=1               # 1 msg/s (gentle on SEARCH)
            ;;
        moderate)
            export MAX_BYTES_PER_SECOND=100000         # 100 KB/s
            export MAX_BYTES_AFTER=300000000            # Throttle after 300 MB
            export MAX_MSGS_PER_SECOND=2               # 2 msgs/s
            ;;
        aggressive)
            export MAX_BYTES_PER_SECOND=0              # No limit
            export MAX_BYTES_AFTER=0                    # No throttle threshold
            export MAX_MSGS_PER_SECOND=0               # No limit
            ;;
        *)
            error "Unknown throttle preset: $preset (use gentle|moderate|aggressive)"
            exit 1
            ;;
    esac
    log "Throttle preset: $preset (bytes/s=$MAX_BYTES_PER_SECOND, after=$MAX_BYTES_AFTER, msgs/s=$MAX_MSGS_PER_SECOND)"
}

# Parse arguments
ACCOUNT=""
DRY_RUN="false"
MAX_AGE_DAYS=""
MIN_AGE_DAYS=""
THROTTLE_PRESET=""
SRC_HOST="$DEFAULT_SRC_HOST"
DST_HOST="$DEFAULT_DST_HOST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --max-age)
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                error "--max-age requires a numeric value (days)"
                exit 1
            fi
            MAX_AGE_DAYS="$2"
            shift 2
            ;;
        --min-age)
            if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                error "--min-age requires a numeric value (days)"
                exit 1
            fi
            MIN_AGE_DAYS="$2"
            shift 2
            ;;
        --throttle)
            if [[ -z "${2:-}" ]]; then
                error "--throttle requires a value (gentle|moderate|aggressive)"
                exit 1
            fi
            THROTTLE_PRESET="$2"
            shift 2
            ;;
        --src-host)
            SRC_HOST="$2"
            shift 2
            ;;
        --dst-host)
            DST_HOST="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        -*)
            error "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$ACCOUNT" ]]; then
                ACCOUNT="$1"
            else
                error "Multiple accounts specified. Run separately for each account."
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$ACCOUNT" ]]; then
    error "No account specified"
    usage
fi

if [[ ! "$ACCOUNT" =~ ^[^@]+@[^@]+$ ]]; then
    error "Invalid email format: $ACCOUNT"
    exit 1
fi

ACCOUNT_SAFE=$(sanitize_account "$ACCOUNT")

# Setup cleanup trap
trap cleanup EXIT INT TERM

# Print banner
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}    EMAIL MIGRATION SYSTEM${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Account:     ${BOLD}$ACCOUNT${NC}"
echo -e "Source:      $SRC_HOST"
echo -e "Destination: $DST_HOST"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "Mode:        ${YELLOW}DRY RUN${NC}"
fi
if [[ -n "$THROTTLE_PRESET" ]]; then
    echo -e "Throttle:    $THROTTLE_PRESET"
fi
echo ""

# Apply throttle preset if specified
if [[ -n "$THROTTLE_PRESET" ]]; then
    apply_throttle_preset "$THROTTLE_PRESET"
fi

# Ensure directories exist
mkdir -p "$STATE_DIR"
mkdir -p "$HEARTBEAT_DIR"
mkdir -p "$SCRIPT_DIR/logs"
chmod 700 "$STATE_DIR"
chmod 700 "$HEARTBEAT_DIR"

# Check credentials
if ! check_credentials "$ACCOUNT"; then
    exit 1
fi
log "Credentials verified"

# Reset stale state
reset_state "$ACCOUNT_SAFE"

# Set auto-restart policy
set_policy "$ACCOUNT_SAFE"

# Start watchdog
if ! start_watchdog; then
    error "Failed to start watchdog"
    exit 1
fi

# Give watchdog a moment to initialize
sleep 2

# Run migration
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}Starting imapsync...${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""

run_migration "$ACCOUNT"
exit_code=$?

# Store exit code for cleanup summary
echo "$exit_code" > "$STATE_DIR/${ACCOUNT_SAFE}.last_exit"

exit $exit_code
