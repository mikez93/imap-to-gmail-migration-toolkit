#!/usr/bin/env bash

# imapsync_cmd.sh - Core imapsync wrapper for single mailbox migration
# Usage: ./imapsync_cmd.sh

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default tuning (override via environment variables when needed)
BUFFER_SIZE=${BUFFER_SIZE:-4194304}
MAX_LINE_LENGTH=${MAX_LINE_LENGTH:-100000}
MAX_MESSAGE_SIZE=${MAX_MESSAGE_SIZE:-52428800}
TMPDIR=${IMAPSYNC_TMPDIR:-/tmp/imapsync_tmp}

# Throttling defaults (Gmail IMAP upload limit: 500 MB/day)
MAX_BYTES_PER_SECOND=${MAX_BYTES_PER_SECOND:-100000}      # 100 KB/s
MAX_BYTES_AFTER=${MAX_BYTES_AFTER:-300000000}              # Throttle after 300 MB transferred
MAX_MSGS_PER_SECOND=${MAX_MSGS_PER_SECOND:-2}             # Caps SEARCH flood from --useheader
RECONNECT_RETRY=${RECONNECT_RETRY:-20}
MIN_AGE_DAYS=${MIN_AGE_DAYS:-}                            # Optional: skip messages newer than N days

# Watchdog integration for safe restarts
WDOG_WRITE_MANIFEST=${WDOG_WRITE_MANIFEST:-true}
WDOG_STATE_DIR=${WDOG_STATE_DIR:-/var/tmp/migration_watchdog}
CRED_DIR=${CRED_DIR:-"$HOME/.imapsync/credentials"}
MAKE_RESTARTABLE=${MAKE_RESTARTABLE:-true}

# Heartbeat configuration
HEARTBEAT_DIR=${HEARTBEAT_DIR:-"$WDOG_STATE_DIR/heartbeats"}
HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL:-5}
IMAPSYNC_BIN=${IMAPSYNC_BIN:-imapsync}

