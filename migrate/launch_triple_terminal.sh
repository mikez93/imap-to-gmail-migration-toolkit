#!/usr/bin/env bash

# launch_triple_terminal.sh - One-line launcher for triple terminal setup
# Opens 3 terminals: Watchdog, Log Tail, and Monitor Dashboard

# Configuration
TERMINAL_APP="${TERMINAL_APP:-Terminal}"  # Terminal or iTerm
BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="/var/tmp/migration_watchdog"
HEARTBEAT_DIR="$STATE_DIR/heartbeats"
LAUNCH_ACCOUNT=""                             # Set to open 4th tab with interactive migration
SRC_HOST="${SRC_HOST:-mail.example.com}"
DST_HOST="${DST_HOST:-imap.gmail.com}"

# Parse simple flags
for arg in "$@"; do
  case "$arg" in
    --start-account)
      shift
      LAUNCH_ACCOUNT="$1"
      shift
      ;;
    --start-account=*)
      LAUNCH_ACCOUNT="${arg#*=}"
      shift
      ;;
    --terminal=*)
      TERMINAL_APP="${arg#*=}"
      shift
      ;;
  esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}${BOLD}    MIGRATION MONITORING SYSTEM LAUNCHER${NC}"
echo -e "${CYAN}${BOLD}════════════════════════════════════════════════════════${NC}"
echo ""

# Ensure required directories exist
echo -e "${GREEN}Creating required directories...${NC}"
mkdir -p "$STATE_DIR"
mkdir -p "$HEARTBEAT_DIR"
mkdir -p "$BASE_DIR/logs"
chmod 700 "$STATE_DIR"
chmod 700 "$HEARTBEAT_DIR"

# Source .env if it exists
if [ -f "$BASE_DIR/.env" ]; then
    echo -e "${GREEN}Loading environment from .env...${NC}"
    set -a
    . "$BASE_DIR/.env"
    set +a
fi

# Check if running on macOS
if [ "$(uname)" != "Darwin" ]; then
    echo -e "${RED}Error: This launcher is designed for macOS${NC}"
    echo "For Linux, manually open three terminals and run:"
    echo "  1. cd $BASE_DIR && RESTART_MODE=auto CHECK_INTERVAL=5 ./migration_watchdog.sh -r"
    echo "  2. tail -n 50 -F $STATE_DIR/watchdog.log $STATE_DIR/*.jsonl"
    echo "  3. cd $BASE_DIR && ./universal_monitor.sh"
    exit 1
fi

# Check for osascript
if ! command -v osascript &> /dev/null; then
    echo -e "${RED}Error: osascript not found${NC}"
    exit 1
fi

echo -e "${GREEN}Launching terminals...${NC}"
echo ""

# Prepare plain (no-ANSI) headings to avoid AppleScript parsing errors
HDR_WDOG="MIGRATION WATCHDOG (Auto-Restart Mode)"
HDR_LOGS="LOG MONITOR (Human & JSON)"
HDR_MONI="UNIVERSAL MIGRATION MONITOR"
HDR_MIGR="START MIGRATION (Interactive)"

# Commands to run in each tab/window
CMD_WDOG="cd '$BASE_DIR' && printf '%s\n\n' '$HDR_WDOG' && RESTART_MODE=auto CHECK_INTERVAL=5 ./migration_watchdog.sh -r"
# Log tail + automatic death snapshot viewer (loop extracted to death_summary_watcher.sh to avoid AppleScript quoting issues)
CMD_LOGS="cd '$BASE_DIR' && printf '%s\n\nWatching: %s\nJSON: %s\n\n' '$HDR_LOGS' '$STATE_DIR/watchdog.log' '$STATE_DIR/watchdog.jsonl' && ( tail -n 50 -F $STATE_DIR/watchdog.log $STATE_DIR/*.jsonl 2>/dev/null & STATE_DIR='$STATE_DIR' ./death_summary_watcher.sh )"
CMD_MONI="cd '$BASE_DIR' && printf '%s\n\n' '$HDR_MONI' && ./universal_monitor.sh"
CMD_ACCT="cd '$BASE_DIR/scripts' && printf '%s for $LAUNCH_ACCOUNT\n\n' '$HDR_MIGR' && ./launch_account_interactive.sh --user $LAUNCH_ACCOUNT --src-host $SRC_HOST --dst-host $DST_HOST"

# Launch based on terminal application preference
if [ "$TERMINAL_APP" = "iTerm" ]; then
    echo "Using iTerm2..."

    osascript <<EOF
    tell application "iTerm"
        create window with default profile
        tell current window
            -- Tab 1: Watchdog
            tell current session to write text "$CMD_WDOG"

            -- Tab 2: Log Tail
            create tab with default profile
            tell current session to write text "$CMD_LOGS"

            -- Tab 3: Universal Monitor
            create tab with default profile
            tell current session to write text "$CMD_MONI"

            -- Tab 4 (optional): Interactive migration for specified account
            if "$LAUNCH_ACCOUNT" is not equal to "" then
                create tab with default profile
                tell current session to write text "$CMD_ACCT"
            end if
        end tell
    end tell
EOF

else
    echo "Using Terminal.app..."

    # Terminal 1: Watchdog
    osascript <<EOF
    tell application "Terminal"
        do script "$CMD_WDOG"
    end tell
EOF

    # Small delay to ensure windows open in order
    sleep 0.5

    # Terminal 2: Log Tail
    osascript <<EOF
    tell application "Terminal"
        do script "$CMD_LOGS"
    end tell
EOF

    sleep 0.5

    # Terminal 3: Universal Monitor
    osascript <<EOF
    tell application "Terminal"
        do script "$CMD_MONI"
    end tell
EOF

    # Optional Terminal 4: Interactive account migration
    if [ -n "$LAUNCH_ACCOUNT" ]; then
      sleep 0.5
      osascript <<EOF
      tell application "Terminal"
          do script "$CMD_ACCT"
      end tell
EOF
    fi
fi

echo -e "${GREEN}✓ Launched 3 terminal windows:${NC}"
echo "  1. ${BOLD}Watchdog${NC} - Auto-restart mode with 5s checks"
echo "  2. ${BOLD}Log Tail${NC} - Human and JSON logs"
echo "  3. ${BOLD}Monitor${NC} - Comprehensive dashboard"
if [ -n "$LAUNCH_ACCOUNT" ]; then
  echo "  4. ${BOLD}$LAUNCH_ACCOUNT${NC} - Interactive migration"
fi
echo ""
echo -e "${CYAN}Quick Commands:${NC}"
echo "  Start test migration: cd scripts && ./test_single.sh"
echo "  Stop watchdog: Ctrl+C in watchdog terminal"
echo "  Stop specific account: touch $STATE_DIR/{account}.stop"
echo ""
echo -e "${YELLOW}Test the system:${NC}"
echo "  1. Start a test migration with stub:"
echo "     export IMAPSYNC_BIN=./scripts/imapsync_stub.sh"
echo "     export STUB_BEHAVIOR=quick_success"
echo "     cd scripts && ./test_single.sh"
echo ""
echo "  2. Test kill detection:"
echo "     Find PID in monitor and run: kill -TERM <PID>"
echo "     Watch for restart within 5 seconds"
echo ""
echo -e "${GREEN}Launcher complete!${NC}"
