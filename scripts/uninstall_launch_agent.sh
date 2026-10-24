#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WATCH_LABEL="com.manuscanis.archie.iphone_receiver"
MENU_LABEL="com.manuscanis.archie.menubar"

"${SCRIPT_DIR}/watch_iphone_receiver.sh" --stop 2>/dev/null || true

for label in "${WATCH_LABEL}" "${MENU_LABEL}"; do
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  rm -f "${HOME}/Library/LaunchAgents/${label}.plist"
done

pkill -f '/\.build/.*/archie-menubar$' 2>/dev/null || true
pkill -f 'Archie Menu.app/Contents/MacOS/archie-menubar' 2>/dev/null || true
rm -rf \
  "${HOME}/Applications/Archie Menu.app" \
  "${HOME}/Library/Application Support/Archie/Archie Menu.app"
echo "Removed Archie LaunchAgents (USB watcher + menu bar)"
