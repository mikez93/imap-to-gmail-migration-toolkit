#!/usr/bin/env sh

# migration_watchdog.sh - Secure Migration Watchdog with Dynamic Process Discovery
# Monitor and optionally restart failed imapsync migrations
# POSIX sh compliant - no bashisms, secure credential handling

# Configuration defaults (override via environment or CLI)
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
MAX_RESTARTS="${MAX_RESTARTS:-12}"
MEMORY_LIMIT_MB="${MEMORY_LIMIT_MB:-40960}"  # 40GB default
MEMORY_COOLDOWN="${MEMORY_COOLDOWN:-30}"
STATE_DIR="${STATE_DIR:-/var/tmp/migration_watchdog}"
LOG_DIRS="${LOG_DIRS:-LOG_imapsync/migrate/logs migrate/logs LOG_imapsync/LOG_imapsync/logs}"
RESTART_MODE="${RESTART_MODE:-monitor}"  # monitor|auto
RETRY_EXIT_CODES="${RETRY_EXIT_CODES:-11 74 75 111 162}"  # Retryable exit codes (includes 11=partial, 162=rate-limited)
STALL_MINUTES="${STALL_MINUTES:-10}"
BACKOFF_SECONDS="${BACKOFF_SECONDS:-60 120 300 900 1800}"  # 1m, 2m, 5m, 15m, 30m
RESET_RESTARTS_AFTER_SEC="${RESET_RESTARTS_AFTER_SEC:-300}"  # Auto-unblock after 5m
DEDUPE_ENFORCE="${DEDUPE_ENFORCE:-true}"          # Ensure one process per account
DEDUPE_POLICY="${DEDUPE_POLICY:-keep-newest}"     # keep-newest|keep-oldest|log-only

# New configuration for enhanced features
PREFER_DST_USER="${PREFER_DST_USER:-true}"  # Use --user2 as canonical account ID
HEARTBEAT_DIR="${HEARTBEAT_DIR:-$STATE_DIR/heartbeats}"
HEARTBEAT_TTL="${HEARTBEAT_TTL:-300}"  # 5 minutes
LOG_JSON="${LOG_JSON:-true}"
LOG_JSON_FILE="${LOG_JSON_FILE:-$STATE_DIR/watchdog.jsonl}"
WDOG_DEATH_TAIL_LINES="${WDOG_DEATH_TAIL_LINES:-100}"

# Colors for output (optional, works without)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    NC='\033[0m'
    BOLD='\033[1m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    NC=''
    BOLD=''
fi

# Logging function
log() {
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf "[%s] %s\n" "$ts" "$*"
    printf "[%s] %s\n" "$ts" "$*" >> "$STATE_DIR/watchdog.log"
}

# JSON escape function for safe logging
# JSON escape function for safe logging (BSD-compatible)
json_escape() {
    awk -v s="$1" 'BEGIN {
        gsub(/\\/, "\\\\", s);
        gsub(/"/, "\\\"", s);
        gsub(/\t/, "\\t", s);
        gsub(/\r/, "\\r", s);
        gsub(/\n/, "\\n", s);
        printf "%s", s;
    }'
}


# JSON logging function for structured events
log_json() {
    [ "${LOG_JSON:-true}" != "true" ] && return 0
    event=$1
    account=$2
    shift 2

    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    umask 077
    {
        printf '{"ts":"%s","pid":%s,"event":"%s","account":"%s"' \
            "$ts" "$$" "$(json_escape "$event")" "$(json_escape "$account")"

        if [ $# -gt 0 ]; then
            printf ',"metadata":{'
            first=1
            for kv in "$@"; do
                k=${kv%%=*}
                v=${kv#*=}
                [ $first -eq 0 ] && printf ','
                printf '"%s":"%s"' "$(json_escape "$k")" "$(json_escape "$v")"
                first=0
            done
            printf '}'
        fi
        printf '}\n'
    } >> "$LOG_JSON_FILE"
}

# Sanitize account name for safe filenames (canonical _at_ format)
sanitize_account() {
    echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'
}

# Legacy underscore-only sanitizer (backward compatibility)
sanitize_acct() {
    echo "$1" | tr '@' '_' | tr -cd '[:alnum:]_.-'
}

# State file helpers (prefer _at_, allow legacy reads)
safe_name_primary() { sanitize_account "$1"; }
safe_name_legacy()  { sanitize_acct "$1"; }

find_state_file() {
    account="$1"
    suffix="$2"
    s1=$(safe_name_primary "$account")
    s2=$(safe_name_legacy "$account")
    if [ -f "$STATE_DIR/${s1}.${suffix}" ]; then
        echo "$STATE_DIR/${s1}.${suffix}"
    elif [ -f "$STATE_DIR/${s2}.${suffix}" ]; then
        echo "$STATE_DIR/${s2}.${suffix}"
    else
        echo ""
    fi
}

state_file_for_write() {
    account="$1"
    suffix="$2"
    echo "$STATE_DIR/$(safe_name_primary "$account").${suffix}"
}

remove_state_file() {
    account="$1"
    suffix="$2"
    s1=$(safe_name_primary "$account")
    s2=$(safe_name_legacy "$account")
    rm -f "$STATE_DIR/${s1}.${suffix}" "$STATE_DIR/${s2}.${suffix}" 2>/dev/null || true
}

# Ensure state directory exists with proper permissions
ensure_state_dir() {
    if [ ! -d "$STATE_DIR" ]; then
        mkdir -p "$STATE_DIR"
        chmod 700 "$STATE_DIR"
    fi
}

# Ensure heartbeat directory exists
ensure_heartbeat_dir() {
    if [ ! -d "$HEARTBEAT_DIR" ]; then
        mkdir -p "$HEARTBEAT_DIR"
        chmod 700 "$HEARTBEAT_DIR"
    fi
}

# Get heartbeat file path for account (prefer _at_, tolerate legacy)
heartbeat_file_for_account() {
    acct="$1"
    primary="$HEARTBEAT_DIR/$(sanitize_account "$acct").hb"
    legacy="$HEARTBEAT_DIR/$(sanitize_acct "$acct").hb"

    if [ -f "$primary" ]; then
        printf '%s' "$primary"
    elif [ -f "$legacy" ]; then
        printf '%s' "$legacy"
    else
        # Return primary path for new files
        printf '%s' "$primary"
    fi
}

# Get heartbeat age in seconds (-1 if missing)
heartbeat_age() {
    hb=$(heartbeat_file_for_account "$1")
    if [ -f "$hb" ]; then
        now=$(date +%s)
        ts=$(cat "$hb" 2>/dev/null)
        case "$ts" in
            ''|*[!0-9]*) echo -1 ;;
            *) echo $((now - ts)) ;;
        esac
    else
        echo -1
    fi
}

