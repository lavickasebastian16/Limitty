'use strict';

// Your coding agents: which ones you chose, whether they're installed and signed
// in, and installing them with each vendor's official installer.
//
//   Claude Code   curl -fsSL https://claude.ai/install.sh | bash          → ~/.local/bin/claude
//   Codex         the official release binary from github.com/openai/codex → ~/.local/bin/codex
//   Antigravity   curl -fsSL https://antigravity.google/cli/install.sh | bash → ~/.local/bin/agy
//
// Nothing needs sudo. Signing in opens the agent's own sign-in page in your browser.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const HOME = os.homedir();
const LOCAL_BIN = path.join(HOME, '.local', 'bin');
const DIR = process.env.LIMITTY_HOME || path.join(HOME, '.limitty');
const CHOICE_FILE = path.join(DIR, 'tools.json');

const CODEX_SCRIPT = `set -e
case "$(uname -s)" in Linux) os=unknown-linux-musl ;; Darwin) os=apple-darwin ;; *) echo "Unsupported system: $(uname -s)"; exit 1 ;; esac
case "$(uname -m)" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; *) echo "Unsupported CPU: $(uname -m)"; exit 1 ;; esac
url="https://github.com/openai/codex/releases/latest/download/codex-$arch-$os.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "Downloading $url"
curl -fsSL "$url" | tar -xz -C "$tmp"
bin="$(find "$tmp" -type f -name 'codex*' | head -n 1)"
[ -n "$bin" ] || { echo "No codex binary in the download"; exit 1; }
mkdir -p "$HOME/.local/bin"
install -m 0755 "$bin" "$HOME/.local/bin/codex"
echo "Installed $HOME/.local/bin/codex"`;

const TOOLS = {
  claude: {
    name: 'Claude Code',
    bin: 'claude',
    provider: 'claude',
    about: 'Anthropic’s coding agent. Uses your Claude Pro or Max plan.',
    script: 'curl -fsSL https://claude.ai/install.sh | bash',
    login: ['auth', 'login'],
    loginHint: 'Sign in with your Claude account. If the page then shows a code, paste it below.',
    signedIn: () => {
      const dir = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
      if (fs.existsSync(path.join(dir, '.credentials.json'))) return true;
      // On Linux and Windows that file is the login; on macOS it may be in the Keychain instead.
      return process.platform === 'darwin' ? null : false;
    },
  },
  codex: {
    name: 'Codex',
    bin: 'codex',
    provider: 'codex',
    about: 'OpenAI’s coding agent. Uses your ChatGPT plan.',
    script: CODEX_SCRIPT,
    login: ['login'],
    loginHint: 'Sign in with your ChatGPT account. The page tells you when you can close it.',
    signedIn: () => fs.existsSync(path.join(process.env.CODEX_HOME || path.join(HOME, '.codex'), 'auth.json')),
  },
  agy: {
    name: 'Antigravity',
    bin: 'agy',
    provider: 'antigravity',
    about: 'Google’s coding agent (agy CLI). Uses your Google account’s Gemini quota.',
    script: 'curl -fsSL https://antigravity.google/cli/install.sh | bash',
    // agy has no login command: it asks you to sign in the first time it's used.
    login: ['-p', 'Reply with just: OK'],
    loginHint: 'Sign in with your Google account.',
    signedIn: () => null, // agy keeps its login where Limitty can't check it
  },
};

const IDS = Object.keys(TOOLS);

/** Puts ~/.local/bin on PATH: the installers put the agents there, and apps started from a launcher often don't have it. */
function ensurePath(env = process.env) {
  const parts = (env.PATH || '').split(path.delimiter).filter(Boolean);
  if (!parts.includes(LOCAL_BIN)) env.PATH = [LOCAL_BIN, ...parts].join(path.delimiter);
  return env;
}

/** Full path of an agent's command, or null. */
function find(id) {
  const t = TOOLS[id];
  if (!t) return null;
  if (id === 'agy' && process.env.ANTIGRAVITY_CLI_PATH) {
    return fs.existsSync(process.env.ANTIGRAVITY_CLI_PATH) ? process.env.ANTIGRAVITY_CLI_PATH : null;
  }
  const exts = process.platform === 'win32' ? ['.exe', '.cmd', '.bat', ''] : [''];
  const dirs = [...(process.env.PATH || '').split(path.delimiter), LOCAL_BIN];
  for (const dir of dirs) {
    for (const ext of exts) {
      const p = dir && path.join(dir, t.bin + ext);
      if (p && isFile(p)) return p;
    }
  }
  return null;
}

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

const versionCache = new Map(); // path → { mtime, version }
function version(bin) {
  let mtime = 0;
  try { mtime = fs.statSync(bin).mtimeMs; } catch { /* gone */ }
  const hit = versionCache.get(bin);
  if (hit && hit.mtime === mtime) return hit.version;
  let v = null;
  try {
    const r = spawnSync(bin, ['--version'], { encoding: 'utf8', timeout: 5000, env: ensurePath({ ...process.env }) });
    const m = `${r.stdout || ''} ${r.stderr || ''}`.match(/\d+\.\d+(\.\d+)?/);
    v = m ? m[0] : null;
  } catch { /* unknown */ }
  versionCache.set(bin, { mtime, version: v });
  return v;
}

// ───── which agents you chose ─────

function readChoice() {
  try {
    const j = JSON.parse(fs.readFileSync(CHOICE_FILE, 'utf8'));
    return Array.isArray(j.chosen) ? j.chosen.filter((id) => TOOLS[id]) : null;
  } catch {
    return null;
  }
}

