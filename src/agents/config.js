'use strict';

// ~/.limitty/agent.json: the GitHub link to your iPhone and your Settings, shared by
// the desktop app, the background agent and the CLI.

const fs = require('fs');
const os = require('os');
const path = require('path');

const DIR = process.env.LIMITTY_HOME || path.join(os.homedir(), '.limitty');
const FILES = {
  dir: DIR,
  config: path.join(DIR, 'agent.json'),
  events: path.join(DIR, 'events.jsonl'),
  state: path.join(DIR, 'state.json'),
  log: path.join(DIR, 'agent.log'),
};

function load() {
  try {
    return JSON.parse(fs.readFileSync(FILES.config, 'utf8'));
  } catch {
    return null;
  }
}

/** The config, created empty if there isn't one yet. */
function ensure() {
  return load() || {};
}

function save(cfg) {
  fs.mkdirSync(DIR, { recursive: true });
  fs.writeFileSync(FILES.config, JSON.stringify(cfg, null, 2), { mode: 0o600 });
}

module.exports = { FILES, load, ensure, save };
