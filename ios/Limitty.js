// Limitty — Claude + Codex usage limits as an iPhone home/lock-screen widget.
// Runs in the free "Scriptable" app (App Store). Setup: see ios/README.md.
//
// Run it inside Scriptable to sign in / preview. Add a Scriptable widget to
// your home screen and pick "Limitty" as the script.
//
// Widget parameter (optional, long-press widget → Edit Widget → Parameter):
//   "claude"  only show Claude
//   "codex"   only show Codex

// ───────────────────────── settings ─────────────────────────
const REFRESH_MINUTES = 15; // iOS decides the real schedule; this is a hint
const KEY_CLAUDE = 'limitty.claude.sessionKey';
const KEY_CODEX = 'limitty.codex.auth';
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1';

const COLORS = {
  bg: Color.dynamic(new Color('#f7f7f9'), new Color('#161619')),
  text: Color.dynamic(new Color('#1b1b1f'), new Color('#ececf1')),
  muted: Color.dynamic(new Color('#6b6b76'), new Color('#9a9aa6')),
  track: Color.dynamic(new Color('#000000', 0.08), new Color('#ffffff', 0.1)),
  ok: new Color('#2fb57a'),
  warn: new Color('#f2b33d'),
  bad: new Color('#f2555a'),
  claude: new Color('#d97757'),
  codex: Color.dynamic(new Color('#1b1b1f'), new Color('#e8e8ea')),
};

// ───────────────────────── helpers ─────────────────────────
class LimitError extends Error {
  constructor(message, hint) { super(message); this.hint = hint; }
}

function toMs(v) {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return v < 1e12 ? v * 1000 : v;
  if (/^\d+(\.\d+)?$/.test(String(v))) return toMs(Number(v));
  const t = Date.parse(v);
  return Number.isNaN(t) ? null : t;
}

function clampPct(n) {
  if (n == null || Number.isNaN(Number(n))) return null;
  return Math.max(0, Math.min(100, Number(n)));
}

function windowLabel(seconds) {
  if (!seconds) return 'Limit';
  const h = seconds / 3600;
  if (h <= 24 && Math.abs(h - Math.round(h)) < 0.01) return `${Math.round(h)}h`;
  if (Math.abs(seconds / 86400 - 7) < 0.1) return 'Weekly';
  return `${Math.round(seconds / 86400)}d`;
}

function fmtUntil(ms, now = Date.now()) {
  if (!ms) return '';
  const s = Math.max(0, Math.round((ms - now) / 1000));
  const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
  if (d) return `${d}d ${h}h`;
  if (h) return `${h}h ${m}m`;
  return `${Math.max(1, m)}m`;
}

function levelColor(pct) {
  if (pct >= 85) return COLORS.bad;
  if (pct >= 60) return COLORS.warn;
  return COLORS.ok;
}

function decodeJwt(token) {
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const pad = part + '='.repeat((4 - (part.length % 4)) % 4);
    return JSON.parse(Data.fromBase64String(pad).toRawString());
  } catch { return null; }
}

async function http(url, headers) {
  const req = new Request(url);
  req.headers = { 'User-Agent': UA, Accept: 'application/json', ...headers };
  req.timeoutInterval = 20;
  const text = await req.loadString();
  const status = req.response?.statusCode ?? 0;
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON (e.g. Cloudflare page) */ }
  return { status, json };
}

// ───────────────────────── Claude ─────────────────────────
// Uses your claude.ai web login (the `sessionKey` cookie, valid for weeks).

const CLAUDE_LABELS = {
  five_hour: 'Session',
  seven_day: 'Weekly',
  seven_day_opus: 'Opus wk',
  seven_day_sonnet: 'Sonnet wk',
};

function parseClaudeUsage(json) {
  const windows = [];
  for (const [key, val] of Object.entries(json || {})) {
    if (!val || typeof val !== 'object' || val.utilization == null) continue;
    windows.push({ id: key, label: CLAUDE_LABELS[key] || key.replace(/_/g, ' '), usedPercent: clampPct(val.utilization), resetsAt: toMs(val.resets_at) });
  }
  const order = Object.keys(CLAUDE_LABELS);
  windows.sort((a, b) => (order.indexOf(a.id) + 1 || 99) - (order.indexOf(b.id) + 1 || 99));
  return windows;
}

function claudePlan(org) {
  const caps = org?.capabilities || [];
  if (caps.includes('claude_max')) return 'Max';
  if (caps.includes('claude_pro')) return 'Pro';
  if (caps.includes('raven')) return 'Team';
  return null;
}

