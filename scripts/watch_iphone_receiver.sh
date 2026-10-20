#!/usr/bin/env bash
# Start archie-receiver while an iPhone is on USB; stop it when unplugged.
# Intended to be invoked by LaunchAgent with --once every few seconds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${HOME}/Library/Application Support/Archie"
LOG_DIR="${HOME}/Library/Logs/archie"
PIN_FILE="${STATE_DIR}/current_pin.txt"
PID_FILE="${STATE_DIR}/receiver.pid"
ARCHIVE="${ARCHIE_ARCHIVE:-${HOME}/Pictures/ArchieArchive}"
DETECT="${SCRIPT_DIR}/iphone_usb_connected.sh"

mkdir -p "${STATE_DIR}" "${LOG_DIR}" "${ARCHIVE}"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "${LOG_DIR}/watch.log"
}

receiver_bin() {
  local release debug
  release="${ARCHIE_ROOT}/.build/release/archie-receiver"
  debug="${ARCHIE_ROOT}/.build/debug/archie-receiver"
  if [[ -x "${release}" ]]; then
    echo "${release}"
    return
  fi
  if [[ -x "${debug}" ]]; then
    echo "${debug}"
    return
  fi
  return 1
}

ensure_built() {
  if receiver_bin >/dev/null; then
    return 0
  fi
  log "building archie-receiver (release)"
  (
    cd "${ARCHIE_ROOT}"
    /usr/bin/swift build -c release --product archie-receiver
  ) >> "${LOG_DIR}/build.log" 2>&1
}

receiver_running() {
  if [[ ! -f "${PID_FILE}" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  rm -f "${PID_FILE}"
  return 1
}

notify_pin() {
  local pin="$1"
  /usr/bin/osascript -e "display notification \"PIN ${pin}\" with title \"Archie\" subtitle \"iPhone connected — receiver ready\"" 2>/dev/null || true
}

start_receiver() {
  ensure_built
  local bin
  bin="$(receiver_bin)" || {
    log "error: archie-receiver binary missing after build"
    return 1
  }

  rm -f "${PIN_FILE}"
  log "starting ${bin} -> ${ARCHIVE}"
  # Launch detached; PIN is written by the receiver to PIN_FILE.
  nohup "${bin}" "${ARCHIVE}" >> "${LOG_DIR}/receiver.log" 2>&1 &
  local pid=$!
  echo "${pid}" > "${PID_FILE}"

  # Wait briefly for PIN file.
  local i pin=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -f "${PIN_FILE}" ]]; then
      pin="$(tr -d '[:space:]' < "${PIN_FILE}")"
      break
    fi
    sleep 0.3
  done

  if [[ -n "${pin}" ]]; then
    log "PIN ${pin}"
    notify_pin "${pin}"
  else
    log "warning: PIN file not ready yet (pid ${pid})"
  fi
}

stop_receiver() {
  if [[ ! -f "${PID_FILE}" ]]; then
    return 0
  fi
  local pid
  pid="$(cat "${PID_FILE}")"
  if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
    log "stopping receiver pid ${pid}"
    kill "${pid}" 2>/dev/null || true
    # Give it a moment, then force if needed.
    sleep 0.5
    kill -0 "${pid}" 2>/dev/null && kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${PID_FILE}" "${PIN_FILE}"
}

once() {
  if "${DETECT}"; then
    if ! receiver_running; then
      start_receiver
    fi
  else
    if receiver_running; then
      stop_receiver
      log "iPhone disconnected — receiver stopped"
    fi
  fi
}

case "${1:-}" in
  --once|"")
    once
    ;;
  --start)
    start_receiver
    ;;
  --stop)
    stop_receiver
    ;;
  --status)
    if "${DETECT}"; then
      echo "iphone: connected"
    else
      echo "iphone: not connected"
    fi
    if receiver_running; then
      echo "receiver: running pid $(cat "${PID_FILE}")"
      if [[ -f "${PIN_FILE}" ]]; then
        echo "pin: $(tr -d '[:space:]' < "${PIN_FILE}")"
      fi
    else
      echo "receiver: stopped"
    fi
    ;;
  *)
    echo "usage: $0 [--once|--start|--stop|--status]" >&2
    exit 1
    ;;
esac
