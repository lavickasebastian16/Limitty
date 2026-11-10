'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-agent-'));
process.env.LIMITTY_HOME = HOME;

const { applyEvent, tick, snapshot, alertText, PENDING_TOOL_MS } = require('../src/agents/state');
const { deriveFromLines } = require('../src/agents/codex');
const { seal, open } = require('../src/agents/crypto');
const hooks = require('../src/agents/hooks');
const config = require('../src/agents/config');
const { normalize } = require('../src/agents/cli');
const { Daemon } = require('../src/agents/daemon');

const run = (events, sessions = {}) => {
  const alerts = [];
  for (const ev of events) {
    const r = applyEvent(sessions, ev);
    sessions = r.sessions;
    if (r.alert) alerts.push(`${r.alert.kind}:${r.alert.session.agent}`);
  }
  return { sessions, alerts };
};

test('claude: working → needs permission → working → finished', () => {
  const ev = (event, detail = {}, t = 1000) => ({ t, agent: 'claude', event, session: 's1', cwd: '/home/me/proj-a', detail });
  const { sessions, alerts } = run([
    ev('UserPromptSubmit'),
    ev('PreToolUse', { tool: 'Bash' }),
    ev('Notification', { type: 'permission_prompt', message: 'Claude needs your permission to use Bash' }),
  ]);
  const s = sessions['claude:s1'];
  assert.strictEqual(s.state, 'attention');
  assert.strictEqual(s.project, 'proj-a');
  assert.deepStrictEqual(alerts, ['attention:claude']);

  const after = run([ev('PostToolUse'), ev('Stop'), ev('Notification', { type: 'idle_prompt', message: 'Claude is waiting for your input' })], sessions);
  assert.strictEqual(after.sessions['claude:s1'].state, 'idle');
  assert.strictEqual(after.sessions['claude:s1'].detail, 'Finished');
  assert.deepStrictEqual(after.alerts, ['finished:claude']);

  const ended = run([ev('SessionEnd')], after.sessions);
  assert.strictEqual(ended.sessions['claude:s1'], undefined);
});

test('agy: a tool pending too long becomes "waiting"; Stop(fullyIdle) finishes', () => {
  const ev = (event, detail = {}, t = 1000) => ({ t, agent: 'agy', event, session: 'c1', cwd: '/w/app', detail });
  let { sessions } = run([ev('PreInvocation'), ev('PreToolUse', { tool: 'run_command' })]);
  assert.strictEqual(tick(sessions, 1000 + PENDING_TOOL_MS - 1).changed, false);
  const t = tick(sessions, 1000 + PENDING_TOOL_MS + 1);
  assert.strictEqual(t.sessions['agy:c1'].state, 'waiting');
  assert.match(t.sessions['agy:c1'].detail, /run_command.*approval/);

  const r = run([ev('PostToolUse', {}, 50_000), ev('Stop', { fullyIdle: false }, 50_001), ev('Stop', { fullyIdle: true }, 60_000)], t.sessions);
  assert.strictEqual(r.sessions['agy:c1'].state, 'idle');
  assert.deepStrictEqual(r.alerts, ['finished:agy']);
});

test('stale sessions go idle and are eventually dropped', () => {
  const { sessions } = run([{ t: 0, agent: 'claude', event: 'UserPromptSubmit', session: 'x' }]);
  const a = tick(sessions, 16 * 60_000);
  assert.strictEqual(a.sessions['claude:x'].state, 'idle');
  const b = tick(a.sessions, 4 * 3600_000);
  assert.deepStrictEqual(b.sessions, {});
});

test('codex: derives state from rollout lines', () => {
  const l = (type, payload, ts = '2026-11-10T10:00:00Z') => JSON.stringify({ timestamp: ts, type, payload });
  assert.strictEqual(deriveFromLines([l('event_msg', { type: 'task_started' })]).state, 'working');
  const pending = deriveFromLines([
    l('event_msg', { type: 'task_started' }),
    l('response_item', { type: 'function_call', name: 'shell', call_id: 'c1' }, '2026-11-10T10:00:05Z'),
  ]);
  assert.deepStrictEqual([pending.state, pending.tool, pending.since], ['pending', 'a shell command', Date.parse('2026-11-10T10:00:05Z')]);
  assert.strictEqual(deriveFromLines([
    l('event_msg', { type: 'task_started' }),
    l('response_item', { type: 'function_call', name: 'shell', call_id: 'c1' }),
    l('response_item', { type: 'function_call_output', call_id: 'c1' }),
  ]).state, 'working');
  assert.strictEqual(deriveFromLines([l('event_msg', { type: 'task_started' }), l('event_msg', { type: 'task_complete' })]).state, 'idle');
  const aborted = deriveFromLines([l('event_msg', { type: 'task_started' }), l('event_msg', { type: 'turn_aborted' })]);
  assert.deepStrictEqual([aborted.state, aborted.aborted], ['idle', true]);
});

