const { app, BrowserWindow, ipcMain, dialog, Menu, shell } = require('electron')
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

  // 监听窗口关闭事件，正确清理win变量
  win.on('closed', () => {
    win = null
  })
}

// 新增：构建并安装应用菜单（示例：在 Help 菜单绑定“使用说明”）
function showHelp() {
  dialog.showMessageBox({
    type: 'info',
    title: '使用说明',
    message: '视频对比工具使用说明',
    detail:
      '1. 点击“选择左侧视频/选择右侧视频”导入多个视频\n' +
      '2. 可选：选择对比模式并输入附加参数\n' +
      '3. 点击“开始对比”启动外部对比程序\n' +
      '4. 程序输出会实时显示在“执行状态”中',
    buttons: ['我知道了']
  })
}

function buildAppMenu() {
  const isMac = process.platform === 'darwin'
  const template = [
    // macOS 应用菜单（中文化）
    ...(isMac
      ? [{
        label: app.name,
        submenu: [
          { role: 'about', label: '关于' },
          { type: 'separator' },
          { role: 'services', label: '服务' },
          { type: 'separator' },
          { role: 'hide', label: '隐藏' },
          { role: 'hideOthers', label: '隐藏其他' },
          { role: 'unhide', label: '显示全部' },
          { type: 'separator' },
          { role: 'quit', label: '退出' }
        ]
      }]
      : []),
    // 文件菜单（中文化）
    {
      label: '文件',
      submenu: [
        {
          label: '选择左侧视频',
          click: () => { if (win) win.webContents.send('menu-select-left') }
        },
        {
          label: '选择右侧视频',
          click: () => { if (win) win.webContents.send('menu-select-right') }
        },
        { type: 'separator' },
        isMac ? { role: 'close', label: '关闭窗口' } : { role: 'quit', label: '退出' },
      ]
    },

    // 视图菜单（显式中文定义：便于增删）
    {
      label: '视图',
      submenu: [
        { role: 'reload', label: '重新加载' },
        { role: 'forceReload', label: '强制重新加载' },
        { role: 'toggleDevTools', label: '切换开发者工具' },
      ]
    },
    // 帮助菜单（中文化）
    {
      label: '帮助',
      submenu: [
        { label: '使用说明', click: showHelp }, { type: 'separator' },
        { label: '更多说明', click: () => shell.openExternal('https://iwiki.woa.com/p/4016316239 PlayerX使用说明') },
        {
          label: '关于我们', click: () => dialog.showMessageBox({
            type: 'info', title: '关于我们', message: '视频对比工具 v1.0\n作者：rbyang'
          })
        },
      ]
    }
  ]

  const menu = Menu.buildFromTemplate(template)
  Menu.setApplicationMenu(menu)
}

// 增加单实例锁，避免重复启动导致无响应，并在重复启动时聚焦已有窗口
const gotLock = app.requestSingleInstanceLock()
if (!gotLock) {
  app.quit()
} else {
  app.on('second-instance', () => {
    // 改进检查逻辑：不仅要检查win是否存在，还要检查窗口是否未被销毁
    if (win && !win.isDestroyed()) {
      if (win.isMinimized()) win.restore()
      win.show()
      win.focus()
    } else {
      createWindow()
    }
  })

  // 修改：应用就绪后创建窗口并安装菜单
  app.whenReady().then(() => {
    createWindow()
    buildAppMenu()
  })

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

ipcMain.handle('run-exe', async (event, file1, file2, mode, customArgs = '') => {
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
    console.log('模式参数:', mode)
    console.log('自定义参数:', customArgs)
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

      // 构建参数数组
      const args = ['-m', mode]

      // 如果有自定义参数，将其添加到参数数组中
      if (customArgs) {
        // 将自定义参数按空格分割成数组
        const customArgsArray = customArgs.split(' ').filter(arg => arg.trim() !== '')
        args.push(...customArgsArray)
      }
      if (!args.includes('-w')) {
        args.push('--window-fit-display')
      }
      // 添加文件路径参数
      args.push(file1, file2)

      console.log('完整参数列表:', args)

      // 启动可执行文件，捕获输出
      const child = spawn(exePath, args, {
        cwd: exeCwd,
        detached: true,
        windowsHide: false,
        stdio: ['ignore', 'pipe', 'pipe'] // 捕获stdout和stderr
      })

      // 捕获标准输出
      child.stdout.on('data', (data) => {
        const log = data.toString().trim()
        if (log) {
          console.log('EXE stdout:', log)
          // 发送日志到渲染进程
          event.sender.send('exe-log', { type: 'stdout', message: log })
        }
      })

      // 捕获错误输出
      child.stderr.on('data', (data) => {
        const log = data.toString().trim()
        if (log) {
          console.log('EXE stderr:', log)
          // 发送日志到渲染进程
          event.sender.send('exe-log', { type: 'stderr', message: log })
        }
      })

      child.on('error', (error) => {
        const msg = `启动失败: ${error.message}\ncode: ${error.code || ''}\npath: ${exePath}`
        reject(msg)
      })

      child.on('close', (code) => {
        console.log(`可执行文件退出，代码: ${code}`)
        event.sender.send('exe-log', { type: 'close', message: `进程退出，代码: ${code}` })
      })

      child.unref()
      resolve(`已启动 ${exeName}，模式: ${mode}`)
    } catch (error) {
      const msg = `执行失败: ${error.message}\ncode: ${error.code || ''}\npath: ${exePath}`
      reject(msg)
    }
  })
})

