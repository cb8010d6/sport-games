#!/usr/bin/env node
/** Restore pinned upstream assets. No npm packages or Git LFS required. Node version requirements: docs/DEVELOPMENT.md. */
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { sanitizeJpegProcessingHistory } from './asset_metadata.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const UA = 'regina-sports-asset-sync/1.0';
export const sha256 = b => crypto.createHash('sha256').update(b).digest('hex');

export function safePath(root, relative) {
  if (typeof relative !== 'string' || !relative || relative.includes('\\') ||
    relative.includes(':') || relative.split('/').some(s => !s || s === '.' || s === '..'))
    throw new Error('Invalid relative asset path');
  const full = path.resolve(root, relative);
  if (!full.startsWith(path.resolve(root) + path.sep)) throw new Error('Asset path escapes the repository');
  let current = path.resolve(root);
  for (const part of relative.split('/')) {
    current = path.join(current, part);
    if (fs.lstatSync(current, { throwIfNoEntry: false })?.isSymbolicLink())
      throw new Error('Asset destination contains a symlink');
  }
  return full;
}

export function validateUrl(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || url.port && url.port !== '443' ||
    !['polyhaven.com', 'polyhaven.org'].some(d => url.hostname === d || url.hostname.endsWith('.' + d)))
    throw new Error('Download URL is not an approved Poly Haven HTTPS host');
  return url;
}

export async function request(url, { fetcher = fetch, timeout = 300000 } = {}) {
  for (let redirect = 0; redirect < 6; redirect++) {
    const target = validateUrl(url);
    const response = await fetcher(target, { headers: { 'User-Agent': UA }, redirect: 'manual',
      signal: AbortSignal.timeout(timeout) });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) throw new Error('Download redirect has no destination');
      url = new URL(location, target).href;
      continue;
    }
    if (!response.ok) { await response.body?.cancel(); throw new Error(`Upstream returned HTTP ${response.status}`); }
    return response;
  }
  throw new Error('Too many upstream redirects');
}

export function validateManifest(manifest) {
  if (manifest.version !== 1 || !Array.isArray(manifest.files)) throw new Error('Unsupported asset manifest');
  const paths = new Set();
  for (const item of manifest.files) {
    safePath(ROOT, item.path);
    if (paths.has(item.path)) throw new Error('Duplicate asset destination');
    paths.add(item.path);
    if (!item.path.startsWith('game/assets/polyhaven/') || !/^[a-f\d]{64}$/.test(item.sha256) ||
      !/^[a-f\d]{64}$/.test(item.downloadSha256) || !Number.isSafeInteger(item.bytes) || item.bytes <= 0 ||
      !/^[A-Za-z0-9_]+$/.test(item.asset) || !Array.isArray(item.selector) || !item.selector.length ||
      item.selector.some(s => typeof s !== 'string' || !s || ['__proto__', 'constructor', 'prototype'].includes(s)) ||
      item.transform && item.transform !== 'jpeg-processing-history-v1')
      throw new Error('Invalid locked asset entry');
  }
  return manifest;
}

export function resolveFile(info, selector) {
  let entry = info;
  for (const key of selector) {
    if (!entry || !Object.hasOwn(entry, key)) throw new Error('The locked asset variant is no longer listed upstream');
    entry = entry[key];
  }
  validateUrl(entry.url);
  return entry;
}

async function fileHash(file) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

export async function installAsset(item, root, resolve, { fetcher = fetch, force = false } = {}) {
  const dest = safePath(root, item.path);
  if (fs.existsSync(dest)) {
    if (await fileHash(dest) === item.sha256) return 'verified';
    if (!force) throw new Error('Local file differs from the lock; use --force to replace it intentionally');
  }
  const remote = await resolve(item);
  const response = await request(remote.url, { fetcher });
  await fsp.mkdir(path.dirname(dest), { recursive: true });
  const temporary = dest + '.' + crypto.randomUUID() + '.part';
  const handle = await fsp.open(temporary, 'wx');
  const hash = crypto.createHash('sha256');
  let bytes = 0;
  try {
    if (!response.body) throw new Error('Empty download response');
    for await (const chunk of response.body) {
      bytes += chunk.byteLength;
      if (bytes > item.bytes) throw new Error('Downloaded file exceeds the locked size');
      hash.update(chunk);
      // FileHandle.write can perform a short write.
      let written = 0;
      while (written < chunk.byteLength) written += (await handle.write(chunk, written, chunk.byteLength - written)).bytesWritten;
    }
    await handle.close();
    if (bytes !== item.bytes || hash.digest('hex') !== item.downloadSha256)
      throw new Error('Upstream content differs from the pinned SHA-256/size; no file was installed');
    if (item.transform) {
      const cleaned = sanitizeJpegProcessingHistory(await fsp.readFile(temporary));
      if (sha256(cleaned) !== item.sha256) throw new Error('Sanitized asset differs from the pinned SHA-256');
      await fsp.writeFile(temporary, cleaned);
    } else if (item.sha256 !== item.downloadSha256) throw new Error('Missing asset transformation');
    await fsp.rename(temporary, dest);
    return 'downloaded';
  } catch (error) {
    await handle.close().catch(() => {});
    await fsp.unlink(temporary).catch(() => {});
    throw error;
  }
}

