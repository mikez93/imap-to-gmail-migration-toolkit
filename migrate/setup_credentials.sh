#!/usr/bin/env bash

# setup_credentials.sh - Set up credentials for email migration
# ================================================================
# This script creates the credential files needed by start_migration.sh
#
# Usage:
#   ./setup_credentials.sh user@example.com
#   ./setup_credentials.sh user@example.com --test
#
# Credentials are stored in:
#   ~/.imapsync/credentials/<account>/pass1  (source/HostGator password)
#   ~/.imapsync/credentials/<account>/pass2  (destination/Google App Password)

set -euo pipefail

# Configuration
CRED_DIR="$HOME/.imapsync/credentials"
DEFAULT_SRC_HOST="mail.example.com"
DEFAULT_DST_HOST="imap.gmail.com"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
    cat <<EOF
${BOLD}setup_credentials.sh - Set up credentials for email migration${NC}

Usage: $0 <email@domain.com> [options]

Options:
  --test              Test credentials after setup (connects to IMAP servers)
  --src-host HOST     Source IMAP host (default: $DEFAULT_SRC_HOST)
  --dst-host HOST     Destination IMAP host (default: $DEFAULT_DST_HOST)
  --show              Show existing credentials (masked)
  --delete            Delete existing credentials for this account
  --help              Show this help

Examples:
  $0 admin@example.com
  $0 admin@example.com --test
  $0 admin@example.com --show

Credentials are stored in:
  ~/.imapsync/credentials/<account>/pass1  (source password)
  ~/.imapsync/credentials/<account>/pass2  (Google App Password)

${YELLOW}Note: Google App Passwords must have spaces removed!${NC}
  Given:    "abcd efgh ijkl mnop"
  Enter as: "abcdefghijklmnop"
EOF
    exit 1
}

log() {
    echo -e "${GREEN}[✓]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $*"
}

error() {
    echo -e "${RED}[✗]${NC} $*" >&2
}

# Sanitize account name for filenames
sanitize_account() {
    echo "$1" | sed 's/@/_at_/g; s/[^a-zA-Z0-9._+-]/_/g'
}

# Mask password for display (show first 2 and last 2 chars)
mask_password() {
    local pass="$1"
    local len=${#pass}
    if [[ $len -le 4 ]]; then
        echo "****"
    else
        echo "${pass:0:2}$( printf '*%.0s' $(seq 1 $((len-4))) )${pass: -2}"
    fi
}

# Show existing credentials
show_credentials() {
    local account="$1"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    echo ""
    echo -e "${CYAN}Credentials for ${BOLD}$account${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
    echo "Directory: $cred_path"
    echo ""
    
    if [[ -f "$cred_path/pass1" ]]; then
        local pass1=$(cat "$cred_path/pass1")
        echo -e "Source password (pass1):      ${GREEN}exists${NC} - $(mask_password "$pass1")"
    else
        echo -e "Source password (pass1):      ${RED}missing${NC}"
    fi
    
    if [[ -f "$cred_path/pass2" ]]; then
        local pass2=$(cat "$cred_path/pass2")
        echo -e "Destination password (pass2): ${GREEN}exists${NC} - $(mask_password "$pass2")"
    else
        echo -e "Destination password (pass2): ${RED}missing${NC}"
    fi
    
    echo ""
}

# Delete credentials
delete_credentials() {
    local account="$1"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    if [[ ! -d "$cred_path" ]]; then
        warn "No credentials found for $account"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}This will delete credentials for $account${NC}"
    echo "Directory: $cred_path"
    echo ""
    read -p "Are you sure? (yes/no): " confirm
    
    if [[ "$confirm" == "yes" ]]; then
        rm -rf "$cred_path"
        log "Credentials deleted"
    else
        warn "Cancelled"
    fi
}

# Test credentials by connecting to IMAP servers
test_credentials() {
    local account="$1"
    local src_host="$2"
    local dst_host="$3"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    echo ""
    echo -e "${CYAN}Testing credentials...${NC}"
    echo ""
    
    # Check if openssl is available
    if ! command -v openssl &> /dev/null; then
        warn "openssl not found - skipping connection test"
        return 0
    fi
    
    local pass1=$(cat "$cred_path/pass1")
    local pass2=$(cat "$cred_path/pass2")
    
    # Test source server
    echo -n "Testing source ($src_host:993)... "
    if echo -e "a LOGIN \"$account\" \"$pass1\"\na LOGOUT" | \
       timeout 10 openssl s_client -connect "$src_host:993" -quiet 2>/dev/null | \
       grep -q "a OK"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        error "Could not authenticate to $src_host"
        echo "  Check: Is the password correct?"
        return 1
    fi
    
    # Test destination server
    echo -n "Testing destination ($dst_host:993)... "
    if echo -e "a LOGIN \"$account\" \"$pass2\"\na LOGOUT" | \
       timeout 10 openssl s_client -connect "$dst_host:993" -quiet 2>/dev/null | \
       grep -q "a OK"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${RED}FAILED${NC}"
        error "Could not authenticate to $dst_host"
        echo "  Check: Is this a Google App Password (not regular password)?"
        echo "  Check: Did you remove spaces from the app password?"
        return 1
    fi
    
    echo ""
    log "Both credentials are valid!"
    return 0
}

