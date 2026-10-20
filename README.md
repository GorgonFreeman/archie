# Archie

Copy photos and videos from an iPhone to a Mac. Verify each file with SHA-256, then delete from the phone only what was proven.

## Mac receiver

Writes **flat** into the archive root (no `YYYY/MM/` nesting):

```bash
swift run archie-receiver ~/Pictures/ArchieArchive
```

### Start automatically when an iPhone is plugged in

```bash
./scripts/install_launch_agent.sh
```

Checks USB every 5s. On connect it starts the receiver, shows a notification with the PIN, and writes it to `~/Library/Application Support/Archie/current_pin.txt`. Unplugging stops the receiver.

Also installs a **menu bar** app: click **Archie** for the PIN (and Copy). While the receiver is live the PIN appears in the menu bar title too.

```bash
./scripts/watch_iphone_receiver.sh --status
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

Open `Apps/Archie.xcodeproj` in Xcode, set your development team, run on a device, enter the PIN shown by the receiver.

See `spec.md` and `spec_full.md` for the design.
