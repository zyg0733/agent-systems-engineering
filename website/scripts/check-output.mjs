import { readFile, readdir, stat } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const defaultBase = '/agent-systems-engineering/'
const defaultOrigin = 'https://zyg0733.github.io'
const unpublishedDirectories = new Set([
  'artifacts', 'node_modules', '.runtime', '_build', 'deps',
  'test', 'lib', 'config', 'fixtures', 'scripts', 'priv'
])

function decodeEntities(value) {
  const named = { amp: '&', quot: '"', apos: "'", lt: '<', gt: '>', colon: ':', sol: '/' }
  return value.replace(/&(#x[\da-f]+|#\d+|amp|quot|apos|lt|gt|colon|sol);/gi, (entity, name) => {
    if (!name.startsWith('#')) return named[name.toLowerCase()]
    const code = name[1].toLowerCase() === 'x' ? parseInt(name.slice(2), 16) : parseInt(name.slice(1), 10)
    return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : entity
  })
}

function attributes(html) {
  // Inspect markup, not example strings inside comments or script/style bodies.
  const markup = html.replace(/<!--[\s\S]*?-->/g, '')
    .replace(/(<script\b[^>]*>)[\s\S]*?<\/script\s*>/gi, '$1</script>')
    .replace(/(<style\b[^>]*>)[\s\S]*?<\/style\s*>/gi, '$1</style>')
  const found = []
  for (const tag of markup.matchAll(/<\/?[a-z][^>]*>/gi)) {
    for (const attribute of tag[0].matchAll(/\s(href|src|id|name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
      found.push({ attribute: attribute[1].toLowerCase(), value: decodeEntities(attribute[2] ?? attribute[3] ?? attribute[4]) })
    }
  }
  return found
}

async function outputFiles(directory, prefix = '') {
  const result = []
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relative = path.posix.join(prefix, entry.name)
    if (entry.isDirectory()) result.push(...await outputFiles(path.join(directory, entry.name), relative))
    else if (entry.isFile()) result.push(relative)
    else result.push(relative) // Symlinks are not a supported published asset.
  }
  return result.sort()
}

async function isFile(file) {
  try { return (await stat(file)).isFile() } catch (error) {
    if (error.code === 'ENOENT' || error.code === 'ENOTDIR') return false
    throw error
  }
}

/** Check emitted pages without fetching URLs or executing page scripts. */
export async function auditOutput(dist, base = defaultBase, { siteOrigin = defaultOrigin } = {}) {
  if (!/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(base)) throw new Error('base must be a slash-delimited URL path')
  const origin = new URL(siteOrigin).origin
  const root = path.resolve(dist)
  const files = await outputFiles(root)
  const findings = []
  const parsed = new Map()
  const readAttributes = async relative => {
    if (!parsed.has(relative)) parsed.set(relative, attributes(await readFile(path.join(root, relative), 'utf8')))
    return parsed.get(relative)
  }
  const add = (file, attribute, url, reason) => findings.push({ file, attribute, url, reason })

  for (const relative of files) {
    if (relative.split('/').some(segment => unpublishedDirectories.has(segment))) {
      add(relative, 'output', relative, 'unpublished directory was included in the site')
    }
  }

  const pages = files.filter(file => file.endsWith('.html'))
  if (pages.length === 0) add('.', 'output', '', 'no HTML pages were emitted')
  for (const page of pages) {
    for (const { attribute, value } of await readAttributes(page)) {
      if (attribute !== 'href' && attribute !== 'src') continue
      const raw = value.trim()
      if (!raw && attribute === 'src') {
        add(page, attribute, raw, 'empty resource URL')
        continue
      }
      // mailto:, tel:, data:, blob: and all other non-HTTP schemes are not
      // website files. GitHub source links and other external sites stay external.
      if (/^[a-z][a-z\d+.-]*:/i.test(raw) && !/^https?:/i.test(raw)) continue
      let url
      try { url = new URL(raw, origin + base + page) } catch {
        add(page, attribute, raw, 'invalid URL')
        continue
      }
      if (url.origin !== origin) continue
      if (!url.pathname.startsWith(base)) {
        add(page, attribute, raw, `local URL escapes the configured base ${base}`)
        continue
      }
      let relative, fragment
      try {
        relative = decodeURIComponent(url.pathname.slice(base.length))
        fragment = decodeURIComponent(url.hash.slice(1)).split(':~:')[0]
      } catch {
        add(page, attribute, raw, 'invalid percent encoding')
        continue
      }
      if (relative.includes('\\') || relative.split('/').includes('..') || path.isAbsolute(relative)) {
        add(page, attribute, raw, 'local URL escapes the output directory')
        continue
      }
      if (relative.split('/').some(segment => unpublishedDirectories.has(segment))) {
        add(page, attribute, raw, 'URL points to unpublished runtime, evidence or source files')
        continue
      }
      const candidates = relative.endsWith('/') || !relative
        ? [relative + 'index.html']
        : path.posix.extname(relative) ? [relative] : [relative, relative + '.html', relative + '/index.html']
      let target
      for (const candidate of candidates) {
        if (await isFile(path.join(root, candidate))) { target = candidate; break }
      }
      if (!target) {
        add(page, attribute, raw, 'local target does not exist')
        continue
      }
      if (fragment && /\.(?:html|svg)$/i.test(target)) {
        const anchors = await readAttributes(target)
        if (!anchors.some(item => (item.attribute === 'id' || item.attribute === 'name') && item.value === fragment)) {
          add(page, attribute, raw, `fragment #${fragment} does not exist in ${target}`)
        }
      }
    }
  }
  return findings
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const dist = fileURLToPath(new URL('../.vitepress/dist/', import.meta.url))
  try {
    const findings = await auditOutput(dist, process.env.SITE_BASE || defaultBase, {
      siteOrigin: process.env.SITE_ORIGIN || defaultOrigin
    })
    for (const finding of findings) console.error(`${finding.file}: ${finding.attribute}=${JSON.stringify(finding.url)}: ${finding.reason}`)
    if (findings.length) {
      console.error(`Published-site audit failed with ${findings.length} issue(s).`)
      process.exitCode = 1
    } else console.log('Published-site audit passed: local pages, fragments, assets and base paths are valid.')
  } catch (error) {
    console.error(`Published-site audit failed: ${error.message}`)
    process.exitCode = 1
  }
}
