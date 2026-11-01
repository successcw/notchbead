#!/bin/bash
# Install (or reinstall) the tokenboard launchd agent for the current user.
#
#   scripts/install.sh
#   TB_LABEL=com.tokenboard.test TB_PORT=8798 TOKENBOARD_DB=/tmp/tb.db scripts/install.sh
#
# Env overrides: TB_LABEL (default com.tokenboard.server), TB_PORT (default 8787),
# TOKENBOARD_DB (passed into the agent when set), TB_PYTHON (default: python3 on PATH).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LABEL="${TB_LABEL:-com.tokenboard.server}"
PORT="${TB_PORT:-8787}"
AGENT_DIR="${HOME}/Library/LaunchAgents"
PLIST="${AGENT_DIR}/${LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/tokenboard"
LOG_FILE="${LOG_DIR}/${LABEL}.log"
LAUNCHD_DOMAIN="gui/$(id -u)"
DEFAULT_DB="${HOME}/Library/Application Support/tokenboard/usage.db"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

xml_escape() {
  # Escape &, <, > and quotes so arbitrary paths stay valid plist strings.
  local text="$1"
  text="${text//&/&amp;}"
  text="${text//</&lt;}"
  text="${text//>/&gt;}"
  text="${text//\"/&quot;}"
  printf '%s' "${text}"
}

# -- validate the inputs ----------------------------------------------------
# Digits only first: a 20-digit value like 99999999999999999999 overflows shell
# integer arithmetic, so it must be rejected by length before any numeric test.
case "${PORT}" in
  ''|*[!0-9]*) die "TB_PORT must be digits only (1-65535), got '${PORT}'" ;;
esac
if [ "${#PORT}" -gt 5 ]; then
  die "TB_PORT must be between 1 and 65535, got '${PORT}' (${#PORT} digits)"
fi
PORT="$((10#${PORT}))"  # safe: at most five digits, and 10# keeps 00080 as 80
if [ "${PORT}" -lt 1 ] || [ "${PORT}" -gt 65535 ]; then
  die "TB_PORT must be between 1 and 65535, got '${PORT}'"
fi
case "${LABEL}" in
  *[!A-Za-z0-9._-]*) die "TB_LABEL may only contain letters, digits, '.', '_' and '-', got '${LABEL}'" ;;
esac

# -- resolve python3 (absolute, >= 3.13) ------------------------------------
RAW_PYTHON="${TB_PYTHON:-$(command -v python3 || true)}"
[ -n "${RAW_PYTHON}" ] || die "python3 not found on PATH; install Python 3.13+ first"
[ -x "${RAW_PYTHON}" ] || die "python3 at '${RAW_PYTHON}' is not executable"
PYTHON_BIN="$("${RAW_PYTHON}" -c 'import sys; print(sys.executable)' 2>/dev/null || true)"
[ -n "${PYTHON_BIN}" ] || die "could not resolve the real path of '${RAW_PYTHON}'"
[ -x "${PYTHON_BIN}" ] || die "resolved python3 '${PYTHON_BIN}' is not executable"

VERSION="$("${PYTHON_BIN}" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
if ! "${PYTHON_BIN}" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 13) else 1)'; then
  die "tokenboard needs Python >= 3.13, but '${PYTHON_BIN}' is ${VERSION}. Install a newer python3 or set TB_PYTHON=/path/to/python3.13"
fi

# -- sanity checks ---------------------------------------------------------
( cd "${REPO_ROOT}" && "${PYTHON_BIN}" -c 'import tokenboard' ) \
  || die "cannot import the tokenboard package from '${REPO_ROOT}' with '${PYTHON_BIN}'"

if ! command -v zstd >/dev/null 2>&1; then
  printf 'warning: zstd not found on PATH — codex archived sessions (*.jsonl.zst) will be skipped.\n' >&2
  printf 'warning: install it with `brew install zstd` and re-run this script if you want that history.\n' >&2
