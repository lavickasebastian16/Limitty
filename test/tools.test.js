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

test('picks a terminal for signing in: Omarchy first, then common ones', () => {
  const only = (...names) => (b) => names.includes(b);
  const [bin, args] = tools.terminalCommand('codex login', { platform: 'linux', has: only('xdg-terminal-exec', 'alacritty'), env: {} });
  assert.strictEqual(bin, 'xdg-terminal-exec');
  assert.deepStrictEqual(args, ['bash', '-lc', 'codex login']);
  assert.deepStrictEqual(tools.terminalCommand('x', { platform: 'linux', has: only('kitty'), env: { TERMINAL: 'foot' } }), ['kitty', ['bash', '-lc', 'x']]);
  assert.strictEqual(tools.terminalCommand('x', { platform: 'linux', has: only('foot'), env: { TERMINAL: 'foot' } })[1][0], '-e');
  assert.strictEqual(tools.terminalCommand('x', { platform: 'linux', has: () => false, env: {} }), null);
  assert.strictEqual(tools.terminalCommand('x', { platform: 'darwin' })[0], 'osascript');
});

test('the sign-in line runs the installed command and waits before closing', () => {
  const line = tools.loginShellLine('codex');
  assert.match(line, /\.local\/bin\/codex login;/);
  assert.match(line, /touch .*signin-codex\.done/);
  assert.match(line, /read -r -t 15/);
});

test('openLogin hands back the command when no terminal can be opened', () => {
  const r = tools.openLogin('codex', { spawnImpl: () => { throw new Error('nope'); } });
  assert.strictEqual(r.ok, false);
  assert.match(r.command, /codex login$/);
});

test('signIn waits for the sign-in to finish, or Skip', async () => {
  // Codex: signed in once auth.json appears.
  fs.rmSync(path.join(HOME, '.codex', 'auth.json'), { force: true });
  const a = tools.signIn('codex', { openImpl: () => ({ ok: true, command: 'codex login' }), pollMs: 20 });
  setTimeout(() => fs.writeFileSync(path.join(HOME, '.codex', 'auth.json'), '{}'), 60);
  assert.strictEqual(await a.promise, 'signed-in');
  // agy can't be checked: done when its terminal command finishes.
  const b = tools.signIn('agy', { openImpl: () => ({ ok: true, command: 'agy' }), pollMs: 20 });
  setTimeout(() => fs.writeFileSync(tools.loginDoneFile('agy'), ''), 60);
  assert.strictEqual(await b.promise, 'signed-in');
  assert.strictEqual(fs.existsSync(tools.loginDoneFile('agy')), false);
  // Closed without signing in.
  fs.rmSync(path.join(HOME, '.codex', 'auth.json'));
  const c = tools.signIn('codex', { openImpl: () => ({ ok: true, command: 'codex login' }), pollMs: 20 });
  setTimeout(() => fs.writeFileSync(tools.loginDoneFile('codex'), ''), 60);
  assert.strictEqual(await c.promise, 'closed');
  const d = tools.signIn('codex', { openImpl: () => ({ ok: true, command: 'codex login' }), pollMs: 20 });
  d.skip();
  assert.strictEqual(await d.promise, 'skipped');
  const e = tools.signIn('codex', { openImpl: () => ({ ok: false, command: 'codex login' }) });
  assert.strictEqual(await e.promise, 'no-terminal');
});
