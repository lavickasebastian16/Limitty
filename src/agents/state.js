'use strict';

// Turns agent events into per-session status. Pure functions, no I/O.
//
// States:
//   working    the agent is busy
//   attention  it's blocked on you (permission prompt, question)
//   waiting    a tool has been pending a while: running long, or waiting for approval
//              (Codex and agy don't report approval prompts, so this is a best guess)
//   idle       finished its turn / waiting for your next prompt

const AGENTS = { claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity' };
const PENDING_TOOL_MS = 30_000; // tool pending this long → "waiting"
const STALE_WORKING_MS = 15 * 60_000; // working with no events → idle
const DROP_IDLE_MS = 3 * 3600_000; // forget idle sessions after this
const MAX_SESSIONS = 12;

function project(cwd) {
  if (!cwd) return '';
  // Split on both separators: hooks may report Windows paths.
  const parts = String(cwd).split(/[\\/]+/).filter(Boolean);
  return parts[parts.length - 1] || String(cwd);
}

/**
 * Applies one event. Returns { sessions, alert } where alert is
 * { kind: 'attention' | 'finished', session } when a push alert is due.
 *
 * Event: { t, agent, event, session, cwd, detail }
 */
function applyEvent(sessions, ev) {
  const key = `${ev.agent}:${ev.session || 'default'}`;
  const prev = sessions[key];
  const s = prev
    ? { ...prev }
    : { key, agent: ev.agent, id: ev.session || 'default', project: project(ev.cwd), state: 'idle', detail: 'Ready', since: ev.t, pendingTool: null };
  if (ev.cwd) { s.project = project(ev.cwd); s.cwd = ev.cwd; }
  s.lastEvent = ev.t;
  const d = ev.detail || {};

  const set = (state, detail) => {
    if (s.state !== state) s.since = ev.t;
    s.state = state;
    s.detail = detail;
  };

  switch (`${ev.agent}:${ev.event}`) {
    // ── Claude Code hooks ──
    case 'claude:SessionStart': set('idle', 'Ready'); break;
    case 'claude:UserPromptSubmit': set('working', 'Working'); s.pendingTool = null; break;
    case 'claude:PreToolUse': set('working', d.tool ? `Using ${d.tool}` : 'Working'); break;
    case 'claude:PostToolUse': set('working', 'Working'); break;
    case 'claude:Notification': {
      const type = d.type || '';
      const msg = d.message || '';
      if (type === 'idle_prompt') {
        if (s.state !== 'idle') set('idle', 'Waiting for your next prompt');
      } else if (/permission|elicitation/.test(type) || /permission|approv|needs your/i.test(msg)) {
        set('attention', msg || 'Needs your permission');
      }
      break;
    }
    case 'claude:Stop': set('idle', 'Finished'); s.pendingTool = null; break;
    case 'claude:SessionEnd': {
      const next = { ...sessions };
      delete next[key];
      return { sessions: next, alert: null };
    }

    // ── Antigravity (agy) hooks ──
    case 'agy:SessionStart': set('idle', 'Ready'); break;
    case 'agy:PreInvocation': set('working', 'Working'); break;
    case 'agy:PreToolUse': set('working', d.tool ? `Using ${d.tool}` : 'Working'); s.pendingTool = { name: d.tool || 'a tool', at: ev.t }; break;
    case 'agy:PostToolUse': set('working', 'Working'); s.pendingTool = null; break;
    case 'agy:Stop':
      if (d.fullyIdle === false) set('working', 'Working');
      else { set('idle', 'Finished'); s.pendingTool = null; }
      break;

    // ── Codex: turn-complete from `notify`, everything else from its session logs ──
    case 'codex:agent-turn-complete': set('idle', 'Finished'); s.pendingTool = null; break;
    case 'codex:log':
      if (d.state === 'working') set('working', d.tool ? `Running ${d.tool}` : 'Working');
      else if (d.state === 'pending') { set('working', `Running ${d.tool || 'a command'}`); s.pendingTool = { name: d.tool || 'a command', at: d.since || ev.t }; }
      else if (d.state === 'idle') { set('idle', d.aborted ? 'Stopped' : 'Finished'); s.pendingTool = null; }
      if (d.state !== 'pending') s.pendingTool = null;
      break;

    default:
      return { sessions, alert: null };
  }

  const next = { ...sessions, [key]: s };
  return { sessions: next, alert: alertFor(prev, s) };
}

function alertFor(prev, s) {
  const was = prev?.state;
  if (s.state === 'attention' && (was !== 'attention' || prev?.detail !== s.detail)) return { kind: 'attention', session: s };
  if (s.state === 'idle' && s.detail === 'Finished' && was && was !== 'idle') return { kind: 'finished', session: s };
  return null;
}

/** Time-based changes: pending tools become "waiting", stale sessions go idle or are dropped. */
function tick(sessions, now) {
  const next = {};
  let changed = false;
  for (const [key, s0] of Object.entries(sessions)) {
    let s = s0;
    if (s.state === 'working' && s.pendingTool && now - s.pendingTool.at > PENDING_TOOL_MS) {
      s = { ...s, state: 'waiting', since: now, detail: `Running ${s.pendingTool.name}, or waiting for your approval` };
    }
    if ((s.state === 'working' || s.state === 'waiting') && now - (s.lastEvent || s.since) > STALE_WORKING_MS) {
      s = { ...s, state: 'idle', since: now, detail: 'No recent activity', pendingTool: null };
    }
    if (s.state === 'idle' && now - (s.lastEvent || s.since) > DROP_IDLE_MS) { changed = true; continue; }
    if (s !== s0) changed = true;
    next[key] = s;
  }
  return { sessions: changed ? next : sessions, changed };
}

/** What the phone receives (encrypted). */
function snapshot(sessions, { host, now }) {
  const order = { attention: 0, waiting: 1, working: 2, idle: 3 };
  const list = Object.values(sessions)
    .sort((a, b) => order[a.state] - order[b.state] || b.lastEvent - a.lastEvent)
    .slice(0, MAX_SESSIONS)
    .map((s) => ({
      agent: s.agent,
      name: AGENTS[s.agent] || s.agent,
      id: String(s.id).slice(0, 12),
      project: String(s.project || '').slice(0, 60),
      state: s.state,
      detail: String(s.detail || '').slice(0, 140),
      since: Math.round(s.since / 1000),
    }));
  return { v: 1, host, sentAt: Math.round(now / 1000), sessions: list };
}

/** A fingerprint that ignores timestamps, to publish only real changes. */
function fingerprint(snap) {
  return JSON.stringify(snap.sessions.map((s) => [s.agent, s.id, s.state, s.detail, s.project]));
}

function alertText(alert, { showProjectNames }) {
  const s = alert.session;
  const name = AGENTS[s.agent] || s.agent;
  const where = showProjectNames && s.project ? ` · ${s.project}` : '';
  if (alert.kind === 'attention') {
    return { title: `${name} needs you${where}`, body: showProjectNames ? s.detail : 'Open your PC to respond.', priority: 4, tags: 'warning' };
  }
  return { title: `${name} finished${where}`, body: 'Waiting for your next prompt.', priority: 3, tags: 'white_check_mark' };
}

module.exports = { applyEvent, tick, snapshot, fingerprint, alertText, AGENTS, PENDING_TOOL_MS, STALE_WORKING_MS };
