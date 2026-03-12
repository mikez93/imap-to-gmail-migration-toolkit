# Migration Templates

This directory contains templates and examples to help you get started with email migrations quickly.

## Templates Overview

### CSV Templates
- `basic_migration.csv` - Simple single-user migration
- `batch_migration.csv` - Multiple users with basic settings
- `enterprise_migration.csv` - Large-scale migration with advanced options
- `test_migration.csv` - Sample data for testing

### Configuration Templates
- `migration_config.sh` - Environment variables template
- `monitoring_config.sh` - Monitoring setup template
- `performance_config.sh` - High-performance configuration

### Script Templates
- `custom_migration.sh` - Custom migration script template
- `pre_migration_checklist.sh` - Pre-migration validation
- `post_migration_report.sh` - Post-migration reporting

## Quick Start Templates

### Basic Single User Migration

**File**: `basic_migration.csv`
```csv
src_user,src_pass,dst_user,dst_pass
john@oldcompany.com,MyPassword123,john@newcompany.com,abcd1234efgh5678
```

**Usage**:
```bash
# Copy template
cp templates/basic_migration.csv migration_map.csv

# Edit with your credentials
nano migration_map.csv

# Test first
./scripts/test_single.sh

# Run migration
./scripts/imapsync_cmd.sh john@oldcompany.com MyPassword123 john@newcompany.com abcd1234efgh5678
```

### Batch Migration for Small Teams

**File**: `batch_migration.csv`
```csv
src_user,src_pass,dst_user,dst_pass,priority
ceo@oldcompany.com,CEOPass123,ceo@newcompany.com,apppass1234567890,high
cto@oldcompany.com,CTOPass456,cto@newcompany.com,apppass2345678901,high
dev1@oldcompany.com,Dev1Pass789,dev1@newcompany.com,apppass3456789012,normal
dev2@oldcompany.com,Dev2Pass012,dev2@newcompany.com,apppass4567890123,normal
```

**Usage**:
```bash
# Copy and edit template
cp templates/batch_migration.csv migration_map.csv
nano migration_map.csv

# Run with priority users first
./scripts/run_batch.sh migration_map.csv --priority "ceo@newcompany.com,cto@newcompany.com"

# Then run remaining users
./scripts/run_batch.sh migration_map.csv
```

### Enterprise Migration Template

**File**: `enterprise_migration.csv`
```csv
src_user,src_pass,dst_user,dst_pass,priority,department,batch
ceo@oldcompany.com,CEOPass123,ceo@newcompany.com,apppass1234567890,critical,executive,1
cfo@oldcompany.com,CFOPass456,cfo@newcompany.com,apppass2345678901,critical,executive,1
cto@oldcompany.com,CTOPass789,cto@newcompany.com,apppass3456789012,high,engineering,2
dev1@oldcompany.com,Dev1Pass012,dev1@newcompany.com,apppass4567890123,normal,engineering,2
dev2@oldcompany.com,Dev2Pass345,dev2@newcompany.com,apppass5678901234,normal,engineering,2
sales1@oldcompany.com,Sales1Pass678,sales1@newcompany.com,apppass6789012345,high,sales,3
sales2@oldcompany.com,Sales2Pass901,sales2@newcompany.com,apppass7890123456,high,sales,3
support1@oldcompany.com,Support1Pass234,support1@newcompany.com,apppass8901234567,normal,support,4
support2@oldcompany.com,Support2Pass567,support2@newcompany.com,apppass9012345678,normal,support,4
```

**Usage**:
```bash
# Copy enterprise template
cp templates/enterprise_migration.csv migration_map.csv
nano migration_map.csv

# Run by priority batches
./scripts/run_batch.sh migration_map.csv --batch 1  # Critical users
./scripts/run_batch.sh migration_map.csv --batch 2  # Engineering
./scripts/run_batch.sh migration_map.csv --batch 3  # Sales
./scripts/run_batch.sh migration_map.csv --batch 4  # Support
```

## Configuration Templates

### Basic Configuration

