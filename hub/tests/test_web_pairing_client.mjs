import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../regina_hub/web/common.js', import.meta.url), 'utf8');

function browser(href, kind = 'phone', request = async () => ({ ok: true, json: async () => ({ token: 'local-fixture' }) })) {
  const sockets = [], timers = [], requests = [], stored = new Map(), states = [], messages = [];
  const location = new URL(href);
  class WebSocket {
    static OPEN = 1;
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    opened() { this.readyState = 1; this.onopen(); }
    message(value) { this.onmessage({ data: JSON.stringify(value) }); }
    close(code = 1000) { this.readyState = 3; this.onclose?.({ code }); }
  }
  const context = vm.createContext({
    navigator: { language: 'en' }, location, URLSearchParams, WebSocket,
    localStorage: { getItem: key => stored.get(key), setItem: (key, value) => stored.set(key, value) },
    setTimeout(fn, delay) { const timer = { fn, delay }; timers.push(timer); return timer; },
    clearTimeout(timer) { timer.cancelled = true; },
    fetch: async (...args) => { requests.push(args); return request(...args); },
  });
  vm.runInContext(source, context);
  const Connection = vm.runInContext('RS.HubConnection', context);
  const connection = new Connection({ kind, name: 'Fixture', onState: state => states.push(state), onMessage: message => messages.push(message) });
  return { connection, location, sockets, timers, requests, stored, states, messages };
}

async function settle() { for (let i = 0; i < 8; i++) await Promise.resolve(); }

function nextRetry(b) {
  const timer = b.timers.find(timer => !timer.cancelled && !timer.ran);
  assert.ok(timer, 'a retry should be scheduled');
  timer.ran = true;
  timer.fn();
  return timer.delay;
}

test('phone sends a fragment token in hello and waits for welcome before input', () => {
  const b = browser('https://example.invalid:47843/#k=phone-fixture');
  assert.equal(b.sockets.length, 1);
  const ws = b.sockets[0];
  assert.equal(ws.url, 'wss://example.invalid:47843/ws');
  ws.opened();
  assert.equal(ws.sent.length, 1);
  assert.equal(ws.sent[0].t, 'hello');
  assert.equal(ws.sent[0].token, 'phone-fixture');
  assert.equal(b.connection.open, false);
  b.connection.send({ t: 'in', b: 1 });
  assert.equal(ws.sent.length, 1);
  ws.message({ t: 'welcome', id: 1, player: 1 });
  assert.equal(b.connection.open, true);
  b.connection.send({ t: 'in', b: 1 });
  assert.equal(ws.sent.length, 2);
  assert.equal(ws.sent[1].token, undefined);
  assert.equal(b.requests.length, 0);
  assert.ok(![...b.stored.values()].includes('phone-fixture'));
});

test('a phone reconnect reuses the fragment but not a token removed from its URL', () => {
  const b = browser('https://example.invalid/#k=phone-fixture');
  b.sockets[0].opened();
  b.sockets[0].message({ t: 'welcome', id: 1, player: 1 });
  b.sockets[0].close(1006);
  assert.equal(nextRetry(b), 500);
  b.sockets[1].opened();
  assert.equal(b.sockets[1].sent[0].token, 'phone-fixture');
  b.sockets[1].close(1006);
  b.location.hash = '';
  nextRetry(b);
  assert.equal(b.sockets.length, 2);
  assert.equal(b.states.at(-1), 'pair_required');
  assert.ok(!b.timers.some(timer => !timer.ran && !timer.cancelled));
});

test('missing or query-only pairing data does not open a socket or start a retry loop', () => {
  for (const href of ['https://example.invalid/', 'https://example.invalid/?k=query-fixture', 'https://example.invalid/#k=']) {
    const b = browser(href);
    assert.equal(b.sockets.length, 0);
    assert.equal(b.requests.length, 0);
    assert.equal(b.timers.length, 0);
    assert.equal(b.states.at(-1), 'pair_required');
  }
});

