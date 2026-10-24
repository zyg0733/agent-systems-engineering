import { h } from 'vue'
import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import ReadingProgress from './ReadingProgress.vue'
import MermaidDiagram from './MermaidDiagram.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  Layout: () =>
    h(DefaultTheme.Layout, null, {
      'layout-bottom': () => h(ReadingProgress, { trackOnly: true }),
    }),
  enhanceApp({ app }) {
    app.component('ReadingProgress', ReadingProgress)
    app.component('MermaidDiagram', MermaidDiagram)
  },
} satisfies Theme
