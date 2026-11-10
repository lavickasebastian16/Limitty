'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-gh-'));
process.env.HOME = HOME;
process.env.USERPROFILE = HOME;
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');
process.env.CLAUDE_CONFIG_DIR = path.join(HOME, '.claude');
process.env.CODEX_HOME = path.join(HOME, '.codex');

const github = require('../src/agents/github');
const { Daemon } = require('../src/agents/daemon');
const config = require('../src/agents/config');

/** A tiny fake of github.com + api.github.com. */
function fakeGitHub({ pendingPolls = 1, existingGist = null } = {}) {
  const calls = [];
  let polls = 0;
  const gists = existingGist ? [existingGist] : [];
  const json = (status, body) => ({ ok: status < 300, status, json: async () => body });
  const fetchImpl = async (url, init = {}) => {
    const body = init.body;
    calls.push({ url, method: init.method || 'GET', headers: init.headers || {}, body });
    if (url === 'https://github.com/login/device/code') {
      return json(200, { device_code: 'dev', user_code: 'ABCD-1234', verification_uri: 'https://github.com/login/device', interval: 5, expires_in: 900 });
    }
    if (url === 'https://github.com/login/oauth/access_token') {
      polls += 1;
      if (polls === 1) return json(200, { error: 'slow_down' });
      if (polls <= pendingPolls + 1) return json(200, { error: 'authorization_pending' });
      return json(200, { access_token: 'gho_token', token_type: 'bearer', scope: 'gist' });
    }
    if (url === 'https://api.github.com/user') return json(200, { login: 'octo' });
    if (url.startsWith('https://api.github.com/gists?')) return json(200, gists);
    if (url === 'https://api.github.com/gists' && init.method === 'POST') {
      const g = { id: 'new-gist', files: JSON.parse(body).files };
      gists.push(g);
      return json(201, g);
    }
    if (url.startsWith('https://api.github.com/gists/') && init.method === 'PATCH') return json(200, {});
    return json(404, {});
  };
  return { fetchImpl, calls };
}

test('device login: shows the code, handles slow_down/pending, returns the token', async () => {
  const gh = fakeGitHub({ pendingPolls: 2 });
  const waits = [];
  let shown;
  const token = await github.deviceLogin({
    clientId: 'Iv1.test', fetchImpl: gh.fetchImpl, wait: async (ms) => { waits.push(ms); },
    onCode: (c) => { shown = c; },
  });
  assert.strictEqual(token, 'gho_token');
  assert.deepStrictEqual(shown, { userCode: 'ABCD-1234', verificationUri: 'https://github.com/login/device' });
  assert.deepStrictEqual(waits, [5000, 10000, 10000, 10000]); // slow_down adds 5 s
  assert.match(gh.calls[0].body, /client_id=Iv1\.test&scope=gist/);
});

test('device login without a client ID explains what to do', async () => {
  await assert.rejects(github.deviceLogin({ clientId: '', onCode: () => {} }), /isn't configured yet/);
});

test('finds an existing status gist, or creates a private one', async () => {
  const existing = fakeGitHub({ existingGist: { id: 'g1', files: { 'limitty-status.json': {} } } });
  assert.strictEqual(await github.findOrCreateGist('t', existing.fetchImpl), 'g1');
  assert.ok(!existing.calls.some((c) => c.method === 'POST'));

  const fresh = fakeGitHub();
  assert.strictEqual(await github.findOrCreateGist('t', fresh.fetchImpl), 'new-gist');
  const post = fresh.calls.find((c) => c.method === 'POST');
  assert.strictEqual(JSON.parse(post.body).public, false);
  assert.strictEqual(post.headers.Authorization, 'Bearer t');
});

test('connect: signs in, saves the account, installs hooks', async () => {
  process.env.LIMITTY_GITHUB_CLIENT_ID = 'Iv1.test';
  delete require.cache[require.resolve('../src/agents/github')];
  delete require.cache[require.resolve('../src/agents/connect')];
  const { connect } = require('../src/agents/connect');
  const gh = fakeGitHub({ pendingPolls: 0 });
  // Skip real waiting by making the poll interval tiny.
  const realSetTimeout = global.setTimeout;
  global.setTimeout = (fn) => realSetTimeout(fn, 0);
  try {
    const r = await connect({ fetchImpl: gh.fetchImpl, onCode: () => {} });
    assert.strictEqual(r.login, 'octo');
    assert.ok(r.results.every(([, ok]) => ok), JSON.stringify(r.results));
  } finally {
    global.setTimeout = realSetTimeout;
  }
  const saved = config.load();
  assert.deepStrictEqual(saved.github, { token: 'gho_token', login: 'octo', gistId: 'new-gist' });
  assert.ok(fs.existsSync(path.join(HOME, '.claude', 'settings.json')));
  assert.ok(fs.existsSync(path.join(HOME, '.gemini', 'config', 'hooks.json')));
});
