# 第 24 周验收记录

验证日期：2026-10-23—24（Asia/Shanghai）。**冻结技术验收与 v0.1 候选教学材料交付通过**：完整回归 1034 项通过，内存回归 569 项通过，固定矩阵 12 类各 20 轮、11 项核心演练全部通过；候选包及归档解压验证通过。原权限、预算、绝对 deadline、unknown/reconcile、审批和 fencing 语义保持。

候选包标签为 `v0.1.0-rc.1`，实际项目版本仍为 `0.1.0-dev`。本目录无 Git 仓库，不伪造 Git tag。W22 真人试读为 0、外部准入仍待验收，Linux CI 未执行；技术候选与正式发布分别判定。本记录的冻结副本保留执行前状态，最终结果补录在原工作区，不为补录修改已运行的冻结源码。

## 首次冻结的失败记录

首次冻结完整回归为 1032 项通过、1 项失败，原始日志和源码保留于 `artifacts/week24-acceptance/`、`artifacts/week24-frozen-source/`，不能计入最终通过结果。失败在既有 DAG 演示的 absolute deadline 观察逻辑：父 Workflow 提交失败状态后，Coordinator 仍需取消子任务并刷新投影；演示提前停止 Coordinator，并用首次终态的旧快照审计，出现 `workflow_rebuild_mismatch`。

真实提交屏障已复现 `seq=2 / child=running` 到 `seq=3 / child=cancelled` 的收尾窗口。修复限于演示等待 Coordinator 确认终态、`pending_sync=nil` 后读取最终快照，并补充确定性回归测试；原 150 ms 截止时间、预算、权限及恢复实现不变。首次失败与复现证据作为诊断材料保留，修复后的新源码已重新冻结并完成本页最终验收。

修复及复现证据见 [diff](../artifacts/week24-acceptance-final/workflow-demo-fix.patch)、[提交屏障记录](../artifacts/week24-acceptance-final/provenance/workflow-publication-race.json)与[专项日志](../artifacts/week24-acceptance-final/provenance/workflow-demo-regression.log)。首次失败日志和当时 source manifest 也随候选保存在 `candidate-evidence/provenance/`，不混入最终通过数。

## 冻结身份与执行环境

最终 [source manifest](../artifacts/week24-acceptance-final/source-manifest.json) SHA-256 为 `6e7d56c135e2774752035913daa99689e7a1ab8249164b34c52817916820b2a1`，含 **502 个源码文件、561 个文件/目录项、3,850,959 bytes**。冻结副本在 `artifacts/week24-frozen-source-final/`；实际 cwd 是原工作区，执行前后逐文件核对其 bytes/mode 与该副本相同。复用了现有 runtime、依赖和 build，不声称从冻结副本重新安装、冷主机或 Linux 复现。

实测宿主为 macOS arm64，Mix 1.20.4、OTP 28（同安装树 release marker 28.4）、PostgreSQL 18.6，见[现场观测](../artifacts/week24-acceptance-final/runtime-observation.json)。本轮新初始化独占 PostgreSQL 集群，开始时没有项目 dev/test 库；固定 `127.0.0.1:55587`、全局 Scheduler 关闭，`fsync/synchronous_commit/full_page_writes` 均为 `on`。现有共享 PostgreSQL `55432` 未被停止。

[execution.json](../artifacts/week24-acceptance-final/execution.json)记录 **22 个固定步骤全部退出 0**，UTC 2026-10-23 15:59:18 开始、16:10:27 进入最终停止步骤；保存真实 argv、日志 SHA、耗时、数据库 system identifier 与本轮 PGDATA。源码末次 verify 通过，随后仅停止精确绑定的自有集群并确认端口释放；未删除保留的故障证据或停止共享库。

## 新增测试与完整回归

新增 **24 项测试**：候选包 16 项、冻结矩阵 7 项、DAG 观察竞态 1 项，其中 2 项需要数据库。覆盖缺失或篡改证据、部分矩阵、少轮次、源码绑定、路径/权限/链接/容量边界、不启动业务应用，以及真实故障诊断与提交屏障观察。原测试断言、业务超时和预算门槛未放宽。

