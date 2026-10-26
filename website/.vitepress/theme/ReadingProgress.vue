<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useData, useRoute, withBase } from 'vitepress'

defineProps<{ trackOnly?: boolean }>()

const chapters = [
  { path: '/book/ch01-from-llm-apps-to-agent-systems-engineering.html', title: '第 1 章 · 从 LLM 应用到 Agent Systems Engineering' },
  { path: '/book/ch02-agent-state-machine.html', title: '第 2 章 · 状态机、命令、事件与系统不变量' },
  { path: '/book/ch05-agent-loop-and-tools.html', title: '第 5 章 · Agent Loop 的理论、设计与实现' },
  { path: '/book/ch08-session-context.html', title: '第 8 章 · Session、Turn、Message 与状态演化' },
  { path: '/book/ch14-history-checkpoints-and-replay.html', title: '第 14 章 · Event History、Checkpoint 与纯重建' },
  { path: '/book/ch16-durable-effects-and-reconciliation.html', title: '第 16 章 · 外部效果、提交协议与 Unknown 核对' },
  { path: '/book/ch20-scheduling-and-recovery.html', title: '第 20 章 · Lease、Heartbeat、超时与任务所有权' },
]

const { site } = useData()
const route = useRoute()
const lastPath = ref<string | null>(null)
const lastChapter = computed(() => chapters.find((chapter) => chapter.path === lastPath.value))
const storageKey = computed(() => `ase:reading:${site.value.base}`)
let stopWatching: (() => void) | undefined

function findChapter(path: string) {
  const base = site.value.base
  let relative = path.split(/[?#]/, 1)[0]
  if (base !== '/' && relative.startsWith(base)) {
    relative = `/${relative.slice(base.length)}`
  }
  return chapters.find((chapter) =>
    relative === chapter.path || relative === chapter.path.replace(/\.html$/, ''),
  )
}

function restore() {
  try {
    const path = window.localStorage.getItem(storageKey.value)
    lastPath.value = chapters.some((chapter) => chapter.path === path) ? path : null
  } catch {
    lastPath.value = null
  }
}

function record(path: string) {
  const chapter = findChapter(path)
  if (!chapter) return
  try {
    window.localStorage.setItem(storageKey.value, chapter.path)
    lastPath.value = chapter.path
  } catch {
    // Reading works normally when the browser disables local storage.
  }
}

function clear() {
  try {
    window.localStorage.removeItem(storageKey.value)
  } catch {
    // Keep the control usable even if storage permission changed after mounting.
  }
  lastPath.value = null
}

function sync(event: StorageEvent) {
  if (event.key === storageKey.value || event.key === null) restore()
}

onMounted(() => {
  restore()
  stopWatching = watch(() => route.path, record, { immediate: true })
  window.addEventListener('storage', sync)
})

onBeforeUnmount(() => {
  stopWatching?.()
  window.removeEventListener('storage', sync)
})
</script>

<template>
  <section v-if="!trackOnly && lastChapter" class="reading-progress" aria-label="继续阅读">
    <div class="reading-progress-copy">
      <span class="section-kicker">最近阅读的章节</span>
      <a :href="withBase(lastChapter.path)" class="reading-progress-link">
        {{ lastChapter.title }} <span aria-hidden="true">→</span>
      </a>
      <span class="reading-progress-note">仅记录最近打开的章节，保存在此浏览器。</span>
    </div>
    <button class="reading-progress-clear" type="button" @click="clear">清除记录</button>
  </section>
</template>
