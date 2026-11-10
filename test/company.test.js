'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-co-'));
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');

const { Company, limitsFromResults } = require('../src/company/company');
const { TaskStore } = require('../src/company/store');
const { parsePlan, pickWorker, pickModel, prompt } = require('../src/company/ceo');
const { command } = require('../src/company/workers');

const PROJECT = fs.mkdtempSync(path.join(HOME, 'site-'));

/** Fake workers: records prompts; answers come from `script(worker, prompt, mode)`. */
function fakeRun(script) {
  const calls = [];
  const runImpl = (worker, prompt, { mode, cwd, model }) => {
    calls.push({ worker, mode, prompt, cwd, model });
    let cancel;
    const promise = new Promise((resolve) => {
      const r = script(worker, prompt, mode);
      if (r === 'hang') { cancel = () => resolve({ ok: false, text: 'Cancelled.' }); return; }
      setTimeout(() => resolve(r), 5);
    });
    return { promise, cancel: () => cancel?.() };
  };
  return { runImpl, calls };
}

const until = async (fn, ms = 3000) => {
  const end = Date.now() + ms;
  while (!fn()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 10));
  }
};

function company(script, { installed = () => true, limits = async () => ({ claude: 40, codex: 90, agy: 70 }) } = {}) {
  const fake = fakeRun(script);
  const c = new Company({ store: new TaskStore(path.join(HOME, `co-${Math.random()}.json`)), runImpl: fake.runImpl, installed, limits });
  c.addProject(PROJECT);
  return { c, calls: fake.calls };
}

test('AI CEO plans, workers run the steps in order, results flow to the next step', async () => {
  const plan = JSON.stringify({ summary: 'Build then test', steps: [
    { worker: 'codex', model: 'high', title: 'Add dark mode', instruction: 'Add a dark mode toggle' },
    { worker: 'agy', title: 'Polish UI', instruction: 'Polish the toggle styling' },
  ] });
  const { c, calls } = company((worker, prompt, mode) => (mode === 'plan'
    ? { ok: true, text: `Here you go:\n${plan}` }
    : { ok: true, text: `${worker} finished` }));
  const alerts = [];
  c.on('alert', (a) => alerts.push(a.kind));
  c.limitCache = { at: Date.now(), value: { claude: 40, codex: 90, agy: 70 } };

  const t = c.create({ title: 'Add dark mode', project: path.basename(PROJECT) });
  c.tick();
  await until(() => c.store.get(t.id).status === 'done');

  const done = c.store.get(t.id);
  assert.strictEqual(done.plan.by, 'claude');
  assert.deepStrictEqual(done.plan.steps.map((s) => [s.worker, s.status, s.output]), [['codex', 'done', 'codex finished'], ['agy', 'done', 'agy finished']]);
  assert.strictEqual(calls[0].mode, 'plan');
  assert.match(calls[0].prompt, /codex \(Codex\): 90% of its usage limit left/);
  assert.deepStrictEqual(done.plan.steps.map((s) => s.model), ['high', 'default']);
  assert.strictEqual(calls[1].model, 'high'); // the worker was run with the CEO's model choice
  assert.strictEqual(calls[0].model, 'sonnet'); // planning uses the CEO's balanced model
  assert.strictEqual(c.snapshot().tasks[0].plan.steps[0].modelLabel, 'high effort');
  assert.match(calls[2].prompt, /Earlier steps:[\s\S]*codex finished/);
  assert.strictEqual(calls[1].cwd, PROJECT);
  assert.deepStrictEqual(alerts, ['done']);
  c.stop();
});

test('a failing step fails the task and skips the rest', async () => {
  const plan = JSON.stringify({ summary: 's', steps: [{ worker: 'claude', instruction: 'a' }, { worker: 'codex', instruction: 'b' }] });
  const { c } = company((w, p, mode) => (mode === 'plan' ? { ok: true, text: plan } : { ok: false, text: 'tests failed' }));
  const t = c.create({ title: 'x', project: PROJECT });
  c.tick();
  await until(() => c.store.get(t.id).status === 'failed');
  assert.deepStrictEqual(c.store.get(t.id).plan.steps.map((s) => s.status), ['failed', 'skipped']);
  c.stop();
});

