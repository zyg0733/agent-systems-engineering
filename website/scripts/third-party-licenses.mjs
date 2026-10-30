import { readFile, readdir, stat } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const defaultRoot = fileURLToPath(new URL('../', import.meta.url))
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex')
const json = async file => JSON.parse(await readFile(file, 'utf8'))
const legalName = /^(?:licen[cs]e|notice|copying|copyright)(?:[._-].*)?$/i
const licenseDirectory = /^(?:licen[cs]es?|legal|notices?)$/i
const reviewedLicenses = new Set(['MIT', 'ISC', 'Apache-2.0', 'BSD-2-Clause', 'BSD-3-Clause', 'EPL-2.0', 'Unlicense', 'CC0-1.0', '(MPL-2.0 OR Apache-2.0)', '(MIT AND CC-BY-3.0)'])
const escapeHtml = text => String(text).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
const slug = value => value.replace(/^@/, '').replaceAll('/', '--').replace(/[^A-Za-z0-9._-]/g, '-')
const plainId = id => id.replace(/^\0/, '').split('?')[0]

function packageDirectory(moduleId) {
  const clean = plainId(moduleId)
  const marker = clean.lastIndexOf('/node_modules/')
  if (marker < 0) return null
  const rest = clean.slice(marker + '/node_modules/'.length).split('/')
  return clean.slice(0, marker + '/node_modules/'.length) + rest.slice(0, rest[0].startsWith('@') ? 2 : 1).join('/')
}

