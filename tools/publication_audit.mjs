#!/usr/bin/env node
/** Read-only publication audit. Outputs relative paths and categories, never matched secrets.
 * Run: node tools/publication_audit.mjs [--strict | --privacy-only] [--write audit-output]
 * Optional Node.js 20+ developer tool; not a game/runtime dependency.
 */
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { inflateSync } from 'node:zlib';
import { policyRule } from './asset_policy.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const policy = JSON.parse(fs.readFileSync(path.join(root, 'tools/asset_policy.json'), 'utf8'));
const ignoredNames = new Set(['.git', '.godot', '.venv', '__pycache__', '.pytest_cache', '.certs',
  '.vscode', '.idea', '.claude', '.codex', 'build', 'dist', 'node_modules']);
const ignoredPrefixes = ['tools/_dl/', 'tools/blender_user/', 'tools/godot/', 'third_party/',
  'publication-preview/', 'audit-output/'];
const ignored = p => p.split('/').some(s => ignoredNames.has(s)) ||
  ignoredPrefixes.some(s => p.startsWith(s)) || /\.(log|pyc|tmp|part|pem|key|p12|pfx|keystore|jsonl)$/i.test(p) ||
  /(^|\/)\.env(?:\.|$)/.test(p) && !p.endsWith('.env.example') || /^firmware\/sdkconfig(?:\.old)?$/.test(p) ||
  ['hub/config.local.json', 'tools/regina_sports.ico'].includes(p);
