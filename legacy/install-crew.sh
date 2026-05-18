#!/usr/bin/env bash
# install-crew.sh — install (or uninstall) KRI overnight crew launchd agents
#
# Usage:
#   bash scripts/automation/install-crew.sh              # install / reload
#   bash scripts/automation/install-crew.sh --uninstall  # stop + remove plists
#
# Plists are generated at install time from REPO_DIR and HOME so the scripts
# work regardless of clone path or username.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPTS_DIR="${REPO_DIR}/scripts/automation"
LAUNCH_AGENTS="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/kri-crew"
PLAN_DIR="${HOME}/.kri-crew"

AGENTS=(
  "ai.velo9.kri-codex-sweeper"
  "ai.velo9.kri-evening-qa"
  "ai.velo9.kri-overnight-build"
  "ai.velo9.kri-morning-summary"
)

UNINSTALL=false
for arg in "$@"; do
  [[ "$arg" == "--uninstall" ]] && UNINSTALL=true
done

# ── Uninstall ─────────────────────────────────────────────────────────────────
if $UNINSTALL; then
  echo "Uninstalling KRI crew launchd agents..."
  for agent in "${AGENTS[@]}"; do
    PLIST="${LAUNCH_AGENTS}/${agent}.plist"
    # Try by plist path first, then by label — handles the case where the plist
    # was manually deleted or moved while the job is still registered with launchd.
    if [[ -f "$PLIST" ]]; then
      launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null \
        && echo "  unloaded (plist): ${agent}" || true
      rm -f "$PLIST"
      echo "  removed: ${agent}.plist"
    else
      launchctl bootout "gui/$(id -u)/${agent}" 2>/dev/null \
        && echo "  unloaded (label): ${agent}" \
        || echo "  not loaded: ${agent}"
    fi
  done
  echo "Done. Log files remain in ${LOG_DIR}/"
  exit 0
fi

echo "Installing KRI overnight crew into ~/Library/LaunchAgents/..."
echo "Repo:    ${REPO_DIR}"
echo "Scripts: ${SCRIPTS_DIR}"
echo ""

# ── Velocity check ────────────────────────────────────────────────────────────
# Notifications are delivered via velocity's Telegram integration. No separate
# Telegram credentials are needed in this repo — the scripts call
# cos.integrations.telegram_bot.send_message() directly from velocity's venv.
VELOCITY_DIR="${HOME}/Developer/velo9-dev/velocity"
if [[ -d "$VELOCITY_DIR" ]]; then
  echo "Velocity found at ${VELOCITY_DIR} — notifications will route through it."
else
  echo "WARNING: ${VELOCITY_DIR} not found. Telegram notifications will be silently skipped."
fi

# ── Directory setup ───────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR" "$PLAN_DIR" "$LAUNCH_AGENTS"
chmod +x "${SCRIPTS_DIR}/"*.sh

# ── Plist generation ──────────────────────────────────────────────────────────
# Generate each plist at install time from REPO_DIR and HOME so paths are
# correct for any clone location or username.
#
# Args: $1=agent-label-suffix  $2=script-filename  $3=hour  $4=minute
#       $5=log-prefix  (e.g. "sweeper")  $6=weekdays (space-separated, default "1 2 3 4 5")
generate_plist() {
  local label="ai.velo9.$1"
  local script="${SCRIPTS_DIR}/$2"
  local hour="$3"
  local minute="$4"
  local log_prefix="$5"
  local weekdays="${6:-1 2 3 4 5}"

  # Build StartCalendarInterval entries for each requested weekday
  local intervals=""
  for d in $weekdays; do
    intervals="${intervals}    <dict><key>Weekday</key><integer>${d}</integer><key>Hour</key><integer>${hour}</integer><key>Minute</key><integer>${minute}</integer></dict>
"
  done

  cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${script}</string>
  </array>

  <key>StartCalendarInterval</key>
  <array>
${intervals}  </array>

  <key>StandardOutPath</key>
  <string>${LOG_DIR}/${log_prefix}-launchd.out</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/${log_prefix}-launchd.err</string>

  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>${HOME}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key>
    <string>${HOME}</string>
  </dict>

  <key>KeepAlive</key>
  <false/>

  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
PLIST_EOF
}

# ── Install each agent ────────────────────────────────────────────────────────
FAILED=0

install_agent() {
  local suffix="$1" script="$2" hour="$3" minute="$4" log_prefix="$5" weekdays="${6:-}"
  local agent="ai.velo9.${suffix}"
  local dst="${LAUNCH_AGENTS}/${agent}.plist"

  # Unload if already loaded (by plist path, ignore errors)
  launchctl bootout "gui/$(id -u)" "$dst" 2>/dev/null || true

  generate_plist "$suffix" "$script" "$hour" "$minute" "$log_prefix" "$weekdays" > "$dst"

  if launchctl bootstrap "gui/$(id -u)" "$dst"; then
    echo "  loaded: ${agent}"
  else
    echo "  FAILED to load: ${agent}"
    FAILED=$(( FAILED + 1 ))
  fi
}

install_agent "kri-codex-sweeper"   "kri-codex-sweeper.sh"   6  30 "sweeper"
install_agent "kri-evening-qa"      "kri-evening-qa.sh"      18  0 "evening-qa"      "0 1 2 3 4"
install_agent "kri-overnight-build" "kri-overnight-build.sh" 23 30 "overnight"
install_agent "kri-morning-summary" "kri-morning-summary.sh"  7  0 "morning-summary"

echo ""
echo "Verify with:  launchctl list | grep 'velo9'"
echo "Logs:         ${LOG_DIR}/"
echo "Plans:        ${PLAN_DIR}/"
echo ""
echo "Schedule:"
echo "  6:30am weekdays  — kri-codex-sweeper  (bug fixes)"
echo "  6:00pm Sun–Thu   — kri-evening-qa     (plan tonight's builds)"
echo " 11:30pm weekdays  — kri-overnight-build (crew builds)"
echo "  7:00am weekdays  — kri-morning-summary (digest)"
echo ""
echo "To cancel tonight's overnight run: touch ~/.kri-crew/cancel-tonight"

if [[ "$FAILED" -gt 0 ]]; then
  echo ""
  echo "ERROR: ${FAILED} agent(s) failed to load. Run 'launchctl error <code>' for details." >&2
  exit 1
fi
