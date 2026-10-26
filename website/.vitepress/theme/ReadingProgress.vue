<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { useData, useRoute, withBase } from 'vitepress'
import chapterEntries from '../../chapters.json'

defineProps<{ trackOnly?: boolean }>()

const chapters = chapterEntries.map(chapter => ({ path: `/book/${chapter.file}.html`, title: chapter.title }))

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
