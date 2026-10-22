# Operation

## Day to day

1. Plug in iPhone (or `pnpm start`) — Mac receiver runs; note the PIN (notification / menu bar / `pnpm status`).
2. Open Archie on the phone, enter PIN.
3. **Import** — copy library to Mac; **Delete Verified** when ready. Pauses before the newest month.
4. **Scan leftovers** — verify archive on Mac, queue matching phone assets for **Delete Verified**.

`pnpm stop` / `pnpm status` as needed.

## When you change code

| Change | Update |
| --- | --- |
| iOS app (`Apps/Archie`, shared `Sources/ArchieCore` used by phone) | `pnpm redeploy` (phone unlocked) |
| Mac receiver / protocol (`ArchieReceiver`, `ArchieCore`) | `pnpm start` (rebuilds + restarts) |
| Menu bar / USB auto-start | `./scripts/install_launch_agent.sh` |

Redeploy does **not** restart the Mac receiver. Start does **not** update the phone app.
