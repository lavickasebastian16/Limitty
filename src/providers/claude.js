'use strict';

// Claude (Claude Code / claude.ai subscription) limits.
// Uses the same OAuth token Claude Code stores after `claude` login, and the
// usage endpoint Claude Code's own /usage screen reads.

const { HOME, readJson, run, fetchJson, toMs, clampPct, ProviderError, path } = require('./util');

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';

const LABELS = {
  five_hour: 'Session (5h)',
  seven_day: 'Weekly',
  seven_day_opus: 'Weekly · Opus',
  seven_day_sonnet: 'Weekly · Sonnet',
  seven_day_oauth_apps: 'Weekly · Apps',
};

async function readCredentials() {
  if (process.env.CLAUDE_CODE_OAUTH_TOKEN) {
    return { accessToken: process.env.CLAUDE_CODE_OAUTH_TOKEN };
  }
  const configDir = process.env.CLAUDE_CONFIG_DIR || path.join(HOME, '.claude');
  const file = readJson(path.join(configDir, '.credentials.json'));
  if (file?.claudeAiOauth?.accessToken) return file.claudeAiOauth;

  if (process.platform === 'darwin') {
    const r = await run('security', ['find-generic-password', '-s', 'Claude Code-credentials', '-w']);
    if (r.ok) {
      try {
        const parsed = JSON.parse(r.stdout.trim());
        if (parsed?.claudeAiOauth?.accessToken) return parsed.claudeAiOauth;
      } catch { /* ignore */ }
    }
  }
  return null;
}

function parseUsage(json) {
  const windows = [];
  for (const [key, val] of Object.entries(json || {})) {
    if (!val || typeof val !== 'object' || val.utilization == null) continue;
    windows.push({
      id: key,
      label: LABELS[key] || key.replace(/_/g, ' '),
      usedPercent: clampPct(val.utilization),
      resetsAt: toMs(val.resets_at),
    });
  }
  const order = Object.keys(LABELS);
  windows.sort((a, b) => (order.indexOf(a.id) + 1 || 99) - (order.indexOf(b.id) + 1 || 99));

  const extra = json?.extra_usage;
  if (extra?.is_enabled && extra.monthly_limit) {
    windows.push({
      id: 'extra_usage',
      label: 'Extra usage (monthly)',
      usedPercent: clampPct(extra.utilization ?? (extra.used_credits / extra.monthly_limit) * 100),
      resetsAt: null,
    });
  }
  return windows;
}

async function fetchClaude() {
  const creds = await readCredentials();
  if (!creds) {
    throw new ProviderError('Not signed in', 'Open ⋯ → Agents and press Sign in.');
  }
  if (creds.expiresAt && creds.expiresAt < Date.now()) {
    throw new ProviderError('Login expired', 'Open ⋯ → Agents and press Sign in again.');
  }
  const res = await fetchJson(USAGE_URL, {
    headers: {
      Authorization: `Bearer ${creds.accessToken}`,
      'anthropic-beta': 'oauth-2025-04-20',
      'Content-Type': 'application/json',
      'User-Agent': 'limitty/0.1',
    },
  });
  if (res.status === 401 || res.status === 403) {
    throw new ProviderError('Login expired', 'Open ⋯ → Agents and press Sign in again.');
  }
  if (!res.ok) throw new ProviderError(`Usage API returned HTTP ${res.status}`);
  const windows = parseUsage(res.json);
  if (!windows.length) throw new ProviderError('No limit data in response');
  return {
    plan: creds.subscriptionType ? capitalize(creds.subscriptionType) : null,
    windows,
  };
}

function capitalize(s) {
  return String(s).charAt(0).toUpperCase() + String(s).slice(1);
}

module.exports = { id: 'claude', name: 'Claude', fetch: fetchClaude, parseUsage };
