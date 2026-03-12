#!/usr/bin/env sh

# Universal Migration Monitor - Comprehensive Dashboard
# Real-time monitoring of all imapsync migrations with detailed status

# Configuration defaults
REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"
STATE_DIR="${STATE_DIR:-/var/tmp/migration_watchdog}"
HEARTBEAT_DIR="${HEARTBEAT_DIR:-$STATE_DIR/heartbeats}"
HEARTBEAT_TTL="${HEARTBEAT_TTL:-300}"
LOG_DIRS="${LOG_DIRS:-migrate/logs LOG_imapsync/migrate/logs LOG_imapsync/LOG_imapsync/logs}"
PREFER_DST_USER="${PREFER_DST_USER:-true}"
MAX_LINES_LOG_SCAN="${MAX_LINES_LOG_SCAN:-200}"
MEM_TREND_DELTA_MB="${MEM_TREND_DELTA_MB:-32}"
CACHE_DIR="${CACHE_DIR:-$STATE_DIR/.monitor_cache}"
MAX_RESTARTS_DISPLAY="${MAX_RESTARTS_DISPLAY:-6}"

# Colors for output
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
    BOLD='\033[1m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BLUE=''; MAGENTA=''; NC=''; BOLD=''
fi

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/scripts/posix_helpers.sh" ]; then
    . "$SCRIPT_DIR/scripts/posix_helpers.sh"
