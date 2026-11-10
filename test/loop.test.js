'use strict';

// The whole phone → PC → phone loop, with a pretend GitHub Gist and pretend agents:
// the phone adds a task to limitty-inbox.json (exactly as the iPhone app writes it),
// the PC picks it up, the CEO splits it by strengths, the workers run, and the
// result lands in limitty-tasks.json with a "done" alert.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-loop-'));
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');

const config = require('../src/agents/config');
const { Daemon } = require('../src/agents/daemon');
const { Company } = require('../src/company/company');
const { TaskStore } = require('../src/company/store');

const until = async (fn, ms = 5000) => {
  const end = Date.now() + ms;
  while (!fn()) {
    if (Date.now() > end) throw new Error('timed out');
    await new Promise((r) => setTimeout(r, 20));
  }
};

/** A pretend api.github.com Gist + ntfy. */
function fakeCloud() {
  const files = {};
  const ntfy = [];
  const fetchImpl = async (url, init = {}) => {
    const method = init.method || 'GET';
    if (url === 'https://api.github.com/gists/g1') {
      if (method === 'PATCH') {
        for (const [name, f] of Object.entries(JSON.parse(init.body).files)) files[name] = f.content;
        return { ok: true, status: 200, json: async () => ({}) };
      }
      return { ok: true, status: 200, json: async () => ({ files: Object.fromEntries(Object.entries(files).map(([n, c]) => [n, { content: c }])) }) };
    }
    if (url.startsWith('https://ntfy.sh/')) { ntfy.push({ url, body: init.body }); return { ok: true, status: 200 }; }
    throw new Error(`unexpected ${method} ${url}`);
  };
  return { files, ntfy, fetchImpl };
}

test('phone → PC → phone: a task from the iPhone is split by strengths, done, and reported back', async () => {
  const project = fs.mkdtempSync(path.join(HOME, 'shop-'));
  const cloud = fakeCloud();
  const prompts = [];
  const runImpl = (worker, prompt, { mode }) => {
    prompts.push({ worker, mode, prompt });
    const text = mode === 'plan'
      ? JSON.stringify({ summary: 'UI to Antigravity, API to Codex, review by Claude', steps: [
        { worker: 'agy', title: 'Checkout page', why: 'frontend/UI work', instruction: 'Build the checkout page UI' },
        { worker: 'codex', model: 'medium', title: 'Payment API', why: 'well-scoped implementation', instruction: 'Add the /pay endpoint' },
        { worker: 'claude', model: 'sonnet', title: 'Review', why: 'reviewing changes across files', instruction: 'Review and fix both parts' },
      ] })
      : `${worker} did it`;
    return { promise: new Promise((r) => setTimeout(() => r({ ok: true, text }), 10)), cancel: () => {} };
  };
  const company = new Company({
    store: new TaskStore(path.join(HOME, 'company.json')),
    runImpl,
    installed: () => true,
    limits: async () => ({ claude: 60, codex: 80, agy: 70 }),
    workerOptions: { strengths: { agy: 'frontend/UI work, CSS, quick edits' } },
  });
  company.addProject(project);
  const cfg = { ...config.DEFAULTS, topic: 'limitty-loop', key: config.base64url(Buffer.alloc(32, 2)), github: { token: 't', gistId: 'g1', login: 'me' } };
  const daemon = new Daemon(cfg, { fetchImpl: cloud.fetchImpl, company, skipLock: true });

  // The phone writes its inbox like GitHubStatusFeed.send (CompanyRequest, JSONEncoder).
  cloud.files['limitty-inbox.json'] = JSON.stringify({ requests: [
    { id: 'A1B2', kind: 'create', title: 'Add a checkout page with payments', project: path.basename(project), worker: 'auto', at: Date.now() / 1000 },
  ] });

  company.start();
  await daemon.pollInbox();
  await until(() => company.store.tasks[0]?.status === 'done');

  const task = company.store.tasks[0];
  assert.strictEqual(task.source, 'phone');
  assert.deepStrictEqual(task.plan.steps.map((s) => [s.worker, s.status]), [['agy', 'done'], ['codex', 'done'], ['claude', 'done']]);
  // The CEO saw the strengths you set.
  assert.match(prompts.find((p) => p.mode === 'plan').prompt, /antigravity.*Good at: frontend\/UI work, CSS, quick edits/i);

  // The phone's view: the tasks file in the Gist shows it done, with the CEO's reasons.
  daemon.requestStatus(true);
  await until(() => JSON.parse(cloud.files['limitty-tasks.json'] || '{"tasks":[]}').tasks[0]?.status === 'done');
  const phoneView = JSON.parse(cloud.files['limitty-tasks.json']).tasks[0];
  assert.strictEqual(phoneView.title, 'Add a checkout page with payments');
  assert.deepStrictEqual(phoneView.plan.steps.map((s) => s.why), ['frontend/UI work', 'well-scoped implementation', 'reviewing changes across files']);

  // "Done" push alert.
  await until(() => cloud.ntfy.some((n) => n.url.includes('-alerts?')));
  const alert = new URL(cloud.ntfy.find((n) => n.url.includes('-alerts?')).url);
  assert.match(alert.searchParams.get('title'), /^Task done/);
  assert.strictEqual(alert.searchParams.get('click'), 'limitty://tasks');

  // The same inbox read again doesn't create the task twice.
  await daemon.pollInbox();
  assert.strictEqual(company.store.tasks.length, 1);

  // Cancel from the phone works too.
  cloud.files['limitty-inbox.json'] = JSON.stringify({ requests: [
    ...JSON.parse(cloud.files['limitty-inbox.json']).requests,
    { id: 'C3', kind: 'remove', task: task.id, at: Date.now() / 1000 },
  ] });
  await daemon.pollInbox();
  assert.strictEqual(company.store.tasks.length, 0);
  company.stop();
  daemon.stop();
});
