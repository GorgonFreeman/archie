# Phone library checkpoints

Archie can snapshot every `PHAsset.localIdentifier` on the phone and save it on the Mac:

`~/Library/Application Support/Archie/checkpoints/`

| File | Meaning |
| --- | --- |
| `baseline.json` | Manual **Checkpoint** button (use before a delete pass) |
| `checkpoint-pre-import-*.json` | Auto at Import start |
| `checkpoint-post-import-*.json` | Auto at Import end (after delete flush) |
| `latest.json` | Most recent snapshot |
| `latest_summary.json` | Count/path only (no ID list) |

Compare:

```bash
./scripts/compare_checkpoints.sh
# or
./scripts/compare_checkpoints.sh \
  ~/Library/Application\ Support/Archie/checkpoints/baseline.json \
  ~/Library/Application\ Support/Archie/checkpoints/latest.json
```

Healthy delete pass: `removed` ≈ assets deleted from Photos (protected items stay and are not in `removed`).