else
    # Fallback definitions if helpers not found
    sanitize_account() { echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'; }
    ensure_secure_dir() { [ -d "$1" ] || { mkdir -p "$1" && chmod 700 "$1"; }; }
    epoch_now() { date '+%s'; }
fi

# Ensure cache directory exists
ensure_secure_dir "$CACHE_DIR"

# Format bytes for display
fmt_bytes() {
    bytes="$1"
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0B"
    elif [ "$bytes" -lt 1024 ]; then
        echo "${bytes}B"
    elif [ "$bytes" -lt 1048576 ]; then
        kb=$((bytes / 1024))
        echo "${kb}KB"
    elif [ "$bytes" -lt 1073741824 ]; then
        mb=$((bytes / 1024 / 1024))
        echo "${mb}MB"
    else
        gb=$((bytes / 1024 / 1024 / 1024))
        echo "${gb}GB"
    fi
}

# Convert a text like "206.160 MiB" or "165.869 KiB" to integer MiB (rounded)
mib_from_text() {
    text="$1"
    echo "$text" | awk '
        function round(x){return int(x+0.5)}
        {
            num=$1; unit=$2
            if (num=="" || unit=="") {print 0; next}
            if (unit=="KiB" || unit=="KB") print round(num/1024)
            else if (unit=="MiB" || unit=="MB") print round(num)
            else if (unit=="GiB" || unit=="GB") print round(num*1024)
            else print 0
        }'
}

# Format seconds to human readable
fmt_secs() {
    secs="$1"
    if [ -z "$secs" ] || [ "$secs" -lt 0 ]; then
        echo "unknown"
        return
    fi

    if [ "$secs" -lt 60 ]; then
        echo "${secs}s"
    elif [ "$secs" -lt 3600 ]; then
        m=$((secs / 60))
        s=$((secs % 60))
        echo "${m}m ${s}s"
    else
        h=$((secs / 3600))
        m=$(((secs % 3600) / 60))
        echo "${h}h ${m}m"
    fi
}

# Format timestamp
fmt_ts() {
    epoch="$1"
    if [ -z "$epoch" ]; then
        echo "unknown"
    else
        date -r "$epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S'
    fi
}

# Calculate time ago
time_ago() {
    past="$1"
    now=$(epoch_now)
    if [ -z "$past" ] || [ "$past" -eq 0 ]; then
        echo "unknown"
    else
        diff=$((now - past))
        fmt_secs "$diff"
    fi
}

# Memory trend arrow
arrow_for_trend() {
    delta="$1"
    if [ "$delta" -gt "$MEM_TREND_DELTA_MB" ]; then
        echo "↑"
    elif [ "$delta" -lt "-$MEM_TREND_DELTA_MB" ]; then
        echo "↓"
    else
        echo "→"
    fi
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

# Get process uptime in seconds
get_pid_uptime_secs() {
    pid="$1"
    # Try etimes (Linux)
    etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -n "$etimes" ] && echo "$etimes" | grep -Eq '^[0-9]+$'; then
        echo "$etimes"
        return
    fi

    # Try etime and parse (macOS)
    etime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
    if [ -z "$etime" ]; then
        echo "0"
        return
    fi

    # Parse [[dd-]hh:]mm:ss format
    d=0; h=0; m=0; s=0
    case "$etime" in
        *-*:*:*) # dd-hh:mm:ss
            d=${etime%%-*}
            rest=${etime#*-}
            h=${rest%%:*}
            rest=${rest#*:}
            m=${rest%%:*}
            s=${rest#*:}
            ;;
        *:*:*) # hh:mm:ss
            h=${etime%%:*}
            rest=${etime#*:}
            m=${rest%%:*}
            s=${rest#*:}
            ;;
        *:*) # mm:ss
            m=${etime%%:*}
            s=${etime#*:}
            ;;
        *) # ss
            s="$etime"
            ;;
    esac
    # Force base-10 to avoid octal errors on macOS when values like 08 appear
    d=$((10#$d)); h=$((10#$h)); m=$((10#$m)); s=$((10#$s))
    total=$((d*86400 + h*3600 + m*60 + s))
    if echo "$total" | grep -Eq '^[0-9]+$'; then
        echo "$total"
    else
        echo "0"
    fi
}

# Check if PID is alive
is_pid_alive() {
    pid="$1"
    kill -0 "$pid" 2>/dev/null
}

# Read heartbeat age
heartbeat_age() {
    account="$1"
    acct_safe=$(sanitize_account "$account")
    hb_file="$HEARTBEAT_DIR/${acct_safe}.hb"

    if [ -f "$hb_file" ]; then
        now=$(epoch_now)
        ts=$(cat "$hb_file" 2>/dev/null)
        case "$ts" in
            ''|*[!0-9]*) echo "-1" ;;
            *) echo $((now - ts)) ;;
        esac
    else
        echo "-1"
    fi
}

# Get heartbeat status string
heartbeat_status() {
    age="$1"
    if [ "$age" -lt 0 ]; then
        echo "${YELLOW}MISSING${NC}"
    elif [ "$age" -lt "$HEARTBEAT_TTL" ]; then
        echo "${GREEN}ALIVE (${age}s)${NC}"
    else
        echo "${RED}STALE (${age}s)${NC}"
    fi
}

# --- State file helpers (supports both _at_ and legacy '_' formats) ---
safe_name_primary() { sanitize_account "$1"; }
safe_name_legacy()  { echo "$1" | tr '@' '_' | tr -cd '[:alnum:]_.-'; }

find_state_file() {
    account="$1"; suffix="$2"
    s1=$(safe_name_primary "$account")
    s2=$(safe_name_legacy  "$account")
    if [ -f "$STATE_DIR/${s1}.${suffix}" ]; then
        echo "$STATE_DIR/${s1}.${suffix}"
    elif [ -f "$STATE_DIR/${s2}.${suffix}" ]; then
        echo "$STATE_DIR/${s2}.${suffix}"
    else
        echo ""
    fi
}

# Read watchdog state files (policy/restarts/exit/reason)
read_policy()    { f=$(find_state_file "$1" "policy");    [ -n "$f" ] && cat "$f" || echo "monitor"; }
read_restarts()  { f=$(find_state_file "$1" "restarts");  [ -n "$f" ] && cat "$f" || echo "0"; }
read_last_exit() { f=$(find_state_file "$1" "last_exit"); [ -n "$f" ] && cat "$f" || echo ""; }
read_last_reason(){ f=$(find_state_file "$1" "last_reason");[ -n "$f" ] && cat "$f" || echo ""; }

read_backoff_status() {
    account="$1"
    backoff_file=$(find_state_file "$account" "next_allowed_ts")
    if [ -n "$backoff_file" ] && [ -f "$backoff_file" ]; then
        next_ts=$(cat "$backoff_file")
        now=$(epoch_now)
        if [ "$next_ts" -gt "$now" ]; then
            remaining=$((next_ts - now))
            echo "in $(fmt_secs $remaining)"
        else
            echo "allowed"
        fi
    else
        echo "allowed"
    fi
}

# Get log file for account
get_log_file() {
    account="$1"
    acct_safe=$(sanitize_account "$account")

    # Try manifest first
    if [ -f "$STATE_DIR/${acct_safe}.manifest" ]; then
        log=$(grep "^LOG_FILE=" "$STATE_DIR/${acct_safe}.manifest" | cut -d= -f2- | tr -d '"')
        if [ -n "$log" ] && [ -f "$log" ]; then
            echo "$log"
            return
        fi
    fi

    # Try latest symlink
    sanitized=$(sanitize_account "$account")
    for dir in $LOG_DIRS; do
        if [ -d "$dir" ]; then
            if [ -L "$dir/${sanitized}_latest.log" ]; then
                target=$(readlink "$dir/${sanitized}_latest.log" 2>/dev/null)
                if [ -f "$target" ]; then
                    echo "$target"
                    return
                fi
            fi
            # Try most recent log
            latest=$(ls -t "$dir" 2>/dev/null | grep "^${sanitized}_" | grep "\.log$" | head -1)
            if [ -n "$latest" ]; then
                echo "$dir/$latest"
                return
            fi
        fi
    done
}

# Parse log file for metrics
parse_log() {
    log="$1"
    if [ ! -f "$log" ]; then
        return
    fi

    tail -n "$MAX_LINES_LOG_SCAN" "$log" 2>/dev/null | awk '
        BEGIN {
            msgs_found=""; msgs_copied=""; msgs_skipped="";
            bytes_text=""; current_folder=""; last_error=""; exit_code="";
        }

        # Messages found/copied/skipped: take the last numeric token
        /^Messages found:/   { for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) { msgs_found=$i; break } }
        /^Messages copied:/  { for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) { msgs_copied=$i; break } }
        /^Messages skipped:/ { for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) { msgs_skipped=$i; break } }

        # Total bytes transferred: capture everything after the colon
        /^Total bytes transferred:/ {
            p = index($0, ":"); if (p > 0) bytes_text = substr($0, p+1)
        }

        # Extract folder name between '[' and ']' using index/substr for portability
        /^From folder[[:space:]]*\[/ {
            s = index($0, "["); if (s > 0) { rest = substr($0, s+1); e = index(rest, "]"); if (e > 0) current_folder = substr(rest, 1, e-1) }
        }

        # Live progress line: "KiB/s|MiB/s ... XX MiB copied" (cumulative)
        /[0-9.]+[[:space:]]+(KiB|MiB|GiB)[[:space:]]+copied$/ {
            # get last two fields (number and unit)
            n=$(NF-1); u=$NF; 
            if (u=="copied") { n=$(NF-2); u=$(NF-1) }
            bytes_text = n " " u
        }

        # Exit code: take the last pure number token on the line
        /Exiting with return value/ {
            for (i=NF;i>=1;i--) if ($i ~ /^[0-9]+$/) { exit_code=$i; break }
        }

        # Common error patterns
        /(ERROR|ERR:|NO \[|BYE|timeout|closed connection|Connection reset|refused|Network is unreachable)/ {
            last_error = substr($0, 1, 80)
        }

        END {
            if (msgs_found != "") print "msgs_found=" msgs_found
            if (msgs_copied != "") print "msgs_copied=" msgs_copied
            if (msgs_skipped != "") print "msgs_skipped=" msgs_skipped
            if (bytes_text != "") print "bytes_text=\"" bytes_text "\""
            if (current_folder != "") print "current_folder=\"" current_folder "\""
            if (exit_code != "") print "exit_code=" exit_code
            if (last_error != "") print "last_error=\"" last_error "\""
        }
    '
}

# Classify exit code
classify_exit() {
    code="$1"
    case "$code" in
        0) echo "SUCCESS" ;;
        6) echo "KILLED" ;;
        11) echo "PARTIAL" ;;
        137|143) echo "KILLED" ;;
        74|75|111) echo "RETRYABLE" ;;
        "") echo "RUNNING" ;;
        *) echo "FAILED" ;;
    esac
}

