import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { cachePaths, installAsset, main, nodeVersionSupported, request, resolveFile, safePath, sha256, validateManifest, validateUrl } from '../sync_assets.mjs';
import { sanitizeJpegProcessingHistory } from '../asset_metadata.mjs';
import { policyRule, shadowedRules } from '../asset_policy.mjs';

const remote = { url: 'https://dl.polyhaven.com/file/ph-assets/fixture.bin' };
const fixture = () => fs.mkdtempSync(path.join(os.tmpdir(), 'regina-assets-'));
function item(bytes) {
  return { path: 'game/assets/polyhaven/fixture.bin', bytes: bytes.length,
    sha256: sha256(bytes), downloadSha256: sha256(bytes) };
}
const response = bytes => new Response(bytes);

function lockedFixture(bytes) {
  const root = fixture(), entry = { ...item(bytes), asset: 'fixture', selector: ['bin'] };
  const manifest = { version: 1, files: [entry] };
  fs.mkdirSync(path.join(root, 'tools'));
  fs.writeFileSync(path.join(root, 'tools/assets.lock.json'), JSON.stringify(manifest));
  return { root, entry, manifest };
}

function offlineRun(root) {
  const output = [], errors = [];
  let calls = 0;
  return { output, errors, calls: () => calls, options: { root,
    fetcher: async () => { calls++; throw new Error('Network is forbidden on a cache hit'); },
    log: text => output.push(text), error: text => errors.push(text) } };
}

test('an exact cache hit checks locked bytes with API and downloads forbidden', async () => {
  const bytes = Buffer.from('warm cache'), { root, entry } = lockedFixture(bytes);
  const dest = safePath(root, entry.path), run = offlineRun(root);
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, bytes);
  assert.equal(await main(['--check'], run.options), 0);
  assert.equal(run.calls(), 0);
  assert.equal(run.output.at(-1), 'Verified 1; downloaded 0; missing/failed 0.');
  assert.deepEqual(run.errors, []);
});

test('missing or corrupt cache hits fail offline without repairing the cache', async () => {
  for (const contents of [null, 'corrupt cache']) {
    const { root, entry } = lockedFixture(Buffer.from('warm cache'));
    const dest = safePath(root, entry.path), run = offlineRun(root);
    if (contents !== null) {
      fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, contents);
    }
    assert.equal(await main(['--check'], run.options), 1);
    assert.equal(run.calls(), 0);
    assert.ok(run.errors.some(error => error.startsWith(entry.path + ':')));
    assert.equal(run.output.at(-1), 'Verified 0; downloaded 0; missing/failed 1.');
    assert.equal(fs.existsSync(dest) ? fs.readFileSync(dest, 'utf8') : null, contents);
  }
});

test('a symlink in a cache destination fails offline and reports its locked path', async () => {
  const bytes = Buffer.from('warm cache'), { root, entry } = lockedFixture(bytes), run = offlineRun(root);
  const target = path.join(root, 'cached'), link = path.join(root, 'game/assets/polyhaven');
  fs.mkdirSync(target); fs.writeFileSync(path.join(target, 'fixture.bin'), bytes);
  fs.mkdirSync(path.dirname(link), { recursive: true });
  fs.symlinkSync(target, link, process.platform === 'win32' ? 'junction' : 'dir');
  await assert.rejects(main(['--check'], run.options), error => error.message.includes('symlink') && error.message.includes(entry.path));
  assert.equal(run.calls(), 0);
  assert.deepEqual(run.output, []);
  assert.deepEqual(fs.readFileSync(path.join(target, 'fixture.bin')), bytes);
});

test('a cold sync installs locked bytes and passes a subsequent offline check', async () => {
  const bytes = Buffer.from('cold cache'), { root } = lockedFixture(bytes), calls = [];
  const run = offlineRun(root);
  assert.equal(await main([], { ...run.options, fetcher: async url => {
    calls.push(url.href);
    return url.hostname === 'api.polyhaven.com' ? response(JSON.stringify({ bin: remote })) : response(bytes);
  } }), 0);
  assert.deepEqual(calls, ['https://api.polyhaven.com/files/fixture', remote.url]);
  assert.equal(await main(['--check'], run.options), 0);
  assert.equal(run.calls(), 0);
  assert.equal(run.output.at(-1), 'Verified 1; downloaded 0; missing/failed 0.');
});