function claudeCookie(raw) {
  const v = raw.trim();
  // Accept either the bare value or a pasted "sessionKey=..." / full cookie string.
  return v.includes('sessionKey=') ? v : `sessionKey=${v}`;
}

async function fetchClaude() {
  if (!Keychain.contains(KEY_CLAUDE)) throw new LimitError('Not signed in', 'Run Limitty in Scriptable → Claude');
  const headers = { Cookie: claudeCookie(Keychain.get(KEY_CLAUDE)) };

  const orgs = await http('https://claude.ai/api/organizations', headers);
  if (orgs.status === 401 || orgs.status === 403) throw new LimitError('Login expired', 'Paste a new sessionKey');
  if (!Array.isArray(orgs.json) || !orgs.json.length) throw new LimitError(`claude.ai error ${orgs.status}`);
  const org = orgs.json.find((o) => (o.capabilities || []).includes('chat')) || orgs.json[0];

  const usage = await http(`https://claude.ai/api/organizations/${org.uuid}/usage`, headers);
  if (usage.status === 401 || usage.status === 403) throw new LimitError('Login expired', 'Paste a new sessionKey');
  const windows = parseClaudeUsage(usage.json);
  if (!windows.length) throw new LimitError(`No usage data (${usage.status})`);
  return { plan: claudePlan(org), windows };
}

// ───────────────────────── Codex ─────────────────────────
// Accepts either:
//   • your chatgpt.com web login cookie (__Secure-next-auth.session-token),
//     from which a fresh access token is fetched each time (lasts weeks), or
//   • a Codex/ChatGPT access token (eyJ…, 3 parts) — expires after ~10 days.

function parseCodexUsage(json, now = Date.now()) {
  const rl = json?.rate_limit || {};
  const win = (id, w) => {
    if (!w) return null;
    let resetsAt = toMs(w.reset_at);
    if (!resetsAt && w.reset_after_seconds != null) resetsAt = now + w.reset_after_seconds * 1000;
    return { id, label: windowLabel(w.limit_window_seconds), usedPercent: clampPct(w.used_percent), resetsAt };
  };
  const windows = [win('primary', rl.primary_window), win('secondary', rl.secondary_window)].filter(Boolean);
  for (const w of windows) if (w.label.endsWith('h')) w.label = 'Session';
  const plan = json?.plan_type ? String(json.plan_type).replace(/^\w/, (c) => c.toUpperCase()) : null;
  return { plan, windows };
}

function classifyCodexAuth(raw) {
  const v = raw.trim();
  if (v.includes('next-auth.session-token')) return { kind: 'cookie', cookie: v };
  const parts = v.split('.');
  if (v.startsWith('eyJ') && parts.length === 3) return { kind: 'token', token: v };
  if (parts.length === 5) return { kind: 'cookie', cookie: `__Secure-next-auth.session-token=${v}` };
  return { kind: 'unknown' };
}

async function codexAccessToken() {
  if (!Keychain.contains(KEY_CODEX)) throw new LimitError('Not signed in', 'Run Limitty in Scriptable → Codex');
  const auth = classifyCodexAuth(Keychain.get(KEY_CODEX));
  if (auth.kind === 'token') return auth.token;
  if (auth.kind === 'cookie') {
    const res = await http('https://chatgpt.com/api/auth/session', { Cookie: auth.cookie });
    if (res.json?.accessToken) return res.json.accessToken;
    if (res.status === 403) throw new LimitError('Blocked by chatgpt.com', 'Paste an access token instead');
    throw new LimitError('Login expired', 'Paste a new ChatGPT cookie');
  }
  throw new LimitError('Unrecognised Codex login', 'Paste the cookie or access token again');
}

async function fetchCodex() {
  const token = await codexAccessToken();
  const claims = decodeJwt(token);
  if (claims?.exp && claims.exp * 1000 < Date.now()) throw new LimitError('Token expired', 'Paste a new Codex token');
  const headers = { Authorization: `Bearer ${token}`, 'User-Agent': 'codex-cli' };
  const accountId = claims?.['https://api.openai.com/auth']?.chatgpt_account_id;
  if (accountId) headers['ChatGPT-Account-Id'] = accountId;

  const res = await http('https://chatgpt.com/backend-api/wham/usage', headers);
  if (res.status === 401 || res.status === 403) throw new LimitError('Login expired', 'Paste a new Codex login');
  const parsed = parseCodexUsage(res.json);
  if (!parsed.windows.length) throw new LimitError(`No usage data (${res.status})`);
  return parsed;
}

// ───────────────────────── data + cache ─────────────────────────

