'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('limitty', {
  get: () => ipcRenderer.invoke('limits:get'),
  refresh: () => ipcRenderer.invoke('limits:refresh'),
  onUpdate: (cb) => ipcRenderer.on('limits:update', (_e, results) => cb(results)),
  onLoading: (cb) => ipcRenderer.on('limits:loading', () => cb()),
  resize: (height) => ipcRenderer.send('window:resize', height),
  hide: () => ipcRenderer.send('window:hide'),
  menu: () => ipcRenderer.send('window:menu'),
  company: () => ipcRenderer.send('window:company'),
  // Prompt box: send one task to the CEO.
  askInfo: () => ipcRenderer.invoke('ask:info'),
  ask: (task) => ipcRenderer.invoke('ask:send', task),
  onAskInfo: (cb) => ipcRenderer.on('ask:info', (_e, info) => cb(info)),
  onFocusAsk: (cb) => ipcRenderer.on('ask:focus', () => cb()),
});