else
  info "zstd: $(command -v zstd)"
fi

info "repo:   ${REPO_ROOT}"
info "python: ${PYTHON_BIN} (${VERSION})"
info "label:  ${LABEL}"
info "port:   ${PORT}"
if [ -n "${TOKENBOARD_DB:-}" ]; then
  info "db:     ${TOKENBOARD_DB}"
else
  info "db:     ${DEFAULT_DB} (default)"
fi

# -- stop an existing agent so the new plist replaces it --------------------
mkdir -p "${AGENT_DIR}" "${LOG_DIR}"

agent_loaded() {
  launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1
}

# Probe the port and classify the result. Only real listeners count: without
# -sTCP:LISTEN an outgoing connection to a *remote* port would match too.
#
# lsof exits 1 both for "no matching file" AND for several errors (see `man
# lsof`, DIAGNOSTICS), so rc=1 alone does not prove the port is free. Both
# streams are captured and rc=1 means "no listener" only when they are empty.
#
# Sets: PORT_STATUS = free | busy | error
#       PORT_PIDS   = space separated pids (busy)
#       PORT_DIAG   = human readable reason (error)
probe_port() {
  local out_file err_file rc=0 stderr_text
  PORT_STATUS="error"
  PORT_PIDS=""
  PORT_DIAG=""
  out_file="$(mktemp "${TMPDIR:-/tmp}/tokenboard-lsof-out.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/tokenboard-lsof-err.XXXXXX")"
  lsof -nP -tiTCP:"${PORT}" -sTCP:LISTEN >"${out_file}" 2>"${err_file}" || rc=$?
  PORT_PIDS="$(tr '\n' ' ' <"${out_file}" | sed -e 's/^ *//' -e 's/ *$//')"
  stderr_text="$(head -n 3 "${err_file}" | tr '\n' ' ' | sed -e 's/ *$//')"
  rm -f "${out_file}" "${err_file}"

  # Any stderr output means lsof could not complete cleanly, so the result is
  # untrustworthy - even when it also printed a pid: a partial listing can omit
  # our own job and make the ownership check believe the port belongs to
  # someone else. Classify that before looking at the exit code.
  if [ -n "${stderr_text}" ]; then
    PORT_DIAG="lsof printed diagnostics (exit ${rc})${PORT_PIDS:+; partial pids: ${PORT_PIDS}}; stderr: ${stderr_text}"
    return 0
  fi

  case "${rc}" in
    0)
      if [ -n "${PORT_PIDS}" ]; then
        PORT_STATUS="busy"
      else
        PORT_DIAG="lsof exited 0 but listed no pid"
      fi
      ;;
    1)
      PORT_STATUS="free"
      ;;
    *)
      PORT_DIAG="lsof exited ${rc} with no diagnostic output"
      ;;
  esac
}

assert_port_free() {
  local context="$1"
  probe_port
  case "${PORT_STATUS}" in
    free)
      return 0
      ;;
    busy)
      die "port ${PORT} is already used by another listener (pid ${PORT_PIDS}); stop it or pick TB_PORT=... [${context}]"
      ;;
    *)
      die "cannot tell whether port ${PORT} is free (${PORT_DIAG}); aborting before touching launchd [${context}]"
      ;;
  esac
}

# Classify the port before any launchctl call at all: a broken probe must not
# even ask launchd a question, let alone mutate it.
probe_port
if [ "${PORT_STATUS}" = "error" ]; then
  die "cannot tell whether port ${PORT} is free (${PORT_DIAG}); aborting before touching launchd [before install]"
fi