# Check if process is stalled based on heartbeat
is_stalled() {
    age=$(heartbeat_age "$1")
    [ "$age" -ge 0 ] && [ "$age" -ge "$HEARTBEAT_TTL" ]
}

# Helper: atomically overwrite a file using stdin as content; permissions 600 via umask
atomic_overwrite() {
    path="$1"
    dir=$(dirname "$path")
    base=$(basename "$path")
    tmp="$dir/.${base}.tmp.$$"
    umask 077
    if cat > "$tmp"; then
        mv -f "$tmp" "$path"
    else
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
}

# Helper: is positive integer (including zero)
is_pos_int() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Helper: return integer or default if invalid
get_int_or_default() {
    val="$1"
    def="$2"
    if is_pos_int "$val"; then
        printf "%s" "$val"
    else
        printf "%s" "$def"
    fi
}

# Helper: parse option value from a command string, handling --opt=value and --opt value with optional quotes
# Usage: parse_opt_value "$cmd" "--user1"
parse_opt_value() {
    _cmd="$1"
    _opt="$2"
    printf "%s\n" "$_cmd" | awk -v o="$_opt" '
    {
        for (i=1;i<=NF;i++) {
            if ($i==o && (i+1)<=NF) {
                v=$(i+1)
                # strip surrounding single/double quotes
                sub(/^'\''/,"",v); sub(/'\''$/,"",v)
                sub(/^"/,"",v);    sub(/"$/,"",v)
                print v; exit
            }
            if ($i ~ "^"o"=") {
                v=$i
                sub("^"o"=","",v)
                sub(/^'\''/,"",v); sub(/'\''$/,"",v)
                sub(/^"/,"",v);    sub(/"$/,"",v)
                print v; exit
            }
        }
    }'
}

# Helper: detect unquoted pipe characters (reject shell pipelines)
has_unquoted_pipe() {
    printf '%s\n' "$1" | awk '
        BEGIN {sq=0; dq=0; q=sprintf("%c",39)}
        {
            for (i=1; i<=length($0); i++) {
                c=substr($0,i,1)
                if (c==q && dq==0) {sq = !sq; continue}
                if (c=="\"" && sq==0) {dq = !dq; continue}
                if (c=="|" && sq==0 && dq==0) {print "YES"; exit}
            }
        }'
}

# Helper: prune KNOWN_ACCOUNTS to avoid unbounded growth
prune_known_accounts() {
    new=""
    for _acct in $KNOWN_ACCOUNTS; do
        if case " $RUNNING_ACCOUNTS " in *" $_acct "*) true ;; *) false ;; esac; then
            new="$new $_acct"
        else
            pid_file=$(find_state_file "$_acct" "pid")
            if [ -n "$pid_file" ] && [ -f "$pid_file" ]; then
            new="$new $_acct"
            fi
        fi
    done
    KNOWN_ACCOUNTS="$new"
}

