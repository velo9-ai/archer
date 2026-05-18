#!/usr/bin/env bash
# kri-morning-summary.sh — 7am morning PR digest
#
# Sends a Telegram summary of last night's overnight build results so JB wakes
# up knowing exactly what's waiting for review. Supplements the real-time
# notifications sent by kri-overnight-build.sh.
#
# See plists/ai.velo9.kri-morning-summary.plist for the daemon definition.

set -euo pipefail

REPO_SLUG="velo9-ai/KRI-IP"
LOG_DIR="${HOME}/Library/Logs/kri-crew"
PLAN_DIR="${HOME}/.kri-crew"
DATE_STAMP="$(date +%Y-%m-%d)"

# Resolve yesterday's date cross-platform (macOS BSD date / GNU date)
YESTERDAY=$(date -v-1d +%Y-%m-%d 2>/dev/null \
  || date -d "yesterday" +%Y-%m-%d 2>/dev/null \
  || echo "")

RESULTS_FILE=""
[[ -n "$YESTERDAY" ]] && RESULTS_FILE="${PLAN_DIR}/overnight-results-${YESTERDAY}.json"

mkdir -p "$LOG_DIR"

VELOCITY_DIR="${HOME}/Developer/velo9-dev/velocity"

tg_send() {
  [[ -d "$VELOCITY_DIR" ]] || return 0
  local msg="*@velocity:* $1"
  (
    cd "$VELOCITY_DIR"
    VELOCITY_MSG="$msg" .venv/bin/python -c \
      "import os,sys; sys.path.insert(0,'.'); from cos.integrations.telegram_bot import send_message; send_message(os.environ['VELOCITY_MSG'])"
  ) 2>/dev/null || true
}

if [[ -z "$RESULTS_FILE" || ! -f "$RESULTS_FILE" ]]; then
  # No results file — check for any open overnight/crew or overnight/done PRs
  if command -v gh &>/dev/null; then
    OPEN_PRS=$(gh pr list \
      --repo "$REPO_SLUG" --state open \
      --label "overnight/crew" \
      --json number,title,url --jq 'length' 2>/dev/null || echo "0")
    if [[ "$OPEN_PRS" -gt 0 ]]; then
      tg_send "☀️ *Good morning, JB* — ${OPEN_PRS} overnight PR(s) waiting for review.

https://github.com/${REPO_SLUG}/pulls"
    fi
  fi
  exit 0
fi

RESULTS=$(cat "$RESULTS_FILE")
PR_COUNT=$(echo  "$RESULTS" | jq '[.[] | select(.status == "pr-opened")] | length')
BLOCKED_N=$(echo "$RESULTS" | jq '[.[] | select(.status == "blocked")] | length')
TOTAL=$(echo     "$RESULTS" | jq 'length')

if [[ "$TOTAL" -eq 0 && "$PR_COUNT" -eq 0 ]]; then
  exit 0
fi

PR_LIST=$(echo "$RESULTS" | jq -r \
  '.[] | select(.status == "pr-opened") | "  • #\(.issue): \(.title | .[0:60])"' || echo "none")

BLOCKED_LIST=$(echo "$RESULTS" | jq -r \
  '.[] | select(.status == "blocked") | "  • #\(.issue): \(.notes)"' || echo "")

MSG="☀️ *Good morning, JB* — KRI overnight results (${YESTERDAY:-last night})

PRs ready to review: *${PR_COUNT}*  |  Blocked: *${BLOCKED_N}*

${PR_LIST}"

[[ -n "$BLOCKED_LIST" ]] && MSG="${MSG}

*Blocked (needs your attention):*
${BLOCKED_LIST}"

MSG="${MSG}

https://github.com/${REPO_SLUG}/pulls"

tg_send "$MSG"