test('cache paths output contains only validated locked paths with no network or banner', async () => {
  const { root, entry } = lockedFixture(Buffer.from('cache paths')), run = offlineRun(root);
  execFileSync('git', ['-C', root, 'init', '--quiet']);
  assert.equal(await main(['--cache-paths'], run.options), 0);
  assert.deepEqual(run.output, [entry.path]);
  assert.deepEqual(run.errors, []);
  assert.equal(run.calls(), 0);
  for (const extra of ['--check', '--list', '--force', '--only'])
    await assert.rejects(main(['--cache-paths', extra, ...(extra === '--only' ? ['fixture'] : [])], run.options));
});

test('cache paths reject newline/glob expansion, directories and non-raw files', () => {
  const { root, entry } = lockedFixture(Buffer.from('cache paths'));
  for (const name of ['x\ny.jpg', 'x\ry.jpg', 'x\u2028y.jpg', 'x*y.jpg', 'x?y.jpg', '[xy].jpg', '{x,y}.jpg',
    '!x.jpg', 'x@(y).jpg', 'x y.jpg', '.godot/x.jpg', 'CREDITS.md', 'x.gltf', 'x.jpg.import', 'x.mjs'])
    assert.throws(() => cachePaths({ version: 1, files: [{ ...entry, path: 'game/assets/polyhaven/' + name }] }, root), /Unsafe asset cache path/);
  fs.mkdirSync(safePath(root, entry.path), { recursive: true });
  assert.throws(() => cachePaths({ version: 1, files: [entry] }, root), /Unsafe asset cache path/);
});

test('cache paths reject Git-tracked intersections before emitting any path', async () => {
  const bytes = Buffer.from('tracked cache'), { root, entry, manifest } = lockedFixture(bytes);
  const dest = safePath(root, entry.path), run = offlineRun(root);
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, bytes);
  execFileSync('git', ['-C', root, 'init', '--quiet']);
  execFileSync('git', ['-C', root, 'add', '--force', '--', entry.path]);
  assert.throws(() => cachePaths(manifest, root), /overlaps a Git-tracked path/);
  await assert.rejects(main(['--cache-paths'], run.options), /overlaps a Git-tracked path/);
  assert.deepEqual(run.output, []);
  assert.equal(run.calls(), 0);
});

test('cache paths reject case aliases and ancestor/descendant overlap within missing candidates', () => {
  const { root, entry } = lockedFixture(Buffer.from('cache paths'));
  execFileSync('git', ['-C', root, 'init', '--quiet']);
  for (const paths of [
    ['fixture.bin', 'FIXTURE.bin'],
    ['foo.bin', 'foo.bin/child.bin'],
    ['foo.bin/child.bin', 'foo.bin']
  ]) {
    const manifest = { version: 1, files: paths.map(name => ({ ...entry, path: 'game/assets/polyhaven/' + name })) };
    assert.ok(manifest.files.every(file => !fs.existsSync(safePath(root, file.path))));
    assert.throws(() => cachePaths(manifest, root), /Asset cache paths overlap/);
  }
});

test('verified local files need no network request', async () => {
  const root = fixture(), bytes = Buffer.from('known asset'), entry = item(bytes), dest = safePath(root, entry.path);
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, bytes);
  const result = await installAsset(entry, root, () => { throw new Error('Network should not be used'); });
  assert.equal(result, 'verified');
});

test('a download is installed only after its size and SHA-256 match', async () => {
  const root = fixture(), bytes = Buffer.from('known asset'), entry = item(bytes);
  assert.equal(await installAsset(entry, root, () => remote, { fetcher: async () => response(bytes) }), 'downloaded');
  assert.deepEqual(fs.readFileSync(safePath(root, entry.path)), bytes);
});