# Include accounts from manifests so short-lived runs are tracked
add_manifest_accounts() {
    for mf in "$STATE_DIR"/*.manifest; do
        [ -f "$mf" ] || continue
        acct=$(grep -E '^ACCOUNT=' "$mf" | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//')
        [ -n "$acct" ] || continue
        if case " $KNOWN_ACCOUNTS " in *" $acct "*) false ;; *) true ;; esac; then
            KNOWN_ACCOUNTS="$KNOWN_ACCOUNTS $acct"
        fi
    done
}

# Helper: sanitize numeric configuration values with defaults
sanitize_config_numbers() {
    CHECK_INTERVAL=$(get_int_or_default "$CHECK_INTERVAL" 60)
    MAX_RESTARTS=$(get_int_or_default "$MAX_RESTARTS" 6)
    MEMORY_LIMIT_MB=$(get_int_or_default "$MEMORY_LIMIT_MB" 40960)
    MEMORY_COOLDOWN=$(get_int_or_default "$MEMORY_COOLDOWN" 30)
    STALL_MINUTES=$(get_int_or_default "$STALL_MINUTES" 10)
}

# Global lock to prevent multiple watchdog instances
acquire_global_lock() {
    LOCK_DIR="$STATE_DIR/.watchdog.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        umask 077
        printf "%s\n" "$$" | atomic_overwrite "$LOCK_DIR/pid"
        trap 'release_global_lock' EXIT
        trap 'release_global_lock; exit 0' INT TERM
        return 0
    fi

    if [ -f "$LOCK_DIR/pid" ]; then
        holder=$(cat "$LOCK_DIR/pid" 2>/dev/null)
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            log "Another watchdog instance is running (PID $holder); exiting"
            exit 1
        fi
        log "Stale lock detected; reclaiming"
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            umask 077
            printf "%s\n" "$$" | atomic_overwrite "$LOCK_DIR/pid"
            trap 'release_global_lock' EXIT
            trap 'release_global_lock; exit 0' INT TERM
            return 0
        fi
    fi

    log "Unable to acquire global lock; exiting"
    exit 1
}

release_global_lock() {
    LOCK_DIR="$STATE_DIR/.watchdog.lock"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# Discover all running imapsync processes dynamically
discover_imapsync_processes() {
    # Only match actual perl imapsync processes, not shell wrappers
    # Updated: robustly match both perl- and binary-invoked imapsync commands, and ignore watchdog/awk/grep noise
    ps -eo pid=,comm=,args= 2>/dev/null | awk '
        {
            pid=$1
            comm=$2
            args=""
            for (i=3; i<=NF; i++) {
                args = args $i " "
            }
            # Match imapsync as command, standalone word, or path ending (allow suffixes like _stub, -bin)
            is_imapsync = (comm ~ /^imapsync/) || (args ~ /(^|[[:space:]])imapsync([[:space:]]|$|[-_.])/) || (args ~ /\/imapsync([[:space:]]|$|[-_.])/) || (args ~ /perl[[:space:]].*imapsync/)
            if (is_imapsync) {
                # Filter out our own watchdog and helper processes
                if (args !~ /migration_watchdog\.sh/ && args !~ /imapsync_cmd\.sh/ && args !~ /awk/ && args !~ /grep/) {
                    sub(/[[:space:]]+$/, "", args)
                    printf "%s|%s\n", pid, args
                }
            }
        }'
}

# Decide which PID to keep among duplicates
pick_winner_pid() {
    policy="$1"; shift
    # input: lines "pid uptime"
    case "$policy" in
        keep-oldest)
            sort -k2nr | head -1 | awk '{print $1}'
            ;;
        *) # keep-newest
            sort -k2n | head -1 | awk '{print $1}'
            ;;
    esac
}

# Extract account from command line (prefer DST_USER for consistency)
get_account_from_cmd() {
    cmd="$1"
    if [ "${PREFER_DST_USER:-true}" = "true" ]; then
        # Try --user2 first (destination user is canonical)
        account=$(parse_opt_value "$cmd" "--user2")
        # Fallback to --user1 if user2 not found
        if [ -z "$account" ]; then
            account=$(parse_opt_value "$cmd" "--user1")
        fi
    else
        # Traditional behavior: try --user1 first
        account=$(parse_opt_value "$cmd" "--user1")
        # Fallback to --user2 if user1 not found
        if [ -z "$account" ]; then
            account=$(parse_opt_value "$cmd" "--user2")
        fi
    fi
    echo "$account"
}

# Extract log file from command line
get_log_from_cmd() {
    cmd="$1"
    parse_opt_value "$cmd" "--logfile"
}

# Find log file by searching directories
fallback_get_log_from_dirs() {
    account="$1"
    # Use full sanitized pattern to match actual log naming
    sanitized=$(sanitize_account "$account")

    for dir in $LOG_DIRS; do
        if [ -d "$dir" ]; then
            # First check for "latest" symlink if it exists
            if [ -L "$dir/${sanitized}_latest.log" ]; then
                readlink "$dir/${sanitized}_latest.log" 2>/dev/null && return
            fi
            # Then look for actual log files with full pattern
            latest=$(ls -t "$dir" 2>/dev/null | grep "^${sanitized}_" | grep "\.log$" | head -1)
            if [ -n "$latest" ]; then
                echo "$dir/$latest"
                return
            fi
        fi
    done
}

# Get RSS memory in MB for a PID
get_rss_mb() {
    pid="$1"
    if [ -n "$pid" ]; then
        rss_kb=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$rss_kb" ]; then
            echo $((rss_kb / 1024))
        else
            echo "0"
        fi
    else
        echo "0"
    fi
}

# Get file age in minutes (-1 if unavailable)
file_age_minutes() {
    path="$1"
    if [ ! -f "$path" ]; then
        echo -1
        return
    fi
    mtime=$(stat -f %m "$path" 2>/dev/null || stat -c %Y "$path" 2>/dev/null)
    if [ -z "$mtime" ]; then
        echo -1
        return
    fi
    now=$(date +%s)
    age=$(( (now - mtime) / 60 ))
    echo "$age"
}

# Get process uptime in seconds (portable macOS/Linux)
get_pid_uptime_secs() {
    pid="$1"
    # Try etimes (Linux) first
    etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$etimes" ] && echo "$etimes" | grep -Eq '^[0-9]+$'; then
        echo "$etimes"
        return
    fi

    # macOS: parse etime [[dd-]hh:]mm:ss
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$etime" ]; then
        echo "0"
        return
    fi

    d=0; h=0; m=0; s=0
    case "$etime" in
        *-*:*:*)
            d=${etime%%-*}
            rest=${etime#*-}
            h=${rest%%:*}
            rest=${rest#*:}
            m=${rest%%:*}
            s=${rest#*:}
            ;;
        *:*:*)
            h=${etime%%:*}
            rest=${etime#*:}
            m=${rest%%:*}
            s=${rest#*:}
            ;;
        *:*)
            m=${etime%%:*}
            s=${etime#*:}
            ;;
        *)
            s="$etime"
            ;;
    esac
    # Force base-10 to avoid octal interpretation (08 -> error) on macOS
    d=$((10#$d)); h=$((10#$h)); m=$((10#$m)); s=$((10#$s))
    echo $((d*86400 + h*3600 + m*60 + s))
}

# Parse exit code from log file
parse_exit_code() {
    logf="$1"
    if [ -f "$logf" ]; then
        grep -E "Exiting with return value [0-9]+" "$logf" 2>/dev/null | tail -1 | awk '{print $NF}'
    fi
}

# Classify migration status based on exit code and log content
classify_status() {
    code="$1"
    logf="$2"

    # Check exit code first
    case "$code" in
        0)
            echo "complete"
            ;;
        6)
            # EXIT_BY_SIGNAL (imapsync message). Treat as retryable; often transient or kill.
            echo "retryable"
            ;;
        137|143)
            echo "user-stop"
            ;;
        162)
            # Gmail rate limit exceeded (Account exceeded command or bandwidth limits)
            echo "rate-limited"
            ;;
        *)
            # Check if this is a retryable code
            for rc in $RETRY_EXIT_CODES; do
                if [ "$code" = "$rc" ]; then
                    echo "retryable"
                    return
                fi
            done

            # Check log patterns when exit code unhelpful
            if [ -f "$logf" ]; then
                if grep -q "EXIT_BY_SIGNAL\|Killed by signal\|SIGTERM\|SIGKILL" "$logf" 2>/dev/null; then
                    echo "retryable"
                elif grep -q "Connection reset\|timeout\|temporarily unavailable\|Network is unreachable" "$logf" 2>/dev/null; then
                    echo "retryable"
                else
                    echo "fatal"
                fi
            else
                echo "fatal"
            fi
            ;;
    esac
}

# Check if restart is allowed for an account
restart_block_reason() {
    account="$1"
    # Global mode
    if [ "$RESTART_MODE" != "auto" ]; then
        echo "monitor-mode"; return 0
    fi
    # Stop sentinel
    stop_file=$(find_state_file "$account" "stop")
    if [ -n "$stop_file" ] && [ -f "$stop_file" ]; then
        echo "stop-sentinel"; return 0
    fi
    # Policy
    policy_file=$(find_state_file "$account" "policy")
    if [ -n "$policy_file" ] && [ -f "$policy_file" ]; then
        policy=$(cat "$policy_file")
        if [ "$policy" = "never" ]; then
            echo "policy-never"; return 0
        fi
    fi
    # Restart count
    restart_count=0
    restart_file=$(find_state_file "$account" "restarts")
    if [ -n "$restart_file" ] && [ -f "$restart_file" ]; then
        rc_raw=$(cat "$restart_file")
        restart_count=$(get_int_or_default "$rc_raw" 0)
    fi
    if [ "$restart_count" -ge "$MAX_RESTARTS" ]; then
        # Optionally auto-reset after cooldown to avoid getting stuck forever
        ra_log=$(find_state_file "$account" "restart_attempts.log")
        if [ -n "$ra_log" ] && [ -f "$ra_log" ]; then
            mtime=$(stat -f %m "$ra_log" 2>/dev/null || stat -c %Y "$ra_log" 2>/dev/null)
        else
            mtime=0
        fi
        now=$(date +%s)
        age=$((now - ${mtime:-0}))
        if [ "$RESET_RESTARTS_AFTER_SEC" -gt 0 ] && [ "$age" -ge "$RESET_RESTARTS_AFTER_SEC" ]; then
            printf '%s\n' 0 | atomic_overwrite "$(state_file_for_write "$account" "restarts")"
            echo ""  # allow restart now
            return 0
        fi
        echo "restarts-exhausted"; return 0
    fi
    # Backoff
    backoff_file=$(find_state_file "$account" "next_allowed_ts")
    if [ -n "$backoff_file" ] && [ -f "$backoff_file" ]; then
        next_ts_raw=$(cat "$backoff_file")
        next_ts=$(get_int_or_default "$next_ts_raw" 0)
        now=$(date +%s)
        if [ "$now" -lt "$next_ts" ]; then
            echo "backoff-$((next_ts-now))s"; return 0
        fi
    fi
    echo ""  # empty means allowed
}

can_restart() {
    r=$(restart_block_reason "$1")
    [ -z "$r" ]
}

# Read restart manifest
read_manifest() {
    account="$1"
    manifest=$(find_state_file "$account" "manifest")
    if [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
        return 1
    fi

    # Safely extract KEY=VALUE without executing the manifest.
    # Only strip a matching pair of outermost double quotes; preserve inner single quotes.
    _extract_val() {
        key="$1"
        # Extract everything to the right of the first '='
        val=$(grep -E "^${key}=" "$manifest" | head -1 | sed 's/^[^=]*=//')
        # If value is double-quoted, strip just that outer pair
        case "$val" in
            \"*\")
                val=$(printf '%s' "$val" | sed 's/^"//; s/"$//')
                ;;
        esac
        printf '%s\n' "$val"
    }

    ACCOUNT=$(_extract_val "ACCOUNT")
    LOG_FILE=$(_extract_val "LOG_FILE")
    REPLAY_CMD=$(_extract_val "REPLAY_CMD")
    PASSFILE1=$(_extract_val "PASSFILE1")
    PASSFILE2=$(_extract_val "PASSFILE2")

    # Optional heartbeat fields
    HEARTBEAT_FILE=$(_extract_val "HEARTBEAT_FILE")
    HEARTBEAT_INTERVAL=$(_extract_val "HEARTBEAT_INTERVAL")

    # Optional Docker execution fields (for macOS restart fidelity)
    MANIFEST_USE_DOCKER=$(_extract_val "USE_DOCKER")
    MANIFEST_DOCKER_IMAGE=$(_extract_val "DOCKER_IMAGE")
    MANIFEST_DOCKER_MEMORY=$(_extract_val "DOCKER_MEMORY_LIMIT")
    MANIFEST_CRED_DIR=$(_extract_val "CRED_DIR_SAFE")
    MANIFEST_LOG_DIR=$(_extract_val "LOG_DIR")
    MANIFEST_TMPDIR=$(_extract_val "TMPDIR_HOST")

    # Basic validation
    if [ -z "$ACCOUNT" ] || [ -z "$REPLAY_CMD" ]; then
        log "ERROR: Manifest missing ACCOUNT or REPLAY_CMD"
        return 1
    fi

    # Reject plaintext passwords in replay command
    if echo "$REPLAY_CMD" | grep -q -- '--password1\|--password2'; then
        log "ERROR: Manifest contains plaintext passwords - refusing to use"
        return 1
    fi

    # REPLAY_CMD must start with imapsync (allow env assignments and paths)
    bin=$(printf '%s\n' "$REPLAY_CMD" | awk '
        {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                    continue
                }
                print $i
                exit
            }
        }')
    # Strip surrounding quotes if present
    bin=$(printf '%s' "$bin" | sed "s/^['\"]//; s/['\"]$//")
    base=${bin##*/}
    case "$base" in
        imapsync|imapsync_*|imapsync-*) ;;
        *)
            log "ERROR: Manifest REPLAY_CMD must start with imapsync (path allowed, got: $base)"
            return 1
            ;;
    esac

    # Reject dangerous shell metacharacters to prevent injection
    # - Semicolons, backticks, redirections, command substitution, logical AND/OR
    # Note: We allow pipe | in quoted strings (for regex patterns like Junk|Spam|Trash)
    if echo "$REPLAY_CMD" | grep -q '[;`<>]'; then
        log "ERROR: Manifest REPLAY_CMD contains forbidden metacharacters"
        return 1
    fi
    # Check for dangerous operators but allow pipes in quoted regex patterns
    if echo "$REPLAY_CMD" | grep -Eq '(\&\&|\|\||\$\()'; then
        log "ERROR: Manifest REPLAY_CMD contains logical operators or command substitution"
        return 1
    fi
    if [ "$(has_unquoted_pipe "$REPLAY_CMD")" = "YES" ]; then
        log "ERROR: Manifest REPLAY_CMD contains unquoted pipe"
        return 1
    fi

    # Debug info to help diagnose quoting issues
    rlen=$(printf '%s' "$REPLAY_CMD" | wc -c | tr -d ' ')
    rend=$(printf '%s' "$REPLAY_CMD" | sed -n 's/.*\(.\)$/\1/p')
    log "Manifest loaded for $ACCOUNT; REPLAY_CMD length=${rlen}; ends_with='${rend}'"

    return 0
}

