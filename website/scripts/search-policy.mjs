// Functions used by VitePress search must remain self-contained when serialized
// into the client configuration. The generated index and browser use the same
// tokenizer and ranking policy.
export function tokenizeReadingText(text) {
  if (typeof Intl.Segmenter === 'function') return Array.from(new Intl.Segmenter('zh-CN', { granularity: 'word' }).segment(text)).filter(part => part.isWordLike).map(part => part.segment)
  return text.match(/[\u3400-\u9fff]|[\p{L}\p{N}_]+/gu) || []
}

export function boostReadingDocument(id) {
  const page = String(id).split('#')[0]
  if (/\/book\/(?:ch\d\d-|glossary\.html|prerequisites\.html)/.test(page)) return 8
  if (/\/labs\/L\d\d-/.test(page)) return 6
  if (/\/(?:start|reading)\.html$/.test(page)) return 5
  if (/\/docs\/(?:command-reference|recovery-runbook|material-access|linux-core-start)\.html$/.test(page)) return 3
  if (/\/docs\/course-map\.html$/.test(page)) return 1
  if (/\/docs\/(?:adr|research)\//.test(page)) return 0.2
  return 0.5
}

export function excludeFromReaderSearch(relative) {
  return relative.startsWith('labs/solutions/') || relative.startsWith('book/templates/') || /^docs\/(?:validation(?:-week\d+)?|reader-review[^/]*|reader-study-review[^/]*|p[234][^/]*-report)\.md$/.test(relative)
}

export function disablePageSearch(source) {
  if (source.startsWith('---\n')) {
    const end = source.indexOf('\n---', 4)
    if (end !== -1) {
      const head = source.slice(4, end).replace(/^search:.*\n?/m, '')
      return `---\n${head}\nsearch: false${source.slice(end)}`
    }
  }
  return `---\nsearch: false\n---\n\n${source}`
}
