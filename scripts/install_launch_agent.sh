#!/usr/bin/env bash
# Install LaunchAgents: USB watcher + menu bar PIN display.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WATCH_SCRIPT="${SCRIPT_DIR}/watch_iphone_receiver.sh"
DETECT_SCRIPT="${SCRIPT_DIR}/iphone_usb_connected.sh"
WATCH_LABEL="com.manuscanis.archie.iphone_receiver"
MENU_LABEL="com.manuscanis.archie.menubar"
WATCH_PLIST="${HOME}/Library/LaunchAgents/${WATCH_LABEL}.plist"
MENU_PLIST="${HOME}/Library/LaunchAgents/${MENU_LABEL}.plist"
LOG_DIR="${HOME}/Library/Logs/archie"
ARCHIVE="${ARCHIE_ARCHIVE:-${HOME}/Pictures/ArchieArchive}"
APP_DIR="${HOME}/Library/Application Support/Archie/Archie Menu.app"
MENUBAR_EXEC="${APP_DIR}/Contents/MacOS/archie-menubar"

chmod +x \
  "${WATCH_SCRIPT}" \
  "${DETECT_SCRIPT}" \
  "${SCRIPT_DIR}/install_launch_agent.sh" \
  "${SCRIPT_DIR}/uninstall_launch_agent.sh"

mkdir -p "${LOG_DIR}" "$(dirname "${WATCH_PLIST}")" "${ARCHIVE}"

echo "Building release binaries…"
(
  cd "${ARCHIE_ROOT}"
  /usr/bin/swift build -c release --product archie-receiver
  /usr/bin/swift build -c release --product archie-menubar
)

echo "Packaging menu bar app…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${ARCHIE_ROOT}/.build/release/archie-menubar" "${MENUBAR_EXEC}"
chmod +x "${MENUBAR_EXEC}"
cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Archie Menu</string>
  <key>CFBundleDisplayName</key>
  <string>Archie Menu</string>
  <key>CFBundleIdentifier</key>
  <string>com.manuscanis.archie.menubar</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleExecutable</key>
  <string>archie-menubar</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF

cat > "${WATCH_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${WATCH_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${WATCH_SCRIPT}</string>
    <string>--once</string>
  </array>
  <key>StartInterval</key>
  <integer>5</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>AbandonProcessGroup</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/launchd.stderr.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin</string>
    <key>ARCHIE_ARCHIVE</key>
    <string>${ARCHIVE}</string>
  </dict>
</dict>
</plist>
EOF

cat > "${MENU_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${MENU_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${MENUBAR_EXEC}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/menubar.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/menubar.stderr.log</string>
</dict>
</plist>
EOF

for label in "${WATCH_LABEL}" "${MENU_LABEL}"; do
  launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
done
pkill -f 'Archie Menu.app/Contents/MacOS/archie-menubar' 2>/dev/null || true
pkill -f '/\.build/.*/archie-menubar$' 2>/dev/null || true

launchctl bootstrap "gui/$(id -u)" "${WATCH_PLIST}"
launchctl enable "gui/$(id -u)/${WATCH_LABEL}"
launchctl bootstrap "gui/$(id -u)" "${MENU_PLIST}"
launchctl enable "gui/$(id -u)/${MENU_LABEL}"

echo "Installed:"
echo "  ${WATCH_PLIST}"
echo "  ${MENU_PLIST}"
echo "Menu bar app: ${APP_DIR}"
echo 'Look for Archie near the clock, or the menu bar overflow chevron.'
echo "Uninstall: ${SCRIPT_DIR}/uninstall_launch_agent.sh"
