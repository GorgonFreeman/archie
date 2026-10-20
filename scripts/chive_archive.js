#!/usr/bin/env node
'use strict';

/**
 * Post-process a flat Archie archive:
 * 1. Park *.asset.json sidecars (so they cannot be orphaned mid-rename)
 * 2. Rename media from sidecar.creationDate when present (PhotoKit), else leave for chive
 * 3. Run chive's renamer on the archive
 * 4. Unpark sidecars next to the new media names and rewrite relativePath fields
 * 5. Patch manifest.jsonl paths
 *
 * Usage: node scripts/chive_archive.js <archive-dir> [--chive path/to/renamer.js] [--force]
 */

const fs = require('fs');
const path = require('path');
const { randomUUID } = require('crypto');
const { spawnSync } = require('child_process');

const SIDECAR_SUFFIX = '.asset.json';
const PARK_DIR_NAME = '.archie-sidecar-park';
const TMP_DIR_NAME = '.archie-tmp';
const MANIFEST_NAME = 'manifest.jsonl';
const CHIVE_LOG_NAME = 'chive_rename_log.tsv';

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
  console.error('pass --chive /path/to/chive/renamer.js or set CHIVE_RENAMER');
  process.exit(1);
}

const parkDir = path.join(archiveRoot, PARK_DIR_NAME);
fs.mkdirSync(parkDir, { recursive: true });

/** @type {Map<string, string>} oldAbsMedia -> newAbsMedia */
const renames = new Map();
/** @type {{ parkPath: string, oldMediaPath: string }[]} */
const parked = [];

