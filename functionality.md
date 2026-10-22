# Connection

Uses a PIN to greenlight the phone <> computer connection. PIN should show in a notification once the phone is detected. It should also be available from a menu item

# Import

Imports photos and videos from the phone, deleting them when we are absolutely sure they are completely transferred.

## Verification

Once a piece of media is imported, it is checksummed vs the asset on the phone. Only once this checks out is the asset Verified (transferred).

## Metadata

Metadata such as Favourite status is recorded in a JSON sidecar, as it cannot live on the image.

## Naming

Media is named in the same format as Chive - by best timestamp. Collisions are handled by a _1, _2 etc. suffix. Sidecars mirror the main file names.

## Media type handling 

Live photos are imported only as the full photo (i.e. after edits).

## Deletion

Once assets are Verified, they are candidates for deletion. A button called "Delete Verified (number)" offers to delete all verified assets when any are available, with a live count update.

Deletion is available through the "Delete Verified" button at any time, or will be offered on Finish or Pause.

## Protecting photos

User has a toggle per album to "protect" photos. This means don't delete after import. Favourites is also supported as an option and is on by default. Once a favourite verifies on the Mac, its asset id is recorded in `.favourites_seen_log` in the archive and skipped on later imports.

## Pause

The import can be paused at any time with a "Pause" button.

## Error handling

Errors of any kind should be handled by discarding the current operation and reimporting in the future. The process is designed to be idempotent, clobber-resistant, etc. so we should be able to handle restarting the process.

# Reconcile

Checks the import directory on the computer for any assets that can be Verified and deleted. Assets must be Verified for deletion, not just checked by filename.

This is available as an option the user can select if any content is in the import directory when the phone is connected.
