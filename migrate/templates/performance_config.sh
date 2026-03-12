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

# Instructions:
# 1. Set up RAM disk first:
#    sudo mkdir -p /dev/shm/imapsync
#    sudo mount -t tmpfs -o size=8G tmpfs /dev/shm/imapsync
#
# 2. Copy this file: cp templates/performance_config.sh config.sh
# 3. Edit values for your specific server
# 4. Source the file: source config.sh
#
# Performance tips:
# - Monitor memory usage closely: watch -n 5 'ps aux | grep imapsync | awk "{sum+=\$6} END {print \"Total: \" sum/1024 \" MB\"}"'
# - Start with lower parallel count and increase gradually
# - Monitor Gmail rate limiting in Admin Console
# - Use RAM disk for temp files when possible
# - Consider running during off-peak hours
#
# Expected performance (64GB system):
# - 6 parallel migrations
# - 30-50 messages/second total
# - 20-30 MB/s total throughput
# - 100GB/hour theoretical max
# - 50-70GB/hour realistic with Gmail limits
#
# Security notes:
# - Never commit this file with real credentials
# - Monitor system resources closely
# - Have monitoring and alerting in place
# - Test thoroughly before production use
