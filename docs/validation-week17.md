# 第 17 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6；沿用 mix.lock，没有增加 Hex 依赖。开发与测试库均已应用第 17 个迁移 `20261023000000_create_workflows.exs`：新增 Workflow、Node、Event 三表及原 Run 的可空归属字段，原无图 Run 保持兼容。

## 本周交付

完成静态 DAG、持久依赖调度、并行子 Run、完整结果汇合，以及失败传播、取消和崩溃恢复。对应 [L16 实验](../labs/L16-dag-workflows.md)、[参考解答](../labs/solutions/L16.md)、[ADR 0016](adr/0016-static-dag-workflows.md) 与[运行手册第 15 节](recovery-runbook.md#15-dag-编排与子任务恢复)。

| 组件 | 行为与边界 |
| --- | --- |
| `Workflows.Definition` | 宿主静态图，最多八节点，最大反链宽度三，实际并发一至三；严格拓扑、版本和选项校验，稳定子 Run ID |
| 权限与预算 | 每节点自己的 Session、工作区、隔离/MCP 策略；依赖不授予权限；不同节点文件授权根不能相等或互为祖先，根路径及 Unicode 别名保守拒绝 |
| 五维预留 | turn、model attempt、output bytes、tool call、dispatch 的节点分配总量不得超过父 cap；重试不退款、不转移，实际支出沿用原持久计数 |
| Store | 图、事件链、节点、私有队列与就绪 Run 同事务提交；下游仅在全部直接依赖成功后创建；原绝对 deadline 约束后续准入 |
| Coordinator | 一个可替换观察者、一个有界 SQL helper、合并 wake 和数据库退避；执行复用原 Scheduler、Worker、intent 与 claim |
| 并发与 fencing | 私有队列约束多个 Coordinator 的共享在途数；父门禁进入 claim、renew、模型扣账、工具执行与结果提交，原代次 fencing 保持 |
| Join | 按节点 ID 排序，保留原任务、完整输出/operation ledger、Run/seq/hash；tagged JSON 保留类型；一 MiB 上限超出显式失败 |
| 失败与取消 | 父门禁先提交，子任务可重复收敛，未创建节点 skipped；confirmed receipt 复用，prepared/unknown 保留 blocked/manual，不重放模糊效果 |
| 只读重建 | 核对版本、定义、每次事件投影、身份/输入、成功子 Run 与保存回执；load/rebuild 不启动 Coordinator 或模型/工具 |

## 自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

冻结版本完整 **748 passed（746 tests、2 doctests），0 失败**，用时 83.9s；原 **10/10 fixtures** 与创建/更新的四个 COMMIT 前后真实进程 kill 检查全部通过。check 包含格式、无警告编译、数据库迁移与完整旧测试。日志：[week17-check-complete.log](../artifacts/week17-check-complete.log)。

无数据库模式 **387 passed（385 tests、2 doctests），361 个数据库测试排除**，用时 9.6s。日志：[week17-memory-tests.log](../artifacts/week17-memory-tests.log)。数据库排除不是 DAG 持久恢复通过；本次完整验收在 macOS 实际执行旧 Seatbelt/MCP 测试，既有 Linux 能力边界不变。

| 本周新增组 | 数量 | 主要判据 |
| --- | ---: | --- |
| Definition | 17 | 严格图/版本、真正反链宽度、五维分配、独立工作区、拒绝 hook/函数/queue、策略往返 |
| Join | 9 | 完整成功来源、确定顺序、tagged 类型、配对与哈希、拒绝 unknown/未完成/超限 |
| Store | 12 | 根事务 kill、并发准入、deadline、取消与回执、投影/历史/身份破坏拒绝、超大 Join 可见失败和无 Run 重建 |
| Coordinator | 12 | 双分支与多控制器、stop/restart、控制器及 Worker 强杀、真实租约到期/fencing、人工核对后归档、失败/取消、SQL 阻塞超时与合并唤醒 |
| WorkflowDemo | 4 | 严格选项、旧输出/全局消费者保护、失败报告、九项真实演练及完整证据落盘 |

共新增 **54 项**，W16 原有 694 项保持。首轮完整回归也为 748 passed；之后统一 Coordinator ID 边界，补齐演练快照与其断言，在冻结版本重跑最终 check，不把中间结果冒充最终版本。中间日志保留在 [week17-check-intermediate.log](../artifacts/week17-check-intermediate.log)。

## 正式演练

```sh
./scripts/mix lab.workflow --output artifacts/week17-workflow
```

正式 **9/9 case 符合预期**，共 **11 个 Workflow、22 个节点、20 个实际创建的子 Run**。父图实际状态为 **7 succeeded、2 failed、2 cancelled**；子 Run 为 **16 succeeded、1 failed、2 cancelled、1 blocked/manual**。两个未创建后代保持 skipped。`all_passed` 表示符合实验判据，不表示所有任务业务成功。

| case | 实际证据 |
| --- | --- |
| serial_baseline / parallel_diamond | 同一四节点图、相同 cap/分配/产物；真实门闩下在途数分别为一/二，两个分支未全成功时 join 尚未创建；各 6 次模型尝试、8 次 dispatch、2 次工具调用 |
| same_budget_reviewer_comparison | 一 Run 完成两产物与结构化意见，对照实施者加 Reviewer 两 Run；任务、产物、意见、五维 cap 与分配总量相同，Reviewer 无文件授权/工具额度 |
| failure_propagation | 子失败后父 failed，依赖 skipped 且数据库没有其 Run |
| cancellation | 运行中真实门闩取消，父先提交 cancelled，执行器退出，迟到结果不能提交 |
| unknown_on_cancel | 非幂等 Mock 效果真实发生一次后取消，父 cancelled、子 blocked，manual 核对与 unresolved 可见，不重放 |
| controller_crash | completed receipt 已 COMMIT 后实际 kill Coordinator；原 Scheduler 随 OTP 父退出；新控制器使用同子 Run，效果入口仍一次、文件保持 ONE_EFFECT |
| commit_windows | 下游准入 COMMIT 前强杀时读不到 child，COMMIT 后强杀时已可见；sync 原图后两者都只产生同一个稳定子 Run 并完成 |
| absolute_deadline | 子 deadline 不晚于父绝对期限；超时后父 failed，运行子任务被收敛，重启不延长时间 |

真正单/双 Run 对照的五维 cap 和分配均为：turn=6、model attempt=6、output bytes=10000、tool call=2、dispatch=16。实际支出分别为：

| 方式 | 模型尝试 | 输出字节 | 工具调用 | dispatch |
| --- | ---: | ---: | ---: | ---: |
| 单 Run | 3 | 229 | 2 | 5 |
| 实施者＋Reviewer | 4 | 252 | 2 | 6 |

增加的审查步骤消耗一次模型尝试。两组输出与意见由 Scripted Provider 预设，不能证明 Reviewer 发现真实错误、提升模型质量或获得生产性能优势。同图串并行对照验证调度，真正单/双 Run 对照验证角色与预算，两者分别留证。

报告：[report.json](../artifacts/week17-workflow/report.json)；日志：[week17-workflow-run.log](../artifacts/week17-workflow-run.log)。每个 case 保存 summary、原图事件/定义、子 Run 输入/状态/历史、模型录制、任务预算和操作台账的可读快照；两个分支另保存完整 Join 与并行门闩证据。非 UTF-8 原始 intent 字节明确标为 base64。报告记录原身份与快照路径，旧输出拒绝覆盖；失败留 namespace、已完成条目和失败原因。

## 独立重建与事实核对

独立新 BEAM 对全部 **11 个 Workflow、20 个子 Run** 做图与完整子历史重建，每图 **31 个模型/工具/执行/编排推进入口均为零**。全部图哈希与正式演练快照相同，九个已保存 Audit 的图还比对原子状态、模型录制与预算哈希；两个 COMMIT 图以正式可读快照及另一次 post-formal 基线验证，不将后采样说成原始 Audit。

围绕本轮 ID 的 **17 张相关持久表**在独立审计前后全列行哈希保持不变，包括 Workflow/Node/Event、Run 历史/intent、恢复、上下文、模型录制、预算、操作/尝试/效果与队列事实。原唯一模糊操作仍为 manual、效果一次。详见 [independent-rebuild.json](../artifacts/week17-workflow/independent-rebuild.json)、[审计脚本](../artifacts/week17-workflow/independent-rebuild.exs)、[原始表事实前](../artifacts/week17-workflow/raw-database-before.json)与[后](../artifacts/week17-workflow/raw-database-after.json)。

独立 Python 复核 **273/273 通过**，检查逐项报告、并行门闩、完整 Join、单次效果、同预算产物与意见、身份及独立重建证据。正式起跑前后 **229 个可执行源码、配置、测试、迁移和脚本文件**逐一 SHA256 相同，并保留对应源码快照；README/文档填充真实计数不在这一冻结范围。见 [independent-audit.json](../artifacts/week17-workflow/independent-audit.json)、[审计脚本](../artifacts/week17-workflow/independent-audit.py)、[source-manifest.json](../artifacts/week17-workflow/source-manifest.json)与[source-snapshot](../artifacts/week17-workflow/source-snapshot)。这些是对正式证据与持久事实的只读核验，不冒充再次执行故障窗口。

第一次独立脚本误要求取消窗口的 journal 一定是 unknown；实际是 prepared、Kernel 已 blocked/unknown、safe_mode=manual，符合原模糊结果语义。保留首次日志与 before 数据，审计判据修正为 prepared 或 unknown 后重新验证；产品源码和正式实验事实没有改变。

## 已验证边界

只读重建与实际续跑分开：前者在空闲独立 BEAM 计数，后者可执行工作。杀 Coordinator 会触发 OTP 子树清理并释放资格；另外的直接 kill Worker 测试才验证真实遗留租约到期与旧代次 fencing，不能混用两类崩溃证据。

取消不撤销外部效果，父图终态仍可有 unresolved 子节点。可信人工核对后应显式 sync 父图归档；核对不会重开已取消父图，也不会解锁其后代。Join 一 MiB 是输出长度约束，不是构造过程的硬内存配额；输出字节预算也不是总磁盘或真实模型 token/资金计费。

本周交付静态宿主图与预设 Reviewer；应用重启后由宿主按原 Workflow ID 启动 Coordinator，不自动扫描并启动所有历史图。动态 DAG、Planner、自动返工、人工审批及产物变化导致批准失效留待后续。没有新增执行后端，既有文件、隔离与 MCP 的授权、人工核对和平台限制继续生效。
