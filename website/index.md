---
layout: home
title: Agent Systems Engineering
titleTemplate: false
description: 从 LLM 应用到可恢复的 Agent 系统。30 章正文草稿、25 份实验手册与 12 单元课程，一边阅读，一边用代码验证系统不变量。
hero:
  name: Agent Systems
  text: Engineering
  tagline: 从纯状态机到可恢复的 Agent 系统
  image:
    src: /logo.svg
    alt: 打开的书页与连接状态、事件和恢复的轨迹
  actions:
    - theme: brand
      text: 开始学习
      link: /start
    - theme: alt
      text: 阅读正文与导读
      link: /reading
    - theme: alt
      text: 做首次小练习
      link: /labs/L01-state-machine#first-exercise
features:
  - title: 把行为写成事实
    details: 从命令、事件与纯状态转换出发。先说清系统不变量，再决定进程如何协作。
  - title: 在故障中理解恢复
    details: 沿事务、回执、历史与租约，观察崩溃发生在哪里，哪些事实能够被信任。
  - title: 用实验验证理解
    details: 固定的离线 Provider 与受控工具，无需模型密钥。把预测、代码和真实输出放在一起。
---

<div class="book-home">

<div class="edition-note"><span class="edition-badge">0.1.0-dev · 持续写作中</span><span>七篇三十章正文草稿已齐，按实现、反例与实验逐章审校。</span></div>

<ReadingProgress />

<section class="home-section" aria-labelledby="shelf-title">
  <div class="section-heading"><div><span class="section-kicker">阅读 · 实验 · 复验</span><h2 id="shelf-title">一本书，也是一间实验室</h2></div><p>沿着同一套可检查的实现，<br>把“应该如此”变成“证据如此”。</p></div>

  <div class="book-stats" aria-label="当前内容规模">
    <div><strong>30</strong><span>章正文草稿</span></div>
    <div><strong>25</strong><span>份实验手册</span></div>
    <div><strong>12</strong><span>个课程单元</span></div>
    <div><strong>30</strong><span>张章节设计卡</span></div>
  </div>

  <div class="reading-paths">
    <a class="reading-path" href="./reading.html"><span class="path-number">01 / 读</span><h3>建立系统直觉</h3><p>按七篇阅读状态、执行、上下文、恢复、调度、安全与系统验收。</p><span class="path-link">选择阅读章节 <span aria-hidden="true">↗</span></span></a>
    <a class="reading-path" href="./labs/L01-state-machine.html#first-exercise"><span class="path-number">02 / 做</span><h3>先完成一条小轨迹</h3><p>预测合法与非法转换，写一个断言，再检查重建为何不执行工具。</p><span class="path-link">进入首次小练习 <span aria-hidden="true">↗</span></span></a>
    <a class="reading-path" href="./docs/course-map.html"><span class="path-number">03 / 连</span><h3>按课程逐步推进</h3><p>用 12 个主题单元组织实验，明确依赖、学生任务与成功标准。</p><span class="path-link">查看完整课程地图 <span aria-hidden="true">↗</span></span></a>
  </div>
</section>

<section class="home-section book-principle" aria-labelledby="principle-title">
  <span class="section-kicker">贯穿全书的问题</span><h2 id="principle-title">工具已经执行成功，<br>但回执丢了。接下来呢？</h2><p>重试、取消、重启和继续执行，各自需要什么证据？<br>我们从这些具体问题出发，设计可解释、可检查、可恢复的 Agent 系统。</p><a class="text-link" href="./book/ch16-durable-effects-and-reconciliation.html">阅读外部效果与 Unknown 核对 <span aria-hidden="true">→</span></a>
</section>

<section class="home-section home-footnote" aria-label="内容与使用说明">
  <p>正文、实验和章节设计卡分别标明完成状态。先看<a href="./book/prerequisites.html">先修与桥接</a>，随时查<a href="./book/glossary.html">术语表</a>。实际实验在本地源码中运行，<a href="./docs/current-status.html">当前状态与平台边界</a>单列。</p><p>原创代码采用 Apache-2.0，教材正文与原创图表采用 CC BY 4.0。<a href="./docs/licensing.html">查看许可范围</a> · <a href="./teaching.html">教师与授课说明</a></p>
</section>

</div>