# Calculate next backoff timestamp
calculate_backoff() {
    account="$1"

    # Get current backoff index (sanitize)
    backoff_idx=0
    backoff_file=$(find_state_file "$account" "backoff_idx")
    if [ -n "$backoff_file" ] && [ -f "$backoff_file" ]; then
        bi_raw=$(cat "$backoff_file")
        backoff_idx=$(get_int_or_default "$bi_raw" 0)
    fi

    # Get the appropriate backoff delay
    idx=0
    delay=60  # Default 1 minute
    for seconds in $BACKOFF_SECONDS; do
        if [ "$idx" -eq "$backoff_idx" ]; then
            delay=$seconds
            break
        fi
        idx=$((idx + 1))
    done

    # Calculate next allowed timestamp
    now=$(date +%s)
    next_ts=$((now + delay))

    # Update backoff index (cap at last value)
    max_idx=$(echo "$BACKOFF_SECONDS" | wc -w)
    max_idx=$((max_idx - 1))
    if [ "$backoff_idx" -lt "$max_idx" ]; then
        backoff_idx=$((backoff_idx + 1))
    fi

    printf "%s\n" "$next_ts" | atomic_overwrite "$(state_file_for_write "$account" "next_allowed_ts")"
    printf "%s\n" "$backoff_idx" | atomic_overwrite "$(state_file_for_write "$account" "backoff_idx")"
}

