# 第 14 章：Event History、Checkpoint 与纯重建

试读修订版，2026-10-25。对应当前仓库 L06、L20；实现与实验编号以仓库为准，原研究计划的 L05 编号已顺延。
本轮采用多代理模拟评审与代码核查；范围和实测记录见[首批学习修订审查](../docs/learning-revision-review.md)。模拟发现的误解是待检验的学习风险，不能写成真人反馈或真实学习耗时。

## 14.1 学习路径：先恢复事实，再决定是否行动

先修能力：能读懂 `{:ok, value}` 的匹配，区分命令与已接受 Event，知道连续 seq 和原 `max_turns` 为什么不能猜；做数据库部分前还需理解事务提交与回滚。用[先修知识](prerequisites.md)检查缺项，遇到中英混用词可查[术语表](glossary.md)。
主路线：[第 2 章状态机](ch02-agent-state-machine.md) → [第 8 章 Session](ch08-session-context.md) → 本章纯值练习 → [第 16 章](ch16-durable-effects-and-reconciliation.md)。只阅读六章不要求先完成 L01—L05；准备运行持久化实验时，再完成 [L04](../labs/L04-controlled-tools.md)、[L05](../labs/L05-session-context.md)和 [L06](../labs/L06-history-checkpoints.md)的环境与任务。
本章先用纯值重建状态，再检查数据库 checkpoint 和模型录制；格式迁移与备份还原是第二遍进阶阅读，不是首次重建的前置条件。
后续：[第 16 章](ch16-durable-effects-and-reconciliation.md)讨论安全续跑，[第 20 章](ch20-scheduling-and-recovery.md)讨论谁有资格推进。

完成本章应能回答三个问题：历史里发生了什么，历史能否被当前代码解释，以及读取历史有没有偷偷重新执行效果。
“最后状态相同”只是第一项；若一次重建又写了文件，即使最终 State 相同，也没有满足本章契约。
可检查的学习产物是：一次完整 State 相等的断言、一条缺口历史的明确拒绝，以及对 rebuild 和 resume 差异的说明。

| 入口 | 输入和输出 | 是否推进业务 |
| --- | --- | --- |
| `History.rebuild/3` | Event 列表 → Kernel State | 否 |
| `CheckpointStore.rebuild/2` | 持久历史、checkpoint → 经验证 State | 否 |
| `Recovery.load/1` | 历史、原配置和进度 → 恢复快照 | 否 |
| `Providers.Recorded.respond/2` | 精确输入、完整录制 → 保存的响应 | 显式调用适配器；宿主仍可继续执行 |
| `Recovery.resume/2` | 有效资格、原配置 → 新事实 | 是，可能调用模型和工具 |

这里的 replay 是重新应用已经接受的事实。它不把过去的 `tool_requested` 解释成现在再发一次工具请求。
读到 `unknown` 就保留 unknown；没有回执的历史不能靠重新执行补齐。

### 第一次小练习：给读取和执行分组

不启动数据库，先从上表选出“仅恢复已有事实”的三个入口，再判断：选择 `Providers.Recorded` 是否就能保证后续 Runtime 零效果？把答案写下后再读提示。

<details>
<summary>提示与自检</summary>

前三个入口仅恢复已有事实。`Recorded.respond/2` 是显式适配器调用，不等同于 History 重建；宿主继续 Runtime 时仍可能执行工具。能 rebuild 只说明历史可解释，不能推出原配置、有效 claim、权限和预算都满足 resume。

</details>

## 14.2 Event 是已经接受的事实

命令描述请求，Event 描述请求被接受以后成立的事实。失败命令不应冒出一段可供重建的成功历史。
每条 Event 绑定 Run ID、连续 seq、精确 schema version、类型与数据；Kernel 用同一规则验证正常推进和历史应用。
重建不排序、不去重、不修补缺口，因为这些“方便处理”会把损坏的顺序变成另一个故事。

