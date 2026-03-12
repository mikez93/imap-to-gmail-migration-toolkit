#!/usr/bin/env sh

# posix_helpers.sh - Shared POSIX-compliant utilities for migration scripts
# These functions work in both sh and bash environments

# Ensure a directory exists with secure permissions (700)
ensure_secure_dir() {
    dir="$1"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chmod 700 "$dir"
    fi
}

# Sanitize account name for safe filenames
# Replaces @ with _at_ and removes unsafe characters
sanitize_account() {
    echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'
}

# Sanitize account name using underscore only (legacy compatibility)
sanitize_acct() {
    echo "$1" | tr '@' '_' | tr -cd '[:alnum:]_.-'
}

# JSON escape function for safe logging
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

# Atomically overwrite a file using stdin as content
# Ensures permissions 600 via umask
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

# Check if value is a positive integer (including zero)
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

# Return integer or default if invalid
get_int_or_default() {
    val="$1"
    def="$2"
    if is_pos_int "$val"; then
        printf "%s" "$val"
    else
        printf "%s" "$def"
    fi
}

# Get current timestamp in various formats
timestamp_iso() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

timestamp_log() {
    date '+%Y-%m-%d %H:%M:%S'
}

timestamp_file() {
    date '+%Y%m%d_%H%M%S'
}

# Get epoch seconds
epoch_now() {
    date '+%s'
}

# Simple logging function
log_to_file() {
    logfile="$1"
    shift
    ts=$(timestamp_log)
    printf "[%s] %s\n" "$ts" "$*" >> "$logfile"
}

# Export functions for use in sourcing scripts
export -f ensure_secure_dir 2>/dev/null || true
export -f sanitize_account 2>/dev/null || true
export -f sanitize_acct 2>/dev/null || true
export -f json_escape 2>/dev/null || true
export -f atomic_overwrite 2>/dev/null || true
export -f is_pos_int 2>/dev/null || true
export -f get_int_or_default 2>/dev/null || true
export -f timestamp_iso 2>/dev/null || true
export -f timestamp_log 2>/dev/null || true
export -f timestamp_file 2>/dev/null || true
export -f epoch_now 2>/dev/null || true
export -f log_to_file 2>/dev/null || true
