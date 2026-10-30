import { defineComponent, h, nextTick, onBeforeUnmount, onMounted } from 'vue'
import DefaultTheme from 'vitepress/theme'
import type { Theme } from 'vitepress'
import ReadingProgress from './ReadingProgress.vue'
import MermaidDiagram from './MermaidDiagram.vue'
import ErrataReport from './ErrataReport.vue'
import './style.css'

export default {
  extends: DefaultTheme,
  Layout: defineComponent({
    setup() {
      let focusFrame = 0
      function restoreSearchFocus(event: KeyboardEvent) {
        if (event.key !== 'Escape' || !document.querySelector('#localsearch-input')) return
        // VitePress 1.6.4 closes local search without restoring its trigger.
        nextTick(() => {
          focusFrame = requestAnimationFrame(() => {
            if (document.querySelector('#localsearch-input')) return
            if (document.activeElement && document.activeElement !== document.body) return
            document.querySelector<HTMLButtonElement>('.VPNavBarSearch button')?.focus({ preventScroll: true })
          })
        })
      }
      onMounted(() => window.addEventListener('keydown', restoreSearchFocus, true))
      onBeforeUnmount(() => {
        window.removeEventListener('keydown', restoreSearchFocus, true)
        cancelAnimationFrame(focusFrame)
      })
      return () => h(DefaultTheme.Layout, null, {
        'layout-bottom': () => h(ReadingProgress, { trackOnly: true }),
      })
    },
  }),
  enhanceApp({ app }) {
    app.component('ReadingProgress', ReadingProgress)
    app.component('MermaidDiagram', MermaidDiagram)
    app.component('ErrataReport', ErrataReport)
  },
} satisfies Theme
