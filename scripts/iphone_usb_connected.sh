#!/usr/bin/env bash
# Exit 0 if an iPhone is on the USB bus, 1 otherwise.
set -euo pipefail

if ioreg -p IOUSB -l -w0 2>/dev/null | grep -qiE 'iPhone'; then
  exit 0
fi

# Fallback — some macOS versions expose product name differently.
if system_profiler SPUSBDataType 2>/dev/null | grep -q 'iPhone'; then
  exit 0
fi

exit 1
