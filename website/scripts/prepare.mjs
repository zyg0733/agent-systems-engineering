import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { disablePageSearch, excludeFromReaderSearch } from './search-policy.mjs'

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
  const chapters = JSON.parse(await readFile(path.join(siteRoot, 'chapters.json'), 'utf8'))
  if (!Array.isArray(chapters) || chapters.length !== 30) throw new Error('The book navigation must contain all 30 chapters')
  for (const [index, chapter] of chapters.entries()) {
    const id = `ch${String(index + 1).padStart(2, '0')}`
    if (chapter.id !== id || typeof chapter.file !== 'string' || !/^ch\d{2}-[a-z0-9-]+$/.test(chapter.file) || !chapter.file.startsWith(id + '-') || typeof chapter.title !== 'string' || !chapter.title.trim() || !Number.isInteger(chapter.part) || chapter.part < 1 || chapter.part > 7) {
      throw new Error(`Invalid or out-of-order chapter navigation at ${id}`)
    }
    const text = await readFile(path.join(repoRoot, 'book', chapter.file + '.md'), 'utf8')
    if (!new RegExp(`^# 第 ${index + 1} 章[：:]`, 'm').test(text)) throw new Error(`Chapter heading does not match ${id}`)
  }
  // The portable book route is rendered at /reading rather than duplicated.
  const files = (await Promise.all(['book', 'labs', 'docs'].map(markdownFiles))).flat().filter(relative => relative !== 'book/reading-route.md')
  await rm(contentRoot, { recursive: true, force: true })
  await mkdir(contentRoot, { recursive: true })
  for (const relative of files) {
    const target = path.join(contentRoot, relative)
    await mkdir(path.dirname(target), { recursive: true })
    let source = await readFile(path.join(repoRoot, relative), 'utf8')
    if (excludeFromReaderSearch(relative)) source = disablePageSearch(source)
    if (/^(?:book\/ch\d\d-|labs\/L\d\d-)/.test(relative)) {
      const access = path.posix.relative(path.posix.dirname(relative), 'docs/material-access.md')
      source = source.replace(/^(# [^\n]+)\n/m, `$1\n\n::: info 源码与实验材料\n本页提供静态讲解；源码与测试可在开源仓库直接查看。运行项目模块时，先克隆仓库并安装对应工具链。纯 Elixir 表达式可在已有运行时学习。[查看材料获取与反馈方式](${access})。\n:::\n`)
    }
    await writeFile(target, source)
  }
  for (const name of ['index.md', 'start.md', 'reading.md', 'teaching.md']) {
    let page = await readFile(name === 'reading.md' ? path.join(repoRoot, 'book', 'reading-route.md') : path.join(siteRoot, name), 'utf8')
    if (name === 'reading.md') page = page.replace(/^(# .+)$/m, '$1\n\n<ReadingProgress />')
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
