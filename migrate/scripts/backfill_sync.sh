#!/usr/bin/env bash

# backfill_sync.sh - Background backfill for large mailboxes
# Uses non-overlapping age windows with overlap margins to incrementally
# sync old messages without hitting Gmail's 500 MB/day IMAP upload limit.
#
# Each run picks the next incomplete window from state, runs start_migration.sh
# with --minage/--max-age + --throttle gentle, and self-terminates after a
# configurable session duration.
#
# Usage:
#   ./backfill_sync.sh user@example.com [options]
#
# Options:
#   --throttle PRESET   Override throttle (default: gentle)
#   --session-limit SECS   Max session duration in seconds (default: 7200 = 2hr)
#   --dry-run           Pass through to start_migration.sh
#   --force-window N    Force a specific window number (0-4)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="${WDOG_STATE_DIR:-/var/tmp/migration_watchdog}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
THROTTLE_PRESET="gentle"
SESSION_LIMIT=7200  # 2 hours
DRY_RUN=""
FORCE_WINDOW=""
OVERLAP_MARGIN=5    # Days of overlap between windows

# Window definitions: "minage maxage" pairs
# Window 0: last 2 months (no minage)
# Window 1: 2-6 months (with overlap margin)
# Window 2: 6-12 months
# Window 3: 1-2 years
# Window 4: everything older than 2 years (no maxage)
WINDOWS="0:60 55:180 175:365 360:730 725:0"

log() {
    echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $*"
}

error() {
    echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $*" >&2
}

sanitize_account() {
    echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'
}

usage() {
    cat <<EOF
${BOLD}backfill_sync.sh - Background backfill for large mailboxes${NC}

Usage: $0 <email@domain.com> [options]

Options:
  --throttle PRESET      Throttle preset (default: gentle)
  --session-limit SECS   Max session duration (default: 7200 = 2hr)
  --dry-run              Test without transferring messages
  --force-window N       Force a specific window (0-4)

Windows:
  0: Last 2 months (--max-age 60)
  1: 2-6 months ago (--min-age 55 --max-age 180)
  2: 6-12 months ago (--min-age 175 --max-age 365)
  3: 1-2 years ago (--min-age 360 --max-age 730)
  4: Older than 2 years (--min-age 725)

Each window has a ${OVERLAP_MARGIN}-day overlap margin to catch boundary messages.
EOF
    exit 1
}

# Parse arguments
ACCOUNT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --throttle)
            THROTTLE_PRESET="$2"
            shift 2
            ;;
        --session-limit)
            SESSION_LIMIT="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="--dry-run"
            shift
            ;;
        --force-window)
            FORCE_WINDOW="$2"
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
                error "Multiple accounts specified"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$ACCOUNT" ]]; then
    error "No account specified"
    usage
fi

ACCOUNT_SAFE=$(sanitize_account "$ACCOUNT")
STATE_FILE="$STATE_DIR/${ACCOUNT_SAFE}.backfill_state"
LOCK_FILE="$STATE_DIR/${ACCOUNT_SAFE}.backfill_lock"

# Ensure state dir exists
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

# Lock file to prevent overlapping runs
if [[ -f "$LOCK_FILE" ]]; then
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
        error "Backfill already running for $ACCOUNT (PID $lock_pid)"
        exit 1
    fi
    warn "Stale lock file found, removing"
    rm -f "$LOCK_FILE"
fi

# Write lock
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT INT TERM

# Read or initialize state
if [[ -f "$STATE_FILE" ]]; then
    CURRENT_WINDOW=$(grep '^CURRENT_WINDOW=' "$STATE_FILE" | cut -d= -f2)
    COMPLETED_WINDOWS=$(grep '^COMPLETED_WINDOWS=' "$STATE_FILE" | cut -d= -f2)
else
    CURRENT_WINDOW=0
    COMPLETED_WINDOWS=""
fi

# Force window if requested
if [[ -n "$FORCE_WINDOW" ]]; then
    CURRENT_WINDOW="$FORCE_WINDOW"
    log "Forced to window $CURRENT_WINDOW"
fi

# Count total windows
TOTAL_WINDOWS=$(echo "$WINDOWS" | wc -w | tr -d ' ')

# Check if all windows are done
if [[ "$CURRENT_WINDOW" -ge "$TOTAL_WINDOWS" ]] && [[ -z "$FORCE_WINDOW" ]]; then
    log "All $TOTAL_WINDOWS windows completed for $ACCOUNT"
    log "Completed windows: $COMPLETED_WINDOWS"
    exit 0
