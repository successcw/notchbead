#!/bin/bash
# Stop and remove the tokenboard launchd agent for the current user.
#
#   scripts/uninstall.sh
#   TB_LABEL=com.tokenboard.test scripts/uninstall.sh
#
# This never deletes your usage database or the service log: the DB is the
# long-term record that survives raw log rotation, so removing it is left to you.
set -euo pipefail

LABEL="${TB_LABEL:-com.tokenboard.server}"
AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST="${AGENT_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/tokenboard"
LOG_FILE="${LOG_DIR}/${LABEL}.log"
LAUNCHD_DOMAIN="gui/$(id -u)"
DEFAULT_DB="${HOME}/Library/Application Support/tokenboard/usage.db"

info() {
  printf '%s\n' "$*"
}

case "${LABEL}" in
  *[!A-Za-z0-9._-]*) printf 'error: invalid TB_LABEL %s\n' "${LABEL}" >&2; exit 1 ;;
esac

# Remember what the agent was actually pointed at before the plist goes away.
PLIST_DB=""
if [ -f "${PLIST}" ] && [ -x /usr/libexec/PlistBuddy ]; then
  PLIST_DB="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:TOKENBOARD_DB' "${PLIST}" 2>/dev/null || true)"
fi
DB_PATH="${TOKENBOARD_DB:-${PLIST_DB:-${DEFAULT_DB}}}"

info "label: ${LABEL}"

if launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  if launchctl bootout "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    info "stopped the running agent"
  else
    printf 'warning: launchctl bootout failed; the agent may still be running\n' >&2
  fi
  for _ in $(seq 1 20); do
    launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1 || break
    sleep 0.25
  done
else
  info "agent is not loaded (nothing to stop)"
fi

if [ -f "${PLIST}" ]; then
  rm -f "${PLIST}"
  info "removed ${PLIST}"
else
  info "no plist at ${PLIST}"
fi

# Also drop a stale definition that launchctl may remember by path.
launchctl remove "${LABEL}" >/dev/null 2>&1 || true

if launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  printf 'error: %s is still loaded after bootout\n' "${LABEL}" >&2
  exit 1
fi

info ""
info "kept on purpose (delete manually if you really want to):"
info "  database: ${DB_PATH}"
info "  log:      ${LOG_FILE}"
info "  logs dir: ${LOG_DIR}"
info ""
info "The database is the long-term usage record — agent logs rotate, this does not."
