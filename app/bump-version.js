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
  const version = process.argv[2]
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

  // 更新版本字段
  pkg.version = version
  latest.version = version

  // 可选：如果 platforms 的链接中包含旧版本号片段，则替换为新版本号
  if (latest.platforms && typeof latest.platforms === 'object') {
    for (const key of Object.keys(latest.platforms)) {
      const val = latest.platforms[key]
      if (typeof val === 'string') {
        // 尝试替换常见文件名中的版本片段（例如 PlayerX-1.0.0 或 Setup 1.0.0）
        let replaced = val
        if (oldLatestVersion && oldLatestVersion !== version) {
          replaced = replaced.replaceAll(oldLatestVersion, version)
          // 兼容空格分隔的版本片段
          replaced = replaced.replaceAll(` ${oldLatestVersion}`, ` ${version}`)
          replaced = replaced.replaceAll(`-${oldLatestVersion}`, `-${version}`)
        }
        latest.platforms[key] = replaced
      } else if (typeof val === 'object' && val) {
        // 支持 { url: "..." } 结构
        if (typeof val.url === 'string' && oldLatestVersion && oldLatestVersion !== version) {
          val.url = val.url
            .replaceAll(oldLatestVersion, version)
            .replaceAll(` ${oldLatestVersion}`, ` ${version}`)
            .replaceAll(`-${oldLatestVersion}`, `-${version}`)
        }
      }
    }
  }

  writeJson(pkgPath, pkg)
  writeJson(latestPath, latest)

  console.log('版本更新完成：')
  console.log(`  package.json: ${oldPkgVersion} -> ${pkg.version}`)
  console.log(`  latest.json : ${oldLatestVersion} -> ${latest.version}`)

  // 显示重要提示
  console.log('\n提示：如需同时更新下载链接，请确保 latest.json 的 platforms 中的链接包含旧版本号片段，本脚本会自动替换；否则请手动调整。')
}

try {
  bump()
} catch (e) {
  console.error('执行失败：' + e.message)
  process.exit(1)
}