fi

# Get current window parameters
WINDOW_IDX=0
WINDOW_MINAGE=""
WINDOW_MAXAGE=""
for w in $WINDOWS; do
    if [[ "$WINDOW_IDX" -eq "$CURRENT_WINDOW" ]]; then
        WINDOW_MINAGE="${w%%:*}"
        WINDOW_MAXAGE="${w##*:}"
        break
    fi
    WINDOW_IDX=$((WINDOW_IDX + 1))
done

if [[ -z "$WINDOW_MINAGE" ]] && [[ -z "$WINDOW_MAXAGE" ]]; then
    error "Invalid window index: $CURRENT_WINDOW"
    exit 1
fi

# Print banner
echo ""
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}    BACKFILL SYNC${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Account:     ${BOLD}$ACCOUNT${NC}"
echo -e "Window:      $CURRENT_WINDOW of $((TOTAL_WINDOWS - 1))"
if [[ "$WINDOW_MINAGE" != "0" ]]; then
    echo -e "Min age:     $WINDOW_MINAGE days"
fi
if [[ "$WINDOW_MAXAGE" != "0" ]]; then
    echo -e "Max age:     $WINDOW_MAXAGE days"
fi
echo -e "Throttle:    $THROTTLE_PRESET"
echo -e "Session max: $((SESSION_LIMIT / 60)) minutes"
echo ""

# Build start_migration.sh arguments
ARGS=("$ACCOUNT" --throttle "$THROTTLE_PRESET")

if [[ "$WINDOW_MAXAGE" != "0" ]]; then
    ARGS+=(--max-age "$WINDOW_MAXAGE")
fi

if [[ "$WINDOW_MINAGE" != "0" ]]; then
    ARGS+=(--min-age "$WINDOW_MINAGE")
fi

if [[ -n "$DRY_RUN" ]]; then
    ARGS+=("$DRY_RUN")
fi

# Run with session time limit
log "Starting backfill window $CURRENT_WINDOW..."
log "Command: $MIGRATE_DIR/start_migration.sh ${ARGS[*]}"

set +e
timeout "$SESSION_LIMIT" "$MIGRATE_DIR/start_migration.sh" "${ARGS[@]}"
EXIT_CODE=$?
set -e

# timeout returns 124 on timeout, pass through other codes
if [[ "$EXIT_CODE" -eq 124 ]]; then
    log "Session time limit reached (${SESSION_LIMIT}s). Will resume next run."
elif [[ "$EXIT_CODE" -eq 0 ]]; then
    log "Window $CURRENT_WINDOW completed successfully"
elif [[ "$EXIT_CODE" -eq 11 ]]; then
    log "Window $CURRENT_WINDOW partially complete (exit 11). Will retry next run."
else
    warn "Window $CURRENT_WINDOW exited with code $EXIT_CODE"
fi

# Update state: advance window on success or timeout (partial progress saved by imapsync)
if [[ "$EXIT_CODE" -eq 0 ]] || [[ "$EXIT_CODE" -eq 124 ]]; then
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        # Window fully synced, advance to next
        COMPLETED_WINDOWS="${COMPLETED_WINDOWS:+$COMPLETED_WINDOWS,}$CURRENT_WINDOW"
        CURRENT_WINDOW=$((CURRENT_WINDOW + 1))
        log "Advancing to window $CURRENT_WINDOW"
    fi
    # On timeout (124), keep the same window for next run (imapsync is incremental)
fi

# Calculate last window that was actually run
if [[ "$EXIT_CODE" -eq 0 ]]; then
    LAST_WINDOW_RUN=$((CURRENT_WINDOW - 1))
else
    LAST_WINDOW_RUN=$CURRENT_WINDOW
fi

# Save state
cat > "$STATE_FILE" <<EOF
CURRENT_WINDOW=$CURRENT_WINDOW
COMPLETED_WINDOWS=$COMPLETED_WINDOWS
LAST_RUN=$(date '+%Y-%m-%d %H:%M:%S')
LAST_EXIT_CODE=$EXIT_CODE
LAST_WINDOW_RUN=$LAST_WINDOW_RUN
THROTTLE=$THROTTLE_PRESET
EOF
chmod 600 "$STATE_FILE"

log "State saved: window=$CURRENT_WINDOW, completed=$COMPLETED_WINDOWS"

exit 0
