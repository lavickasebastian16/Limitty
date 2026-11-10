'use strict';

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('company', {
  state: () => ipcRenderer.invoke('company:state'),
  create: (task) => ipcRenderer.invoke('company:create', task),
  cancel: (id) => ipcRenderer.invoke('company:cancel', id),
  retry: (id) => ipcRenderer.invoke('company:retry', id),
  remove: (id) => ipcRenderer.invoke('company:remove', id),
  addProject: () => ipcRenderer.invoke('company:addProject'),
  removeProject: (name) => ipcRenderer.invoke('company:removeProject', name),
  onUpdate: (cb) => ipcRenderer.on('company:update', (_e, s) => cb(s)),
});
