const fs = require('fs')
const path = require('path')

function usage() {
  console.log('用法：')
  console.log('  node bump-version.js <version>')
  console.log('示例：')
  console.log('  node bump-version.js 1.0.1')
}

// 简单校验 semver: major.minor.patch，可选预发布/构建元数据
function isValidVersion(v) {
  return /^(\d+)\.(\d+)\.(\d+)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(v)
}

function readJson(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8')
  try { return JSON.parse(raw) } catch (e) {
    throw new Error(`解析 ${filePath} 失败：${e.message}`)
  }
}

function writeJson(filePath, obj) {
  const content = JSON.stringify(obj, null, 2) + '\n'
  fs.writeFileSync(filePath, content, 'utf8')
}

function bump() {
  // 优先从命令行参数读取，其次从环境变量 VERSION 读取
  const version = process.argv[2] || process.env.VERSION
  if (!version) {
    console.error('错误：未提供版本号参数')
    usage()
    process.exit(1)
  }
  if (!isValidVersion(version)) {
    console.error(`错误：无效的版本号 "${version}"，需符合格式：x.y.z 或带预发布/构建后缀`)
    process.exit(1)
  }

  const appDir = __dirname
  const pkgPath = path.join(appDir, 'package.json')
  const latestPath = path.join(appDir, 'latest.json')

  if (!fs.existsSync(pkgPath)) {
    console.error(`未找到 package.json：${pkgPath}`)
    process.exit(1)
  }
  if (!fs.existsSync(latestPath)) {
    console.error(`未找到 latest.json：${latestPath}`)
    process.exit(1)
  }

  const pkg = readJson(pkgPath)
  const latest = readJson(latestPath)

  const oldPkgVersion = pkg.version
  const oldLatestVersion = latest.version

  // 递归替换对象中所有字符串值里的旧版本号
  function replaceVersionInObj(obj, oldVer, newVer) {
    if (!oldVer || oldVer === newVer) return obj
    if (typeof obj === 'string') return obj.replaceAll(oldVer, newVer)
    if (Array.isArray(obj)) return obj.map(item => replaceVersionInObj(item, oldVer, newVer))
    if (obj && typeof obj === 'object') {
      const result = {}
      for (const key of Object.keys(obj)) {
        result[key] = replaceVersionInObj(obj[key], oldVer, newVer)
      }
      return result
    }
    return obj
  }

  // 更新 package.json 版本
  pkg.version = version

  // 更新 latest.json：先递归替换所有字段中的旧版本号，再设置 version 字段
  const updatedLatest = replaceVersionInObj(latest, oldLatestVersion, version)
  updatedLatest.version = version

  writeJson(pkgPath, pkg)
  writeJson(latestPath, updatedLatest)

  console.log('版本更新完成：')
  console.log(`  package.json : ${oldPkgVersion} -> ${pkg.version}`)
  console.log(`  latest.json  : ${oldLatestVersion} -> ${updatedLatest.version}`)
  if (updatedLatest.downloads) {
    console.log('  downloads 链接已同步更新：')
    for (const [k, v] of Object.entries(updatedLatest.downloads)) {
      console.log(`    ${k}: ${v}`)
    }
  }
}

try {
  bump()
} catch (e) {
  console.error('执行失败：' + e.message)
  process.exit(1)
}