| 固定命令 | 实际结果 | 证据 |
| --- | --- | --- |
| `./scripts/mix check` | **1034 passed**，1032 tests + 2 doctests；0 失败；ExUnit 218.5s | [完整日志](../artifacts/week24-acceptance-final/full_check.log) |
| `LAB_DATABASE_ENABLED=false ./scripts/mix test` | **569 passed**，567 tests + 2 doctests；**465 个数据库测试排除**；ExUnit 89.5s | [内存日志](../artifacts/week24-acceptance-final/memory_check.log) |

1034 = W23 的 1010 + 新增 24；569 + 465 = 1034。完整 check 同时通过格式、warnings-as-errors 编译、21 个迁移、原 **10/10 fixtures** 与 PostgreSQL COMMIT 前后崩溃验证。内存排除数不计通过，465 个数据库测试已在完整模式执行。Mix 对显式加载的 `test/support/frozen_matrix_fixture.exs` 输出测试命名过滤提示；它未造成编译警告错误或测试失败，原始提示完整保留。

## 固定故障矩阵与教学主路径

[最终矩阵](../artifacts/week24-acceptance-final/matrix/report.json) `complete=true`、`all_passed=true`。F01—F12 每类 **20 个实际 observation**，合计 **240**；不是沿用旧报告或只生成 plan。行级记录绑定 540 份证据引用，file-only verify 与独立审计均通过。

| 组合组件 | 本轮实测 |
| --- | --- |
| P2 | 16 个窗口 × 20 = **320** 个探针通过 |
| lease / heartbeat / fencing | 5 个窗口 × 20 = **100** 个探针通过；真实 SIGSTOP/SIGCONT，额外 840 次旧 claim 调用全部拒绝 |
| 数据库断连 | 两个独立批次，每批 5 个窗口 × 10；共 **100** 个探针通过 |

**520 个组件探针与 240 个行级 observation 分开计数**；F06/F11 按轮绑定组件事实，不把复用证据加成新的独立故障次数。F07 每轮 100 个同逻辑操作并发请求只有 1 个效果；F08 改参数请求明确冲突；F12 保持 SQL 版本约束，未知 Event schema 写入被拒、未知重建/Codec/兼容版本明确拒绝，未临时放开约束。

另在同一冻结身份下完成 **11 项核心演练**：P1、history、调度、负载、隔离、MCP、DAG、审批、观测、评测与升级。history 重建与在线状态相同且 effect boundary 调用为 0；隔离 18/18、MCP 20/20、DAG 9/9、审批 11/11、观测 8/8、评测 10/10 通过。评测包含 6 个 cohort、60 个 Run；所有结果和原始文件由[证据索引](../artifacts/week24-acceptance-final/index.json)绑定。数据库故障覆盖受控连接故障，不扩大为 PG 介质损坏或生产灾备证明。

## 候选教学材料与归档