**File**: `migration_config.sh`
```bash
#!/bin/bash
# Basic migration configuration template
# Copy to your project and customize

# Source server settings
export SRC_HOST="mail.yourdomain.com"
export SRC_PORT="993"
export SRC_SSL="true"

# Destination server settings
export DST_HOST="imap.gmail.com"
export DST_PORT="993"
export DST_SSL="true"

# Performance settings (adjust based on your system)
export BUFFER_SIZE="4194304"        # 4MB (safe default)
export MAX_PARALLEL="3"             # 3 concurrent migrations
export MAX_MESSAGE_SIZE="52428800"  # 50MB message limit

# Logging settings
export LOG_DIR="LOG_imapsync/logs"
export LOG_LEVEL="INFO"

# Security settings
export TEMP_DIR="/tmp/migration_tmp"
export SECURE_PASS_FILES="true"

# Gmail-specific settings
export GMAIL_EXCLUSIONS="\\[Gmail\\]/All Mail,\\[Gmail\\]/Important,\\[Gmail\\]/Starred"

# Migration options
export SYNC_INTERNAL_DATES="true"
export USE_UID="true"
export AUTOMAP="true"
export ADD_HEADER="true"
```

**Usage**:
```bash
# Copy and customize
cp templates/migration_config.sh config.sh
nano config.sh

# Source in your scripts
source config.sh

# Or set as environment variables
export $(grep -v '^#' config.sh | xargs)
```

### High-Performance Configuration

**File**: `performance_config.sh`
```bash
#!/bin/bash
# High-performance configuration for dedicated servers
# Use with caution - requires 64GB+ RAM

# Performance settings for 64GB+ systems
export BUFFER_SIZE="33554432"       # 32MB buffer
export MAX_PARALLEL="6"             # 6 concurrent migrations
export MAX_LINE_LENGTH="100000"     # 100KB line limit
export MAX_MESSAGE_SIZE="52428800"  # 50MB message limit

# Fast I/O settings
export FAST_IO1="true"
export FAST_IO2="true"

# RAM disk for temporary files (requires setup)
export RAM_DISK="/dev/shm/imapsync"
export RAM_DISK_SIZE="8G"

# Network optimizations
export TCP_BUFFER_MAX="134217728"   # 128MB TCP buffer
export CONNECTION_RETRIES="20"

# Gmail rate limiting (be conservative)
export MAX_MSGS_PER_SECOND="8"      # Below Gmail limits
export MAX_BYTES_PER_SECOND="5242880" # 5MB/s per connection

# Advanced imapsync options
export NO_FOLDER_SIZES="true"
export NO_FOLDER_SIZES_AT_END="true"
export USE_UID="true"
export SYNC_INTERNAL_DATES="true"
export AUTOMAP="true"
export ADD_HEADER="true"

# Folder separators
export SEP1="."
export SEP2="/"

# Exclusions (critical for Gmail)
export EXCLUDE_FOLDERS="\\[Gmail\\]/All Mail,\\[Gmail\\]/Important,\\[Gmail\\]/Starred"

# Logging
export LOG_DIR="LOG_imapsync/logs"
export LOG_LEVEL="INFO"
```

**Usage**:
```bash
# Set up RAM disk first
sudo mkdir -p /dev/shm/imapsync
sudo mount -t tmpfs -o size=8G tmpfs /dev/shm/imapsync

# Source performance config
source templates/performance_config.sh

# Run high-performance migration
./scripts/run_batch.sh migration_map.csv -c 6
```

## Script Templates

### Custom Migration Script

