import test from 'node:test'
import assert from 'node:assert/strict'
import { createErrataReport, privateIssueDraft } from './errata-report.mjs'

test('errata report preserves Unicode, code and line breaks as plain text with explicit missing fields', () => {
  const report = createErrataReport({ where: '第 16 章 §4', actual: 'unknown\r\n<script>alert(1)</script>\r\n`x & y`' })
  assert.ok(report.includes('第 16 章 §4'))
  assert.ok(report.includes('unknown\n<script>alert(1)</script>\n`x & y`'))
  assert.ok(report.includes('材料版本 / 完整 commit\n（待填写）'))
  assert.ok(!report.includes('\r'))
})

test('issue draft keeps untrusted text inside encoded parameters of the fixed private repository', () => {
  const input = { where: 'https://evil.invalid/?body=wrong#片段', actual: 'a&redirect=https://evil.invalid/\n中文' }
  const url = new URL(privateIssueDraft(input))
  assert.equal(url.origin, 'https://github.com')
  assert.equal(url.pathname, '/zyg0733/agent-systems-engineering/issues/new')
  assert.equal(url.searchParams.get('body'), createErrataReport(input))
  assert.deepEqual([...url.searchParams.keys()].sort(), ['body', 'title'])
  assert.equal(url.hash, '')
})

test('long reports remain downloadable without producing an oversized GitHub link', () => {
  const input = { actual: '中文与输出\n'.repeat(1000) }
  assert.equal(privateIssueDraft(input), null)
  assert.ok(createErrataReport(input).includes(input.actual.trim()))
})