const PROVIDERS = [
  { id: 'claude', name: 'Claude', color: COLORS.claude, fetch: fetchClaude, key: KEY_CLAUDE },
  { id: 'codex', name: 'Codex', color: COLORS.codex, fetch: fetchCodex, key: KEY_CODEX },
];

function cachePath() {
  const fm = FileManager.local();
  return fm.joinPath(fm.documentsDirectory(), 'limitty-cache.json');
}
function readCache() {
  try { return JSON.parse(FileManager.local().readString(cachePath())) || {}; } catch { return {}; }
}
function writeCache(c) {
  try { FileManager.local().writeString(cachePath(), JSON.stringify(c)); } catch { /* ignore */ }
}

async function loadAll(only) {
  const cache = readCache();
  const list = PROVIDERS.filter((p) => !only || p.id === only);
  const results = await Promise.all(list.map(async (p) => {
    const base = { id: p.id, name: p.name, color: p.color };
    try {
      const data = await p.fetch();
      cache[p.id] = { ...data, fetchedAt: Date.now() };
      return { ...base, ok: true, ...data, fetchedAt: Date.now() };
    } catch (e) {
      const c = cache[p.id];
      // Network hiccup: keep showing the last good numbers (marked stale) for up to a day.
      if (c && !(e instanceof LimitError) && Date.now() - c.fetchedAt < 864e5) return { ...base, ok: true, ...c, stale: true };
      return { ...base, ok: false, error: e.message || String(e), hint: e.hint };
    }
  }));
  writeCache(cache);
  return results;
}

// ───────────────────────── drawing ─────────────────────────

function barImage(pct, width, height = 6) {
  const dc = new DrawContext();
  dc.size = new Size(width, height);
  dc.opaque = false;
  dc.respectScreenScale = true;
  const r = height / 2;
  const track = new Path();
  track.addRoundedRect(new Rect(0, 0, width, height), r, r);
  dc.addPath(track);
  dc.setFillColor(COLORS.track);
  dc.fillPath();
  const w = Math.max(pct > 0 ? height : 0, (width * Math.min(100, pct)) / 100);
  if (w > 0) {
    const fill = new Path();
    fill.addRoundedRect(new Rect(0, 0, w, height), r, r);
    dc.addPath(fill);
    dc.setFillColor(levelColor(pct));
    dc.fillPath();
  }
  return dc.getImage();
}

function addText(stack, str, size, color, bold = false) {
  const t = stack.addText(str);
  t.font = bold ? Font.semiboldSystemFont(size) : Font.systemFont(size);
  t.textColor = color;
  t.lineLimit = 1;
  return t;
}

function addProvider(parent, r, { barWidth, maxRows, compact }) {
  const box = parent.addStack();
  box.layoutVertically();

  const head = box.addStack();
  head.centerAlignContent();
  const dot = head.addText('●');
  dot.font = Font.systemFont(compact ? 8 : 9);
  dot.textColor = r.color;
  head.addSpacer(4);
  addText(head, r.name, compact ? 12 : 13, COLORS.text, true);
  if (r.plan && !compact) { head.addSpacer(5); addText(head, r.plan, 10, COLORS.muted); }
  if (r.stale) { head.addSpacer(4); addText(head, '⏱', 9, COLORS.muted); }
  box.addSpacer(compact ? 3 : 4);

  if (!r.ok) {
    addText(box, r.error, 11, COLORS.bad);
    if (r.hint) addText(box, r.hint, 9, COLORS.muted).lineLimit = 2;
    return;
  }

  for (const w of r.windows.slice(0, maxRows)) {
    const pct = Math.round(w.usedPercent ?? 0);
    const top = box.addStack();
    top.size = new Size(barWidth, 0);
    addText(top, w.label, 10.5, COLORS.text);
    top.addSpacer();
    addText(top, `${pct}%`, 10.5, COLORS.text, true);
    box.addSpacer(2);
    const img = box.addImage(barImage(pct, barWidth));
    img.imageSize = new Size(barWidth, 6);
    if (!compact && w.resetsAt) {
      box.addSpacer(1);
      addText(box, `resets in ${fmtUntil(w.resetsAt)}`, 9, COLORS.muted);
    }
    box.addSpacer(compact ? 3 : 5);
  }
}

