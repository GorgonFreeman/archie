# iPhone Photo Offloader: Spec v2

## Purpose

Copy every photo and video from an iPhone to a Mac, prove each copy is byte-identical, then delete from the iPhone only what was proven. No verification, no deletion.

## Scope

**In:**
- Full import of all photos and videos
- Checksum verification
- Delete-after-verify
- **A metadata sidecar JSON per asset** (see below)
- A "protect favourites" toggle
- A hand-picked list of protected albums

**Out (cut from v1):**
- iCloud Photos support
- A polished Mac UI
- Libimobiledevice, ImageCaptureCore, and any filesystem-level access
- Resume across apps or multiple devices
- Dedupe across imports
- Editing and re-encoding
- Cloud anything

## Components

1. **iPhone app (SwiftUI + PhotoKit).** This is where all the logic lives. It enumerates assets, exports originals, hashes them, sends them, and deletes verified ones.
2. **Mac receiver (Swift command-line tool).** It receives files, writes them safely, re-hashes them, and returns receipts. It makes no decisions about deletion.

## User settings (iPhone app)

- **Protect favourites:** on or off (default on).
- **Protected albums:** the user picks any number of regular albums by name. Stored by `PHAssetCollection.localIdentifier`.

An asset is **protected** if it is a favourite (and the toggle is on) or belongs to any protected album. Protected assets are still imported, and never deleted.

## Import flow

For each asset (`PHAsset`), the app transfers all of its resources via `PHAssetResourceManager`: original photo or video, paired video (Live Photo), RAW and JPEG partners, edited full-size render, and adjustment data. This keeps Live Photos, edits and RAW+JPEG intact without guessing from filenames.

Hidden assets are included in the import.

Per resource:

1. **Phone:** Stream the original bytes without re-encoding. Compute SHA-256 over the exact bytes sent. Send the metadata (asset ID, resource type, original filename, creation date, size, hash) first, then the bytes.
2. **Mac:** Write to a temp file while hashing, then `F_FULLFSYNC` and close. Atomically rename to `YYYY/MM/<filename>`, adding a suffix on collisions and never overwriting. Reopen the final file and hash it again.
3. **Mac:** Reply with a receipt only if the final-file hash equals both the hash computed during receipt and the phone's declared hash. Otherwise reply with a failure, delete the temp file, and the phone retries (max 3 attempts).
4. **Phone:** Mark the resource as verified only on a matching receipt.
5. **Mac:** Append a record to `manifest.jsonl` (asset ID, resource, path, size, hash, timestamp).

If the phone cannot read an original (for example, it is not on the device), the asset is marked failed and retained.

## Metadata sidecar

PhotoKit holds information that is not in the original files: corrected locations and dates, favourite status, album membership. Deleting the asset destroys it, so it is preserved per asset.

For each asset, the phone builds a JSON file and sends it through the same hashed, verified path as the media. The Mac stores it next to the primary file as `<primary filename>.asset.json`.

Fields (confirm against the real iOS version in the spike):

- `assetId` (`localIdentifier`), `importedAt`, device model, iOS version
- `creationDate` and `modificationDate` (as PhotoKit reports them, including user corrections)
- `location`: latitude, longitude, altitude, as PhotoKit reports them (including user corrections)
- `isFavorite`, `isHidden`
- `albums`: name and `localIdentifier` for every regular-album membership
- `mediaType`, `subtypes` (Live Photo, screenshot, panorama, slo-mo, etc.), `burstIdentifier`
- `pixelWidth`, `pixelHeight`, `duration`
- `resources`: for each, type, original filename, size, SHA-256, and relative path on the Mac

Favourite and album values are a snapshot as of import time. Deletion decisions still re-read them fresh.

Out of scope: people, scene labels, captions, keywords (no public PhotoKit access, to be confirmed in the spike). These can be added later by running Vision on the Mac copies.

## Deletion rule

An asset is **eligible** only if all of the following hold:

- Every one of its resources has a verified receipt from this run.
- Its metadata sidecar has a verified receipt too. Without a stored sidecar, the asset is retained.
- It is not protected, evaluated **fresh at delete time** (favourite flag and album membership re-read from PhotoKit).
- Photos authorization is **full access**. Under limited access, the app never deletes.

Eligible assets are deleted with `PHAssetChangeRequest.deleteAssets`, in batches (one iOS confirmation prompt per batch, which cannot be suppressed). Deleted items go to Recently Deleted for 30 days.

Before deleting, the app shows a summary: assets and bytes to delete, assets retained (and why: protected, failed, unreadable). Deletion is a separate button after the import finishes, not automatic.

After each batch, the app re-fetches to confirm what actually disappeared. A disconnect, crash, or error leaves everything in an undeleted state. No receipt on record means no deletion.

## Protocol

- **Discovery:** Bonjour on the local network. Mac advertises, phone connects. (USB transport is a possible later addition.)
- **Security:** TLS, with a one-time PIN shown on the Mac and entered on the phone to pair.
- **Messages:** length-prefixed frames. HELLO, ASSET_BEGIN (metadata), CHUNK (bytes), RESOURCE_END (phone's hash), RECEIPT or FAIL, SESSION_END. The sidecar JSON travels as one more resource of the asset, in the same frames.
- **Chunking:** about 1 to 4 MB per chunk, with backpressure so the phone never buffers a whole video in memory.

## Constraints and known limits

- The app must stay in the foreground, with the screen kept awake (idle timer disabled), during transfer.
- Developer-signed builds expire after 7 days (free account) and need re-installing from Xcode.
- The Mac archive is not a backup. Back it up separately before the first deletion.
- Photos privacy permission is required. The app should refuse to run import-and-delete without full access.

## Acceptance criteria

1. Every file on the Mac matches its phone-side SHA-256 after an independent re-read.
2. Killing the transfer at any point (app, Mac, network) deletes nothing and leaves no partial file in the final archive.
3. Re-running after an interruption does not duplicate or corrupt verified files.
4. Favourites (when protected) and protected-album assets are never deleted, including when album membership changes between import and delete.
5. An asset with any unverified or missing resource is never deleted.
6. Live Photos, RAW+JPEG and edited photos arrive with all components.
7. Limited-access authorization blocks deletion.
8. The app reports counts of imported, verified, failed, retained, and deleted assets.
9. Every imported asset has a sidecar that parses as valid JSON, lists all its resources with matching hashes, and carries its location, favourite and album data. An asset whose sidecar failed verification is never deleted.
10. A photo whose location or date was edited in Photos shows the edited values in its sidecar.

## Build order

1. **Spike (1 day):** PhotoKit enumeration of a test library on a real phone. Export resources, check protection logic, delete a test asset and confirm it lands in Recently Deleted. Dump every metadata field PhotoKit returns for a sample of assets (including edited-location ones) to settle the sidecar schema, and check whether anything about people or scenes is exposed.
2. **Mac receiver and protocol:** hashing, atomic writes, receipts, manifest. No deletion yet.
3. **Phone import loop and verification.** Test with interrupted transfers.
4. **Deletion, summary screen, and settings.** Test against the acceptance criteria on a throwaway library first.
5. **Run on the real library** in stages, with a Mac backup in place.
