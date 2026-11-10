'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-agent-'));
process.env.LIMITTY_HOME = HOME;

const { applyEvent, tick, snapshot, PENDING_TOOL_MS } = require('../src/agents/state');
const { deriveFromLines } = require('../src/agents/codex');
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

test('snapshot sorts attention first', () => {
  const { sessions } = run([
    { t: 1, agent: 'codex', event: 'log', session: 'a', cwd: '/p/one', detail: { state: 'working' } },
    { t: 2, agent: 'claude', event: 'Notification', session: 'b', cwd: '/p/two', detail: { type: 'permission_prompt', message: 'Needs permission to use Edit' } },
  ]);
  const snap = snapshot(sessions, { host: 'pc', now: 5000 });
  assert.deepStrictEqual(snap.sessions.map((s) => s.state), ['attention', 'working']);
  assert.strictEqual(snap.sessions[0].name, 'Claude Code');
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
  assert.ok(a.Stop[0].command.endsWith(`hook.js" "agy" "Stop" "${hooks.MARK}"`), a.Stop[0].command);
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

test('hooks: the installed commands really run and record events (Claude via shell, Codex via argv)', () => {
  const { execSync, spawnSync } = require('child_process');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-hookrun-'));
  const claude = path.join(dir, 'settings.json');
  hooks.installClaude(claude);
  assert.ok(fs.existsSync(hooks.hookScriptPath()), 'hook script copied to ~/.limitty');
  const cmd = JSON.parse(fs.readFileSync(claude, 'utf8')).hooks.Notification[0].hooks[0].command;
  const events = path.join(process.env.LIMITTY_HOME, 'events.jsonl');
  fs.rmSync(events, { force: true });
  // Claude Code runs hook commands through a shell, with the event as JSON on stdin.
  execSync(cmd, { input: JSON.stringify({ hook_event_name: 'Notification', session_id: 'real1', cwd: '/p/x', notification_type: 'permission_prompt', message: 'May I?' }) });
  // Codex runs `notify` as an argument list and appends one JSON argument.
  const toml = path.join(dir, 'config.toml');
  hooks.installCodex(toml);
  const argv = JSON.parse(fs.readFileSync(toml, 'utf8').match(/notify = (\[.*\])/)[1]);
  spawnSync(argv[0], [...argv.slice(1), JSON.stringify({ type: 'agent-turn-complete', 'thread-id': 'th9', cwd: '/p/y' })]);
  const lines = fs.readFileSync(events, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.deepStrictEqual(lines.map((e) => [e.agent, e.event, e.session]), [['claude', 'Notification', 'real1'], ['codex', 'agent-turn-complete', 'th9']]);
  assert.strictEqual(lines[0].detail.message, 'May I?');
});

test('normalize: maps each agent\'s hook payload', () => {
  const c = normalize('claude', '--limitty-hook', { hook_event_name: 'Notification', session_id: 's', cwd: '/x', notification_type: 'permission_prompt', message: 'm' });
  assert.deepStrictEqual([c.event, c.session, c.detail.type], ['Notification', 's', 'permission_prompt']);
  const g = normalize('agy', 'Stop', { conversationId: 'conv', fullyIdle: true });
  assert.deepStrictEqual([g.event, g.session, g.detail.fullyIdle], ['Stop', 'conv', true]);
  const x = normalize('codex', '--limitty-hook', { type: 'agent-turn-complete', 'thread-id': 't1', cwd: '/y' });
  assert.deepStrictEqual([x.event, x.session], ['agent-turn-complete', 't1']);
});

test('daemon: status goes only to the Gist: right away when an agent needs you, else at most every 15 s', async () => {
  const cfg = { github: { token: 'tok', gistId: 'g1', login: 'me' } };
  const calls = [];
  let now = 1_000_000_000;
  const d = new Daemon(cfg, { now: () => now, fetchImpl: async (url, init) => { calls.push({ url, ...init }); return { ok: true, status: 200, json: async () => ({}) }; } });
  const gist = () => calls.filter((c) => c.url === 'https://api.github.com/gists/g1');
  const sessionsSent = (i) => JSON.parse(JSON.parse(gist()[i].body).files['limitty-status.json'].content).sessions;

  d.ingest([{ t: now, agent: 'codex', event: 'log', session: 'c', cwd: '/p/api', detail: { state: 'working' } }]);
  assert.strictEqual(gist().length, 1, 'first change goes out');
  now += 2000;
  d.ingest([{ t: now, agent: 'codex', event: 'log', session: 'c2', cwd: '/p/web', detail: { state: 'working' } }]);
  assert.strictEqual(gist().length, 1, 'a plain change waits for the 15 s gap');
  now += 1000;
  d.ingest([{ t: now, agent: 'claude', event: 'Notification', session: 's', cwd: '/p/site', detail: { type: 'permission_prompt', message: 'Claude needs your permission to use Bash' } }]);
  assert.strictEqual(gist().length, 2, 'needs you: sent right away');
  assert.strictEqual(sessionsSent(1)[0].state, 'attention');
  assert.ok(!calls.some((c) => !c.url.startsWith('https://api.github.com/')), 'nothing sent anywhere else');

  // No change → nothing; heartbeat after 10 min.
  now += 20_000;
  d.requestStatus();
  assert.strictEqual(gist().length, 2);
  now += 11 * 60_000;
  d.requestStatus();
  assert.strictEqual(gist().length, 3);
  d.stop();

  // Not linked to a phone: nothing is sent.
  const offline = new Daemon({}, { fetchImpl: async () => { throw new Error('should not be called'); } });
  offline.ingest([{ t: 1, agent: 'codex', event: 'log', session: 'x', cwd: '/p', detail: { state: 'working' } }]);
  offline.stop();
});

test('hooks: repair rewrites hooks left by an older version, and leaves others alone', () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-repair-'));
  const saved = { HOME: process.env.HOME, CLAUDE_CONFIG_DIR: process.env.CLAUDE_CONFIG_DIR, CODEX_HOME: process.env.CODEX_HOME };
  process.env.HOME = home;
  process.env.CLAUDE_CONFIG_DIR = path.join(home, '.claude');
  process.env.CODEX_HOME = path.join(home, '.codex');
  try {
    const { repairHooks } = require('../src/agents/connect');
    // Nothing installed: nothing to do.
    assert.deepStrictEqual(repairHooks(), []);
    // An old-style hook (the app binary + a path inside the app) in Claude Code's settings.
    fs.mkdirSync(process.env.CLAUDE_CONFIG_DIR, { recursive: true });
    const old = `"/opt/Limitty/limitty" "/opt/Limitty/resources/app.asar/src/agents/cli.js" hook claude ${hooks.MARK}`;
    fs.writeFileSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json'), JSON.stringify({ theme: 'dark', hooks: { Stop: [{ hooks: [{ type: 'command', command: old }] }] } }));
    assert.deepStrictEqual(repairHooks(), ['Claude Code']);
    const s = JSON.parse(fs.readFileSync(path.join(process.env.CLAUDE_CONFIG_DIR, 'settings.json'), 'utf8'));
    assert.strictEqual(s.theme, 'dark');
    assert.strictEqual(s.hooks.Stop.length, 1, 'old one replaced, not added to');
    assert.strictEqual(s.hooks.Stop[0].hooks[0].command, hooks.hookCommand('claude'));
    assert.deepStrictEqual(repairHooks(), [], 'up to date now');
  } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
});
