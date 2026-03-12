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

# Instructions:
# 1. Copy this file: cp templates/migration_config.sh config.sh
# 2. Edit the values for your environment
# 3. Source the file: source config.sh
# 4. Or set as environment variables: export $(grep -v '^#' config.sh | xargs)
#
# Customization tips:
# - For 64GB+ systems: Increase BUFFER_SIZE to 33554432 (32MB)
# - For slower networks: Decrease MAX_PARALLEL to 2
# - For testing: Set MAX_PARALLEL=1 and BUFFER_SIZE=2097152 (2MB)
# - For production: Use values shown above (conservative but reliable)
#
# Security notes:
# - Never commit this file with real credentials
# - Use password files instead of environment variables when possible
# - Clear environment variables after use: unset SRC_PASS DST_PASS
