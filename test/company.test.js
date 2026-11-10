'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-co-'));
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');

const { Company } = require('../src/company/company');
const { TaskStore } = require('../src/company/store');
const { parsePlan, pickWorker } = require('../src/company/ceo');
const { command } = require('../src/company/workers');

const PROJECT = fs.mkdtempSync(path.join(HOME, 'site-'));

/** Fake workers: records prompts; answers come from `script(worker, prompt, mode)`. */
function fakeRun(script) {
  const calls = [];
  const runImpl = (worker, prompt, { mode, cwd }) => {
    calls.push({ worker, mode, prompt, cwd });
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
    { worker: 'codex', title: 'Add dark mode', instruction: 'Add a dark mode toggle' },
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

test('plan parsing and worker commands', () => {
  assert.strictEqual(parsePlan('no json', ['claude']), null);
  const p = parsePlan('```json\n{"summary":"s","steps":[{"worker":"gpt","instruction":"do it"}]}\n```', ['codex']);
  assert.strictEqual(p.steps[0].worker, 'codex'); // unknown worker → first available
  assert.strictEqual(pickWorker({ claude: { available: true, busy: true, remaining: 99 }, codex: { available: true, busy: false, remaining: 10 }, agy: { available: false } }), 'codex');

  const claude = command('claude', 'hi', 'work');
  assert.deepStrictEqual(claude.args.slice(0, 3), ['-p', '--output-format', 'json']);
  assert.ok(claude.args.includes('acceptEdits'));
  assert.strictEqual(claude.stdin, 'hi');
  assert.deepStrictEqual(claude.parse('{"type":"result","result":"Done!","is_error":false}'), { text: 'Done!', failed: false });
  assert.ok(command('claude', 'x', 'plan').args.includes('--disallowedTools'));
  assert.ok(command('codex', 'x', 'work').args.includes('--full-auto'));
  assert.ok(command('codex', 'x', 'plan').args.includes('read-only'));
});
