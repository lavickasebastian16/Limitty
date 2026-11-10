'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('settings', {
  get: () => ipcRenderer.invoke('settings:get'),
  set: (patch) => ipcRenderer.invoke('settings:set', patch),
  detectAgy: () => ipcRenderer.invoke('settings:detectAgy'),
  linkPhone: () => ipcRenderer.invoke('settings:linkPhone'),
  unlinkPhone: () => ipcRenderer.invoke('settings:unlinkPhone'),
  openAgents: () => ipcRenderer.send('window:agents'),
});