function listFiles(dir) {
  const out = [];
  for (const name of fs.readdirSync(dir)) {
    if (name === PARK_DIR_NAME || name === TMP_DIR_NAME) continue;
    const full = path.join(dir, name);
    const st = fs.statSync(full);
    if (st.isDirectory()) {
      // Flat import — ignore leftover nested dirs except by walking for migration.
      out.push(...listFiles(full));
    } else if (st.isFile()) {
      out.push(full);
    }
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

function parkAllSidecars() {
  for (const file of listFiles(archiveRoot)) {
    if (!isSidecar(file)) continue;
    const media = mediaPathForSidecar(file);
    const parkPath = path.join(parkDir, `${ randomUUID() }.json`);
    fs.renameSync(file, parkPath);
    parked.push({ parkPath, oldMediaPath: media });
    console.log('parked sidecar for', path.basename(media));
  }
}

function renameFromSidecarDates() {
  for (const entry of parked) {
    const { parkPath, oldMediaPath } = entry;
    if (!fs.existsSync(oldMediaPath)) continue;

    let doc;
    try {
      doc = JSON.parse(fs.readFileSync(parkPath, 'utf8'));
    } catch {
      continue;
    }
    if (!doc.creationDate) continue;

    const date = new Date(doc.creationDate);
    if (Number.isNaN(date.getTime())) continue;

    const dir = path.dirname(oldMediaPath);
    const ext = path.extname(oldMediaPath);
    const newPath = uniquePath(dir, formatChiveDate(date), ext);
    if (path.resolve(newPath) === path.resolve(oldMediaPath)) continue;

    fs.renameSync(oldMediaPath, newPath);
    renames.set(path.resolve(oldMediaPath), path.resolve(newPath));
    console.log('sidecar-date rename', path.basename(oldMediaPath), '->', path.basename(newPath));
  }
}

function runChive() {
  const logPath = path.join(archiveRoot, CHIVE_LOG_NAME);
  const args = [chiveRenamer, archiveRoot, '--log', logPath];
  if (force) args.push('--force');
  console.log('running chive', args.join(' '));
  const result = spawnSync(process.execPath, args, { stdio: 'inherit' });
  if (result.status !== 0) {
    console.error('chive exited', result.status);
    process.exit(result.status || 1);
  }
  return logPath;
}

function ingestChiveLog(logPath) {
  if (!fs.existsSync(logPath)) return;
  const lines = fs.readFileSync(logPath, 'utf8').split('\n').slice(1);
  for (const line of lines) {
    if (!line.trim()) continue;
    const cols = line.split('\t');
    if (cols.length < 3) continue;
    const oldPath = path.resolve(cols[1]);
    const newPath = path.resolve(cols[2]);
    if (oldPath.endsWith(SIDECAR_SUFFIX)) continue;
    if (oldPath.includes(`${ path.sep }${ PARK_DIR_NAME }${ path.sep }`)) continue;
    renames.set(oldPath, newPath);
  }
}

function applyPathMap(value, pathMap) {
  if (typeof value !== 'string') return value;
  if (pathMap.has(value)) return pathMap.get(value);
  const base = path.basename(value);
  if (pathMap.has(base)) return pathMap.get(base);
  return value;
}

function unparkSidecars() {
  /** basename old -> basename new, and relative old -> relative new */
  const pathMap = new Map();
  for (const [oldAbs, newAbs] of renames) {
    pathMap.set(oldAbs, newAbs);
    pathMap.set(path.basename(oldAbs), path.basename(newAbs));
    pathMap.set(path.relative(archiveRoot, oldAbs), path.relative(archiveRoot, newAbs));
  }

  for (const { parkPath, oldMediaPath } of parked) {
    const oldAbs = path.resolve(oldMediaPath);
    const newAbs = renames.get(oldAbs) || oldAbs;
    if (!fs.existsSync(newAbs)) {
      console.error('missing media for sidecar, restoring park next to old name', oldMediaPath);
      const fallback = oldAbs + SIDECAR_SUFFIX;
      fs.renameSync(parkPath, fallback);
      continue;
    }

    const dest = newAbs + SIDECAR_SUFFIX;
    let doc;
    try {
      doc = JSON.parse(fs.readFileSync(parkPath, 'utf8'));
    } catch (err) {
      console.error('bad sidecar json', parkPath, err.message);
      fs.renameSync(parkPath, dest);
      continue;
    }

    if (Array.isArray(doc.resources)) {
      doc.resources = doc.resources.map((r) => ({
        ...r,
        relativePath: applyPathMap(r.relativePath, pathMap),
      }));
    }

    fs.writeFileSync(parkPath, `${ JSON.stringify(doc) }\n`);
    if (fs.existsSync(dest)) {
      console.error('sidecar dest exists, leaving parked', dest);
      continue;
    }
    fs.renameSync(parkPath, dest);
    console.log('sidecar', path.basename(dest));
  }
}

function patchManifest() {
  const manifestPath = path.join(archiveRoot, MANIFEST_NAME);
  if (!fs.existsSync(manifestPath)) return;

  const pathMap = new Map();
  for (const [oldAbs, newAbs] of renames) {
    pathMap.set(path.relative(archiveRoot, oldAbs), path.relative(archiveRoot, newAbs));
    pathMap.set(path.basename(oldAbs), path.basename(newAbs));
  }

  const lines = fs.readFileSync(manifestPath, 'utf8').split('\n');
  const next = lines.map((line) => {
    if (!line.trim()) return line;
    try {
      const row = JSON.parse(line);
      if (row.relativePath) {
        row.relativePath = applyPathMap(row.relativePath, pathMap);
      }
      return JSON.stringify(row);
    } catch {
      return line;
    }
  });
  fs.writeFileSync(manifestPath, next.join('\n'));
  console.log('updated', MANIFEST_NAME);
}

function cleanupParkDir() {
  try {
    const left = fs.readdirSync(parkDir);
    if (left.length === 0) {
      fs.rmdirSync(parkDir);
    } else {
      console.error('park dir not empty — inspect', parkDir, left);
    }
  } catch {
    // ignore
  }
}

parkAllSidecars();
renameFromSidecarDates();
const logPath = runChive();
ingestChiveLog(logPath);
unparkSidecars();
patchManifest();
cleanupParkDir();
console.log('done', { renames: renames.size, sidecars: parked.length });
