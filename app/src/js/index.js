import { isValidVideoFile } from './utils.js';
import * as UI from './ui.js';

document.addEventListener('DOMContentLoaded', function() {
  const fileList1 = document.getElementById('fileList1');
  const fileList2 = document.getElementById('fileList2');
  const runBtn = document.getElementById('runBtn');
  const modeSelect = document.getElementById('modeSelect');
  const urlConfirmBtn = document.getElementById('urlConfirmBtn');
  const urlCancelBtn = document.getElementById('urlCancelBtn');
  const urlModal = document.getElementById('urlModal');
  const urlInput = document.getElementById('urlInput');
  const urlFileInput = document.getElementById('urlFileInput');

  // 面板模式状态
  const panelModes = { 1: 'local', 2: 'local' };

  let file1Path = null;
  let file2Path = null;
  let files1 = [];
  let files2 = [];
  let selectedMode = 'hstack'; // 默认模式
  let currentImportPanelIndex = 1;
  let currentUrlPanelIndex = 1;

  // 初始化 Tab 切换逻辑
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const panelIndex = parseInt(btn.dataset.panel);
      const mode = btn.dataset.mode;
      
      // 更新 Tab 样式
      const tabs = btn.parentElement.querySelectorAll('.tab-btn');
      tabs.forEach(t => t.classList.remove('active'));
      btn.classList.add('active');
      
      // 更新模式
      panelModes[panelIndex] = mode;
      
      // 清空当前选择（切换模式时重置）
      if (panelIndex === 1) {
        file1Path = null;
        files1 = [];
        UI.renderFileList(fileList1, [], 1, selectFile);
        UI.setVideoFileUI(1, null);
      } else {
        file2Path = null;
        files2 = [];
        UI.renderFileList(fileList2, [], 2, selectFile);
        UI.setVideoFileUI(2, null);
      }
      
      updateRunButton();
      UI.updatePanelUI(panelIndex, mode);
    });
  });

  // 绑定导入按钮事件
  [1, 2].forEach(idx => {
    document.getElementById(`importBtn${idx}`).addEventListener('click', (e) => {
      e.stopPropagation();
      currentImportPanelIndex = idx;
      urlFileInput.value = '';
      urlFileInput.click();
    });
  });

  // 处理文件选择
  urlFileInput.addEventListener('change', (e) => {
    const file = e.target.files[0];
    if (!file) return;

    const reader = new FileReader();
    reader.onload = (event) => {
      const content = event.target.result;
      // 提取 URL (支持 http, https, rtmp, rtsp, udp, tcp, ftp)
      // 排除末尾可能的标点符号或引号
      const urlRegex = /(?:https?|rtmp|rtsp|udp|tcp|ftp):\/\/[^\s"';,<>]+/gi;
      const urls = content.match(urlRegex);
      
      if (urls && urls.length > 0) {
        // 去重
        const uniqueUrls = [...new Set(urls)];
        console.log(`从文件中提取到 ${uniqueUrls.length} 个 URL`);
        handleFiles(uniqueUrls, currentImportPanelIndex);
      } else {
        UI.showOutput('❌ 未在文件中找到有效的视频 URL', 'error');
      }
    };
    reader.onerror = () => {
      UI.showOutput('❌ 读取文件失败', 'error');
    };
    reader.readAsText(file);
  });

  function updateRunButton() {
    runBtn.disabled = !(file1Path && file2Path);
  }

  function handleUrlSubmit() {
    const inputVal = UI.getUrlInputValue();
    if (inputVal) {
      // 支持分号(中英文)分隔多个 URL
      const urls = inputVal.split(/;|；/).map(u => u.trim()).filter(u => u.length > 0);
      if (urls.length > 0) {
        handleFiles(urls, currentUrlPanelIndex);
      }
    }
    UI.hideUrlModal();
  }

  urlConfirmBtn.onclick = handleUrlSubmit;
  urlCancelBtn.onclick = UI.hideUrlModal;
  
  urlModal.onclick = (e) => {
    if (e.target === urlModal) UI.hideUrlModal();
  };

  urlInput.onkeydown = (e) => {
    if (e.key === 'Enter') handleUrlSubmit();
    if (e.key === 'Escape') UI.hideUrlModal();
  };

  function inputUrl(panelIndex) {
    currentUrlPanelIndex = panelIndex;
    UI.showUrlModal(panelIndex);
  }

  // 绑定点击事件
  [1, 2].forEach(idx => {
    const videoInfo = document.getElementById(`videoInfo${idx}`);
    videoInfo.addEventListener('click', (e) => {
      if (e.target.closest('.url-trigger') || e.target.closest('.import-trigger')) return;
      if (panelModes[idx] === 'local') {
        openFilesAndHandle(idx);
      } else {
        inputUrl(idx);
      }
    });
  });

  // 新增：探测视频信息
  async function probeVideoInfo(filePath, panelIndex) {
    try {
      console.log(`开始探测视频信息: 面板${panelIndex}, 文件: ${filePath}`);
      
      // 更新状态显示
      UI.setProbeStatus(panelIndex, '探测中...');
      
      const videoInfo = await window.api.probeVideoInfo(filePath);
      console.log('视频信息探测结果:', videoInfo);
      
      // 格式化并显示视频信息
      UI.displayVideoInfo(videoInfo, panelIndex);
      
    } catch (error) {
      console.error(`视频信息探测失败:`, error);
      
      // 显示错误信息
      UI.displayVideoInfoError(panelIndex);
      
      // 在输出框中显示错误
      UI.showOutput(`❌ 视频信息探测失败: ${error}`, 'error');
    }
  }

  function selectFile(filePath, panelIndex) {
    console.log(`选择文件: 面板${panelIndex}, 路径: ${filePath}`);
    
    if (panelIndex === 1) {
      file1Path = filePath;
      UI.updateFileListSelection(fileList1, filePath);
      UI.setVideoFileUI(1, filePath);
      if (filePath) probeVideoInfo(filePath, 1);
    } else {
      file2Path = filePath;
      UI.updateFileListSelection(fileList2, filePath);
      UI.setVideoFileUI(2, filePath);
      if (filePath) probeVideoInfo(filePath, 2);
    }
    
    updateRunButton();
  }

  function handleFiles(filePaths, panelIndex) {
    console.log(`处理文件: 面板${panelIndex}, 文件数量: ${filePaths.length}`);
    console.log('文件路径列表:', filePaths);
    
    const videoFiles = [];
    const invalidFiles = [];
    
    for (const filePath of filePaths) {
      console.log('检查文件:', filePath);
      if (isValidVideoFile(filePath)) {
        console.log(`有效视频文件: ${filePath}`);
        videoFiles.push(filePath);
      } else {
        console.log(`无效文件(非视频): ${filePath}`);
        invalidFiles.push(filePath);
      }
    }
    
    console.log(`找到 ${videoFiles.length} 个视频文件，${invalidFiles.length} 个无效文件`);
    
    if (panelIndex === 1) {
      files1 = [...new Set([...files1, ...videoFiles])];
      UI.renderFileList(fileList1, files1, 1, selectFile);
      if (files1.length > 0 && !file1Path) {
        selectFile(files1[0], 1);
      }
    } else {
      files2 = [...new Set([...files2, ...videoFiles])];
      UI.renderFileList(fileList2, files2, 2, selectFile);
      if (files2.length > 0 && !file2Path) {
        selectFile(files2[0], 2);
      }
    }
    
    if (videoFiles.length > 0) {
      UI.showOutput(`已添加 ${videoFiles.length} 个视频文件`, 'success');
    } else {
      // 这里需要 videoExtensions，但它在 constants 里。
      // 为了简单，这里不显示具体扩展名，或者从 utils 导入
      UI.showOutput(`未检测到有效的视频文件。`, 'error');
    }
  }

  // 拖拽支持
  function setupDragDrop(panel, panelIndex) {
    // 拖拽进入
    panel.addEventListener('dragenter', (e) => {
      e.preventDefault();
      e.stopPropagation();
      panel.classList.add('drag-over');
    });

    // 拖拽悬停
    panel.addEventListener('dragover', (e) => {
      e.preventDefault();
      e.stopPropagation();
      panel.classList.add('drag-over');
      e.dataTransfer.dropEffect = 'copy';
    });

    // 拖拽离开
    panel.addEventListener('dragleave', (e) => {
      e.preventDefault();
      e.stopPropagation();
      // 只有当鼠标真正离开 panel 时才移除样式
      if (!panel.contains(e.relatedTarget)) {
        panel.classList.remove('drag-over');
      }
    });

    // 放置处理
    panel.addEventListener('drop', (e) => {
      e.preventDefault();
      e.stopPropagation();
      panel.classList.remove('drag-over');
      
      // 如果当前是 URL 模式，自动切换到本地模式
      if (panelModes[panelIndex] === 'url') {
        console.log(`检测到拖拽操作，自动切换面板 ${panelIndex} 到本地模式`);
        const tabBtn = panel.querySelector('.tab-btn[data-mode="local"]');
        if (tabBtn) tabBtn.click();
      }

      const files = [];
      if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
        for (let i = 0; i < e.dataTransfer.files.length; i++) {
          const file = e.dataTransfer.files[i];
          // 尝试通过 API 获取路径（Electron 安全策略限制直接访问 path）
          const path = window.api && window.api.getFilePath ? window.api.getFilePath(file) : file.path;
          if (path) {
            files.push(path);
          }
        }
      }
      
      if (files.length > 0) {
        handleFiles(files, panelIndex);
      } else {
        UI.showOutput('❌ 拖拽无效：无法获取文件路径或未检测到文件。请尝试点击选择。', 'error');
        console.error('未检测到有效的文件路径');
      }
    });
  }

  const panel1 = document.querySelector('.video-panel.left');
  const panel2 = document.querySelector('.video-panel.right');
  setupDragDrop(panel1, 1);
  setupDragDrop(panel2, 2);

  // 封装文件选择逻辑
  async function openFilesAndHandle(panelIndex) {
    try {
      const files = await window.api.openFiles();
      if (files && files.length > 0) {
        handleFiles(files, panelIndex);
      }
    } catch (error) {
      console.error('选择文件失败:', error);
      UI.showOutput('选择文件失败: ' + error.message, 'error');
    }
  }

  // 菜单事件绑定
  if (window.menu && typeof window.menu.onSelectLeft === 'function') {
    window.menu.onSelectLeft(() => {
      openFilesAndHandle(1);
    });
  }
  if (window.menu && typeof window.menu.onSelectRight === 'function') {
    window.menu.onSelectRight(() => {
      openFilesAndHandle(2);
    });
  }

  // 绑定“检查更新…”菜单事件
  if (window.menu && typeof window.menu.onCheckUpdate === 'function') {
    window.menu.onCheckUpdate(async () => {
      UI.showOutput('正在检查更新...', 'running');
      try {
        const res = await window.api.checkForUpdates();
        let msg = '';
        let type = 'success';
        switch (res.status) {
          case 'opened':
            msg = `已打开下载页面：${res.updateUrl || ''}`;
            break;
          case 'update-available':
            msg = `发现新版本：${res.latestVersion}，请点击“帮助 > 检查更新”弹窗中的前往下载按钮，或稍后手动更新。`;
            break;
          case 'uptodate':
            msg = `已是最新版本：当前 ${res.currentVersion}，远端 ${res.latestVersion}`;
            break;
          case 'no-source':
            msg = '未配置更新源：请设置环境变量 UPDATE_JSON_URL 指向远程版本清单（latest.json）';
            type = 'error';
            break;
          case 'error':
            msg = `检查更新失败：${res.error || '未知错误'}`;
            type = 'error';
            break;
          default:
            msg = `未知状态：${res.status}`;
            type = 'error';
        }
        UI.showOutput(msg, type);
      } catch (e) {
        UI.showOutput('检查更新失败：' + e, 'error');
      }
    });
  }

  runBtn.onclick = async () => {
    if (!file1Path || !file2Path) {
      UI.showOutput('请先选择两个视频文件', 'error');
      return;
    }

    // 获取当前选择的模式
    selectedMode = modeSelect.value;
    
    // 获取自定义参数
    const customInput = document.getElementById('customInput').value.trim();
    
    console.log('开始对比，模式:', selectedMode);
    console.log('文件1:', file1Path);
    console.log('文件2:', file2Path);
    console.log('自定义参数:', customInput);
    
    // 检查是否包含 URL
    const isUrl = (path) => path && path.match(/^(http|https|rtmp|rtsp|udp|tcp|ftp):\/\//i);
    const hasUrl = isUrl(file1Path) || isUrl(file2Path);
    
    if (hasUrl) {
      UI.showOutput('正在启动视频对比工具 (检测到网络视频，正在缓冲，请耐心等待)...', 'running');
      UI.showLoadingModal(true);
    } else {
      UI.showOutput('正在启动视频对比工具...', 'running');
    }
    
    runBtn.disabled = true;
    
    // 给UI一点时间渲染
    await new Promise(resolve => setTimeout(resolve, 100));

    let isSuccess = false;
    try {
      const result = await window.api.runExe(file1Path, file2Path, selectedMode, customInput);
      console.log('启动结果:', result);
      UI.showOutput('✅ ' + result, 'success');
      isSuccess = true;
    } catch (e) {
      console.error('启动失败:', e);
      UI.showOutput('❌ ' + e, 'error');
    } finally {
      runBtn.disabled = false;
      if (hasUrl && isSuccess) {
        // URL 模式下延迟关闭，给 video-compare 缓冲的时间
        setTimeout(() => {
          UI.showLoadingModal(false);
        }, 10000);
      } else {
        UI.showLoadingModal(false);
      }
    }
  };

  // 监听可执行文件日志
  window.api.onExeLog((data) => {
    console.log('收到日志:', data);
    const timestamp = new Date().toLocaleTimeString();
    const prefix = data.type === 'stderr' ? '[错误] ' : data.type === 'close' ? '[结束] ' : '';
    const logEntry = `[${timestamp}] ${prefix}${data.message}\n`;
    
    UI.appendOutput(logEntry, data.type);
  });

  // 初始化状态
  fileList1.style.display = 'none';
  fileList2.style.display = 'none';
  updateRunButton();
});