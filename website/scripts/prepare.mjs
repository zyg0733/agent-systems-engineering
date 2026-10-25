import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

export const siteRoot = fileURLToPath(new URL('../', import.meta.url))
export const repoRoot = path.dirname(siteRoot)
export const contentRoot = path.join(siteRoot, '.content')

// Only these authored Markdown trees become website content. Runtime data,
// source code, fixtures, dependencies and experiment artifacts are never copied.
export async function markdownFiles(directory) {
  const files = []
  for (const entry of await readdir(path.join(repoRoot, directory), { withFileTypes: true })) {
    const relative = path.posix.join(directory, entry.name)
    if (entry.isDirectory()) files.push(...await markdownFiles(relative))
    else if (entry.isFile() && entry.name.endsWith('.md')) files.push(relative)
  }
  return files.sort()
}

export async function prepare() {
  // The portable book route is rendered at /reading rather than duplicated.
  const files = (await Promise.all(['book', 'labs', 'docs'].map(markdownFiles))).flat().filter(relative => relative !== 'book/reading-route.md')
  await rm(contentRoot, { recursive: true, force: true })
  await mkdir(contentRoot, { recursive: true })
  for (const relative of files) {
    const target = path.join(contentRoot, relative)
    await mkdir(path.dirname(target), { recursive: true })
    let source = await readFile(path.join(repoRoot, relative), 'utf8')
    if (relative.startsWith('labs/solutions/') || /^docs\/(?:validation(?:-week\d+)?|reader-review|reader-study-review|p[234]-report)/.test(relative)) {
      source = '---\nsearch: false\n---\n\n' + source
    }
    await writeFile(target, source)
  }
  for (const name of ['index.md', 'start.md', 'reading.md', 'teaching.md']) {
    let page = await readFile(name === 'reading.md' ? path.join(repoRoot, 'book', 'reading-route.md') : path.join(siteRoot, name), 'utf8')
    if (name === 'reading.md') page = page.replace('# 六章阅读路线\n', '# 六章阅读路线\n\n<ReadingProgress />\n')
    // These authored pages live one level below the repo in GitHub, but at
    // the website root after preparation. Preserve both sets of relative links.
    await writeFile(path.join(contentRoot, name), page.replace(/\]\(\.\.\/(book|labs|docs)\//g, ']($1/'))
  }
  await cp(path.join(repoRoot, 'README.md'), path.join(contentRoot, 'project.md'))
  await cp(path.join(siteRoot, 'public'), path.join(contentRoot, 'public'), { recursive: true })
  await mkdir(path.join(contentRoot, 'public', 'licenses'), { recursive: true })
  for (const name of ['LICENSE', 'LICENSE-DOCS', 'NOTICE']) {
    await cp(path.join(repoRoot, name), path.join(contentRoot, 'public', 'licenses', name + '.txt'))
  }
  console.log(`Prepared ${files.length + 5} reading pages from existing Markdown.`)
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await prepare()
