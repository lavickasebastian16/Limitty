'use strict';

const test = require('node:test');
const assert = require('node:assert');
const claude = require('../src/providers/claude');
const codex = require('../src/providers/codex');
const ag = require('../src/providers/antigravity');
const { renderAll, fmtUntil } = require('../src/renderer/render');

test('claude: parses five_hour / seven_day windows', () => {
  const w = claude.parseUsage({
    five_hour: { utilization: 42, resets_at: '2026-11-10T15:00:00Z' },
    seven_day: { utilization: 13.5, resets_at: '2026-11-14T00:00:00Z' },
    seven_day_opus: null,
    extra_usage: { is_enabled: false },
  });
  assert.deepStrictEqual(w.map((x) => [x.label, x.usedPercent]), [['Session (5h)', 42], ['Weekly', 13.5]]);
  assert.strictEqual(w[0].resetsAt, Date.parse('2026-11-10T15:00:00Z'));
});

test('codex: parses rate_limit windows', () => {
  const r = codex.parseUsage({
    plan_type: 'plus',
    rate_limit: {
      primary_window: { used_percent: 7, limit_window_seconds: 18000, reset_at: 1762800000 },
      secondary_window: { used_percent: 61, limit_window_seconds: 604800, reset_after_seconds: 3600 },
    },
  });
  assert.strictEqual(r.plan, 'Plus');
  assert.deepStrictEqual(r.windows.map((x) => [x.label, x.usedPercent]), [['5h window', 7], ['Weekly', 61]]);
  assert.strictEqual(r.windows[0].resetsAt, 1762800000 * 1000);
  assert.ok(r.windows[1].resetsAt > Date.now());
});

test('antigravity: parses legacy GetUserStatus clientModelConfigs', () => {
  const r = ag.parseQuota({
    userStatus: {
      planStatus: { planInfo: { planName: 'Pro' } },
      cascadeModelConfigData: {
        clientModelConfigs: [
          { label: 'Gemini 3 Pro', quotaInfo: { remainingFraction: 0.75, resetTime: '2026-11-10T18:00:00Z' } },
          { label: 'Claude Sonnet 4.5', quotaInfo: { resetTime: '2026-11-10T19:00:00Z' } },
        ],
      },
    },
  });
  assert.strictEqual(r.plan, 'Pro');
  assert.deepStrictEqual(r.windows.map((x) => [x.label, x.usedPercent]), [['Gemini 3 Pro', 25], ['Claude Sonnet 4.5', 100]]);
});

test('antigravity: parses summary groups/buckets', () => {
  const r = ag.parseQuota({
    response: {
      groups: [{
        displayName: 'Gemini',
        buckets: [{ bucketId: 'g', displayName: '5h', remaining: { remainingFraction: 0.4, resetTime: '2026-11-10T18:00:00Z' } }],
      }],
    },
  });
  assert.deepStrictEqual(r.windows.map((x) => [x.label, Math.round(x.usedPercent)]), [['Gemini · 5h', 60]]);
});

test('antigravity: condenses many models into families', () => {
  const models = ['Gemini 3 Pro (High)', 'Gemini 3 Pro (Low)', 'Gemini 3 Flash', 'Claude Sonnet 4.5', 'Claude Opus 4.5', 'GPT-OSS 120B']
    .map((label, i) => ({ label, quotaInfo: { remainingFraction: 1 - i / 10, resetTime: '2026-11-10T18:00:00Z' } }));
  const r = ag.parseQuota({ clientModelConfigs: models });
  assert.deepStrictEqual(r.windows.map((x) => x.label).sort(), ['Claude + GPT', 'Gemini Flash', 'Gemini Pro']);
  assert.strictEqual(Math.round(r.windows.find((x) => x.label === 'Claude + GPT').usedPercent), 50);
});

test('antigravity: finds language server flags', () => {
  const s = ag.findServers([
    { pid: 10, cmd: '/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm --csrf_token abc123 --extension_server_port 53410 --app_data_dir antigravity' },
    { pid: 11, cmd: '/usr/bin/vim' },
  ]);
  assert.deepStrictEqual(s, [{ pid: 10, csrf: 'abc123', extPort: 53410, extCsrf: null }]);
});

test('render: shows errors and bars', () => {
  const html = renderAll([
    { id: 'claude', name: 'Claude', ok: true, plan: 'Max', windows: [{ label: 'Session (5h)', usedPercent: 90, resetsAt: Date.now() + 3 * 3600e3 }] },
    { id: 'codex', name: 'Codex', ok: false, error: 'Not signed in', hint: 'Run `codex login`' },
  ]);
  assert.match(html, /fill bad/);
  assert.match(html, /Not signed in/);
  assert.strictEqual(fmtUntil(Date.now() + 90 * 60e3 + 500), 'resets in 1h 30m');
});
