# 第 25 周验收记录

验证日期：2026-10-24（Asia/Shanghai）。**W25 技术实现和验收完成**：新增 39 项测试，完整回归 1073 项通过，内存回归 608 项通过；新试读包、发行评估和 CLI 集成通过。现有权限、已用预算、绝对 deadline、unknown/reconcile、审批与 fencing 语义保持。

原 W22 试读协议、W24 `v0.1.0-rc.1` 候选和完整 Linux 等现有发布门槛保留。实际真人仍为 0，冷主机和 Linux 外部证据未取得，对应项继续 pending；`evidence_complete=false`、`approval_recorded=false`、`publication_status=not_published`、`release_ready=false`。没有创建 tag、上传或发布。

## 交付与合同

| 交付 | 实际行为 |
| --- | --- |
| [ReleaseStudy](../lib/agent_systems_lab/release_study.ex) | 新 kind/schema 协议，必须显式选择已验证的 source-only 冻结导出；复制 project 后保留原 source manifest 字节，绑定六章和实验的 hash |
| `lab.reading.frozen` | prepare、add、append、report；旧 `lab.reading` 和 W22 合同不变 |
| 追加式反馈闭环 | 原始反馈字节独占保存；连续序号、事件 hash 链与 head；fix 引用问题，只有原读者对最近 fix 的同源码复验可关闭问题；新 fix 重开问题，旧复验不能关闭新 fix |
| [ReleaseAssessment](../lib/agent_systems_lab/release_assessment.ex) | 只读重算原候选、新试读账本和环境证据；缺证据 pending，存在但损坏、错版本或错源码时 error |
| `lab.release.assess` | 固定 v1 原完整 Linux 政策，不接受降门槛、批准或发布选项；证据齐备、批准和实际发布分开记录 |
| 教学与运行 | [L24](../labs/L24-versioned-release-assessment.md)、[解答](../labs/solutions/L24.md)、[ADR 0024](adr/0024-versioned-release-assessment.md)、[操作说明](release-assessment.md)、[运行手册第 23 节](recovery-runbook.md#23-版本化发行评估与追加式试读闭环)及公开接口、限制和 backlog 已更新 |

旧 `CandidatePackage` 仍保留其 rc.1、0 人、Linux pending、release false 历史合同，未手工修改字段。新评估政策 `v0.1-original-full-linux-v1` 保留 3—5 名真实读者、至少一次新工作区主实验、无未解决 blocker、完整 Linux 隔离与 12×20 矩阵要求，并按后续计划分别评估新 macOS 主机冷安装。Linux 适用子集与 Seatbelt 排除不能通过 full gate。

环境记录有 schema、源码与候选身份、安装输入、版本、固定 argv、退出码和 hash 绑定日志。成功 full/memory 日志的覆盖数量须与候选同源码基线相符，不能用更小但互相自洽的测试集合冒充全量。Linux 隔离逐项核对 required 能力、清理、后端与状态一致；只接受已声明的原 non-goals。

## 两个源码身份

| 身份 | 文件与 source manifest SHA-256 |
| --- | --- |
| W25 评估工具的执行源码 | **515 个文件、574 个文件/目录项、4,032,511 bytes**；`4fbe9b2b86a3b10038fce06272c60560511da3791731c8e3959885706c05ba16` |
| 被评估的 W24 rc.1 冻结源码 | **502 个文件**；`6e7d56c135e2774752035913daa99689e7a1ab8249164b34c52817916820b2a1` |

本周冻结副本在 `artifacts/week25-frozen-source/`，实际 cwd 为原工作区；执行前后逐文件核对 bytes/mode 相同，见 [source manifest](../artifacts/week25-acceptance/source-manifest.json)。没有把新工具的通过数改写为旧候选的新测试结果。

真实[新试读包入口](../artifacts/week25-reader-packet/START-HERE.md)绑定旧 rc.1 的冻结源码，包含 **507 个文件、569 个文件/目录项**。`project/` 是 W24 项目，没有新增的 W25 CLI；接收反馈和评估从可信 W25 宿主运行，读者在工作副本实验。原 project 内 W22 指南保留历史身份，新包根入口解释本轮协议。

本轮 `protocol_hash` 为 `9d2f7b085c5fde72fc15bcfc6eda15faaadc6b47ea732a68486319ce4726be40`；候选原 manifest 文件 SHA 为 `c3596200e9c305e4fbd35037c8af8e4bedc0a2ce5b0da0b4858eee780bfbbf70`。改变包内源码必须新建协议和重新取得适用反馈；同源码下的环境或解释修复才可在当前账本追加复验，不自动继承跨版本批准。

## 新增测试与完整回归

新增 **39 项纯文件测试**：ReleaseStudy 18 项、ReleaseAssessment 21 项。专项日志分别为 [18/18](../artifacts/week25-release-study-focused.log)与 [21/21](../artifacts/week25-release-assessment-focused.log)。覆盖原始 manifest/反馈字节、错误 source/protocol、重复读者、未知 schema/字段、路径与链接/容量边界、并发追加、事件先落而 head 未更新、旧 fix 复验失效、固定政策、外部日志/数量/隔离记录错配等。

完整外部门槛通过路径只使用临时合成 fixture，测试后删除；不计真人、冷主机或 Linux 实测。普通检查继续离线。

| 固定回归 | 实际结果 | 日志 |
| --- | --- | --- |
| `./scripts/mix check` | **1073 passed**，1071 tests + 2 doctests，0 失败；ExUnit 261.5s | [full_check](../artifacts/week25-acceptance/full_check.log) |
| `LAB_DATABASE_ENABLED=false ./scripts/mix test` | **608 passed**，606 tests + 2 doctests；**465 个数据库测试排除**；ExUnit 167.2s | [memory_check](../artifacts/week25-acceptance/memory_check.log) |

1073 = W24 的 1034 + 新增 39；608 = 569 + 39；608 + 465 = 1073。465 个数据库测试已在完整模式执行，排除不算通过。完整 check 同时通过格式、warnings-as-errors 编译、21 个迁移、原 **10/10 fixtures** 和 PostgreSQL COMMIT 前后崩溃验证。仅保留原 `frozen_matrix_fixture.exs` 的测试命名过滤提示，没有新增此类提示或放宽原断言。

[execution.json](../artifacts/week25-acceptance/execution.json)记录 **13 步全部退出 0**，UTC 2026-10-23 17:10:32 开始、17:18:00 进入最终停止步骤。完整与内存回归均在 umask 077 下执行；沿用现有 runtime、依赖和 build。现场为 macOS arm64、Mix 1.20.4、OTP 28（同安装树 marker 28.4）、PostgreSQL 18.6，见[环境观测](../artifacts/week25-acceptance/runtime-observation.json)，不声称冷安装。

本轮新建独占 PostgreSQL 集群，端口 55589，开始时没有项目库；`fsync/synchronous_commit/full_page_writes` 均为 on。最后按 PID 文件、PGDATA、端口精确绑定停止自有集群并确认端口释放；共享 55432 未被停止。

本周未改运行内核，也未重新执行 W24 的 520 个组件窗口和 12×20 全冻结矩阵；它们保留 W24 源码与证据身份，不累计为本周次数。现有相关测试全部在本次完整回归执行。

## 零执行边界与实际待验收状态

在全新 BEAM 中，以实际加载的 `LAB_DATABASE_ENABLED=true`、`LAB_SCHEDULER_ENABLED=true` 和非业务端口 65531 调用新包准备、report 和 assess。前后业务应用未启动，Repo/Scheduler/RunSupervisor 均不存在；对 **55 个模型、工具、恢复、审批、观测、SQL、应用/Repo 和进程启动入口**启用真实 call_count，全部为 **0**，见 [admission-probe](../artifacts/week25-acceptance/admission-probe.json)。显式文件复制和输出是宿主操作，不是工具执行。

新包在 report/assess 前后完整 bytes/mode 清单一致。两个新 CLI 与 API 结果逐字段相同，见 [reading CLI](../artifacts/week25-acceptance/reading_report_cli.log)和 [assessment CLI](../artifacts/week25-acceptance/release_assess_cli.log)。只读评估不信任或写入缓存 report.json。

| 实际评估项 | 结果 |
| --- | --- |
| 原 rc.1 技术候选完整性 | passed，重新运行 CandidatePackage.verify |
| 外部真人 | **0**，反馈文件 **0**、账本事件 **0**，pending |
| 新工作区独立真人主实验 | **0**，pending |
| 冷 macOS 主机 | 无外部证据，pending |
| 完整 Linux | 无外部证据，pending |
| 发行证据齐备 | false |
| 获准及实际发布 | approval false，not_published，release false |

实际[试读报告](../artifacts/week25-acceptance/reader-report.json)、[发行评估](../artifacts/week25-acceptance/release-assessment.json)和[政策](../artifacts/week25-acceptance/policy.json)均保存。空[外部索引模板](../artifacts/week25-acceptance/external-index-template.json)不作为环境证据或通过记录。评估 `report_hash` 为 `1998ac6fbb1333ddd3727612b632d83d2a0114d41f77125bf8696c11ea3dfae6`，这是规范化内容摘要，不等同原 JSON 文件 SHA。

## 独立审计与旧事实保护

[最终独立文件审计](../artifacts/week25-acceptance/independent-audit-verified.json) **8/8 组通过**。Python stdlib 只读重算源清单、日志/回归、资源清理、零执行探针、新包/政策/待验收状态、旧产物、开发库和文档绑定；不导入项目、不启动子进程、不连 SQL、不执行反馈或解码 ETF。它核对既有事实的一致性，不认证人、机器或执行。

最初两轮审计分别为 4/8、7/8，输出和当时脚本副本均保留。修正的是审计格式假设：Reproduction 使用 NUL 字段/换行摘要而非 JSON 摘要；runtime 输出是 Mix banner；旧原始证据包含故意的符号链接；exact policy 需包含最终 non-goals 字段。按实际合同修正后重新审计，未修改冻结产品源码、旧证据或准入门槛。

原 **503 个源文件全部保留，497 个完全不变**；6 个旧文档更新为 README、backlog、known-limitations、public-interfaces、recovery-runbook、release-operations。新增 12 个源码/测试/教材文件。旧 lib/config/test/priv/scripts/fixtures、21 个 migration、mix.exs、mix.lock bytes/mode 均保持，权限、预算和恢复实现没有变更。

开发库 **22 张表、18722 行**的全列行 hash 列表前后完全相同；前后快照 SHA 均为 `488b79123ea7388157fbd3b8370494c78151923c42934e0e6d9d48b2056b9017`。快照仅含行摘要，未复制原始数据。

以下旧产物的完整文件集合、bytes/mode 均核验保持：W22 试读包 **480 文件**，rc.1 候选 **7246 文件**，W24 原始证据 **6767 常规文件与1条符号链接**，W24 冻结导出 **503 文件**。候选目录项权限也对原 manifest 核验；故意的链接只核对目标字符串，不跟随。原 tar.gz SHA 仍为 `f1d66f2a2035d5f8129c4e98b3032e56b1e096416014c1ace847a455bd94052b`。

[证据索引](../artifacts/week25-acceptance/evidence-index.json)绑定 **551 个文件、11,921,478 bytes**，包括本轮执行、真实零人包、专项、审计、保护摘要和原身份入口；索引文件 SHA 为 `f84746bc081ef896314f0dd974971e07f78ce8614f737592aa43c3fee2257a2b`。文档静态审计核对 **10 份文档、279 条本地文件链接、34 个实际 CLI**，不将它当成命令执行或所有 fragment 验证。

## 使用边界与补录

反馈为可信宿主接收的自报，匿名 ID 不认证真人。每人一份初始反馈、最多 5 人，每份最多 64 个问题；账本最多 512 个事件、16 MiB，JSON 单文件有界。哈希链/head 检测缺序、改写和半写，不能防止有权重写整包者制造自洽历史或回退；须在包外保存报告锚点。残留锁或半写先保留证据并人工核对，不自动删事件或修 head。

本记录在执行与审计后补录，冻结副本保留执行前说明。只更新原工作区本文件，不回写已运行源码副本、候选、试读包或证据索引。后续 W26 仍须取得实际新主机/Linux 证据，W27 仍须真实试读；本周工具准备完成不关闭这些门槛。
