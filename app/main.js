const { app, BrowserWindow, ipcMain, dialog } = require('electron')
const path = require('path')
const fs = require('fs')
const os = require('os')
let win
function createWindow() {
  win = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  })
  win.loadFile('index.html')
}

// 增加单实例锁，避免重复启动导致无响应，并在重复启动时聚焦已有窗口
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    if (win) {
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    } else {
      createWindow()
    }
  })

  app.whenReady().then(createWindow)

  // macOS: 当点击 Dock 图标且没有窗口时，重新创建；有窗口时恢复并聚焦
  app.on('activate', () => {
    const all = BrowserWindow.getAllWindows()
    if (all.length === 0) {
      createWindow()
    } else {
      const w = all[0]
      if (w.isMinimized()) w.restore()
      w.show()
      w.focus()
    }
  })
}

ipcMain.handle('open-file', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog({
    properties: ['openFile'],
    filters: [
      { name: 'Video', extensions: ['mp4', 'mkv', 'avi', 'mov'] }
    ]
  })
  if (canceled || !filePaths || filePaths.length === 0) {
    return null
  }
  return filePaths[0]
})

ipcMain.handle('open-files', async () => {
  const { canceled, filePaths } = await dialog.showOpenDialog({
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: 'Video', extensions: ['mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm'] }
    ]
  })
  if (canceled || !filePaths || filePaths.length === 0) {
    return null
  }
  return filePaths
})

ipcMain.handle('scan-folder', async (event, folderPath) => {
  const videoExtensions = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.flv', '.webm']
  const videoFiles = []
  
  function scanDirectory(dirPath) {
    try {
      const items = fs.readdirSync(dirPath, { withFileTypes: true })
      
      for (const item of items) {
        const fullPath = path.join(dirPath, item.name)
        
        if (item.isDirectory()) {
          scanDirectory(fullPath)
        } else if (item.isFile()) {
          const ext = path.extname(item.name).toLowerCase()
          if (videoExtensions.includes(ext)) {
            videoFiles.push(fullPath)
          }
        }
      }
    } catch (error) {
      console.error('扫描文件夹出错:', error)
      throw new Error(`扫描文件夹失败: ${error.message}`)
    }
  }
  
  if (!fs.existsSync(folderPath)) {
    throw new Error('文件夹不存在: ' + folderPath)
  }
  
  const stats = fs.statSync(folderPath)
  if (!stats.isDirectory()) {
    throw new Error('路径不是文件夹: ' + folderPath)
  }
  
  scanDirectory(folderPath)
  return videoFiles
})

// 根据平台获取可执行文件路径和名称

function getExecutableInfo() {
  const platform = os.platform()
  let exeDirName, exeName
  
  switch (platform) {
    case 'win32':
      exeDirName = 'win-inner'
      exeName = 'video-compare.exe'
      break
    case 'darwin':
      exeDirName = 'mac-inner'
      exeName = 'video-compare'
      break
    default:
      exeDirName = 'win-inner'
      exeName = 'video-compare.exe'
  }
  
  return { exeDirName, exeName }
}

ipcMain.handle('run-exe', async (event, file1, file2) => {
  return new Promise((resolve, reject) => {
    const { exeDirName, exeName } = getExecutableInfo()
    let exePath
    
    if (app.isPackaged) {
      // 打包后，可执行文件在 app.asar.unpacked 目录中
      exePath = path.join(process.resourcesPath, 'app.asar.unpacked', exeDirName, exeName)
    } else {
      // 开发环境，可执行文件在项目目录下的对应平台子目录
      // 使用 path.resolve 确保路径正确
      exePath = path.resolve(__dirname, exeDirName, exeName)
    }

    console.log('当前平台:', os.platform())
    console.log('process.resourcesPath:', process.resourcesPath)
    console.log('__dirname:', __dirname)
    console.log('执行路径(可执行):', exePath)
    console.log('参数 file1:', file1)
    console.log('参数 file2:', file2)

    const { spawn } = require('child_process')
    try {
      // 检查可执行文件是否存在
      if (!fs.existsSync(exePath)) {
        console.log('可执行文件不存在，检查路径:', exePath)
        console.log('当前工作目录:', process.cwd())
        
        // 尝试其他可能的路径
        const altPath1 = path.resolve(process.cwd(), exeDirName, exeName)
        const altPath2 = path.resolve(__dirname, '..', exeDirName, exeName)
        console.log('备选路径1:', altPath1)
        console.log('备选路径2:', altPath2)
        
        return reject(`找不到可执行文件: ${exePath}\n请确认已将 ${exeName} 和相关依赖文件放入 ${exeDirName} 目录，且在打包配置中包含并 asarUnpack。`)
      }

      const exeCwd = path.dirname(exePath)
      
      // 启动可执行文件
      const child = spawn(exePath, [file1, file2], {
        cwd: exeCwd,
        detached: true,
        windowsHide: false,
        stdio: 'ignore' // 不用管stdout/stderr，避免阻塞
      })

      child.on('error', (error) => {
        const msg = `启动失败: ${error.message}\ncode: ${error.code || ''}\npath: ${exePath}`
        reject(msg)
      })
      
      child.unref()
      resolve(`已启动 ${exeName}`)
    } catch (error) {
      const msg = `执行失败: ${error.message}\ncode: ${error.code || ''}\npath: ${exePath}`
      reject(msg)
    }
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})