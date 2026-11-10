'use strict';

// OpenAI Codex (ChatGPT plan) limits.
// Primary source: the usage endpoint the Codex CLI's /status reads, using the
// login stored in ~/.codex/auth.json. Fallback: the most recent `rate_limits`
// snapshot Codex writes into its local session logs.

const { HOME, readJson, fetchJson, toMs, clampPct, windowLabel, ProviderError, path, fs } = require('./util');

const USAGE_URL = 'https://chatgpt.com/backend-api/wham/usage';

function codexHome() {
  return process.env.CODEX_HOME || path.join(HOME, '.codex');
}

function windowFrom(id, w, nowMs = Date.now()) {
  if (!w) return null;
  const seconds = w.limit_window_seconds ?? (w.window_minutes != null ? w.window_minutes * 60 : null);
  let resetsAt = toMs(w.reset_at ?? w.resets_at);
  const after = w.reset_after_seconds ?? w.resets_in_seconds;
  if (!resetsAt && after != null) resetsAt = nowMs + after * 1000;
  return { id, label: windowLabel(seconds), usedPercent: clampPct(w.used_percent), resetsAt };
}

function parseUsage(json) {
  const rl = json?.rate_limit || {};
  const windows = [
    windowFrom('primary', rl.primary_window),
    windowFrom('secondary', rl.secondary_window),
  ].filter(Boolean);
  const plan = json?.plan_type ? String(json.plan_type).replace(/^\w/, (c) => c.toUpperCase()) : null;
  return { plan, windows };
}

/** Find the newest rate_limits event in ~/.codex/sessions/**.jsonl */
function readFromSessionLogs() {
  const root = path.join(codexHome(), 'sessions');
  const files = [];
  const walk = (dir, depth) => {
    let entries;
    try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = path.join(dir, e.name);
      if (e.isDirectory() && depth < 4) walk(p, depth + 1);
      else if (e.isFile() && e.name.endsWith('.jsonl')) {
        try { files.push({ p, m: fs.statSync(p).mtimeMs }); } catch { /* ignore */ }
      }
    }
  };
  walk(root, 0);
  files.sort((a, b) => b.m - a.m);

  for (const { p, m } of files.slice(0, 10)) {
    let lines;
    try { lines = fs.readFileSync(p, 'utf8').trim().split('\n'); } catch { continue; }
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].includes('rate_limits')) continue;
      let ev;
      try { ev = JSON.parse(lines[i]); } catch { continue; }
      const rl = ev?.payload?.rate_limits || ev?.rate_limits || ev?.msg?.rate_limits;
      if (!rl) continue;
      const tsMs = toMs(ev.timestamp) ?? m;
      const windows = [windowFrom('primary', rl.primary, tsMs), windowFrom('secondary', rl.secondary, tsMs)].filter(Boolean);
      if (windows.length) return { windows, asOf: tsMs };
    }
  }
  return null;
}

async function fetchCodex() {
  const auth = readJson(path.join(codexHome(), 'auth.json'));
  const token = auth?.tokens?.access_token;
  let apiError = null;

  if (token) {
    const headers = {
      Authorization: `Bearer ${token}`,
      'User-Agent': 'codex-cli',
      Accept: 'application/json',
    };
    if (auth.tokens.account_id) headers['ChatGPT-Account-Id'] = auth.tokens.account_id;
    try {
      const res = await fetchJson(USAGE_URL, { headers });
      if (res.ok && res.json) {
        const parsed = parseUsage(res.json);
        if (parsed.windows.length) return parsed;
        apiError = 'No limit data in response';
      } else if (res.status === 401 || res.status === 403) {
        apiError = 'Login expired';
      } else {
        apiError = `Usage API returned HTTP ${res.status}`;
      }
    } catch (e) {
      apiError = e.message;
    }
  }

  const local = readFromSessionLogs();
  if (local) {
    return { plan: null, windows: local.windows, note: `from local log · ${new Date(local.asOf).toLocaleString()}` };
  }

  if (!token) throw new ProviderError('Not signed in', 'Run `codex login` and sign in with ChatGPT.');
  throw new ProviderError(apiError || 'Unavailable', apiError === 'Login expired' ? 'Run `codex` once to refresh your login.' : undefined);
}

module.exports = { id: 'codex', name: 'Codex', fetch: fetchCodex, parseUsage, readFromSessionLogs };
