'use strict';

// Runs ios/Limitty.js under Node with minimal fakes of Scriptable's APIs.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');

const SRC = fs.readFileSync(path.join(__dirname, '..', 'ios', 'Limitty.js'), 'utf8');

function jwt(claims) {
  const b = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${b({ alg: 'none' })}.${b(claims)}.sig`;
}

function makeEnv(routes, keychain = {}) {
  const calls = [];
  const files = {};
  const store = new Map(Object.entries(keychain));

  class Node {
    constructor(kind, extra) { Object.assign(this, { kind, children: [] }, extra); }
    addStack() { const s = new Node('stack'); this.children.push(s); return s; }
    addText(t) { const s = new Node('text', { text: t }); this.children.push(s); return s; }
    addImage(img) { const s = new Node('image', { img }); this.children.push(s); return s; }
    addSpacer(n) { this.children.push(new Node('spacer', { n })); }
    layoutVertically() {} layoutHorizontally() {} centerAlignContent() {} topAlignContent() {} setPadding() {}
    async presentMedium() {}
  }

  const globals = {
    LIMITTY_TEST: true,
    module: { exports: {} },
    Color: Object.assign(class { constructor(h, a) { this.hex = h; this.a = a; } }, { dynamic: (l, d) => ({ l, d }) }),
    Font: { systemFont: (s) => ({ s }), semiboldSystemFont: (s) => ({ s, b: 1 }) },
    Size: class { constructor(w, h) { this.w = w; this.h = h; } },
    Rect: class { constructor(...a) { this.a = a; } },
    Path: class { addRoundedRect() {} },
    DrawContext: class { addPath() {} setFillColor() {} fillPath() {} getImage() { return { image: true }; } },
    DateFormatter: class { useShortTimeStyle() {} string() { return '10:00'; } },
    ListWidget: class extends Node { constructor() { super('widget'); } },
    Data: { fromBase64String: (s) => ({ toRawString: () => Buffer.from(s, 'base64').toString('utf8') }) },
    Keychain: {
      contains: (k) => store.has(k), get: (k) => store.get(k), set: (k, v) => store.set(k, v), remove: (k) => store.delete(k),
    },
    FileManager: {
      local: () => ({
        documentsDirectory: () => '/docs', joinPath: (a, b) => `${a}/${b}`,
        readString: (p) => files[p], writeString: (p, s) => { files[p] = s; },
      }),
    },
    Request: class {
      constructor(url) { this.url = url; }
      async loadString() {
        calls.push({ url: this.url, headers: this.headers });
        const r = routes[this.url];
        if (!r) throw new Error('offline');
        this.response = { statusCode: r.status ?? 200 };
        return typeof r.body === 'string' ? r.body : JSON.stringify(r.body);
      }
    },
    config: { runsInWidget: true, widgetFamily: 'medium' },
    args: { widgetParameter: null },
    Script: { setWidget(w) { globals.widget = w; }, complete() {} },
    Pasteboard: { pasteString: () => null },
    Alert: class {},
  };

  const names = Object.keys(globals);
  // eslint-disable-next-line no-new-func
  const AsyncFn = Object.getPrototypeOf(async () => {}).constructor;
  const run = new AsyncFn(...names, SRC);
  return { globals, calls, store, load: async () => { await run(...names.map((n) => globals[n])); return globals.module.exports; } };
}

const texts = (n) => (n.kind === 'text' ? [n.text] : []).concat(...n.children.map(texts));

const CLAUDE_ROUTES = {
  'https://claude.ai/api/organizations': { body: [{ uuid: 'org-1', capabilities: ['chat', 'claude_max'] }] },
  'https://claude.ai/api/organizations/org-1/usage': {
    body: { five_hour: { utilization: 42, resets_at: new Date(Date.now() + 2 * 3600e3).toISOString() }, seven_day: { utilization: 88, resets_at: null }, seven_day_opus: null },
  },
};

test('ios: claude via sessionKey cookie', async () => {
  const env = makeEnv(CLAUDE_ROUTES, { 'limitty.claude.sessionKey': 'sk-ant-sid01-abc' });
  const m = await env.load();
  const [claude] = await m.loadAll('claude');
  assert.strictEqual(claude.ok, true);
  assert.strictEqual(claude.plan, 'Max');
  assert.deepStrictEqual(claude.windows.map((w) => [w.label, w.usedPercent]), [['Session', 42], ['Weekly', 88]]);
  assert.strictEqual(env.calls[0].headers.Cookie, 'sessionKey=sk-ant-sid01-abc');
});

test('ios: codex via session cookie mints a token, sends account id', async () => {
  const token = jwt({ exp: Date.now() / 1000 + 3600, 'https://api.openai.com/auth': { chatgpt_account_id: 'acct-9' } });
  const env = makeEnv({
    'https://chatgpt.com/api/auth/session': { body: { accessToken: token } },
    'https://chatgpt.com/backend-api/wham/usage': {
      body: { plan_type: 'plus', rate_limit: { primary_window: { used_percent: 12, limit_window_seconds: 18000, reset_after_seconds: 600 }, secondary_window: { used_percent: 50, limit_window_seconds: 604800, reset_at: 1893456000 } } },
    },
  }, { 'limitty.codex.auth': 'a.b.c.d.e' });
  const m = await env.load();
  const [codex] = await m.loadAll('codex');
  assert.strictEqual(codex.ok, true, codex.error);
  assert.strictEqual(codex.plan, 'Plus');
  assert.deepStrictEqual(codex.windows.map((w) => [w.label, w.usedPercent]), [['Session', 12], ['Weekly', 50]]);
  assert.strictEqual(env.calls[0].headers.Cookie, '__Secure-next-auth.session-token=a.b.c.d.e');
  assert.strictEqual(env.calls[1].headers['ChatGPT-Account-Id'], 'acct-9');
});

test('ios: expired pasted codex token gives a clear error', async () => {
  const env = makeEnv({}, { 'limitty.codex.auth': jwt({ exp: 1000 }) });
  const m = await env.load();
  const [codex] = await m.loadAll('codex');
  assert.deepStrictEqual([codex.ok, codex.error], [false, 'Token expired']);
});

test('ios: offline falls back to cached numbers marked stale', async () => {
  const env = makeEnv(CLAUDE_ROUTES, { 'limitty.claude.sessionKey': 'k' });
  const m = await env.load();
  await m.loadAll('claude');
  for (const k of Object.keys(CLAUDE_ROUTES)) delete CLAUDE_ROUTES[k];
  const [again] = await m.loadAll('claude');
  assert.strictEqual(again.ok, true);
  assert.strictEqual(again.stale, true);
});

test('ios: widget renders every family; not-signed-in shows hint', async () => {
  const env = makeEnv({});
  const m = await env.load();
  const results = await m.loadAll();
  for (const fam of ['small', 'medium', 'large', 'accessoryRectangular', 'accessoryInline', 'accessoryCircular']) {
    const all = texts(m.buildWidget(results, fam)).join(' | ');
    assert.ok(all.length > 0, fam);
    if (fam === 'medium') assert.match(all, /Not signed in/);
  }
});

test('ios: main() sets a widget when run as widget', async () => {
  const env = makeEnv({});
  const m = await env.load();
  await m.main();
  assert.strictEqual(env.globals.widget.kind, 'widget');
});

test('ios: classifies codex logins', async () => {
  const m = await makeEnv({}).load();
  assert.strictEqual(m.classifyCodexAuth('eyJa.eyJb.c').kind, 'token');
  assert.strictEqual(m.classifyCodexAuth('eyJa.b.c.d.e').kind, 'cookie');
  assert.strictEqual(m.classifyCodexAuth('__Secure-next-auth.session-token.0=x; __Secure-next-auth.session-token.1=y').kind, 'cookie');
  assert.strictEqual(m.classifyCodexAuth('hello').kind, 'unknown');
});
