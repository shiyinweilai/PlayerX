const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  openFile: () => ipcRenderer.invoke('open-file'),
  runExe: (file1, file2) => ipcRenderer.invoke('run-exe', file1, file2)
})