```text
run_started(seq=1)
  → tool_requested(seq=2, operation_id=call-001)
  → tool_result_recorded(seq=3, operation_id=call-001)
  → run_succeeded(seq=4)
```

结果必须配对到原 operation；终态后追加事实、跨 Run 混入 Event 或跳过 seq，都应明确拒绝。
配置也属于解释条件：例如原始 `max_turns` 不能从事件条数猜测，重建时必须保持。
追踪 [History](../lib/agent_systems_lab/history.ex) → [Kernel](../lib/agent_systems_lab/kernel.ex)，再读 [history_test](../test/agent_systems_lab/history_test.exs)。

### 纯值练习：等待工具也可以只读重建

在项目根目录启动 `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/iex`，连续执行：

```elixir
alias AgentSystemsLab.{Checkpoint, History}
alias AgentSystemsLab.Kernel, as: LabKernel
id = "ch14-pure"
opts = [max_turns: 6]
{:ok, queued} = LabKernel.new(id, opts)
{:ok, running, [started]} = LabKernel.dispatch(queued, {:start, "检查历史"})
call = %{operation_id: "call-001", tool: "mock_write", arguments: %{"value" => 7}}
{:ok, waiting, [requested]} =
  LabKernel.dispatch(running, {:model_response, {:call, call}})
{:ok, observed, [result]} = LabKernel.dispatch(waiting,
  {:tool_result, "call-001", {:ok, %{"receipt" => "saved"}}})
{:ok, finished, [succeeded]} =
  LabKernel.dispatch(observed, {:model_response, {:final, "已核对"}})
events = [started, requested, result, succeeded]
{:ok, rebuilt} = History.rebuild(id, events, opts)
true = rebuilt === finished
{:ok, checkpoint} = Checkpoint.new(id, Enum.take(events, 2), opts)
:ok = Checkpoint.verify(checkpoint, Enum.take(events, 2))
{:ok, rebuilt_tail} = History.from_checkpoint(checkpoint, Enum.drop(events, 2))
true = rebuilt_tail === rebuilt
{:error, _} = History.rebuild(id, [started, result, succeeded], opts)
{:error, _} = History.rebuild(id, [%{started | schema_version: 2}], opts)
```

这里构造的 `mock_write` 只是 Event 数据，从未调用工具。把它换成文件工具提议，也不应让 History 写文件。
保存成功比较及两个错误返回；“IEx 没有打印工具日志”不足以证明调用次数为零。

## 14.3 Checkpoint 绑定哪一段事实

checkpoint 保存历史前缀的状态投影，同时绑定 Run、last seq、原选项、前缀 hash 和 State hash。
尾部应用必须紧接前缀序号，不能跨 Run、跳过事件或继续一个已经终结的状态。
但一个自洽的 hash 只能说明内容匹配；它不是签名，也不证明记录来自获授权的写入者。伪造 State 后重算 hash，不会让它成为权威历史。纯值 `History.from_checkpoint/2` 要求调用者提供可信 checkpoint；它自身没有读取数据库权威前缀。

因此数据库读取会用原始完整前缀核对 checkpoint。当前实现并不减少这段读取，也不承诺启动加速。
先建立可验证边界，后续才有条件研究可信 checkpoint 和历史分段优化；不能先删历史再假设摘要可信。
无 checkpoint 时，`mode: :checkpoint` 明确返回 `audit.mode == :full`；最新 checkpoint 已损坏时则报错。
不能偷偷换成较旧 checkpoint 或完整重建，让使用者误以为损坏记录仍然有效。

创建时要求 expected seq，并在事务内绑定当前事实。重复创建同一 Run/seq 不覆盖原记录，陈旧 seq 不发布 checkpoint。
提交前崩溃应没有新行；COMMIT 后 caller 没拿到 ACK，另一个进程仍能读到完整 checkpoint。
外层回滚事务会移动真正提交边界，因此相关写入 API 拒绝嵌套写事务。
对应实现：[CheckpointStore](../lib/agent_systems_lab/checkpoint_store.ex)；测试：[checkpoint_store_test](../test/agent_systems_lab/checkpoint_store_test.exs)。

