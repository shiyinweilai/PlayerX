const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// 根据平台获取必要的文件列表
function getRequiredFiles(platform) {
  const platformFiles = {
    'win32': ['video-compare.exe'],
    'darwin': ['video-compare']
  };
  
  return platformFiles[platform] || platformFiles['win32'];
}

// 检查必要文件是否存在
function checkRequiredFiles(platform) {
  const innerDir = platform === 'win32' ? 'win-inner' : 'mac-inner';
  const requiredFiles = getRequiredFiles(platform);
  
  console.log(`检查${innerDir}目录下的必要文件是否存在...`);
  
  const missingFiles = [];
  if (platform === 'darwin') {
    const appBundleExists = fs.existsSync(path.join(__dirname, innerDir, 'video-compare'));
    if (!appBundleExists) {
      missingFiles.push('video-compare (.app 应用包)');
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
    console.log(`请将${platform}平台的视频比较工具放入${innerDir}目录。`);
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
  if (!platform) {
    console.error('错误：必须通过环境变量 PLATFORM 指定目标平台');
    console.error('使用方法：');
    console.error('  npm run pack:win    # Windows平台');
    console.error('  npm run pack:mac    # macOS平台');
    process.exit(1);
  }
  
  // 验证平台参数有效性
  const validPlatforms = ['win32', 'darwin'];
  if (!validPlatforms.includes(platform)) {
    console.error(`错误：无效的平台参数 "${platform}"`);
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
  
  try {
    // 设置环境变量来跳过签名（仅对macOS）
    const env = { ...process.env };
    if (platform === 'darwin') {
      env.CSC_IDENTITY_AUTO_DISCOVERY = 'false';
    }
    
    let cmd = 'npx electron-builder';
    if (platform === 'darwin') {
      cmd += ' --mac --arm64';
    }

    execSync(cmd, { stdio: 'inherit', env });

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