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
      exePath = path.join(__dirname, exeDirName, exeName)
    }

    // macOS: 额外支持 .app Bundle，避免弹出终端
    let appBundlePath = null
    if (os.platform() === 'darwin') {
      const bundleName = 'video-compare' // 如果你打成 .app，请将名称保持一致
      const bundleCandidates = app.isPackaged
        ? [
            path.join(process.resourcesPath, 'app.asar.unpacked', exeDirName, bundleName),
            path.join(process.resourcesPath, exeDirName, bundleName)
          ]
        : [
            path.join(__dirname, exeDirName, bundleName)
          ]
      appBundlePath = bundleCandidates.find(p => fs.existsSync(p)) || null
    }

    // 读取 .app 的 CFBundleExecutable 名称（用于回退直接执行）
    function getBundleExecutableName(bundlePath) {
      try {
        const infoPlist = path.join(bundlePath, 'Contents', 'Info.plist')
        if (!fs.existsSync(infoPlist)) return path.basename(bundlePath, '.app')
        const raw = fs.readFileSync(infoPlist, 'utf8')
        const m = raw.match(/<key>CFBundleExecutable<\/key>\s*<string>([^<]+)<\/string>/)
        return m ? m[1] : path.basename(bundlePath, '.app')
      } catch {
        return path.basename(bundlePath, '.app')
      }
    }

    console.log('当前平台:', os.platform())
    console.log('process.resourcesPath:', process.resourcesPath)
    console.log('执行路径(可执行):', exePath)
    if (appBundlePath) console.log('发现 .app Bundle:', appBundlePath)
    console.log('参数 file1:', file1)
    console.log('参数 file2:', file2)

    const { spawn } = require('child_process')
    try {
      if (os.platform() === 'darwin') {
        if (!appBundlePath) {
          return reject(`macOS 平台要求使用 .app Bundle 启动以避免弹出终端。未找到: ${path.join(app.isPackaged ? process.resourcesPath : __dirname, exeDirName, 'video-compare')}`)
        }
        // 优先使用 open -n -a 启动（-n 强制新实例）
        const args = ['-n', '-a', appBundlePath, '--args', file1, file2]
        const child = spawn('open', args, {
          cwd: path.dirname(appBundlePath),
          detached: true,
          stdio: 'ignore'
        })
        let openFailed = false
        child.on('error', (error) => {
          openFailed = true
          console.warn(`[run] open -a 失败，尝试直接执行 .app 内容可执行: ${error.message}`)
          // 回退：直接运行 .app/Contents/MacOS/<CFBundleExecutable>
          try {
            const execName = getBundleExecutableName(appBundlePath)
            const macExec = path.join(appBundlePath, 'Contents', 'MacOS', execName)
            if (!fs.existsSync(macExec)) {
              return reject(`未找到 .app 内部可执行文件: ${macExec}`)
            }
            const direct = spawn(macExec, [file1, file2], {
              cwd: path.dirname(appBundlePath),
              detached: true,
              stdio: 'ignore'
            })
            direct.on('error', (err2) => {
              const msg = `直接执行 .app 可执行失败: ${err2.message}\npath: ${macExec}`
              reject(msg)
            })
            direct.unref()
            resolve(`已直接启动 ${execName}`)
          } catch (errFallback) {
            reject(`回退执行失败: ${errFallback.message}`)
          }
        })
        child.unref()
        if (!openFailed) {
          return resolve(`已启动 ${path.basename(appBundlePath)} (open -n -a)`)    
        }
      }

      // 非 macOS，回退到原有可执行文件逻辑
      const exeCwd = path.dirname(exePath)
      if (!fs.existsSync(exePath)) {
        return reject(`找不到可执行文件: ${exePath}\n请确认已将 ${exeName} 和相关依赖文件放入 ${exeDirName} 目录，且在打包配置中包含并 asarUnpack。`)
      }

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
      const msg = `执行失败: ${error.message}\ncode: ${error.code || ''}\npath: ${appBundlePath || exePath}`
      reject(msg)
    }
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})