test('codex: log events drive the session, notify finishes it once', () => {
  const ev = (event, detail, t) => ({ t, agent: 'codex', event, session: 'th', cwd: 'C:\\code\\api', detail });
  const r = run([
    ev('log', { state: 'working' }, 1),
    ev('log', { state: 'pending', tool: 'a shell command', since: 2 }, 2),
    ev('agent-turn-complete', {}, 3),
    ev('log', { state: 'idle' }, 4),
  ]);
  assert.strictEqual(r.sessions['codex:th'].project, 'api');
  assert.deepStrictEqual(r.alerts, ['finished:codex']);
});

test('crypto: round trip and tamper detection', () => {
  const key = config.base64url(Buffer.alloc(32, 7));
  const box = seal({ hi: 'there' }, key);
  assert.deepStrictEqual(open(box, key), { hi: 'there' });
  const bad = Buffer.from(box, 'base64'); bad[20] ^= 1;
  assert.throws(() => open(bad.toString('base64'), key));
});

test('snapshot sorts attention first and alert text respects privacy', () => {
  const { sessions } = run([
    { t: 1, agent: 'codex', event: 'log', session: 'a', cwd: '/p/one', detail: { state: 'working' } },
    { t: 2, agent: 'claude', event: 'Notification', session: 'b', cwd: '/p/two', detail: { type: 'permission_prompt', message: 'Needs permission to use Edit' } },
  ]);
  const snap = snapshot(sessions, { host: 'pc', now: 5000 });
  assert.deepStrictEqual(snap.sessions.map((s) => s.state), ['attention', 'working']);
  assert.strictEqual(snap.sessions[0].name, 'Claude Code');
  const alert = { kind: 'attention', session: sessions['claude:b'] };
  assert.strictEqual(alertText(alert, { showProjectNames: true }).title, 'Claude Code needs you · two');
  assert.doesNotMatch(JSON.stringify(alertText(alert, { showProjectNames: false })), /two|Edit/);
});

test('hooks: install merges with existing settings and uninstall removes only ours', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-hooks-'));
  const claude = path.join(dir, 'settings.json');
  fs.writeFileSync(claude, JSON.stringify({ model: 'opus', hooks: { Stop: [{ hooks: [{ type: 'command', command: 'say done' }] }] } }));
  hooks.installClaude(claude);
  hooks.installClaude(claude); // idempotent
  let s = JSON.parse(fs.readFileSync(claude, 'utf8'));
  assert.strictEqual(s.model, 'opus');
  assert.strictEqual(s.hooks.Stop.length, 2);
  assert.strictEqual(s.hooks.PreToolUse[0].matcher, '*');
  assert.ok(s.hooks.Notification[0].hooks[0].command.includes(hooks.MARK));
  hooks.uninstallClaude(claude);
  s = JSON.parse(fs.readFileSync(claude, 'utf8'));
  assert.deepStrictEqual(s, { model: 'opus', hooks: { Stop: [{ hooks: [{ type: 'command', command: 'say done' }] }] } });

  const agy = path.join(dir, 'hooks.json');
  hooks.installAgy(agy);
  const a = JSON.parse(fs.readFileSync(agy, 'utf8')).limitty;
  assert.ok(a.Stop[0].command.endsWith(`hook agy Stop ${hooks.MARK}`));
  hooks.uninstallAgy(agy);
  assert.deepStrictEqual(JSON.parse(fs.readFileSync(agy, 'utf8')), {});

  const toml = path.join(dir, 'config.toml');
  fs.writeFileSync(toml, 'model = "gpt-5"\n\n[profiles.fast]\nnotify = ["x"]\n');
  assert.strictEqual(hooks.installCodex(toml).status, 'installed');
  const text = fs.readFileSync(toml, 'utf8');
  assert.ok(text.indexOf('notify = [') < text.indexOf('[profiles.fast]'));
  assert.strictEqual(hooks.installCodex(toml).status, 'already');
  hooks.uninstallCodex(toml);
  assert.strictEqual(fs.readFileSync(toml, 'utf8'), 'model = "gpt-5"\n\n[profiles.fast]\nnotify = ["x"]\n');

  fs.writeFileSync(toml, 'notify = ["my-notifier"]\n');
  assert.strictEqual(hooks.installCodex(toml).status, 'conflict');
});

