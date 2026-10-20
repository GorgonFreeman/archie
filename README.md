# Archie

Copy photos and videos from an iPhone to a Mac. Verify each file with SHA-256, then delete from the phone only what was proven.

## Mac receiver

```bash
swift run archie-receiver ~/Pictures/ArchieArchive
```

## iOS app

Open `Apps/Archie.xcodeproj` in Xcode, set your development team, run on a device, enter the PIN shown by the receiver.

See `spec.md` and `spec_full.md` for the design.
