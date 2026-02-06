const { app, BrowserWindow, ipcMain, dialog, Menu, shell, nativeImage, net } = require('electron')

// 设置应用名称
app.setName('Player X')

const path = require('path')
const fs = require('fs')
const os = require('os')
const https = require('https')
let win

// 默认更新检查地址（请修改此处为你自己的 URL）
const UPDATE_MANIFEST_URL = "https://tvp-76917.gzc.vod.tencent-cloud.com/rbyang/PlayerX/latest.json"

function createWindow() {
  // 尝试加载应用图标
  let appIcon = null
  try {
    const iconPath = path.join(__dirname, 'update-icon.png')
    if (fs.existsSync(iconPath)) {
      appIcon = nativeImage.createFromPath(iconPath)
    }
  } catch (e) {
    // 忽略图标加载错误
  }

  win = new BrowserWindow({
    width: 1200,
    height: 800,
    icon: appIcon, // 设置窗口图标
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  })

  win.loadFile(path.join(__dirname, 'index.html'))

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

    // 编辑菜单（新增，支持快捷键）
    {
      label: '编辑',
      submenu: [
        { role: 'undo', label: '撤销' },
        { role: 'redo', label: '重做' },
        { type: 'separator' },
        { role: 'cut', label: '剪切' },
        { role: 'copy', label: '复制' },
        { role: 'paste', label: '粘贴' },
        ...(isMac ? [
          { role: 'pasteAndMatchStyle', label: '粘贴并匹配样式' },
          { role: 'delete', label: '删除' },
          { role: 'selectAll', label: '全选' },
          { type: 'separator' },
          {
            label: '语音',
            submenu: [
              { role: 'startSpeaking', label: '开始朗读' },
              { role: 'stopSpeaking', label: '停止朗读' }
            ]
          }
        ] : [
          { role: 'delete', label: '删除' },
          { type: 'separator' },
          { role: 'selectAll', label: '全选' }
        ])
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
        { label: '检查更新…', click: () => { if (win) win.webContents.send('menu-check-update') } },
        { type: 'separator' },
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
    // macOS: 设置 Dock 图标
    if (process.platform === 'darwin' && app.dock) {
      try {
        const iconPath = path.join(__dirname, 'update-icon.png')
        if (fs.existsSync(iconPath)) {
          const icon = nativeImage.createFromPath(iconPath)
          app.dock.setIcon(icon)
        }
      } catch (e) {
        console.error('设置 Dock 图标失败:', e)
      }
    }

    createWindow()
    buildAppMenu()
    // 启动3秒后自动检查更新
    setTimeout(() => {
      checkForUpdates(false).catch(e => console.log('Auto update check failed:', e))
    }, 3000)
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
      // 打包后，可执行文件在 Resources 目录中 (通过 extraResources 复制)
      exePath = path.join(process.resourcesPath, exeDirName, exeName)
    } else {
      // 开发环境，可执行文件在 src/external 下的对应平台子目录
      // __dirname 是 src 目录
      exePath = path.resolve(__dirname, 'external', exeDirName, exeName)
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
        const altPath2 = path.resolve(__dirname, 'external', exeDirName, exeName)
        console.log('备选路径1:', altPath1)
        console.log('备选路径2:', altPath2)

        return reject(`找不到可执行文件: ${exePath}\n请确认已将 ${exeName} 和相关依赖文件放入 src/external/${exeDirName} 目录，且在打包配置中正确配置 extraResources。`)
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
    ffprobePath = path.join(process.resourcesPath, ffprobeDirName, ffprobeName)
  } else {
    ffprobePath = path.resolve(__dirname, 'external', ffprobeDirName, ffprobeName)
  }

  return ffprobePath
}

// 处理视频信息探测请求
ipcMain.handle('probe-video-info', async (event, filePath) => {
  const ffprobePath = getFfprobePath()
  console.log('ffprobe路径:', ffprobePath)
  console.log('探测视频文件:', filePath)

  // 简单判断是否为 URL
  const isUrl = filePath.match(/^(http|https|rtmp|rtsp):\/\//)

  // 检查文件是否存在（仅本地文件）
  if (!isUrl && !fs.existsSync(filePath)) {
    throw new Error(`视频文件不存在: ${filePath}`)
  }

  // 检查ffprobe是否存在
  if (!fs.existsSync(ffprobePath)) {
    throw new Error(`ffprobe工具不存在: ${ffprobePath}`)
  }

  const { spawn } = require('child_process')

  // 定义探测函数，支持超时
  const probe = async () => {
    return new Promise((resolve, reject) => {
      const args = [
        '-v', 'quiet',
        '-print_format', 'json',
        '-show_format',
        '-show_streams'
      ]
      
      // 针对 URL 优化探测参数，减少等待时间
      if (isUrl) {
        args.push('-analyzeduration', '10000000') // 10秒
        args.push('-probesize', '10000000') // 10MB
      }
      
      args.push(filePath)

      const ffprobe = spawn(ffprobePath, args)
      
      let stdoutData = ''
      let stderrData = ''
      let isTimeout = false

      // 设置超时 (URL 15秒，本地 5秒)
      const timeoutMs = isUrl ? 15000 : 5000
      const timer = setTimeout(() => {
        isTimeout = true
        ffprobe.kill()
        reject(new Error(`探测超时 (${timeoutMs}ms)`))
      }, timeoutMs)

      ffprobe.stdout.on('data', (data) => {
        stdoutData += data.toString()
      })

      ffprobe.stderr.on('data', (data) => {
        stderrData += data.toString()
      })

      ffprobe.on('close', (code) => {
        clearTimeout(timer)
        if (isTimeout) return

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
            reject(new Error(`解析ffprobe输出失败: ${parseError.message}`))
          }
        } else {
          reject(new Error(`ffprobe执行失败，退出码: ${code}\n错误信息: ${stderrData}`))
        }
      })

      ffprobe.on('error', (error) => {
        clearTimeout(timer)
        if (!isTimeout) {
          reject(new Error(`启动ffprobe失败: ${error.message}`))
        }
      })
    })
  }

  // 重试逻辑
  const maxRetries = isUrl ? 1 : 0
  let lastError
  
  for (let i = 0; i <= maxRetries; i++) {
    try {
      if (i > 0) console.log(`重试探测 (${i}/${maxRetries}): ${filePath}`)
      return await probe()
    } catch (err) {
      lastError = err
      console.warn(`探测尝试 ${i + 1} 失败: ${err.message}`)
    }
  }
  
  throw lastError
})
// 自动下载并安装更新
function downloadAndInstallUpdate(downloadUrl) {
  if (!win) return

  const tempDir = app.getPath('temp')
  // 尝试从 URL 获取文件名，如果失败则使用默认名
  let fileName = 'update-package'
  try {
    const urlObj = new URL(downloadUrl)
    fileName = path.basename(urlObj.pathname) || 'update-package'
  } catch (e) {}

  // 简单的后缀补全
  if (!path.extname(fileName)) {
    fileName += process.platform === 'win32' ? '.exe' : '.zip'
  }

  const savePath = path.join(tempDir, fileName)

  // 显示下载进度窗口（点击“自动下载更新”即视为用户已同意，无需后续确认）
  const progressWin = createUpdateProgressWindow()
  const updateProgressUI = (percent, subText) => {
    if (!win) return
    try {
      if (typeof percent === 'number' && percent >= 0 && percent <= 1) {
        win.setProgressBar(percent)
      }
      if (progressWin && !progressWin.isDestroyed()) {
        const pct = typeof percent === 'number' && percent >= 0 ? Math.min(100, Math.floor(percent * 100)) : 0
        const safeText = String(subText || '').replace(/\\/g, '\\\\').replace(/`/g, '\\`')
        progressWin.webContents.executeJavaScript(
          `window.__setUpdateProgress && window.__setUpdateProgress(${pct}, \`${safeText}\`)`
        ).catch(() => {})
      }
    } catch (e) {}
  }

  const closeProgressUI = () => {
    try { win && win.setProgressBar(-1) } catch (e) {}
    try {
      if (progressWin && !progressWin.isDestroyed()) progressWin.close()
    } catch (e) {}
  }

  try {
    const file = fs.createWriteStream(savePath)
    const request = net.request(downloadUrl)

    request.on('response', (response) => {
      // 处理重定向
      if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
        closeProgressUI()
        downloadAndInstallUpdate(response.headers.location)
        return
      }

      const totalBytes = parseInt(response.headers['content-length'], 10)
      let receivedBytes = 0

      const startAt = Date.now()
      let lastTickAt = startAt
      let lastTickBytes = 0

      const formatBytes = (bytes) => {
        if (!bytes || bytes < 0) return '0 B'
        const units = ['B', 'KB', 'MB', 'GB']
        let v = bytes
        let i = 0
        while (v >= 1024 && i < units.length - 1) {
          v /= 1024
          i++
        }
        return `${v.toFixed(i === 0 ? 0 : 1)} ${units[i]}`
      }

      const formatSeconds = (sec) => {
        if (!isFinite(sec) || sec < 0) return '--'
        const s = Math.floor(sec)
        const m = Math.floor(s / 60)
        const r = s % 60
        return m > 0 ? `${m}分${r}秒` : `${r}秒`
      }

      updateProgressUI(0, '正在下载更新包...')

      response.on('data', (chunk) => {
        receivedBytes += chunk.length
        file.write(chunk)

        if (totalBytes > 0) {
          const progress = receivedBytes / totalBytes

          const now = Date.now()
          if (now - lastTickAt >= 250) {
            const deltaBytes = receivedBytes - lastTickBytes
            const deltaSec = (now - lastTickAt) / 1000
            const speed = deltaSec > 0 ? (deltaBytes / deltaSec) : 0
            const remainBytes = totalBytes - receivedBytes
            const eta = speed > 0 ? (remainBytes / speed) : Infinity

            updateProgressUI(
              progress,
              `已下载 ${formatBytes(receivedBytes)} / ${formatBytes(totalBytes)}  ·  速度 ${formatBytes(speed)}/s  ·  剩余 ${formatSeconds(eta)}`
            )

            lastTickAt = now
            lastTickBytes = receivedBytes
          } else {
            updateProgressUI(progress, '')
          }
        } else {
          // 无 content-length：只能显示已下载大小
          updateProgressUI(0, `已下载 ${formatBytes(receivedBytes)}（服务器未返回总大小）`)
        }
      })

      response.on('end', () => {
        file.end()
        updateProgressUI(1, '下载完成，正在准备安装...')

        // 给 UI 一个短暂时间刷新，然后开始安装
        setTimeout(() => {
          closeProgressUI()
          // 仅 macOS 支持“自动下载并自动安装/替换”
          installMacUpdate(savePath)
        }, 300)
      })

      response.on('error', (err) => {
        file.close()
        fs.unlink(savePath, () => {}) // 删除未完成的文件
        closeProgressUI()
        dialog.showErrorBox('下载失败', '更新下载出错: ' + err.message)
      })
    })

    request.on('error', (err) => {
      closeProgressUI()
      dialog.showErrorBox('请求失败', '无法连接更新服务器: ' + err.message)
    })

    request.end()
  } catch (e) {
    closeProgressUI()
    dialog.showErrorBox('错误', '启动下载失败: ' + e.message)
  }
}

