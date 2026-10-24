import { defineConfig } from 'vitepress'
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { slug } from 'github-slugger'

const root = fileURLToPath(new URL('../', import.meta.url))
const source = path.join(root, '.content')
const base = process.env.SITE_BASE || '/agent-systems-engineering/'
if (!/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(base)) throw new Error('SITE_BASE must be a slash-delimited URL path')
const repo = 'https://github.com/zyg0733/agent-systems-engineering'
const chapters = [
  ['第 2 章 · 状态机与不变量', 'ch02-agent-state-machine'],
  ['第 5 章 · Agent Loop 与工具', 'ch05-agent-loop-and-tools'],
  ['第 8 章 · Session 与 Context', 'ch08-session-context'],
  ['第 14 章 · 历史、检查点与重放', 'ch14-history-checkpoints-and-replay'],
  ['第 16 章 · 持久效果与核对', 'ch16-durable-effects-and-reconciliation'],
  ['第 20 章 · 调度与恢复', 'ch20-scheduling-and-recovery']
].map(([text, file]) => ({ text, link: '/book/' + file }))
const labs = readdirSync(path.join(source, 'labs')).filter(file => /^L\d\d-.*\.md$/.test(file)).sort().map(file => ({
  text: readFileSync(path.join(source, 'labs', file), 'utf8').split('\n')[0].replace(/^#\s*/, ''),
  link: '/labs/' + file.replace(/\.md$/, '')
}))
const sidebar = [
  { text: '从这里开始', items: [{ text: '开始学习', link: '/start' }, { text: '阅读路线与章节', link: '/reading' }, { text: '环境准备与项目说明', link: '/project' }] },
  { text: '六章试读正文', items: chapters },
  { text: '动手实验 · L01—L25', collapsed: true, items: labs },
  { text: '课程与教学', collapsed: true, items: [{ text: 'C01—C12 课程地图', link: '/docs/course-map' }, { text: '全书 30 章设计卡', link: '/book/chapter-cards' }, { text: '教师参考与使用方式', link: '/teaching' }, { text: '正式试读与反馈协议', link: '/book/reader-study/README' }] },
  { text: '随手查阅', collapsed: true, items: [{ text: '架构与系统边界', link: '/docs/architecture' }, { text: '命令与实现参考', link: '/docs/command-reference' }, { text: '公开接口与扩展', link: '/docs/public-interfaces' }, { text: '恢复运行手册', link: '/docs/recovery-runbook' }, { text: '已知限制', link: '/docs/known-limitations' }] },
  { text: '项目与维护', collapsed: true, items: [{ text: '源码检查与 CI', link: '/docs/github-ci' }, { text: '阅读站维护', link: '/docs/reading-site' }, { text: '教材质量与试读计划', link: '/docs/public-reading-quality-plan' }, { text: '结果与历史记录', link: '/docs/results-index' }, { text: '下一阶段计划', link: '/docs/next-stage-plan' }, { text: '许可与署名', link: '/docs/licensing' }] }
]

export default defineConfig({
  title: 'Agent Systems Engineering',
  description: '从纯状态机到可恢复的 Agent 系统：六章试读、25 份实验和 12 个课程单元。',
  lang: 'zh-CN',
  base,
  srcDir: '.content',
  cleanUrls: false,
  lastUpdated: false,
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
    editLink: { pattern: ({ relativePath }) => `https://github.com/zyg0733/agent-systems-engineering/edit/main/${relativePath === 'project.md' ? 'README.md' : /^(index|start|reading|teaching)\.md$/.test(relativePath) ? 'website/' + relativePath : relativePath}`, text: '在 GitHub 查看或改进本页' },
    footer: {
      message: `教材 <a href="https://creativecommons.org/licenses/by/4.0/">CC BY 4.0</a> · 代码 <a href="${base}licenses/LICENSE.txt">Apache-2.0</a> · <a href="${base}docs/licensing.html">许可范围与署名</a>`,
      copyright: 'Agent Systems Lab contributors · 0.1.0-dev'
    },
    search: { provider: 'local', options: {
      miniSearch: { options: {
        tokenize(text) {
          if (typeof Intl.Segmenter === 'function') return Array.from(new Intl.Segmenter('zh-CN', { granularity: 'word' }).segment(text)).filter(part => part.isWordLike).map(part => part.segment)
          return text.match(/[\u3400-\u9fff]|[\p{L}\p{N}_]+/gu) || []
        }
      } },
      translations: { button: { buttonText: '搜索书与实验', buttonAriaLabel: '搜索教材、实验与参考手册' }, modal: { noResultsText: '没有找到相关内容，试试“状态机”“幂等”或实验编号。', resetButtonTitle: '清空搜索', displayDetails: '显示段落', backButtonTitle: '返回搜索', footer: { selectText: '打开', navigateText: '切换结果', closeText: '关闭' } } }
    } },
    notFound: { code: '404', title: '没有找到这一页', quote: '可以返回首页，选择已完成的六章正文与实验。', linkLabel: '返回首页', linkText: '返回首页' }
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
        if (tokens[index].info.trim() === 'mermaid') return `<MermaidDiagram code="${Buffer.from(tokens[index].content).toString('base64')}" />`
        return fence(tokens, index, options, env, self)
      }
    }
  }
})
