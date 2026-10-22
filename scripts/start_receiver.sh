#!/usr/bin/env bash
# Build (release) and start the Mac receiver; print PIN.
# Usage: ./scripts/start_receiver.sh
# Env:
#   ARCHIE_ARCHIVE  Archive directory (default: ~/Pictures/ArchieArchive)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCH="${SCRIPT_DIR}/watch_iphone_receiver.sh"
STATE_DIR="${HOME}/Library/Application Support/Archie"
PIN_FILE="${STATE_DIR}/current_pin.txt"
LOG_DIR="${HOME}/Library/Logs/archie"

die() {
  echo "error: $*" >&2
  exit 1
}

echo "building archie-receiver (release)…"
(
  cd "${ARCHIE_ROOT}"
  /usr/bin/swift build -c release --product archie-receiver
) || die "swift build failed — see above"

echo "starting receiver…"
"${WATCH}" --start

# PIN may take a moment after fork.
pin=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if [[ -f "${PIN_FILE}" ]]; then
    pin="$(tr -d '[:space:]' < "${PIN_FILE}")"
    [[ -n "${pin}" ]] && break
  fi
  sleep 0.2
done

"${WATCH}" --status
if [[ -n "${pin}" ]]; then
  echo "PIN ${pin}"
else
  echo "warning: PIN not ready yet — check ${LOG_DIR}/receiver.log" >&2
fi
