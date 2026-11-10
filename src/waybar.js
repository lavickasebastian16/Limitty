'use strict';

// Waybar module: usage limits + agent/task status in your bar (made for Omarchy).
//
//   "custom/limitty": {
//     "exec": "limitty --waybar",      // or: node /path/to/Limitty/src/waybar.js
//     "return-type": "json",
//     "interval": 60,
//     "on-click": "limitty --toggle",
//     "on-click-right": "limitty --company"
//   }
//
// Limits are cached for 2 minutes so Waybar doesn't hammer the usage APIs.

const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = process.env.LIMITTY_HOME || path.join(os.homedir(), '.limitty');
const CACHE = path.join(DIR, 'waybar-cache.json');
const TTL_MS = 2 * 60_000;
const SHORT = { claude: 'C', codex: 'X', antigravity: 'G' };

async function limits() {
  try {
    const c = JSON.parse(fs.readFileSync(CACHE, 'utf8'));
    if (Date.now() - c.at < TTL_MS) return c.results;
  } catch { /* no cache */ }
  const { fetchAll } = require('./providers');
  const results = await fetchAll();
  try {
    fs.mkdirSync(DIR, { recursive: true });
    fs.writeFileSync(CACHE, JSON.stringify({ at: Date.now(), results }));
  } catch { /* ignore */ }
  return results;
}

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function untilText(ms) {
  if (!ms) return '';
  const s = Math.max(0, Math.round((ms - Date.now()) / 1000));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
}

/** Builds the Waybar JSON: { text, tooltip, class, percentage }. */
function build(results, agents, company) {
  const parts = [];
  const tip = [];
  let worst = 0;
  for (const r of results) {
    if (!r.ok) { tip.push(`${r.name}: ${r.error}`); continue; }
    const top = Math.max(...r.windows.map((w) => w.usedPercent ?? 0));
    worst = Math.max(worst, top);
    parts.push(`${SHORT[r.id] || r.name[0]} ${Math.round(top)}%`);
    tip.push(`<b>${r.name}</b>${r.plan ? ` (${r.plan})` : ''}`);
    for (const w of r.windows) tip.push(`  ${w.label}: ${Math.round(w.usedPercent ?? 0)}%${w.resetsAt ? `, resets in ${untilText(w.resetsAt)}` : ''}`);
  }

  const sessions = Object.values(agents?.sessions || {});
  const needs = sessions.filter((s) => s.state === 'attention').length;
  const working = sessions.filter((s) => s.state === 'working' || s.state === 'waiting').length;
  const tasks = (company?.tasks || []).filter((t) => ['queued', 'planning', 'running'].includes(t.status)).length;
  const extra = [needs ? `! ${needs}` : '', working ? `● ${working}` : '', tasks ? `▸ ${tasks}` : ''].filter(Boolean);
  if (sessions.length || tasks) {
    tip.push('', '<b>Agents</b>');
    for (const s of sessions) tip.push(`  ${s.agent} · ${s.project || ''}: ${s.state} (${s.detail})`);
    if (tasks) tip.push(`  ${tasks} Company task${tasks > 1 ? 's' : ''} in progress`);
  }

  const cls = needs ? 'attention' : worst >= 85 ? 'critical' : worst >= 60 ? 'warning' : 'normal';
  return {
    text: [...extra, parts.join(' · ') || 'Limitty'].join('  '),
    tooltip: tip.join('\n') || 'No usage data yet',
    class: cls,
    percentage: Math.round(worst),
  };
}

async function print() {
  let out;
  try {
    out = build(await limits(), readJson(path.join(DIR, 'state.json')), readJson(path.join(DIR, 'company.json')));
  } catch (e) {
    out = { text: 'Limitty', tooltip: e.message, class: 'error' };
  }
  process.stdout.write(`${JSON.stringify(out)}\n`);
}

if (require.main === module) print();

module.exports = { print, build };