# Restart a migration
restart_account() {
    account="$1"
    acct_safe=$(sanitize_account "$account")

    # Read manifest
    if ! read_manifest "$account"; then
        log "${YELLOW}No valid manifest for $account - cannot restart${NC}"
        return 1
    fi

    # Increment restart count (sanitize read)
    restart_count=0
    restart_file=$(find_state_file "$account" "restarts")
    if [ -n "$restart_file" ] && [ -f "$restart_file" ]; then
        rc_raw=$(cat "$restart_file")
        restart_count=$(get_int_or_default "$rc_raw" 0)
    fi
    restart_count=$((restart_count + 1))
    printf "%s\n" "$restart_count" | atomic_overwrite "$(state_file_for_write "$account" "restarts")"

    # Calculate backoff
    calculate_backoff "$account"

    # Prepare diagnostics
    cmd_len=$(printf '%s' "$REPLAY_CMD" | wc -c | tr -d ' ')
    last_char=$(printf '%s' "$REPLAY_CMD" | sed -n 's/.*\(.\)$/\1/p')
    sq_count=$(printf '%s' "$REPLAY_CMD" | awk -F"'" '{print NF-1}')
    dq_count=$(printf '%s' "$REPLAY_CMD" | awk -F"\"" '{print NF-1}')

    # Persist last command and manifest snapshot for deep debugging
    printf '%s\n' "$REPLAY_CMD" | atomic_overwrite "$(state_file_for_write "$account" "last_replay_cmd")"
    manifest_path=$(find_state_file "$account" "manifest")
    if [ -n "$manifest_path" ] && [ -f "$manifest_path" ]; then
        # Save a snapshot of the manifest used for this restart
        cat "$manifest_path" | atomic_overwrite "$(state_file_for_write "$account" "last_manifest")"
    fi

    # Log restart attempt details
    audit="$(state_file_for_write "$account" "restart_attempts.log")"
    umask 077
    {
        ts="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "[$ts] account=$account attempt=$restart_count cmd_len=$cmd_len sq=$sq_count dq=$dq_count passfile1=$PASSFILE1 passfile2=$PASSFILE2 log_file=$LOG_FILE"
        echo "REPLAY_CMD=$REPLAY_CMD"
    } >> "$audit"

    # Validate balanced quotes (simple even-count heuristic)
    if [ $((sq_count % 2)) -ne 0 ]; then
        log "ERROR: Unbalanced single quotes in REPLAY_CMD for $account (count=$sq_count, len=$cmd_len, ends_with='${last_char}')"
        printf "%s\n" "quote-error" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
        return 1
    fi
    if [ $((dq_count % 2)) -ne 0 ]; then
        log "ERROR: Unbalanced double quotes in REPLAY_CMD for $account (count=$dq_count, len=$cmd_len, ends_with='${last_char}')"
        printf "%s\n" "quote-error" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
        return 1
    fi

    # Shell parse check (-n = noexec) to catch syntax errors before executing
    if ! sh -n -c "$REPLAY_CMD" 2>> "$STATE_DIR/watchdog.log"; then
        log "ERROR: REPLAY_CMD fails shell parse (-n) for $account; aborting restart. len=$cmd_len, ends_with='${last_char}'"
        printf "%s\n" "parse-error" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
        return 1
    fi

    # Start the migration
    log "${GREEN}Restarting $account (attempt $restart_count/$MAX_RESTARTS)${NC}"

    # Check if this manifest was created in Docker mode; if so, wrap replay in Docker
    # (MANIFEST_USE_DOCKER etc. are set by read_manifest() above)
    if [ "$MANIFEST_USE_DOCKER" = "true" ] && [ -n "$MANIFEST_DOCKER_IMAGE" ]; then
        # Rebuild as Docker invocation: extract imapsync args from REPLAY_CMD
        # The REPLAY_CMD starts with the imapsync binary + args. We need to extract the args
        # and remap host paths to container paths.
        # Escape sed special chars in paths to avoid regex surprises
        esc_cred=$(printf '%s\n' "$MANIFEST_CRED_DIR" | sed 's|[.[\*^$]|\\&|g')
        esc_log=$(printf '%s\n' "${MANIFEST_LOG_DIR:-/nonexistent}" | sed 's|[.[\*^$]|\\&|g')
        esc_tmp=$(printf '%s\n' "${MANIFEST_TMPDIR:-/tmp/imapsync_tmp}" | sed 's|[.[\*^$]|\\&|g')
        docker_replay_args=$(printf '%s\n' "$REPLAY_CMD" | sed "s|$esc_cred|/creds|g; s|$esc_log|/logs|g; s|$esc_tmp|/tmp/imapsync|g; s|[^ ]*imapsync ||")
        docker_mem="${MANIFEST_DOCKER_MEMORY:-8g}"
        log "Executing via Docker ($MANIFEST_DOCKER_IMAGE, mem=$docker_mem) for $account"
        log "Docker args: imapsync $docker_replay_args"

        sh -c "docker run --rm --memory='$docker_mem' \
            -v '$MANIFEST_CRED_DIR:/creds:ro' \
            -v '${MANIFEST_LOG_DIR:-/tmp}:/logs' \
            -v '${MANIFEST_TMPDIR:-/tmp/imapsync_tmp}:/tmp/imapsync' \
            '$MANIFEST_DOCKER_IMAGE' \
            imapsync $docker_replay_args" >> "$STATE_DIR/watchdog.log" 2>&1 &
    else
        log "Executing REPLAY_CMD for $account: $REPLAY_CMD"
        sh -c "$REPLAY_CMD" >> "$STATE_DIR/watchdog.log" 2>&1 &
    fi
    new_pid=$!

    printf "%s\n" "$new_pid" | atomic_overwrite "$(state_file_for_write "$account" "pid")"
    log "Started PID $new_pid for $account"

    # Start a lightweight heartbeat writer for restarted jobs (macOS-friendly)
    # Uses manifest-provided HEARTBEAT_FILE/INTERVAL when present; otherwise falls back
    hb_file="${HEARTBEAT_FILE:-$(heartbeat_file_for_account "$account")}"
    hb_int="${HEARTBEAT_INTERVAL:-5}"
    if [ -n "$hb_file" ]; then
        ensure_heartbeat_dir
        (
            last_mtime=0
            while kill -0 "$new_pid" 2>/dev/null; do
                if [ -n "$LOG_FILE" ]; then
                    mtime=$(stat -f %m "$LOG_FILE" 2>/dev/null || stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
                    if [ -n "$mtime" ] && [ "$mtime" -gt 0 ] && [ "$mtime" -ne "$last_mtime" ]; then
                        printf '%s\n' "$mtime" > "$hb_file" 2>/dev/null || true
                        last_mtime="$mtime"
                    fi
                else
                    date +%s > "$hb_file" 2>/dev/null || true
                fi
                sleep "$hb_int"
            done
        ) >> "$STATE_DIR/watchdog.log" 2>&1 &
        echo "$!" > "$(state_file_for_write "$account" "hbwriter_pid")"
        log "Heartbeat sidecar started for $account (pid $!, every ${hb_int}s) -> $hb_file"
    fi
}

# Handle memory limit exceeded
handle_memory_limit() {
    pid="$1"
    account="$2"
    rss_mb="$3"

    if [ "$RESTART_MODE" = "auto" ] && can_restart "$account"; then
        log "${YELLOW}Memory limit exceeded for $account (${rss_mb}MB > ${MEMORY_LIMIT_MB}MB) - recycling${NC}"

        # Gentle termination
        kill -TERM "$pid" 2>/dev/null || true
        sleep "$MEMORY_COOLDOWN"

        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi

        # Mark as OOM restart
        printf "%s\n" "oom" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"

        # Attempt restart
        restart_account "$account"
    else
        log "${YELLOW}WARNING: $account using ${rss_mb}MB (limit: ${MEMORY_LIMIT_MB}MB)${NC}"
    fi
}

# Return heartbeat timestamp (epoch) or 0 if missing/invalid
heartbeat_ts() {
    acct="$1"
    hb=$(heartbeat_file_for_account "$acct")
    if [ -f "$hb" ]; then
        ts=$(cat "$hb" 2>/dev/null)
        case "$ts" in
            ''|*[!0-9]*) echo 0 ;;
            *) echo "$ts" ;;
        esac
    else
        echo 0
    fi
}

