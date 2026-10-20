# Archie

Copy photos and videos from an iPhone to a Mac. Verify each file with SHA-256, then delete from the phone only what was proven.

## Mac receiver

Writes **flat** into the archive root (no `YYYY/MM/` nesting):

```bash
swift run archie-receiver ~/Pictures/ArchieArchive
```

### Date-rename with chive (keeps sidecars paired)

After a run (or on an existing flat archive), park sidecars, rename media, restore `*.asset.json`:

```bash
node scripts/chive_archive.js ~/Pictures/ArchieArchive
```

Uses each sidecar’s PhotoKit `creationDate` when present; otherwise runs sibling `chive/renamer.js`. Pass `--chive /path/to/renamer.js` if chive isn’t next to this repo.

## iOS app

Open `Apps/Archie.xcodeproj` in Xcode, set your development team, run on a device, enter the PIN shown by the receiver.

See `spec.md` and `spec_full.md` for the design.