**File**: `custom_migration.sh`
```bash
#!/bin/bash
# Custom migration script template
# Customize for your specific needs

set -euo pipefail

# Configuration
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly CSV_FILE="${PROJECT_ROOT}/migration_map.csv"
readonly LOG_DIR="${PROJECT_ROOT}/LOG_imapsync/logs"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_DIR}/custom_migration.log"
}

# Error handling
error_exit() {
    local message="$1"
    log "ERROR" "$message"
    exit 1
}

# Pre-migration checks
pre_migration_checks() {
    log "INFO" "Running pre-migration checks..."

    # Check dependencies
    if ! command -v imapsync >/dev/null 2>&1; then
        error_exit "imapsync not found. Install with: sudo apt-get install imapsync"
    fi

    # Check CSV file exists
    if [[ ! -f "$CSV_FILE" ]]; then
        error_exit "Migration CSV not found: $CSV_FILE"
    fi

    # Check log directory
    mkdir -p "$LOG_DIR" || error_exit "Cannot create log directory: $LOG_DIR"

    # Validate CSV format
    if ! head -1 "$CSV_FILE" | grep -q "src_user,src_pass,dst_user,dst_pass"; then
        error_exit "Invalid CSV format. Expected: src_user,src_pass,dst_user,dst_pass"
    fi

    log "INFO" "Pre-migration checks completed successfully"
}

# Main migration function
run_migration() {
    local csv_file="$1"
    local parallel="${2:-3}"
    local dry_run="${3:-false}"

    log "INFO" "Starting migration with $parallel parallel processes"

    if [[ "$dry_run" == "true" ]]; then
        log "INFO" "DRY RUN MODE - No actual migration will occur"
        ./scripts/run_batch.sh "$csv_file" --dry-run -c "$parallel"
    else
        ./scripts/run_batch.sh "$csv_file" -c "$parallel"
    fi
}

# Post-migration report
generate_report() {
    log "INFO" "Generating post-migration report..."

    local report_file="${LOG_DIR}/migration_report_$(date +%Y%m%d_%H%M%S).txt"

    cat > "$report_file" << EOF
MIGRATION REPORT
================
Date: $(date)
CSV File: $CSV_FILE
Parallel Processes: $2
Dry Run: $3

COMPLETED MIGRATIONS:
$(grep "SUCCESS" LOG_imapsync/logs/*.log | wc -l)

FAILED MIGRATIONS:
$(grep "FAILED\|ERROR" LOG_imapsync/logs/*.log | wc -l)

TOTAL MESSAGES:
$(grep "copied to" LOG_imapsync/logs/*.log | wc -l)

LOG FILES:
$(ls -la LOG_imapsync/logs/*.log | wc -l) files created

EOF

    log "INFO" "Report generated: $report_file"
}

# Main execution
main() {
    echo "Custom Migration Script"
    echo "======================"

    # Parse arguments
    local csv_file="${CSV_FILE}"
    local parallel="3"
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--concurrent)
                parallel="$2"
                shift 2
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [-c CONCURRENT] [--dry-run]"
                exit 0
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done

    # Run migration
    pre_migration_checks
    run_migration "$csv_file" "$parallel" "$dry_run"
    generate_report "$csv_file" "$parallel" "$dry_run"

    log "INFO" "Migration completed successfully"
}

# Run main function with all arguments
main "$@"
```

**Usage**:
```bash
# Copy and customize
cp templates/custom_migration.sh my_migration.sh
chmod +x my_migration.sh
nano my_migration.sh

# Run with default settings
./my_migration.sh

# Run with 6 parallel processes
./my_migration.sh -c 6

# Dry run to test
./my_migration.sh --dry-run
```

### Pre-Migration Checklist

**File**: `pre_migration_checklist.sh`
```bash
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
```

**Usage**:
```bash
# Run pre-migration checks
./templates/pre_migration_checklist.sh

# Should output something like:
# ✅ All checks passed! Ready for migration.
```

## Example Configurations

### Small Business (1-10 users)

**Configuration**:
```bash
# Conservative settings for small migrations
export BUFFER_SIZE=4194304    # 4MB buffer
export MAX_PARALLEL=2         # 2 concurrent migrations
export LOG_LEVEL="INFO"
```

**CSV Template**: Use `basic_migration.csv` or `batch_migration.csv`

**Recommended workflow**:
```bash
# 1. Test single account
./scripts/test_single.sh

# 2. Run all users
./scripts/run_batch.sh migration_map.csv -c 2

# 3. Monitor progress
./launch_triple_terminal.sh
```

### Medium Business (10-100 users)

**Configuration**:
```bash
# Balanced settings for medium migrations
export BUFFER_SIZE=8388608    # 8MB buffer
export MAX_PARALLEL=4         # 4 concurrent migrations
export LOG_LEVEL="INFO"
```

**CSV Template**: Use `enterprise_migration.csv` with priority batches

**Recommended workflow**:
```bash
# 1. Test with sample users
./scripts/run_batch.sh migration_map.csv --dry-run

# 2. Run priority users first
./scripts/run_batch.sh migration_map.csv --priority "ceo@,cfo@,cto@"

# 3. Run remaining users by department
./scripts/run_batch.sh migration_map.csv --batch engineering
./scripts/run_batch.sh migration_map.csv --batch sales
./scripts/run_batch.sh migration_map.csv --batch support
```

### Large Enterprise (100+ users)

**Configuration**: Use `performance_config.sh` template

**CSV Template**: Use `enterprise_migration.csv` with detailed batching

**Recommended workflow**:
```bash
# 1. Set up high-performance environment
source templates/performance_config.sh

# 2. Test performance with small batch
./scripts/run_batch.sh test_batch.csv -c 6

# 3. Run production migration in phases
./scripts/run_batch.sh migration_map.csv --batch critical
./scripts/run_batch.sh migration_map.csv --batch high
./scripts/run_batch.sh migration_map.csv --batch normal
./scripts/run_batch.sh migration_map.csv --batch low
```

## Best Practices

### CSV File Management

