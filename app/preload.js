const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  openFiles: () => ipcRenderer.invoke('open-files'),
  scanFolder: (folderPath) => ipcRenderer.invoke('scan-folder', folderPath),
  runExe: (file1, file2) => ipcRenderer.invoke('run-exe', file1, file2)
})