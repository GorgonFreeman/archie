# Clobber audit (archive writes)

Goal: **never replace** existing media or foreign sidecar bytes. Prefer fail/retain over overwrite.

## Verdict (after hardening)

| Path | Media replace? | Sidecar replace? |
| --- | --- | --- |
| `AtomicWriter` publish | No (`moveItem` + re-unique + archive lock) | — |
| `AtomicWriter.abort` | No (only deletes tmp; never deletes unpublished final) | — |
| `AssetRenamer` media moves | No (`moveItem` fails if dest exists) | — |
| `AssetRenamer` new sidecar path | No (preflight + tmp/`moveItem`) | — |
| `AssetRenamer` same-path sidecar rewrite | — | Own sidecar only (intentional) |
| `chive_archive.js` renames | No (`link`+`unlink` via `renameNoClobber`) | Same |
| `ManifestStore` | N/A (jsonl only) | — |

## Remaining residual risks (not silent photo clobber)

1. **Lock is PID-file based** (not `flock`): a crashed holder is cleared; two processes could still race in theory. Mitigated by Swift `moveItem` / Node `linkSync` refusing occupied dests.
2. **Upstream `chive/renamer.js`** (invoked by backlog) may still use POSIX `rename` for some sidecar types (e.g. `.aae`). Prefer not running backlog while the receiver is live; stop receiver first.
3. **Manifest `jsonl` full rewrite** can lose concurrent appends across processes — index only, not photo bytes.
4. **Phone delete** after settle is intentional removal from the library (Recently Deleted), not archive clobber.

## Fixes applied in this pass

- Settle: refuse existing sidecar dest before moves; publish sidecar via tmp + `moveItem`.
- Ingest: re-unique if dest appeared; take archive lock around publish; `abort` never deletes a path we did not publish.
- Backlog: `renameNoClobber` (`linkSync` + `unlinkSync`); bad JSON quarantined under a unique name (never onto `<media>.asset.json`).
