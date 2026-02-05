const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// 根据平台获取必要的文件列表
function getRequiredFiles(platform) {
  const platformFiles = {
    'win32': ['video-compare.exe', 'ffprobe.exe'],
    'darwin': ['video-compare', 'ffprobe']
  };
  
  return platformFiles[platform] || platformFiles['win32'];
}

// 检查必要文件是否存在
function checkRequiredFiles(platform) {
  const innerDir = platform === 'win32' ? 'win-inner' : 'mac-inner';
  const requiredFiles = getRequiredFiles(platform);
  
  // 修正路径：文件现在位于 src/external 下
  const externalDir = path.join(__dirname, 'src', 'external', innerDir);
  
  console.log(`检查${innerDir}目录下的必要文件是否存在...`);
  
  const missingFiles = [];
  if (platform === 'darwin') {
    const appBundleExists = fs.existsSync(path.join(externalDir, 'video-compare'));
    if (!appBundleExists) {
      missingFiles.push('video-compare (.app 应用包)');
    }
  } else {
    requiredFiles.forEach(file => {
      if (!fs.existsSync(path.join(externalDir, file))) {
        missingFiles.push(file);
      }
    });
  }
  
  if (missingFiles.length > 0) {
    console.error(`以下必要文件缺失: ${missingFiles.join(', ')}`);
    console.log(`请将${platform}平台的视频比较工具放入 src/external/${innerDir} 目录。`);
    return false;
  }
  
  console.log(`所有${platform}平台必要文件都存在`);
  return true;
}

// 工具函数：安全删除
function safeRm(target) {
  try { fs.rmSync(target, { recursive: true, force: true }); } catch {}
}

// 主函数
function main() {
  console.log('开始打包准备...');
  
  // 获取平台参数（必须通过环境变量指定）
  const platform = process.env.PLATFORM;
  const isPortable = process.env.PORTABLE === 'true';
  
  if (!platform) {
    console.error('错误：必须通过环境变量 PLATFORM 指定目标平台');
    console.error('使用方法：');
    console.error('  npm run pack:win    # Windows平台');
    console.error('  npm run pack:mac    # macOS平台');
    console.error('  npm run pack:win:portable    # Windows便携版');
    console.error('  npm run pack:mac:portable    # macOS便携版');
    process.exit(1);
  }
  
  if (isPortable) {
    console.log('打包模式：便携版（独立运行，无需安装）');
  } else {
    console.log('打包模式：安装版');
  }
  
  // 验证平台参数有效性
  const validPlatforms = ['win32', 'darwin'];
  if (!validPlatforms.includes(platform)) {
    console.error(`错误：无效的平台参数 \"${platform}\"`);
    console.error(`有效平台：${validPlatforms.join(', ')}`);
    process.exit(1);
  }
  
  console.log(`目标平台: ${platform}`);
  
  // 检查必要文件
  if (!checkRequiredFiles(platform)) {
    console.error('文件检查失败，打包中止');
    process.exit(1);
  }
  
  console.log('文件检查完成，开始使用electron-builder打包...');
  
  // 生成临时 electron-builder 配置，确保资源打入包并为 mac 启用签名/硬化
  const isMac = platform === 'darwin'
  const builderConfig = {
    appId: 'com.playerx.app',
    productName: 'Player X',
    asar: true,
    // 排除 src/external，避免打入 asar
    files: ['**/*', '!dist/**', '!src/external/**'],
    // 使用 extraResources 将外部文件复制到 Resources 目录
    extraResources: isMac
      ? [{ from: 'src/external/mac-inner', to: 'mac-inner' }]
      : [{ from: 'src/external/win-inner', to: 'win-inner' }],
    mac: {
      icon: 'src/update-icon.png',
      hardenedRuntime: false,
      gatekeeperAssess: false,
      category: 'public.app-category.video',
      // 便携版：直接生成.app文件；安装版：生成zip和dmg
      target: isPortable 
        ? [{ target: 'dir', arch: ['arm64'] }]
        : [
            { target: 'zip', arch: ['arm64'] },
            { target: 'dmg', arch: ['arm64'] }
          ]
    },
    win: {
      // 便携版：生成portable版本；安装版：生成nsis安装包
      target: isPortable ? 'portable' : 'nsis',
      executableName: 'PlayerX'
    },
    nsis: {
      oneClick: false,
      allowToChangeInstallationDirectory: true,
      allowElevation: true,
      createDesktopShortcut: true,
      createStartMenuShortcut: true,
      shortcutName: 'PlayerX',
      menuCategory: 'Video Tools',
      runAfterFinish: true,
      deleteAppDataOnUninstall: false
    },
    portable: {
      artifactName: '${productName}-${version}-portable.${ext}'
    },
    dmg: { sign: false }
  };
  const cfgPath = path.join(__dirname, 'electron-builder.temp.json');
  fs.writeFileSync(cfgPath, JSON.stringify(builderConfig, null, 2));

  try {
    // 允许自动发现证书：不要强行禁用（之前会导致未签名）
    const env = { ...process.env };
    // 如果你设置了 APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID，electron-builder 将自动签名 & 公证
    // 若未设置，将尝试本地钥匙串中的 Developer ID 证书；若也没有，将生成未签名包（仍可本地测试）。
    
    // 私下分发：明确关闭自动证书发现，避免打包过程尝试签名
    if (platform === 'darwin') {
      env.CSC_IDENTITY_AUTO_DISCOVERY = 'false'
    }

    let cmd = `npx electron-builder -c "${cfgPath}"`;
    if (platform === 'darwin') {
      cmd += ' --mac --arm64';
    } else if (platform === 'win32') {
      cmd += ' --win --x64';
    }

    execSync(cmd, { stdio: 'inherit', env });

    const dist_dir = path.join(__dirname, 'dist');
    console.log('打包完成！输出目录: ', dist_dir);
  } catch (error) {
    console.error('打包失败:', error.message);
    process.exit(1);
  } finally {
    // 清理临时配置文件
    try { fs.unlinkSync(cfgPath); } catch {}
  }
}

// 执行主函数
if (require.main === module) {
  main();
}

module.exports = { checkRequiredFiles, getRequiredFiles };