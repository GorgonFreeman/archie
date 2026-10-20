#!/usr/bin/env node
'use strict';

/**
 * Post-process an Archie archive (nested or flat):
 * 1. Park *.asset.json sidecars
 * 2. Flatten media to the archive root
 * 3. Rename from sidecar.creationDate when present, else chive
 * 4. Unpark sidecars as <newMedia>.asset.json; rewrite relativePath
 * 5. Patch manifest.jsonl
 *
 * Usage: node scripts/chive_archive.js <archive-dir> [--chive path] [--force]
 */

const fs = require('fs');
const path = require('path');
const { randomUUID, createHash } = require('crypto');
const { spawnSync } = require('child_process');

const SIDECAR_SUFFIX = '.asset.json';
const PARK_DIR_NAME = '.archie-sidecar-park';
const TMP_DIR_NAME = '.archie-tmp';
const MANIFEST_NAME = 'manifest.jsonl';
const CHIVE_LOG_NAME = 'chive_rename_log.tsv';
const ARCHIVE_LOCK_NAME = '.archie-archive.lock';
const SKIP_NAMES = new Set([MANIFEST_NAME, CHIVE_LOG_NAME, '.DS_Store', ARCHIVE_LOCK_NAME]);

const rawArgs = process.argv.slice(2);
const force = rawArgs.includes('--force');
let chivePathArg = null;
const pos = [];
for (let i = 0; i < rawArgs.length; i++) {
  const arg = rawArgs[i];
  if (arg === '--force') continue;
  if (arg === '--chive') {
    chivePathArg = rawArgs[++i];
    continue;
  }
  if (arg.startsWith('--chive=')) {
    chivePathArg = arg.slice('--chive='.length);
    continue;
  }
  pos.push(arg);
}

if (pos.length !== 1) {
  console.error('usage: node scripts/chive_archive.js <archive-dir> [--chive path] [--force]');
  process.exit(1);
}

const archiveRoot = path.resolve(pos[0]);
if (!fs.existsSync(archiveRoot) || !fs.statSync(archiveRoot).isDirectory()) {
  console.error('not a directory', archiveRoot);
  process.exit(1);
}

const defaultChive = path.resolve(__dirname, '../../chive/renamer.js');
const chiveRenamer = path.resolve(chivePathArg || process.env.CHIVE_RENAMER || defaultChive);
if (!fs.existsSync(chiveRenamer)) {
  console.error('chive renamer not found:', chiveRenamer);
  process.exit(1);
}

const parkDir = path.join(archiveRoot, PARK_DIR_NAME);
fs.mkdirSync(parkDir, { recursive: true });

/** @type {Map<string, string>} any prior abs path -> current final abs path */
const renames = new Map();
/** @type {{ parkPath: string, originalMediaPath: string }[]} */
const parked = [];

function listFiles(dir) {
  const out = [];
  for (const name of fs.readdirSync(dir)) {
    if (name === PARK_DIR_NAME || name === TMP_DIR_NAME) continue;
    const full = path.join(dir, name);
    let st;
    try {
      st = fs.statSync(full);
    } catch {
      continue;
    }
    if (st.isDirectory()) out.push(...listFiles(full));
    else if (st.isFile()) out.push(full);
  }
  return out;
}

function isSidecar(filePath) {
  return filePath.endsWith(SIDECAR_SUFFIX);
}

function mediaPathForSidecar(sidecarPath) {
  return sidecarPath.slice(0, -SIDECAR_SUFFIX.length);
}

function formatChiveDate(date) {
  const ms = date.getMilliseconds();
  const timePart =
    `${ String(date.getHours()).padStart(2, '0') }h` +
    `${ String(date.getMinutes()).padStart(2, '0') }m` +
    `${ String(date.getSeconds()).padStart(2, '0') }s` +
    (ms ? `${ String(ms).padStart(3, '0') }ms` : '');
  return (
    `${ date.getFullYear() }-` +
    `${ String(date.getMonth() + 1).padStart(2, '0') }-` +
    `${ String(date.getDate()).padStart(2, '0') }_${ timePart }`
  );
}

function uniquePath(dir, baseName, ext) {
  let candidate = path.join(dir, `${ baseName }${ ext }`);
  let n = 1;
  while (fs.existsSync(candidate)) {
    candidate = path.join(dir, `${ baseName }_${ n }${ ext }`);
    n += 1;
  }
  return candidate;
}

function recordRename(from, to) {
  from = path.resolve(from);
  to = path.resolve(to);
  if (from === to) return;
  for (const [k, v] of [...renames.entries()]) {
    if (v === from) renames.set(k, to);
  }
  renames.set(from, to);
}