## 14.4 模型录制与历史重建的边界

模型输入 capture 在 Provider 启动前保存 Context 来源、Session、权限、payload 与 manifest。
结果录制只保存完整、已通过校验并被接受的响应，与 Run/Event/下一意图一同提交。
取消后迟到的候选、不完整 stream、Provider error 和预算拒绝，不会变成可重放的成功响应。

录制读取同时核对精确输入、Context 来源、完整响应以及实际接受它的 Event。
只验证响应 hash 会漏掉“响应存在，却从未被 Kernel 接受”的情况；只对比提示词文字又会漏掉权限和工具回执变化。
`Recorded` 是宿主显式选择的适配器，输入不匹配就拒绝，不按语义相似度寻找一份可用回答。
宿主若把录制响应投入新一轮正常 Runtime，后续仍须执行 schema、权限、配对和预算检查。

读 [ModelResultStore](../lib/agent_systems_lab/model_result_store.ex)、[Recording](../lib/agent_systems_lab/recording.ex) 和 [Recorded](../lib/agent_systems_lab/providers/recorded.ex)。
对照 [recording_test](../test/agent_systems_lab/recording_test.exs)、[run_server_recording_test](../test/agent_systems_lab/run_server_recording_test.exs)。
当前录制不是全部厂商请求、计费 token 或原始网络包的归档；Provider 标签也不是身份认证。

## 14.5 运行一次真正的新进程核验

在项目根目录执行；每个输出目录必须尚不存在，重跑时把 `reader-01` 改成新编号：

```sh
./scripts/postgres start
./scripts/mix setup
LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.history --output artifacts/ch14-history-reader-01
```

该命令先创建一个演示 Run 并真实写一次自有工作区文件，随后启动另一个 BEAM 只读重建。
不要把整个命令描述为零效果；零效果契约仅针对其中的新进程核验阶段。
检查该目录的 `report.json`、`fresh-vm.log`、`events.bin` 和工作区文件。

| 验收项 | 从哪里判断 |
| --- | --- |
| 全量与 checkpoint 状态相等 | `full_matches_checkpoint == true` |
| 与原进程完整 State 相等 | `same_as_expected_state`、`same_as_live_state` 为 true |
| 既有录制可验证 | `recorded_model_results == 2` |
| 前缀和 tail 均参与验证 | `verified_prefix_events == 2`、`replayed_tail_events == 2` |
| 新进程没有跨越执行入口 | `effect_boundary_calls` 每一项均为 0 |
| 文件没有被重建再次修改 | `original_file_writes == 1`、`file_unchanged_by_rebuild == true` |

把本次 `report.json` 的 `run_id` 代入 `./scripts/mix lab.rebuild RUN_ID` 及 `./scripts/mix lab.rebuild RUN_ID --checkpoint`。
这里 `RUN_ID` 是需要替换的参数，不是要新建的身份；两个命令都只读取已经存在的事实。
审计入口 [RebuildAudit](../lib/agent_systems_lab/rebuild_audit.ex) 的函数计数覆盖整个当前 VM，应在空闲或新 BEAM 中运行。
其他业务同时执行会污染计数；只检查控制台没有日志、复用原 PID 或原 ETS，都不能替代新进程证据。

## 14.6 版本兼容：五个版本域分别检查

| 版本域 | 当前契约 |
| --- | --- |
| Kernel/Event schema | 1；未知值拒绝 |
| Codec | 1；受限惰性数据，拒绝可执行或不支持的 term |
| history format | 1、2；这是 Event 存储布局 |
| checkpoint/recording schema | 按各自入口精确校验，不由 layout 代替 |
| SQL migration | 明确 DDL 列表，不等同于数据已经迁移 |

