#!/usr/bin/env bash

# launch_account_interactive.sh
# Prompts for credentials and launches a single imapsync migration
# Usage:
#   ./launch_account_interactive.sh \
#     --user user1@example.com \
#     --src-host mail.example.com \
#     --dst-host imap.gmail.com [--max-age 7]

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

USER_EMAIL=""
SRC_HOST=""
DST_HOST=""
MAX_AGE_DAYS="${MAX_AGE_DAYS:-}"

usage() {
  echo "Usage: $0 --user <email> --src-host <host> --dst-host <host> [--max-age <days>]" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_EMAIL="${2:-}"; shift 2;;
    --src-host)
      SRC_HOST="${2:-}"; shift 2;;
    --dst-host)
      DST_HOST="${2:-}"; shift 2;;
    --max-age)
      MAX_AGE_DAYS="${2:-}"; shift 2;;
    *)
      echo -e "${YELLOW}Warning: Unknown argument '$1' (ignored)${NC}" >&2
      shift;;
  esac
done

[[ -z "$USER_EMAIL" || -z "$SRC_HOST" || -z "$DST_HOST" ]] && usage

SRC_USER="${SRC_USER:-$USER_EMAIL}"
DST_USER="${DST_USER:-$USER_EMAIL}"

echo -e "${GREEN}Starting interactive migration for ${USER_EMAIL}${NC}"
echo "Source host: $SRC_HOST  |  Destination host: $DST_HOST"
if [[ -n "${MAX_AGE_DAYS}" ]]; then
  echo "Message age limit: last ${MAX_AGE_DAYS} day(s)"
fi

read -r -s -p "Enter SOURCE password for $SRC_USER: " SRC_PASS; echo
read -r -s -p "Enter GMAIL APP PASSWORD (no spaces) for $DST_USER: " DST_PASS; echo

export SRC_HOST SRC_USER SRC_PASS DST_HOST DST_USER DST_PASS
[[ -n "${MAX_AGE_DAYS}" ]] && export MAX_AGE_DAYS

# Enable watchdog-friendly settings
export MAKE_RESTARTABLE=${MAKE_RESTARTABLE:-true}
export WDOG_WRITE_MANIFEST=${WDOG_WRITE_MANIFEST:-true}
export HEARTBEAT_INTERVAL=${HEARTBEAT_INTERVAL:-5}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${GREEN}Launching imapsync_cmd.sh ...${NC}"
./imapsync_cmd.sh
rc=$?
echo -e "${GREEN}imapsync_cmd.sh exited with code ${rc}${NC}"
exit $rc