function createUpdateProgressWindow() {
  if (!win) return null

  const progressWin = new BrowserWindow({
    parent: win,
    modal: true,
    show: false,
    width: 560,
    height: 200,
    resizable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    title: '正在下载更新',
    backgroundColor: '#1f1f1f',
    webPreferences: {
      nodeIntegration: true,
      contextIsolation: false
    }
  })

  const html = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>正在下载更新</title>
<style>
  body{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;background:#2b2b2b;color:#fff;}
  .wrap{padding:18px 18px 14px 18px;}
  .title{font-size:18px;font-weight:700;margin-bottom:10px;}
  .bar{height:14px;background:rgba(255,255,255,.18);border-radius:8px;overflow:hidden;}
  .bar>div{height:100%;width:0;background:#0a84ff;border-radius:8px;transition:width .12s linear;}
  .row{display:flex;justify-content:space-between;align-items:center;margin-top:10px;gap:12px;}
  .pct{font-size:14px;opacity:.95;white-space:nowrap;}
  .sub{font-size:13px;opacity:.85;line-height:1.4;margin-top:10px;min-height:18px;}
  .hint{font-size:12px;opacity:.65;margin-top:10px;}
</style>
</head>
<body>
  <div class="wrap">
    <div class="title">正在后台下载更新包，请稍候…</div>
    <div class="bar"><div id="fill"></div></div>
    <div class="row">
      <div class="pct" id="pct">0%</div>
    </div>
    <div class="sub" id="sub"></div>
    <div class="hint">下载完成后将自动解压、处理权限并重启完成更新</div>
  </div>

  <script>
    window.__setUpdateProgress = function(pct, text){
      try{
        var p = Math.max(0, Math.min(100, Number(pct)||0));
        document.getElementById('fill').style.width = p + '%';
        document.getElementById('pct').textContent = p + '%';
        if (text){ document.getElementById('sub').textContent = text; }
      }catch(e){}
    }
  </script>
</body>
</html>`

  progressWin.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(html))
  progressWin.once('ready-to-show', () => progressWin.show())
  return progressWin
}

function installMacUpdate(filePath) {
  // 1. 解压
  const unzipDir = path.join(path.dirname(filePath), 'PlayerX_Update')
  // 清理旧目录
  fs.rmSync(unzipDir, { recursive: true, force: true })
  fs.mkdirSync(unzipDir)

  const { exec } = require('child_process')

  // 使用系统 unzip 命令
  exec(`unzip -o "${filePath}" -d "${unzipDir}"`, (err, stdout, stderr) => {
    if (err) {
      dialog.showErrorBox('更新失败', `解压失败: ${err.message}\n${stderr}`)
      return
    }

    // 2. 找到 .app
    const files = fs.readdirSync(unzipDir)
    const appName = files.find(f => f.endsWith('.app'))
    if (!appName) {
      dialog.showErrorBox('更新失败', '更新包中未找到 .app 应用文件')
      return
    }

    const newAppPath = path.join(unzipDir, appName)

    // 3. 移除隔离属性 (Gatekeeper)
    exec(`xattr -r -d com.apple.quarantine "${newAppPath}"`, (err) => {
      // 忽略 xattr 错误

      // 4. 准备替换和重启（点击“自动下载更新”即视为用户已同意，无需再确认）
      const currentAppPath = path.resolve(process.execPath, '../../..')

      if (!currentAppPath.endsWith('.app')) {
        dialog.showErrorBox('更新提示', `无法自动替换，请手动将新版本移动到应用程序目录。\n新版本位置: ${newAppPath}`)
        shell.showItemInFolder(newAppPath)
        return
      }

      // 生成更新脚本：替换后自动重启
      const scriptPath = path.join(app.getPath('temp'), 'update_script.sh')
      const scriptContent = `#!/bin/bash
sleep 2
rm -rf "${currentAppPath}"
mv "${newAppPath}" "${currentAppPath}"
open "${currentAppPath}"
`
      fs.writeFileSync(scriptPath, scriptContent, { mode: 0o755 })

      // 运行脚本
      const child = require('child_process').spawn('/bin/bash', [scriptPath], {
        detached: true,
        stdio: 'ignore'
      })
      child.unref()

      // 退出应用
      app.quit()
    })
  })
}



/**
 * 检查更新
 * @param {boolean} interactive - 是否为交互模式（手动触发）
 */
async function checkForUpdates(interactive = false) {
  const currentVersion = app.getVersion()
  // 优先使用环境变量，可在本地或打包环境通过环境变量注入清单地址或自定义头
  const manifestUrl = process.env.UPDATE_JSON_URL || UPDATE_MANIFEST_URL
  const headerEnv = process.env.UPDATE_JSON_HEADERS || process.env.PRIVATE_TOKEN || ''

  // 将可选的自定义 headers 从 JSON 字符串解析（例如：{"Authorization":"Bearer ..."}），或从 PRIVATE_TOKEN 环境变量转换为 PRIVATE-TOKEN
  let extraHeaders = {}
  if (headerEnv) {
    try {
      // 如果是单个 token 字符串（PRIVATE_TOKEN），则设置 PRIVATE-TOKEN
      if (!headerEnv.trim().startsWith('{')) {
        extraHeaders['PRIVATE-TOKEN'] = headerEnv.trim()
      } else {
        extraHeaders = JSON.parse(headerEnv)
      }
    } catch (e) {
      console.warn('解析 UPDATE_JSON_HEADERS 失败，将忽略自定义头:', e.message)
      extraHeaders = {}
    }
  }

  if (!manifestUrl) {
    if (interactive) {
      await dialog.showMessageBox({
        type: 'info',
        title: '检查更新',
        message: `当前版本：${currentVersion}`,
        detail: '未配置更新源。请设置环境变量 UPDATE_JSON_URL 指向版本清单 JSON\n例如：UPDATE_JSON_URL=https://your-domain.com/playerx/latest.json',
        buttons: ['我知道了']
      })
    }
    return { status: 'no-source', currentVersion }
  }

  // 数字分段版本比较：1.2.10 > 1.2.3
  const cmp = (a, b) => {
    const pa = String(a).split('.').map(n => parseInt(n || '0', 10))
    const pb = String(b).split('.').map(n => parseInt(n || '0', 10))
    const len = Math.max(pa.length, pb.length)
    for (let i = 0; i < len; i++) {
      const x = pa[i] || 0; const y = pb[i] || 0
      if (x > y) return 1
      if (x < y) return -1
    }
    return 0
  }

  // 帮助函数：保存响应到 cache/latest.json 以便排查（异步不阻塞主流程）
  const saveCache = (content) => {
    try {
      const cacheDir = path.join(__dirname, '..', '..', 'cache')
      if (!fs.existsSync(cacheDir)) fs.mkdirSync(cacheDir, { recursive: true })
      fs.writeFileSync(path.join(cacheDir, 'latest.json'), content, 'utf8')
    } catch (e) {
      console.warn('写入缓存失败:', e.message)
    }
  }

  try {
    let data = ''

    // 支持 file:// 或 本地路径
    if (manifestUrl.startsWith('file://') || /^[a-zA-Z]:\\/.test(manifestUrl)) {
      let localPath = manifestUrl

      if (manifestUrl.startsWith('file://')) {
        localPath = manifestUrl.replace('file://', '')
      }
      try {
        data = fs.readFileSync(localPath, 'utf8')
      } catch (err) {
        throw new Error('读取本地清单失败: ' + err.message)
      }
    } else {
      // 网络请求，支持最多 5 次重定向
      data = await new Promise((resolve, reject) => {
        try {
          const urlObj = new URL(manifestUrl)
          const maxRedirects = 5
          let redirects = 0

          const doGet = (urlToGet) => {
            const opts = {
              method: 'GET',
              timeout: 10000,
              headers: Object.assign({ 'Accept': 'application/json', 'User-Agent': `${app.name}/${app.getVersion()}` }, extraHeaders)
            }
            const lib = urlToGet.startsWith('https:') ? require('https') : require('http')
            const req = lib.get(urlToGet, opts, (res) => {
              // 处理重定向
              if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
                if (redirects++ >= maxRedirects) {
                  reject(new Error('重定向次数过多'))
                  return
                }
                // 相对跳转处理
                const next = new URL(res.headers.location, urlToGet).toString()
                res.resume()
                doGet(next)
                return
              }

              if (res.statusCode && res.statusCode >= 400) {
                reject(new Error(`HTTP 错误 ${res.statusCode}`))
                return
              }

              let buf = ''
              res.setEncoding('utf8')
              res.on('data', (chunk) => buf += chunk)
              res.on('end', () => {
                // 如果响应为空但 Content-Length 显示非 0，还是交给上层处理（可能是服务器 HEAD/GET 行为差异）
                resolve(buf)
              })
            })

            req.on('error', (err) => reject(err))
            req.on('timeout', () => {
              req.destroy()
              reject(new Error('请求超时'))
            })
          }

          doGet(urlObj.toString())
        } catch (err) {
          reject(err)
        }
      })
    }

    // 保存缓存供调试
    try { saveCache(data) } catch (e) {}

    if (!data || data.trim().length === 0) throw new Error('远程返回内容为空，可能是需要鉴权或返回了空响应')

    // 解析 JSON：要求至少有 version 字段，下载链接可在不同位置（优先平台字段）
    let json
    try { json = JSON.parse(data) } catch (e) { throw new Error('JSON 解析失败: ' + e.message + '\n响应预览:' + data.slice(0, 200)) }

    const latestVersion = json.version || json.latest || json.tag || ''

    // 获取下载链接：优先检查 platforms/downloads 字段（按 process.platform），其次检查通用 url 字段
    let downloadUrl = ''

    // 1) 兼容旧结构：platforms
    if (json.platforms && typeof json.platforms === 'object') {
      const platformKey = process.platform
      downloadUrl = json.platforms[platformKey] || json.platforms[platformKey.replace('darwin', 'mac')] || json.platforms[platformKey.replace('win32', 'win')]
      if (!downloadUrl) {
        const p = json.platforms[platformKey] || json.platforms['win32'] || json.platforms['darwin'] || json.platforms['mac'] || json.platforms['win']
        if (p && typeof p === 'object') downloadUrl = p.url || p.download || p.downloadUrl || ''
      }
    }

    // 2) 兼容当前 latest.json：downloads
    if (!downloadUrl && json.downloads && typeof json.downloads === 'object') {
      if (process.platform === 'darwin') {
        downloadUrl = json.downloads.darwin || json.downloads.mac || json.downloads.macos || ''
      } else if (process.platform === 'win32') {
        // Windows 更新：只提供“浏览器下载”，默认优先便携版，其次安装版（安装版仅保留打包功能）
        downloadUrl = json.downloads['win-portable'] || json.downloads.winPortable || json.downloads.win32 || json.downloads.win || json.downloads['win-install'] || json.downloads.winInstall || ''
      } else {
        // 其他平台：尽力找一个通用字段
        downloadUrl = json.downloads[process.platform] || json.downloads.linux || ''
      }
    }

    // 3) 兜底：通用字段
    if (!downloadUrl) downloadUrl = json.url || json.download || json.downloadUrl || ''

    if (!latestVersion) {
      throw new Error('清单缺少版本字段：version')
    }

    // 尝试加载自定义更新图标
    let updateIcon = null
    try {
      // 尝试从当前目录(src)加载 update-icon.png
      const iconPath = path.join(__dirname, 'update-icon.png')
      if (fs.existsSync(iconPath)) {
        updateIcon = nativeImage.createFromPath(iconPath)
      }
    } catch (e) {
      // 忽略图标加载错误
    }

    const rel = cmp(latestVersion, currentVersion)
    if (rel > 0) {
      const isMac = process.platform === 'darwin'
      const isWin = process.platform === 'win32'

      const buttons = downloadUrl
        ? (isMac ? ['自动下载更新', '浏览器下载', '稍后'] : ['浏览器下载', '稍后'])
        : ['好的']

      const cancelId = downloadUrl
        ? (isMac ? 2 : 1)
        : 0

      const detailText = downloadUrl
        ? (isMac
          ? '点击“自动下载更新”后，将在后台下载更新包；下载完成后会自动解压、移除 macOS 隔离属性并提示重启完成更新。'
          : 'Windows 端暂不提供安装版自动更新：将通过浏览器下载便携版更新包；下载完成后请手动解压覆盖并重新打开应用。')
        : (json.notes || json.changelog || '暂无可用下载链接，请稍后重试。')

      const btn = await dialog.showMessageBox({
        type: 'question',
        title: '发现新版本',
        icon: updateIcon,
        message: `当前版本：${currentVersion}，最新版本：${latestVersion}`,
        detail: detailText,
        buttons,
        defaultId: 0,
        cancelId
      })

      if (downloadUrl) {
        if (isMac) {
          if (btn.response === 0) {
            // 自动下载（仅 macOS）
            downloadAndInstallUpdate(downloadUrl)
            return { status: 'downloading', currentVersion, latestVersion }
          } else if (btn.response === 1) {
            // 浏览器下载
            await shell.openExternal(downloadUrl)
            return { status: 'opened', currentVersion, latestVersion, updateUrl: downloadUrl }
          }
        } else {
          // Windows / 其他平台：只保留浏览器下载
          if (btn.response === 0) {
            await shell.openExternal(downloadUrl)
            return { status: 'opened', currentVersion, latestVersion, updateUrl: downloadUrl }
          }
        }
      }

      return { status: 'update-available', currentVersion, latestVersion, updateUrl: downloadUrl }
    }

    if (interactive) {
      await dialog.showMessageBox({
        type: 'info',
        title: '已是最新版本',
        icon: updateIcon,
        message: `当前版本：${currentVersion}`,
        detail: `最新版本：${latestVersion}`,
        buttons: ['好的']
      })
    }
    return { status: 'uptodate', currentVersion, latestVersion }
  } catch (e) {
    if (interactive) {
      await dialog.showMessageBox({
        type: 'error',
        title: '检查更新失败',
        message: '无法获取远程版本信息',
        detail: e.message,
        buttons: ['关闭']
      })
    } else {
      console.error('自动更新检查失败:', e.message)
    }
    return { status: 'error', error: e.message }
  }
}

// 注册 IPC 处理程序
ipcMain.handle('check-for-updates', async () => {
  return await checkForUpdates(true)
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
