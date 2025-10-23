const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// 根据平台获取必要的文件列表
function getRequiredFiles(platform) {
  const platformFiles = {
    'win32': [
      'video-compare.exe'
    ],
    'darwin': [
      // 仅支持 .app Bundle，避免终端弹出
      'VideoCompare'
    ],
    'linux': [
      'video-compare'
    ]
  };
  
  return platformFiles[platform] || platformFiles['win32'];
}

// 检查必要文件是否存在
function checkRequiredFiles(platform) {
  const innerDir = platform === 'win32' ? 'win-inner' : (platform === 'linux' ? 'linux-inner' : 'mac-inner');
  const requiredFiles = getRequiredFiles(platform);
  
  console.log(`检查${innerDir}目录下的必要文件是否存在...`);
  
  const missingFiles = [];
  if (platform === 'darwin') {
    // 强制要求 .app Bundle
    const appBundleExists = fs.existsSync(path.join(__dirname, innerDir, 'VideoCompare'));
    if (!appBundleExists) {
      missingFiles.push('VideoCompare (.app 应用包)');
    }
  } else {
    requiredFiles.forEach(file => {
      if (!fs.existsSync(path.join(__dirname, innerDir, file))) {
        missingFiles.push(file);
      }
    });
  }
  
  if (missingFiles.length > 0) {
    console.error(`以下必要文件缺失: ${missingFiles.join(', ')}`);
    console.log(`请将${platform}平台的视频比较工具放入${innerDir}目录。macOS 请确保放置完整的 VideoCompare（例如：mac-inner/VideoCompare），并在打包配置中 asarUnpack。`);
    return false;
  }
  
  console.log(`所有${platform}平台必要文件都存在`);
  return true;
}

// 工具函数：安全删除
function safeRm(target) {
  try { fs.rmSync(target, { recursive: true, force: true }); } catch {}
}

// 工具函数：裁剪语言包 (.lproj)
function pruneLproj(dir, keepSet) {
  if (!fs.existsSync(dir)) return;
  for (const entry of fs.readdirSync(dir)) {
    if (entry.endsWith('.lproj') && !keepSet.has(entry)) {
      const p = path.join(dir, entry);
      safeRm(p);
      console.log(`[shrink] 删除语言目录: ${p}`);
    }
  }
}

// 工具函数：裁剪 Chromium locales
function pruneLocales(localesDir, keepPakSet) {
  if (!fs.existsSync(localesDir)) return;
  for (const f of fs.readdirSync(localesDir)) {
    if (f.endsWith('.pak') && !keepPakSet.has(f)) {
      const p = path.join(localesDir, f);
      safeRm(p);
      console.log(`[shrink] 删除locale: ${p}`);
    }
  }
}

// 工具函数：strip 二进制（忽略错误）
function tryStrip(binPath) {
  if (!fs.existsSync(binPath)) return;
  try {
    execSync(`strip -x "${binPath}"`);
    console.log(`[shrink] strip: ${binPath}`);
  } catch (e) {
    console.warn(`[shrink] strip 失败(可忽略): ${e.message}`);
  }
}

