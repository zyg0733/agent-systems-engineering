const issueEndpoint = 'https://github.com/zyg0733/agent-systems-engineering/issues/new'
const fields = [
  ['where', '页面 / 小节'], ['version', '材料版本 / 完整 commit'],
  ['category', '问题类型'], ['expected', '我的理解 / 期望结果'],
  ['actual', '实际文字 / 命令与返回'], ['evidence', '最小复现 / 可检查依据'],
  ['environment', '环境与影响范围'],
]

export function createErrataReport(values) {
  return '# Agent Systems Engineering 勘误报告\n\n' + fields.map(([key, title]) => {
    const value = String(values[key] ?? '').replace(/\r\n?/g, '\n').trim()
    return `## ${title}\n${value || '（待填写）'}`
  }).join('\n\n') + '\n'
}

export function privateIssueDraft(values) {
  const url = new URL(issueEndpoint)
  const location = String(values.where || '教材反馈').replace(/\s+/g, ' ').trim().slice(0, 80)
  url.searchParams.set('title', `[教材勘误] ${location}`)
  url.searchParams.set('body', createErrataReport(values))
  // Long reports stay in the local copy/download flow instead of a truncated URL.
  return url.href.length <= 7000 ? url.href : null
}