test('picking a worker skips the CEO; cancel stops a running worker', async () => {
  const { c, calls } = company(() => 'hang');
  const t = c.create({ title: 'long job', project: PROJECT, worker: 'codex' });
  c.tick();
  await until(() => c.store.get(t.id).plan?.steps[0].status === 'running');
  assert.strictEqual(calls[0].worker, 'codex');
  assert.strictEqual(calls[0].mode, 'work');
  assert.strictEqual(c.store.get(t.id).plan.by, 'you');
  c.cancel(t.id);
  await until(() => !c.busyWorkers.has('codex'));
  assert.strictEqual(c.store.get(t.id).status, 'cancelled');
  assert.strictEqual(c.store.get(t.id).plan.steps[0].status, 'cancelled');
  c.stop();
});

test('without a usable CEO answer, falls back to the worker with the most limit left', async () => {
  const { c } = company((w, p, mode) => (mode === 'plan' ? { ok: true, text: 'I refuse to use JSON' } : { ok: true, text: 'ok' }));
  c.limitCache = { at: Date.now(), value: { claude: 40, codex: 90, agy: 70 } };
  const t = c.create({ title: 'fix bug', project: PROJECT });
  c.tick();
  await until(() => c.store.get(t.id).status === 'done');
  assert.strictEqual(c.store.get(t.id).plan.steps[0].worker, 'codex');
  assert.match(c.store.get(t.id).plan.summary, /couldn't plan/);
  c.stop();
});

test('no workers installed → clear failure', async () => {
  const { c } = company(() => ({ ok: true, text: '' }), { installed: () => false });
  const t = c.create({ title: 'x', project: PROJECT });
  c.tick();
  await until(() => c.store.get(t.id).status === 'failed');
  assert.match(c.store.get(t.id).error, /No worker is available/);
  c.stop();
});

test('phone inbox requests are handled once; bad project shows as a failed task', () => {
  const { c } = company(() => 'hang');
  c.tick = () => {}; // don't start work in this test
  const req = { id: 'r1', kind: 'create', title: 'from phone', project: path.basename(PROJECT), worker: 'agy' };
  c.handleInbox([req, req]);
  c.handleInbox([req]);
  assert.strictEqual(c.store.tasks.filter((t) => t.title === 'from phone').length, 1);
  assert.strictEqual(c.store.tasks[0].source, 'phone');
  c.handleInbox([{ id: 'r2', kind: 'create', title: 'oops', project: 'nope' }]);
  assert.strictEqual(c.store.tasks[0].status, 'failed');
  assert.match(c.store.tasks[0].error, /Unknown project/);

  const snap = c.snapshot();
  assert.deepStrictEqual(snap.projects.map((p) => p.name), [path.basename(PROJECT)]);
  assert.strictEqual(snap.tasks.length, 2);
  assert.ok('codex' in snap.workers);
});

test('interrupted tasks are marked failed after a restart', () => {
  const file = path.join(HOME, 'restart.json');
  const s1 = new TaskStore(file);
  const t = s1.create({ title: 't', project: { name: 'p', path: PROJECT } });
  s1.update(t.id, (x) => { x.status = 'running'; x.plan = { steps: [{ status: 'running' }] }; });
  const s2 = new TaskStore(file);
  assert.strictEqual(s2.get(t.id).status, 'failed');
  assert.match(s2.get(t.id).error, /Interrupted/);
});

test('plan parsing checks workers and models', () => {
  const team = {
    claude: { available: false, models: [] },
    codex: { available: true, busy: false, remaining: 80, models: [{ id: 'high', tier: 'strongest', remaining: 80 }, { id: 'medium', tier: 'balanced', remaining: 80 }, { id: 'low', tier: 'fast', remaining: 80 }] },
    agy: { available: false, models: [] },
  };
  assert.strictEqual(parsePlan('no json', team), null);
  const p = parsePlan('```json\n{"summary":"s","steps":[{"worker":"gpt","model":"turbo","instruction":"do it"}]}\n```', team);
  assert.deepStrictEqual([p.steps[0].worker, p.steps[0].model], ['codex', 'medium']); // unknown worker/model → sensible defaults
  const q = parsePlan('{"steps":[{"worker":"codex","model":"low","instruction":"fix typo"}]}', team);
  assert.strictEqual(q.steps[0].model, 'low');
  assert.strictEqual(pickWorker({ claude: { available: true, busy: true, remaining: 99 }, codex: { available: true, busy: false, remaining: 10 }, agy: { available: false } }), 'codex');
});

test('model choice avoids models that are nearly out of limit', () => {
  const info = { models: [{ id: 'opus', tier: 'strongest', remaining: 60 }, { id: 'sonnet', tier: 'balanced', remaining: 5 }, { id: 'haiku', tier: 'fast', remaining: 60 }] };
  assert.ok(['opus', 'haiku'].includes(pickModel(info)), 'balanced model is at 5%, so a neighbour is used');
  assert.strictEqual(pickModel({ models: [{ id: 'a', tier: 'balanced', remaining: 3 }, { id: 'b', tier: 'fast', remaining: 9 }] }), 'b');
});

test('team shows per-model limits; CEO prompt lists models and that it can work', () => {
  const { c } = company(() => 'hang');
  c.limitCache = { at: Date.now(), value: { claude: { overall: 70, models: { opus: 10, sonnet: 50 } }, codex: { overall: 90, models: {} }, agy: { overall: 40, models: { pro: 20, flash: 40 } } } };
  const team = c.team();
  assert.deepStrictEqual(team.claude.models.map((m) => [m.id, m.remaining]), [['opus', 10], ['sonnet', 50], ['haiku', 70]]);
  assert.deepStrictEqual(team.agy.models.map((m) => m.id), ['default']); // agy models need slugs in settings
  c.workerOptions = { agyModels: { pro: 'gemini-pro-slug', flash: 'gemini-flash-slug' } };
  assert.deepStrictEqual(c.team().agy.models.map((m) => [m.id, m.remaining]), [['pro', 20], ['flash', 40]]);
  const text = prompt({ title: 't', project: { name: 'p', path: PROJECT } }, c.team(), 'claude');
  assert.match(text, /claude \(Claude Code\) ← this is you, the CEO/);
  assert.match(text, /opus \[strongest, 10% left\]/);
  assert.match(text, /"model": "model id from the list"/);
  c.stop();
});

test('limits from Limitty\'s readers become per-model limits', () => {
  const lim = limitsFromResults([
    { id: 'claude', ok: true, windows: [{ id: 'five_hour', usedPercent: 30 }, { id: 'seven_day', usedPercent: 50 }, { id: 'seven_day_opus', usedPercent: 95 }] },
    { id: 'codex', ok: true, windows: [{ id: 'primary', usedPercent: 10 }, { id: 'secondary', usedPercent: 40 }] },
    { id: 'antigravity', ok: true, windows: [{ label: 'Gemini Pro', usedPercent: 80 }, { label: 'Gemini Flash', usedPercent: 10 }, { label: 'Claude + GPT', usedPercent: 0 }] },
  ]);
  assert.deepStrictEqual(lim.claude, { overall: 50, models: { opus: 5, sonnet: null } });
  assert.deepStrictEqual(lim.codex, { overall: 60, models: {} });
  assert.deepStrictEqual(lim.agy, { overall: 90, models: { pro: 20, flash: 90 } });
});

test('worker commands carry the chosen model', () => {
  const claude = command('claude', 'hi', 'work', {}, 'opus');
  assert.deepStrictEqual(claude.args.slice(0, 5), ['-p', '--output-format', 'json', '--model', 'opus']);
  assert.ok(claude.args.includes('acceptEdits'));
  assert.strictEqual(claude.stdin, 'hi');
  assert.deepStrictEqual(claude.parse('{"type":"result","result":"Done!","is_error":false}'), { text: 'Done!', failed: false });
  assert.ok(command('claude', 'x', 'plan').args.includes('--disallowedTools'));
  const codex = command('codex', 'x', 'work', {}, 'high');
  assert.ok(codex.args.includes('model_reasoning_effort="high"'));
  assert.deepStrictEqual(codex.args.slice(codex.args.indexOf('--sandbox'), codex.args.indexOf('--sandbox') + 2), ['--sandbox', 'workspace-write']);
  assert.ok(!codex.args.includes('--full-auto'), 'removed in newer Codex');
  assert.ok(command('codex', 'x', 'plan').args.includes('read-only'));
  assert.ok(!command('agy', 'x', 'work', {}, 'pro').args.includes('--model'), 'no slug configured → no flag');
  assert.deepStrictEqual(command('agy', 'x', 'work', { agyModels: { pro: 'g-pro' } }, 'pro').args.slice(0, 4), ['-p', 'x', '--model', 'g-pro']);
});

test('Run again on a task that is still running does nothing; a task without its folder fails clearly', async () => {
  const { c, calls } = company((worker, prompt, mode) => (mode === 'plan' ? 'hang' : { ok: true, text: 'ok' }), { installed: (id) => id === 'claude' });
  c.limitCache = { at: Date.now(), value: {} };
  const t = c.create({ title: 'Long job', project: path.basename(PROJECT) });
  c.tick();
  await until(() => c.store.get(t.id).status === 'planning');
  c.retry(t.id);
  assert.strictEqual(c.store.get(t.id).status, 'planning', 'not restarted');
  assert.strictEqual(calls.filter((x) => x.mode === 'plan').length, 1, 'no second plan');
  c.cancel(t.id);

  // A phone request for an unknown project becomes a failed task; Run again must not run it anywhere.
  c.handleInbox([{ id: 'r1', kind: 'create', title: 'Fix it', project: 'nope' }]);
  const bad = c.store.tasks.find((x) => x.title === 'Fix it');
  assert.strictEqual(bad.status, 'failed');
  c.retry(bad.id);
  c.tick();
  assert.strictEqual(c.store.get(bad.id).status, 'failed');
  assert.match(c.store.get(bad.id).error, /project folder/);
  assert.strictEqual(calls.filter((x) => x.mode === 'plan').length, 1, 'never planned');
});

test('Cancel stops the agent and the commands it started', { skip: process.platform === 'win32' }, async () => {
  const { run } = require('../src/company/workers');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-kill-'));
  fs.writeFileSync(path.join(dir, 'codex'), `#!/bin/sh\ncat >/dev/null\nsleep 300 &\necho $! > "${dir}/child.pid"\nwait\n`, { mode: 0o755 });
  const savedPath = process.env.PATH;
  process.env.PATH = `${dir}${path.delimiter}${savedPath}`;
  try {
    const job = run('codex', 'x', { cwd: dir });
    await until(() => fs.existsSync(path.join(dir, 'child.pid')) && fs.readFileSync(path.join(dir, 'child.pid'), 'utf8').trim());
    const pid = Number(fs.readFileSync(path.join(dir, 'child.pid'), 'utf8'));
    job.cancel();
    assert.strictEqual((await job.promise).text, 'Cancelled.');
    const running = () => { try { return !/\) Z /.test(fs.readFileSync(`/proc/${pid}/stat`, 'utf8')); } catch { return false; } };
    await until(() => !running(), 3000);
  } finally {
    process.env.PATH = savedPath;
  }
});