// 获取ffprobe可执行文件路径
function getFfprobePath() {
  const platform = os.platform()
  let ffprobeDirName, ffprobeName

  switch (platform) {
    case 'win32':
      ffprobeDirName = 'win-inner'
      ffprobeName = 'ffprobe.exe'
      break
    case 'darwin':
      ffprobeDirName = 'mac-inner'
      ffprobeName = 'ffprobe'
      break
    default:
      ffprobeDirName = 'win-inner'
      ffprobeName = 'ffprobe.exe'
  }

  let ffprobePath
  if (app.isPackaged) {
    ffprobePath = path.join(process.resourcesPath, 'app.asar.unpacked', ffprobeDirName, ffprobeName)
  } else {
    ffprobePath = path.resolve(__dirname, ffprobeDirName, ffprobeName)
  }

  return ffprobePath
}

// 处理视频信息探测请求
ipcMain.handle('probe-video-info', async (event, filePath) => {
  return new Promise((resolve, reject) => {
    const ffprobePath = getFfprobePath()

    console.log('ffprobe路径:', ffprobePath)
    console.log('探测视频文件:', filePath)

    // 检查文件是否存在
    if (!fs.existsSync(filePath)) {
      return reject(`视频文件不存在: ${filePath}`)
    }

    // 检查ffprobe是否存在
    if (!fs.existsSync(ffprobePath)) {
      return reject(`ffprobe工具不存在: ${ffprobePath}`)
    }

    const { spawn } = require('child_process')

    try {
      // 使用ffprobe探测视频信息
      const ffprobe = spawn(ffprobePath, [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams',
        filePath
      ])

      let stdoutData = ''
      let stderrData = ''

      ffprobe.stdout.on('data', (data) => {
        stdoutData += data.toString()
      })

      ffprobe.stderr.on('data', (data) => {
        stderrData += data.toString()
      })

      ffprobe.on('close', (code) => {
        if (code === 0) {
          try {
            const videoInfo = JSON.parse(stdoutData)

            // 提取关键信息
            const info = {
              duration: videoInfo.format?.duration || '未知',
              size: videoInfo.format?.size || '未知',
              bitrate: videoInfo.format?.bit_rate || '未知',
              format: videoInfo.format?.format_name || '未知',
              videoStreams: [],
              audioStreams: []
            }

            // 处理视频流信息
            if (videoInfo.streams) {
              videoInfo.streams.forEach(stream => {
                if (stream.codec_type === 'video') {
                  // 检测像素格式，如果是yuv420p则标记为yuv420p (tv)
                  const pixelFormat = stream.pix_fmt || '未知'
                  const pixelFormatDisplay = pixelFormat === 'yuv420p' ? 'yuv420p (tv)' : pixelFormat

                  // 提取颜色空间信息
                  const colorSpace = stream.color_space || stream.color_primaries || '未知'

                  info.videoStreams.push({
                    codec: stream.codec_name || '未知',
                    resolution: `${stream.width || '?'}x${stream.height || '?'}`,
                    fps: stream.r_frame_rate || '未知',
                    bitrate: stream.bit_rate || '未知',
                    pixelFormat: pixelFormatDisplay,
                    colorSpace: colorSpace
                  })
                } else if (stream.codec_type === 'audio') {
                  info.audioStreams.push({
                    codec: stream.codec_name || '未知',
                    channels: stream.channels || '未知',
                    sampleRate: stream.sample_rate || '未知',
                    language: stream.tags?.language || '未知'
                  })
                }
              })
            }

            resolve(info)
          } catch (parseError) {
            reject(`解析ffprobe输出失败: ${parseError.message}`)
          }
        } else {
          reject(`ffprobe执行失败，退出码: ${code}\n错误信息: ${stderrData}`)
        }
      })

      ffprobe.on('error', (error) => {
        reject(`启动ffprobe失败: ${error.message}`)
      })

    } catch (error) {
      reject(`执行ffprobe出错: ${error.message}`)
    }
  })
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})