import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises'
import path from 'node:path'
import os from 'node:os'
import { auditOutput } from './check-output.mjs'
import { startPreview } from './preview.mjs'
import { disablePageSearch, excludeFromReaderSearch } from './search-policy.mjs'

test('P2 fault reports and separate solutions stay out of search while reader chapters remain indexed', () => {
  assert.equal(excludeFromReaderSearch('docs/p2-fault-report.md'), true)
  assert.equal(excludeFromReaderSearch('docs/p3-report.md'), true)
  assert.equal(excludeFromReaderSearch('labs/solutions/L19.md'), true)
  assert.equal(excludeFromReaderSearch('book/templates/capstone-report.md'), true)
  assert.equal(excludeFromReaderSearch('book/ch15-retry-timeout-and-idempotency.md'), false)
})

test('search exclusion preserves an authored page title in a single frontmatter block', () => {
  const source = '---\ntitle: 历史记录\nsearch: true\n---\n\n# 记录\n'
  const prepared = disablePageSearch(source)
  assert.equal(prepared, '---\ntitle: 历史记录\n\nsearch: false\n---\n\n# 记录\n')
})

async function fixture(t, files) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'reading-site-audit-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  for (const [name, content] of Object.entries(files)) {
    const file = path.join(root, name)
    await mkdir(path.dirname(file), { recursive: true })
    await writeFile(file, content)
  }
  return root
}

test('a reading page can link to another chapter, Unicode anchors, its own outline and built assets', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="/agent-systems-engineering/book/ch02.html?view=reader&amp;lang=zh#状态机">阅读</a><script src="/agent-systems-engineering/assets/app.js"></script><link href="/agent-systems-engineering/assets/style.css" rel="stylesheet"><img src="/agent-systems-engineering/logo.svg#mark">',
    'book/ch02.html': '<h1 id="状态机">状态机</h1><a href="#状态机">目录</a><a href="#">搜索按钮</a><a href="../index.html">首页</a><a href="?mode=book#%E7%8A%B6%E6%80%81%E6%9C%BA">同页</a><a href="../glossary/">术语</a>',
    'glossary/index.html': '<h1>术语</h1>',
    'assets/app.js': 'export const ok = true',
    'assets/style.css': 'body { color: #222 }',
    'logo.svg': '<svg><g id="mark" /></svg>'
  })
  assert.deepEqual(await auditOutput(root), [])
})

test('a real target page with the wrong heading fragment fails', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="book/ch02.html#旧标题">状态机</a>',
    'book/ch02.html': '<h1 id="新标题">新标题</h1>'
  })
  const findings = await auditOutput(root)
  assert.equal(findings.length, 1)
  assert.equal(findings[0].file, 'index.html')
  assert.match(findings[0].reason, /fragment #旧标题 does not exist/)
})

test('missing chapters and missing CSS/JavaScript resources are reported independently', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="book/unwritten.html">未写章</a><link rel="stylesheet" href="assets/missing.css"><script src="assets/missing.js"></script>'
  })
  const findings = await auditOutput(root)
  assert.deepEqual(findings.map(finding => finding.url).sort(), ['assets/missing.css', 'assets/missing.js', 'book/unwritten.html'])
  assert.ok(findings.every(finding => /does not exist/.test(finding.reason)))
})

test('a root-relative asset cannot accidentally leave a GitHub project-site base', async t => {
  const root = await fixture(t, {
    'index.html': '<img src="/logo.svg"><a href="/book/ch02.html">章节</a>',
    'logo.svg': '<svg />',
    'book/ch02.html': '<h1>存在的章节</h1>'
  })
  const findings = await auditOutput(root)
  assert.equal(findings.length, 2)
  assert.ok(findings.every(finding => /configured base/.test(finding.reason)))
})

test('external sources and non-web URLs require no network or local target', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="https://github.com/zyg0733/agent-systems-engineering/blob/main/test/kernel_test.exs#L3">源码</a><a href="//example.org/missing.html#absent">外站</a><a href="mailto:reader@example.org">邮件</a><a href="tel:+1234">电话</a><img src="data:image/svg+xml;base64,PHN2ZyAvPg=="><a href="blob:example">临时文件</a>'
  })
  assert.deepEqual(await auditOutput(root), [])
})

test('absolute links to this Pages host are still checked as local pages', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="https://zyg0733.github.io/agent-systems-engineering/missing.html">本站缺页</a><img src="//zyg0733.github.io/logo.svg">'
  })
  const findings = await auditOutput(root)
  assert.equal(findings.length, 2)
  assert.ok(findings.some(finding => /does not exist/.test(finding.reason)))
  assert.ok(findings.some(finding => /configured base/.test(finding.reason)))
})

test('runtime, local evidence, dependencies and test source must never become public file links', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="artifacts/report.html">证据</a><script src="node_modules/package/index.js"></script><a href=".runtime/postgres/log.txt">日志</a><a href="test/example.exs">测试源码</a><a href="%61rtifacts/encoded.json">编码的证据路径</a>'
  })
  const findings = await auditOutput(root)
  assert.equal(findings.length, 5)
  assert.ok(findings.every(finding => /unpublished/.test(finding.reason)))
})

