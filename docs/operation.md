# Operation

## Day to day

1. Plug in iPhone (or `pnpm start`) — Mac receiver runs; note the PIN (notification / menu bar / `pnpm status`).
2. Open Archie on the phone, enter PIN. Imports write to `~/Pictures/ArchieArchive/<device name>/` (the phone’s name). Legacy files left flat under `ArchieArchive/` are still seen for skip/scan.
3. Optional **Checkpoint** — snapshots every phone asset ID to `~/Library/Application Support/Archie/checkpoints/` (`baseline.json`). Import also writes `pre-import` / `post-import` automatically. Compare with `pnpm compare-checkpoints`.
4. **Import** — copy library to Mac; **Delete Verified** when ready. Keep Archie in the foreground (backgrounding auto-pauses). If the cable drops, setup fails (connect / settled IDs / protected-seen / recent-seen), or the link dies: tap orange **Reconnect** (mid-run continues; after a failed setup it starts fresh). Assets already settled on the Mac are skipped when that list loads. **Protect last 30 days** (default on) keeps recent imports on the phone; they are tracked in `.recent_seen_log` and queued for Delete Verified once older than 30 days. Protected-seen (favourites/albums) assets are also skipped. After pulling protocol changes, `pnpm start` the Mac receiver and `pnpm redeploy` the phone.
5. **Scan leftovers** — verify archive on Mac, queue matching phone assets for **Delete Verified**.

`pnpm stop` / `pnpm status` as needed.

## When you change code

| Change | Update |
| --- | --- |
| iOS app (`Apps/Archie`, shared `Sources/ArchieCore` used by phone) | `pnpm redeploy` (phone unlocked) |
| Mac receiver / protocol (`ArchieReceiver`, `ArchieCore`) | `pnpm start` (rebuilds + restarts) |
| Menu bar / USB auto-start | `./scripts/install_launch_agent.sh` |

Redeploy does **not** restart the Mac receiver. Start does **not** update the phone app.
