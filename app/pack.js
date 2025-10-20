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
      'video-compare',
      // macOS 应用通常打包为 .app 格式，这里列出可能的依赖文件
      'libSDL2.dylib',
      'libSDL2_ttf.dylib'
    ],
    'linux': [
      'video-compare',
      'libSDL2.so',
      'libSDL2_ttf.so'
    ]
  };
  
  return platformFiles[platform] || platformFiles['win32'];
}

// 检查必要文件是否存在
function checkRequiredFiles(platform) {
  const innerDir = platform === 'win32' ? 'win-inner' : 'mac-inner';
  const requiredFiles = getRequiredFiles(platform);
  
  console.log(`检查${innerDir}目录下的必要文件是否存在...`);
  
  const missingFiles = [];
  requiredFiles.forEach(file => {
    if (!fs.existsSync(path.join(__dirname, innerDir, file))) {
      missingFiles.push(file);
    }
  });
  
  if (missingFiles.length > 0) {
    console.error(`以下必要文件缺失: ${missingFiles.join(', ')}`);
    console.log(`请将${platform}平台的视频比较工具放入${innerDir}目录`);
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
    execSync('npx electron-builder', { stdio: 'inherit' });
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