export function embeddedPackages(sources, contents = [], overrides = []) {
  const packages = new Map()
  for (const [index, source] of sources.entries()) {
    if (!source.includes('/node_modules/')) continue
    const match = source.match(/\/\.pnpm\/([^/]+)\/node_modules\/(@[^/]+\/[^/]+|[^/]+)\//)
    if (!match) {
      const override = overrides.find(item => item.source === source && typeof contents[index] === 'string' && item.source_sha256 === sha256(contents[index]))
      if (!override) throw new Error(`Unreviewed bundled dependency source: ${source}`)
      packages.set(`${override.name}@${override.version}`, { name: override.name, version: override.version })
      continue
    }
    const [, folder, name] = match
    const prefix = name.replace('/', '+') + '@'
    if (!folder.startsWith(prefix)) throw new Error(`Cannot identify bundled dependency version: ${source}`)
    const version = folder.slice(prefix.length).split(/[_(]/)[0]
    if (!/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/.test(version)) throw new Error(`Invalid bundled dependency version: ${source}`)
    packages.set(`${name}@${version}`, { name, version })
  }
  return [...packages.values()]
}

async function legalFiles(root, relative = '', depth = 0) {
  const result = []
  for (const entry of await readdir(path.join(root, relative), { withFileTypes: true })) {
    const file = path.posix.join(relative, entry.name)
    if (entry.isSymbolicLink()) continue
    if (entry.isFile() && (legalName.test(entry.name) || relative !== '')) result.push(file)
    else if (entry.isDirectory() && depth < 2 && licenseDirectory.test(entry.name)) result.push(...await legalFiles(root, file, depth + 1))
  }
  return result.sort()
}

function upstream(metadata, locked) {
  const repository = typeof metadata.repository === 'string' ? metadata.repository : metadata.repository?.url
  return { repository: repository || null, distribution: locked.resolved || null, integrity: locked.integrity || null }
}

/** The inventory comes from the actual client chunks, including lazy chunks. */
export function thirdPartyLicenses({ root = defaultRoot } = {}) {
  let serverBuild = false
  return {
    name: 'reading-site-third-party-licenses',
    apply: 'build',
    enforce: 'post',
    configResolved(config) { serverBuild = Boolean(config.build.ssr) },
    // Vite's import-preload rewrite runs after ordinary user plugins. Record
    // the final client bytes after all default-order generateBundle hooks.
    generateBundle: { order: 'post', async handler(_options, bundle) {
      if (serverBuild) return
      const lockBytes = await readFile(path.join(root, 'package-lock.json'))
      const lock = JSON.parse(lockBytes)
      const supplements = await json(path.join(root, 'third-party', 'supplemental.json'))
      for (const record of supplements.license_source_records || []) {
        if (sha256(await readFile(path.join(root, 'third-party', record.file))) !== record.sha256) throw new Error(`Reviewed original notice changed: ${record.file}`)
      }
      const reviewedNoticeFiles = new Set((supplements.license_source_records || []).map(record => record.file))
      const packages = new Map()
      const embedded = new Map()
      const chunks = []
      const emit = (fileName, source) => this.emitFile({ type: 'asset', fileName, source })
      for (const chunk of Object.values(bundle)) {
        if (chunk.type !== 'chunk') continue
        // VitePress lean chunks have a synthetic bundle key ending in '-lean'.
        const fileName = chunk.fileName
        const owners = new Set()
        for (const moduleId of Object.keys(chunk.modules)) {
          const directory = packageDirectory(moduleId)
          if (!directory) continue
          const relative = path.relative(root, directory).split(path.sep).join('/')
          if (!relative.startsWith('node_modules/') || relative.includes('../')) throw new Error(`Dependency outside site root: ${moduleId}`)
          const metadata = await json(path.join(directory, 'package.json'))
          const locked = lock.packages[relative]
          if (!locked || locked.version !== metadata.version) throw new Error(`Installed dependency differs from lock: ${relative}`)
          const key = `${metadata.name}@${metadata.version}`
          if (!packages.has(key)) packages.set(key, { key, directory, relative, metadata, locked, modules: new Set(), chunks: new Set() })
          const record = packages.get(key)
          record.modules.add(path.relative(directory, plainId(moduleId)).split(path.sep).join('/'))
          record.chunks.add(fileName)
          owners.add(key)
          const mapFile = plainId(moduleId) + '.map'
          if (existsSync(mapFile)) {
            const map = await json(mapFile)
            for (const dependency of embeddedPackages(map.sources || [], map.sourcesContent, supplements.source_map_overrides)) {
              const embeddedKey = `${dependency.name}@${dependency.version}`
              if (!embedded.has(embeddedKey)) embedded.set(embeddedKey, { ...dependency, owners: new Set() })
              embedded.get(embeddedKey).owners.add(key)
            }
          }
        }
        chunks.push({ file: fileName, sha256: sha256(chunk.code), packages: [...owners].sort() })
      }
      const entries = []
      const installedEmbedded = new Map()
      for (const [key, dependency] of embedded) {
        if (packages.has(key) || supplements.embedded.some(entry => `${entry.name}@${entry.version}` === key)) continue
        const relative = 'node_modules/' + dependency.name
        const directory = path.join(root, relative)
        if (!existsSync(path.join(directory, 'package.json'))) continue
        const metadata = await json(path.join(directory, 'package.json'))
        const locked = lock.packages[relative]
        if (metadata.version === dependency.version && locked?.version === metadata.version) installedEmbedded.set(key, { directory, metadata, locked })
      }
      const missingEmbedded = [...embedded.keys()].filter(key => !packages.has(key) && !installedEmbedded.has(key) && !supplements.embedded.some(entry => `${entry.name}@${entry.version}` === key))
      if (missingEmbedded.length) throw new Error(`Missing reviewed licenses for prebundled dependencies: ${missingEmbedded.join(', ')}`)
      const appendLegal = async (entry, directory, files) => {
        if (!files.length) throw new Error(`No license/notice files for ${entry.name}@${entry.version}`)
        entry.notices = []
        for (const file of files) {
          if (directory === path.join(root, 'third-party') && !reviewedNoticeFiles.has(file)) throw new Error(`Supplemental notice lacks original-source review: ${file}`)
          const bytes = await readFile(path.join(directory, file))
          if (!bytes.length || bytes.includes(0)) throw new Error(`Empty or binary license file: ${entry.name}/${file}`)
          const output = `licenses/third-party/${slug(entry.name)}@${entry.version}/${file.replaceAll('/', '--')}.txt`
          emit(output, bytes)
          entry.notices.push({ file: output, source_file: file, sha256: sha256(bytes) })
        }
        entries.push(entry)
      }
      for (const record of [...packages.values()].sort((a, b) => a.key.localeCompare(b.key))) {
        const { metadata, locked } = record
        const override = supplements.package_license_overrides?.[record.key]
        const license = metadata.license || override?.license
        if (!reviewedLicenses.has(license)) throw new Error(`Unreviewed license metadata: ${record.key}: ${license}`)
        const notices = await legalFiles(record.directory)
        if (override && !await Promise.all(notices.map(file => readFile(path.join(record.directory, file)).then(sha256))).then(hashes => hashes.includes(override.license_sha256))) throw new Error(`Reviewed license changed: ${record.key}`)
        const noticeOverride = supplements.package_notice_overrides?.[record.key]
        await appendLegal({ name: metadata.name, version: metadata.version, license, kind: 'client-module', ...upstream(metadata, locked), modules: [...record.modules].sort(), chunks: [...record.chunks].sort(), notice_source: noticeOverride?.reason || 'original installed package' }, notices.length ? record.directory : path.join(root, 'third-party'), notices.length ? notices : noticeOverride?.license_files || [])
      }
      for (const [key, dependency] of [...embedded.entries()].sort()) {
        if (packages.has(key)) continue
        const installed = installedEmbedded.get(key)
        if (installed) {
          if (!reviewedLicenses.has(installed.metadata.license)) throw new Error(`Unreviewed embedded package license: ${key}`)
          await appendLegal({ name: dependency.name, version: dependency.version, license: installed.metadata.license, kind: 'prebundled-source-map', embedded_in: [...dependency.owners].sort(), ...upstream(installed.metadata, installed.locked) }, installed.directory, await legalFiles(installed.directory))
          continue
        }
        const supplement = supplements.embedded.find(entry => `${entry.name}@${entry.version}` === key)
        if (!supplement) throw new Error(`Missing reviewed license for prebundled dependency: ${key}`)
        await appendLegal({ ...supplement, kind: 'prebundled-source-map', embedded_in: [...dependency.owners].sort() }, path.join(root, 'third-party'), supplement.license_files)
      }
      for (const component of supplements.bundled_components || []) {
        if (!packages.has(component.owner)) continue
        for (const input of component.inputs) {
          if (sha256(await readFile(path.join(root, input.file))) !== input.sha256) throw new Error(`Reviewed bundled component changed: ${component.name}: ${input.file}`)
        }
        await appendLegal({ ...component, kind: 'reviewed-vendored-component' }, path.join(root, 'third-party'), component.license_files)
      }
      const fontFiles = Object.entries(bundle).filter(([name]) => /\.(?:woff2?|ttf|otf)$/.test(name))
      if (fontFiles.length) {
        const font = supplements.fonts
        if (packages.get('vitepress@' + font.vitepress_version) === undefined) throw new Error('Font provenance does not match VitePress version')
        const assets = []
        for (const [file, asset] of fontFiles) {
          if (asset.type !== 'asset' || !/^assets\/inter-(?:roman|italic)-[a-z-]+\.[\w-]+\.woff2$/.test(file)) throw new Error(`Unreviewed font asset: ${file}`)
          const hash = sha256(asset.source)
          const original = font.files.find(record => record.sha256 === hash)
          if (!original) throw new Error(`Font bytes differ from reviewed source: ${file}`)
          assets.push({ file, sha256: hash, source_file: original.file })
        }
        await appendLegal({ name: font.name, version: font.version, license: font.license, kind: 'font', repository: font.repository, source: font.source, assets }, path.join(root, 'third-party'), font.license_files)
      }
      const manifest = { schema_version: 1, scope: 'actual client chunks, inspected prebundled source maps and emitted fonts', lock_sha256: sha256(lockBytes), packages: entries, chunks: chunks.sort((a, b) => a.file.localeCompare(b.file)), supplemental_sha256: sha256(await readFile(path.join(root, 'third-party', 'supplemental.json'))), source_availability: supplements.source_availability }
      const prefix = 'licenses/third-party/'
      emit(prefix + 'manifest.json', JSON.stringify(manifest, null, 2) + '\n')
      emit(prefix + 'SOURCE-AVAILABILITY.txt', supplements.source_availability)
      const list = entries.map(entry => `<li><h2>${escapeHtml(entry.name)} ${escapeHtml(entry.version)}</h2><p>${escapeHtml(entry.license)} · ${escapeHtml(entry.kind)}</p><ul>${entry.notices.map(notice => `<li><a href="${escapeHtml(notice.file.slice(prefix.length))}">${escapeHtml(notice.source_file)}</a></li>`).join('')}</ul>${entry.distribution ? `<p><a href="${escapeHtml(entry.distribution)}">Original package</a></p>` : ''}</li>`).join('\n')
      emit(prefix + 'index.html', `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>第三方版权与许可证</title><style>body{font:16px/1.7 system-ui;max-width:70ch;margin:2rem auto;padding:0 1rem;overflow-wrap:anywhere}li{margin-bottom:1rem}h2{font-size:1.1rem}pre{white-space:pre-wrap}</style><body><h1>第三方版权与许可证</h1><p>以下软件和字体按各自原许可分发；项目的 Apache-2.0 / CC BY 4.0 不替代这些条款。清单由本次客户端构建生成，包含延迟加载的图示代码。</p><p><a href="manifest.json">版本、来源与校验清单</a> · <a href="SOURCE-AVAILABILITY.txt">源代码取得说明</a></p><ul>${list}</ul><h2>源代码取得说明</h2><pre>${escapeHtml(supplements.source_availability)}</pre></body></html>\n`)
      console.log(`Third-party attribution: ${entries.length} packages/font records; ${chunks.length} client chunks.`)
    } }
  }
}

export async function auditLicenses(dist, { root = defaultRoot } = {}) {
  const manifestFile = path.join(dist, 'licenses/third-party/manifest.json')
  const manifest = await json(manifestFile)
  const findings = []
  if (manifest.schema_version !== 1 || !manifest.packages?.length || !manifest.chunks?.length) findings.push('Missing client dependency inventory')
  if (manifest.lock_sha256 !== sha256(await readFile(path.join(root, 'package-lock.json')))) findings.push('Inventory does not match package-lock.json')
  if (manifest.supplemental_sha256 !== sha256(await readFile(path.join(root, 'third-party/supplemental.json')))) findings.push('Inventory does not match reviewed supplemental inputs')
  const expected = new Set()
  const packageKeys = new Set((manifest.packages || []).map(entry => `${entry.name}@${entry.version}`))
  const verify = async record => {
    if (!record.file || record.file.includes('..') || path.isAbsolute(record.file)) { findings.push('Unsafe inventory path'); return }
    expected.add(record.file)
    try { if (sha256(await readFile(path.join(dist, record.file))) !== record.sha256) findings.push(`Changed bytes: ${record.file}`) } catch { findings.push(`Missing file: ${record.file}`) }
  }
  for (const entry of manifest.packages || []) {
    if (!entry.notices?.length) findings.push(`Missing notices: ${entry.name}`)
    for (const notice of entry.notices || []) await verify(notice)
    for (const asset of entry.assets || []) await verify(asset)
  }
  for (const chunk of manifest.chunks || []) {
    await verify(chunk)
    for (const key of chunk.packages || []) if (!packageKeys.has(key)) findings.push(`Chunk attribution absent: ${chunk.file}: ${key}`)
  }
  const walk = async (dir, relative = '') => {
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const file = path.posix.join(relative, entry.name)
      if (entry.isDirectory()) await walk(path.join(dir, entry.name), file)
      else if (/\.(?:woff2?|ttf|otf)$/.test(file) && !expected.has(file)) findings.push(`Uninventoried font: ${file}`)
      else if (/\.m?js$/.test(file) && !expected.has(file)) findings.push(`Uninventoried client script: ${file}`)
    }
  }
  await walk(dist)
  for (const name of ['mermaid', 'minisearch', 'vitepress', 'Inter']) if (!manifest.packages.some(entry => entry.name === name)) findings.push(`Required client attribution missing: ${name}`)
  for (const file of ['licenses/third-party/index.html', 'licenses/third-party/SOURCE-AVAILABILITY.txt']) if (!(await stat(path.join(dist, file)).catch(() => null))?.isFile()) findings.push(`Missing index/source notice: ${file}`)
  const sourceNotice = await readFile(path.join(dist, 'licenses/third-party/SOURCE-AVAILABILITY.txt'), 'utf8').catch(() => null)
  const supplements = await json(path.join(root, 'third-party/supplemental.json'))
  if (sourceNotice !== supplements.source_availability || sourceNotice !== manifest.source_availability) findings.push('Changed or missing source-availability statement')
  return { status: findings.length ? 'failed' : 'passed', packages: manifest.packages?.length || 0, chunks: manifest.chunks?.length || 0, findings }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const result = await auditLicenses(path.join(defaultRoot, '.vitepress/dist'))
  console.log(JSON.stringify(result))
  if (result.findings.length) process.exitCode = 1
}
