#!/bin/bash
# Pre-migration validation checklist
# Run this before starting any migration

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Logging
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check() {
    local description="$1"
    local command="$2"
    local expected="$3"

    echo -n "Checking: $description... "

    if eval "$command" >/dev/null 2>&1; then
        if [[ -n "$expected" ]] && eval "$command" | grep -q "$expected"; then
            echo -e "${GREEN}✓ PASS${NC}"
        else
            echo -e "${GREEN}✓ PASS${NC}"
        fi
    else
        echo -e "${RED}✗ FAIL${NC}"
        return 1
    fi
}

warning() {
    local description="$1"
    local command="$2"

    echo -n "Checking: $description... "

    if eval "$command" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ OK${NC}"
    else
        echo -e "${YELLOW}⚠ WARNING${NC}"
        echo "  Suggestion: $3"
    fi
}

main() {
    echo "Pre-Migration Checklist"
    echo "======================"
    echo

    local failures=0

    # System requirements
    echo "📋 System Requirements"
    echo "---------------------"

    check "imapsync is installed" "command -v imapsync" || ((failures++))
    check "GNU parallel is installed" "command -v parallel" || ((failures++))
    check "Python 3 is available" "python3 --version" || ((failures++))

    warning "Sufficient RAM available" "free | awk 'NR==2{print \$2/1024/1024}' | awk '{print(\$1>8?\"true\":\"false\")}'" \
           "Consider using a system with at least 8GB RAM"

    warning "Sufficient disk space" "df / | awk 'NR==2{print \$4/1024/1024}' | awk '{print(\$1>10?\"true\":\"false\")}'" \
           "Ensure at least 10GB free space for logs and temporary files"

    # Network connectivity
    echo
    echo "🌐 Network Connectivity"
    echo "----------------------"

    check "DNS resolution for Gmail" "nslookup imap.gmail.com" || ((failures++))
    check "TCP connection to Gmail IMAP" "timeout 10 bash -c '</dev/tcp/imap.gmail.com/993'" || ((failures++))
    check "SSL connection to Gmail" "openssl s_client -connect imap.gmail.com:993 -servername imap.gmail.com" || ((failures++))

    # Configuration files
    echo
    echo "📄 Configuration Files"
    echo "----------------------"

    if [[ -f "migration_map.csv" ]]; then
        check "Migration CSV exists" "test -f migration_map.csv" || ((failures++))
        check "CSV has correct headers" "head -1 migration_map.csv | grep -q 'src_user,src_pass,dst_user,dst_pass'" || ((failures++))
        check "CSV has data rows" "tail -n +2 migration_map.csv | wc -l | grep -q '[1-9]'" || ((failures++))
    else
        echo -e "⚠️  ${YELLOW}Migration CSV not found${NC}"
        echo "   Create migration_map.csv with your user data"
        ((failures++))
    fi

    # Directory structure
    echo
    echo "📁 Directory Structure"
    echo "---------------------"

    check "Log directory exists" "test -d LOG_imapsync/logs || mkdir -p LOG_imapsync/logs" || ((failures++))
    check "Config directory exists" "test -d config || mkdir -p config" || ((failures++))
    check "Scripts are executable" "test -x scripts/imapsync_cmd.sh && test -x scripts/run_batch.sh" || ((failures++))

    # Security checks
    echo
    echo "🔒 Security Checks"
    echo "-----------------"

    if [[ -f "migration_map.csv" ]]; then
        check "Migration CSV has secure permissions" "test $(stat -c %a migration_map.csv) -le 600" || ((failures++))
    fi

    warning "No hardcoded passwords in scripts" "grep -r 'password.*=' scripts/ | grep -v '^#' | wc -l | grep -q '^0'" \
           "Remove hardcoded passwords from scripts"

    # Summary
    echo
    echo "📊 Summary"
    echo "----------"

    if [[ $failures -eq 0 ]]; then
        echo -e "${GREEN}✅ All checks passed! Ready for migration.${NC}"
        echo
        echo "Next steps:"
        echo "1. Test with single account: ./scripts/test_single.sh"
        echo "2. Run migration: ./scripts/run_batch.sh migration_map.csv"
        echo "3. Monitor progress: ./launch_triple_terminal.sh"
    else
        echo -e "${RED}❌ $failures check(s) failed. Please resolve issues before migrating.${NC}"
        echo
        echo "Common solutions:"
        echo "- Install missing dependencies: sudo apt-get install imapsync parallel"
        echo "- Fix CSV format: Ensure headers are 'src_user,src_pass,dst_user,dst_pass'"
        echo "- Check network: Verify firewall allows outbound connections to imap.gmail.com:993"
        echo "- Review security: Use password files instead of command line arguments"
    fi

    echo
    echo "For detailed troubleshooting, see: docs/TROUBLESHOOTING.md"
}

main "$@"
