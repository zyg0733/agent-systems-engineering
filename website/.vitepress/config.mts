import { defineConfig } from 'vitepress'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { slug } from 'github-slugger'
import { boostReadingDocument, tokenizeReadingText } from '../scripts/search-policy.mjs'
import { thirdPartyLicenses } from '../scripts/third-party-licenses.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const source = path.join(root, '.content')
const base = process.env.SITE_BASE || '/agent-systems-engineering/'
if (!/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(base)) throw new Error('SITE_BASE must be a slash-delimited URL path')
const repo = 'https://github.com/zyg0733/agent-systems-engineering'
const chapterEntries = JSON.parse(readFileSync(path.join(root, 'chapters.json'), 'utf8')) as Array<{ id: string; file: string; title: string; part: number }>
const partTitles = ['基础模型与持久化', 'Agent 执行与会话', '上下文与工具协议', '历史、外部效果与恢复', '调度与所有权', '编排、安全与审批', '观测、评估与系统验收']
const chapterParts = partTitles.map((text, index) => ({
  text: `第 ${index + 1} 篇 · ${text}`,
  collapsed: index !== 0,
  items: chapterEntries.filter(chapter => chapter.part === index + 1).map(chapter => ({ text: chapter.title, link: '/book/' + chapter.file }))
}))
const labs = readdirSync(path.join(source, 'labs')).filter(file => /^L\d\d-.*\.md$/.test(file)).sort().map(file => ({
  text: readFileSync(path.join(source, 'labs', file), 'utf8').split('\n')[0].replace(/^#\s*/, ''),
  link: '/labs/' + file.replace(/\.md$/, '')
}))
const sidebar = [
  { text: '从这里开始', items: [{ text: '开始学习', link: '/start' }, { text: '先修自测与桥接', link: '/book/prerequisites' }, { text: '阅读路线与章节', link: '/reading' }, { text: '术语与易混概念', link: '/book/glossary' }, { text: '材料获取与反馈', link: '/docs/material-access' }, { text: '固定版本实验包', link: '/docs/experiment-package' }, { text: '勘误与问题反馈', link: '/docs/errata' }, { text: 'Linux core 入门', link: '/docs/linux-core-start' }, { text: '当前状态与边界', link: '/docs/current-status' }, { text: '环境准备与项目说明', link: '/project' }] },
  { text: '全书正文 · 30 章草稿', items: chapterParts },
  { text: '动手实验 · L01—L25', collapsed: true, items: labs },
  { text: '课程与教学', collapsed: true, items: [{ text: 'C01—C12 课程地图', link: '/docs/course-map' }, { text: '全书 30 章设计卡', link: '/book/chapter-cards' }, { text: '教师参考与使用方式', link: '/teaching' }, { text: '全书草稿与交叉评审', link: '/docs/book-completion-review' }] },
  { text: '随手查阅', collapsed: true, items: [{ text: '架构与系统边界', link: '/docs/architecture' }, { text: '命令与实现参考', link: '/docs/command-reference' }, { text: '公开接口与扩展', link: '/docs/public-interfaces' }, { text: '恢复运行手册', link: '/docs/recovery-runbook' }, { text: '技术主张核查', link: '/docs/technical-claims-review' }] },
  { text: '项目与维护', collapsed: true, items: [{ text: '源码检查与 CI', link: '/docs/github-ci' }, { text: '阅读站维护', link: '/docs/reading-site' }, { text: '公开准备修订', link: '/docs/readiness-improvements-review' }, { text: '教材质量计划', link: '/docs/public-reading-quality-plan' }, { text: '公开教材借鉴', link: '/docs/learning-design-references' }, { text: '结果与历史记录', link: '/docs/results-index' }, { text: '下一阶段计划', link: '/docs/next-stage-plan' }, { text: '许可与署名', link: '/docs/licensing' }] }
]

export default defineConfig({
  title: 'Agent Systems Engineering',
  description: '从 LLM 应用到可恢复的 Agent 系统：30 章正文草稿、25 份实验和 12 个课程单元。',
  lang: 'zh-CN',
  base,
  srcDir: '.content',
  cleanUrls: false,
  lastUpdated: false,
  vite: { plugins: [thirdPartyLicenses({ root })] },
  head: [['link', { rel: 'icon', type: 'image/svg+xml', href: base + 'logo.svg' }]],
  themeConfig: {
    logo: '/logo.svg',
    siteTitle: 'Agent Systems Engineering',
    nav: [{ text: '开始学习', link: '/start' }, { text: '阅读正文', link: '/reading' }, { text: '课程地图', link: '/docs/course-map' }, { text: '教师参考', link: '/teaching' }],
    sidebar,
    outline: { level: [2, 3], label: '本页目录' },
    docFooter: { prev: '上一篇', next: '下一篇' },
    sidebarMenuLabel: '全书与实验目录',
    returnToTopLabel: '返回顶部',
    darkModeSwitchLabel: '阅读配色',
    lightModeSwitchTitle: '切换浅色',
    darkModeSwitchTitle: '切换深色',
    skipToContentLabel: '跳到正文',
    externalLinkIcon: true,
    socialLinks: [{ icon: 'github', link: repo, ariaLabel: 'GitHub 源码仓库（需访问权限）' }],
    editLink: { pattern: ({ relativePath }) => '/docs/errata.html?page=' + encodeURIComponent(relativePath), text: '报告本页问题' },
    footer: {
      message: `教材 <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a> · 代码 <a href="${base}licenses/LICENSE.txt">Apache-2.0</a> · <a href="${base}docs/licensing.html">许可范围与署名</a> · <a href="${base}licenses/third-party/index.html" target="_self">第三方版权与许可证</a>`,
      copyright: 'Agent Systems Lab contributors · 0.1.0-dev'
    },
    search: { provider: 'local', options: {
      miniSearch: { options: { tokenize: tokenizeReadingText }, searchOptions: { boostDocument: boostReadingDocument } },
      translations: { button: { buttonText: '搜索书与实验', buttonAriaLabel: '搜索教材、实验与参考手册' }, modal: { noResultsText: '没有找到相关内容，试试“状态机”“幂等”或实验编号。', resetButtonTitle: '清空搜索', displayDetails: '显示段落', backButtonTitle: '返回搜索', footer: { selectText: '打开', navigateText: '切换结果', closeText: '关闭' } } }
    } },
    notFound: { code: '404', title: '没有找到这一页', quote: '可以返回首页，选择已有正文草稿与实验。', linkLabel: '返回首页', linkText: '返回首页' }
  },
  markdown: {
    codeCopyButtonTitle: '复制代码',
    // Preserve the existing GitHub fragments, including numbered Chinese headings.
    anchor: { slugify: slug },
    headers: { slugify: slug },
    toc: { slugify: slug },
    languages: ['elixir', 'erlang', 'bash', 'sql', 'json', 'python'],
    config(md) {
      md.core.ruler.after('inline', 'repository-links', state => {
        const current = String(state.env.relativePath || 'index.md')
        for (const token of state.tokens) for (const child of token.children || []) {
          if (child.type !== 'link_open') continue
          const href = child.attrGet('href')
          if (!href || /^(?:[a-z][a-z\d+.-]*:|\/\/|#)/i.test(href)) continue
          const [target, fragment] = href.split(/#(.*)/s)
          if (target.startsWith('/')) continue
          let decoded
          try { decoded = decodeURIComponent(target) } catch { throw new Error(`Invalid link ${href} in ${current}`) }
          const relative = path.posix.normalize(path.posix.join(path.posix.dirname(current), decoded))
          if (relative.startsWith('../')) throw new Error(`Link escapes repository: ${href} in ${current}`)
          if (relative === 'README.md') child.attrSet('href', '/' + 'project.md' + (fragment === undefined ? '' : '#' + fragment))
          else if (relative === 'book/reading-route.md') child.attrSet('href', '/reading.md' + (fragment === undefined ? '' : '#' + fragment))
          else if (/^website\/(?:index|start|reading|teaching)\.md$/.test(relative)) child.attrSet('href', '/' + relative.slice('website/'.length) + (fragment === undefined ? '' : '#' + fragment))
          else if (existsSync(path.join(source, relative)) && relative.endsWith('.md')) continue
          else if (['LICENSE', 'LICENSE-DOCS', 'NOTICE'].includes(relative)) child.attrSet('href', '/licenses/' + relative + '.txt')
          else if (relative.startsWith('artifacts/')) {
            child.attrSet('href', '/docs/evidence-guide.md')
            child.attrSet('title', '历史原始证据由维护者另行保存；查看获取与阅读说明')
          }
          else if (existsSync(path.join(root, '..', relative))) child.attrSet('href', repo + (statSync(path.join(root, '..', relative)).isDirectory() ? '/tree/main/' : '/blob/main/') + relative.split('/').map(encodeURIComponent).join('/') + (fragment === undefined ? '' : '#' + fragment))
          else if (target.startsWith('/')) continue
          else throw new Error(`Unmapped reading link ${href} in ${current}`)
        }
      })
      const fence = md.renderer.rules.fence!
      md.renderer.rules.fence = (tokens, index, options, env, self) => {
        if (tokens[index].info.trim() === 'mermaid') {
          let heading = '系统流程'
          for (let i = 0; i < index; i++) if (tokens[i].type === 'heading_open' && tokens[i + 1]?.type === 'inline') heading = tokens[i + 1].content
          const label = ('图示：' + heading).replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[character]!)
          return `<MermaidDiagram code="${Buffer.from(tokens[index].content).toString('base64')}" label="${label}" />`
        }
        return fence(tokens, index, options, env, self)
      }
    }
  }
})
