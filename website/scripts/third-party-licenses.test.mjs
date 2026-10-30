import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { auditLicenses, embeddedPackages, thirdPartyLicenses } from './third-party-licenses.mjs'

const hash = bytes => createHash('sha256').update(bytes).digest('hex')
async function fixture(t, { omitLicense = false, license = 'MIT', installedVersion = '1.0.0' } = {}) {
  const root = await mkdtemp(path.join(tmpdir(), 'reading-licenses-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(path.join(root, 'node_modules/example'), { recursive: true })
  await mkdir(path.join(root, 'third-party'), { recursive: true })
  await writeFile(path.join(root, 'node_modules/example/package.json'), JSON.stringify({ name: 'example', version: installedVersion, license }))
  if (!omitLicense) await writeFile(path.join(root, 'node_modules/example/LICENSE'), 'Copyright Example Author\nPermission notice kept exactly.\n')
  await writeFile(path.join(root, 'package-lock.json'), JSON.stringify({ packages: { 'node_modules/example': { version: '1.0.0' } } }))
  await writeFile(path.join(root, 'third-party/reviewed.txt'), 'Fixed original notice.')
  await writeFile(path.join(root, 'third-party/supplemental.json'), JSON.stringify({ embedded: [], source_availability: 'Upstream source location.', license_source_records: [{ file: 'reviewed.txt', sha256: hash('Fixed original notice.') }] }))
  const bundle = { 'assets/app.js': { type: 'chunk', fileName: 'assets/app.js', code: '/* real client output */', modules: { [path.join(root, 'node_modules/example/index.js')]: { renderedLength: 1 } } } }
  const plugin = thirdPartyLicenses({ root })
  plugin.configResolved({ build: { ssr: false } })
  const emitted = new Map()
  const run = () => plugin.generateBundle.handler.call({ emitFile: file => emitted.set(file.fileName, file.source) }, {}, bundle)
  return { root, bundle, plugin, emitted, run }
}

test('client attribution copies original notice bytes and names the exact locked package', async t => {
  const f = await fixture(t)
  await f.run()
  const manifest = JSON.parse(f.emitted.get('licenses/third-party/manifest.json'))
  assert.equal(manifest.packages[0].name, 'example')
  assert.equal(manifest.packages[0].version, '1.0.0')
  const notice = manifest.packages[0].notices[0]
  assert.deepEqual(f.emitted.get(notice.file), await readFile(path.join(f.root, 'node_modules/example/LICENSE')))
  assert.equal(notice.sha256, hash(f.emitted.get(notice.file)))
})

test('client inventory uses output file names instead of VitePress synthetic lean keys', async t => {
  const f = await fixture(t)
  f.bundle['assets/app.js-lean'] = { ...f.bundle['assets/app.js'], fileName: 'assets/app.lean.js' }
  await f.run()
  const manifest = JSON.parse(f.emitted.get('licenses/third-party/manifest.json'))
  assert.deepEqual(manifest.chunks.map(chunk => chunk.file), ['assets/app.js', 'assets/app.lean.js'])
  assert.equal(f.plugin.generateBundle.order, 'post')
})

test('build refuses missing license text even when metadata says MIT', async t => {
  const f = await fixture(t, { omitLicense: true })
  await assert.rejects(f.run(), /No license\/notice files/)
})

test('build refuses an installed dependency version outside the lock and an unreviewed license', async t => {
  await assert.rejects((await fixture(t, { installedVersion: '2.0.0' })).run(), /differs from lock/)
  await assert.rejects((await fixture(t, { license: 'Unreviewed-Terms' })).run(), /Unreviewed license metadata/)
})

test('build rejects changed supplemental license text instead of silently blessing a new digest', async t => {
  const f = await fixture(t)
  await writeFile(path.join(f.root, 'third-party/reviewed.txt'), 'Edited original notice.')
  await assert.rejects(f.run(), /Reviewed original notice changed/)
})

test('supplemental notice cannot bypass its original-source review', async t => {
  const f = await fixture(t, { omitLicense: true })
  const supplementsFile = path.join(f.root, 'third-party/supplemental.json')
  const supplements = JSON.parse(await readFile(supplementsFile, 'utf8'))
  supplements.license_source_records = []
  supplements.package_notice_overrides = { 'example@1.0.0': { license_files: ['reviewed.txt'] } }
  await writeFile(supplementsFile, JSON.stringify(supplements))
  await assert.rejects(f.run(), /Supplemental notice lacks original-source review/)
})

test('prebundled dependency without version requires an exact reviewed source hash', () => {
  const source = 'webpack://LIB/node_modules/path-browserify/index.js'
  const content = 'upstream original bytes'
  const override = { source, source_sha256: hash(content), name: 'path-browserify', version: '1.0.1' }
  assert.throws(() => embeddedPackages([source], [content]), /Unreviewed bundled dependency/)
  assert.deepEqual(embeddedPackages([source], [content], [override]), [{ name: 'path-browserify', version: '1.0.1' }])
  assert.throws(() => embeddedPackages([source], [content + 'changed'], [override]), /Unreviewed bundled dependency/)
})

test('SSR output does not overwrite the client license inventory', async t => {
  const f = await fixture(t)
  f.plugin.configResolved({ build: { ssr: true } })
  await f.run()
  assert.equal(f.emitted.size, 0)
})

test('output audit detects deleted notices, altered chunks, omitted package attribution and unexpected fonts', async t => {
  const f = await fixture(t)
  await f.run()
  const dist = path.join(f.root, 'dist')
  for (const [relative, bytes] of f.emitted) {
    await mkdir(path.dirname(path.join(dist, relative)), { recursive: true })
    await writeFile(path.join(dist, relative), bytes)
  }
  await mkdir(path.join(dist, 'assets'), { recursive: true })
  await writeFile(path.join(dist, 'assets/app.js'), f.bundle['assets/app.js'].code)
  const mp = path.join(dist, 'licenses/third-party/manifest.json')
  const manifest = JSON.parse(await readFile(mp, 'utf8'))
  // Required production names are not the target of this focused integrity test.
  for (const name of ['mermaid', 'minisearch', 'vitepress', 'Inter']) manifest.packages.push({ name, version: 'fixture', notices: manifest.packages[0].notices })
  await writeFile(mp, JSON.stringify(manifest))
  assert.equal((await auditLicenses(dist, { root: f.root })).status, 'passed')
  const notice = manifest.packages[0].notices[0].file
  await rm(path.join(dist, notice))
  await writeFile(path.join(dist, 'assets/app.js'), 'tampered')
  await writeFile(path.join(dist, 'assets/unreviewed.woff2'), 'font')
  await writeFile(path.join(dist, 'assets/omitted-chunk.js'), 'client code')
  await writeFile(path.join(dist, 'licenses/third-party/SOURCE-AVAILABILITY.txt'), '')
  manifest.packages.shift()
  await writeFile(mp, JSON.stringify(manifest))
  const result = await auditLicenses(dist, { root: f.root })
  assert.equal(result.status, 'failed')
  assert.ok(result.findings.some(x => x.includes('Missing file:')))
  assert.ok(result.findings.some(x => x.includes('Changed bytes: assets/app.js')))
  assert.ok(result.findings.some(x => x.includes('Chunk attribution absent:')))
  assert.ok(result.findings.some(x => x.includes('Uninventoried font:')))
  assert.ok(result.findings.some(x => x.includes('Uninventoried client script:')))
  assert.ok(result.findings.some(x => x.includes('source-availability statement')))
})
