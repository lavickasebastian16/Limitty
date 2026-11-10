'use strict';

const { app, BrowserWindow, Tray, Menu, ipcMain, nativeImage, screen } = require('electron');
const path = require('path');
const fs = require('fs');
const { fetchAll } = require('./providers');

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
    {
      label: 'Show',
      submenu: [['claude', 'Claude'], ['codex', 'Codex'], ['antigravity', 'Antigravity (agy)']].map(([id, label]) => ({
        label,
        type: 'checkbox',
        checked: config.providers.includes(id),
        click: (item) => {
          config.providers = item.checked
            ? [...new Set([...config.providers, id])]
            : config.providers.filter((p) => p !== id);
          saveConfig();
          refresh();
        },
      })),
    },
    {
      label: 'Start at login',
      type: 'checkbox',
      checked: app.getLoginItemSettings().openAtLogin,
      click: (item) => app.setLoginItemSettings({ openAtLogin: item.checked }),
    },
    { label: 'Reset position', click: () => { config.x = null; config.y = null; saveConfig(); placeDefault(); } },
    { type: 'separator' },
    { label: 'Quit Limitty', click: () => app.quit() },
  ]);
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

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => { if (win) win.showInactive(); });

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

    win.webContents.once('did-finish-load', refresh);
    schedule();
  });

  // Keep running in the tray when the widget is closed.
  app.on('window-all-closed', (e) => e.preventDefault());
}
