#!/usr/bin/env node
'use strict';

// Limitty PC companion: tells your iPhone whether Claude Code, Codex and
// Antigravity (agy) are working, need your attention, or are idle.
//
//   npm run agent:setup     sign in with GitHub and install the hooks
//                           (--qr: pair with a QR code instead, no GitHub)
//   npm run agent           run the relay (setup can make it start at login)
//
//   node src/agents/cli.js status | pair | test | uninstall

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const config = require('./config');
const hooks = require('./hooks');

const [, , cmd, ...args] = process.argv;

async function main() {
  switch (cmd) {
    case 'hook': return hook(args);
    case 'setup': return setup(args);
    case 'run': return run();
    case 'status': return status();
    case 'pair': return pair(config.ensure());
    case 'logout': require('./connect').disconnect(); console.log('Signed out of GitHub. Run setup to connect again.'); return;
    case 'test': return test();
    case 'uninstall': return uninstall();
    default:
      console.log('Usage: limitty-agent <setup [--qr] [--relogin] [--no-autostart]|run|status|pair|test|logout|uninstall>');
      process.exitCode = cmd ? 1 : 0;
  }
}

// ───────────── hook: called by the agents; must be fast and silent ─────────────

async function hook([agent, event]) {
  try {
    let payload = {};
    if (agent === 'codex') {
      // Codex passes one JSON argument (after our marker).
      const json = process.argv.slice(2).reverse().find((a) => a.startsWith('{'));
      payload = json ? JSON.parse(json) : {};
    } else {
      const text = await readStdin(1500);
      payload = text.trim() ? JSON.parse(text) : {};
    }
    const ev = normalize(agent, event, payload);
    if (!ev) return;
    fs.mkdirSync(config.FILES.dir, { recursive: true });
    fs.appendFileSync(config.FILES.events, `${JSON.stringify(ev)}\n`);
  } catch {
    // Never break the agent because of Limitty.
  }
}

function normalize(agent, event, p) {
  const t = Date.now();
  if (agent === 'claude') {
    return {
      t, agent, event: p.hook_event_name || event, session: p.session_id, cwd: p.cwd,
      detail: { tool: p.tool_name, type: p.notification_type, message: p.message },
    };
  }
  if (agent === 'agy') {
    return {
      t, agent, event, session: p.conversationId || p.conversation_id || p.sessionId, cwd: p.cwd || p.workspacePath || process.cwd(),
      detail: { tool: p.toolCall?.name || p.tool_name, fullyIdle: p.fullyIdle },
    };
  }
  if (agent === 'codex') {
    return { t, agent, event: p.type || event, session: p['thread-id'] || p.thread_id, cwd: p.cwd, detail: {} };
  }
  return null;
}

function readStdin(timeoutMs) {
  return new Promise((resolve) => {
    if (process.stdin.isTTY) return resolve('');
    let data = '';
    const done = () => resolve(data);
    const timer = setTimeout(done, timeoutMs);
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { data += c; });
    process.stdin.on('end', () => { clearTimeout(timer); done(); });
    process.stdin.on('error', () => { clearTimeout(timer); done(); });
  });
}

// ───────────── setup ─────────────

async function setup(argv) {
  console.log('\nLimitty agent setup\n');
  const report = ([name, ok, msg]) => console.log(`  ${ok ? '✓' : '✗'} ${name}: ${msg}`);

  if (argv.includes('--qr')) {
    // Older pairing: QR code + encrypted ntfy relay, no GitHub account.
    const cfg = config.ensure();
    require('./connect').installHooks().forEach(report);
    if (!argv.includes('--no-autostart')) startAtLogin(report);
    console.log('\nRestart any running Claude Code / Codex / agy sessions so they pick up the hooks.\n');
    await pair(cfg);
    return;
  }

  const { connect } = require('./connect');
  try {
    const { login, results } = await connect({
      forceLogin: argv.includes('--relogin'),
      onCode: ({ userCode, verificationUri }) => {
        console.log('Sign in with GitHub so your PC and iPhone can find each other:');
        console.log(`  1. Open ${verificationUri}`);
        console.log(`  2. Enter the code  ${userCode}\n`);
        openBrowser(verificationUri);
      },
    });
    console.log(`  ✓ Signed in to GitHub as @${login}`);
    results.forEach(report);
  } catch (e) {
    console.log(`  ✗ ${e.message}`);
    process.exitCode = 1;
    return;
  }
  if (!argv.includes('--no-autostart')) startAtLogin(report);
  console.log('\nDone. Restart any running Claude Code / Codex / agy sessions so they pick up the hooks.');
  console.log('On your iPhone: Limitty → Agents on your PC → Sign in with GitHub (same account).\n');
}

function startAtLogin(report) {
  try { report(['Start at login', true, autostart(true)]); } catch (e) { report(['Start at login', false, e.message]); }
}

function openBrowser(url) {
  try {
    const { spawn } = require('child_process');
    const [cmd, args] = process.platform === 'win32' ? ['cmd', ['/c', 'start', '', url]]
      : process.platform === 'darwin' ? ['open', [url]] : ['xdg-open', [url]];
    spawn(cmd, args, { stdio: 'ignore', detached: true }).on('error', () => {}).unref();
  } catch { /* the URL is printed anyway */ }
}

