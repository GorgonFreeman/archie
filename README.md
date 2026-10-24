# Archie

Copy photos and videos from an iPhone to a Mac. Verify each file with SHA-256, then delete from the phone only what was proven.

## Mac receiver

Writes **flat** into the archive root (no `YYYY/MM/` nesting).

```bash
pnpm start    # build release receiver, start it, print PIN
pnpm status
pnpm stop
```

### Start automatically when an iPhone is plugged in

```bash
./scripts/install_launch_agent.sh
```

Checks USB every 5s. On connect it starts the receiver, shows a notification with the PIN, and writes it to `~/Library/Application Support/Archie/current_pin.txt`. Unplugging stops the receiver.

Also installs a **menu bar** app (icon **A**): click for the PIN, Copy, or re-show the notification. The USB watcher still posts a PIN notification on connect.

```bash
./scripts/uninstall_launch_agent.sh
```

Override archive path with `ARCHIE_ARCHIVE=/path ./scripts/install_launch_agent.sh`.

### Date names

During import the Mac renames each verified asset to `YYYY-MM-DD_HHhMMmSSs` (one date for all resources) before acknowledging settle; the phone deletes only after that ack.

For an existing backlog of raw `IMG_…` names (stop the receiver first, or wait until it is idle):

```bash
node scripts/chive_archive.js ~/Pictures/ArchieArchive
```

Takes the same `.archie-archive.lock` as live settle. Uses each sidecar’s PhotoKit `creationDate` when present; otherwise runs sibling `chive/renamer.js`. Pass `--chive /path/to/renamer.js` if chive isn’t next to this repo.

## iOS app

From this repo (phone plugged in and unlocked):

```bash
pnpm redeploy
```

On build failure, the script prints the last lines of `/tmp/archie-dd/archie-build.log`. Override team/device with `ARCHIE_DEVELOPMENT_TEAM` / `ARCHIE_DEVICE`.

Xcode works too: open `Apps/Archie.xcodeproj`, set your development team, Run on a device. Enter the PIN shown by the receiver.

See `spec.md` and `spec_full.md` for the design.
