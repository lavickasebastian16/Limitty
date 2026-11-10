'use strict';

// Pure rendering helpers (no Electron APIs) so the widget can be previewed/tested in a browser.

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fmtUntil(ms, now = Date.now()) {
  if (!ms) return '';
  const s = Math.max(0, Math.round((ms - now) / 1000));
  if (s === 0) return 'resetting now';
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d) return `resets in ${d}d ${h}h`;
  if (h) return `resets in ${h}h ${m}m`;
  return `resets in ${Math.max(1, m)}m`;
}

function level(pct) {
  if (pct >= 85) return 'bad';
  if (pct >= 60) return 'warn';
  return '';
}

function renderProvider(r, now) {
  const head = `<div class="phead"><span class="dot ${esc(r.id)}"></span><span class="pname">${esc(r.name)}</span>${
    r.plan ? `<span class="plan">${esc(r.plan)}</span>` : ''}${r.note ? `<span class="note" title="${esc(r.note)}">${esc(r.note)}</span>` : ''}</div>`;
  if (!r.ok) {
    return `<div class="provider">${head}<div class="error"><strong>●</strong> ${esc(r.error)}</div>${
      r.hint ? `<div class="hint">${esc(r.hint)}</div>` : ''}</div>`;
  }
  const rows = r.windows.map((w) => {
    const pct = Math.round(w.usedPercent ?? 0);
    return `<div class="row"><div class="rtop"><span class="rlabel" title="${esc(w.label)}">${esc(w.label)}</span><span class="rpct ${level(pct)}">${pct}%</span></div>`
      + `<div class="track"><div class="fill ${level(pct)}" style="width:${pct}%"></div></div>`
      + `<div class="reset">${esc(fmtUntil(w.resetsAt, now))}</div></div>`;
  }).join('');
  return `<div class="provider">${head}${rows}</div>`;
}

const STATE_LABEL = { attention: 'needs you', waiting: 'maybe waiting', working: 'working' };

/** Agents that are doing something right now (from the hooks). */
function renderAgents(sessions) {
  return (sessions || []).map((s) => `<div class="arow ${esc(s.state)}" title="${esc(`${s.name} · ${s.project}: ${s.detail}`)}"><span class="pulse"></span>`
    + `<span class="aname">${esc(s.name)}</span><span class="adetail">${esc(s.project)}${s.detail ? ` · ${esc(s.detail)}` : ''}</span>`
    + `<span class="astate">${STATE_LABEL[s.state] || esc(s.state)}</span></div>`).join('');
}

function renderAll(results, now = Date.now()) {
  if (!results || !results.length) return '<div class="empty">No agents chosen yet. Open ⋯ → Agents to pick and install them.</div>';
  return results.map((r) => renderProvider(r, now)).join('');
}

if (typeof module !== 'undefined') module.exports = { renderAll, renderAgents, fmtUntil, level };
