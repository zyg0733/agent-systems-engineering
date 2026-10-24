# Agent Systems Lab

《Agent Systems Engineering》的 Elixir/OTP 配套实验项目，学习如何把 Agent 的状态、外部效果与恢复过程变成可检查的事实。固定 Scripted/Recorded Provider、Mock 与受控工具支持离线复现，**无需模型密钥**。

项目覆盖纯状态机、事务与事件历史、Streaming 和预算、Session/Context、工具回执与核对、崩溃恢复、多 Worker 调度、lease/fencing、隔离执行、MCP stdio、DAG、人工审批、观测与固定评测。配套 **25 份实验手册、12 个课程单元、30 张章节设计卡和六章试读稿**。

当前版本为 **`0.1.0-dev`**。W26 技术交付已完成；`v0.1.0-rc.1` 是历史候选包的清单标签，正式 `0.1.0` 尚未发布。

源码仓库：[zyg0733/agent-systems-engineering](https://github.com/zyg0733/agent-systems-engineering)（私有仓库，需获得访问权限）。远程检查见 [GitHub Actions](https://github.com/zyg0733/agent-systems-engineering/actions)，结果以具体提交对应的运行记录为准。

## 快速开始

以下命令在克隆或下载后的**项目根目录**执行。实际验收组合为 macOS arm64、Elixir **1.20.4**、Erlang/OTP **28.4**、PostgreSQL **18.6**；精确依赖见 [mix.lock](mix.lock)。macOS 安装脚本也提供 x86_64 下载路径，该架构尚未取得本项目实际验收证据。

新克隆目录不包含 `.runtime/`、`deps/`、`_build/` 或实验数据库。先安装运行时与依赖，再运行最小内存演示：

```sh
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

需要数据库的完整实验继续执行：

```sh
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
./scripts/mix setup
LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

安装脚本把运行时、缓存与 PostgreSQL 放在项目的 `.runtime/` 内。需普通非 root 用户、macOS 开发工具和下载/解压工具；PostgreSQL 从源码构建，还需 C 编译器、make、Bison、Flex 和 Perl。完整前置与跨环境执行见[环境操作手册](docs/cross-environment-validation.md#1-选源码分清执行范围)。

默认连接为 `127.0.0.1:55432`，用户 `postgres`，开发/测试库分别为 `agent_systems_lab_dev`、`agent_systems_lab_test`；本地实例使用 trust 认证。可用 `DATABASE_URL` 或 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 指定自己的实验实例。`check` 会创建/迁移测试库，运行真实 PostgreSQL 集成和受控崩溃验收；各实验的数据库与输出要求见对应手册。

`./scripts/mix`、`./scripts/iex` 优先使用项目内运行时，缺少该安装时使用 PATH 中的 Elixir；它们不会自动安装软件。维护者已有安装的本地工作副本可先运行 `./scripts/postgres status`，再运行 `./scripts/mix check`。已有全局工具链也可直接使用 `mix`。

只做内存回归时使用 `LAB_DATABASE_ENABLED=false ./scripts/mix test`，数据库用例会报告为排除。Linux 需另备固定版本的 BEAM/PostgreSQL；[Linux CI 说明](docs/github-ci.md)记录适用范围与执行状态。

## 学习路线与文档

1. 从 [L01 状态机实验](labs/L01-state-machine.md)、[架构说明](docs/architecture.md)和 [Kernel 源码](lib/agent_systems_lab/kernel.ex)开始，理解纯状态转换、命令与事件。
2. 按 [C01—C12 课程地图](docs/course-map.md)推进事务、工具、历史恢复、调度、隔离与编排。实验分册保留 L01—L25 编号，课程单元与实验编号分别使用。
3. 阅读[六章试读指南](book/reader-study/README.md)与[30 张章节设计卡](book/chapter-cards.md)。章节设计卡包含其余章节规划，六章正文仍需外部试读与技术审校。
4. 用[命令与实现参考](docs/command-reference.md)、[公开接口与扩展契约](docs/public-interfaces.md)查具体入口，按[恢复运行手册](docs/recovery-runbook.md)处理 unknown、回执、审批与恢复。

| 需要做的事 | 文档入口 |
| --- | --- |
| 查全部实验命令与实现边界 | [命令与实现参考](docs/command-reference.md)、[公开接口](docs/public-interfaces.md) |
| 导出源码、复现并采集环境证据 | [跨环境执行](docs/cross-environment-validation.md)、[L25](labs/L25-cross-environment-validation.md) |
| 核对候选、试读与发行门槛 | [发行评估](docs/release-assessment.md)、[发布操作](docs/release-operations.md) |
| 查看实际验收与剩余工作 | [W26 验收](docs/validation-week26.md)、[结果索引](docs/results-index.md)、[证据阅读说明](docs/evidence-guide.md)、[下一阶段计划](docs/next-stage-plan.md) |
| 查看 GitHub 接入记录与检查 CI | [首次入库说明](docs/github-onboarding.md)、[GitHub CI](docs/github-ci.md) |

## 已验收基线与当前限制

[W26 实际验收](docs/validation-week26.md)于 **2026-10-24（Asia/Shanghai）**，在同一 macOS arm64 宿主使用声明的 warm cache、新源码工作区、重新编译的依赖与独立 PostgreSQL 完成：

| 验证项 | W26 冻结源码的实际结果 |
| --- | --- |
| 完整 `./scripts/mix check` | **1093 项通过**（1091 tests + 2 doctests），0 排除；另含 10/10 固定场景和 PostgreSQL 提交边界检查 |
| 内存回归 | **628 项通过**（626 tests + 2 doctests），465 项数据库用例排除 |
| Python 执行器专项 | **36/36 通过** |
| 六个主实验 | verify、p1、history、recover、fence、upgrade 全部通过 |

这些数字绑定 W26 冻结源码与对应原始报告；后续源码或文档整理需重新核对，不能继承为新版本的执行证明。历史 `artifacts/` 默认不进入 Git，源码仓库保留验收叙述与操作说明，原始材料由维护者另行保存和移交。

当前待验收项包括：**真实新 macOS 主机冷安装、实际 Linux 适用回归、完整 Linux 隔离/冻结矩阵，以及 3—5 名独立真人试读**（当前 0 名）。CI 配置或 Linux 计划不构成已执行证据；Linux 核心回归排除 Seatbelt，不能满足完整 Linux 门槛。旧候选一次隔离失败的根因仍未定位，原失败记录保留。

运行时目前使用 Scripted/Recorded Provider，尚未接入真实厂商模型；隔离是 macOS Seatbelt 教学后端，Linux 后端未实现。外部效果不确定时进入 unknown/manual 核对，取消不会撤销已有效果。项目面向单可信宿主与单 PostgreSQL；完整边界见[已知限制](docs/known-limitations.md)。

正式发布保持 `evidence_complete=false`、`approval_recorded=false`、`release_ready=false`。首次 GitHub 托管与正式版本发行分别验收。

## 许可证

本项目原创代码、脚本、测试、配置和教材中的原创代码示例采用 [Apache-2.0](LICENSE)；教材正文、实验讲解及原创图表采用 [CC BY 4.0](LICENSE-DOCS)。转载或改编教材时请保留署名、许可链接并标明修改。

具体目录与内容边界见[许可范围说明](docs/licensing.md)，项目声明见 [NOTICE](NOTICE)。第三方依赖、引用、图片和代码保留其原有许可与署名，不因所在目录而重新授权。