/** The agents you chose; before you choose, all of them (setup installs what's missing). */
function chosen() {
  return readChoice() ?? [...IDS];
}

function hasChosen() {
  return readChoice() !== null;
}

function isChosen(id) {
  return chosen().includes(id);
}

function choose(ids) {
  const list = IDS.filter((id) => ids.includes(id));
  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(CHOICE_FILE, JSON.stringify({ chosen: list }, null, 2));
  return list;
}

/** Everything the Agents screen shows. */
function status() {
  const picked = chosen();
  return IDS.map((id) => {
    const t = TOOLS[id];
    const bin = find(id);
    return {
      id,
      name: t.name,
      about: t.about,
      chosen: picked.includes(id),
      installed: !!bin,
      path: bin,
      version: bin ? version(bin) : null,
      signedIn: bin ? t.signedIn() : false,
      loginHint: t.loginHint,
      canInstall: process.platform !== 'win32',
    };
  });
}

// ───── installing ─────

/**
 * Runs the agent's official installer. `onLine` gets each line of output.
 * Returns { promise: Promise<{ ok, path, error }>, cancel }.
 */
function install(id, { onLine = () => {}, script } = {}) {
  const t = TOOLS[id];
  if (!t) throw new Error(`Unknown agent ${id}`);
  if (process.platform === 'win32') {
    return { promise: Promise.resolve({ ok: false, error: 'Automatic install works on Linux and macOS. On Windows, install it from its website.' }), cancel: () => {} };
  }
  const child = spawn('bash', ['-c', script || t.script], {
    env: ensurePath({ ...process.env, CI: '1' }),
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  const tail = [];
  const feed = (buf) => {
    for (const raw of buf.toString().split(/\r?\n|\r/)) {
      // eslint-disable-next-line no-control-regex
      const line = raw.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').trimEnd();
      if (!line) continue;
      tail.push(line);
      if (tail.length > 20) tail.shift();
      onLine(line);
    }
  };
  child.stdout.on('data', feed);
  child.stderr.on('data', feed);
  const promise = new Promise((resolve) => {
    child.on('error', (e) => resolve({ ok: false, error: e.message }));
    child.on('close', (code) => {
      const bin = find(id);
      if (code === 0 && bin) resolve({ ok: true, path: bin });
      else resolve({ ok: false, error: code === 0 ? `The installer finished but no \`${t.bin}\` command was found.` : (tail.slice(-3).join(' ') || `Installer exited with code ${code}`) });
    });
  });
  return { promise, cancel: () => child.kill() };
}

// ───── signing in (in your browser) ─────

const URL_RE = /https:\/\/[^\s"'<>]+/g;

/**
 * Signs in to an agent: runs its login in the background, hands each sign-in link to
 * `onUrl` (Limitty opens it in a new browser tab), and passes a code you paste (Claude
 * shows one on the page) back to it. Resolves to 'signed-in' | 'failed' | 'cancelled'.
 * Returns { promise, sendCode, cancel, output() }.
 */
function browserLogin(id, { onUrl = () => {}, onLine = () => {}, timeoutMs = 10 * 60_000, spawnImpl = spawn } = {}) {
  const t = TOOLS[id];
  const bin = find(id) || t.bin;
  const lines = [];
  const seen = new Set();
  let child;
  let cancelled = false;
  let finish;
  const promise = new Promise((resolve) => { finish = resolve; });
  const env = ensurePath({ ...process.env, AGY_CLI_DISABLE_AUTO_UPDATE: 'true' });
  // Limitty opens the page itself, so stop the agents opening a second tab.
  if (id !== 'agy') env.BROWSER = process.platform === 'win32' ? 'cmd /c rem' : 'true';
  try {
    child = spawnImpl(bin, t.login, { cwd: HOME, env, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
  } catch (e) {
    finish('failed');
    return { promise, sendCode: () => {}, cancel: () => {}, output: () => e.message };
  }
  const feed = (buf) => {
    for (const raw of String(buf).split(/\r?\n|\r/)) {
      // eslint-disable-next-line no-control-regex
      const line = raw.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').trim();
      if (!line) continue;
      lines.push(line);
      if (lines.length > 40) lines.shift();
      onLine(line);
      for (const url of line.match(URL_RE) || []) {
        // Only sign-in pages, not e.g. a docs link; and each one once.
        if (seen.has(url) || !/oauth|auth|login|accounts\.google|signin/i.test(url)) continue;
        seen.add(url);
        onUrl(url);
      }
    }
  };
  child.stdout?.on('data', feed);
  child.stderr?.on('data', feed);
  child.stdin?.on('error', () => {});
  const timer = setTimeout(() => { cancelled = true; child.kill(); }, timeoutMs);
  child.on('error', (e) => { clearTimeout(timer); lines.push(e.message); finish('failed'); });
  child.on('close', (code) => {
    clearTimeout(timer);
    if (cancelled) return finish('cancelled');
    const signed = t.signedIn();
    finish(signed === true || (code === 0 && signed !== false) ? 'signed-in' : 'failed');
  });
  return {
    promise,
    sendCode: (code) => { try { child.stdin.write(`${String(code).trim()}\n`); } catch { /* gone */ } },
    cancel: () => { cancelled = true; try { child.kill(); } catch { /* gone */ } },
    output: () => lines.slice(-6).join('\n'),
  };
}

module.exports = {
  TOOLS, IDS, LOCAL_BIN, CHOICE_FILE,
  ensurePath, find, status, chosen, hasChosen, isChosen, choose,
  install, browserLogin,
};
