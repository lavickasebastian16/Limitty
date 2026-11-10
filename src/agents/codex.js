'use strict';

// Codex doesn't have status hooks, so we read its session logs
// (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl). Codex writes `task_started` /
// `task_complete` / `turn_aborted` events and every tool call with its output.
// Approval prompts aren't logged, so a tool call with no output for a while is
// reported as "running, or waiting for your approval".

const fs = require('fs');
const os = require('os');
const path = require('path');

const ACTIVE_WINDOW_MS = 2 * 3600_000;
const TAIL_BYTES = 256 * 1024;

function codexHome() {
  return process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
}

const CALL_TYPES = new Set(['function_call', 'custom_tool_call', 'local_shell_call', 'tool_search_call']);
const OUTPUT_TYPES = new Set(['function_call_output', 'custom_tool_call_output', 'local_shell_call_output', 'tool_search_output']);

/**
 * Derives the state from a rollout's lines (oldest first).
 * Returns { state: 'working' | 'pending' | 'idle' | null, tool, since, aborted }.
 */
function deriveFromLines(lines) {
  let state = null;
  let aborted = false;
  const pending = new Map(); // call_id → { name, at }
  for (const line of lines) {
    if (!line) continue;
    let ev;
    try { ev = JSON.parse(line); } catch { continue; }
    const p = ev.payload || {};
    const at = Date.parse(ev.timestamp) || 0;
    if (ev.type === 'event_msg') {
      if (p.type === 'task_started' || p.type === 'turn_started') { state = 'working'; aborted = false; pending.clear(); }
      else if (p.type === 'task_complete' || p.type === 'turn_complete') { state = 'idle'; aborted = false; pending.clear(); }
      else if (p.type === 'turn_aborted') { state = 'idle'; aborted = true; pending.clear(); }
      else if (p.type === 'user_message' && state !== 'working') { state = 'working'; }
    } else if (ev.type === 'response_item') {
      if (CALL_TYPES.has(p.type)) {
        state = 'working';
        pending.set(p.call_id || p.id || String(at), { name: toolName(p), at });
      } else if (OUTPUT_TYPES.has(p.type)) {
        pending.delete(p.call_id || p.id);
      } else if (p.type === 'message' && p.role === 'user' && state !== 'working') {
        state = 'working';
      }
    }
  }
  if (state === 'working' && pending.size) {
    const oldest = [...pending.values()].sort((a, b) => a.at - b.at)[0];
    return { state: 'pending', tool: oldest.name, since: oldest.at, aborted };
  }
  return { state, tool: null, since: null, aborted };
}

function toolName(p) {
  if (p.type === 'local_shell_call') return 'a shell command';
  const n = p.name || 'a tool';
  if (n === 'shell' || n === 'exec_command' || n === 'local_shell') return 'a shell command';
  if (n === 'apply_patch') return 'a file edit';
  return n;
}

function readTail(file, bytes = TAIL_BYTES) {
  const fd = fs.openSync(file, 'r');
  try {
    const size = fs.fstatSync(fd).size;
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(size - start);
    fs.readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString('utf8').split('\n');
    if (start > 0) lines.shift(); // partial first line
    return lines;
  } finally {
    fs.closeSync(fd);
  }
}

function readMeta(file) {
  try {
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(16 * 1024);
    const n = fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const first = JSON.parse(buf.subarray(0, n).toString('utf8').split('\n')[0]);
    if (first.type === 'session_meta') return { id: first.payload?.id, cwd: first.payload?.cwd };
  } catch { /* ignore */ }
  return {};
}

function recentRollouts(now = Date.now()) {
  const root = path.join(codexHome(), 'sessions');
  const out = [];
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith('.jsonl')) {
        try {
          const m = fs.statSync(p).mtimeMs;
          if (now - m < ACTIVE_WINDOW_MS) out.push({ file: p, mtime: m });
        } catch { /* ignore */ }
      }
    }
  };
  walk(root, 0);
  return out;
}

/**
 * Watches Codex logs. `scan()` returns events for sessions whose derived state changed.
 */
class CodexWatcher {
  constructor() {
    this.seen = new Map(); // file → { mtime, key }
  }

  scan(now = Date.now()) {
    const events = [];
    for (const { file, mtime } of recentRollouts(now)) {
      const prev = this.seen.get(file);
      if (prev && prev.mtime === mtime) continue;
      const meta = prev?.meta || readMeta(file);
      let d;
      try { d = deriveFromLines(readTail(file)); } catch { continue; }
      // On first sight of an old log, only report it if it's still mid-turn and recently written.
      const key = `${d.state}|${d.tool}|${d.since}|${d.aborted}`;
      this.seen.set(file, { mtime, key, meta });
      if (prev?.key === key || !d.state) continue;
      if (!prev && d.state === 'idle') continue;
      events.push({
        t: now,
        agent: 'codex',
        event: 'log',
        session: meta.id || path.basename(file, '.jsonl').slice(-36),
        cwd: meta.cwd,
        detail: { state: d.state, tool: d.tool, since: d.since || now, aborted: d.aborted },
      });
    }
    return events;
  }
}

module.exports = { deriveFromLines, CodexWatcher, codexHome };