// Patched Node lines only (2026-10-21 security releases); the canonical
// statement of this requirement is docs/DEVELOPMENT.md / CODING_STANDARDS §5.
const NODE_MINIMUMS = [[22, 23, 4], [24, 22, 1], [26, 12, 1]];
export function nodeVersionSupported(version = process.versions.node) {
  const [major, minor, patch] = version.split('.').map(Number);
  return NODE_MINIMUMS.some(([maj, min, pat]) => major === maj && (minor > min || (minor === min && patch >= pat)));
}

export async function main(args = process.argv.slice(2)) {
  if (!nodeVersionSupported()) {
    console.error(`Node.js ${process.versions.node} is not a supported patched release (need 22.23.4+, 24.22.1+ or 26.12.1+; see docs/DEVELOPMENT.md).`);
    return 1;
  }
  const options = { check: false, list: false, force: false, only: null };
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--help') {
      console.log('node tools/sync_assets.mjs [--check | --list] [--only ASSET_ID] [--force]\n' +
        'Downloads missing locked Poly Haven files. Existing matches are skipped.\n' +
        '--check and --list are offline. --force replaces changed local files.');
      return 0;
    }
    if (args[i] === '--only') { options.only = args[++i]; if (!options.only) throw new Error('--only requires an asset ID'); }
    else if (['--check', '--list', '--force'].includes(args[i])) options[args[i].slice(2)] = true;
    else throw new Error('Unknown option: ' + args[i]);
  }
  if (options.check && options.list) throw new Error('Choose --check or --list');
  const manifest = validateManifest(JSON.parse(await fsp.readFile(path.join(ROOT, 'tools/assets.lock.json'), 'utf8')));
  const files = manifest.files.filter(x => !options.only || x.asset === options.only);
  if (!files.length) throw new Error('No matching locked assets');
  console.log('Powered by Poly Haven — https://polyhaven.com (CC0 assets; no endorsement).');
  if (options.list) {
    const groups = new Map();
    for (const x of files) {
      const row = groups.get(x.asset) ?? { files: 0, bytes: 0 };
      row.files++; row.bytes += x.bytes; groups.set(x.asset, row);
    }
    for (const [id, row] of groups) console.log(`${id}: ${row.files} files, ${(row.bytes / 1048576).toFixed(1)} MiB — https://polyhaven.com/a/${id}`);
    return 0;
  }
  const api = new Map();
  async function resolve(item) {
    if (!api.has(item.asset)) {
      const response = await request(`https://api.polyhaven.com/files/${item.asset}`, { timeout: 60000 });
      api.set(item.asset, await response.json());
    }
    return resolveFile(api.get(item.asset), item.selector);
  }
  let verified = 0, downloaded = 0, failed = 0;
  for (const item of files) {
    try {
      if (options.check) {
        const file = safePath(ROOT, item.path);
        if (!fs.existsSync(file) || await fileHash(file) !== item.sha256) throw new Error('Missing or changed');
        verified++;
      } else {
        // Low parallelism and bounded retries avoid flooding the public API.
        let result;
        for (let attempt = 0; attempt < 3; attempt++) {
          try { result = await installAsset(item, ROOT, resolve, options); break; }
          catch (error) {
            if (attempt === 2 || /Local file differs|pinned|locked|Sanitized|variant/.test(error.message)) throw error;
            await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
          }
        }
        if (result === 'verified') verified++;
        else { downloaded++; console.log('Downloaded ' + item.path); }
      }
    } catch (error) { failed++; console.error(`${item.path}: ${error.message}`); }
  }
  console.log(`Verified ${verified}; downloaded ${downloaded}; missing/failed ${failed}.`);
  if (failed) console.error('See docs/ASSETS.md. No unverified replacement files were installed.');
  return failed ? 1 : 0;
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  main().then(code => { process.exitCode = code; }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