write_death_snapshot() {
    account="$1"; old_pid="$2"; logfile="$3"; exit_code="$4"; status="$5"
    acct_safe=$(sanitize_account "$account")
    # Determine heartbeat age/timestamp at death
    hbts=$(heartbeat_ts "$account")
    now=$(date +%s)
    if [ "$hbts" -gt 0 ]; then
        hbage=$((now - hbts))
    else
        hbage=-1
    fi
    # Tail file
    tail_file="$STATE_DIR/${acct_safe}.death_tail"
    if [ -f "$logfile" ]; then
        tail -n "$WDOG_DEATH_TAIL_LINES" "$logfile" > "$tail_file" 2>/dev/null || true
    else
        : > "$tail_file"
    fi
    # Write summary
    summary="$STATE_DIR/${acct_safe}.death_summary"
    {
        echo "time=$(date '+%Y-%m-%d %H:%M:%S')";
        echo "old_pid=$old_pid";
        echo "exit_code=${exit_code:-unknown}";
        echo "status=${status:-unknown}";
        echo "log_file=${logfile:-unknown}";
        echo "tail_file=$tail_file";
        echo "hb_age=$hbage";
        echo "hb_ts=$hbts";
    } > "$summary"
    # JSON event with extra fields
    log_json "death_snapshot" "$account" \
        "exit_code=${exit_code:-unknown}" "status=${status:-unknown}" \
        "heartbeat_age=${hbage}" "heartbeat_ts=${hbts}" \
        "log_file=${logfile:-unknown}" "tail_file=${tail_file}"
}

# Show usage
usage() {
    cat <<EOF
Usage: $0 [-r] [-i SECS] [-m MB] [-s DIR] [-l "DIRS"] [-h]

Secure Migration Watchdog - Monitor and optionally restart imapsync processes

Options:
  -r          Enable auto-restart mode (default: monitor only)
  -i SECS     Check interval in seconds (default: $CHECK_INTERVAL)
  -m MB       Memory limit in MB (default: $MEMORY_LIMIT_MB)
  -s DIR      State directory (default: $STATE_DIR)
  -l "DIRS"   Space-separated log directories (default: "$LOG_DIRS")
  -h          Show this help message

Environment variables:
  RESTART_MODE      monitor|auto (default: monitor)
  MAX_RESTARTS      Maximum restart attempts (default: 3)
  RETRY_EXIT_CODES  Space-separated retryable exit codes
  MEMORY_COOLDOWN   Seconds to wait after TERM before KILL

Per-account control:
  Create $STATE_DIR/<account>.policy with "auto" to allow restarts
  Touch $STATE_DIR/<account>.stop to block all restarts

EOF
    exit 0
}

# Parse command line options
while getopts "ri:m:s:l:h" opt; do
    case "$opt" in
        r)
            RESTART_MODE="auto"
            ;;
        i)
            CHECK_INTERVAL="$OPTARG"
            ;;
        m)
            MEMORY_LIMIT_MB="$OPTARG"
            ;;
        s)
            STATE_DIR="$OPTARG"
            ;;
        l)
            LOG_DIRS="$OPTARG"
            ;;
        h)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

# Initialize
ensure_state_dir
ensure_heartbeat_dir
sanitize_config_numbers
acquire_global_lock

