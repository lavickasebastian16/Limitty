'use strict';

// The background part of the PC companion: reads hook events and Codex logs,
// keeps track of each agent session, and relays status to your iPhone.
//
// Budget: ntfy.sh's free tier allows 250 messages a day per IP address, so
// status goes out only when it changes (at most every 30 s), with a heartbeat
// every 30 minutes; push alerts go out right away.

const fs = require('fs');
const os = require('os');
const { FILES, alertsTopic } = require('./config');
const { seal } = require('./crypto');
const { applyEvent, tick, snapshot, fingerprint, alertText } = require('./state');
const { CodexWatcher } = require('./codex');

const STATUS_MIN_INTERVAL_MS = 30_000;
const STATUS_SLOW_INTERVAL_MS = 5 * 60_000; // when the daily budget runs low
const HEARTBEAT_MS = 30 * 60_000;
const DAILY_BUDGET = 250;
const SLOW_DOWN_AT = 180;
const ALERT_RESERVE = 10;

class Daemon {
  constructor(cfg, { log = () => {}, fetchImpl = globalThis.fetch, now = () => Date.now() } = {}) {
    this.cfg = cfg;
    this.log = log;
    this.fetch = fetchImpl;
    this.now = now;
    this.sessions = {};
    this.offset = 0;
    this.lastPrint = '';
    this.lastStatusAt = 0;
    this.pendingStatus = false;
    this.budget = { day: 0, used: 0 };
    this.backoffUntil = 0;
    this.recentAlerts = new Map();
    this.codex = new CodexWatcher();
    this.timers = [];
  }

  // ───── lifecycle ─────

  start() {
    if (!acquireLock()) {
      this.log('Another Limitty agent is already running; not starting a second one.');
      return false;
    }
    this.restore();
    this.timers.push(setInterval(() => this.readEvents(), 1000));
    this.timers.push(setInterval(() => this.ingest(this.codex.scan(this.now())), 5000));
    this.timers.push(setInterval(() => this.onTick(), 5000));
    this.readEvents();
    this.ingest(this.codex.scan(this.now()));
    this.requestStatus(true);
    this.log(`Limitty agent running. Relaying to ${this.cfg.server}/${this.cfg.topic}`);
    return true;
  }

  stop() {
    this.timers.forEach(clearInterval);
    this.timers = [];
    this.persist();
    releaseLock();
  }

  restore() {
    try {
      const saved = JSON.parse(fs.readFileSync(FILES.state, 'utf8'));
      this.sessions = saved.sessions || {};
      this.offset = saved.offset || 0;
      this.budget = saved.budget || this.budget;
    } catch { /* first run */ }
  }

  persist() {
    try {
      fs.mkdirSync(FILES.dir, { recursive: true });
      fs.writeFileSync(FILES.state, JSON.stringify({ sessions: this.sessions, offset: this.offset, budget: this.budget }));
    } catch { /* ignore */ }
  }

  // ───── input ─────

  readEvents() {
    let size;
    try { size = fs.statSync(FILES.events).size; } catch { return; }
    if (size < this.offset) this.offset = 0; // file was rotated
    if (size === this.offset) return;
    const fd = fs.openSync(FILES.events, 'r');
    const buf = Buffer.alloc(size - this.offset);
    fs.readSync(fd, buf, 0, buf.length, this.offset);
    fs.closeSync(fd);
    const text = buf.toString('utf8');
    const end = text.lastIndexOf('\n');
    if (end === -1) return; // wait for a complete line
    this.offset += Buffer.byteLength(text.slice(0, end + 1));
    const events = text.slice(0, end).split('\n').map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
    this.ingest(events);
    // Keep the events file small.
    if (this.offset > 1_000_000) {
      try { fs.truncateSync(FILES.events, 0); this.offset = 0; } catch { /* ignore */ }
    }
  }

