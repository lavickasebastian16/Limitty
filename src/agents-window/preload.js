'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('agents', {
  state: () => ipcRenderer.invoke('agents:state'),
  choose: (ids) => ipcRenderer.invoke('agents:choose', ids),
  setup: () => ipcRenderer.invoke('agents:setup'),
  install: (id) => ipcRenderer.invoke('agents:install', id),
  skip: (id) => ipcRenderer.invoke('agents:skip', id),
  openExternal: (url) => ipcRenderer.send('agents:open', url),
  login: (id) => ipcRenderer.invoke('agents:login', id),
  done: () => ipcRenderer.send('agents:done'),
  onUpdate: (cb) => ipcRenderer.on('agents:update', (_e, s) => cb(s)),
  onLog: (cb) => ipcRenderer.on('agents:log', (_e, line) => cb(line)),
});