1. **Always backup your CSV**:
   ```bash
   cp migration_map.csv migration_map.csv.backup
   ```

2. **Use secure permissions**:
   ```bash
   chmod 600 migration_map.csv
   ```

3. **Validate CSV format**:
   ```bash
   # Check headers
   head -1 migration_map.csv

   # Check for empty lines
   grep -v '^#' migration_map.csv | grep -v '^src_user' | awk -F',' 'NF != 4 {print "Line " NR ": " $0}'

   # Count users
   tail -n +2 migration_map.csv | wc -l
   ```

### Testing Strategy

1. **Start with test accounts**:
   ```bash
   # Create test CSV with non-critical accounts
   cp templates/test_migration.csv test_migration_map.csv
   nano test_migration_map.csv
   ```

2. **Test different scenarios**:
   ```bash
   # Test single account
   ./scripts/test_single.sh

   # Test batch processing
   ./scripts/run_batch.sh test_migration_map.csv -c 2

   # Test failure recovery
   # Kill a migration and verify it resumes
   ```

3. **Performance testing**:
   ```bash
   # Test with different buffer sizes
   export BUFFER_SIZE=2097152  # 2MB
   ./scripts/run_batch.sh test_migration_map.csv -c 1

   export BUFFER_SIZE=4194304  # 4MB
   ./scripts/run_batch.sh test_migration_map.csv -c 1
   ```

## Troubleshooting Templates

### Common Issues and Solutions

#### Authentication Problems
```bash
# Test authentication directly
imapsync --host2 imap.gmail.com --user2 user@domain.com \
         --password2 "apppasswordnospaces" --ssl2 --justlogin

# Check app password format
echo "App password should have no spaces: abcdefghijklmnop"
```

#### Performance Issues
```bash
# Check system resources
free -h
top -p $(pgrep imapsync)

# Reduce buffer size if memory issues
export BUFFER_SIZE=2097152  # 2MB

# Check transfer rates
tail -f LOG_imapsync/logs/*.log | grep "msgs/s"
```

#### Network Issues
```bash
# Test connectivity
ping -c 3 imap.gmail.com
telnet imap.gmail.com 993

# Check firewall
sudo ufw status
sudo iptables -L | grep 993
```

## Template Customization

### Creating Your Own Templates

1. **Start with existing template**:
   ```bash
   cp templates/basic_migration.csv my_template.csv
   ```

2. **Customize for your organization**:
   ```bash
   # Add columns for your needs
   echo "src_user,src_pass,dst_user,dst_pass,department,priority,manager" > my_template.csv

   # Add sample data
   echo "john@old.com,pass123,john@new.com,apppass123,engineering,high,jane@new.com" >> my_template.csv
   ```

3. **Create configuration template**:
   ```bash
   cp templates/migration_config.sh my_config.sh
   nano my_config.sh
   ```

4. **Test your template**:
   ```bash
   ./templates/pre_migration_checklist.sh
   ./scripts/run_batch.sh my_template.csv --dry-run
   ```

## Integration Examples

### With Google Workspace Admin Console

```bash
# 1. Export users from Google Admin
# Go to Admin Console → Users → Export Users

# 2. Convert to migration format
./scripts/convert_google_export.py users.csv migration_map.csv

# 3. Generate app passwords for all users
# Use Google Admin SDK or manual process

# 4. Run migration
./scripts/run_batch.sh migration_map.csv
```

### With Active Directory

```bash
# 1. Export users from AD
# Use PowerShell or LDAP query

# 2. Convert to migration format
./scripts/convert_ad_export.py ad_users.csv migration_map.csv

# 3. Set up authentication
# Configure IMAP for all users or use service account

# 4. Run migration
./scripts/run_batch.sh migration_map.csv
```

## Support and Updates

### Getting Help with Templates

1. **Check template documentation**:
   ```bash
   cat templates/README.md
   ```

2. **Validate your configuration**:
   ```bash
   ./templates/pre_migration_checklist.sh
   ```

3. **Test with sample data**:
   ```bash
   ./scripts/run_batch.sh templates/test_migration.csv --dry-run
   ```

### Contributing Templates

1. **Create your template** in the appropriate format
2. **Test thoroughly** with different scenarios
3. **Document usage** in this README
4. **Submit as pull request** with clear description

## Template Version History

- **v1.0** (2025-09-26): Initial template collection
  - Basic, batch, and enterprise CSV templates
  - Configuration templates for different environments
  - Pre-migration checklist script
  - Custom migration script template

---

**Happy migrating!** 🚀

For more examples and advanced configurations, see the main documentation in the `docs/` directory.
