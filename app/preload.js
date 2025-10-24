const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('api', {
  openFiles: () => ipcRenderer.invoke('open-files'),
  scanFolder: (folderPath) => ipcRenderer.invoke('scan-folder', folderPath),
  runExe: (file1, file2, mode, customArgs) => ipcRenderer.invoke('run-exe', file1, file2, mode, customArgs),
  
  // 添加视频信息探测API
  probeVideoInfo: (filePath) => ipcRenderer.invoke('probe-video-info', filePath),
  
  // 添加日志监听器
  onExeLog: (callback) => {
    ipcRenderer.on('exe-log', (event, data) => {
      callback(data)
    })
  }
})

contextBridge.exposeInMainWorld('menu', {
  onSelectLeft: (cb) => ipcRenderer.on('menu-select-left', cb),
  onSelectRight: (cb) => ipcRenderer.on('menu-select-right', cb),
})