import { videoExtensions } from './constants.js';

export function isValidVideoFile(filePath) {
  if (!filePath || typeof filePath !== 'string') {
    console.log('无效的文件路径:', filePath)
    return false
  }
  
  // 检查是否为 URL (支持常见流媒体协议)
  if (filePath.match(/^(http|https|rtmp|rtsp|udp|tcp|ftp):\/\//i)) {
    console.log('检测到网络视频 URL:', filePath)
    return true
  }
  
  const ext = filePath.toLowerCase().substring(filePath.lastIndexOf('.')).toLowerCase()
  // console.log('文件扩展名:', ext)
  
  const isValid = videoExtensions.includes(ext)
  // console.log('文件是否有效:', isValid)
  
  return isValid
}