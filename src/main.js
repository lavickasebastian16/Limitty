'use strict';

const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen, dialog, shell, clipboard } = require('electron');
const path = require('path');
const fs = require('fs');
const { fetchAll } = require('./providers');
const tools = require('./tools');

// The agents' installers put them in ~/.local/bin, which apps started from a launcher often lack.
tools.ensurePath();

const DEFAULTS = {
  x: null,
  y: null,
  alwaysOnTop: true,
  refreshMinutes: 5,
  providers: ['claude', 'codex', 'antigravity'],
};

let win = null;
let tray = null;
let timer = null;
let lastResults = [];
let config = { ...DEFAULTS };
const VERSION = (() => { try { return require('../limitty.json').version; } catch { return app.getVersion(); } })();
let host = null; // runs the Company + phone relay (or { owner: false } if another process does)
let companyWin = null;
let agentsWin = null;
let settingsWin = null;

const configPath = () => path.join(app.getPath('userData'), 'config.json');

function loadConfig() {
  try { config = { ...DEFAULTS, ...JSON.parse(fs.readFileSync(configPath(), 'utf8')) }; } catch { config = { ...DEFAULTS }; }
}
function saveConfig() {
  try {
    fs.mkdirSync(path.dirname(configPath()), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(config, null, 2));
  } catch { /* ignore */ }
}

