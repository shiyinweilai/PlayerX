const { app, BrowserWindow, ipcMain, dialog, Menu, shell } = require('electron')
const path = require('path')
const fs = require('fs')
const os = require('os')
const https = require('https')
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
      exePath = path.resolve(__dirname, '..', exeDirName, exeName)
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
    ffprobePath = path.resolve(__dirname, '..', ffprobeDirName, ffprobeName)
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
// 增强：支持拉取远程版本JSON进行对比（UPDATE_JSON_URL 优先；若 UPDATE_URL 以 .json 结尾也视为清单），并按平台选择下载链接
ipcMain.handle('check-for-updates', async () => {
  const currentVersion = app.getVersion()
  // 优先使用环境变量，可在本地或打包环境通过环境变量注入清单地址或自定义头
  const defaultManifest = "https://tvp-76917.gzc.vod.tencent-cloud.com/rbyang/PlayerX/latest.json"
  const manifestUrl = process.env.UPDATE_JSON_URL || defaultManifest
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
    await dialog.showMessageBox({
      type: 'info',
      title: '检查更新',
      message: `当前版本：${currentVersion}`,
      detail: '未配置更新源。请设置环境变量 UPDATE_JSON_URL 指向版本清单 JSON\n例如：UPDATE_JSON_URL=https://your-domain.com/playerx/latest.json',
      buttons: ['我知道了']
    })
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
n
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

    // 获取下载链接：优先检查 platforms 字段（按 process.platform），其次检查通用 url 字段
    let downloadUrl = ''
    if (json.platforms && typeof json.platforms === 'object') {
      const platformKey = process.platform
      downloadUrl = json.platforms[platformKey] || json.platforms[platformKey.replace('darwin', 'mac')] || json.platforms[platformKey.replace('win32', 'win')]
      if (!downloadUrl) {
        const p = json.platforms[platformKey] || json.platforms['win32'] || json.platforms['darwin'] || json.platforms['mac'] || json.platforms['win']
        if (p && typeof p === 'object') downloadUrl = p.url || p.download || p.downloadUrl || ''
      }
    }
    if (!downloadUrl) downloadUrl = json.url || json.download || json.downloadUrl || ''

    if (!latestVersion) {
      throw new Error('清单缺少版本字段：version')
    }

    const rel = cmp(latestVersion, currentVersion)
    if (rel > 0) {
      const btn = await dialog.showMessageBox({
        type: 'info',
        title: '发现新版本',
        message: `当前版本：${currentVersion}，最新版本：${latestVersion}`,
        detail: (json.notes || json.changelog || '是否前往下载新版本？'),
        buttons: downloadUrl ? ['前往下载', '稍后'] : ['好的'],
        defaultId: 0,
        cancelId: 1
      })
      if (downloadUrl && btn.response === 0) {
        await shell.openExternal(downloadUrl)
        return { status: 'opened', currentVersion, latestVersion, updateUrl: downloadUrl }
      }
      return { status: 'update-available', currentVersion, latestVersion, updateUrl: downloadUrl }
    }

    await dialog.showMessageBox({
      type: 'info',
      title: '已是最新版本',
      message: `当前版本：${currentVersion}`,
      detail: `最新版本：${latestVersion}`,
      buttons: ['好的']
    })
    return { status: 'uptodate', currentVersion, latestVersion }
  } catch (e) {
    await dialog.showMessageBox({
      type: 'error',
      title: '检查更新失败',
      message: '无法获取远程版本信息',
      detail: e.message,
      buttons: ['关闭']
    })
    return { status: 'error', error: e.message }
  }
})

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit()
})
