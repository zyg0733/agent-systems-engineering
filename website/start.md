---
title: 开始学习
description: 选择阅读、实验或授课路线，从第一个状态机进入 Agent Systems Engineering。
---

# 开始学习

先读一章，再完成一个能解释清楚的实验。本书适合写过程序、想理解 Agent 执行与恢复机制的读者；动手部分逐步需要 Elixir/OTP、进程与 SQL 事务知识。你不需要准备模型密钥；当前实现使用固定 Scripted/Recorded Provider、Mock 与受控工具。

开始前用[阅读准备与先修桥接](../book/prerequisites.md)的五道自测找出需要补读的概念。只读设计无需立即安装环境；运行代码则需要仓库访问权和对应平台。

## 选择你的入口

| 你现在想做什么 | 从这里开始 |
| --- | --- |
| 先理解系统设计 | [第 1 章：从 LLM 应用到 Agent Systems Engineering](../book/ch01-from-llm-apps-to-agent-systems-engineering.md)，再按[阅读路线](../book/reading-route.md)进入第 2 章状态机 |
| 直接动手运行 | 先完成下方演示，再做 [L01 首次小练习](../labs/L01-state-machine.md#first-exercise)：预测状态、拒绝错 ID、核对重建前后的 Mock 计数 |
| 系统学习全部主题 | [C01—C12 课程地图](../docs/course-map.md)，按课程依赖组织 25 份实验手册 |
| 组织课程或读书会 | [教师与授课说明](teaching.md)，先确定范围、独立练习副本和证据要求 |

## 跑通第一个演示

运行实验需要源码。仓库目前为[私有仓库](https://github.com/zyg0733/agent-systems-engineering)，克隆前需获得访问权限。

以下是已验收的 macOS 路线，在克隆后的**项目根目录**执行。首次安装需要下载运行时和依赖；安装脚本会将它们放入项目的 `.runtime/`。详细平台和工具要求见[跨环境执行说明](../docs/cross-environment-validation.md)。

```sh
git clone https://github.com/zyg0733/agent-systems-engineering.git
cd agent-systems-engineering
sh scripts/bootstrap_runtime.sh
./scripts/mix local.hex --force
./scripts/mix deps.get
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.demo
```

成功输出的末两行为：

```text
status=succeeded turns=2 requests=1 effects=1
rebuild_matches=true (in-memory history; no durable storage)
```

这一步只运行内存演示。接着完成 [L01 首次小练习](../labs/L01-state-machine.md#first-exercise)，亲自检查 `command → event → state` 的关系。小练习完成后再进入 L01 的完整任务，不需要先跑全仓库回归才能开始学习。

遇到 `state/status`、`rebuild/resume` 或 `unknown/error` 时，先查[共用术语表](../book/glossary.md)。安装下载、阅读、执行和排错应分别记录；此处没有承诺固定的首次学习用时。

## 再进入持久化与恢复

后续实验使用真实 PostgreSQL。共同验收版本为 Elixir **1.20.4**、Erlang/OTP **28.4**、PostgreSQL **18.6**；精确依赖以源码的 `mix.lock` 为准。

```sh
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

请使用自己的实验数据库。默认本地端口为 `55432`，开发库与测试库分别为 `agent_systems_lab_dev`、`agent_systems_lab_test`；具体连接、输出目录及故障注入要求按每份实验手册执行。

如果使用自定义实例，先用 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 选定专用实验实例，再在同一终端执行 `unset DATABASE_URL`；完整回归使用默认测试库名。单次 `env -u` 不会修改父终端；后续每份实验的完整 `check` 都显式移除 URL，避免恢复测试的动态 Repo 被全局 URL 改指目标库。

后续命令在这个终端继续执行；另开终端时重设上述环境变量。按[阅读与实验路线](../book/reading-route.md#把阅读路线走成实验路线)逐段记录预测、当前产物和换条件后的解释，再查对应解答；运行演示不等于独立完成整份作业。

Linux 的适用回归范围见 [GitHub CI 说明](../docs/github-ci.md)。完整隔离实验使用 macOS Seatbelt 教学后端，Linux 隔离后端尚未实现。按[当前状态与边界](../docs/current-status.md)判断哪些实验适合当前环境。

## 每次实验留下三样东西

1. **预测**：写出应保持的不变量，以及这个故障窗口可能留下的状态。
2. **证据**：保存实际命令、退出码、原始输出和新生成的报告，不覆盖旧产物。
3. **解释**：比较预测与结果，说明下一步执行凭什么安全。

遇到问题时，先查[术语表](../book/glossary.md)、[命令与实现参考](../docs/command-reference.md)和[恢复运行手册](../docs/recovery-runbook.md)，再沿对应实验回到源码与测试。课程的具体任务、评分与成功标准以[课程地图](../docs/course-map.md)为准。

::: info 当前内容状态
本站对应 `0.1.0-dev`：7 章正文草稿（含第 1 章导读）、25 份实验手册、12 个课程单元与 30 张章节设计卡。设计卡用于说明写作计划与依赖，正式 `0.1.0` 尚未发布。
:::