# Docker configuration - use Docker by default on macOS to avoid memory leaks
# See: https://github.com/imapsync/imapsync/issues/312
if [[ -z "${USE_DOCKER:-}" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        USE_DOCKER="true"
    else
        USE_DOCKER="false"
    fi
fi
DOCKER_IMAGE=${DOCKER_IMAGE:-"gilleslamiral/imapsync"}
DOCKER_MEMORY_LIMIT=${DOCKER_MEMORY_LIMIT:-"8g"}  # Limit Docker container to 8GB

# Source shared POSIX helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/posix_helpers.sh"

# Validate required environment variables
validate_env() {
    local required_vars=(
        "SRC_HOST"
        "SRC_USER"
        "SRC_PASS"
        "DST_HOST"
        "DST_USER"
        "DST_PASS"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            echo -e "${RED}Error: Environment variable $var is not set${NC}" >&2
            return 1
        fi
    done
}

# Note: ensure_secure_dir and sanitize_account are now sourced from posix_helpers.sh

# Write passwords to secure files
write_passfiles() {
    local account_safe="$(sanitize_account "$DST_USER")"
    local cred_subdir="${CRED_DIR}/${account_safe}"

    ensure_secure_dir "$CRED_DIR"
    ensure_secure_dir "$cred_subdir"

    PASSFILE1="${cred_subdir}/pass1"
    PASSFILE2="${cred_subdir}/pass2"

    # Use atomic_overwrite with umask 077 for secure passfile creation
    (
        umask 077
        printf '%s' "$SRC_PASS" | atomic_overwrite "$PASSFILE1"
        printf '%s' "$DST_PASS" | atomic_overwrite "$PASSFILE2"
    )

    chmod 600 "$PASSFILE1" "$PASSFILE2"

    echo "Created secure password files in $cred_subdir"
}

# Start heartbeat sidecar process
start_heartbeat() {
    local target_pid="${1:-}"
    ensure_secure_dir "$HEARTBEAT_DIR"
    local account_safe="$(sanitize_account "$DST_USER")"
    HB_FILE="$HEARTBEAT_DIR/${account_safe}.hb"

    # Start heartbeat loop in background
    (
        umask 077
        last_mtime=0
        init_mtime=$(stat -f %m "$LOG_FILE" 2>/dev/null || stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ -n "$init_mtime" && "$init_mtime" -gt 0 ]]; then
            printf '%s\n' "$init_mtime" > "$HB_FILE"
            last_mtime="$init_mtime"
        else
            date +%s > "$HB_FILE"
        fi
        while true; do
            if [[ -n "$target_pid" ]]; then
                if ! kill -0 "$target_pid" 2>/dev/null; then
                    break
                fi
            fi
            mtime=$(stat -f %m "$LOG_FILE" 2>/dev/null || stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
            if [[ -n "$mtime" && "$mtime" -gt 0 && "$mtime" != "$last_mtime" ]]; then
                printf '%s\n' "$mtime" > "$HB_FILE"
                last_mtime="$mtime"
            fi
            sleep "$HEARTBEAT_INTERVAL"
        done
    ) &
    HB_PID=$!

    # Set up cleanup trap
    trap 'stop_heartbeat' EXIT INT TERM

    echo "Started heartbeat for $DST_USER (PID: $HB_PID, interval: ${HEARTBEAT_INTERVAL}s)"
}

# Stop heartbeat process
stop_heartbeat() {
    if [[ -n "${HB_PID:-}" ]]; then
        kill "$HB_PID" 2>/dev/null || true
        wait "$HB_PID" 2>/dev/null || true
        echo "Stopped heartbeat (PID: $HB_PID)"
    fi
}

# Write restart manifest for watchdog
write_restart_manifest() {
    local account_safe="$(sanitize_account "$DST_USER")"
    local manifest="${WDOG_STATE_DIR}/${account_safe}.manifest"

    ensure_secure_dir "$WDOG_STATE_DIR"

    # Build replay command without passwords
    local replay_cmd="$IMAPSYNC_BIN"
    replay_cmd="$replay_cmd --host1 '$SRC_HOST'"
    replay_cmd="$replay_cmd --user1 '$SRC_USER'"
    replay_cmd="$replay_cmd --passfile1 '$PASSFILE1'"
    replay_cmd="$replay_cmd --ssl1"
    replay_cmd="$replay_cmd --host2 '$DST_HOST'"
    replay_cmd="$replay_cmd --user2 '$DST_USER'"
    replay_cmd="$replay_cmd --passfile2 '$PASSFILE2'"
    replay_cmd="$replay_cmd --ssl2"
    replay_cmd="$replay_cmd --syncinternaldates"
    replay_cmd="$replay_cmd --useheader 'Message-Id'"
    replay_cmd="$replay_cmd --automap"
    replay_cmd="$replay_cmd --addheader"
    replay_cmd="$replay_cmd --exclude '\\[Gmail\\]/All Mail'"
    replay_cmd="$replay_cmd --exclude '\\[Gmail\\]/Important'"
    replay_cmd="$replay_cmd --exclude '\\[Gmail\\]/Starred'"
    replay_cmd="$replay_cmd --exclude '^(Junk|Spam|Trash|Deleted Items|Deleted Messages)'"
    replay_cmd="$replay_cmd --buffersize $BUFFER_SIZE"
    replay_cmd="$replay_cmd --maxlinelength $MAX_LINE_LENGTH"
    replay_cmd="$replay_cmd --maxsize $MAX_MESSAGE_SIZE"
    replay_cmd="$replay_cmd --fastio1 --fastio2"
    replay_cmd="$replay_cmd --nofoldersizes --nofoldersizesatend"
    replay_cmd="$replay_cmd --tmpdir '$TMPDIR'"
    replay_cmd="$replay_cmd --sep1 '.'"
    replay_cmd="$replay_cmd --sep2 '/'"
    replay_cmd="$replay_cmd --maxbytespersecond $MAX_BYTES_PER_SECOND"
    replay_cmd="$replay_cmd --maxbytesafter $MAX_BYTES_AFTER"
    replay_cmd="$replay_cmd --maxmessagespersecond $MAX_MSGS_PER_SECOND"
    replay_cmd="$replay_cmd --reconnectretry1 $RECONNECT_RETRY --reconnectretry2 $RECONNECT_RETRY"
    replay_cmd="$replay_cmd --logdir ''"
    replay_cmd="$replay_cmd --logfile '$LOG_FILE'"

    # Capture Docker execution mode so the watchdog replays with the same method
    local log_dir_manifest
    log_dir_manifest=$(dirname "$LOG_FILE")
    local cred_dir_safe_manifest
    cred_dir_safe_manifest="${CRED_DIR}/$(sanitize_account "$DST_USER")"

    # Write manifest file atomically
    (
        umask 077
        cat <<EOF | atomic_overwrite "$manifest"
ACCOUNT="$DST_USER"
LOG_FILE="$LOG_FILE"
REPLAY_CMD="$replay_cmd"
PASSFILE1="$PASSFILE1"
PASSFILE2="$PASSFILE2"
HEARTBEAT_FILE="$HEARTBEAT_DIR/$(sanitize_account "$DST_USER").hb"
HEARTBEAT_INTERVAL="$HEARTBEAT_INTERVAL"
USE_DOCKER="$USE_DOCKER"
DOCKER_IMAGE="$DOCKER_IMAGE"
DOCKER_MEMORY_LIMIT="$DOCKER_MEMORY_LIMIT"
CRED_DIR_SAFE="$cred_dir_safe_manifest"
LOG_DIR="$log_dir_manifest"
TMPDIR_HOST="$TMPDIR"
EXTRA_ENV_FILE=""
EOF
    )

    chmod 600 "$manifest"
    echo "Created restart manifest: $manifest"
}

# Create log directory if it doesn't exist
setup_logging() {
    local root_dir
    root_dir="$(cd "$SCRIPT_DIR/../.." && pwd)"
    local log_dir
    if [[ -n "${LOG_DIR:-}" ]]; then
        if [[ "$LOG_DIR" = /* ]]; then
            log_dir="$LOG_DIR"
        else
            log_dir="$root_dir/$LOG_DIR"
        fi
    else
        log_dir="$root_dir/migrate/logs"
    fi
    mkdir -p "$log_dir"

    # Generate log filename based on destination user and timestamp
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local sanitized_user
    sanitized_user="$(sanitize_account "$DST_USER")"
    LOG_FILE="${log_dir}/${sanitized_user}_${timestamp}.log"

    # Create "latest" symlink for easy discovery
    ln -sfn "$LOG_FILE" "${log_dir}/${sanitized_user}_latest.log"

    echo "Log file: $LOG_FILE"
}

# Main imapsync execution
run_imapsync() {
    local dry_run="${DRY_RUN:-false}"
    local delete_mode="${DELETE_MODE:-false}"
    local max_age="${MAX_AGE_DAYS:-}"

    # Set up secure credentials if requested
    if [[ "$MAKE_RESTARTABLE" == "true" ]]; then
        write_passfiles
    fi

    # Build imapsync command
    local cmd_prefix=""
    if [[ -n "${STUB_BEHAVIOR:-}" ]]; then
        cmd_prefix="STUB_BEHAVIOR='${STUB_BEHAVIOR}'"
    fi
    local cmd="$IMAPSYNC_BIN"

    # Source server configuration
    cmd="$cmd --host1 '$SRC_HOST'"
    cmd="$cmd --user1 '$SRC_USER'"

    # Use passfile or password based on MAKE_RESTARTABLE
    if [[ "$MAKE_RESTARTABLE" == "true" ]]; then
        cmd="$cmd --passfile1 '$PASSFILE1'"
    else
        cmd="$cmd --password1 '$SRC_PASS'"
    fi

    cmd="$cmd --ssl1"

    # Destination server configuration
    cmd="$cmd --host2 '$DST_HOST'"
    cmd="$cmd --user2 '$DST_USER'"

    # Use passfile or password based on MAKE_RESTARTABLE
    if [[ "$MAKE_RESTARTABLE" == "true" ]]; then
        cmd="$cmd --passfile2 '$PASSFILE2'"
    else
        cmd="$cmd --password2 '$DST_PASS'"
    fi

    cmd="$cmd --ssl2"

    # Core sync options
    cmd="$cmd --syncinternaldates"  # Preserve original message dates
    cmd="$cmd --useheader 'Message-Id'"  # Match by Message-Id (works with external imports)
    cmd="$cmd --automap"             # Automatically map special folders
    cmd="$cmd --addheader"           # Add X-imapsync header for tracking

    # Gmail-specific optimizations
    cmd="$cmd --exclude '\\[Gmail\\]/All Mail'"  # Avoid duplicates from All Mail
    cmd="$cmd --exclude '\\[Gmail\\]/Important'"  # Skip Gmail virtual folders
    cmd="$cmd --exclude '\\[Gmail\\]/Starred'"

    # Exclude common spam/trash folders
    cmd="$cmd --exclude '^(Junk|Spam|Trash|Deleted Items|Deleted Messages)'"

    # Performance tuning
    cmd="$cmd --buffersize $BUFFER_SIZE"
    cmd="$cmd --maxlinelength $MAX_LINE_LENGTH"
    cmd="$cmd --maxsize $MAX_MESSAGE_SIZE"
    cmd="$cmd --fastio1"
    cmd="$cmd --fastio2"
    cmd="$cmd --nofoldersizes"
    cmd="$cmd --nofoldersizesatend"
    cmd="$cmd --tmpdir '$TMPDIR'"

    # Folder separators
    cmd="$cmd --sep1 '.'"
    cmd="$cmd --sep2 '/'"

    # Throttling (Gmail rate-limit prevention)
    cmd="$cmd --maxbytespersecond $MAX_BYTES_PER_SECOND"
    cmd="$cmd --maxbytesafter $MAX_BYTES_AFTER"
    cmd="$cmd --maxmessagespersecond $MAX_MSGS_PER_SECOND"
    cmd="$cmd --reconnectretry1 $RECONNECT_RETRY --reconnectretry2 $RECONNECT_RETRY"

    # Age filters
    if [[ -n "$max_age" ]]; then
        cmd="$cmd --maxage $max_age"
    fi
    local min_age="${MIN_AGE_DAYS:-}"
    if [[ -n "$min_age" ]]; then
        cmd="$cmd --minage $min_age"
    fi

    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        cmd="$cmd --dry"
        echo -e "${YELLOW}Running in DRY RUN mode - no actual changes will be made${NC}"
    fi

    # SAFETY: After cutover, new messages arrive in Gmail only. The backfill sync
    # copies old HostGator messages TO Gmail but must NEVER delete Gmail messages.
    # --delete2 is blocked when a backfill_state file exists for this account.
    if [[ "$delete_mode" == "true" ]]; then
        local account_safe_del
        account_safe_del="$(sanitize_account "$DST_USER")"
        if [[ -f "$WDOG_STATE_DIR/${account_safe_del}.backfill_state" ]]; then
            echo -e "${RED}ERROR: Cannot use delete mode during backfill. Account is in post-cutover sync.${NC}"
            echo "Remove $WDOG_STATE_DIR/${account_safe_del}.backfill_state to override (dangerous)."
            return 1
        fi
        echo -e "${YELLOW}WARNING: Delete mode enabled - messages deleted on source will be deleted on destination${NC}"
        read -p "Are you sure you want to continue with delete mode? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Delete mode cancelled"
            return 1
        fi
        cmd="$cmd --delete2"
        cmd="$cmd --expunge2"
    fi

    # Add logging - use --logdir '' to prevent imapsync's default LOG_imapsync/ prefix
    cmd="$cmd --logdir ''"
    cmd="$cmd --logfile '$LOG_FILE'"

    # Create temp directory
    mkdir -p "$TMPDIR"

    echo -e "${GREEN}Starting imapsync for $DST_USER${NC}"

    # Write restart manifest if requested
    if [[ "$WDOG_WRITE_MANIFEST" == "true" ]] && [[ "$MAKE_RESTARTABLE" == "true" ]]; then
        write_restart_manifest
    fi

    # Optionally unset sensitive environment variables
    if [[ "$MAKE_RESTARTABLE" == "true" ]]; then
        unset SRC_PASS DST_PASS
    fi

    # Execute imapsync - via Docker on macOS to avoid memory leaks
    set +e
    if [[ "$USE_DOCKER" == "true" ]]; then
        # Check if Docker is running
        if ! docker info >/dev/null 2>&1; then
            echo -e "${RED}ERROR: Docker is not running. Please start Docker Desktop.${NC}"
            echo "On macOS, native imapsync has severe memory leaks (80GB+)."
            echo "Docker is required to run migrations safely."
            return 1
        fi
        
        # Build Docker command with volume mounts
        # Map: host credential dir -> /creds, host log dir -> /logs, host tmp -> /tmp/imapsync
        local log_dir=$(dirname "$LOG_FILE")
        local log_name=$(basename "$LOG_FILE")
        local cred_dir_safe="${CRED_DIR}/$(sanitize_account "$DST_USER")"
        
        # Rebuild imapsync args for Docker container paths
        local docker_args=""
        docker_args="$docker_args --host1 '$SRC_HOST' --user1 '$SRC_USER'"
        docker_args="$docker_args --passfile1 '/creds/pass1' --ssl1"
        docker_args="$docker_args --host2 '$DST_HOST' --user2 '$DST_USER'"
        docker_args="$docker_args --passfile2 '/creds/pass2' --ssl2"
        docker_args="$docker_args --syncinternaldates --useheader 'Message-Id' --automap --addheader"
        docker_args="$docker_args --exclude '\\[Gmail\\]/All Mail'"
        docker_args="$docker_args --exclude '\\[Gmail\\]/Important'"
        docker_args="$docker_args --exclude '\\[Gmail\\]/Starred'"
        docker_args="$docker_args --exclude '^(Junk|Spam|Trash|Deleted Items|Deleted Messages)'"
        docker_args="$docker_args --buffersize $BUFFER_SIZE"
        docker_args="$docker_args --maxlinelength $MAX_LINE_LENGTH"
        docker_args="$docker_args --maxsize $MAX_MESSAGE_SIZE"
        docker_args="$docker_args --fastio1 --fastio2"
        docker_args="$docker_args --nofoldersizes --nofoldersizesatend"
        docker_args="$docker_args --tmpdir '/tmp/imapsync'"
        docker_args="$docker_args --sep1 '.' --sep2 '/'"
        docker_args="$docker_args --maxbytespersecond $MAX_BYTES_PER_SECOND"
        docker_args="$docker_args --maxbytesafter $MAX_BYTES_AFTER"
        docker_args="$docker_args --maxmessagespersecond $MAX_MSGS_PER_SECOND"
        docker_args="$docker_args --reconnectretry1 $RECONNECT_RETRY --reconnectretry2 $RECONNECT_RETRY"
        [[ -n "$max_age" ]] && docker_args="$docker_args --maxage $max_age"
        [[ -n "${MIN_AGE_DAYS:-}" ]] && docker_args="$docker_args --minage $MIN_AGE_DAYS"
        [[ "$dry_run" == "true" ]] && docker_args="$docker_args --dry"
        # --log forces logging in Docker context (disabled by default)
        docker_args="$docker_args --log --logdir '' --logfile '/logs/$log_name'"
        
        echo "Mode: Docker (${DOCKER_IMAGE}, memory limit: ${DOCKER_MEMORY_LIMIT})"
        echo "Command: docker run imapsync [credentials hidden] ..."
        
        eval "docker run --rm \
            --memory='$DOCKER_MEMORY_LIMIT' \
            -v '$cred_dir_safe:/creds:ro' \
            -v '$log_dir:/logs' \
            -v '$TMPDIR:/tmp/imapsync' \
            '$DOCKER_IMAGE' \
            imapsync $docker_args" &
    else
        echo "Mode: Native"
        echo "Command: imapsync [credentials hidden] ..."
        if [[ -n "$cmd_prefix" ]]; then
            eval "$cmd_prefix $cmd" &
        else
            eval "$cmd" &
        fi
    fi
    local imap_pid=$!
    local account_safe
    account_safe="$(sanitize_account "$DST_USER")"
    ensure_secure_dir "$WDOG_STATE_DIR"
    printf "%s\n" "$imap_pid" | atomic_overwrite "$WDOG_STATE_DIR/${account_safe}.pid"
    # Start heartbeat monitoring (tied to imapsync PID)
    start_heartbeat "$imap_pid"

    wait "$imap_pid"
    local exit_code=$?
    set -e

    # Stop heartbeat monitoring
    stop_heartbeat

    return $exit_code
}

# Parse imapsync log for summary
generate_summary() {
    local exit_code=$1

    echo ""
    echo "========================================="
    echo "Migration Summary for $DST_USER"
    echo "========================================="

    if [[ -f "$LOG_FILE" ]]; then
        # Extract key metrics from log
        local messages_found=$(grep -oP 'Messages found:\s+\K\d+' "$LOG_FILE" 2>/dev/null || echo "Unknown")
        local messages_copied=$(grep -oP 'Messages copied:\s+\K\d+' "$LOG_FILE" 2>/dev/null || echo "Unknown")
        local messages_skipped=$(grep -oP 'Messages skipped:\s+\K\d+' "$LOG_FILE" 2>/dev/null || echo "Unknown")
        local bytes_transferred=$(grep -oP 'Total bytes transferred:\s+\K[\d.]+\s+\w+' "$LOG_FILE" 2>/dev/null || echo "Unknown")
        local errors=$(grep -c "ERR" "$LOG_FILE" 2>/dev/null || echo "0")

        echo "Messages found: $messages_found"
        echo "Messages copied: $messages_copied"
        echo "Messages skipped: $messages_skipped"
        echo "Data transferred: $bytes_transferred"
        echo "Errors encountered: $errors"
    fi

    echo "Exit code: $exit_code"

    if [[ $exit_code -eq 0 ]]; then
        echo -e "${GREEN}Status: SUCCESS${NC}"
    elif [[ $exit_code -eq 11 ]]; then
        echo -e "${YELLOW}Status: PARTIAL SUCCESS (some errors occurred)${NC}"
    else
        echo -e "${RED}Status: FAILED${NC}"
    fi

    echo "Log file: $LOG_FILE"
    echo "========================================="
}

# Main execution
main() {
    echo "ImapSync Migration Tool"
    echo "======================="

    # Validate environment
    if ! validate_env; then
        echo "Please set all required environment variables:"
        echo "  export SRC_HOST='mail.oldhost.com'"
        echo "  export SRC_USER='user@old.com'"
        echo "  export SRC_PASS='password'"
        echo "  export DST_HOST='imap.gmail.com'"
        echo "  export DST_USER='user@new.com'"
        echo "  export DST_PASS='app_password'"
        echo ""
        echo "Optional variables:"
        echo "  export DRY_RUN=true          # Test without making changes"
        echo "  export DELETE_MODE=true      # Mirror deletions (dangerous)"
        echo "  export MAX_AGE_DAYS=365      # Only migrate recent messages"
        echo "  export LOG_DIR=migrate/logs  # Log directory path"
        echo ""
        echo "Watchdog integration variables:"
        echo "  export MAKE_RESTARTABLE=true        # Use passfiles for secure restart"
        echo "  export WDOG_WRITE_MANIFEST=true     # Create restart manifest"
        echo "  export WDOG_STATE_DIR=/var/tmp/migration_watchdog  # State directory"
        echo "  export CRED_DIR=\$HOME/.imapsync/credentials      # Credential storage"
        exit 1
    fi

    # Setup logging
    setup_logging

    # Run migration
    run_imapsync
    local exit_code=$?

    # Generate summary
    generate_summary $exit_code

    exit $exit_code
}

# Run main function
main "$@"
