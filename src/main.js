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
    { label: win?.isVisible() ? 'Hide widget' : 'Show widget', click: toggleWindow },
    { label: 'Refresh now', click: refresh },
    {
      label: 'Always on top',
      type: 'checkbox',
      checked: config.alwaysOnTop,
      click: (item) => {
        config.alwaysOnTop = item.checked;
        win?.setAlwaysOnTop(item.checked);
        saveConfig();
      },
    },
    {
      label: 'Refresh every',
      submenu: [1, 2, 5, 10, 15, 30].map((m) => ({
        label: `${m} min`,
        type: 'radio',
        checked: config.refreshMinutes === m,
        click: () => { config.refreshMinutes = m; saveConfig(); schedule(); },
      })),
    },
    { label: 'Choose agents…', click: openAgents },
    {
      label: 'Start at login',
      type: 'checkbox',
      checked: getStartAtLogin(),
      click: (item) => setStartAtLogin(item.checked),
    },
    { label: 'Reset position', click: () => { config.x = null; config.y = null; saveConfig(); placeDefault(); } },
    { type: 'separator' },
    { label: 'Company: tasks for your agents…', click: openCompany },
    agentsMenuItem(),
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
      label: `Agents → iPhone: @${gh.login}`,
      submenu: [
        { label: 'Reinstall agent hooks', click: () => { require('./agents/connect').installHooks(); dialog.showMessageBox({ message: 'Agent hooks reinstalled. Restart open agent sessions to pick them up.' }); } },
        { label: 'Disconnect', click: () => { require('./agents/connect').disconnect(); host?.detachRelay?.(); updateTray(); } },
      ],
    };
  }
  return { label: 'Connect agents to iPhone…', click: connectAgents };
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
const agentJobs = {}; // id → { job: 'queued'|'installing', error, loginCommand, loginOpened }
let installing = false;

function openAgents() {
  if (agentsWin) { agentsWin.show(); agentsWin.focus(); return; }
  agentsWin = new BrowserWindow({
    width: 620,
    height: 560,
    minWidth: 460,
    minHeight: 380,
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
    return { ...a, job: j.job || null, error: j.error || null, loginCommand: j.loginCommand || null, loginOpened: !!j.loginOpened && a.signedIn !== true };
  });
  return { agents: list, busy: installing, version: VERSION };
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

/** Hooks for live status on the phone, if you've connected it. */
function reinstallHooksIfConnected() {
  if (!agentConfig()) return;
  try { require('./agents/connect').installHooks(); } catch { /* shown in the menu instead */ }
}

async function installAgents(ids) {
  ids = ids.filter((id) => tools.TOOLS[id] && !tools.find(id));
  if (installing || !ids.length) return agentsState();
  installing = true;
  for (const id of ids) agentJobs[id] = { job: 'queued' };
  pushAgentsState();
  const log = (line) => agentsWin?.webContents.send('agents:log', line);
  for (const id of ids) {
    agentJobs[id] = { job: 'installing' };
    pushAgentsState();
    log(`── Installing ${tools.TOOLS[id].name} ──`);
    const r = await tools.install(id, { onLine: log }).promise;
    if (r.ok) {
      log(`✓ ${tools.TOOLS[id].name} installed: ${r.path}`);
      agentJobs[id] = {};
      // Straight on to signing in, unless it already is.
      if (tools.TOOLS[id].signedIn() !== true) loginAgent(id);
    } else {
      log(`✗ ${tools.TOOLS[id].name}: ${r.error}`);
      agentJobs[id] = { error: `Install failed: ${r.error}` };
    }
    pushAgentsState();
  }
  installing = false;
  require('./company/workers').isInstalled.clearCache?.();
  reinstallHooksIfConnected();
  refresh();
  return agentsState();
}

function loginAgent(id) {
  const r = tools.openLogin(id);
  agentJobs[id] = { ...(agentJobs[id] || {}), loginOpened: r.ok, loginCommand: r.ok ? null : r.command };
  setTimeout(refresh, 60_000); // pick up the new limits once you've signed in
  return agentsState();
}

function setupAgentsIpc() {
  ipcMain.handle('agents:state', () => agentsState());
  ipcMain.handle('agents:choose', (_e, ids) => { applyChoice(ids); return agentsState(); });
  ipcMain.handle('agents:install', (_e, ids) => installAgents(ids));
  ipcMain.handle('agents:login', (_e, id) => loginAgent(id));
  ipcMain.on('agents:done', () => {
    if (!tools.hasChosen()) applyChoice(tools.chosen());
    agentsWin?.close();
  });
  ipcMain.on('window:agents', openAgents);
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
  // When another process runs the Company, watch its saved state.
  fs.watchFile(require('./company/host').COMPANY_FILE, { interval: 2000 }, () => { if (!host?.owner) pushCompanyState(); });
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
//   limitty --waybar    print usage limits as Waybar JSON and exit

function handleArgs(argv) {
  if (argv.includes('--company')) openCompany();
  else if (argv.includes('--agents')) openAgents();
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
    setupCompanyIpc();
    setupAgentsIpc();

    win.webContents.once('did-finish-load', refresh);
    schedule();

    startHost();
    if (process.argv.includes('--company')) openCompany();
    // First launch: pick your agents (and install any that are missing).
    if (process.argv.includes('--agents') || !tools.hasChosen()) openAgents();
  });

  app.on('before-quit', () => host?.stop?.());

  // Keep running in the tray when the widget is closed.
  app.on('window-all-closed', (e) => e.preventDefault());
}
