import { ICONS } from './constants.js';

const getEl = (id) => document.getElementById(id);

export function updatePanelUI(panelIndex, mode) {
  const videoNameElement = getEl(panelIndex === 1 ? 'videoName1' : 'videoName2');
  const videoInfoElement = getEl(panelIndex === 1 ? 'videoInfo1' : 'videoInfo2');
  
  // 更新模式 class
  videoInfoElement.classList.remove('mode-local', 'mode-url');
  videoInfoElement.classList.add('mode-' + mode);
  
  // 如果当前没有文件，更新提示文字和图标
  if (!videoInfoElement.classList.contains('has-file')) {
    videoNameElement.textContent = mode === 'local' ? '点击选择或拖拽（本地）视频到此处' : '点击输入网络视频 URL';
    const iconContainer = videoInfoElement.querySelector('.upload-icon');
    if (iconContainer) iconContainer.innerHTML = ICONS[mode];
  }
}

export function resetVideoDetails(panelIndex) {
  const suffix = panelIndex === 1 ? '1' : '2';
  const fields = ['duration', 'size', 'format', 'resolution', 'videoCodec', 'audioCodec', 'pixelFormat', 'colorSpace'];
  fields.forEach(field => {
    const el = getEl(`${field}${suffix}`);
    if (el) el.textContent = '-';
  });
}

export function setVideoFileUI(panelIndex, filePath) {
  const videoNameElement = getEl(panelIndex === 1 ? 'videoName1' : 'videoName2');
  const videoInfoElement = getEl(panelIndex === 1 ? 'videoInfo1' : 'videoInfo2');
  const videoDetailsElement = getEl(panelIndex === 1 ? 'videoDetails1' : 'videoDetails2');
  
  if (filePath) {
    // 提取文件名（去除路径）
    const fileName = filePath.split('/').pop() || filePath.split('\\').pop() || filePath;
    videoNameElement.textContent = fileName;
    videoNameElement.title = filePath; // 添加完整路径提示
    videoInfoElement.classList.remove('empty');
    videoInfoElement.classList.add('has-file');
    
    // 显示详细视频信息区域
    videoDetailsElement.classList.add('show');
  } else {
    videoNameElement.textContent = '点击选择或拖拽（本地）视频到此处';
    videoNameElement.title = '';
    videoInfoElement.classList.add('empty');
    videoInfoElement.classList.remove('has-file');
    
    // 隐藏详细视频信息区域
    videoDetailsElement.classList.remove('show');
    
    // 重置详细视频信息
    resetVideoDetails(panelIndex);
  }
}

export function displayVideoInfo(videoInfo, panelIndex) {
  const suffix = panelIndex === 1 ? '1' : '2';
  
  // 格式化时长（秒转分钟:秒）
  let durationText = '-';
  if (videoInfo.duration && videoInfo.duration !== '未知') {
    const duration = parseFloat(videoInfo.duration);
    if (!isNaN(duration)) {
      const minutes = Math.floor(duration / 60);
      const seconds = Math.floor(duration % 60);
      durationText = `${minutes}:${seconds.toString().padStart(2, '0')}`;
    }
  }
  
  // 格式化文件大小（字节转MB）
  let sizeText = '-';
  if (videoInfo.size && videoInfo.size !== '未知') {
    const size = parseInt(videoInfo.size);
    if (!isNaN(size)) {
      sizeText = (size / (1024 * 1024)).toFixed(2) + ' MB';
    }
  }
  
  // 获取视频流信息
  let resolution = '-';
  let videoCodec = '-';
  let audioCodec = '-';
  let pixelFormat = '-';
  let colorSpace = '-';
  
  if (videoInfo.videoStreams && videoInfo.videoStreams.length > 0) {
    const videoStream = videoInfo.videoStreams[0];
    resolution = videoStream.resolution;
    videoCodec = videoStream.codec;
    pixelFormat = videoStream.pixelFormat || '-';
    colorSpace = videoStream.colorSpace || '-';
  }
  
  if (videoInfo.audioStreams && videoInfo.audioStreams.length > 0) {
    const audioStream = videoInfo.audioStreams[0];
    audioCodec = audioStream.codec;
  }
  
  // 更新显示
  const updates = {
    duration: durationText,
    size: sizeText,
    format: videoInfo.format || '-',
    resolution: resolution,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    pixelFormat: pixelFormat,
    colorSpace: colorSpace
  };
  
  for (const [key, value] of Object.entries(updates)) {
    const el = getEl(`${key}${suffix}`);
    if (el) el.textContent = value;
  }
  
  console.log(`面板${panelIndex}视频信息显示完成`);
}

export function displayVideoInfoError(panelIndex) {
  const suffix = panelIndex === 1 ? '1' : '2';
  const fields = ['duration', 'size', 'format', 'resolution', 'videoCodec', 'audioCodec', 'pixelFormat', 'colorSpace'];
  fields.forEach(field => {
    const el = getEl(`${field}${suffix}`);
    if (el) el.textContent = '探测失败';
  });
}

export function setProbeStatus(panelIndex, status) {
  const suffix = panelIndex === 1 ? '1' : '2';
  const elDuration = getEl(`duration${suffix}`);
  const elSize = getEl(`size${suffix}`);
  if (elDuration) elDuration.textContent = status;
  if (elSize) elSize.textContent = status;
}

export function renderFileList(fileListElement, files, panelIndex, onSelectFile) {
  fileListElement.innerHTML = '';
  
  if (files.length === 0) {
    fileListElement.style.display = 'none';
    return;
  }
  
  fileListElement.style.display = 'block';
  
  files.forEach((file, index) => {
    const fileItem = document.createElement('div');
    fileItem.className = 'file-item';
    fileItem.innerHTML = `<span class="selected-file-path">${file}</span>`;
    fileItem.onclick = (e) => {
      e.stopPropagation();
      onSelectFile(file, panelIndex);
    };
    fileListElement.appendChild(fileItem);
  });
}

export function updateFileListSelection(fileListElement, selectedFilePath) {
  Array.from(fileListElement.children).forEach((item) => {
    const pathSpan = item.querySelector('.selected-file-path');
    const path = pathSpan ? pathSpan.textContent : '';
    item.classList.toggle('selected', path === selectedFilePath);
  });
}

// Modal related
const urlModal = getEl('urlModal');
const urlInput = getEl('urlInput');

export function showUrlModal(panelIndex) {
  urlInput.value = '';
  urlModal.classList.add('show');
  setTimeout(() => urlInput.focus(), 50);
}

export function hideUrlModal() {
  urlModal.classList.remove('show');
}

export function getUrlInputValue() {
  return urlInput.value.trim();
}

export function showOutput(message, type = 'normal') {
  const output = getEl('output');
  output.textContent = message;
  if (type === 'error') output.className = 'output-box error';
  else if (type === 'success') output.className = 'output-box success';
  else if (type === 'running') output.className = 'output-box running';
  else output.className = 'output-box';
}

export function appendOutput(message, type) {
  const output = getEl('output');
  output.textContent += message;
  output.scrollTop = output.scrollHeight;
  
  if (type === 'stderr') {
    output.className = 'output-box error';
  } else if (type === 'close') {
    output.className = message.includes('代码: 0') ? 'output-box success' : 'output-box error';
  } else {
    output.className = 'output-box running';
  }
}

export function showLoadingModal(show) {
  const loadingModal = getEl('loadingModal');
  if (show) loadingModal.classList.add('show');
  else loadingModal.classList.remove('show');
}