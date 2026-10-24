<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { useData } from 'vitepress'

const props = defineProps<{ code: string }>()
const { isDark } = useData()
const chart = computed(() => new TextDecoder().decode(Uint8Array.from(atob(props.code), character => character.charCodeAt(0))))
const svg = ref('')
const failed = ref(false)
let mounted = false
let generation = 0

async function render() {
  if (!mounted) return
  const current = ++generation
  try {
    const { default: mermaid } = await import('mermaid')
    mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: isDark.value ? 'dark' : 'neutral', fontFamily: 'system-ui, sans-serif' })
    const result = await mermaid.render('diagram-' + crypto.randomUUID(), chart.value)
    if (current === generation) { svg.value = result.svg; failed.value = false }
  } catch {
    if (current === generation) { svg.value = ''; failed.value = true }
  }
}
onMounted(() => { mounted = true; render() })
watch([() => props.code, isDark], render)
</script>

<template>
  <figure class="reading-diagram" aria-label="系统流程图">
    <div v-if="svg" class="reading-diagram-svg" v-html="svg" />
    <pre v-else><code>{{ chart }}</code></pre>
    <figcaption v-if="failed">图示暂未渲染，以上为完整 Mermaid 源码。</figcaption>
  </figure>
</template>

<style scoped>
.reading-diagram { margin: 24px 0; overflow-x: auto; text-align: center; }
.reading-diagram :deep(svg) { max-width: 100%; height: auto; margin: auto; }
.reading-diagram pre { text-align: left; }
.reading-diagram figcaption { font-size: 13px; color: var(--vp-c-text-2); }
</style>