// macOS: 打包后精简 .app 体积（移除多余语言包、裁剪locales、删除crashpad/swiftshader、strip可执行、移除非mac资源/符号）
function shrinkMacApp(distDirRoot = path.join(process.cwd(), 'dist')) {
  try {
    // 识别输出子目录（mac、mac-arm64、mac-universal）
    const macDirs = ['mac-arm64', 'mac', 'mac-universal'];
    let appDir = null;
    for (const d of macDirs) {
      const candidate = path.join(distDirRoot, d);
      if (fs.existsSync(candidate)) {
        const items = fs.readdirSync(candidate);
        const appName = items.find(f => f.endsWith('.app'));
        if (appName) {
          appDir = path.join(candidate, appName);
          break;
        }
      }
    }
    if (!appDir) {
      console.warn('[shrink] 未找到 .app 目录，跳过精简');
      return;
    }

    const contentsDir = path.join(appDir, 'Contents');
    const resourcesDir = path.join(contentsDir, 'Resources');
    const frameworksDir = path.join(contentsDir, 'Frameworks');

    // 1) 移除多余 .lproj 语言目录，只保留英文与中文（主 Resources）
    const keepLproj = new Set(['en.lproj', 'zh.lproj', 'zh_CN.lproj', 'zh-Hans.lproj']);
    pruneLproj(resourcesDir, keepLproj);

    // 同步裁剪所有 Helper 应用中的 .lproj
    if (fs.existsSync(frameworksDir)) {
      for (const entry of fs.readdirSync(frameworksDir)) {
        if (entry.endsWith('.app')) {
          const helperRes = path.join(frameworksDir, entry, 'Contents', 'Resources');
          pruneLproj(helperRes, keepLproj);
        }
      }
    }

    // 2) 裁剪 locales 目录（Chromium 语言包）
    const keepPak = new Set(['en-US.pak', 'zh-CN.pak']);
    pruneLocales(path.join(resourcesDir, 'locales'), keepPak);
    if (fs.existsSync(frameworksDir)) {
      for (const entry of fs.readdirSync(frameworksDir)) {
        if (entry.endsWith('.app')) {
          pruneLocales(path.join(frameworksDir, entry, 'Contents', 'Resources', 'locales'), keepPak);
        }
      }
    }

    // 3) 删除非 mac 平台的 inner 目录（例如 win-inner、linux-inner），只保留 mac-inner
    const unpackedDir = path.join(resourcesDir, 'app.asar.unpacked');
    if (fs.existsSync(unpackedDir)) {
      for (const e of fs.readdirSync(unpackedDir)) {
        if (e !== 'mac-inner') {
          const p = path.join(unpackedDir, e);
          safeRm(p);
          console.log(`[shrink] 删除非 mac 目录: ${e}`);
        }
      }
    }

    // 4) 删除 crashpad_handler（崩溃上报进程，非必须）与 swiftshader（若存在）
    const crashpad = path.join(frameworksDir, 'Electron Framework.framework', 'Resources', 'crashpad_handler');
    if (fs.existsSync(crashpad)) { safeRm(crashpad); console.log('[shrink] 删除 crashpad_handler'); }
    const swiftshader1 = path.join(resourcesDir, 'swiftshader');
    const swiftshader2 = path.join(frameworksDir, 'Electron Framework.framework', 'Resources', 'swiftshader');
    if (fs.existsSync(swiftshader1)) { safeRm(swiftshader1); console.log('[shrink] 删除 Resources/swiftshader'); }
    if (fs.existsSync(swiftshader2)) { safeRm(swiftshader2); console.log('[shrink] 删除 Framework swiftshader'); }

    // 5) strip 自有 CLI 以及 Electron Helpers 可执行文件
    tryStrip(path.join(resourcesDir, 'app.asar.unpacked', 'mac-inner', 'video-compare'));
    // 主可执行
    tryStrip(path.join(contentsDir, 'MacOS', path.basename(appDir, '.app')));
    // Helper 可执行
    if (fs.existsSync(frameworksDir)) {
      for (const entry of fs.readdirSync(frameworksDir)) {
        if (entry.endsWith('.app')) {
          const helperBinDir = path.join(frameworksDir, entry, 'Contents', 'MacOS');
          for (const f of fs.readdirSync(helperBinDir)) {
            const binPath = path.join(helperBinDir, f);
            tryStrip(binPath);
          }
        }
      }
    }

    // 6) 删除 dSYMs 目录（位于 dist 根目录，非 .app 内，体积较大）
    for (const n of fs.readdirSync(distDirRoot)) {
      if (n.endsWith('.dSYM')) {
        const p = path.join(distDirRoot, n);
        safeRm(p);
        console.log(`[shrink] 删除 dSYM: ${n}`);
      }
    }

    // 7) 删除许可/示例等非必须文件（如存在）
    const candidates = [
      path.join(resourcesDir, 'LICENSE'),
      path.join(resourcesDir, 'LICENSES.chromium.html'),
      path.join(resourcesDir, 'version')
    ];
    for (const p of candidates) { if (fs.existsSync(p)) { safeRm(p); console.log(`[shrink] 删除冗余文件: ${p}`); } }

    console.log('[shrink] macOS 应用精简完成');
  } catch (err) {
    console.warn(`[shrink] 精简过程出现问题(可忽略): ${err.message}`);
  }
}

// 主函数
function main() {
  console.log('开始打包准备...');
  
  // 获取当前平台
  const platform = process.platform;
  console.log(`当前平台: ${platform}`);
  
  // 检查必要文件
  if (!checkRequiredFiles(platform)) {
    console.error('文件检查失败，打包中止');
    process.exit(1);
  }
  
  console.log('文件检查完成，开始使用electron-builder打包...');
  
  try {
    // 运行electron-builder打包
    // macOS 默认跳过签名，避免卡住；通过环境变量 MAC_SIGN=1 或 CSC_IDENTITY_AUTO_DISCOVERY=true 开启
    const signEnabled = (process.env.MAC_SIGN === '1') || (process.env.CSC_IDENTITY_AUTO_DISCOVERY === 'true');
    let cmd = 'npx electron-builder';
    // 仅构建 arm64（.app 体积由 shrinkMacApp 处理）
    if (platform === 'darwin') {
      cmd += ' --mac --arm64';
    }
    if (platform === 'darwin' && !signEnabled) {
      // 两种方式都设置，确保electron-builder不去自动发现签名证书
      process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'false';
      process.env.CSC_FOR_PULL_REQUEST = 'true'; // 明确告知跳过签名
      cmd += ' --config.mac.identity=null';
      console.log('[macOS] 已禁用签名，若需签名请设置环境变量 MAC_SIGN=1');
    }

    execSync(cmd, { stdio: 'inherit' });

    // 打包完成后，尝试精简 macOS 应用体积
    if (platform === 'darwin') {
      shrinkMacApp(path.join(process.cwd(), 'dist'));
    }

    console.log('打包完成！输出目录: dist/');
  } catch (error) {
    console.error('打包失败:', error.message);
    process.exit(1);
  }
}

// 执行主函数
if (require.main === module) {
  main();
}

module.exports = { checkRequiredFiles, getRequiredFiles };