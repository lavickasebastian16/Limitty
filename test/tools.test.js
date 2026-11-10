'use strict';

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

// Each test file runs in its own process, so pointing HOME and LIMITTY_HOME at a
// temp folder before loading the module keeps the real ones untouched.
const HOME = fs.mkdtempSync(path.join(os.tmpdir(), 'limitty-tools-'));
process.env.HOME = HOME;
process.env.LIMITTY_HOME = path.join(HOME, '.limitty');
process.env.PATH = '/usr/bin:/bin';
delete process.env.CODEX_HOME;
delete process.env.CLAUDE_CONFIG_DIR;
delete process.env.ANTIGRAVITY_CLI_PATH;
const tools = require('../src/tools');

const BIN = path.join(HOME, '.local', 'bin');
function fakeAgent(name, ver = '1.2.3') {
  fs.mkdirSync(BIN, { recursive: true });
  const p = path.join(BIN, name);
  fs.writeFileSync(p, `#!/bin/sh\necho "${name} ${ver}"\n`, { mode: 0o755 });
  return p;
}

test('ensurePath adds ~/.local/bin once', () => {
  const env = { PATH: '/usr/bin' };
  tools.ensurePath(env);
  tools.ensurePath(env);
  assert.strictEqual(env.PATH, `${BIN}${path.delimiter}/usr/bin`);
});

test('finds agents in ~/.local/bin even when it is not on PATH', () => {
  assert.strictEqual(tools.find('codex'), null);
  const p = fakeAgent('codex', '0.167.0');
  assert.strictEqual(tools.find('codex'), p);
  const codex = tools.status().find((a) => a.id === 'codex');
  assert.strictEqual(codex.installed, true);
  assert.strictEqual(codex.version, '0.167.0');
  assert.strictEqual(codex.signedIn, false);
  fs.mkdirSync(path.join(HOME, '.codex'), { recursive: true });
  fs.writeFileSync(path.join(HOME, '.codex', 'auth.json'), '{}');
  assert.strictEqual(tools.status().find((a) => a.id === 'codex').signedIn, true);
});

test('before you choose, all agents are ticked; then your choice wins', () => {
  assert.strictEqual(tools.hasChosen(), false);
  assert.deepStrictEqual(tools.chosen(), ['claude', 'codex', 'agy']);
  tools.choose(['agy', 'claude', 'nonsense']);
  assert.strictEqual(tools.hasChosen(), true);
  assert.deepStrictEqual(tools.chosen(), ['claude', 'agy']); // fixed order, unknown ids dropped
  assert.strictEqual(tools.isChosen('codex'), false);
  tools.choose(['claude', 'codex']);
});

test('install runs the installer, streams output and finds the new command', async () => {
  const lines = [];
  const script = `echo "\x1b[32mDownloading\x1b[0m"; mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\\necho 2.0.1\\n' > "$HOME/.local/bin/claude"; chmod +x "$HOME/.local/bin/claude"; echo done`;
  const r = await tools.install('claude', { script, onLine: (l) => lines.push(l) }).promise;
  assert.strictEqual(r.ok, true, r.error);
  assert.strictEqual(r.path, path.join(BIN, 'claude'));
  assert.deepStrictEqual(lines, ['Downloading', 'done']); // colours stripped
});

test('a failed install reports the last lines of output', async () => {
  const r = await tools.install('agy', { script: 'echo "curl: (6) Could not resolve host"; exit 6' }).promise;
  assert.strictEqual(r.ok, false);
  assert.match(r.error, /Could not resolve host/);
});

test('an installer that succeeds without leaving the command is a failure', async () => {
  const r = await tools.install('agy', { script: 'echo ok' }).promise;
  assert.strictEqual(r.ok, false);
  assert.match(r.error, /no `agy` command/);
});

test('browser sign-in: opens the sign-in link once, passes a pasted code back, and checks the result', async () => {
  // A pretend `claude auth login`: prints a link, waits for a code, then saves the login.
  const creds = path.join(HOME, '.claude', '.credentials.json');
  fs.rmSync(creds, { force: true });
  fakeAgent('claude');
  fs.writeFileSync(path.join(BIN, 'claude'), `#!/bin/sh
echo "Opening browser to sign in…"
echo "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=abc"
echo "See https://docs.example.com/help for help"
printf "Paste code here if prompted > "
read code
[ "$code" = "good-code" ] || { echo "Invalid code."; exit 1; }
mkdir -p "$HOME/.claude" && echo '{}' > "$HOME/.claude/.credentials.json"
echo "Login successful."
`, { mode: 0o755 });
  const urls = [];
  const s = tools.browserLogin('claude', { onUrl: (u) => urls.push(u) });
  await new Promise((r) => setTimeout(r, 300));
  assert.deepStrictEqual(urls, ['https://claude.com/cai/oauth/authorize?code=true&state=abc'], 'only the sign-in link');
  assert.strictEqual(tools.TOOLS.claude.signedIn(), false, 'no login file yet means signed out (Linux)');
  s.sendCode('  good-code \n');
  assert.strictEqual(await s.promise, 'signed-in');
  assert.strictEqual(tools.TOOLS.claude.signedIn(), true);

  // A wrong code: fails, with the agent's message.
  fs.rmSync(creds);
  const bad = tools.browserLogin('claude');
  await new Promise((r) => setTimeout(r, 200));
  bad.sendCode('nope');
  assert.strictEqual(await bad.promise, 'failed');
  assert.match(bad.output(), /Invalid code/);

  // Skip.
  const skipped = tools.browserLogin('claude');
  skipped.cancel();
  assert.strictEqual(await skipped.promise, 'cancelled');
});
