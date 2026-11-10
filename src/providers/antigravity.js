'use strict';

// Google Antigravity (agy) model quotas.
//
// Antigravity (the app, IDE and the `agy` CLI) runs a local "language server"
// that knows your current model quotas. We:
//   1. find that process, read its --csrf_token / port flags,
//   2. ask it for the quota summary over its local Connect/JSON API,
//   3. fall back to `agy -p /usage --output-format json` if no server is up.

const https = require('https');
const http = require('http');
const { HOME, run, toMs, clampPct, ProviderError, path, fs } = require('./util');

const SERVICE = '/exa.language_server_pb.LanguageServerService/';
const METHODS = ['RetrieveUserQuotaSummary', 'GetUserStatus'];
const METADATA = { ideName: 'antigravity', extensionName: 'antigravity', locale: 'en', ideVersion: 'unknown' };

// ---------- process + port discovery ----------

async function listProcesses() {
  if (process.platform === 'win32') {
    const r = await run('powershell.exe', [
      '-NoProfile', '-Command',
      'Get-CimInstance Win32_Process | Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress',
    ], { timeout: 15000 });
    if (!r.ok) return [];
    try {
      const arr = [].concat(JSON.parse(r.stdout));
      return arr.filter((p) => p.CommandLine).map((p) => ({ pid: p.ProcessId, cmd: p.CommandLine }));
    } catch { return []; }
  }
  const r = await run('ps', ['-ax', '-o', 'pid=,command=']);
  if (!r.ok) return [];
  return r.stdout.split('\n').map((l) => {
    const m = l.trim().match(/^(\d+)\s+(.*)$/);
    return m ? { pid: Number(m[1]), cmd: m[2] } : null;
  }).filter(Boolean);
}

function flag(cmd, name) {
  const m = cmd.match(new RegExp(`--${name}[=\\s]+("([^"]*)"|(\\S+))`));
  return m ? (m[2] ?? m[3]) : null;
}

function findServers(procs) {
  const out = [];
  for (const { pid, cmd } of procs) {
    const lower = cmd.toLowerCase();
    const isLs = /language[_-]server/.test(lower);
    const isAg = lower.includes('antigravity') || /(^|[\\/\s])agy(\.exe)?(\s|$)/.test(lower);
    if (!isLs || !isAg) continue;
    out.push({
      pid,
      csrf: flag(cmd, 'csrf_token') || '',
      extPort: Number(flag(cmd, 'extension_server_port')) || null,
      extCsrf: flag(cmd, 'extension_server_csrf_token'),
    });
  }
  return out;
}

async function listeningPorts(pid) {
  const ports = new Set();
  if (process.platform === 'win32') {
    const r = await run('netstat', ['-ano', '-p', 'tcp']);
    for (const line of r.stdout.split('\n')) {
      const cols = line.trim().split(/\s+/);
      if (cols[3] === 'LISTENING' && Number(cols[4]) === pid) {
        const p = Number(cols[1].split(':').pop());
        if (p) ports.add(p);
      }
    }
    return [...ports];
  }
  const r = await run('lsof', ['-nP', '-iTCP', '-sTCP:LISTEN', '-a', '-p', String(pid)]);
  for (const m of r.stdout.matchAll(/:(\d+)\s+\(LISTEN\)/g)) ports.add(Number(m[1]));
  if (!ports.size && process.platform === 'linux') {
    // /proc fallback: map the process's socket inodes to listening ports.
    try {
      const inodes = new Set();
      for (const fd of fs.readdirSync(`/proc/${pid}/fd`)) {
        try {
          const m = fs.readlinkSync(`/proc/${pid}/fd/${fd}`).match(/socket:\[(\d+)\]/);
          if (m) inodes.add(m[1]);
        } catch { /* ignore */ }
      }
      for (const t of ['tcp', 'tcp6']) {
        let txt = '';
        try { txt = fs.readFileSync(`/proc/${pid}/net/${t}`, 'utf8'); } catch { continue; }
        for (const line of txt.split('\n').slice(1)) {
          const c = line.trim().split(/\s+/);
          if (c[3] === '0A' && inodes.has(c[9])) ports.add(parseInt(c[1].split(':')[1], 16));
        }
      }
    } catch { /* ignore */ }
  }
  return [...ports];
}

function post(proto, port, method, csrf) {
  const body = JSON.stringify({ metadata: METADATA });
  const lib = proto === 'https' ? https : http;
  return new Promise((resolve) => {
    const req = lib.request({
      host: '127.0.0.1',
      port,
      path: SERVICE + method,
      method: 'POST',
      // The local server uses a self-signed cert; only ever talk to 127.0.0.1.
      rejectUnauthorized: false,
      timeout: 4000,
      headers: {
        'Content-Type': 'application/json',
        'Connect-Protocol-Version': '1',
        'X-Codeium-Csrf-Token': csrf || '',
        'Content-Length': Buffer.byteLength(body),
      },
    }, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        if (res.statusCode !== 200) return resolve(null);
        try { resolve(JSON.parse(data)); } catch { resolve(null); }
      });
    });
    req.on('error', () => resolve(null));
    req.on('timeout', () => { req.destroy(); resolve(null); });
    req.end(body);
  });
}

async function queryServer(server) {
  const targets = [];
  for (const port of await listeningPorts(server.pid)) targets.push(['https', port, server.csrf], ['http', port, server.csrf]);
  if (server.extPort) targets.push(['http', server.extPort, server.extCsrf || server.csrf]);
  for (const method of METHODS) {
    for (const [proto, port, csrf] of targets) {
      const json = await post(proto, port, method, csrf);
      if (!json) continue;
      const parsed = parseQuota(json);
      if (parsed.windows.length) return parsed;
    }
  }
  return null;
}

