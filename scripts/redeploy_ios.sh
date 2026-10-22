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
BUILD_LOG="${DERIVED}/archie-build.log"

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
echo "building… (log: ${BUILD_LOG})"

mkdir -p "${DERIVED}"
# Capture full log; -quiet hides progress but we dump the tail on failure.
if ! xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "platform=iOS,id=${DEVICE_ID}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="${TEAM}" \
  -derivedDataPath "${DERIVED}" \
  -quiet \
  build >"${BUILD_LOG}" 2>&1
then
  echo "error: xcodebuild failed — last 80 lines of ${BUILD_LOG}:" >&2
  tail -n 80 "${BUILD_LOG}" >&2 || true
  exit 1
fi

APP="${DERIVED}/Build/Products/Debug-iphoneos/Archie.app"
if [[ ! -d "${APP}" ]]; then
  # Fallback if configuration name differs.
  APP="$(
    find "${DERIVED}/Build/Products" -path '*iphoneos*/Archie.app' -type d 2>/dev/null \
      | head -1
  )"
fi
[[ -n "${APP}" && -d "${APP}" ]] || die "Archie.app not found under ${DERIVED}/Build/Products (see ${BUILD_LOG})"

echo "installing ${APP}…"
if ! xcrun devicectl device install app \
  --device "${DEVICE_ID}" \
  "${APP}"
then
  die "install failed — unlock the phone, trust this Mac, and retry"
fi

echo "launching ${BUNDLE_ID}…"
if ! xcrun devicectl device process launch \
  --device "${DEVICE_ID}" \
  "${BUNDLE_ID}"
then
  echo "warning: launch failed — open Archie on the phone (unlock if locked)" >&2
fi

echo "redeployed ✓  unlock the phone if Photos/network prompts appear"
