'use strict';

// Everything you can change in the Settings window, kept in ~/.limitty/agent.json
// (shared with the background agent and the CLI) so one file holds it all.

const { spawnSync } = require('child_process');
const config = require('./agents/config');
const { WORKERS } = require('./company/workers');
const tools = require('./tools');

const CEOS = ['claude', 'codex', 'agy', 'rules'];

function read() {
  const c = config.load() || { ...config.DEFAULTS };
  const w = c.workers || {};
  return {
    ceo: CEOS.includes(c.ceo) ? c.ceo : 'claude',
    strengths: Object.fromEntries(Object.keys(WORKERS).map((id) => [id, w.strengths?.[id] || ''])),
    defaultStrengths: Object.fromEntries(Object.entries(WORKERS).map(([id, x]) => [id, x.strengths])),
    allowCommands: w.allowCommands !== false,
    agyModels: { pro: w.agyModels?.pro || '', flash: w.agyModels?.flash || '' },
    alertOnFinish: c.alertOnFinish !== false,
    showProjectNames: c.showProjectNames !== false,
    github: c.github?.token ? { login: c.github.login || null } : null,
  };
}

/** Saves the changed fields. Unknown or invalid values are ignored. */
function write(patch = {}) {
  const c = config.ensure();
  c.workers = c.workers || {};
  if (CEOS.includes(patch.ceo)) c.ceo = patch.ceo;
  if (patch.strengths && typeof patch.strengths === 'object') {
    c.workers.strengths = { ...(c.workers.strengths || {}) };
    for (const id of Object.keys(WORKERS)) {
      if (!(id in patch.strengths)) continue;
      const v = String(patch.strengths[id] || '').trim().slice(0, 300);
      if (v && v !== WORKERS[id].strengths) c.workers.strengths[id] = v;
      else delete c.workers.strengths[id];
    }
  }
  if (typeof patch.allowCommands === 'boolean') c.workers.allowCommands = patch.allowCommands;
  if (patch.agyModels && typeof patch.agyModels === 'object') {
    const clean = (v) => String(v || '').trim().replace(/[^\w.:/@-]/g, '').slice(0, 80);
    const m = { pro: clean(patch.agyModels.pro), flash: clean(patch.agyModels.flash) };
    if (m.pro || m.flash) c.workers.agyModels = Object.fromEntries(Object.entries(m).filter(([, v]) => v));
    else delete c.workers.agyModels;
  }
  if (typeof patch.alertOnFinish === 'boolean') c.alertOnFinish = patch.alertOnFinish;
  if (typeof patch.showProjectNames === 'boolean') c.showProjectNames = patch.showProjectNames;
  config.save(c);
  return read();
}

/** Guesses Antigravity's Pro and Flash model names from `agy models`. */
function detectAgyModels(run = spawnSync) {
  const bin = tools.find('agy');
  if (!bin) return { ok: false, error: 'Antigravity (agy) isn’t installed.' };
  const r = run(bin, ['models'], { encoding: 'utf8', timeout: 15_000, env: tools.ensurePath({ ...process.env, AGY_CLI_DISABLE_AUTO_UPDATE: 'true' }) });
  const text = `${r.stdout || ''}\n${r.stderr || ''}`;
  return { ok: true, ...pickAgyModels(text), output: text.trim().slice(0, 2000) };
}

function pickAgyModels(text) {
  const ids = [];
  for (const line of String(text).split('\n')) {
    const m = line.match(/\b(gemini[\w.:/-]*)/i);
    if (m) ids.push(m[1].replace(/[),.;]+$/, ''));
  }
  const newest = (list) => list.sort((a, b) => b.localeCompare(a, undefined, { numeric: true }))[0] || '';
  return {
    pro: newest(ids.filter((x) => /pro/i.test(x))),
    flash: newest(ids.filter((x) => /flash/i.test(x) && !/lite/i.test(x))) || newest(ids.filter((x) => /flash/i.test(x))),
  };
}

module.exports = { read, write, detectAgyModels, pickAgyModels, CEOS };