async function pair(cfg) {
  const link = config.pairingLink(cfg);
  console.log('Pair your iPhone: scan this with the Camera app (it opens Limitty),');
  console.log('or copy the link into Limitty → Agents → Pair with PC.\n');
  try {
    require('qrcode-terminal').generate(link, { small: true }, (qr) => console.log(qr));
  } catch {
    console.log('(Run `npm install` to show a QR code here.)');
  }
  console.log(`${link}\n`);
  console.log('Push alerts: install the free "ntfy" app on your iPhone and subscribe to');
  console.log(`  server ${cfg.server}   topic ${config.alertsTopic(cfg)}\n`);
  console.log('Keep the link and topic private: anyone with them can see or send your alerts.');
}

// ───────────── run / status / test / uninstall ─────────────

function run() {
  const cfg = config.load();
  if (!cfg) {
    console.error('Not set up yet. Run: npm run agent:setup');
    process.exitCode = 1;
    return;
  }
  const { Daemon } = require('./daemon');
  const log = (m) => {
    const line = `${new Date().toISOString()} ${m}`;
    console.log(line);
    try { fs.appendFileSync(config.FILES.log, `${line}\n`); } catch { /* ignore */ }
  };
  const d = new Daemon(cfg, { log });
  if (!d.start()) { process.exitCode = 0; return; }
  const stop = () => { d.stop(); process.exit(0); };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);
}

function status() {
  let saved = {};
  try { saved = JSON.parse(fs.readFileSync(config.FILES.state, 'utf8')); } catch { /* none */ }
  const sessions = Object.values(saved.sessions || {});
  if (!sessions.length) console.log('No agent sessions seen yet.');
  const icon = { working: '●', attention: '!', waiting: '?', idle: '○' };
  for (const s of sessions) {
    console.log(`${icon[s.state] || '-'} ${s.agent.padEnd(7)} ${String(s.project || '').padEnd(24)} ${s.state.padEnd(9)} ${s.detail}`);
  }
  if (saved.budget) console.log(`\nntfy messages used today: ${saved.budget.used}/250`);
}

async function test() {
  const cfg = config.load();
  if (!cfg) { console.error('Not set up yet. Run: npm run agent:setup'); return; }
  const res = await fetch(`${cfg.server}/${config.alertsTopic(cfg)}`, {
    method: 'POST',
    body: 'If you can read this on your iPhone, alerts work.',
    headers: { Title: 'Limitty test alert', Tags: 'tada', ...(cfg.token ? { Authorization: `Bearer ${cfg.token}` } : {}) },
  });
  console.log(res.ok ? 'Sent a test alert.' : `ntfy returned HTTP ${res.status}`);
}

function uninstall() {
  for (const [name, fn] of [['Claude Code', hooks.uninstallClaude], ['Antigravity', hooks.uninstallAgy], ['Codex', hooks.uninstallCodex]]) {
    try { const f = fn(); console.log(`  ✓ ${name}: ${f ? `removed from ${f}` : 'nothing to remove'}`); } catch (e) { console.log(`  ✗ ${name}: ${e.message}`); }
  }
  try { console.log(`  ✓ Start at login: ${autostart(false)}`); } catch (e) { console.log(`  ✗ Start at login: ${e.message}`); }
  console.log(`\nYour pairing key is kept in ${config.FILES.config}. Delete that folder to forget it.`);
}

// ───────────── start at login ─────────────

function autostart(enable) {
  const node = process.execPath;
  const cli = __filename;
  if (process.platform === 'win32') {
    const dir = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
    const file = path.join(dir, 'Limitty Agent.vbs');
    if (!enable) { fs.rmSync(file, { force: true }); return 'removed'; }
    fs.writeFileSync(file, `CreateObject("WScript.Shell").Run """${node}"" ""${cli}"" run", 0, False\r\n`);
    try { execFileSync('wscript.exe', [file]); } catch { /* starts at next login */ }
    return `${file}`;
  }
  if (process.platform === 'darwin') {
    const file = path.join(os.homedir(), 'Library', 'LaunchAgents', 'com.limitty.agent.plist');
    try { execFileSync('launchctl', ['unload', file], { stdio: 'ignore' }); } catch { /* not loaded */ }
    if (!enable) { fs.rmSync(file, { force: true }); return 'removed'; }
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.limitty.agent</string>
  <key>ProgramArguments</key><array><string>${node}</string><string>${cli}</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${config.FILES.log}</string>
  <key>StandardErrorPath</key><string>${config.FILES.log}</string>
</dict></plist>
`);
    execFileSync('launchctl', ['load', file]);
    return file;
  }
  // Linux (and WSL with systemd)
  const file = path.join(os.homedir(), '.config', 'systemd', 'user', 'limitty-agent.service');
  if (!enable) {
    try { execFileSync('systemctl', ['--user', 'disable', '--now', 'limitty-agent'], { stdio: 'ignore' }); } catch { /* ignore */ }
    fs.rmSync(file, { force: true });
    return 'removed';
  }
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `[Unit]\nDescription=Limitty agent status relay\n\n[Service]\nExecStart="${node}" "${cli}" run\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n`);
  try {
    execFileSync('systemctl', ['--user', 'daemon-reload'], { stdio: 'ignore' });
    execFileSync('systemctl', ['--user', 'enable', '--now', 'limitty-agent'], { stdio: 'ignore' });
    return `${file} (systemd user service)`;
  } catch {
    throw new Error('systemd isn\'t available here (common in WSL). Keep `npm run agent` running in a terminal instead.');
  }
}

if (require.main === module) {
  main().catch((e) => {
    if (cmd !== 'hook') { console.error(e.message); process.exitCode = 1; }
  });
}

module.exports = { normalize };
