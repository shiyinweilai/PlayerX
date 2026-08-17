const fs = require('fs');
const path = require('path');

const { listAll } = require('../lib/store');
const { CONFIGS_DIR } = require('../lib/paths');

const ACTIVE_CONFIG_FILE = path.join(CONFIGS_DIR, '_active.json');

function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
}

function readJsonSafe(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (_) {
    return fallback;
  }
}

function normalizeBindings(obj) {
  if (!obj || typeof obj !== 'object') return {};
  const raw = obj.bindings && typeof obj.bindings === 'object' ? obj.bindings : {};
  const out = {};
  for (const [mode, val] of Object.entries(raw)) {
    const arr = Array.isArray(val) ? val : (val ? [val] : []);
    out[mode] = arr.filter(Boolean).map(v => String(v));
  }
  return out;
}

function readActiveBindings() {
  const obj = readJsonSafe(ACTIVE_CONFIG_FILE, {});
  return normalizeBindings(obj);
}

function uniq(arr) {
  return [...new Set((arr || []).filter(Boolean))];
}

function extractMembers(cfg) {
  const groups = cfg && cfg.testSource && cfg.testSource.groups;
  if (!groups || typeof groups !== 'object') return [];
  const members = [];
  for (const list of Object.values(groups)) {
    if (Array.isArray(list)) {
      for (const u of list) if (u) members.push(String(u));
    }
  }
  return uniq(members);
}

function modeLabel(mode) {
  const map = {
    multi_dim: '多维评分',
    subjective: '主观评分',
    quality: '质量比较',
    quality_slide: '质量比较2',
    test: '测试模式',
  };
  return map[mode] || mode;
}

function safePercent(a, b) {
  if (!b) return 0;
  return Math.round((a / b) * 1000) / 10;
}

function handle(_req, res) {
  setCors(res);
  try {
    if (!fs.existsSync(CONFIGS_DIR)) {
      return res.json({ ok: true, data: { summary: {}, tags: [], tasks: [] } });
    }

    const bindings = readActiveBindings(); // { mode: [configName] }
    const allItems = listAll(); // 上传评分文件

    const tasks = [];

    for (const [mode, names] of Object.entries(bindings)) {
      const uniqueNames = uniq(names);
      for (const name of uniqueNames) {
        const file = path.join(CONFIGS_DIR, `${name}.json`);
        if (!fs.existsSync(file)) continue;
        const cfg = readJsonSafe(file, {});

        const tag = String((cfg && (cfg.tag || (cfg.build && cfg.build.tag))) || '').trim() || '未设置';
        const members = extractMembers(cfg);
        const expectedCount = members.length;

        const files = allItems.filter(it => (it.mode || '') === mode && (it.tag || '') === tag);
        const submittedUsers = uniq(files.map(it => it.user));
        // 完成率只统计配置成员中已提交的人数
        const submittedMembers = members.filter(u => submittedUsers.includes(u));
        const missingUsers = members.filter(u => !submittedUsers.includes(u));

        tasks.push({
          mode,
          modeLabel: modeLabel(mode),
          configName: name,
          tag,
          taskName: (cfg && (cfg.task || cfg.type)) || name,
          members,
          expectedCount,
          submittedUsers,
          submittedCount: submittedMembers.length,
          missingUsers,
          fileCount: files.length,
          latestMtime: files.length ? files[0].mtime : null,
        });
      }
    }

    const tagMap = new Map();
    for (const t of tasks) {
      if (!tagMap.has(t.tag)) {
        tagMap.set(t.tag, {
          tag: t.tag,
          expectedCount: 0,
          submittedCount: 0,
          fileCount: 0,
          missingUsers: [],
          tasks: [],
        });
      }
      const row = tagMap.get(t.tag);
      row.expectedCount += t.expectedCount;
      row.submittedCount += t.submittedCount;
      row.fileCount += t.fileCount;
      row.tasks.push({
        mode: t.mode,
        modeLabel: t.modeLabel,
        configName: t.configName,
        expectedCount: t.expectedCount,
        submittedCount: t.submittedCount,
        missingUsers: t.missingUsers,
      });
      row.missingUsers = uniq([...row.missingUsers, ...t.missingUsers]);
    }

    const tags = [...tagMap.values()]
      .map(r => ({
        ...r,
        pendingCount: Math.max(0, r.expectedCount - r.submittedCount),
        completionRate: safePercent(r.submittedCount, r.expectedCount),
      }))
      .sort((a, b) => {
        if (a.pendingCount !== b.pendingCount) return b.pendingCount - a.pendingCount;
        return a.tag.localeCompare(b.tag);
      });

    const expectedTotal = tasks.reduce((s, t) => s + t.expectedCount, 0);
    const submittedTotal = tasks.reduce((s, t) => s + t.submittedCount, 0);
    const uploadedUsers = uniq(allItems.map(it => it.user));

    const summary = {
      activeConfigCount: tasks.length,
      activeTagCount: tags.length,
      expectedTotal,
      submittedTotal,
      completionRate: safePercent(submittedTotal, expectedTotal),
      uploadedCsvCount: allItems.length,
      uploadedUserCount: uploadedUsers.length,
      missingPeopleCount: tasks.reduce((s, t) => s + t.missingUsers.length, 0),
      updatedAt: new Date().toISOString(),
    };

    res.json({ ok: true, data: { summary, tags, tasks } });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message || 'dashboard failed' });
  }
}

module.exports = { handle };
