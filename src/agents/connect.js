'use strict';

const fs = require('fs');

// One-step "connect this PC to your iPhone": sign in with GitHub, find or create
// the private status Gist, and install the agent hooks. Used by `npm run agent:setup`
// and by the desktop app's one-click setup and Settings → iPhone.

const config = require('./config');
const hooks = require('./hooks');
const github = require('./github');

/**
 * onCode({ userCode, verificationUri }) is called when you need to approve the
 * sign-in on github.com. Returns { login, results: [[name, ok, message]] }.
 */
async function connect({ onCode, fetchImpl = fetch, forceLogin = false } = {}) {
  const cfg = config.ensure();
  let gh = cfg.github || {};
  if (!gh.token || forceLogin) {
    gh = { token: await github.deviceLogin({ onCode, fetchImpl }) };
  }
  gh.login = await github.whoami(gh.token, fetchImpl);
  gh.gistId = await github.findOrCreateGist(gh.token, fetchImpl);
  cfg.github = gh;
  config.save(cfg);
  return { login: gh.login, results: installHooks() };
}

function installHooks() {
  const results = [];
  const step = (name, fn) => {
    try { results.push([name, true, fn()]); } catch (e) { results.push([name, false, e.message]); }
  };
  step('Claude Code hooks', () => hooks.installClaude());
  step('Antigravity (agy) hooks', () => hooks.installAgy());
  step('Codex', () => {
    const r = hooks.installCodex();
    if (r.status === 'conflict') {
      return `you already have a \`notify\` command in ${r.file}. Limitty still reads Codex's logs; `
        + `for instant "finished" alerts, replace it with:\n      ${r.line}`;
    }
    return `${r.file} (turn-complete notify)`;
  });
  return results;
}

/**
 * At app start: keep ~/.limitty/hook.js current, and rewrite our hooks if they were
 * installed by an older version or another copy of Limitty (e.g. moved AppImage).
 * Only touches agents that already have our hooks. Returns the names it fixed.
 */
function repairHooks() {
  const fixed = [];
  try { hooks.ensureHookScript(); } catch { return fixed; }
  const check = (name, file, current, install) => {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { return; }
    if (!text.includes(hooks.MARK) || text.includes(current)) return;
    try { install(); fixed.push(name); } catch { /* leave it */ }
  };
  check('Claude Code', hooks.claudeSettingsPath(), JSON.stringify(hooks.hookCommand('claude')).slice(1, -1), () => hooks.installClaude());
  check('Antigravity', hooks.agyHooksPath(), JSON.stringify(hooks.hookCommand('agy', 'Stop')).slice(1, -1), () => hooks.installAgy());
  check('Codex', hooks.codexConfigPath(), hooks.hookArgv('codex').map((a) => JSON.stringify(a)).join(', '), () => hooks.installCodex());
  return fixed;
}

function disconnect() {
  const cfg = config.load();
  if (cfg?.github) {
    delete cfg.github;
    config.save(cfg);
  }
}

module.exports = { repairHooks, connect, disconnect, installHooks };