function createWindow() {
  const { workArea } = screen.getPrimaryDisplay();
  const width = 300;
  const x = config.x ?? workArea.x + workArea.width - width - 16;
  const y = config.y ?? workArea.y + 16;

  win = new BrowserWindow({
    title: 'Limitty', // Hyprland window rules match this title
    width,
    height: 360,
    x,
    y,
    frame: false,
    transparent: true,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    alwaysOnTop: config.alwaysOnTop,
    hasShadow: false,
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.once('ready-to-show', () => win.showInactive());
  win.on('moved', () => {
    const [nx, ny] = win.getPosition();
    config.x = nx;
    config.y = ny;
    saveConfig();
  });
  win.on('closed', () => { win = null; });
}

function trayIcon() {
  const img = nativeImage.createFromPath(path.join(__dirname, '..', 'assets', 'tray.png'));
  if (process.platform === 'darwin') img.setTemplateImage(true);
  return img;
}

function buildTrayMenu() {
  const summary = lastResults.map((r) => {
    if (!r.ok) return { label: `${r.name}: ${r.error}`, enabled: false };
    const top = Math.max(...r.windows.map((w) => w.usedPercent ?? 0));
    return { label: `${r.name}: ${Math.round(top)}% used`, enabled: false };
  });
  return Menu.buildFromTemplate([
    { label: `Limitty ${VERSION}`, enabled: false },
    { type: 'separator' },
    ...summary,
    ...(summary.length ? [{ type: 'separator' }] : []),
    { label: 'Type a task for your agents…', click: focusAsk },
    { label: 'Company: tasks and progress…', click: openCompany },
    { type: 'separator' },
    { label: win?.isVisible() ? 'Hide widget' : 'Show widget', click: toggleWindow },
    { label: 'Refresh now', click: refresh },
    { label: 'Reset position', click: () => { config.x = null; config.y = null; saveConfig(); placeDefault(); } },
    { type: 'separator' },
    { label: 'Agents: install and sign in…', click: openAgents },
    agentsMenuItem(),
    { label: 'Settings…', click: openSettings },
    { type: 'separator' },
    { label: 'Quit Limitty', click: () => app.quit() },
  ]);
}

// ───── Agent status on your iPhone ─────

function agentConfig() {
  try { return require('./agents/config').load(); } catch { return null; }
}

/** Runs the Company and the phone relay, unless the background agent already does. */
function startHost() {
  try {
    host = require('./company/host').startHost({ log: (m) => console.log(`[agent] ${m}`) });
    host.company?.on('change', pushCompanyState);
  } catch (e) {
    console.error('[agent]', e.message);
    host = { owner: false };
  }
}

function agentsMenuItem() {
  const gh = agentConfig()?.github;
  if (gh?.gistId) {
    return {
      label: `iPhone: linked as @${gh.login}`,
      submenu: [
        { label: 'Reinstall agent hooks', click: () => { require('./agents/connect').installHooks(); dialog.showMessageBox({ message: 'Agent hooks reinstalled. Restart open agent sessions to pick them up.' }); } },
        { label: 'Unlink', click: () => { require('./agents/connect').disconnect(); host?.detachRelay?.(); updateTray(); } },
      ],
    };
  }
  return { label: 'Link iPhone…', click: connectAgents };
}

let connecting = false;
async function connectAgents() {
  if (connecting) return;
  connecting = true;
  try {
    const { connect } = require('./agents/connect');
    const { login, results } = await connect({
      onCode: ({ userCode, verificationUri }) => {
        clipboard.writeText(userCode);
        shell.openExternal(verificationUri);
        // Not awaited: sign-in continues in the background while this is shown.
        dialog.showMessageBox({
          type: 'info',
          message: `Sign in with GitHub\n\nEnter this code on the GitHub page that just opened:\n\n${userCode}`,
          detail: 'It is already copied to your clipboard. Limitty connects as soon as you approve it.',
        });
      },
    });
    setStartAtLogin(true); // keep the relay running after restarts
    host?.attachRelay?.();
    const failed = results.filter(([, ok]) => !ok).map(([name, , msg]) => `${name}: ${msg}`);
    dialog.showMessageBox({
      type: failed.length ? 'warning' : 'info',
      message: `Connected as @${login}`,
      detail: `${failed.length ? `Some hooks need attention:\n${failed.join('\n')}\n\n` : ''}`
        + 'Restart any open Claude Code, Codex or agy sessions so they pick up the hooks.\n\n'
        + 'On your iPhone: Limitty → Agents on your PC → Sign in with GitHub (same account).\n'
        + 'Limitty now starts at login so the status stays up to date.',
    });
  } catch (e) {
    dialog.showMessageBox({ type: 'error', message: 'Couldn\'t connect', detail: e.message });
  } finally {
    connecting = false;
    updateTray();
  }
}

// ───── Agents window: choose, install and sign in ─────

const PROVIDER_OF = { claude: 'claude', codex: 'codex', agy: 'antigravity' };
const agentJobs = {}; // id → { job: 'queued'|'installing'|'signin', error, note, url, codeBox }
const signIns = {}; // id → { sendCode, cancel } while you sign in
let installing = false;
// The one-click setup: each step's state ('todo'|'running'|'done'|'skipped'|'failed') and a note.
const SETUP_STEPS = [
  ['install', 'Install the agents'],
  ['signin', 'Sign in to each agent'],
  ['phone', 'Link your iPhone (GitHub)'],
  ['hooks', 'Live agent status (widget and phone)'],
  ['autostart', 'Start Limitty at login'],
];
let setup = null; // { steps: { id: { state, note } }, code, finished }

function openAgents() {
  if (agentsWin) { agentsWin.show(); agentsWin.focus(); return; }
  agentsWin = new BrowserWindow({
    width: 640,
    height: 720,
    minWidth: 460,
    minHeight: 420,
    title: 'Limitty Agents',
    webPreferences: { preload: path.join(__dirname, 'agents-window', 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  agentsWin.setMenuBarVisibility(false);
  agentsWin.loadFile(path.join(__dirname, 'agents-window', 'index.html'));
  agentsWin.on('closed', () => { agentsWin = null; });
}

function agentsState() {
  const list = tools.status().map((a) => {
    const j = agentJobs[a.id] || {};
    return { ...a, job: j.job || null, error: j.error || null, note: j.note || null, url: j.url || null, codeBox: !!j.codeBox };
  });
  const cfg = agentConfig();
  return {
    agents: list,
    busy: installing,
    setup: setup && {
      steps: SETUP_STEPS.map(([id, label]) => ({ id, label, ...(setup.steps[id] || { state: 'todo' }) })),
      code: setup.code,
      finished: setup.finished,
    },
    phoneLinked: !!cfg?.github?.token,
    githubLogin: cfg?.github?.login || null,
    version: VERSION,
  };
}

function pushAgentsState() {
  agentsWin?.webContents.send('agents:update', agentsState());
}

/** Your choice also decides which limits the widget shows and who the Company can use. */
function applyChoice(ids) {
  const chosen = tools.choose(ids);
  config.providers = chosen.map((id) => PROVIDER_OF[id]);
  saveConfig();
  require('./company/workers').isInstalled.clearCache?.();
  refresh();
  return chosen;
}

const agentLog = (line) => agentsWin?.webContents.send('agents:log', line);

async function installOne(id) {
  agentJobs[id] = { job: 'installing' };
  pushAgentsState();
  agentLog(`── Installing ${tools.TOOLS[id].name} ──`);
  const r = await tools.install(id, { onLine: agentLog }).promise;
  agentLog(r.ok ? `✓ ${tools.TOOLS[id].name} installed: ${r.path}` : `✗ ${tools.TOOLS[id].name}: ${r.error}`);
  agentJobs[id] = r.ok ? {} : { error: `Install failed: ${r.error}` };
  pushAgentsState();
  return r.ok;
}

/** Signs in through a new browser tab and waits until you're done there (or press Skip). */
async function signInOne(id) {
  const t = tools.TOOLS[id];
  agentJobs[id] = { job: 'signin', note: `${id === 'agy' ? 'Antigravity is opening its sign-in page in your browser…' : 'Opening the sign-in page in your browser…'} ${t.loginHint}`, url: null, codeBox: id !== 'codex' };
  pushAgentsState();
  const s = tools.browserLogin(id, {
    onUrl: (url, { open = true } = {}) => {
      if (open && !agentJobs[id]?.url) shell.openExternal(url); // a new tab; later links are only offered
      agentJobs[id] = { ...agentJobs[id], url, note: `A sign-in page opened in your browser. ${t.loginHint}` };
      pushAgentsState();
    },
    onLine: agentLog,
  });
  signIns[id] = s;
  const r = await s.promise;
  delete signIns[id];
  agentJobs[id] = r === 'signed-in' ? {}
    : r === 'cancelled' ? { error: 'Not signed in yet. Press Sign in when you’re ready.' }
      : { error: `Sign-in didn’t finish. ${s.output().split('\n').slice(-2).join(' ')}`.trim() };
  require('./company/workers').isInstalled.clearCache?.();
  pushAgentsState();
  setTimeout(refresh, 2000); // show the new limits
  return r;
}

function setStep(id, state, note) {
  if (!setup) return;
  setup.steps[id] = { state, note: note || null };
  pushAgentsState();
}

/** Everything, one click: install → sign in → link the phone → hooks → start at login. */
async function runSetup() {
  if (installing) return agentsState();
  installing = true;
  setup = { steps: {}, code: null, finished: false };
  const chosen = tools.hasChosen() ? tools.chosen() : applyChoice(tools.chosen());
  try {
    // 1. Install
    setStep('install', 'running');
    const missing = chosen.filter((id) => !tools.find(id));
    for (const id of missing) agentJobs[id] = { job: 'queued' };
    let failed = 0;
    for (const id of missing) if (!(await installOne(id))) failed += 1;
    require('./company/workers').isInstalled.clearCache?.();
    setStep('install', failed ? 'failed' : 'done', missing.length
      ? (failed ? `${failed} couldn't be installed; see below.` : `Installed ${missing.map((id) => tools.TOOLS[id].name).join(', ')}.`)
      : 'Already installed.');

    // 2. Sign in, one at a time
    setStep('signin', 'running');
    const needLogin = chosen.filter((id) => tools.find(id) && tools.TOOLS[id].signedIn() !== true);
    const skipped = [];
    for (const id of needLogin) {
      setStep('signin', 'running', `Waiting for you to sign in to ${tools.TOOLS[id].name} in your browser…`);
      const r = await signInOne(id);
      if (r !== 'signed-in') skipped.push(tools.TOOLS[id].name);
    }
    setStep('signin', skipped.length ? 'skipped' : 'done', skipped.length ? `Not finished: ${skipped.join(', ')}. Use Sign in next to it any time.` : 'All signed in.');

    // 3 + 4. Link the phone and install the hooks
    const cfg = agentConfig();
    if (cfg?.github?.token) {
      setStep('phone', 'done', `Linked as @${cfg.github.login}.`);
      setStep('hooks', 'running');
      const results = require('./agents/connect').installHooks();
      const bad = results.filter(([, ok]) => !ok);
      setStep('hooks', bad.length ? 'failed' : 'done', bad.length ? bad.map(([n, , m]) => `${n}: ${m}`).join(' · ') : 'Restart open agent sessions to pick them up.');
    } else {
      setStep('phone', 'running', 'Approve Limitty on the GitHub page that opened. The code is already copied.');
      try {
        const { connect } = require('./agents/connect');
        const { login, results } = await connect({
          onCode: ({ userCode, verificationUri }) => {
            clipboard.writeText(userCode);
            shell.openExternal(verificationUri);
            setup.code = { userCode, verificationUri };
            pushAgentsState();
          },
        });
        setup.code = null;
        setStep('phone', 'done', `Linked as @${login}. On your iPhone: Limitty → Sign in with GitHub (same account).`);
        const bad = results.filter(([, ok]) => !ok);
        setStep('hooks', bad.length ? 'failed' : 'done', bad.length ? bad.map(([n, , m]) => `${n}: ${m}`).join(' · ') : 'Restart open agent sessions to pick them up.');
        host?.attachRelay?.();
      } catch (e) {
        setup.code = null;
        setStep('phone', 'failed', `${e.message} You can link it later in Settings → iPhone.`);
        // Live status still works on this PC without the phone.
        const results = require('./agents/connect').installHooks();
        const bad = results.filter(([, ok]) => !ok);
        setStep('hooks', bad.length ? 'failed' : 'done', bad.length ? bad.map(([n, , m]) => `${n}: ${m}`).join(' · ') : 'Restart open agent sessions to pick them up.');
      }
    }

    // 5. Start at login, so status and alerts keep working after a restart
    try {
      setStartAtLogin(true);
      setStep('autostart', 'done');
    } catch (e) {
      setStep('autostart', 'failed', e.message);
    }
  } finally {
    installing = false;
    setup.finished = true;
    pushAgentsState();
    updateTray();
    refresh();
  }
  return agentsState();
}

function setupAgentsIpc() {
  ipcMain.handle('agents:state', () => agentsState());
  ipcMain.handle('agents:choose', (_e, ids) => { applyChoice(ids); return agentsState(); });
  ipcMain.handle('agents:setup', () => runSetup());
  ipcMain.handle('agents:install', async (_e, id) => {
    if (installing || tools.find(id)) return agentsState();
    installing = true;
    try { if (await installOne(id)) await signInOne(id); } finally { installing = false; }
    require('./company/workers').isInstalled.clearCache?.();
    return agentsState();
  });
  ipcMain.handle('agents:login', async (_e, id) => {
    if (signIns[id]) return agentsState();
    signInOne(id); // not awaited: the window follows along via updates
    return agentsState();
  });
  ipcMain.handle('agents:skip', (_e, id) => { signIns[id]?.cancel(); return agentsState(); });
  ipcMain.handle('agents:code', (_e, id, code) => { if (code) signIns[id]?.sendCode(code); return agentsState(); });
  ipcMain.on('agents:reopen', (_e, id) => { const u = agentJobs[id]?.url; if (u) shell.openExternal(u); });
  ipcMain.on('agents:done', () => {
    if (!tools.hasChosen()) applyChoice(tools.chosen());
    agentsWin?.close();
  });
  ipcMain.on('agents:open', (_e, url) => { if (/^https:\/\/github\.com\//.test(url)) shell.openExternal(url); });
  ipcMain.on('window:agents', openAgents);
}

// ───── Settings window ─────

function openSettings() {
  if (settingsWin) { settingsWin.show(); settingsWin.focus(); return; }
  settingsWin = new BrowserWindow({
    width: 660,
    height: 760,
    minWidth: 480,
    minHeight: 420,
    title: 'Limitty Settings',
    webPreferences: { preload: path.join(__dirname, 'settings-window', 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  settingsWin.setMenuBarVisibility(false);
  settingsWin.loadFile(path.join(__dirname, 'settings-window', 'index.html'));
  settingsWin.on('closed', () => { settingsWin = null; });
}

function settingsState() {
  return {
    ...require('./settings').read(),
    refreshMinutes: config.refreshMinutes,
    alwaysOnTop: config.alwaysOnTop,
    startAtLogin: getStartAtLogin(),
    agents: tools.status(),
    version: VERSION,
  };
}

function setupSettingsIpc() {
  ipcMain.handle('settings:get', () => settingsState());
  ipcMain.handle('settings:set', (_e, patch = {}) => {
    require('./settings').write(patch);
    host?.applyConfig?.(); // also picked up by the background agent if it runs the Company
    if ([1, 2, 5, 10, 15, 30].includes(patch.refreshMinutes)) { config.refreshMinutes = patch.refreshMinutes; saveConfig(); schedule(); }
    if (typeof patch.alwaysOnTop === 'boolean') { config.alwaysOnTop = patch.alwaysOnTop; saveConfig(); win?.setAlwaysOnTop(patch.alwaysOnTop); }
    if (typeof patch.startAtLogin === 'boolean') setStartAtLogin(patch.startAtLogin);
    updateTray();
    return settingsState();
  });
  ipcMain.handle('settings:detectAgy', () => require('./settings').detectAgyModels());
  ipcMain.handle('settings:linkPhone', async () => { await connectAgents(); return settingsState(); });
  ipcMain.handle('settings:unlinkPhone', () => {
    require('./agents/connect').disconnect();
    host?.detachRelay?.();
    updateTray();
    return settingsState();
  });
  ipcMain.on('window:settings', openSettings);
}

// ───── Company window ─────

function openCompany() {
  if (companyWin) { companyWin.show(); companyWin.focus(); return; }
  companyWin = new BrowserWindow({
    width: 760,
    height: 720,
    minWidth: 520,
    minHeight: 420,
    title: 'Limitty Company',
    webPreferences: { preload: path.join(__dirname, 'company-window', 'preload.js'), contextIsolation: true, nodeIntegration: false },
  });
  companyWin.setMenuBarVisibility(false);
  companyWin.loadFile(path.join(__dirname, 'company-window', 'index.html'));
  companyWin.on('closed', () => { companyWin = null; });
}

function companyState() {
  const { readState } = require('./company/host');
  if (host?.owner) {
    const c = host.company;
    return { owner: true, tasks: c.store.tasks, projects: c.projects(), team: c.team(), workers: require('./company/workers').WORKERS };
  }
  return { owner: false, ...readState(), workers: require('./company/workers').WORKERS };
}

function pushCompanyState() {
  companyWin?.webContents.send('company:update', companyState());
  win?.webContents.send('ask:info', askInfo());
}

// ───── Live agent status in the widget ─────

function agentSessions() {
  const { snapshot } = require('./agents/state');
  let sessions = host?.daemon?.sessions;
  if (!sessions) {
    // The background agent runs things: read what it saved.
    try { sessions = JSON.parse(fs.readFileSync(require('./agents/config').FILES.state, 'utf8')).sessions; } catch { sessions = {}; }
  }
  return snapshot(sessions || {}, { host: '', now: Date.now() }).sessions.filter((s) => s.state !== 'idle').slice(0, 4);
}

// ───── Prompt box in the widget ─────

function askInfo() {
  const st = companyState();
  const projects = ((st.owner ? st.projects : st.allProjects || st.projects) || []).map((p) => p.name);
  const tasks = st.tasks || [];
  const active = tasks.filter((t) => ['queued', 'planning', 'running'].includes(t.status)).length;
  // The latest task that finished in the last hour, so the widget can show it.
  const recent = tasks.find((t) => ['done', 'failed'].includes(t.status) && Date.now() - t.updatedAt < 60 * 60_000);
  return {
    projects,
    lastProject: projects.includes(config.lastProject) ? config.lastProject : projects[0] || null,
    active,
    last: recent ? { title: recent.title.split('\n')[0].slice(0, 60), status: recent.status } : null,
  };
}

async function askSend(req) {
  if (req?.addProject) {
    const r = await dialog.showOpenDialog(win, { title: 'Choose a project folder', properties: ['openDirectory'] });
    if (r.canceled || !r.filePaths[0]) return { info: askInfo() };
    companyRequest({ kind: 'addProject', path: r.filePaths[0] });
    await new Promise((res) => setTimeout(res, 400));
    return { info: askInfo(), added: path.basename(r.filePaths[0]) };
  }
  const title = String(req?.title || '').trim();
  if (!title) return { ok: false, error: 'Type what you want done.', info: askInfo() };
  if (!tools.chosen().some((id) => tools.find(id))) {
    openAgents();
    return { ok: false, error: 'Install an agent first.', info: askInfo() };
  }
  config.lastProject = req.project;
  saveConfig();
  companyRequest({ kind: 'create', title, project: req.project, worker: 'auto' });
  await new Promise((res) => setTimeout(res, 400));
  return { ok: true, info: askInfo() };
}

function focusAsk() {
  if (!win) return;
  win.show();
  win.focus();
  win.webContents.send('ask:focus');
  updateTray();
}

/** Do it here if we run the Company, otherwise hand it to the process that does. */
function companyRequest(req) {
  if (host?.owner) {
    host.company.handleInbox([{ id: `${Date.now()}-${Math.random()}`, source: 'pc', ...req }]);
    host.company.tick();
  } else {
    require('./company/host').sendRequest(req);
  }
  setTimeout(pushCompanyState, 300);
}

function setupCompanyIpc() {
  ipcMain.handle('company:state', () => ({ ...companyState(), version: VERSION }));
  ipcMain.handle('company:create', (_e, { title, project, worker }) => companyRequest({ kind: 'create', title, project, worker }));
  for (const kind of ['cancel', 'retry', 'remove']) {
    ipcMain.handle(`company:${kind}`, (_e, task) => companyRequest({ kind, task }));
  }
  ipcMain.handle('company:addProject', async () => {
    const r = await dialog.showOpenDialog(companyWin, { title: 'Choose a project folder', properties: ['openDirectory'] });
    if (r.canceled || !r.filePaths[0]) return null;
    companyRequest({ kind: 'addProject', path: r.filePaths[0] });
    return require('path').basename(r.filePaths[0]);
  });
  ipcMain.handle('company:removeProject', (_e, name) => companyRequest({ kind: 'removeProject', name }));
  // The team: CEO and roles (saved with Settings), and a quick check that each agent answers.
  const teamState = () => {
    const st = require('./settings').read();
    return { ceo: st.ceo, strengths: st.strengths, defaultStrengths: st.defaultStrengths, agents: tools.status() };
  };
  ipcMain.handle('company:team', () => teamState());
  ipcMain.handle('company:setTeam', (_e, patch = {}) => {
    require('./settings').write({ ceo: patch.ceo, strengths: patch.strengths });
    host?.applyConfig?.();
    setTimeout(pushCompanyState, 100);
    return teamState();
  });
  ipcMain.handle('company:testTeam', () => testTeam());
  // When another process runs the Company, watch its saved state.
  fs.watchFile(require('./company/host').COMPANY_FILE, { interval: 2000 }, () => { if (!host?.owner) pushCompanyState(); });
}

/** Asks each chosen agent for a one-word reply, so you see right away what works. */
async function testTeam() {
  const { run } = require('./company/workers');
  const dir = fs.mkdtempSync(path.join(require('os').tmpdir(), 'limitty-test-'));
  const opts = agentConfig()?.workers || {};
  const results = await Promise.all(tools.chosen().map(async (id) => {
    if (!tools.find(id)) return { id, ok: false, text: 'Not installed. Open Agents… to install it.' };
    if (tools.TOOLS[id].signedIn() === false) return { id, ok: false, text: 'Not signed in. Open Agents… and press Sign in.' };
    const r = await run(id, 'This is a connection test from Limitty. Reply with exactly: OK', { cwd: dir, mode: 'plan', timeoutMs: 120_000, opts }).promise;
    return { id, ok: r.ok, text: r.text.slice(-800) };
  }));
  fs.rmSync(dir, { recursive: true, force: true });
  require('./company/workers').isInstalled.clearCache?.();
  return results;
}

function placeDefault() {
  if (!win) return;
  const { workArea } = screen.getPrimaryDisplay();
  win.setPosition(workArea.x + workArea.width - win.getSize()[0] - 16, workArea.y + 16);
}

function updateTray() {
  if (!tray) return;
  tray.setContextMenu(buildTrayMenu());
  const tip = lastResults.map((r) => (r.ok
    ? `${r.name}: ${r.windows.map((w) => `${w.label} ${Math.round(w.usedPercent ?? 0)}%`).join(', ')}`
    : `${r.name}: ${r.error}`)).join('\n');
  tray.setToolTip(tip || 'Limitty');
}

function toggleWindow() {
  if (!win) createWindow();
  else if (win.isVisible()) win.hide();
  else win.showInactive();
  updateTray();
}

let refreshing = null;
async function refresh() {
  if (refreshing) return refreshing;
  win?.webContents.send('limits:loading');
  refreshing = fetchAll(config.providers).then((results) => {
    lastResults = results;
    win?.webContents.send('limits:update', results);
    updateTray();
    return results;
  }).finally(() => { refreshing = null; });
  return refreshing;
}

function schedule() {
  clearInterval(timer);
  timer = setInterval(refresh, Math.max(1, config.refreshMinutes) * 60 * 1000);
}

// ───── Start at login (Electron's own setting only works on macOS and Windows) ─────

const AUTOSTART_FILE = path.join(app.getPath('home'), '.config', 'autostart', 'limitty.desktop');

function getStartAtLogin() {
  if (process.platform === 'linux') return fs.existsSync(AUTOSTART_FILE);
  return app.getLoginItemSettings().openAtLogin;
}

function setStartAtLogin(on) {
  if (process.platform !== 'linux') { app.setLoginItemSettings({ openAtLogin: on }); return; }
  if (!on) { fs.rmSync(AUTOSTART_FILE, { force: true }); return; }
  // AppImage: the AppImage file itself; installed package / dev: the executable (+ app folder in dev).
  const exec = process.env.APPIMAGE ? `"${process.env.APPIMAGE}"`
    : app.isPackaged ? `"${process.execPath}"` : `"${process.execPath}" "${app.getAppPath()}"`;
  fs.mkdirSync(path.dirname(AUTOSTART_FILE), { recursive: true });
  fs.writeFileSync(AUTOSTART_FILE, `[Desktop Entry]\nType=Application\nName=Limitty\nComment=Usage limits and agent status\nExec=${exec}\nIcon=limitty\nTerminal=false\nX-GNOME-Autostart-enabled=true\n`);
}

// ───── Command-line switches (handy for Hyprland keybinds and Waybar) ─────
//   limitty --company   open the Company window
//   limitty --toggle    show/hide the widget
//   limitty --agents    choose, install and sign in to your agents
//   limitty --prompt    show the widget and type a task for your agents
//   limitty --settings  open Settings
//   limitty --waybar    print usage limits as Waybar JSON and exit

function handleArgs(argv) {
  if (argv.includes('--company')) openCompany();
  else if (argv.includes('--agents')) openAgents();
  else if (argv.includes('--prompt')) focusAsk();
  else if (argv.includes('--settings')) openSettings();
  else if (argv.includes('--toggle')) toggleWindow();
  else if (win) win.showInactive();
}

if (process.platform === 'linux') app.commandLine.appendSwitch('enable-transparent-visuals');

if (process.argv.includes('--waybar')) {
  require('./waybar').print().finally(() => app.exit(0));
} else if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => handleArgs(argv));

  app.whenReady().then(() => {
    if (process.platform === 'darwin') app.dock?.hide();
    loadConfig();
    createWindow();
    tray = new Tray(trayIcon());
    tray.on('click', toggleWindow);
    updateTray();

    ipcMain.handle('limits:get', () => lastResults);
    ipcMain.handle('limits:refresh', () => refresh());
    ipcMain.on('window:resize', (_e, height) => {
      if (!win) return;
      const h = Math.max(80, Math.min(900, Math.ceil(height)));
      const [w, cur] = win.getSize();
      if (cur === h) return;
      // Some window managers ignore setSize on non-resizable windows.
      win.setResizable(true);
      win.setSize(w, h);
      win.setResizable(false);
    });
    ipcMain.on('window:hide', () => { win?.hide(); updateTray(); });
    ipcMain.on('window:menu', () => buildTrayMenu().popup({ window: win }));
    ipcMain.on('window:company', openCompany);
    ipcMain.handle('ask:info', () => askInfo());
    ipcMain.handle('agents:sessions', () => agentSessions());
    ipcMain.handle('ask:send', (_e, req) => askSend(req));
    setupCompanyIpc();
    setupAgentsIpc();
    setupSettingsIpc();

    win.webContents.once('did-finish-load', refresh);
    schedule();

    startHost();
    // Hooks from an older version (or a moved AppImage) point at the wrong place: fix them.
    try {
      const fixed = require('./agents/connect').repairHooks();
      if (fixed.length) console.log(`[agent] updated hooks: ${fixed.join(', ')}`);
    } catch (e) { console.error('[agent] hook repair:', e.message); }
    if (process.argv.includes('--company')) openCompany();
    if (process.argv.includes('--prompt')) win.webContents.once('did-finish-load', focusAsk);
    if (process.argv.includes('--settings')) openSettings();
    // First launch: pick your agents (and install any that are missing).
    if (process.argv.includes('--agents') || !tools.hasChosen()) openAgents();
  });

  app.on('before-quit', () => host?.stop?.());

  // Keep running in the tray when the widget is closed.
  app.on('window-all-closed', (e) => e.preventDefault());
}
