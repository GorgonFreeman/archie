# Archie errors / known issues

Observed during the 2026-10-21 morning import (receiver PIN `692666`). Pause-related idle is expected and not covered here.

---

## 1. Settle rename fails on multi-resource assets (`FullSizeRender`, etc.)

### What you see

Receiver log:

```text
ok IMG_1404-1.JPG
ok Adjustments-31.plist
ok IMG_1404-1.MOV
ok FullSizeRender-9.mov
ok FullSizeRender-13.jpg
ok IMG_1404.JPG.asset-1.json
settle fail “FullSizeRender-9.mov” couldn’t be moved to “ArchieArchive”
  because an item with the same name already exists.
```

Phone keeps the asset (`settleFailed`). Mac leaves the verified files under raw names (`FullSizeRender-*`, `IMG_*-N`, `Adjustments-*.plist`).

~11 failures this session; renaming is **not** generally broken — Live Photo HEIC+MOV settles succeed (`settled … (3 renames)`). Failures cluster on assets with **two or more resources that share an extension** (edited pair: `IMG_….MOV` + `FullSizeRender-….mov`, or `.JPG` + `.jpg`).

### Why (root cause)

`AssetRenamer.allocateUnique` picks `YYYY-MM-DD_HHhMMmSSs` + extension and tracks claimed names in a `Set<String>`:

```swift
reserved.insert(name)  // e.g. "2018-04-01_05h26m33s.MOV"
```

PhotoKit / exporters often use **different casing** for the same extension (`.MOV` vs `.mov`, `.JPG` vs `.jpg`, `.HEIC` vs `.heic`). The archive volume is APFS **case-insensitive**.

So for one asset:

1. Plan step A: `IMG_1404-1.MOV` → reserves `…s.MOV`, move succeeds.
2. Plan step B: `FullSizeRender-9.mov` → reserved check is case-**sensitive**, so `…s.mov` looks free; on-disk check also misses because `…s.MOV` was only reserved, not necessarily visible as `…s.mov` before the first move — after A runs, B’s destination is the **same inode/name** → `moveItem` throws “item already exists”.

Same-second collisions across assets are already handled (`_1`, `_2`). This bug is **within one asset**, same second, same extension, different case.

That is why it feels like “renaming doesn’t work”: the assets that need rename most (edited Live Photos with an extra render) are exactly the ones that hit this.

### Fix

In `AssetRenamer` (and ideally `ArchiveLayout` / sidecar suffix handling for consistency):

1. **Normalize extensions to lowercase** when building the date filename (`base + "." + ext.lowercased()`).
2. Store **lowercased** names in `reserved`.
3. Treat on-disk existence as case-insensitive (lowercased compare of `lastPathComponent`, or always target lowercase destinations so new files are uniform).

Optional hardening:

- Before `moveItem`, if `to` exists, re-allocate instead of failing.
- Unit test: one asset with `a.MOV` + `b.mov` (+ optional `c.JPG` + `d.jpg`) settles to `date.mov` + `date_1.mov` without error; media hashes unchanged.

After the fix: rebuild/restart the Mac receiver (`swift build -c release` + reconnect / watch script). Redeploy iOS only if you change phone-side behavior (not required for this bug).

### Cleanup of already-failed files

Files from failed settles are still valid byte copies (hashes matched). Options:

- Re-run import for those assets (phone still has them) once the renamer is fixed — may create another verified copy unless you dedupe by hash first.
- Or a one-off backlog settle: group leftover `FullSizeRender*` / matching `IMG_*` via sidecar `assetId` / resource hashes and call the fixed `AssetRenamer`.

---

## 2. Leftover raw names (`IMG_*`, `FullSizeRender*`) in the archive

### What you see

After a run that also had successful settles:

- Hundreds of `IMG_*` (and `IMG_*-N.*` collision spellings)
- Dozens of `FullSizeRender-*`
- Some `Adjustments-*.plist`
- Sidecars like `IMG_….asset-1.json`

Meanwhile many assets are correctly named `2018-04-01_…`.

### Why

Several overlapping causes — not one mystery:

| Cause | Effect |
| --- | --- |
| **Issue 1 settle failure + rollback** | Media stay at pre-settle names; verified but not “pretty”. |
| **Write path always uses original filename** | `ArchiveLayout` stores `IMG_…` / `FullSizeRender-…` until settle. Mid-run raw names are normal; they should disappear after settle. |
| **Name collisions on write** | If `IMG_1404.JPG` already exists, new copy becomes `IMG_1404-1.JPG`. Sidecar may be `IMG_1404.JPG.asset-1.json`. Harmless if settle runs; ugly if settle fails. |
| **Re-import / resume** | Same library asset imported again while a dated copy already exists → another raw write + settle to `date_N`. Failed settle leaves an extra raw set. |
| **Prior backlog / partial chive runs** | Older mess can linger; hash-identical dupes confuse counting. |

So leftovers are mostly **symptoms of issue 1** plus the intentional “raw then rename” pipeline, not a second renamer.

### Fix

1. Ship issue 1 fix (stops new leftovers from edited multi-resource assets).
2. **Idle backlog pass** (receiver stopped or archive lock): extend `chive_archive.js` / a small Swift “settle leftovers” tool to:
   - Find `*.asset.json` whose `resources[].relativePath` still look unsettled (`IMG_`, `FullSizeRender`, etc.)
   - Run the same date rename + sidecar/manifest update as live settle
   - Skip or quarantine sets that fail hash checks
3. Optional: **hash dedupe** — if an unsettled file’s sha256 already exists under a date name for the same `assetId`, delete or quarantine the raw duplicate instead of renaming into another `_N`.
4. Keep live settle as source of truth; backlog is for recovery only.

### How to tell “in flight” vs “stuck”

- In flight: receiver log still printing `ok` / `settled`, mtimes within seconds.
- Stuck: import paused/idle, raw names unchanged, log shows `settle fail` for that basename, or raw files with no later `settled` line.

---

## Quick status checklist

- [x] `allocateUnique` lowercases extensions + reserved keys  
- [x] Test: `.MOV` + `.mov` in one asset  
- [x] Restart release `archie-receiver` after fix  
- [ ] Backlog settle / quarantine for current `FullSizeRender*` + stranded `IMG_*`  
- [ ] Confirm new edited Live Photos settle without `settle fail`