PORT_CHECK_CONTEXT="before install"
if agent_loaded; then
  PORT_CHECK_CONTEXT="after bootout"
  # The agent we are about to replace may hold the port itself; verify the
  # listener really is our job before booting anything out.
  AGENT_PID="$(launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" 2>/dev/null \
    | awk '/^[[:space:]]*pid = /{print $3; exit}')" || AGENT_PID=""
  probe_port
  case "${PORT_STATUS}" in
    busy)
      if [ -z "${AGENT_PID}" ]; then
        die "port ${PORT} is held by pid ${PORT_PIDS} but ${LABEL} has no pid; refusing to stop it"
      fi
      case " ${PORT_PIDS} " in
        *" ${AGENT_PID} "*) : ;;  # our own agent: safe to replace
        *)
          die "port ${PORT} is held by pid ${PORT_PIDS}, not by ${LABEL} (pid ${AGENT_PID})"
          ;;
      esac
      ;;
    free)
      : ;;  # agent loaded but not listening yet
    *)
      die "cannot tell whether port ${PORT} is free (${PORT_DIAG}); aborting before touching launchd"
      ;;
  esac

  info "stopping the running agent before reinstalling…"
  launchctl bootout "${LAUNCHD_DOMAIN}/${LABEL}" >/dev/null 2>&1 || true
  # bootout is asynchronous; give launchd a moment to release the port.
  for _ in $(seq 1 20); do
    agent_loaded || break
    sleep 0.25
  done
fi

# Checked again after the bootout: the port must really be free before we write
# a plist that launchd would immediately start into an occupied port.
assert_port_free "${PORT_CHECK_CONTEXT}"

# -- write the plist -------------------------------------------------------
ENV_ENTRIES="
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>PYTHONDONTWRITEBYTECODE</key>
    <string>1</string>"
if [ -n "${TOKENBOARD_DB:-}" ]; then
  ENV_ENTRIES="${ENV_ENTRIES}
    <key>TOKENBOARD_DB</key>
    <string>$(xml_escape "${TOKENBOARD_DB}")</string>"
fi

cat > "${PLIST}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "${LABEL}")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${PYTHON_BIN}")</string>
    <string>-m</string>
    <string>tokenboard</string>
    <string>serve</string>
    <string>--port</string>
    <string>${PORT}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "${REPO_ROOT}")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>30</integer>
  <key>StandardOutPath</key>
  <string>$(xml_escape "${LOG_FILE}")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "${LOG_FILE}")</string>
  <key>EnvironmentVariables</key>
  <dict>${ENV_ENTRIES}
  </dict>
</dict>
</plist>
PLIST_EOF

plutil -lint "${PLIST}" >/dev/null || die "generated plist is invalid: ${PLIST}"

if ! launchctl bootstrap "${LAUNCHD_DOMAIN}" "${PLIST}"; then
  printf 'error: launchctl bootstrap failed for %s\n' "${PLIST}" >&2
  [ -f "${LOG_FILE}" ] && tail -n 40 "${LOG_FILE}" >&2
  exit 1
fi

# -- wait until the HTTP API answers ---------------------------------------
URL="http://127.0.0.1:${PORT}/"
META_URL="${URL}api/meta"
HEALTHY=0
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "${META_URL}" 2>/dev/null | grep -q '"sources"'; then
    HEALTHY=1
    break
  fi
  sleep 1
done

if [ "${HEALTHY}" -ne 1 ]; then
  printf 'error: %s did not answer within 60s\n' "${META_URL}" >&2
  printf -- '--- %s (last 40 lines) ---\n' "${LOG_FILE}" >&2
  [ -f "${LOG_FILE}" ] && tail -n 40 "${LOG_FILE}" >&2
  printf -- '--- launchctl print ---\n' >&2
  launchctl print "${LAUNCHD_DOMAIN}/${LABEL}" >&2 2>&1 || true
  exit 1
fi

info ""
info "tokenboard is running: ${URL}"
info "meta: $(curl -fsS --max-time 5 "${META_URL}")"
info "log:  ${LOG_FILE}"
info "stop: launchctl bootout ${LAUNCHD_DOMAIN}/${LABEL}   (or scripts/uninstall.sh)"