// ---------- agy CLI fallback ----------

async function findAgy() {
  if (process.env.ANTIGRAVITY_CLI_PATH) return process.env.ANTIGRAVITY_CLI_PATH;
  const which = await run(process.platform === 'win32' ? 'where' : 'which', ['agy']);
  if (which.ok && which.stdout.trim()) return which.stdout.trim().split(/\r?\n/)[0];
  for (const p of [path.join(HOME, '.local/bin/agy'), '/opt/homebrew/bin/agy', '/usr/local/bin/agy']) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

async function queryCli(bin) {
  const r = await run(bin, ['-p', '/usage', '--output-format', 'json'], {
    timeout: 45000,
    env: { ...process.env, AGY_CLI_DISABLE_AUTO_UPDATE: 'true', NO_COLOR: '1' },
  });
  const text = r.stdout;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start < 0 || end < start) return null;
  try {
    const parsed = parseQuota(JSON.parse(text.slice(start, end + 1)));
    return parsed.windows.length ? parsed : null;
  } catch { return null; }
}

// ---------- parsing ----------

const NAME_KEYS = ['displayName', 'label', 'modelName', 'model', 'name', 'bucketId', 'id'];

function nameOf(o) {
  for (const k of NAME_KEYS) if (typeof o?.[k] === 'string' && o[k]) return o[k];
  if (typeof o?.modelOrAlias?.model === 'string') return o.modelOrAlias.model;
  return null;
}

/**
 * Walk any quota-shaped JSON and pull out {label, usedPercent, resetsAt}.
 * Handles the summary format (groups[].buckets[].remaining.remainingFraction),
 * the legacy GetUserStatus format (clientModelConfigs[].quotaInfo) and
 * generic percentage fields the CLI may emit.
 */
function parseQuota(json) {
  const found = [];
  const seen = new Set();

  const visit = (node, parentName, groupName) => {
    if (!node || typeof node !== 'object') return;
    if (Array.isArray(node)) { node.forEach((n) => visit(n, parentName, groupName)); return; }

    const own = nameOf(node);
    const name = own || parentName;
    const isGroup = Array.isArray(node.buckets);
    const nextGroup = isGroup ? own || groupName : groupName;

    const quota = node.quotaInfo || node.remaining || node.quota;
    let remaining = null;
    let used = null;
    let reset = null;
    if (quota && typeof quota === 'object' && !Array.isArray(quota)) {
      // Proto3 omits zero values: a quotaInfo with no remainingFraction means exhausted.
      remaining = quota.remainingFraction ?? (quota.resetTime ? 0 : null);
      reset = quota.resetTime ?? quota.resetAt;
    } else if (typeof node.remainingFraction === 'number') {
      remaining = node.remainingFraction;
      reset = node.resetTime ?? node.resetAt;
    } else {
      const pct = node.usedPercent ?? node.used_percent ?? node.percentUsed;
      const rem = node.remainingPercent ?? node.remaining_percent ?? node.percentRemaining;
      if (typeof pct === 'number') used = pct;
      else if (typeof rem === 'number') used = 100 - rem;
      reset = node.resetTime ?? node.resetsAt ?? node.resets_at ?? node.reset_at;
    }
    if (remaining != null) used = (1 - Number(remaining)) * 100;

    if (used != null && name) {
      const label = groupName && groupName !== name ? `${groupName} · ${name}` : name;
      if (!seen.has(label)) {
        seen.add(label);
        found.push({ id: label, label, usedPercent: clampPct(used), resetsAt: toMs(reset) });
      }
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (k === 'quotaInfo' || k === 'remaining') continue;
      visit(v, name, nextGroup);
    }
  };

  visit(json, null, null);
  return { plan: findPlan(json), windows: condense(found) };
}

function findPlan(json) {
  const p = json?.userStatus?.planStatus?.planInfo?.planName
    || json?.userStatus?.userTier?.name
    || json?.planName || json?.plan;
  return typeof p === 'string' ? p : null;
}

/** Many individual models share one quota pool; collapse to families when the list is long. */
function condense(windows) {
  if (windows.length <= 4) return windows;
  const families = new Map();
  for (const w of windows) {
    const l = w.label.toLowerCase();
    const fam = l.includes('gemini') && l.includes('flash') ? 'Gemini Flash'
      : l.includes('gemini') ? 'Gemini Pro'
        : l.includes('claude') || l.includes('gpt') || l.includes('sonnet') || l.includes('opus') ? 'Claude + GPT'
          : 'Other models';
    const cur = families.get(fam);
    if (!cur || w.usedPercent > cur.usedPercent) families.set(fam, { ...w, id: fam, label: fam });
  }
  return [...families.values()];
}

async function fetchAntigravity() {
  const servers = findServers(await listProcesses());
  for (const s of servers) {
    const res = await queryServer(s);
    if (res) return res;
  }
  const bin = await findAgy();
  if (bin) {
    const res = await queryCli(bin);
    if (res) return { ...res, note: 'via agy CLI' };
  }
  if (!servers.length && !bin) {
    throw new ProviderError('Antigravity not running', 'Open Antigravity or install the `agy` CLI and sign in.');
  }
  throw new ProviderError('Could not read quota', 'Make sure you are signed in to Antigravity / `agy`.');
}

module.exports = { id: 'antigravity', name: 'Antigravity', fetch: fetchAntigravity, parseQuota, findServers };
