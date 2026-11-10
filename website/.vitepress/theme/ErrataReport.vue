<script setup>
import { computed, onMounted, reactive, ref } from 'vue'
import { createErrataReport, issueDraft } from '../../scripts/errata-report.mjs'

const values = reactive({ where: '', version: '', category: '文字或解释', expected: '', actual: '', evidence: '', environment: '' })
const report = computed(() => createErrataReport(values))
const issueUrl = computed(() => issueDraft(values))
const status = ref('')
onMounted(() => {
  values.where = (new URLSearchParams(window.location.search).get('page') || '').slice(0, 300)
})
async function copyReport() {
  try { await navigator.clipboard.writeText(report.value); status.value = '报告已复制。请检查内容后再转交。' }
  catch { status.value = '复制未成功，请选中下方报告手动复制，或下载文本。' }
}
function downloadReport() {
  const url = URL.createObjectURL(new Blob([report.value], { type: 'text/plain;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = 'agent-systems-erratum.txt'
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
  status.value = '已发起文本下载。保存后可附到 GitHub Issue；这一步没有提交反馈。'
}
</script>

<template>
  <section class="errata-report" aria-label="勘误报告工具">
    <p class="errata-note">填写内容只保留在当前页面，不会自动发送或保存；离开页面前请复制或下载。请删去 token、密码、连接串与无关私人内容。</p>
    <div class="errata-fields">
      <label for="errata-where">页面 / 小节<input id="errata-where" v-model="values.where" maxlength="300" placeholder="例如第 16 章 16.4，或 L01 第 0 节"></label>
      <label for="errata-version">材料版本 / 完整 commit<input id="errata-version" v-model="values.version" maxlength="150" placeholder="从实验包清单或源码填写；不知道可填“未知”"></label>
      <label for="errata-category">问题类型<select id="errata-category" v-model="values.category"><option>文字或解释</option><option>技术准确性</option><option>练习或参考答案</option><option>阅读功能或材料获取</option></select></label>
      <label for="errata-expected">我的理解 / 期望结果<textarea id="errata-expected" v-model="values.expected" rows="3" maxlength="8000"></textarea></label>
      <label for="errata-actual">实际文字 / 命令与返回<textarea id="errata-actual" v-model="values.actual" rows="4" maxlength="8000"></textarea></label>
      <label for="errata-evidence">最小复现 / 可检查依据<textarea id="errata-evidence" v-model="values.evidence" rows="3" maxlength="8000"></textarea></label>
      <label for="errata-environment">环境与影响范围<textarea id="errata-environment" v-model="values.environment" rows="2" maxlength="2000" placeholder="例如 Ubuntu core；阻塞哪一步；未执行可直接注明"></textarea></label>
    </div>
    <div class="errata-actions"><button type="button" @click="copyReport">复制报告</button><button type="button" @click="downloadReport">下载文本报告</button></div>
    <p class="errata-status" role="status" aria-live="polite">{{ status }}</p>
    <details><summary>检查生成的报告</summary><textarea class="errata-preview" :value="report" readonly rows="14" aria-label="生成的勘误报告"></textarea></details>
    <p>检查报告后可打开 GitHub Issue 草稿。点击会将报告内容交给 GitHub，仍需登录 GitHub 并确认提交；提交后的 Issue 对外公开。</p>
    <a v-if="issueUrl" :href="issueUrl" target="_blank" rel="noopener noreferrer">打开 GitHub Issue 草稿（需登录）</a>
    <p v-else>报告较长，请复制或下载后，手动粘贴到<a href="https://github.com/zyg0733/agent-systems-engineering/issues/new" target="_blank" rel="noopener noreferrer">GitHub Issue（需登录）</a>。</p>
  </section>
</template>

<style scoped>
.errata-report { border: 1px solid var(--vp-c-divider); border-radius: 12px; padding: 20px; margin: 24px 0; }
.errata-note { color: var(--vp-c-text-2); font-size: 14px; }
.errata-fields { display: grid; gap: 16px; }
.errata-fields label { display: grid; gap: 6px; font-size: 14px; font-weight: 600; }
.errata-report input, .errata-report textarea, .errata-report select { box-sizing: border-box; width: 100%; min-width: 0; border: 1px solid var(--vp-c-divider); border-radius: 6px; background: var(--vp-c-bg); color: var(--vp-c-text-1); padding: 8px 10px; font: inherit; }
.errata-report textarea { resize: vertical; font-weight: 400; }
.errata-report :is(input, textarea, select, button, a, summary):focus-visible { outline: 2px solid var(--vp-c-brand-1); outline-offset: 3px; }
.errata-actions { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 20px; }
.errata-actions button { border: 1px solid var(--vp-c-brand-1); border-radius: 6px; padding: 8px 14px; font-weight: 600; color: var(--vp-c-brand-1); cursor: pointer; }
.errata-status { min-height: 1.5em; color: var(--vp-c-text-2); font-size: 14px; }
.errata-preview { margin-top: 12px; }
.errata-report a { overflow-wrap: anywhere; }
@media (max-width: 480px) { .errata-report { padding: 14px; } }
</style>
