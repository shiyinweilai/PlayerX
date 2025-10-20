const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

// 检查video-compare-app目录下的必要文件是否存在
function checkRequiredFiles() {
  const requiredFiles = [
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
  ];
  
  console.log('检查video-compare-app目录下的必要文件是否存在...');
  
  const missingFiles = [];
  requiredFiles.forEach(file => {
    if (!fs.existsSync(path.join(__dirname, 'video-compare-app', file))) {
      missingFiles.push(file);
    }
  });
  
  if (missingFiles.length > 0) {
    console.error('以下必要文件缺失:', missingFiles.join(', '));
    return false;
  }
  
  console.log('所有必要文件都存在');
  return true;
}

// 主函数
function main() {
  console.log('开始打包准备...');
  
  // 检查必要文件
  if (!checkRequiredFiles()) {
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

module.exports = { checkRequiredFiles };