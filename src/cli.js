#!/usr/bin/env node
'use strict';

// `npm run check` — print your limits in the terminal (no window needed).
// `npm run check -- --json` for machine-readable output.

const { fetchAll } = require('./providers');

function bar(pct, width = 20) {
  const filled = Math.round((pct / 100) * width);
  return '█'.repeat(filled) + '░'.repeat(width - filled);
}

function until(ms) {
  if (!ms) return '';
  const s = Math.max(0, Math.round((ms - Date.now()) / 1000));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  return `resets in ${d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`}`;
}

(async () => {
  const results = await fetchAll();
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(results, null, 2));
    return;
  }
  for (const r of results) {
    console.log(`\n${r.name}${r.plan ? ` (${r.plan})` : ''}${r.note ? `  — ${r.note}` : ''}`);
    if (!r.ok) {
      console.log(`  ✗ ${r.error}${r.hint ? `\n    ${r.hint}` : ''}`);
      continue;
    }
    for (const w of r.windows) {
      const pct = w.usedPercent ?? 0;
      console.log(`  ${w.label.padEnd(22)} ${bar(pct)} ${String(Math.round(pct)).padStart(3)}% used  ${until(w.resetsAt)}`);
    }
  }
  console.log();
})();