test('policy rejection stops reconnecting and a new QR token permits an explicit retry', () => {
  const b = browser('https://example.invalid/#k=wrong-fixture');
  b.sockets[0].opened();
  b.sockets[0].close(1008);
  assert.equal(b.connection.open, false);
  assert.equal(b.states.at(-1), 'pair_required');
  assert.equal(b.timers.length, 0);
  b.location.hash = '#k=new-fixture';
  b.connection.connect();
  b.sockets[1].opened();
  assert.equal(b.sockets[1].sent[0].token, 'new-fixture');
});

test('only an HTTP loopback simulator bootstraps its token from the local API', async () => {
  for (const host of ['127.0.0.1', 'localhost', '[::1]']) {
    const b = browser(`http://${host}:47802/sim`, 'sim');
    await settle();
    assert.equal(b.requests.length, 1);
    const [path, options] = b.requests[0];
    assert.equal(path, '/api/pairing');
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.redirect, 'error');
    assert.equal(b.sockets.length, 1);
    b.sockets[0].opened();
    assert.equal(b.sockets[0].sent[0].token, 'local-fixture');
  }
  for (const href of ['https://localhost/sim', 'http://192.0.2.1/sim', 'https://example.invalid/sim']) {
    const b = browser(href, 'sim');
    await settle();
    assert.equal(b.requests.length, 0);
    assert.equal(b.sockets.length, 0);
    assert.equal(b.states.at(-1), 'pair_required');
  }
  const phone = browser('http://127.0.0.1:47802/', 'phone');
  await settle();
  assert.equal(phone.requests.length, 0);
  assert.equal(phone.sockets.length, 0);
});

test('an API policy failure or invalid response does not open a socket', async () => {
  for (const response of [
    { ok: false, status: 403 },
    { ok: true, json: async () => ({}) },
    { ok: true, json: async () => ({ token: 42 }) },
    { ok: true, json: async () => ({ token: '' }) },
  ]) {
    const b = browser('http://127.0.0.1:47802/sim', 'sim', async () => response);
    await settle();
    assert.equal(b.sockets.length, 0);
    assert.equal(b.timers.length, 0);
    assert.equal(b.states.at(-1), 'pair_required');
  }
});

test('network failures retry with backoff and read the current simulator token', async () => {
  let available = false;
  const b = browser('http://127.0.0.1:47802/sim', 'sim', async () => {
    if (!available) throw new Error('network unavailable');
    return { ok: true, json: async () => ({ token: 'replacement-fixture' }) };
  });
  await settle();
  assert.equal(b.states.at(-1), 'disconnected');
  assert.equal(nextRetry(b), 500);
  await settle();
  assert.equal(nextRetry(b), 1000);
  await settle();
  available = true;
  assert.equal(nextRetry(b), 2000);
  await settle();
  b.sockets[0].opened();
  assert.equal(b.sockets[0].sent[0].token, 'replacement-fixture');
  b.sockets[0].message({ t: 'welcome' });
  b.sockets[0].close(1006);
  assert.equal(nextRetry(b), 500);
});

test('stale simulator bootstrap results and socket callbacks cannot replace a newer connection', async () => {
  let release;
  let calls = 0;
  const b = browser('http://127.0.0.1:47802/sim', 'sim', () => {
    if (++calls === 1) return new Promise(resolve => { release = resolve; });
    return Promise.resolve({ ok: true, json: async () => ({ token: 'new-fixture' }) });
  });
  b.connection.connect();
  await settle();
  release({ ok: true, json: async () => ({ token: 'old-fixture' }) });
  await settle();
  assert.equal(b.sockets.length, 1);
  const old = b.sockets[0];
  b.connection.connect();
  await settle();
  old.onclose({ code: 1006 });
  old.message({ t: 'welcome' });
  assert.equal(b.connection.ws, b.sockets[1]);
  assert.equal(b.connection.open, false);
  assert.equal(b.timers.length, 0);
});

test('invalid server messages are ignored and transient errors preserve bounded reconnects', () => {
  const b = browser('https://example.invalid/#k=phone-fixture');
  const ws = b.sockets[0];
  ws.opened();
  for (const value of [null, [], 1, 'invalid']) ws.message(value);
  ws.onmessage({ data: '{' });
  assert.equal(b.connection.open, false);
  ws.onerror();
  ws.onclose({ code: 1006 });
  assert.equal(b.timers.length, 1);
});
