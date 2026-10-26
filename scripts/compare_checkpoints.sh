#!/usr/bin/env bash
# Diff two phone-library checkpoints (JSON from Archie receiver).
# Usage:
#   ./scripts/compare_checkpoints.sh [before.json] [after.json]
# Defaults: baseline.json → latest.json under Application Support/Archie/checkpoints
set -euo pipefail

CKPT_DIR="${HOME}/Library/Application Support/Archie/checkpoints"
BEFORE="${1:-${CKPT_DIR}/baseline.json}"
AFTER="${2:-${CKPT_DIR}/latest.json}"

if [[ ! -f "${BEFORE}" ]]; then
  echo "error: missing before checkpoint: ${BEFORE}" >&2
  exit 1
fi
if [[ ! -f "${AFTER}" ]]; then
  echo "error: missing after checkpoint: ${AFTER}" >&2
  exit 1
fi

python3 - "$BEFORE" "$AFTER" <<'PY'
import json, sys
from pathlib import Path

before = json.loads(Path(sys.argv[1]).read_text())
after = json.loads(Path(sys.argv[2]).read_text())
b = set(before.get('assetIds') or [])
a = set(after.get('assetIds') or [])
removed = sorted(b - a)
added = sorted(a - b)
bc = before.get('assetCount', len(b))
ac = after.get('assetCount', len(a))
print('before', before.get('label'), before.get('deviceName'), bc, before.get('createdAt'))
print('after ', after.get('label'), after.get('deviceName'), ac, after.get('createdAt'))
print('removed', len(removed))
print('added  ', len(added))
print('net    ', ac - bc)
print()
print('Expect: phone removed ≈ assets deleted on phone after import.')
print('        Protected retained assets stay on phone and will not appear in removed.')
if removed and len(removed) <= 20:
    print('removed ids:')
    for i in removed:
        print(' ', i)
elif removed:
    print('removed ids: (showing 10 of %d)' % len(removed))
    for i in removed[:10]:
        print(' ', i)
PY