新增 [FrozenFaultMatrix](../lib/agent_systems_lab/frozen_fault_matrix.ex)、[CandidatePackage](../lib/agent_systems_lab/candidate_package.ex)及 `lab.freeze` / `lab.candidate` 固定 CLI。plan/verify 和候选 build 只处理受界文件，不执行证据中的命令；真实矩阵 run 单独启动业务执行。配套 [L23](../labs/L23-frozen-candidate-release.md)、[解答](../labs/solutions/L23.md)、[ADR 0023](adr/0023-frozen-candidate-release.md)、[候选说明](candidate-release.md)、[结果索引](results-index.md)、[限制](known-limitations.md)、[backlog](backlog.md)及[运行手册第 22 节](recovery-runbook.md#22-冻结验收与候选包交付)。

候选根目录为 `artifacts/agent-systems-lab-v0.1.0-rc.1/`，包含 **12 个课程单元、30 张章节卡、6 章试读正文、L01—L23 与解答**，以及 **6740 份声明证据文件、30,238,310 bytes**。27 个排除项逐项写入 catalog policy，包括故意的隔离符号链接、无扩展名 native/canary、缓存及空日志；原目录保留。所有矩阵必要引用仍完整纳入。合成升级 `.dump`、惰性 `.bin` 仅核验字节，不导入或反序列化；未打包 runtime、deps、build、PGDATA、开发库原始行、凭据或真人反馈。

| 交付身份 | SHA-256 |
| --- | --- |
| [candidate-manifest.json](../artifacts/agent-systems-lab-v0.1.0-rc.1/candidate-manifest.json) | `c3596200e9c305e4fbd35037c8af8e4bedc0a2ce5b0da0b4858eee780bfbbf70` |
| [包内证据 index](../artifacts/agent-systems-lab-v0.1.0-rc.1/candidate-evidence/index.json) | `2cc0d2c98bdacf910e7272f19bdac14a7cdcf51bb4df6fc084c2106bae468657` |
| [tar.gz](../artifacts/agent-systems-lab-v0.1.0-rc.1.tar.gz)，5,223,567 bytes | `f1d66f2a2035d5f8129c4e98b3032e56b1e096416014c1ace847a455bd94052b` |

[归档校验记录](../artifacts/week24-packaging/archive-result.json)确认候选 build、原包 verify、全新自有目录解包后 verify 均退出 0、manifest 完全相同；仅清理按 token/inode 绑定的本轮解包目录。归档成员来自已验证清单，固定 uid/gid/mtime/gzip mtime 与排序，预检类型、路径和配额后逐文件校验。SHA 与旁边的 `.sha256` 只表完整性，不认证下载来源或发布者。

## 独立审计、旧事实保护与发布边界

独立 Python stdlib 文件审计打包前 **9813/9813** 通过，见[prepackage](../artifacts/week24-acceptance-final/audit-independent-prepackage.json)；打包后 **124076/124076** 通过，见[postpackage](../artifacts/week24-packaging/audit-independent-postpackage.json)。后者重新核验源码、回归、逐轮原始 summary/cleanup、100 请求明细、11 项演练、包文件与归档的 hash/mode/完整成员集合。不导入项目代码、不启动子进程、不连接 SQL、不解包、不解释 ETF；它核对已有执行证据，不冒充重新故障执行、真人审阅或签名认证。

与 488 文件旧源码基线相比：**481 个旧文件完全不变**；5 个旧文档（README、known-limitations、public-interfaces、recovery-runbook、release-operations）更新，另仅 `WorkflowDemo.ex` 与其测试作上述观察修复；新增 14 个源码/教材文件。21 个迁移、配置、mix.exs、mix.lock、原引导脚本及权限/预算/恢复核心文件 bytes/mode 保持。

开发库 **22 张表、18722 行**的全列行 SHA 列表前后完全一致，见[比较](../artifacts/week24-acceptance-final/provenance/protected-db-comparison.json)；前后快照 SHA 均为 `488b79123ea7388157fbd3b8370494c78151923c42934e0e6d9d48b2056b9017`，只复制摘要、不复制原始行。W22 旧正式试读包 **480 个文件** bytes/mode/hash 不变，真实反馈仍为 0。

本记录是验收后派生补录；冻结副本与候选包内保留执行前记录，包内机器 index 是实际结果入口。执行、打包、postpackage 审计后才补录本文件，不回写已运行源码、候选或证据 index。就冻结源码集合而言，原工作区仅此派生文档与候选的差异属于预期。

技术候选 `technical_candidate_ready=true`；正式发行仍为 **`release_ready=false`、`external_humans=0`、`linux_validation=pending`**。3–5 人真实试读、外部独立操作、Linux/冷主机验证及后续长章写作分别列入 backlog，不用本轮技术通过替代。当前目录无 Git 仓库，未创建 tag、上传、部署或发布。
