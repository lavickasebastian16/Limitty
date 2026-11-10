'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('agents', {
  state: () => ipcRenderer.invoke('agents:state'),
  choose: (ids) => ipcRenderer.invoke('agents:choose', ids),
  install: (ids) => ipcRenderer.invoke('agents:install', ids),
  login: (id) => ipcRenderer.invoke('agents:login', id),
  done: () => ipcRenderer.send('agents:done'),
  onUpdate: (cb) => ipcRenderer.on('agents:update', (_e, s) => cb(s)),
  onLog: (cb) => ipcRenderer.on('agents:log', (_e, line) => cb(line)),
});