早期 L06 的“当周没有迁移器”描述的是第 7 周边界。当前 L20 已实现显式 layout 1→2，仍没有 Event schema 1→2 迁移。
v2 envelope 保存原 Codec 字节及 digest，解包后解释同一事件；不能把版本列改回 1，或忽略未知 schema 以冒充兼容。
Run/Event 混合布局、坏 envelope、缺失或损坏迁移 journal 都应失败。

`HistoryMigration.plan/1` 只读；`migrate/3` 要求当前 expected seq、没有有效 claim，在一个真实事务内修改布局并比较完整 snapshot。
journal 绑定迁移的原前缀，之后合法追加 v2 Event 不会抹去来源。预算、权限、cursor、deadline、回执和 checkpoint 的原含义保持。
有界迁移上限为 4096 Event / 32 MiB；超限拒绝，不截断。对应 [HistoryMigration](../lib/agent_systems_lab/history_migration.ex) 和 [迁移测试](../test/agent_systems_lab/history_migration_test.exs)。

## 14.7 备份还原后的“相同”与“可执行”

数据库 dump/restore 成功只证明传输步骤完成，还需核对原始行、schema/序列、重建状态和受保护业务事实。
复制来的有效 token 不能直接成为新目标执行权威。L20 先只读验证，再显式 fence 原 claim，最后才允许新资格续跑。
这意味着 exact restore 比较发生在 fence 之前；接管后 claim 字段按协议改变，不应再声称全部字节仍相同。

```sh
LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.upgrade --output artifacts/ch14-upgrade-reader-01
```

本命令创建并精确清理自己的实验数据库，保留原授权工作区；备份没有包含工作区、roles、tablespaces 或 WAL。
完整步骤和拒绝矩阵见 [L20](../labs/L20-history-migration-backup-restore.md)，事故操作见 [运行手册第 19 节](../docs/recovery-runbook.md#19-历史迁移版本兼容与备份还原)。

## 14.8 卡点、习题与完成标准

| 卡点 | 应采取的判断 |
| --- | --- |
| 旧 Run 能 rebuild，却不能 resume | 缺少原登记配置；不要猜 cursor、权限和预算 |
| safe ETF 词汇未加载 | 修复可信模块加载；不要移除安全解码限制 |
| 有坏 checkpoint，但全量能重建 | 保留损坏错误；不要静默掩盖坏记录 |
| hash 都相等，就可以自动执行吗 | 不能；完整性、授权和有效 claim 是不同条件 |
| 还原数据库能读，原文件却不在 | DB 备份不覆盖工作区；按原授权与文件证据另行处理 |

1. 把一条工具回执 operation ID 改掉，解释为什么重建必须拒绝，而不能再执行工具来“修复”。
2. 构造自洽的伪造 checkpoint，指出哪个权威前缀比较会拒绝它。
3. 给出迁移 COMMIT 前后崩溃的读取结果；说明 caller error 为什么不能证明回滚。
4. 区分布局 v2、Event schema v2 与新 SQL 列，写出每一项的当前支持范围。

首次阅读完成标准：能完成分组小练习和纯值比较，解释一条明确拒绝。持久化实验完成标准另含新 BEAM 零执行报告；不要把预期字段当成本次实测结论。
针对性测试可运行 `LAB_DATABASE_ENABLED=false ./scripts/mix test test/agent_systems_lab/history_test.exs test/agent_systems_lab/recording_test.exs`。
持久化与迁移测试按 [L06](../labs/L06-history-checkpoints.md)、L20 执行；尝试后查 [L06 参考解答](../labs/solutions/L06.md)和 [L20 参考解答](../labs/solutions/L20.md)。数量以自己的日志和 [W21 验收](../docs/validation-week21.md)分别记录。
本章不提供可信签名、任意不可信 archive 导入、生产 PITR 或跨地域恢复保证。
