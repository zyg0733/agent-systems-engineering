# 第 18 周验收记录

验证日期：2026-10-21—22，最终验收 2026-10-22（Asia/Shanghai）。环境为 macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6；沿用 mix.lock，没有新增 Hex 依赖。开发与测试库均已应用全部 **20 个迁移**：本周新增 Workflow Control/Event、Approval Case/Event，以及 Workflow 的可空 control owner 交叉绑定字段，旧无图/无审批 Run 保持兼容。

配套 [L17 实验](../labs/L17-human-approvals.md)、[参考解答](../labs/solutions/L17.md)、[ADR 0017](adr/0017-human-approvals-and-rework.md)、[运行手册第 16 节](recovery-runbook.md#16-人工审批暂停与受控返工) 和 [P4 总结](p4-report.md)。

## 交付与契约

| 组件 | 已实现行为 |
| --- | --- |
| Artifact | 宿主固定已授权工作区、输出选择、initial 和 protected baseline；严格路径/链接/别名检查；单文件至多 64 KiB，每轮产物总额度至多 1 MiB；捕获完整 UTF-8 字节与 SHA256 |
| Plan | 一至三轮提前固定的 Workflow 与独立工作区；所有轮次五维预算分配总量不得超过 Case cap；approver allowlist；单一原绝对 timeout |
| Cases | 持久 Case、人工决定、原请求 ID、CAS seq、subject hash、generation、完整事件链与各轮证据；批准/返工与新轮登记保持事务性 |
| 哈希与失效 | subject 绑定 Case/Plan、轮次、generation、Workflow proof、完整输出哈希与原基线；改变后当前批准撤销，改回旧内容不复活 |
| release | 每次重新验证，包括重复请求；返回当前批准的不可变字节与基线版本，不执行工具、应用补丁或发布 |
| Pause/Resume | 可选持久 Control；按原锁顺序撤销已领取 token，快速恢复仍拒绝旧 claim；原 Run、回执、支出与 deadline 不重置 |
| 所属关系与权限 | 审批所属 Workflow 拒绝公开 resume 绕过；Workflow owner 与 Control owner 双向绑定，单个控制记录删除/剥离 owner 会拒绝执行 |
| 受控返工 | 只选择下一预声明轮；旧轮暂停且证据不改，旧预算不退款；新 Workflow、owned gate 和 Case 切轮同事务提交 |
| 运行层 | 一个有界 Case SQL helper、合并 wake、退避、至多一个当前 Workflow Coordinator；approved 状态继续观察外部文件变化 |
| 重建 | 每个历史 subject 均绑定原 Plan 的产物选择与 Workflow proof，不只检查最终快照；load/rebuild 不重捕获产物内容或启动执行 |

模型没有审批工具。actor 由可信宿主认证后传入并与 allowlist 核对；本周没有新增登录、签名服务或 RBAC。模型 Reviewer 的 `approved` 字段仍只是数据。

## 自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

冻结代码完整 **806 passed（804 tests、2 doctests），0 失败**，用时 **94.6s**。原 **10/10 fixtures** 以及创建/更新四个 COMMIT 前后真实进程 kill 检查全部通过。check 包含格式、无警告编译、数据库迁移与全部 W1—W18 测试。日志：[week18-check-complete.log](../artifacts/week18-check-complete.log)。

无数据库模式 **409 passed（407 tests、2 doctests），397 个数据库测试排除**，用时 **10.9s**。日志：[week18-memory-tests.log](../artifacts/week18-memory-tests.log)。数据库排除不代表持久审批通过；完整验收实际执行本机 Seatbelt/MCP 旧测试，既有 Linux 边界保持。

| 新增测试组 | 数量 | 主要判据 |
| --- | ---: | --- |
| Artifact | 11 | 不可变完整字节、hash、initial/protected 区别、缺失/冲突、路径/链接拒绝、严格版本及纯快照验证 |
| Plan | 10 | 一至三轮、全轮五维预留、独立授权、有限名单、单轮产物总额度、规范化与拒绝动态配置 |
| Controls | 11 | 快速 pause/resume fencing、在途 executor 退役、依赖不解锁、两个 COMMIT kill、期限、归属损坏与未知结果人工核对 |
| Cases | 18 | 相同字节放行、变化与改回失效、基线冲突、有限返工、并发人工 CAS、请求幂等、暂停/批准/返工的六个真实提交窗口、历史与绑定破坏拒绝 |
| Runtime | 4 | 两个真正新 BEAM 的有效批准放行/变化失效、approved 后台轮询、SQL 行锁阻塞下响应/有界 helper/超时与恢复 |
| ApprovalDemo | 4 | 严格选项/运行层权限、旧证据保护、失败报告、十一项真实演练与完整证据保存 |

本周新增 **58 项**，W17 原有 **748 项**保持。针对日志：[Cases](../artifacts/week18-cases-tests.log)、[Runtime](../artifacts/week18-runtime-tests.log)、[演练测试](../artifacts/week18-demo-final-tests.log)。针对回归有各自范围，不重复加总成独立新增测试数。

真正新 BEAM 测试使用独立 `elixir` OS 进程、已编译 code paths 和原数据库：一项沿用原批准放行 exact bytes，另一项在主进程改文件后拒绝旧批准，并由主进程重读验证失效事务已经提交。与只在同 VM 重启 Coordinator 的测试区分。

## 正式演练

```sh
./scripts/mix lab.approval --output artifacts/week18-approval
```

正式 **11/11 case 符合预期**，共 **13 个审批 Case、17 个已创建 Workflow、32 个已创建子 Run**。审批 Case 的实际状态为 **6 approved、4 awaiting_review、1 paused/manual、1 cancelled、1 failed**；Workflow 为 **15 succeeded、1 blocked、1 cancelled**；子 Run 为 **30 succeeded、1 blocked、1 cancelled**。每个 Workflow 声明两个节点，共 34 个节点，未知结果与期限案例的两个后代未创建。`all_passed` 表示符合判据，不表示业务全部成功。

| case | 实际观察 |
| --- | --- |
| hash_bound_release | 人工批准绑定本轮哈希，重复 release 返回同一不可变 PATCH_V1；原 BASE 未被应用或发布 |
| changed_artifact_revokes | release 后改产物，重复原 release 仍失效；改回原字节不复活，新的人工决定才能放行；已返回旧字节保持不可变 |
| baseline_conflict | protected base 改动后拒绝放行与强行批准；只选择已声明第二轮，形成新的可审查 subject |
| bounded_rework | 同一返工请求重试仍只有第二轮一次；旧 Workflow hash 与支出不变；超过轮次拒绝；只放行 PATCH_V2，原 deadline 相同 |
| pause_restart | 模型输入门闩处暂停，旧 executor 退出；原 claim 在暂停时拒绝、恢复后仍 stale；重启 Coordinator 使用同 Workflow/Run，预算不退款 |
| pause_effect_unknown | 非幂等 Mock 效果发生后暂停；恢复核对为 unknown/manual，真实效果仍一次，未解锁后代；再次暂停等待人工核对 |
| human_request_guard | 非名单 actor、旧 subject、注入 script、直接恢复 owned Workflow 均拒绝；同一批准只一条决定，改内容复用 request ID 冲突 |
| approval_commit_windows | before/after COMMIT 的真实 process kill；前者看不到批准、后者可见，原请求恢复都只保留一条决定 |
| rework_commit_windows | before/after COMMIT 的真实 process kill；Case 切轮与新 Workflow 一起回滚或一起存在，原请求重试不重复返工 |
| cancel_after_approval | Case 取消后无可用批准，release 与直接恢复均拒绝 |
| deadline_after_pause | 暂停后原墙钟期限到期，Case failed；不能以 resume 延长原时间 |

演练的 actor 是合成的可信宿主请求，Reviewer 与产物输出由 Scripted Provider 固定；不宣称真实人的签名、模型审查质量、外部发布效果或生产吞吐。pause_restart 是暂停后 graceful stop/recreate；批准/返工窗口才是真实强杀事务进程，不混用两类证据。

报告：[report.json](../artifacts/week18-approval/report.json)；日志：[week18-approval-formal.log](../artifacts/week18-approval-formal.log)。每项保存完整 Case/Plan/决定/事件、Workflow/Control、子 Run 历史与操作台账，以及在执行停止后的 Audit；report 的 evidence 记录快照文件名和 hash。非 UTF-8 原始 intent 字节以明确 base64 标记保存。旧输出拒绝覆盖，失败仍留 namespace、已完成记录与失败位置。

## 严格历史修复与独立复核

只读审查曾实证：旧 subject 已失效后，只篡改其历史 Artifact root 并重算该快照、subject 与后一事件链哈希，最终新 subject 不变，初版仍接受。已修为**每条历史投影**都执行纯 Artifact.matches_spec、原轮次 Workflow proof/seq 与 definition hash 绑定；同一独立探针复跑被拒绝，加入回归。这没有引入重建时文件捕获或执行。

正式后的空闲独立新 BEAM 对全部 **13 个 Case、17 个 Workflow、32 个子 Run**重建，逐个与正式保存的 Case、Workflow、Control、子状态、模型录制与预算 hash 比较。每 Case **46 个执行/控制变更/产物捕获入口**全部为零，共 **598 个零计数**；相关 **21 张持久表**全列原始行与 hash 在审计前后保持一致。唯一模糊操作仍 paused/manual、unknown、效果一次。

独立 Python 交叉核验 **607/607 通过**：复核逐项报告、31 个历史 subject 的每文件 SHA256/字节、全轮预算预留、原 deadline、旧 proof 不变、暂停后的已扣模型尝试/游标、基线冲突、改回旧内容仍需新 generation、唯一 unknown 的单次效果和 release 不应用补丁。正式起跑前后 **251 个可执行源码、配置、测试和 fixture 文件**的 hash 与 mode 全部相同，保存完整源码快照。README/文档填充真实计数不在这一冻结范围。

证据：[independent-audit.json](../artifacts/week18-approval/independent-audit.json)、[新 BEAM 重建](../artifacts/week18-approval/independent-rebuild.json)、[原始表事实前](../artifacts/week18-approval/raw-database-before.json)与[后](../artifacts/week18-approval/raw-database-after.json)、[source-manifest.json](../artifacts/week18-approval/source-manifest.json)、[源码快照](../artifacts/week18-approval/source-snapshot)。审计脚本及日志也保存在正式目录。这些是对当前事实和正式原始轨迹的只读验证，不冒充重新制造每一个故障窗口。

## 当前边界

release 是不可变字节的授权检查，不是应用补丁或发布。真正消费者应使用批准的字节，并对基线做 compare-and-swap；不能先批准路径，再读取变化后的内容。外部已经接受的旧字节无法撤回，文件系统也不是跨多个文件的事务；无法观测短暂修改后在检查前完全还原的过程。

load/rebuild 读取保存的事实而不重捕获当前内容；旧 approved 历史不能代替 release。Plan 恢复仍继承既有 Workflow 对工作区/策略的校验，不承诺删掉宿主工作区后仍可继续。操作者身份与安全登录由可信宿主负责，数据库不是恶意整库协调重写下的签名账本。

返工只选择预声明轮次，不重开旧 Run、不动态生成 Planner/图/预算。所有轮次总预留、实际旧支出与绝对 deadline 均保持。未知工具效果、原文件权限、隔离后端和 MCP 能力限制不因审批而改变。P4 本地教学范围及 W15—W18 证据关系见 [阶段总结](p4-report.md)。