function buildWidget(results, family = 'medium') {
  const w = new ListWidget();
  w.refreshAfterDate = new Date(Date.now() + REFRESH_MINUTES * 60e3);

  // Lock screen widgets: plain text, tinted by iOS.
  if (family === 'accessoryInline') {
    w.addText(results.map((r) => (r.ok ? `${r.name[0]} ${Math.round(r.windows[0]?.usedPercent ?? 0)}%` : `${r.name[0]} –`)).join('  '));
    return w;
  }
  if (family === 'accessoryRectangular' || family === 'accessoryCircular') {
    for (const r of results) {
      const line = r.ok ? `${r.name} ${r.windows.slice(0, 2).map((x) => `${Math.round(x.usedPercent ?? 0)}%`).join(' · ')}` : `${r.name} –`;
      const t = w.addText(line);
      t.font = Font.semiboldSystemFont(family === 'accessoryCircular' ? 10 : 13);
      t.lineLimit = 1;
    }
    return w;
  }

  w.backgroundColor = COLORS.bg;
  w.setPadding(14, 14, 12, 14);

  if (family === 'small') {
    for (const [i, r] of results.entries()) {
      if (i) w.addSpacer(6);
      addProvider(w, r, { barWidth: 128, maxRows: 2, compact: true });
    }
    w.addSpacer();
    return w;
  }

  if (family === 'medium' && results.length > 1) {
    const row = w.addStack();
    row.topAlignContent();
    for (const [i, r] of results.entries()) {
      if (i) row.addSpacer(16);
      addProvider(row, r, { barWidth: 130, maxRows: 3, compact: false });
    }
    w.addSpacer();
  } else {
    for (const [i, r] of results.entries()) {
      if (i) w.addSpacer(8);
      addProvider(w, r, { barWidth: family === 'medium' ? 290 : 300, maxRows: 4, compact: false });
    }
    w.addSpacer();
  }

  const foot = w.addStack();
  const df = new DateFormatter();
  df.useShortTimeStyle();
  addText(foot, `Limitty · updated ${df.string(new Date())}`, 9, COLORS.muted);
  return w;
}

// ───────────────────────── in-app setup ─────────────────────────

async function promptSecret(title, message, key) {
  const a = new Alert();
  a.title = title;
  a.message = message;
  const clip = Pasteboard.pasteString();
  a.addSecureTextField('Paste here', '');
  a.addAction('Save');
  if (clip) a.addAction('Use clipboard');
  if (Keychain.contains(key)) a.addDestructiveAction('Remove saved login');
  a.addCancelAction('Cancel');
  const i = await a.presentAlert();
  if (i === -1) return;
  const actions = ['save', ...(clip ? ['clip'] : []), ...(Keychain.contains(key) ? ['remove'] : [])];
  const act = actions[i];
  if (act === 'remove') { Keychain.remove(key); return; }
  const value = (act === 'clip' ? clip : a.textFieldValue(0) || '').trim();
  if (value) Keychain.set(key, value);
}

async function setupMenu() {
  for (;;) {
    const a = new Alert();
    a.title = 'Limitty';
    a.message = 'Claude & Codex limits on your home screen.\nSet up your logins, then add a Scriptable widget and choose this script.';
    const status = (k) => (Keychain.contains(k) ? '✓' : '—');
    a.addAction('Preview widget');
    a.addAction(`Claude login ${status(KEY_CLAUDE)}`);
    a.addAction(`Codex login ${status(KEY_CODEX)}`);
    a.addCancelAction('Done');
    const i = await a.presentSheet();
    if (i === -1) return;
    if (i === 0) {
      const w = buildWidget(await loadAll(), 'medium');
      await w.presentMedium();
    } else if (i === 1) {
      await promptSecret('Claude login',
        'Paste your claude.ai "sessionKey" cookie (starts with sk-ant-sid…). See ios/README.md for how to copy it. It is stored in the iOS Keychain.',
        KEY_CLAUDE);
    } else if (i === 2) {
      await promptSecret('Codex login',
        'Paste EITHER your chatgpt.com "__Secure-next-auth.session-token" cookie (lasts weeks) OR the access_token from ~/.codex/auth.json (lasts ~10 days). Stored in the iOS Keychain.',
        KEY_CODEX);
    }
  }
}

// ───────────────────────── entry ─────────────────────────

async function main() {
  const param = (args.widgetParameter || '').trim().toLowerCase();
  const only = ['claude', 'codex'].includes(param) ? param : null;
  if (config.runsInWidget) {
    Script.setWidget(buildWidget(await loadAll(only), config.widgetFamily));
  } else {
    await setupMenu();
  }
  Script.complete();
}

if (typeof LIMITTY_TEST === 'undefined') {
  await main();
} else {
  module.exports = { parseClaudeUsage, parseCodexUsage, classifyCodexAuth, fmtUntil, loadAll, buildWidget, main };
}