test('wrong content leaves a changed local file intact and removes temporary files', async () => {
  const root = fixture(), bytes = Buffer.from('known asset'), entry = item(bytes), dest = safePath(root, entry.path);
  fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, 'custom art');
  await assert.rejects(installAsset(entry, root, () => remote), /Local file differs/);
  await assert.rejects(installAsset(entry, root, () => remote,
    { force: true, fetcher: async () => response(Buffer.from('wrong asset')) }), /pinned/);
  assert.equal(fs.readFileSync(dest, 'utf8'), 'custom art');
  assert.deepEqual(fs.readdirSync(path.dirname(dest)), ['fixture.bin']);
});

test('oversized and interrupted responses never install partial data', async () => {
  for (const fetcher of [async () => response('too much data'), async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(Buffer.from('a')); controller.error(new Error('interrupted')); }
  }))]) {
    const root = fixture(), entry = item(Buffer.from('ok'));
    await assert.rejects(installAsset(entry, root, () => remote, { fetcher }));
    assert.equal(fs.existsSync(safePath(root, entry.path)), false);
    assert.deepEqual(fs.readdirSync(path.dirname(safePath(root, entry.path))), []);
  }
});

test('paths and redirects cannot escape approved destinations', async () => {
  const root = fixture();
  for (const p of ['../elsewhere', '/absolute', 'folder/../escape', 'folder\\escape'])
    assert.throws(() => safePath(root, p));
  const credentialUrl = new URL(remote.url);
  credentialUrl.username = 'fixture-user'; credentialUrl.password = 'fixture-password';
  for (const url of ['http://dl.polyhaven.com/file', 'https://polyhaven.com.example.org/file',
    'https://example.org/file', credentialUrl.href]) assert.throws(() => validateUrl(url));
  let calls = 0;
  await assert.rejects(request(remote.url, { fetcher: async () => {
    calls++; return new Response(null, { status: 302, headers: { location: 'https://example.org/file' } });
  } }), /approved/);
  assert.equal(calls, 1);
});

test('API selectors include the exact requested model dependency', () => {
  const info = { gltf: { '2k': { gltf: { include: { 'textures/fixture.jpg': remote } } } } };
  assert.equal(resolveFile(info, ['gltf', '2k', 'gltf', 'include', 'textures/fixture.jpg']), remote);
  assert.throws(() => resolveFile(info, ['gltf', '4k', 'gltf']), /no longer listed/);
});

function historyJpeg() {
  const history = Buffer.from(['C:', 'Users', 'Fixture', 'processing-command-'.repeat(5)].join('/') + '\0');
  const copyright = Buffer.from('Example creator; CC0\0');
  const start = 8 + 2 + 2 * 12 + 4, tiff = Buffer.alloc(start + history.length + copyright.length);
  tiff.write('II'); tiff.writeUInt16LE(42, 2); tiff.writeUInt32LE(8, 4); tiff.writeUInt16LE(2, 8);
  for (const [i, tag, value, offset] of [[0, 0x0131, history, start], [1, 0x8298, copyright, start + history.length]]) {
    const p = 10 + i * 12; tiff.writeUInt16LE(tag, p); tiff.writeUInt16LE(2, p + 2);
    tiff.writeUInt32LE(value.length, p + 4); tiff.writeUInt32LE(offset, p + 8); value.copy(tiff, offset);
  }
  const exif = Buffer.concat([Buffer.from('Exif\0\0'), tiff]), length = Buffer.alloc(2);
  length.writeUInt16BE(exif.length + 2);
  const pixels = Buffer.from([255, 218, 0, 2, 2, 4, 6, 8, 255, 217]);
  return { jpeg: Buffer.concat([Buffer.from([255, 216, 255, 225]), length, exif, pixels]), pixels, copyright };
}

