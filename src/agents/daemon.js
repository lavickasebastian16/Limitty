'use strict';

// The background part of the PC companion: reads hook events and Codex logs,
// keeps track of each agent session, and shares status and tasks with your iPhone
// through a private GitHub Gist (at most every 15 s, right away when an agent needs
// you or finishes, plus a heartbeat every 10 minutes). The phone turns changes into
// notifications.

const fs = require('fs');
const os = require('os');
const { FILES } = require('./config');
const { applyEvent, tick, snapshot, fingerprint } = require('./state');
const { CodexWatcher } = require('./codex');
const github = require('./github');

const GIST_MIN_INTERVAL_MS = 15_000;
const GIST_HEARTBEAT_MS = 10 * 60_000;

class Daemon {
  constructor(cfg, { log = () => {}, fetchImpl = globalThis.fetch, now = () => Date.now(), company = null, skipLock = false } = {}) {
    this.cfg = cfg;
    this.log = log;
    this.fetch = fetchImpl;
    this.now = now;
    this.sessions = {};
    this.offset = 0;
    this.lastPrint = '';
    this.lastStatusAt = 0;
    this.gistBackoffUntil = 0;
    this.codex = new CodexWatcher();
    this.timers = [];
    this.company = company;
    this.skipLock = skipLock;
    this.onCompanyChange = () => this.requestStatus();
    // A task finished or failed: tell the phone now rather than in up to 15 s.
    this.onCompanyAlert = () => this.requestStatus(true);
    if (company) {
      company.recentFolders = () => Object.values(this.sessions).map((s) => s.cwd).filter(Boolean);
      company.on('change', this.onCompanyChange);
      company.on('alert', this.onCompanyAlert);
    }
  }

  // ───── lifecycle ─────

  start() {
    if (!this.skipLock && !acquireLock()) {
      this.log('Another Limitty agent is already running; not starting a second one.');
      return false;
    }
    this.restore();
    this.timers.push(setInterval(() => this.readEvents(), 1000));
    this.timers.push(setInterval(() => this.ingest(this.codex.scan(this.now())), 5000));
    this.timers.push(setInterval(() => this.onTick(), 5000));
    this.timers.push(setInterval(() => this.pollInbox(), 15_000));
    this.readEvents();
    this.ingest(this.codex.scan(this.now()));
    this.requestStatus(true);
    this.log(this.cfg.github?.gistId
      ? `Limitty agent running. Sharing status with your iPhone via GitHub (@${this.cfg.github.login || 'you'}).`
      : 'Limitty agent running. Not linked to an iPhone yet.');
    return true;
  }

  stop() {
    this.timers.forEach(clearInterval);
    this.timers = [];
    this.persist();
    if (this.company) {
      this.company.off('change', this.onCompanyChange);
      this.company.off('alert', this.onCompanyAlert);
    }
    if (!this.skipLock) releaseLock();
  }

  restore() {
    try {
      const saved = JSON.parse(fs.readFileSync(FILES.state, 'utf8'));
      this.sessions = saved.sessions || {};
      this.offset = saved.offset || 0;
    } catch { /* first run */ }
  }

  persist() {
    try {
      fs.mkdirSync(FILES.dir, { recursive: true });
      fs.writeFileSync(FILES.state, JSON.stringify({ sessions: this.sessions, offset: this.offset }));
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
    let alerted = false;
    for (const ev of events) {
      const r = applyEvent(this.sessions, ev);
      this.sessions = r.sessions;
      if (r.alert) alerted = true;
    }
    // Needs you / finished: the phone should hear about it right away.
    this.requestStatus(alerted);
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
    const gh = this.cfg.github;
    if (!gh?.token || !gh.gistId) return;
    const now = this.now();
    const snap = snapshot(this.sessions, { host: os.hostname(), now });
    const print = fingerprint(snap) + (this.company ? this.company.fingerprint() : '');
    const due = print !== this.lastPrint || now - this.lastStatusAt > GIST_HEARTBEAT_MS;
    if (!due && !force) return;
    if (!force && now - this.lastStatusAt < GIST_MIN_INTERVAL_MS) return; // next tick
    if (now < this.gistBackoffUntil) return;
    this.lastPrint = print;
    this.lastStatusAt = now;
    const files = { [github.STATUS_FILE]: snap };
    if (this.company) files[github.TASKS_FILE] = this.company.snapshot();
    github.writeFiles(gh.token, gh.gistId, files, this.fetch).catch((e) => {
      this.log(`Couldn't update the GitHub Gist: ${e.message}`);
      this.lastPrint = ''; // retry
      this.gistBackoffUntil = now + 60_000;
    });
  }

  /** Tasks you gave from the phone (Company mode). */
  async pollInbox() {
    const gh = this.cfg.github;
    if (!this.company || !gh?.token || !gh.gistId) return;
    try {
      const inbox = await github.readFile(gh.token, gh.gistId, github.INBOX_FILE, this.fetch);
      if (inbox?.requests?.length) this.company.handleInbox(inbox.requests);
    } catch (e) {
      this.log(`Couldn't read tasks from your phone: ${e.message}`);
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

module.exports = { Daemon, acquireLock, releaseLock };