test('copied runtime files are rejected even without any incoming link', async t => {
  const root = await fixture(t, { 'index.html': '<h1>教材</h1>', '.runtime/private.txt': 'should not be published' })
  const findings = await auditOutput(root)
  assert.equal(findings.length, 1)
  assert.equal(findings[0].attribute, 'output')
  assert.match(findings[0].reason, /unpublished directory/)
})

test('HTML entities are decoded in attributes and legacy named anchors remain valid', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="chapter.html?a=1&amp;b=2#tools%26effects">继续</a><a href="chapter.html#legacy">旧锚点</a>',
    'chapter.html': '<h2 id="tools&amp;effects">Tools &amp; effects</h2><a name="legacy"></a>'
  })
  assert.deepEqual(await auditOutput(root), [])
})

test('a custom root deployment works, but malformed URLs and unconverted Markdown do not', async t => {
  const root = await fixture(t, {
    'index.html': '<a href="/chapter.html#ok">有效</a><a href="/chapter.md#ok">未转换</a><a href="/%E0%A4%A">错误编码</a><a href="/chapter.html#missing">错误标题</a>',
    'chapter.html': '<h1 id="ok">完成</h1>'
  })
  const findings = await auditOutput(root, '/')
  assert.equal(findings.length, 3)
  assert.ok(findings.some(finding => /invalid percent encoding/.test(finding.reason)))
  assert.ok(findings.some(finding => finding.url.includes('chapter.md')))
  assert.ok(findings.some(finding => /fragment #missing/.test(finding.reason)))
})

test('commented examples and inline script/style strings are not page navigation', async t => {
  const root = await fixture(t, {
    'index.html': '<!-- <a href="missing.html">注释</a> --><script>const example = \'<a href="unpublished.html">\'</script><style>/* <a href="also-missing.html"> */</style><a href="#">有效空片段</a>'
  })
  assert.deepEqual(await auditOutput(root), [])
})

test('an empty build cannot pass the published-site audit', async t => {
  const root = await fixture(t, { 'assets/app.js': 'export {}' })
  assert.match((await auditOutput(root))[0].reason, /no HTML pages/)
  await assert.rejects(auditOutput(root, '/missing-trailing-slash'), /slash-delimited/)
})

test('preview actually listens only on loopback and serves project-base HTML, JS and HEAD correctly', async t => {
  const root = await fixture(t, { 'index.html': '<h1>中文阅读</h1>', 'assets/app.js': 'export {}' })
  const server = await startPreview({ dist: root, base: '/book/', port: 0 })
  t.after(() => new Promise(resolve => server.close(resolve)))
  assert.equal(server.address().address, '127.0.0.1')
  const origin = `http://127.0.0.1:${server.address().port}`
  const page = await fetch(origin + '/book/')
  assert.equal(page.status, 200)
  assert.match(page.headers.get('content-type'), /text\/html; charset=utf-8/)
  assert.equal(await page.text(), '<h1>中文阅读</h1>')
  const asset = await fetch(origin + '/book/assets/app.js')
  assert.match(asset.headers.get('content-type'), /text\/javascript/)
  const head = await fetch(origin + '/book/', { method: 'HEAD' })
  assert.equal(head.status, 200)
  assert.equal(await head.text(), '')
  assert.ok(Number(head.headers.get('content-length')) > 0)
  const redirect = await fetch(origin + '/book', { redirect: 'manual' })
  assert.equal(redirect.status, 302)
  assert.equal(redirect.headers.get('location'), '/book/')
})

test('preview refuses files outside the build, malformed paths and writes', async t => {
  const root = await fixture(t, { 'index.html': 'reader', '404.html': 'missing' })
  const outside = await fixture(t, { 'private.txt': 'must stay outside' })
  await symlink(path.join(outside, 'private.txt'), path.join(root, 'escaped.txt'))
  const server = await startPreview({ dist: root, base: '/book/', port: 0 })
  t.after(() => new Promise(resolve => server.close(resolve)))
  const origin = `http://127.0.0.1:${server.address().port}`
  for (const [target, status] of [['/book/escaped.txt', 403], ['/book/%2e%2e%2fprivate.txt', 403], ['/book/%E0%A4%A', 400], ['/outside.html', 404], ['/book/missing.html', 404]]) {
    const response = await fetch(origin + target)
    assert.equal(response.status, status, target)
    assert.ok(!(await response.text()).includes('must stay outside'))
  }
  const write = await fetch(origin + '/book/', { method: 'POST', body: 'change' })
  assert.equal(write.status, 405)
  await rm(path.join(root, '404.html'))
  await symlink(path.join(outside, 'private.txt'), path.join(root, '404.html'))
  const fallback = await fetch(origin + '/book/still-missing.html')
  assert.equal(fallback.status, 404)
  assert.equal(await fallback.text(), 'Page not found')
  await assert.rejects(startPreview({ dist: root, base: '/invalid', port: 0 }), /Invalid SITE_BASE/)
})

test('an occupied preview port fails rather than silently listening elsewhere', async t => {
  const root = await fixture(t, { 'index.html': 'reader' })
  const server = await startPreview({ dist: root, port: 0 })
  t.after(() => new Promise(resolve => server.close(resolve)))
  await assert.rejects(startPreview({ dist: root, port: server.address().port }), { code: 'EADDRINUSE' })
})