  ingest(events) {
    if (!events.length) return;
    for (const ev of events) {
      const r = applyEvent(this.sessions, ev);
      this.sessions = r.sessions;
      if (r.alert) this.sendAlert(r.alert);
    }
    this.requestStatus();
    this.persist();
  }

  onTick() {
    const r = tick(this.sessions, this.now());
    if (r.changed) {
      this.sessions = r.sessions;
      this.persist();
    }
    this.requestStatus();
  }

  // ───── output ─────

  requestStatus(force = false) {
    const now = this.now();
    const snap = snapshot(this.sessions, { host: os.hostname(), now });
    const print = fingerprint(snap);
    const changed = print !== this.lastPrint;
    const heartbeatDue = now - this.lastStatusAt > HEARTBEAT_MS;
    if (!changed && !heartbeatDue && !force) return;
    const minGap = this.budgetLeft() < DAILY_BUDGET - SLOW_DOWN_AT ? STATUS_SLOW_INTERVAL_MS : STATUS_MIN_INTERVAL_MS;
    if (!force && now - this.lastStatusAt < minGap) return; // try again on the next tick
    if (this.budgetLeft() <= ALERT_RESERVE) return;
    this.lastPrint = print;
    this.lastStatusAt = now;
    this.post(this.cfg.topic, seal(snap, this.cfg.key), {}).catch(() => {});
  }

  sendAlert(alert) {
    if (alert.kind === 'finished' && !this.cfg.alertOnFinish) return;
    const now = this.now();
    const dedupe = `${alert.session.key}|${alert.kind}|${alert.session.detail}`;
    if (now - (this.recentAlerts.get(dedupe) || 0) < 60_000) return;
    this.recentAlerts.set(dedupe, now);
    if (this.budgetLeft() <= 0) return;
    const a = alertText(alert, this.cfg);
    // Query parameters (rather than headers) keep non-ASCII titles intact.
    const q = new URLSearchParams({ title: a.title, priority: String(a.priority), tags: a.tags, click: 'limitty://agents' });
    this.post(`${alertsTopic(this.cfg)}?${q}`, a.body, {}).catch(() => {});
    // Make sure the phone app's list matches the alert.
    this.lastStatusAt = 0;
    setTimeout(() => this.requestStatus(), 1500);
  }

  budgetLeft() {
    const day = Math.floor(this.now() / 86_400_000);
    if (this.budget.day !== day) this.budget = { day, used: 0 };
    return DAILY_BUDGET - this.budget.used;
  }

  async post(topic, body, headers) {
    if (this.now() < this.backoffUntil) return;
    this.budgetLeft();
    this.budget.used += 1;
    const h = { ...headers };
    if (this.cfg.token) h.Authorization = `Bearer ${this.cfg.token}`;
    try {
      const res = await this.fetch(`${this.cfg.server}/${topic}`, { method: 'POST', body, headers: h });
      if (res.status === 429) {
        this.backoffUntil = this.now() + 10 * 60_000;
        this.log('ntfy rate limit reached; pausing for 10 minutes.');
      } else if (!res.ok) {
        this.log(`ntfy returned HTTP ${res.status}`);
      }
    } catch (e) {
      this.log(`Couldn't reach ${this.cfg.server}: ${e.message}`);
    }
  }
}

// One agent per PC: a PID lock file.
const LOCK = () => `${FILES.dir}/agent.pid`;

function acquireLock() {
  try {
    const pid = Number(fs.readFileSync(LOCK(), 'utf8'));
    if (pid && pid !== process.pid) {
      try { process.kill(pid, 0); return false; } catch { /* stale lock */ }
    }
  } catch { /* no lock */ }
  fs.mkdirSync(FILES.dir, { recursive: true });
  fs.writeFileSync(LOCK(), String(process.pid));
  return true;
}

function releaseLock() {
  try {
    if (Number(fs.readFileSync(LOCK(), 'utf8')) === process.pid) fs.unlinkSync(LOCK());
  } catch { /* ignore */ }
}

module.exports = { Daemon };
