const { contextBridge, ipcRenderer, webUtils } = require('electron')

contextBridge.exposeInMainWorld('api', {
  openFiles: () => ipcRenderer.invoke('open-files'),
  scanFolder: (folderPath) => ipcRenderer.invoke('scan-folder', folderPath),
  // 新增：获取文件路径（解决拖拽时 path 属性丢失问题）
  getFilePath: (file) => webUtils.getPathForFile(file),
  runExe: (file1, file2, mode, customArgs) => ipcRenderer.invoke('run-exe', file1, file2, mode, customArgs),
  
  // 添加视频信息探测API
  probeVideoInfo: (filePath) => ipcRenderer.invoke('probe-video-info', filePath),
  
  // 添加日志监听器
  onExeLog: (callback) => {
    ipcRenderer.on('exe-log', (event, data) => {
      callback(data)
    })
  },

  // 新增：手动检查更新
  checkForUpdates: () => ipcRenderer.invoke('check-for-updates')
})

contextBridge.exposeInMainWorld('menu', {
  onSelectLeft: (cb) => ipcRenderer.on('menu-select-left', cb),
  onSelectRight: (cb) => ipcRenderer.on('menu-select-right', cb),
  // 新增：菜单触发手动检查更新
  onCheckUpdate: (cb) => ipcRenderer.on('menu-check-update', cb),
})