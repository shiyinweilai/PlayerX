const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// 根据平台获取必要的文件列表
function getRequiredFiles(platform) {
  const platformFiles = {
    'win32': [
      'video-compare.exe',
      'SDL2.dll',
      'SDL2_ttf.dll',
      'avcodec-61.dll',
      'avdevice-61.dll',
      'avfilter-10.dll',
      'avformat-61.dll',
      'avutil-59.dll',
      'swresample-5.dll',
      'swscale-8.dll'
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
    if (platform === 'darwin' && !signEnabled) {
      // 两种方式都设置，确保electron-builder不去自动发现签名证书
      process.env.CSC_IDENTITY_AUTO_DISCOVERY = 'false';
      process.env.CSC_FOR_PULL_REQUEST = 'true'; // 明确告知跳过签名
      cmd += ' --config.mac.identity=null';
      console.log('[macOS] 已禁用签名，若需签名请设置环境变量 MAC_SIGN=1');
    }

    execSync(cmd, { stdio: 'inherit' });
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