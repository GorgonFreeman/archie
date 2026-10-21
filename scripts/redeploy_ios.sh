#!/usr/bin/env bash
# Build Archie for a connected iPhone and install it.
# Usage: ./scripts/redeploy_ios.sh
# Env:
#   ARCHIE_DEVELOPMENT_TEAM  Apple team id (default: 3RA377US5A)
#   ARCHIE_DEVICE            Device UDID or name (default: first connected iPhone)
#   ARCHIE_DERIVED_DATA      DerivedData path (default: /tmp/archie-dd)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARCHIE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ARCHIE_ROOT}/Apps/Archie.xcodeproj"
SCHEME="Archie"
TEAM="${ARCHIE_DEVELOPMENT_TEAM:-3RA377US5A}"
DERIVED="${ARCHIE_DERIVED_DATA:-/tmp/archie-dd}"
BUNDLE_ID="com.manuscanis.archie"

die() {
  echo "error: $*" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing $1"
}

require xcodebuild
require xcrun

pick_device() {
  if [[ -n "${ARCHIE_DEVICE:-}" ]]; then
    echo "${ARCHIE_DEVICE}"
    return
  fi

  # Physical iPhone lines look like: Name (17.5.1) (00008030-…)
  # Macs are a single UUID paren and must be skipped.
  local line udid
  line="$(
    xcrun xctrace list devices 2>/dev/null \
      | awk '
          /^== Devices ==$/ { in_dev=1; next }
          /^== Simulators ==$/ { in_dev=0 }
          in_dev && /\([0-9]+\.[0-9][^)]*\) \([0-9A-Fa-f-]{20,}\)/ {
            print
            exit
          }
        '
  )"
  [[ -n "${line}" ]] || die "no connected iPhone — plug in, unlock, and trust this Mac"

  udid="$(echo "${line}" | sed -n 's/.*(\([0-9A-Fa-f-]\{20,\}\))$/\1/p')"
  [[ -n "${udid}" ]] || die "could not parse device UDID from: ${line}"
  echo "${udid}"
}

device_name_for() {
  local id="$1"
  xcrun xctrace list devices 2>/dev/null \
    | awk -v id="${id}" '
        index($0, "(" id ")") {
          sub(/ \([0-9]+\.[0-9][^)]*\) \([^)]+\)$/, "")
          print
          exit
        }
      '
}

DEVICE_ID="$(pick_device)"
DEVICE_NAME="$(device_name_for "${DEVICE_ID}")"
DEVICE_NAME="${DEVICE_NAME:-${DEVICE_ID}}"

echo "device: ${DEVICE_NAME} (${DEVICE_ID})"
echo "team:   ${TEAM}"
echo "building…"

mkdir -p "${DERIVED}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${TEAM}" \
  -derivedDataPath "${DERIVED}" \
  -quiet \
  build

APP="$(
  find "${DERIVED}/Build/Products" -name 'Archie.app' -type d 2>/dev/null \
    | grep -v 'iphonesimulator' \
    | head -1
)"
[[ -n "${APP}" && -d "${APP}" ]] || die "Archie.app not found under ${DERIVED}/Build/Products"

echo "installing ${APP}…"
xcrun devicectl device install app \
  --device "${DEVICE_ID}" \
  "${APP}"

echo "launching ${BUNDLE_ID}…"
xcrun devicectl device process launch \
  --device "${DEVICE_ID}" \
  "${BUNDLE_ID}" \
  >/dev/null 2>&1 || echo "(installed; open Archie on the phone if launch was blocked)"

echo "redeployed ✓  unlock the phone if Photos/network prompts appear"
