'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const DIR = process.env.LIMITTY_HOME || path.join(os.homedir(), '.limitty');
const FILES = {
  dir: DIR,
  config: path.join(DIR, 'agent.json'),
  events: path.join(DIR, 'events.jsonl'),
  state: path.join(DIR, 'state.json'),
  log: path.join(DIR, 'agent.log'),
};

const DEFAULTS = {
  server: 'https://ntfy.sh',
  // Optional ntfy access token (for a self-hosted server or a paid ntfy.sh plan).
  token: null,
  // Push "finished" alerts as well as "needs you" alerts.
  alertOnFinish: true,
  // Include project folder names in push alerts (alerts are not encrypted).
  showProjectNames: true,
};

function base64url(buf) {
  return buf.toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function load() {
  try {
    return { ...DEFAULTS, ...JSON.parse(fs.readFileSync(FILES.config, 'utf8')) };
  } catch {
    return null;
  }
}

/** Creates the pairing secrets once; later calls return the existing config. */
function ensure() {
  const existing = load();
  if (existing) return existing;
  const cfg = {
    ...DEFAULTS,
    // Topic names are public on ntfy.sh, so they're long and random. Status is
    // also encrypted with `key`, which never leaves your PC and phone.
    topic: `limitty-${base64url(crypto.randomBytes(15)).replace(/[-_]/g, 'x')}`,
    key: base64url(crypto.randomBytes(32)),
  };
  save(cfg);
  return cfg;
}

function save(cfg) {
  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(FILES.config, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

const alertsTopic = (cfg) => `${cfg.topic}-alerts`;

function pairingLink(cfg) {
  const q = new URLSearchParams({ s: cfg.server, t: cfg.topic, k: cfg.key });
  return `limitty://pair?${q.toString()}`;
}

module.exports = { FILES, DEFAULTS, load, ensure, save, alertsTopic, pairingLink, base64url };