# Save cache for account
save_cache() {
    account="$1"
    shift
    acct_safe=$(sanitize_account "$account")
    cache_file="$CACHE_DIR/${acct_safe}.cache"

    {
        for kv in "$@"; do
            echo "$kv"
        done
    } > "$cache_file.tmp"
    mv -f "$cache_file.tmp" "$cache_file"
}

# Load cache for account
load_cache() {
    account="$1"
    key="$2"
    acct_safe=$(sanitize_account "$account")
    cache_file="$CACHE_DIR/${acct_safe}.cache"

    if [ -f "$cache_file" ]; then
        grep "^${key}=" "$cache_file" 2>/dev/null | cut -d= -f2-
    fi
}

# Collect all accounts
collect_accounts() {
    accounts=""

    # From PID files
    for f in "$STATE_DIR"/*.pid; do
        if [ -f "$f" ]; then
            base=$(basename "$f" .pid)
            # Prefer manifest to recover exact email
            if [ -f "$STATE_DIR/${base}.manifest" ]; then
                acct=$(grep "^ACCOUNT=" "$STATE_DIR/${base}.manifest" 2>/dev/null | cut -d= -f2- | tr -d '"')
                [ -n "$acct" ] && accounts="$accounts $acct" && continue
            fi
            # Fallback: only revert the explicit _at_ marker
            account=$(echo "$base" | sed 's/_at_/@/g')
            accounts="$accounts $account"
        fi
    done

    # From manifest files
    for f in "$STATE_DIR"/*.manifest; do
        if [ -f "$f" ]; then
            acct=$(grep "^ACCOUNT=" "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')
            if [ -n "$acct" ]; then
                accounts="$accounts $acct"
            fi
        fi
    done

    # From last_exit files
    for f in "$STATE_DIR"/*.last_exit; do
        if [ -f "$f" ]; then
            base=$(basename "$f" .last_exit)
            account=$(echo "$base" | tr '_' '@')
            accounts="$accounts $account"
        fi
    done

    # Unique and sort
    echo "$accounts" | tr ' ' '\n' | sort -u | grep -v '^$'
}

# Display account card
display_account() {
    idx="$1"
    account="$2"
    acct_safe=$(sanitize_account "$account")

    # Check if running (support both pid filename formats)
    pid=""
    pid_file=$(find_state_file "$account" "pid")
    if [ -n "$pid_file" ]; then
        pid=$(sed -n '1p' "$pid_file" 2>/dev/null)
        if ! is_pid_alive "$pid"; then
            pid=""
        fi
    fi

    # Determine status
    if [ -n "$pid" ]; then
        status="RUNNING"
        uptime=$(get_pid_uptime_secs "$pid")
        case "$uptime" in
            ''|*[!0-9]*) uptime=0 ;;
        esac
        rss_mb=$(get_rss_mb "$pid")

        # Check for death since last check
        last_pid=$(load_cache "$account" "last_pid")
        if [ -n "$last_pid" ] && [ "$last_pid" != "$pid" ]; then
            printf '%b\n' "${GREEN}[RESTARTED]${NC} Process $last_pid → $pid"
        fi

        # Save current PID and start time
        save_cache "$account" \
            "last_pid=$pid" \
            "pid_start_ts=$(( $(epoch_now) - uptime ))" \
            "last_rss_mb=$rss_mb"

        # Header for running process
        printf '%b\n' "${BOLD}[$idx] $account (PID $pid) ${GREEN}[RUNNING $(fmt_secs $uptime)]${NC}"

    else
        status="STOPPED"
        # Check if recently died
        last_pid=$(load_cache "$account" "last_pid")
        if [ -n "$last_pid" ]; then
            # Process died since last check
            pid_start_ts=$(load_cache "$account" "pid_start_ts")
            if [ -n "$pid_start_ts" ]; then
                now=$(epoch_now)
                runtime=$((now - pid_start_ts))
                death_msg="${RED}[DIED $(time_ago $now) ago]${NC} ❌"
            else
                death_msg="${RED}[DIED]${NC} ❌"
            fi
            # Clear last_pid from cache
            save_cache "$account" "last_pid="
        else
            death_msg="${YELLOW}[STOPPED]${NC}"
        fi

        # Header for stopped process
        printf '%b\n' "${BOLD}[$idx] $account $death_msg"
    fi

    # Get state information
    policy=$(read_policy "$account")
    restarts=$(read_restarts "$account")
    last_exit=$(read_last_exit "$account")
    last_reason=$(read_last_reason "$account")
    backoff=$(read_backoff_status "$account")
    hb_age=$(heartbeat_age "$account")
    hb_stat=$(heartbeat_status "$hb_age")

    # Status line
    if [ "$status" = "RUNNING" ]; then
        # Memory trend
        last_rss=$(load_cache "$account" "last_rss_mb")
        if [ -n "$last_rss" ] && [ "$last_rss" != "$rss_mb" ]; then
            mem_delta=$((rss_mb - last_rss))
            mem_arrow=$(arrow_for_trend "$mem_delta")
        else
            mem_arrow="→"
        fi

        printf '%b\n' "    Status: ${GREEN}Transferring${NC} | Heartbeat: $hb_stat | Memory: ${rss_mb}MB $mem_arrow"
    else
        exit_class=$(classify_exit "$last_exit")
        printf '%b\n' "    Exit: ${last_exit:-unknown} (${exit_class}) | Reason: ${last_reason:-unknown}"
    fi

    # Get log information
    log_file=$(get_log_file "$account")
    if [ -n "$log_file" ] && [ -f "$log_file" ]; then
        # Check if log changed
        log_mtime=$(stat -f %m "$log_file" 2>/dev/null || stat -c %Y "$log_file" 2>/dev/null)
        cached_mtime=$(load_cache "$account" "log_mtime")

        if [ "$log_mtime" != "$cached_mtime" ] || [ -z "$cached_mtime" ]; then
            # Parse log
            eval "$(parse_log "$log_file")"

            # Compute total messages copied so far (grep count, cached by mtime)
            msgs_copied_total=$(grep -c " copied to " "$log_file" 2>/dev/null || echo 0)
            msgs_copied=${msgs_copied_total}

            # Calculate progress
            if [ -n "$msgs_found" ] && [ "$msgs_found" -gt 0 ] 2>/dev/null; then
                if [ -n "$msgs_copied" ] && [ "$msgs_copied" -ge 0 ] 2>/dev/null; then
                    progress_pct=$((msgs_copied * 100 / msgs_found))
                else
                    progress_pct=0
                fi
            else
                progress_pct=""
            fi

            # Calculate transfer rate
            if [ -n "$msgs_copied" ]; then
                last_msgs=$(load_cache "$account" "last_msgs_copied")
                last_msgs_ts=$(load_cache "$account" "last_msgs_ts")
                now=$(epoch_now)

                if [ -n "$last_msgs" ] && [ -n "$last_msgs_ts" ] && [ "$last_msgs" != "$msgs_copied" ]; then
                    time_delta=$((now - last_msgs_ts))
                    if [ "$time_delta" -gt 0 ]; then
                        msgs_delta=$((msgs_copied - last_msgs))
                        rate=$((msgs_delta / time_delta))
                    else
                        rate=0
                    fi
                else
                    rate=""
                fi
            else
                rate=""
            fi

            # Compute session deltas (per PID) for messages and MiB
            bytes_mib=0
            if [ -n "$bytes_text" ]; then
                bytes_mib=$(mib_from_text "$bytes_text")
            fi

            base_pid=$(load_cache "$account" "base_pid")
            msgs_base=$(load_cache "$account" "msgs_base")
            bytes_base_mib=$(load_cache "$account" "bytes_base_mib")
            if [ -z "$base_pid" ] || [ "$base_pid" != "$pid" ]; then
                msgs_base=${msgs_copied:-0}
                bytes_base_mib=${bytes_mib:-0}
                save_cache "$account" "base_pid=$pid" "msgs_base=$msgs_base" "bytes_base_mib=$bytes_base_mib"
            fi

            msgs_session=0
            if [ -n "$msgs_copied" ] && [ -n "$msgs_base" ]; then
                msgs_session=$((msgs_copied - msgs_base))
                [ "$msgs_session" -lt 0 ] && msgs_session=0
            fi

            mib_session=0
            if [ -n "$bytes_mib" ] && [ -n "$bytes_base_mib" ]; then
                mib_session=$((bytes_mib - bytes_base_mib))
                [ "$mib_session" -lt 0 ] && mib_session=0
            fi

            # Save to cache
            save_cache "$account" \
                "log_mtime=$log_mtime" \
                "msgs_found=${msgs_found:-0}" \
                "msgs_copied=${msgs_copied:-0}" \
                "msgs_skipped=${msgs_skipped:-0}" \
                "bytes_text=$bytes_text" \
                "bytes_mib=${bytes_mib:-0}" \
                "msgs_base=${msgs_base:-0}" \
                "bytes_base_mib=${bytes_base_mib:-0}" \
                "msgs_session=${msgs_session:-0}" \
                "mib_session=${mib_session:-0}" \
                "current_folder=$current_folder" \
                "last_error=$last_error" \
                "progress_pct=${progress_pct:-0}" \
                "last_msgs_copied=${msgs_copied:-0}" \
                "last_msgs_ts=$now" \
                "rate=${rate:-0}"
        else
            # Load from cache
            msgs_found=$(load_cache "$account" "msgs_found")
            msgs_copied=$(load_cache "$account" "msgs_copied")
            progress_pct=$(load_cache "$account" "progress_pct")
            rate=$(load_cache "$account" "rate")
            bytes_text=$(load_cache "$account" "bytes_text")
            bytes_mib=$(load_cache "$account" "bytes_mib")
            msgs_session=$(load_cache "$account" "msgs_session")
            mib_session=$(load_cache "$account" "mib_session")
            current_folder=$(load_cache "$account" "current_folder")
            last_error=$(load_cache "$account" "last_error")
        fi

        # Progress line
        if [ -n "$msgs_found" ] && [ "$msgs_found" -gt 0 ]; then
            if [ -n "$progress_pct" ]; then
                pct_str=" (${progress_pct}%)"
            else
                pct_str=""
            fi

            if [ -n "$rate" ] && [ "$rate" -gt 0 ]; then
                rate_str=" | Speed: ${rate} msgs/s"
            else
                rate_str=""
            fi

            printf '%b\n' "    Progress: ${msgs_copied:-0}/${msgs_found} msgs${pct_str}${rate_str} | Data:${bytes_text:-unknown}"
            printf '%b\n' "    Session: +${msgs_session:-0} msgs | +${mib_session:-0} MiB"
        else
            # Fallback when total unknown
            if [ -n "$msgs_copied" ] || [ -n "$bytes_text" ]; then
                printf '%b\n' "    Copied: ${msgs_copied:-0} msgs | Data:${bytes_text:-unknown}"
                printf '%b\n' "    Session: +${msgs_session:-0} msgs | +${mib_session:-0} MiB"
            fi
        fi

        # Current folder
        if [ -n "$current_folder" ]; then
            printf '%b\n' "    Current: ${CYAN}${current_folder}${NC}"
        fi

        # Errors
        if [ -n "$last_error" ]; then
            printf '%b\n' "    ${RED}Error: ${last_error}${NC}"
        fi
    fi

    # Policy and restart info
    if [ "$restarts" -gt 0 ]; then
        restart_str="${restarts}/${MAX_RESTARTS_DISPLAY}"
    else
        restart_str="0/${MAX_RESTARTS_DISPLAY}"
    fi

    printf '%b\n' "    Restarts: $restart_str | Policy: ${policy} | Next retry: ${backoff}"

    # History (if available)
    if [ -f "$STATE_DIR/${acct_safe}.restart_attempts.log" ]; then
        history=$(tail -3 "$STATE_DIR/${acct_safe}.restart_attempts.log" 2>/dev/null | grep "exit_code" | sed 's/.*exit_code=//' | tr '\n' '→' | sed 's/→$//')
        if [ -n "$history" ]; then
            printf '%b\n' "    History: $history"
        fi
    fi

    echo ""
}

# Clear screen for refresh
clear_screen() {
    if [ -t 1 ]; then
        clear
    fi
}

# Main loop
main() {
    printf '%b\n' "${CYAN}Starting Universal Migration Monitor...${NC}"
    echo "Refresh interval: ${REFRESH_INTERVAL}s"
    echo "State directory: $STATE_DIR"
    echo ""

    while true; do
        clear_screen

        # Header
        printf '%b\n' "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
        printf '%b\n' "${BOLD}${CYAN}    UNIVERSAL MIGRATION MONITOR - $(date +"%H:%M:%S")${NC}"
        printf '%b\n' "${BOLD}${CYAN}════════════════════════════════════════════════════════${NC}"
        echo ""

        # Collect and display accounts
        accounts=$(collect_accounts)
        if [ -z "$accounts" ]; then
            printf '%b\n' "${YELLOW}No migrations found${NC}"
            echo ""
            echo "To start a migration:"
            echo "  cd migrate/scripts"
            echo "  ./test_single.sh"
        else
            idx=1
            for account in $accounts; do
                display_account "$idx" "$account"
                idx=$((idx + 1))
            done

            # Summary
            total=$(echo "$accounts" | wc -w | tr -d ' ')
            running=$(for a in $accounts; do
                pf=$(find_state_file "$a" "pid");
                if [ -n "$pf" ]; then
                    pid=$(sed -n '1p' "$pf" 2>/dev/null)
                    kill -0 "$pid" 2>/dev/null && echo 1
                fi
            done | wc -l | tr -d ' ')

            printf '%b\n' "${CYAN}────────────────────────────────────────────────────────${NC}"
            printf '%b\n' "${BOLD}Summary:${NC} Total: $total | Running: $running | Stopped: $((total - running))"
        fi

        echo ""
        printf '%b\n' "${CYAN}────────────────────────────────────────────────────────${NC}"
        echo "Press Ctrl+C to exit | Refreshing every ${REFRESH_INTERVAL}s"

        sleep "$REFRESH_INTERVAL"
    done
}

# Handle signals
trap 'echo ""; echo "Exiting monitor..."; exit 0' INT TERM

# Run main
main
