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

app.whenReady().then(createWindow)

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
    case 'linux':
      exeDirName = 'linux-inner'
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
      exePath = path.join(__dirname, exeDirName, exeName)
    }

    console.log('当前平台:', os.platform())
    console.log('process.resourcesPath:', process.resourcesPath)
    console.log('执行路径:', exePath)
    console.log('参数 file1:', file1)
    console.log('参数 file2:', file2)

    if (!fs.existsSync(exePath)) {
      return reject(`找不到可执行文件: ${exePath}\n请确认已将 ${exeName} 和相关依赖文件放入 ${exeDirName} 目录，且在打包配置中包含并 asarUnpack。`)
    }

    // GUI程序通常不会退出，使用spawn以脱离模式启动，不等待退出
    const { spawn } = require('child_process')
    const exeCwd = path.dirname(exePath)

    try {
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