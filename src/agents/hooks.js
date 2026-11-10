'use strict';

// Installs (and removes) the small hooks that tell Limitty what your agents are doing.
// Every entry we add carries the `--limitty-hook` marker so we only ever touch our own.

const fs = require('fs');
const os = require('os');
const path = require('path');

const MARK = '--limitty-hook';
const HOOK_SOURCE = path.join(__dirname, 'hook.js');

/** Forward slashes work everywhere (Node accepts them on Windows) and survive any shell. */
const slash = (p) => p.split(path.sep).join('/');

/** Where the agents run the hook from: a copy outside the app, so the path never changes. */
function hookScriptPath() {
  return path.join(require('./config').FILES.dir, 'hook.js');
}

/** Copies the hook script into ~/.limitty (on every install and app start, so updates reach it). */
function ensureHookScript() {
  const dest = hookScriptPath();
  const code = fs.readFileSync(HOOK_SOURCE, 'utf8'); // also works from inside the app's .asar archive
  let current = null;
  try { current = fs.readFileSync(dest, 'utf8'); } catch { /* not there yet */ }
  if (current !== code) {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.writeFileSync(dest, code);
  }
  return dest;
}

/**
 * The program that runs the hook script. Plain Node when Limitty runs from source.
 * The desktop app is Electron: it runs scripts as Node when ELECTRON_RUN_AS_NODE=1
 * is set. For an AppImage, use the AppImage file itself, since its inside path moves
 * on every start.
 */
function runtime() {
  if (process.versions.electron && process.platform !== 'win32') {
    return ['/usr/bin/env', 'ELECTRON_RUN_AS_NODE=1', slash(process.env.APPIMAGE || process.execPath)];
  }
  return [slash(process.execPath)];
}

function hookArgv(agent, event) {
  return [...runtime(), slash(hookScriptPath()), agent, ...(event ? [event] : []), MARK];
}

function hookCommand(agent, event) {
  return hookArgv(agent, event).map((a) => `"${a}"`).join(' ');
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) {
    if (e.code === 'ENOENT') return {};
    throw new Error(`Can't read ${file}: ${e.message}. Fix or remove it, then run setup again.`);
  }
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (fs.existsSync(file)) fs.copyFileSync(file, `${file}.limitty-backup`);
  fs.writeFileSync(file, `${JSON.stringify(obj, null, 2)}\n`);
}

const isOurs = (h) => typeof h?.command === 'string' && h.command.includes(MARK);

// ───────────── Claude Code: ~/.claude/settings.json ─────────────

const CLAUDE_EVENTS = ['SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Notification', 'Stop', 'SessionEnd'];

function claudeSettingsPath() {
  return path.join(process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude'), 'settings.json');
}

function stripClaude(settings) {
  const hooks = settings.hooks || {};
  for (const ev of Object.keys(hooks)) {
    hooks[ev] = (hooks[ev] || [])
      .map((m) => ({ ...m, hooks: (m.hooks || []).filter((h) => !isOurs(h)) }))
      .filter((m) => m.hooks.length);
    if (!hooks[ev].length) delete hooks[ev];
  }
  if (Object.keys(hooks).length) settings.hooks = hooks;
  else delete settings.hooks;
  return settings;
}

function installClaude(file = claudeSettingsPath()) {
  ensureHookScript();
  const settings = stripClaude(readJson(file));
  settings.hooks = settings.hooks || {};
  for (const ev of CLAUDE_EVENTS) {
    const entry = { hooks: [{ type: 'command', command: hookCommand('claude'), timeout: 10 }] };
    if (ev === 'PreToolUse' || ev === 'PostToolUse') entry.matcher = '*';
    settings.hooks[ev] = [...(settings.hooks[ev] || []), entry];
  }
  writeJson(file, settings);
  return file;
}

function uninstallClaude(file = claudeSettingsPath()) {
  if (!fs.existsSync(file)) return null;
  writeJson(file, stripClaude(readJson(file)));
  return file;
}

// ───────────── Antigravity (agy): ~/.gemini/config/hooks.json ─────────────

const AGY_EVENTS = ['SessionStart', 'PreInvocation', 'PreToolUse', 'PostToolUse', 'Stop'];

function agyHooksPath() {
  return path.join(os.homedir(), '.gemini', 'config', 'hooks.json');
}

function installAgy(file = agyHooksPath()) {
  ensureHookScript();
  const cfg = readJson(file);
  const group = { enabled: true };
  for (const ev of AGY_EVENTS) {
    const handler = { type: 'command', command: hookCommand('agy', ev), timeout: 10 };
    group[ev] = ev === 'PreToolUse' || ev === 'PostToolUse' ? [{ matcher: '*', hooks: [handler] }] : [handler];
  }
  cfg.limitty = group;
  writeJson(file, cfg);
  return file;
}

function uninstallAgy(file = agyHooksPath()) {
  if (!fs.existsSync(file)) return null;
  const cfg = readJson(file);
  delete cfg.limitty;
  writeJson(file, cfg);
  return file;
}

// ───────────── Codex: `notify` in ~/.codex/config.toml ─────────────

function codexConfigPath() {
  return path.join(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'), 'config.toml');
}

function codexNotifyLine() {
  return `notify = [${hookArgv('codex').map((a) => JSON.stringify(a)).join(', ')}]`;
}

/** Returns { file, status: 'installed' | 'already' | 'conflict', line }. */
function installCodex(file = codexConfigPath()) {
  ensureHookScript();
  const line = codexNotifyLine();
  let text = '';
  try { text = fs.readFileSync(file, 'utf8'); } catch { /* new file */ }
  const lines = text.split(/\r?\n/);
  // `notify` must be a top-level key, i.e. before the first [table].
  const firstTable = lines.findIndex((l) => /^\s*\[/.test(l));
  const topLevel = firstTable === -1 ? lines : lines.slice(0, firstTable);
  const existing = topLevel.findIndex((l) => /^\s*notify\s*=/.test(l));
  if (existing !== -1) {
    if (lines[existing].includes(MARK)) {
      lines[existing] = line;
      fs.writeFileSync(file, lines.join('\n'));
      return { file, status: 'already', line };
    }
    return { file, status: 'conflict', line };
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  if (text) fs.copyFileSync(file, `${file}.limitty-backup`);
  fs.writeFileSync(file, `# Tells Limitty when a Codex turn finishes.\n${line}\n${text ? `\n${text}` : ''}`);
  return { file, status: 'installed', line };
}

function uninstallCodex(file = codexConfigPath()) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  const out = text.split(/\r?\n/).filter((l) => !(l.includes(MARK) && /^\s*notify\s*=/.test(l)) && l !== '# Tells Limitty when a Codex turn finishes.');
  fs.writeFileSync(file, out.join('\n').replace(/^\n+/, ''));
  return file;
}

module.exports = {
  MARK, hookCommand, hookArgv, ensureHookScript, hookScriptPath, installClaude, uninstallClaude, installAgy, uninstallAgy, installCodex, uninstallCodex,
  claudeSettingsPath, agyHooksPath, codexConfigPath, CLAUDE_EVENTS, AGY_EVENTS,
};