const findings = [];
const files = [];
let trackedExcluded = [], gitHistoryChecked = false, gitFileSet = null;
const gitArgs = ['-c', `safe.directory=${root.replaceAll('\\', '/')}`];
try {
  const top = execFileSync('git', [...gitArgs, 'rev-parse', '--show-toplevel'],
    { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  if (path.resolve(top).toLowerCase() !== root.toLowerCase()) throw new Error('Different repository root');
  const options = { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 16 << 20 };
  gitFileSet = new Set(execFileSync('git', [...gitArgs, 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], options).split('\0').filter(Boolean));
  trackedExcluded = [...new Set([
    ...execFileSync('git', [...gitArgs, 'ls-files', '-z'], options).split('\0').filter(Boolean).filter(ignored),
    ...execFileSync('git', [...gitArgs, 'ls-files', '--cached', '--ignored', '--exclude-standard', '-z'], options).split('\0').filter(Boolean)
  ])].sort();
  gitHistoryChecked = Number(execFileSync('git', [...gitArgs, 'rev-list', '--all', '--count'], options).trim()) === 0;
} catch { /* A source snapshot can still be scanned; no historical clearance is claimed. */ }
function walk(dir, rel = '') {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = rel ? `${rel}/${e.name}` : e.name;
    if (ignored(p) || ignored(`${p}/`)) continue;
    if (e.isSymbolicLink()) { findings.push({ path: p, category: 'symlink-review' }); continue; }
    if (e.isDirectory()) walk(path.join(dir, e.name), p);
    else if (e.isFile() && (!gitFileSet || gitFileSet.has(p))) files.push(p);
  }
}
walk(root);
files.sort();

const checks = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/g],
  ['github-token', /\b(?:github_pat_[A-Za-z0-9_]{25,}|gh[pousr]_[A-Za-z0-9]{25,})\b/g],
  ['cloud-access-key', /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g],
  ['service-token', /\b(?:sk-(?:proj-)?[A-Za-z0-9_-]{24,}|xox[baprs]-[A-Za-z0-9-]{20,})\b/g],
  ['personal-home-path', /(?:[A-Za-z]:[\\/](?:Users|Documents and Settings)[\\/][^\s"'<>]+|\/(?:Users|home)\/[^\s"'<>]+)/g],
  ['machine-specific-project-path', /[A-Za-z]:[\\/](?:Regina-main|Espressif|_dl)(?:[\\/][^\s"'<>]*)?/gi],
  ['absolute-drive-path', /\b[A-Za-z]:[\\/][^\s"'<>]*/g],
  ['private-network-address', /\b(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2}|169\.254(?:\.\d{1,3}){2})\b/g],
  ['mac-address', /(?<![\w:-])(?:[A-F\d]{2}[:-]){5}[A-F\d]{2}(?![\w:-])/gi],
  ['email-review', /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi],
  ['network-share-path', /\\\\[A-Za-z0-9_-]+\\[A-Za-z0-9_$-]+/g],
  ['credential-in-url', /https?:\/\/[^\s/@:]+:[^\s/@]+@/gi]
];
function scanText(p, text, metadata = false) {
  for (const [category, pattern] of checks) {
    pattern.lastIndex = 0;
    for (const m of text.matchAll(pattern)) {
      // Generic route-selection target; UDP connect sends no packet and reveals no saved host IP.
      if (category === 'private-network-address' && p === 'hub/regina_hub/netutil.py' &&
        m[0] === [10, 255, 255, 255].join('.')) continue;
      findings.push({ path: p, category, ...(metadata ? { location: 'embedded-metadata' } :
        { line: text.slice(0, m.index).split('\n').length }) });
    }
  }
}
function exifText(p, data) {
  // TIFF offsets are relative to the byte-order marker. Do not scan embedded thumbnails.
  if (data.length < 8) return;
  const order = data.subarray(0, 2).toString(), little = order === 'II';
  if (!little && order !== 'MM') return;
  const u16 = n => little ? data.readUInt16LE(n) : data.readUInt16BE(n);
  const u32 = n => little ? data.readUInt32LE(n) : data.readUInt32BE(n);
  if (u16(2) !== 42) return;
  const seen = new Set();
  function ifd(offset) {
    if (!offset || seen.has(offset) || offset + 2 > data.length) return;
    seen.add(offset);
    const count = u16(offset);
    if (count > 4096 || offset + 2 + count * 12 + 4 > data.length) throw new Error('Invalid EXIF directory');
    for (let i = 0; i < count; i++) {
      const pos = offset + 2 + i * 12, tag = u16(pos), type = u16(pos + 2), n = u32(pos + 4);
      if (tag === 0x8825 && u32(pos + 8)) findings.push({ path: p, category: 'gps-metadata-review', location: 'embedded-metadata' });
      if ([0x8769, 0x8825, 0xa005].includes(tag)) { ifd(u32(pos + 8)); continue; }
      if (type !== 2 && tag !== 0x9286 && !(tag >= 0x9c9b && tag <= 0x9c9f)) continue;
      const start = n <= 4 ? pos + 8 : u32(pos + 8);
      if (start + n > data.length) throw new Error('Invalid EXIF value');
      const value = data.subarray(start, start + n);
      scanText(p, value.toString(tag >= 0x9c9b && tag <= 0x9c9f ? 'utf16le' : 'utf8'), true);
    }
    ifd(u32(offset + 2 + count * 12));
  }
  ifd(u32(4));
}
function jpegText(p, b) {
  if (b.length < 4 || b.readUInt16BE(0) !== 0xffd8) return;
  for (let pos = 2; pos + 4 <= b.length;) {
    if (b[pos++] !== 0xff) throw new Error('Invalid JPEG marker');
    while (b[pos] === 0xff) pos++;
    const marker = b[pos++];
    if (marker === 0xda || marker === 0xd9) break; // Compressed pixels contain no metadata fields.
    if (marker === 1 || marker >= 0xd0 && marker <= 0xd7) continue;
    if (pos + 2 > b.length) throw new Error('Truncated JPEG marker');
    const n = b.readUInt16BE(pos);
    if (n < 2 || pos + n > b.length) throw new Error('Invalid JPEG segment');
    const data = b.subarray(pos + 2, pos + n);
    if (marker === 0xe1) {
      if (data.subarray(0, 6).toString() === 'Exif\0\0') exifText(p, data.subarray(6));
      else if (data.subarray(0, 35).toString().startsWith('http://ns.adobe.com/')) scanText(p, data.toString(), true);
    } else if (marker === 0xfe) scanText(p, data.toString(), true);
    else if (marker === 0xed && data.subarray(0, 14).toString() === 'Photoshop 3.0\0') {
      for (let q = 14; q + 12 <= data.length;) {
        if (data.subarray(q, q + 4).toString() !== '8BIM') break;
        const id = data.readUInt16BE(q + 4), nameBytes = 1 + data[q + 6];
        const lengthAt = q + 6 + nameBytes + nameBytes % 2;
        if (lengthAt + 4 > data.length) break;
        const size = data.readUInt32BE(lengthAt), start = lengthAt + 4;
        if (start + size > data.length) throw new Error('Invalid Photoshop resource');
        if ([0x0404, 0x0424].includes(id)) scanText(p, data.subarray(start, start + size).toString(), true);
        q = start + size + size % 2;
      }
    }
    pos += n;
  }
}
function embeddedText(p, b) {
  if (b.subarray(0, 4).toString() === 'glTF' && b.length >= 20) {
    const n = b.readUInt32LE(12);
    if (b.subarray(16, 20).toString() === 'JSON' && n <= b.length - 20)
      scanText(p, JSON.stringify(JSON.parse(b.subarray(20, 20 + n).toString('utf8'))), true);
  } else if (b.subarray(1, 4).toString() === 'PNG') {
    for (let pos = 8; pos + 12 <= b.length;) {
      const n = b.readUInt32BE(pos), type = b.subarray(pos + 4, pos + 8).toString();
      if (pos + 12 + n > b.length) break;
      const data = b.subarray(pos + 8, pos + 8 + n);
      if (['tEXt', 'iTXt'].includes(type)) scanText(p, data.toString('utf8'), true);
      if (type === 'eXIf') exifText(p, data);
      if (type === 'zTXt') {
        const end = data.indexOf(0);
        try { scanText(p, inflateSync(data.subarray(end + 2), { maxOutputLength: 4 << 20 }).toString(), true); }
        catch { findings.push({ path: p, category: 'metadata-decode-review' }); }
      }
      pos += n + 12;
    }
  } else if (b.subarray(0, 4).toString() === 'RIFF' && b.subarray(8, 12).toString() === 'WAVE') {
    for (let pos = 12; pos + 8 <= b.length;) {
      const type = b.subarray(pos, pos + 4).toString(), n = b.readUInt32LE(pos + 4);
      if (pos + 8 + n > b.length) break;
      if (['LIST', 'iXML', '_PMX', 'bext'].includes(type)) scanText(p, b.subarray(pos + 8, pos + 8 + n).toString(), true);
      pos += 8 + n + (n % 2);
    }
  } else if (/\.jpe?g$/i.test(p)) {
    jpegText(p, b);
  }
}
const textExtensions = new Set(['.gd', '.gdshader', '.tscn', '.tres', '.godot', '.import', '.uid', '.py',
  '.mjs', '.js', '.css', '.html', '.md', '.txt', '.json', '.gltf', '.ps1', '.bat', '.sh', '.yml', '.yaml',
  '.toml', '.cfg', '.ini', '.csv', '.h', '.hpp', '.c', '.cpp', '.cmake', '.defaults', '.lock', '.svg']);
const binaryExtensions = new Set(['.glb', '.bin', '.hdr', '.png', '.jpg', '.jpeg', '.wav', '.ico']);
const manifest = [];
for (const p of files) {
  const full = path.join(root, p), stat = fs.statSync(full), ext = path.extname(p).toLowerCase();
  if (textExtensions.has(ext) || /(?:^|\/)(?:LICENSE|CMakeLists\.txt|\.gitignore|\.gitattributes)$/.test(p))
    scanText(p, fs.readFileSync(full, 'utf8'));
  if (binaryExtensions.has(ext)) {
    const b = fs.readFileSync(full);
    const lfsPointer = b.subarray(0, 60).toString().startsWith('version https://git-lfs.github.com/spec/v1');
    try { embeddedText(p, b); } catch { findings.push({ path: p, category: 'metadata-decode-review' }); }
    const pending = policyRule(policy.pending, p);
    const documented = policyRule(policy.documented, p);
    manifest.push({ path: p, bytes: stat.size, sha256: crypto.createHash('sha256').update(b).digest('hex'),
      materialized: !lfsPointer,
      status: pending ? 'pending-rights-review' : documented?.basis === 'maintainer-declaration' ?
        'maintainer-declared-original' : documented ? 'documented-source' : 'needs-source-classification',
      ...(pending ? { reason: pending.reason, source: pending.source } : documented ?
        { license: documented.license, evidence: documented.evidence, ...(documented.basis ? { basis: documented.basis } : {}) } : {}) });
  }
  if (stat.size > 100 * 1024 * 1024) findings.push({ path: p, category: 'exceeds-ordinary-git-file-limit' });
}
// A tracked ignored file is separately reported above; .gitignore cannot untrack it.
const pending = manifest.filter(x => !['documented-source', 'maintainer-declared-original'].includes(x.status));
const report = { scope: '.', scannedFiles: files.length, binaryAssets: manifest.length,
  binaryBytes: manifest.reduce((n, x) => n + x.bytes, 0), findings, trackedExcluded,
  gitHistoryChecked, rightsReviewOutstanding: pending.length,
  maintainerDeclaredOriginals: manifest.filter(x => x.status === 'maintainer-declared-original').length,
  assetsNotMaterialized: manifest.filter(x => !x.materialized).length,
  publishReady: findings.length === 0 && trackedExcluded.length === 0 && pending.length === 0 && manifest.every(x => x.materialized),
  limitations: [
    'Pattern and embedded-metadata scan; not proof that no personal data or unrecognised credentials exist.',
    'Does not inspect image appearance, spoken audio, all binary formats, or historical commits.',
    'Documented sources and maintainer originality declarations are recorded separately; neither is an independent legal guarantee.'
  ] };
const wi = args.indexOf('--write');
if (wi >= 0) {
  if (!args[wi + 1]) throw new Error('--write requires an output directory');
  const out = path.resolve(root, args[wi + 1]);
  if (!out.startsWith(root + path.sep)) throw new Error('Output must remain inside this repository');
  fs.mkdirSync(out, { recursive: true });
  fs.writeFileSync(path.join(out, 'privacy-scan.json'), JSON.stringify(report, null, 2) + '\n');
  fs.writeFileSync(path.join(out, 'asset-manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
}
console.log(JSON.stringify(report, null, 2));
if (args.includes('--strict') && !report.publishReady) process.exitCode = 1;
if (args.includes('--privacy-only') && (findings.length || trackedExcluded.length)) process.exitCode = 1;