test('normalize: maps each agent\'s hook payload', () => {
  const c = normalize('claude', '--limitty-hook', { hook_event_name: 'Notification', session_id: 's', cwd: '/x', notification_type: 'permission_prompt', message: 'm' });
  assert.deepStrictEqual([c.event, c.session, c.detail.type], ['Notification', 's', 'permission_prompt']);
  const g = normalize('agy', 'Stop', { conversationId: 'conv', fullyIdle: true });
  assert.deepStrictEqual([g.event, g.session, g.detail.fullyIdle], ['Stop', 'conv', true]);
  const x = normalize('codex', '--limitty-hook', { type: 'agent-turn-complete', 'thread-id': 't1', cwd: '/y' });
  assert.deepStrictEqual([x.event, x.session], ['agent-turn-complete', 't1']);
});

test('daemon: relays encrypted status and plain alerts, within budget', async () => {
  const cfg = { ...config.DEFAULTS, topic: 'limitty-test', key: config.base64url(Buffer.alloc(32, 1)) };
  const posts = [];
  let now = 1_000_000_000;
  const d = new Daemon(cfg, { now: () => now, fetchImpl: async (url, init) => { posts.push({ url, ...init }); return { ok: true, status: 200 }; } });
  d.ingest([{ t: now, agent: 'claude', event: 'Notification', session: 's', cwd: '/p/site', detail: { type: 'permission_prompt', message: 'Claude needs your permission to use Bash' } }]);
  await new Promise((r) => setTimeout(r, 1700));

  const alert = posts.find((p) => p.url.includes('-alerts?'));
  assert.ok(alert, 'alert sent');
  const q = new URL(alert.url).searchParams;
  assert.strictEqual(q.get('title'), 'Claude Code needs you · site');
  assert.strictEqual(q.get('click'), 'limitty://agents');
  assert.strictEqual(alert.body, 'Claude needs your permission to use Bash');
  const status = posts.filter((p) => p.url.endsWith('/limitty-test'));
  assert.strictEqual(status.length, 1, 'one status update');
  const body = open(status[0].body, cfg.key);
  assert.strictEqual(body.sessions[0].state, 'attention');

  // No change → nothing new; heartbeat after 30 min.
  d.requestStatus();
  assert.strictEqual(posts.filter((p) => p.url.endsWith('/limitty-test')).length, 1);
  now += 31 * 60_000;
  d.requestStatus();
  assert.strictEqual(posts.filter((p) => p.url.endsWith('/limitty-test')).length, 2);
  d.stop();
});

test('daemon: with Bark set up on the phone, alerts use Bark with a sound per kind (no ntfy)', async () => {
  const cfg = { ...config.DEFAULTS, topic: 'limitty-test', key: config.base64url(Buffer.alloc(32, 1)), github: { token: 't', gistId: 'g', login: 'me' } };
  const phone = { notify: { bark: { server: 'https://api.day.app', key: 'AbCdEf123456' }, sounds: { attention: 'telegraph', done: 'bell' } } };
  const calls = [];
  const fetchImpl = async (url, init = {}) => {
    calls.push({ url, ...init });
    if (url.endsWith('/gists/g') && (init.method || 'GET') === 'GET') {
      return { ok: true, status: 200, json: async () => ({ files: { 'limitty-phone.json': { content: JSON.stringify(phone) } } }) };
    }
    return { ok: true, status: 200, json: async () => ({}) };
  };
  let now = 2_000_000_000;
  const d = new Daemon(cfg, { now: () => now, fetchImpl });
  await d.pollPhone();
  assert.strictEqual(d.phone.sounds.attention, 'telegraph');
  d.ingest([{ t: now, agent: 'claude', event: 'Notification', session: 's', cwd: '/p/site', detail: { type: 'permission_prompt', message: 'Claude needs your permission to use Bash' } }]);
  now += 1000;
  d.ingest([{ t: now, agent: 'claude', event: 'Stop', session: 's', cwd: '/p/site' }]);
  await new Promise((r) => setTimeout(r, 50));
  const bark = calls.filter((c) => c.url === 'https://api.day.app/push').map((c) => JSON.parse(c.body));
  assert.deepStrictEqual(bark.map((b) => [b.sound, b.level]), [['telegraph', 'timeSensitive'], ['bell', 'active']]);
  assert.match(bark[0].title, /Claude Code needs you/);
  assert.strictEqual(calls.filter((c) => c.url.includes('ntfy')).length, 0, 'no ntfy alerts');
  d.stop();
});