function resolveFinal(start) {
  let cur = path.resolve(start);
  const seen = new Set();
  while (renames.has(cur) && !seen.has(cur)) {
    seen.add(cur);
    cur = renames.get(cur);
  }
  return cur;
}

function sha256File(filePath) {
  const hash = createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function snapshotMediaHashes() {
  /** @type {Map<string, number>} */
  const counts = new Map();
  for (const file of listFiles(archiveRoot)) {
    if (isSidecar(file)) continue;
    if (SKIP_NAMES.has(path.basename(file))) continue;
    const dig = sha256File(file);
    counts.set(dig, (counts.get(dig) || 0) + 1);
  }
  return counts;
}

function parkAllSidecars() {
  for (const file of listFiles(archiveRoot)) {
    if (!isSidecar(file)) continue;
    const media = mediaPathForSidecar(file);
    const parkPath = path.join(parkDir, `${ randomUUID() }.json`);
    fs.renameSync(file, parkPath);
    parked.push({ parkPath, originalMediaPath: path.resolve(media) });
  }
  console.log('parked sidecars', parked.length);
}

function flattenMediaToRoot() {
  let moved = 0;
  for (const file of listFiles(archiveRoot)) {
    if (isSidecar(file)) continue;
    if (SKIP_NAMES.has(path.basename(file))) continue;
    if (path.resolve(path.dirname(file)) === archiveRoot) continue;

    const ext = path.extname(file);
    const base = path.basename(file, ext);
    const dest = uniquePath(archiveRoot, base, ext);
    fs.renameSync(file, dest);
    recordRename(file, dest);
    moved += 1;
  }
  console.log('flattened to root', moved);

  // Remove empty nested dirs (bottom-up).
  const dirs = [];
  function walkDirs(dir) {
    for (const name of fs.readdirSync(dir)) {
      if (name === PARK_DIR_NAME || name === TMP_DIR_NAME) continue;
      const full = path.join(dir, name);
      if (fs.statSync(full).isDirectory()) {
        walkDirs(full);
        dirs.push(full);
      }
    }
  }
  walkDirs(archiveRoot);
  for (const dir of dirs) {
    try {
      if (fs.readdirSync(dir).length === 0) fs.rmdirSync(dir);
    } catch {
      // ignore
    }
  }
}

function renameFromSidecarDates() {
  let n = 0;
  for (const entry of parked) {
    const current = resolveFinal(entry.originalMediaPath);
    if (!fs.existsSync(current)) continue;

    let doc;
    try {
      doc = JSON.parse(fs.readFileSync(entry.parkPath, 'utf8'));
    } catch {
      continue;
    }
    if (!doc.creationDate) continue;

    const date = new Date(doc.creationDate);
    if (Number.isNaN(date.getTime())) continue;

    const ext = path.extname(current);
    const newPath = uniquePath(archiveRoot, formatChiveDate(date), ext);
    if (path.resolve(newPath) === path.resolve(current)) continue;

    fs.renameSync(current, newPath);
    recordRename(current, newPath);
    n += 1;
  }
  console.log('sidecar-date renames', n);
}

function runChive() {
  const logPath = path.join(archiveRoot, CHIVE_LOG_NAME);
  const args = [chiveRenamer, archiveRoot, '--log', logPath];
  if (force) args.push('--force');
  console.log('running chive…');
  const result = spawnSync(process.execPath, args, { stdio: 'inherit' });
  if (result.status !== 0) {
    console.error('chive exited', result.status);
    process.exit(result.status || 1);
  }
  return logPath;
}

function ingestChiveLog(logPath) {
  if (!fs.existsSync(logPath)) return;
  let n = 0;
  const lines = fs.readFileSync(logPath, 'utf8').split('\n').slice(1);
  for (const line of lines) {
    if (!line.trim()) continue;
    const cols = line.split('\t');
    if (cols.length < 3) continue;
    const oldPath = path.resolve(cols[1]);
    const newPath = path.resolve(cols[2]);
    if (oldPath.endsWith(SIDECAR_SUFFIX)) continue;
    if (oldPath.includes(`${ path.sep }${ PARK_DIR_NAME }${ path.sep }`)) continue;
    recordRename(oldPath, newPath);
    n += 1;
  }
  console.log('chive log renames ingested', n);
}

function buildRelPathMap() {
  /** @type {Map<string, string>} */
  const pathMap = new Map();
  for (const [oldAbs, newAbs] of renames) {
    const oldRel = path.relative(archiveRoot, oldAbs);
    const newRel = path.relative(archiveRoot, newAbs);
    pathMap.set(oldRel, newRel);
    // Sidecars are named <media>.asset.json — keep manifest rows paired.
    pathMap.set(oldRel + SIDECAR_SUFFIX, newRel + SIDECAR_SUFFIX);
  }
  return pathMap;
}

function applyPathMap(value, pathMap) {
  if (typeof value !== 'string') return value;
  if (pathMap.has(value)) return pathMap.get(value);
  // Nested leftovers sometimes stored with leading ./ 
  const norm = value.replace(/^\.\//, '');
  if (pathMap.has(norm)) return pathMap.get(norm);
  return value;
}

function unparkSidecars() {
  const pathMap = buildRelPathMap();
  let ok = 0;
  let failed = 0;

  for (const { parkPath, originalMediaPath } of parked) {
    const newAbs = resolveFinal(originalMediaPath);
    if (!fs.existsSync(newAbs)) {
      console.error('MISSING media for sidecar', originalMediaPath, '->', newAbs);
      failed += 1;
      const fallback = path.join(archiveRoot, path.basename(originalMediaPath) + SIDECAR_SUFFIX);
      fs.renameSync(parkPath, uniquePath(archiveRoot, path.basename(fallback, SIDECAR_SUFFIX), SIDECAR_SUFFIX));
      continue;
    }

    const dest = newAbs + SIDECAR_SUFFIX;
    let doc;
    try {
      doc = JSON.parse(fs.readFileSync(parkPath, 'utf8'));
    } catch (err) {
      console.error('bad sidecar json', parkPath, err.message);
      failed += 1;
      fs.renameSync(parkPath, dest);
      continue;
    }

    if (Array.isArray(doc.resources)) {
      doc.resources = doc.resources.map((r) => ({
        ...r,
        relativePath: applyPathMap(r.relativePath, pathMap),
      }));
    }

    if (fs.existsSync(dest)) {
      console.error('sidecar dest exists', dest);
      failed += 1;
      continue;
    }
    fs.writeFileSync(parkPath, `${ JSON.stringify(doc) }\n`);
    fs.renameSync(parkPath, dest);
    ok += 1;
  }
  console.log('sidecars restored', { ok, failed });
  return failed;
}

function patchManifest() {
  const manifestPath = path.join(archiveRoot, MANIFEST_NAME);
  if (!fs.existsSync(manifestPath)) return;
  const pathMap = buildRelPathMap();

  // Sidecar JSON was rewritten (relativePath updates) — refresh hash/size by assetId.
  /** @type {Map<string, string>} */
  const sidecarByAsset = new Map();
  for (const file of listFiles(archiveRoot)) {
    if (!isSidecar(file)) continue;
    try {
      const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (doc.assetId) sidecarByAsset.set(doc.assetId, file);
    } catch {
      // ignore
    }
  }

  const lines = fs.readFileSync(manifestPath, 'utf8').split('\n');
  const next = lines.map((line) => {
    if (!line.trim()) return line;
    try {
      const row = JSON.parse(line);
      if (row.relativePath) row.relativePath = applyPathMap(row.relativePath, pathMap);

      const isSidecarRow = row.resourceType === 'sidecar'
        || String(row.relativePath || '').endsWith(SIDECAR_SUFFIX);
      if (isSidecarRow && row.assetId && sidecarByAsset.has(row.assetId)) {
        const side = sidecarByAsset.get(row.assetId);
        row.relativePath = path.relative(archiveRoot, side);
        row.sha256 = sha256File(side);
        row.size = fs.statSync(side).size;
      }

      return JSON.stringify(row);
    } catch {
      return line;
    }
  });
  fs.writeFileSync(manifestPath, next.map((l) => l).join('\n') + (next.length ? '\n' : ''));
  console.log('updated manifest.jsonl');
}

function cleanupParkDir() {
  const left = fs.existsSync(parkDir) ? fs.readdirSync(parkDir) : [];
  if (left.length === 0) {
    try { fs.rmdirSync(parkDir); } catch { /* ignore */ }
  } else {
    console.error('park dir not empty', parkDir, left.length);
  }
}

function hashesEqual(a, b) {
  if (a.size !== b.size) return false;
  for (const [k, v] of a) {
    if (b.get(k) !== v) return false;
  }
  return true;
}

function verifyArchive() {
  const issues = [];
  let sidecars = 0;
  let media = 0;

  for (const file of listFiles(archiveRoot)) {
    if (SKIP_NAMES.has(path.basename(file))) continue;
    if (isSidecar(file)) {
      sidecars += 1;
      const mediaPath = mediaPathForSidecar(file);
      if (!fs.existsSync(mediaPath)) {
        issues.push(`orphan sidecar: ${ path.relative(archiveRoot, file) }`);
        continue;
      }
      let doc;
      try {
        doc = JSON.parse(fs.readFileSync(file, 'utf8'));
      } catch (err) {
        issues.push(`invalid json: ${ file }: ${ err.message }`);
        continue;
      }
      if (!Array.isArray(doc.resources)) {
        issues.push(`no resources[]: ${ file }`);
        continue;
      }
      for (const r of doc.resources) {
        if (!r.relativePath) {
          issues.push(`missing relativePath in ${ file }`);
          continue;
        }
        const target = path.join(archiveRoot, r.relativePath);
        if (!fs.existsSync(target)) {
          issues.push(`broken relativePath ${ r.relativePath } in ${ path.basename(file) }`);
        }
        if (r.sha256 && r.sha256.length === 64) {
          const dig = sha256File(target);
          if (dig !== r.sha256.toLowerCase()) {
            issues.push(`hash mismatch ${ r.relativePath } sidecar=${ r.sha256 } file=${ dig }`);
          }
        }
      }
    } else {
      media += 1;
      if (path.dirname(file) !== archiveRoot) {
        issues.push(`still nested: ${ path.relative(archiveRoot, file) }`);
      }
    }
  }

  // manifest paths
  const manifestPath = path.join(archiveRoot, MANIFEST_NAME);
  if (fs.existsSync(manifestPath)) {
    for (const line of fs.readFileSync(manifestPath, 'utf8').split('\n')) {
      if (!line.trim()) continue;
      try {
        const row = JSON.parse(line);
        if (row.relativePath && !fs.existsSync(path.join(archiveRoot, row.relativePath))) {
          issues.push(`manifest missing file: ${ row.relativePath }`);
        }
        if (row.sha256 && row.relativePath) {
          const dig = sha256File(path.join(archiveRoot, row.relativePath));
          if (dig !== String(row.sha256).toLowerCase()) {
            issues.push(`manifest hash mismatch: ${ row.relativePath }`);
          }
        }
      } catch {
        issues.push('manifest unparseable line');
      }
    }
  }

  return { sidecars, media, issues };
}

function acquireArchiveLock() {
  const lockPath = path.join(archiveRoot, ARCHIVE_LOCK_NAME);
  if (fs.existsSync(lockPath)) {
    const raw = fs.readFileSync(lockPath, 'utf8').trim();
    const pid = Number(raw);
    if (pid > 0) {
      try {
        process.kill(pid, 0);
        console.error('archive locked by pid', pid, '— stop the receiver or wait');
        process.exit(4);
      } catch {
        fs.unlinkSync(lockPath);
      }
    } else {
      fs.unlinkSync(lockPath);
    }
  }
  fs.writeFileSync(lockPath, String(process.pid));
  return lockPath;
}

function releaseArchiveLock(lockPath) {
  try {
    if (fs.existsSync(lockPath) && fs.readFileSync(lockPath, 'utf8').trim() === String(process.pid)) {
      fs.unlinkSync(lockPath);
    }
  } catch {
    // ignore
  }
}

const lockPath = acquireArchiveLock();
try {
  console.log('snapshotting media hashes…');
  const beforeHashes = snapshotMediaHashes();
  console.log('media files', [...beforeHashes.values()].reduce((a, b) => a + b, 0));

  parkAllSidecars();
  flattenMediaToRoot();
  renameFromSidecarDates();
  const logPath = runChive();
  ingestChiveLog(logPath);
  const sidecarFailures = unparkSidecars();
  patchManifest();
  cleanupParkDir();

  console.log('verifying…');
  const afterHashes = snapshotMediaHashes();
  if (!hashesEqual(beforeHashes, afterHashes)) {
    console.error('DATA ISSUE: media sha256 multiset changed (content altered or file lost/gained)');
    process.exit(2);
  }
  console.log('media hashes unchanged ✓');

  const { sidecars, media, issues } = verifyArchive();
  console.log('counts', { sidecars, media, renames: renames.size });
  if (sidecarFailures || issues.length) {
    console.error('DATA ISSUES:');
    for (const issue of issues.slice(0, 50)) console.error(' -', issue);
    if (issues.length > 50) console.error(` … and ${ issues.length - 50 } more`);
    process.exit(3);
  }
  console.log('done — archive OK');
} finally {
  releaseArchiveLock(lockPath);
}