test('processing-history cleanup preserves copyright and compressed pixel bytes', () => {
  const { jpeg, pixels, copyright } = historyJpeg(), cleaned = sanitizeJpegProcessingHistory(jpeg);
  assert.equal(cleaned.length, jpeg.length);
  assert.ok(cleaned.subarray(-pixels.length).equals(pixels));
  assert.ok(cleaned.includes(copyright));
  assert.ok(!cleaned.includes(Buffer.from('processing-command-')));
  assert.ok(jpeg.includes(Buffer.from('processing-command-'))); // Input is not mutated.
});

test('sanitized downloads must match the final hash before installation', async () => {
  const root = fixture(), { jpeg } = historyJpeg(), cleaned = sanitizeJpegProcessingHistory(jpeg);
  const entry = { ...item(cleaned), downloadSha256: sha256(jpeg), transform: 'jpeg-processing-history-v1' };
  assert.equal(await installAsset(entry, root, () => remote, { fetcher: async () => response(jpeg) }), 'downloaded');
  assert.deepEqual(fs.readFileSync(safePath(root, entry.path)), cleaned);
});

test('only patched Node lines are supported (#51)', () => {
  assert.equal(nodeVersionSupported('22.23.4'), true);
  assert.equal(nodeVersionSupported('22.23.3'), false);
  assert.equal(nodeVersionSupported('24.22.1'), true);
  assert.equal(nodeVersionSupported('26.12.1'), true);
  assert.equal(nodeVersionSupported('20.19.0'), false);
  assert.equal(nodeVersionSupported('23.11.0'), false);
  assert.equal(nodeVersionSupported('28.0.0'), true);  // newer majors than the list are not blocked
});

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const policy = JSON.parse(fs.readFileSync(path.join(repo, 'tools/asset_policy.json'), 'utf8'));

test('shared asset library files are documented CC0 sources (#58)', () => {
  for (const p of ['game/assets/shared/arena/arena_bleacher.glb', 'game/assets/shared/materials/acg_net004a/acg_net004a_diff_2k.png']) {
    assert.equal(policyRule(policy.pending, p), undefined);
    const rule = policyRule(policy.documented, p);
    assert.equal(rule?.license, 'CC0-1.0');
    assert.equal(rule.evidence, 'game/assets/shared/CREDITS.md');
  }
  assert.equal(policyRule(policy.documented, 'game/assets/sharedx/a.png')?.prefix, undefined);
});

test('asset policy rules point at existing evidence and none is shadowed', () => {
  for (const r of policy.documented) assert.ok(fs.existsSync(path.join(repo, r.evidence.split('#')[0])), r.evidence);
  assert.deepEqual(shadowedRules(policy.documented), []);
  assert.deepEqual(shadowedRules(policy.pending), []);
  const rules = [{ prefix: 'a/' }, { prefix: 'a/b/' }, { prefix: 'c/', extensions: ['.png'] }, { prefix: 'c/d/' }];
  assert.deepEqual(shadowedRules(rules).map(r => r.prefix), ['a/b/']);
});

test('locked entries may carry a planned-use note, but only as text', () => {
  const entry = { path: 'game/assets/polyhaven/x/x_2k.jpg', asset: 'x', selector: ['Diffuse', '2k', 'jpg'],
    bytes: 1, sha256: 'a'.repeat(64), downloadSha256: 'a'.repeat(64) };
  assert.doesNotThrow(() => validateManifest({ version: 1, files: [{ ...entry, purpose: 'C6 hall shell' }] }));
  for (const purpose of ['', 7, ['C6']])
    assert.throws(() => validateManifest({ version: 1, files: [{ ...entry, purpose }] }), /Invalid locked asset entry/);
  const lock = validateManifest(JSON.parse(fs.readFileSync(path.join(repo, 'tools/assets.lock.json'), 'utf8')));
  const noted = new Set(lock.files.filter(x => x.purpose).map(x => x.asset));
  for (const id of ['painted_metal_shutter', 'painted_plaster_wall', 'red_brick', 'sparse_grass', 'white_plaster_02',
    'WetFloorSign_01', 'concrete_cat_statue', 'rollershutter_window_01', 'spray_paint_bottles'])
    assert.ok(noted.has(id) && lock.files.filter(x => x.asset === id).every(x => x.purpose), id);
});