# Startup banner
echo "${CYAN}════════════════════════════════════════════════════════${NC}"
echo "${BOLD}${CYAN}SECURE MIGRATION WATCHDOG STARTING${NC}"
echo "${CYAN}════════════════════════════════════════════════════════${NC}"
echo ""
log "${BOLD}Secure Migration Watchdog Started${NC}"
log "Mode: $RESTART_MODE | Check interval: ${CHECK_INTERVAL}s | Memory limit: ${MEMORY_LIMIT_MB}MB"
log "State directory: $STATE_DIR"

    # Track known accounts to detect stopped processes
    KNOWN_ACCOUNTS=""

    # Main monitoring loop
    while true; do
    # Discover all running imapsync processes
    processes=$(discover_imapsync_processes)

    # Track currently running accounts
    RUNNING_ACCOUNTS=""
    acct_tmp="$STATE_DIR/.acct_pids.tmp"
    : > "$acct_tmp"; chmod 600 "$acct_tmp" 2>/dev/null || true

    # Process each discovered migration without using a subshell (no pipes)
    if [ -n "$processes" ]; then
        while IFS='|' read -r pid cmd; do
            if [ -z "$pid" ] || [ -z "$cmd" ]; then
                continue
            fi

            # Extract account and log file
            account=$(get_account_from_cmd "$cmd")
            if [ -z "$account" ]; then
                continue
            fi

            acct_safe=$(sanitize_account "$account")
            RUNNING_ACCOUNTS="$RUNNING_ACCOUNTS $account"

            # Update PID file atomically
            printf "%s\n" "$pid" | atomic_overwrite "$(state_file_for_write "$account" "pid")"

            # Track this account
            if case " $KNOWN_ACCOUNTS " in *" $account "*) false ;; *) true ;; esac; then
                KNOWN_ACCOUNTS="$KNOWN_ACCOUNTS $account"
                log "${GREEN}Discovered migration: $account (PID $pid)${NC}"
                log_json "sync_discovered" "$account" "pid=$pid"
            fi

            # Check heartbeat status
            hb_age=$(heartbeat_age "$account")
            if [ "$hb_age" -ge 0 ]; then
                    if is_stalled "$account"; then
                        log "${YELLOW}Warning: $account heartbeat is stale (age: ${hb_age}s, TTL: ${HEARTBEAT_TTL}s)${NC}"
                        log_json "stall_detected" "$account" "pid=$pid" "heartbeat_age=$hb_age"

                        # If auto mode and can restart, handle stall
                        if [ "$RESTART_MODE" = "auto" ] && can_restart "$account"; then
                            log "${YELLOW}Restarting stalled migration: $account${NC}"
                            # Kill the stalled process gently
                            kill -TERM "$pid" 2>/dev/null || true
                            sleep 5
                            if kill -0 "$pid" 2>/dev/null; then
                                kill -KILL "$pid" 2>/dev/null || true
                            fi
                            # Mark as stalled restart
                            printf "%s\n" "stall" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
                            log_json "restart_triggered" "$account" "reason=stall" "pid=$pid"
                            restart_account "$account"
                        fi
                    fi
                fi

            # Check memory usage with integer validation
            rss_mb=$(get_rss_mb "$pid")
            rss_mb=$(get_int_or_default "$rss_mb" 0)
            limit_mb=$(get_int_or_default "$MEMORY_LIMIT_MB" 40960)
            if [ "$rss_mb" -gt "$limit_mb" ]; then
                handle_memory_limit "$pid" "$account" "$rss_mb"
            fi

            # Record for duplicate detection (account|pid|uptime)
            up=$(get_pid_uptime_secs "$pid")
            echo "$account|$pid|$up" >> "$acct_tmp"

            # Find log file
            logfile=$(get_log_from_cmd "$cmd")
            if [ -z "$logfile" ]; then
                logfile=$(fallback_get_log_from_dirs "$account")
            fi

            # Check for stalls
            if [ -n "$logfile" ] && [ -f "$logfile" ]; then
                # Check if log is stale
                log_age=$(file_age_minutes "$logfile")
                if [ "$log_age" -ge 0 ] && [ "$log_age" -ge "$STALL_MINUTES" ]; then
                    log "${YELLOW}Warning: $account appears stalled (no updates for ${STALL_MINUTES}+ minutes)${NC}"
                fi
            fi
        done <<EOF
