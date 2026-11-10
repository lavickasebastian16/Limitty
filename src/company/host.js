'use strict';

// One process on the PC runs the Company and the phone relay: the desktop app or
// the background agent (`npm run agent`), whichever starts first. The other one
// talks to it through files: requests go to ~/.limitty/inbox.jsonl and the task
// list is read from ~/.limitty/company.json.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('../agents/config');
const { Daemon, acquireLock, releaseLock } = require('../agents/daemon');
const { Company, LOCAL_INBOX } = require('./company');
const { FILE: COMPANY_FILE } = require('./store');

function startHost({ log = () => {} } = {}) {
  if (!acquireLock()) return { owner: false };
  const cfg = config.load();
  const company = new Company({ ceo: cfg?.ceo || 'claude', workerOptions: cfg?.workers || {} });
  company.start();
  const host = {
    owner: true,
    company,
    daemon: null,
    /** Starts (or restarts) the phone relay, e.g. after connecting GitHub. */
    attachRelay() {
      host.daemon?.stop();
      host.daemon = null;
      const c = config.load();
      if (!c) return;
      host.daemon = new Daemon(c, { log, company, skipLock: true });
      host.daemon.start();
    },
    detachRelay() {
      host.daemon?.stop();
      host.daemon = null;
    },
    stop() {
      host.detachRelay();
      company.stop();
      releaseLock();
    },
  };
  host.attachRelay();

  // Settings changed (Settings window, CLI or by hand): use them right away.
  host.applyConfig = () => {
    const c = config.load() || {};
    company.ceo = c.ceo || 'claude';
    company.workerOptions = c.workers || {};
    require('./workers').isInstalled.clearCache?.();
    if (host.daemon) {
      for (const k of ['alertOnFinish', 'showProjectNames']) if (k in c) host.daemon.cfg[k] = c[k];
    }
    company.changed();
  };
  const onConfig = () => host.applyConfig();
  fs.watchFile(config.FILES.config, { interval: 1500 }, onConfig);
  const stop = host.stop;
  host.stop = () => { fs.unwatchFile(config.FILES.config, onConfig); stop(); };
  return host;
}

/** For the process that isn't running the Company. */
function sendRequest(req) {
  fs.mkdirSync(path.dirname(LOCAL_INBOX), { recursive: true });
  fs.appendFileSync(LOCAL_INBOX, `${JSON.stringify({ id: crypto.randomBytes(6).toString('hex'), source: 'pc', ...req })}\n`);
}

function readState() {
  try {
    const d = JSON.parse(fs.readFileSync(COMPANY_FILE, 'utf8'));
    return { tasks: d.tasks || [], projects: d.allProjects || d.projects || [], team: d.team || {} };
  } catch {
    return { tasks: [], projects: [], team: {} };
  }
}

module.exports = { startHost, sendRequest, readState, COMPANY_FILE };