# Main credential setup
setup_credentials() {
    local account="$1"
    local account_safe=$(sanitize_account "$account")
    local cred_path="$CRED_DIR/$account_safe"
    
    echo ""
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}${BOLD}    CREDENTIAL SETUP FOR $account${NC}"
    echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Credentials will be stored in: $cred_path"
    echo ""
    
    # Check for existing credentials
    if [[ -f "$cred_path/pass1" ]] || [[ -f "$cred_path/pass2" ]]; then
        warn "Credentials already exist for this account"
        show_credentials "$account"
        echo ""
        read -p "Overwrite existing credentials? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            echo "Cancelled"
            exit 0
        fi
        echo ""
    fi
    
    # Create directory
    mkdir -p "$cred_path"
    chmod 700 "$cred_path"
    
    # Get source password
    echo -e "${BOLD}Source Server (HostGator)${NC}"
    echo "Host: $SRC_HOST"
    echo "User: $account"
    echo ""
    read -sp "Enter source password: " src_pass
    echo ""
    
    if [[ -z "$src_pass" ]]; then
        error "Password cannot be empty"
        exit 1
    fi
    
    # Get destination password
    echo ""
    echo -e "${BOLD}Destination Server (Google Workspace)${NC}"
    echo "Host: $DST_HOST"
    echo "User: $account"
    echo ""
    echo -e "${YELLOW}Important: Use a Google App Password, not your regular password!${NC}"
    echo -e "${YELLOW}Remove ALL spaces from the app password before entering.${NC}"
    echo "  Example: 'abcd efgh ijkl mnop' → 'abcdefghijklmnop'"
    echo ""
    read -sp "Enter Google App Password (no spaces): " dst_pass
    echo ""
    
    if [[ -z "$dst_pass" ]]; then
        error "Password cannot be empty"
        exit 1
    fi
    
    # Check for spaces in app password
    if [[ "$dst_pass" =~ \  ]]; then
        error "App password contains spaces! Remove them and try again."
        exit 1
    fi
    
    # Write credentials
    echo ""
    echo "Writing credentials..."
    
    printf '%s' "$src_pass" > "$cred_path/pass1"
    chmod 600 "$cred_path/pass1"
    log "Source password saved to $cred_path/pass1"
    
    printf '%s' "$dst_pass" > "$cred_path/pass2"
    chmod 600 "$cred_path/pass2"
    log "Destination password saved to $cred_path/pass2"
    
    echo ""
    echo -e "${GREEN}${BOLD}Credentials saved successfully!${NC}"
    
    # Optionally test
    if [[ "$DO_TEST" == "true" ]]; then
        test_credentials "$account" "$SRC_HOST" "$DST_HOST"
    else
        echo ""
        echo "To test credentials, run:"
        echo "  $0 $account --test"
    fi
    
    echo ""
    echo "To start the migration, run:"
    echo "  cd $(dirname "$0")"
    echo "  ./start_migration.sh $account"
    echo ""
}

# Parse arguments
ACCOUNT=""
DO_TEST="false"
DO_SHOW="false"
DO_DELETE="false"
SRC_HOST="$DEFAULT_SRC_HOST"
DST_HOST="$DEFAULT_DST_HOST"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test)
            DO_TEST="true"
            shift
            ;;
        --show)
            DO_SHOW="true"
            shift
            ;;
        --delete)
            DO_DELETE="true"
            shift
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
                error "Multiple accounts specified"
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate account
if [[ -z "$ACCOUNT" ]]; then
    error "No account specified"
    usage
fi

if [[ ! "$ACCOUNT" =~ ^[^@]+@[^@]+$ ]]; then
    error "Invalid email format: $ACCOUNT"
    exit 1
fi

# Execute requested action
if [[ "$DO_SHOW" == "true" ]]; then
    show_credentials "$ACCOUNT"
elif [[ "$DO_DELETE" == "true" ]]; then
    delete_credentials "$ACCOUNT"
elif [[ "$DO_TEST" == "true" ]] && [[ -f "$CRED_DIR/$(sanitize_account "$ACCOUNT")/pass1" ]]; then
    # If --test is passed and credentials exist, just test them
    test_credentials "$ACCOUNT" "$SRC_HOST" "$DST_HOST"
else
    setup_credentials "$ACCOUNT"
fi