$processes
EOF
    fi

    # Add accounts from manifests so very short runs are not missed
    add_manifest_accounts

    # Deduplicate if multiple PIDs for the same account
    if [ -s "$acct_tmp" ]; then
        dups_found=0
        for acct in $(cut -d'|' -f1 "$acct_tmp" | sort | uniq); do
            count=$(awk -F'|' -v a="$acct" '$1==a{c++} END{print c+0}' "$acct_tmp")
            if [ "$count" -gt 1 ]; then
                dups_found=1
                # Build list pid uptime
                plist=$(awk -F'|' -v a="$acct" '$1==a{print $2" "$3}' "$acct_tmp")
                winner=$(printf "%s\n" "$plist" | pick_winner_pid "$DEDUPE_POLICY")
                # If log-only, just report
                if [ "$DEDUPE_ENFORCE" = "true" ] && [ "$DEDUPE_POLICY" != "log-only" ]; then
                    for p in $(printf "%s\n" "$plist" | awk '{print $1}'); do
                        if [ "$p" != "$winner" ]; then
                            log "${YELLOW}Duplicate migration for $acct detected; keeping PID $winner, stopping duplicate PID $p${NC}"
                            kill -TERM "$p" 2>/dev/null || true
                            sleep 2
                            kill -KILL "$p" 2>/dev/null || true
                            log_json "duplicate_stopped" "$acct" "kept_pid=$winner" "killed_pid=$p"
                        fi
                    done
                else
                    log "${YELLOW}Duplicate migration for $acct detected; policy=$DEDUPE_POLICY (no kill)${NC}"
                    log_json "duplicate_detected" "$acct" "policy=$DEDUPE_POLICY" "pids=$(printf "%s\n" "$plist" | awk '{printf $1","}' | sed 's/,$//')"
                fi
            fi
        done
        [ "$dups_found" -eq 1 ] && log "${YELLOW}Duplicate scan completed${NC}"
    fi

    # Check for stopped processes
    for account in $KNOWN_ACCOUNTS; do
        # Skip if currently running
        if case " $RUNNING_ACCOUNTS " in *" $account "*) true ;; *) false ;; esac; then
            continue
        fi

        # Check if we have a PID file for this account
        pid_file=$(find_state_file "$account" "pid")
        if [ -n "$pid_file" ] && [ -f "$pid_file" ]; then
            old_pid=$(sed -n '1p' "$pid_file")

            # Verify process is really dead
            if ! kill -0 "$old_pid" 2>/dev/null; then
                # Process died - analyze why
                logfile=$(fallback_get_log_from_dirs "$account")
                exit_code=$(parse_exit_code "$logfile")
                status=$(classify_status "$exit_code" "$logfile")

                log "${RED}Process died: $account (exit code: ${exit_code:-unknown}, status: $status)${NC}"
                write_death_snapshot "$account" "$old_pid" "$logfile" "$exit_code" "$status"
                log_json "sync_lost" "$account" "exit_code=${exit_code:-unknown}" "status=$status"

                # Handle based on status
                case "$status" in
                    complete)
                        log "${GREEN}✓ $account completed successfully${NC}"
                        log_json "sync_completed" "$account" "exit_code=${exit_code:-0}"
                        remove_state_file "$account" "restarts"
                        remove_state_file "$account" "backoff_idx"
                        remove_state_file "$account" "next_allowed_ts"
                        remove_state_file "$account" "pid"
                        ;;
                    user-stop)
                        if can_restart "$account"; then
                            log_json "restart_triggered" "$account" "reason=user-stop" "exit_code=${exit_code:-unknown}"
                            restart_account "$account"
                        else
                            log "🛑 $account stopped by user/system"
                            log_json "user_stop" "$account" "exit_code=${exit_code:-137}"
                            remove_state_file "$account" "pid"
                        fi
                        ;;
                    rate-limited)
                        # Gmail quota exceeded: force 30-minute backoff, defer restart to next cycle
                        log "${YELLOW}Rate-limited: $account hit Gmail quota (exit 162). Deferring restart 30 min.${NC}"
                        log_json "rate_limited" "$account" "exit_code=${exit_code:-162}"
                        now_rl=$(date +%s)
                        printf "%s\n" "$((now_rl + 1800))" | atomic_overwrite "$(state_file_for_write "$account" "next_allowed_ts")"
                        # Remove pid and last_exit so next watchdog cycle re-evaluates
                        # after the backoff expires (can_restart will pass once now > next_allowed_ts)
                        remove_state_file "$account" "pid"
                        remove_state_file "$account" "last_exit"
                        log_json "restart_deferred" "$account" "reason=rate-limited" "backoff_sec=1800"
                        ;;
                    retryable)
                        if can_restart "$account"; then
                            log_json "restart_triggered" "$account" "reason=retryable" "exit_code=${exit_code:-unknown}"
                            restart_account "$account"
                        else
                            reason=$(restart_block_reason "$account")
                            log "Retryable failure for $account but restart not permitted (reason: ${reason:-unknown})"
                            [ -z "$reason" ] || log "  Hint: reason=$reason"
                            log_json "restart_denied" "$account" "reason=${reason:-unknown}" "exit_code=${exit_code:-unknown}"
                            remove_state_file "$account" "pid"
                        fi
                        ;;
                    *)
                        log "${RED}✗ $account failed (manual review required)${NC}"
                        log_json "sync_failed" "$account" "exit_code=${exit_code:-unknown}" "status=$status"
                        if [ -n "$logfile" ]; then
                            log "  Log: $logfile"
                        fi
                        remove_state_file "$account" "pid"
                        ;;
                esac

                # Save status for reference (atomic writes)
                printf "%s\n" "$status" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
                if [ -n "$exit_code" ]; then
                    printf "%s\n" "$exit_code" | atomic_overwrite "$(state_file_for_write "$account" "last_exit")"
                fi
            fi
        else
            # No PID file: check manifest + log for short-lived runs
            last_exit_file=$(find_state_file "$account" "last_exit")
            if [ -z "$last_exit_file" ] || [ ! -f "$last_exit_file" ]; then
                manifest_file=$(find_state_file "$account" "manifest")
                if [ -n "$manifest_file" ] && [ -f "$manifest_file" ]; then
                    logfile=$(grep -E '^LOG_FILE=' "$manifest_file" | head -1 | sed 's/^[^=]*=//; s/^"//; s/"$//')
                    if [ -z "$logfile" ]; then
                        logfile=$(fallback_get_log_from_dirs "$account")
                    fi
                    exit_code=$(parse_exit_code "$logfile")
                    if [ -n "$exit_code" ]; then
                        status=$(classify_status "$exit_code" "$logfile")
                        log "${RED}Process ended quickly: $account (exit code: ${exit_code:-unknown}, status: $status)${NC}"
                        write_death_snapshot "$account" "unknown" "$logfile" "$exit_code" "$status"
                        log_json "sync_lost" "$account" "exit_code=${exit_code:-unknown}" "status=$status"

                        case "$status" in
                            complete)
                                log "${GREEN}✓ $account completed successfully${NC}"
                                log_json "sync_completed" "$account" "exit_code=${exit_code:-0}"
                                remove_state_file "$account" "restarts"
                                remove_state_file "$account" "backoff_idx"
                                remove_state_file "$account" "next_allowed_ts"
                                ;;
                            user-stop)
                                if can_restart "$account"; then
                                    log_json "restart_triggered" "$account" "reason=user-stop" "exit_code=${exit_code:-unknown}"
                                    restart_account "$account"
                                else
                                    log "🛑 $account stopped by user/system"
                                    log_json "user_stop" "$account" "exit_code=${exit_code:-137}"
                                fi
                                ;;
                            rate-limited)
                                log "${YELLOW}Rate-limited: $account hit Gmail quota (exit 162). Deferring restart 30 min.${NC}"
                                log_json "rate_limited" "$account" "exit_code=${exit_code:-162}"
                                now_rl2=$(date +%s)
                                printf "%s\n" "$((now_rl2 + 1800))" | atomic_overwrite "$(state_file_for_write "$account" "next_allowed_ts")"
                                # Clear last_exit so next cycle re-evaluates after backoff
                                remove_state_file "$account" "last_exit"
                                log_json "restart_deferred" "$account" "reason=rate-limited" "backoff_sec=1800"
                                ;;
                            retryable)
                                if can_restart "$account"; then
                                    log_json "restart_triggered" "$account" "reason=retryable" "exit_code=${exit_code:-unknown}"
                                    restart_account "$account"
                                else
                                    reason=$(restart_block_reason "$account")
                                    log "Retryable failure for $account but restart not permitted (reason: ${reason:-unknown})"
                                    [ -z "$reason" ] || log "  Hint: reason=$reason"
                                    log_json "restart_denied" "$account" "reason=${reason:-unknown}" "exit_code=${exit_code:-unknown}"
                                fi
                                ;;
                            *)
                                log "${RED}✗ $account failed (manual review required)${NC}"
                                log_json "sync_failed" "$account" "exit_code=${exit_code:-unknown}" "status=$status"
                                if [ -n "$logfile" ]; then
                                    log "  Log: $logfile"
                                fi
                                ;;
                        esac

                        printf "%s\n" "$status" | atomic_overwrite "$(state_file_for_write "$account" "last_reason")"
                        printf "%s\n" "$exit_code" | atomic_overwrite "$(state_file_for_write "$account" "last_exit")"
                    fi
                fi
            fi
        fi
    done

    # Periodic cleanup of known accounts to avoid memory growth
    prune_known_accounts

    # Status summary
    active_count=0
    if [ -n "$processes" ]; then
        active_count=$(echo "$processes" | grep '^[0-9]' | wc -l | tr -d ' ')
    fi

    echo ""
    echo "${CYAN}[$(date '+%H:%M:%S')] Status Check${NC}"
    echo "${CYAN}─────────────────────────────────────────────────────────${NC}"

    if [ "$active_count" -gt 0 ]; then
        echo "Active migrations: $active_count"
        while IFS='|' read -r pid cmd; do
            if [ -n "$pid" ] && [ -n "$cmd" ]; then
                account=$(get_account_from_cmd "$cmd")
                rss_mb=$(get_rss_mb "$pid")
                echo "  ${GREEN}✓${NC} $account (PID $pid, ${rss_mb}MB)"
            fi
        done <<EOF
$processes
EOF
    else
        echo "No active migrations"
    fi

    if [ "$RESTART_MODE" = "auto" ]; then
        echo ""
        echo "Auto-restart: ENABLED"
    else
        echo ""
        echo "Mode: MONITOR ONLY (use -r to enable auto-restart)"
    fi

    sleep "$CHECK_INTERVAL"
done
