# L08：有限重试、退避、超时与结果核对

对应第 9 周，建议用时 12—16 小时。前置实验为 L01—L07。本周继续使用持久 Recovery 路径，给暂时失败增加有界的下一次机会，并让结果未知的业务操作进入可见核对队列。

本次要证明：换一个 worker 不会重置重试次数或退避时间；超时不会被解释成“肯定没有执行”；非幂等操作的模糊结果不会自动重发；队列查询不会偷偷执行任务。最终成功只是其中一个断言，明确耗尽或等待核对也是正确结果。

## 1. 为错误选择下一步

先阅读 [ADR 0008](../docs/adr/0008-bounded-retries-and-reconciliation.md)，用“发生在什么边界、效果是否已知、当前能力允许什么”解释分类。

| 观察 | 应当回答的问题 | 下一步原则 |
| --- | --- | --- |
| 暂时不可用、临时限流 | 本次失败是否允许再次请求？剩余次数、时间与预算够吗？ | 持久保存失败和 due；到期后显式续跑 |
| schema、参数、权限或能力错误 | 同样输入再试能改变前提吗？ | 明确停止，不靠重试扩大授权 |
| 取消、总 deadline、输出预算耗尽 | 是否仍有执行资格和资源？ | 保留停止条件，不重置配额 |
| 模型请求超时 | 是否只有该请求等待超时？是否已经接受结果？ | 策略允许时重试；不接受半截流 |
| 工具超时或回执丢失 | 外部效果是否可能已发生？有权威回执或稳定去重契约吗？ | 先保留 unknown，再显式查询或人工核对 |
| 本地没有找到结果 | 没找到的是权威业务账本还是临时缓存？旧执行还可能迟到吗？ | 不能仅凭“没有本地结果”重新执行 |

同样的 timeout 字样可能产生不同后续动作。模型请求超时、Run deadline 和工具效果超时必须分开；错误类别不能替代工具能力、当前 claim 或预算检查。

`ErrorPolicy` 只做纯分类。下面三项说明为什么既需要 class，也需要 effect 与 retryable：

```elixir
alias AgentSystemsLab.ErrorPolicy
%{class: :transient, retryable: true} = ErrorPolicy.classify(:unavailable)
%{class: :unknown, retryable: false} = ErrorPolicy.classify(:tool_timeout,
  scope: :tool, idempotent?: false, effect: :possible)
%{class: :permanent, retryable: false} = ErrorPolicy.classify(:unrecognized_failure)
```

未识别原因保守地归为永久错误，不从任意字符串猜可重试。分类本身既不等待也不调用 Provider/工具，真正资格还要在执行边界检查。

练习：各举一个“可以重试但此刻不能重试”和“错误暂时发生但不能自动重投业务”的例子。第一个例子应落在退避、预算或到期资格上；第二个例子应落在结果未知与能力契约上。

## 2. 运行本周演示

在项目根目录执行：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
./scripts/mix lab.retry
./scripts/mix lab.reconcile
```

后续命令与 IEx 沿用这个终端；另开终端时先选择实例、清除 `DATABASE_URL` 并重新设置上述两个环境变量。启用 Repo 并关闭全局 Scheduler 后，由观察者决定何时 resume/reconcile，不会在你检查 due、claim 和队列之前被后台推进示例。

重复演示时使用新目录，保留原始证据：

```sh
./scripts/mix lab.retry --output artifacts/week09-retries-second
```

`lab.retry` 运行确定性的离线故障计划；`lab.reconcile` 只展示当前待核对任务，不调用 Provider 或工具。准确测试计数、报告路径与正式故障点见 [第 9 周验收记录](../docs/validation-week09.md)。

保存四种数量：模型请求尝试、工具执行尝试、核对查询尝试、业务效果数。它们各自回答不同问题。重试次数增加不应自动推出业务效果增加；核对查询也不能被统计成第二次业务写入。

## 3. 先验证策略是有限且持久的

重试策略在创建 Recovery Run 时明确启用，未启用的 Run 保持第 8 周行为。原 Recovery 配置 v1 不增加隐式默认字段；新策略与 journal 使用独立持久记录，并继续严格校验版本、形状和来源绑定。

默认策略的含义如下：

| 字段 | 默认值 | 约束 |
| --- | --- | --- |
| `max_attempts` | 3 | 包含第一次尝试的总次数 |
| `base_delay_ms` | 100 | 第一次失败后的退避间隔 |
| `max_delay_ms` | 5000 | 指数间隔的封顶值 |
| `max_elapsed_ms` | 30_000 | 当前工作的重试总时间窗口 |
| `tool_timeout_ms` | 1000 | 单次工具等待上限；不证明效果撤销 |

已完成第 `n` 次尝试后，候选间隔为 `min(max_delay_ms, base_delay_ms * 2^(n - 1))`。第一次失败后的间隔为 100 ms，第二次为 200 ms；若总共只允许 3 次尝试，第三次失败后不再安排第四次。间隔从本次失败被持久处理时开始计算，不通过重置首次尝试时间来延长窗口。

用纯 `RetryPolicy` 先验证时间算术；这里的整数时间只用于纯函数测试，真正执行使用数据库时间：

```elixir
alias AgentSystemsLab.RetryPolicy
{:ok, policy} = RetryPolicy.new([])
{:retry, 1100} = RetryPolicy.next(policy, 1, 1000, 1000)
{:retry, 1400} = RetryPolicy.next(policy, 2, 1000, 1200)
{:exhausted, :attempts} = RetryPolicy.next(policy, 3, 1000, 1500)
{:exhausted, :deadline} = RetryPolicy.next(policy, 1, 1000, 1000, 1100)
```

候选 due 达到 Run deadline 或首次尝试时间加重试窗口时，策略耗尽。时间窗口与次数上限同时约束，较长的一个不能覆盖较短的另一个。

未到期时调用 `resume`，应该快速返回 `{:ok, snapshot}`，其中当前 retry 保持 `:waiting`；直接调用 `step` 则返回 `{:error, {:retry_not_due, due}}`，不消费新 attempt。检查失败次数、最后原因、首次时间与 due 均已保存，当前 claim 已释放，新的 Provider/工具调用数为 0。不要用一个睡眠中的 worker 代表持久调度；退出该进程后，新进程仍须看见同一 due。

## 4. 模型暂时故障与超时

为同一逻辑脚本位置安排“暂时故障、成功”的尝试序列。第一次失败后应保留原 cursor，记录尝试与 due；到期前续跑不能调用 Provider。到期后新进程继续，完整成功响应通过 schema、预算、Kernel 与录制校验后，才推进 cursor 和已接受 turn。

在 `./scripts/iex` 中运行下面的独立任务。`model_attempt_scripts` 的键是原脚本的零基 cursor，列表元素是该位置各次尝试使用的完整 Scripted entry：

```elixir
alias AgentSystemsLab.{ModelResultStore, Recovery, RecoveryStore, RetryStore}
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
retry_id = "l08-model-#{suffix}"
{:ok, _} = Recovery.create_run(retry_id, "暂时失败后完成",
  script: [{:final, "恢复完成"}],
  retry_policy: [base_delay_ms: 5000, max_delay_ms: 5000, max_elapsed_ms: 120_000],
  model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "恢复完成"}]},
  run_timeout_ms: 300_000)
{:ok, waiting} = Recovery.resume(retry_id)
:running = waiting.state.status
0 = waiting.recovery.progress.cursor
1 = waiting.recovery.progress.model_attempts
%{status: :waiting, attempts: 1, next_attempt_at_ms: due} = waiting.recovery.retry
{:ok, unchanged} = Recovery.load(retry_id)
true = unchanged.recovery.retry.next_attempt_at_ms === due
```

在 due 之前再调用 `Recovery.resume(retry_id)`，尝试数仍应为 1。到期后由另一个进程或重新启动的 `./scripts/iex` 显式续跑，并检查最终事实。在同一个 IEx 中，下面的 sleep 只让实验观察者等到 due；Recovery 内部不 sleep 等待退避：

```elixir
Process.sleep(max(due - RecoveryStore.now_ms(), 0) + 25)
{:ok, done} = Recovery.resume(retry_id, owner: "l08-after-due")
:succeeded = done.state.status
"恢复完成" = done.state.output
1 = done.recovery.progress.cursor
2 = done.recovery.progress.model_attempts
{:ok, [recording]} = ModelResultStore.list(retry_id)
{:final, "恢复完成"} = recording.record.response
{:ok, [journal]} = RetryStore.list(retry_id)
2 = journal.attempts
2 = length(journal.deliveries)
```

`recovery.retry` 是当前 seq 的工作视图；转换推进后它可以为 nil。历史各 seq 的 journal 通过 `RetryStore.list/1` 查询，不能因为当前视图为空就认定之前没有失败。示例扩大了观察窗口，仍须按顺序在该窗口内执行；长时间停留后耗尽是正确保护结果。故障计划列表不足后沿用最后一条 entry，仍受有限次数约束；未配置的 cursor 使用原脚本。`retry_policy: []` 表示显式采用默认策略，省略策略则不启用；单独提供故障计划而没有策略会拒绝创建。

分别完成下列对照：

1. 暂时故障后成功：请求尝试为 2，完整接受的响应为 1；最终录制只有被接受的结果。
2. 连续暂时故障：达到总尝试上限后明确耗尽，不建立无限 due 链。
3. 单次模型请求超时：在允许的有限策略内安排下次尝试；原 attempt 的已扣字节保留。
4. Run deadline、输出字节或模型总尝试预算耗尽：不通过 retry 重新分配资源。
5. schema 或权限错误：同样输入不再投递，历史记录明确停止原因。
6. 一次失败产生部分流输出：不能拼接下一次 attempt 的半截流，也不能将失败输出录制成完整结果。

模型重试预算与 `max_model_attempts` 都要通过。前者约束当前工作的重复次数与窗口，后者约束整个 Run 的模型请求资源；Kernel `max_turns` 仍只统计已接受的模型响应。重启不能把这三个数归并成一个可以重置的计数器。

故障计划是创建时固定的测试输入，不在每次 resume 时偷偷更换 Provider。对照持久配置，检查成功后再调用 resume 不会消费故障计划里的下一条响应。

## 5. 工具重试先检查效果语义

使用持久 Mock 完成“可证明效果前暂时失败，稍后成功”的实验。原 operation ID、tool 和精确参数保持不变；实际投递可以新增 attempt，但业务效果最终为 1。将失败次数设置为超过策略上限时，应该在有限次数后停止，而不是不断生成新 operation 绕过去重。

```elixir
alias AgentSystemsLab.DurableTools
tool_id = "l08-tool-#{suffix}"
call = %{operation_id: "save-001", tool: "mock_write", arguments: %{"value" => "saved"}}
{:ok, _} = Recovery.create_run(tool_id, "效果前故障的有限重试",
  script: [{:call, call}, {:final, "保存完成"}],
  retry_policy: [base_delay_ms: 1000, max_delay_ms: 1000],
  mock_transient_failures: 1)
{:ok, proposed} = Recovery.step(tool_id)
:waiting_tool = proposed.state.status
{:ok, retrying} = Recovery.step(tool_id)
%{scope: :tool, status: :waiting, attempts: 1, next_attempt_at_ms: tool_due} = retrying.recovery.retry
%{effects: 0, attempts: 1} = DurableTools.stats(tool_id)
Process.sleep(max(tool_due - RecoveryStore.now_ms(), 0) + 25)
{:ok, saved} = Recovery.resume(tool_id)
:succeeded = saved.state.status
%{effects: 1, attempts: 2} = DurableTools.stats(tool_id)
```

这里自动重试只针对该幂等 Mock adapter 可证明的 transient/no-effect 回执。任意工具返回一个错误字样，或人工提供失败证据，都不会因此取得重投授权。`mock_transient_failures` 是创建时固定的离线故障计划，不在恢复时改变。

再比较“效果前明确失败”和“效果后回执丢失”：

| 边界 | 已知事实 | 正确后续 |
| --- | --- | --- |
| 能证明未产生效果的暂时故障 | 本次没有业务效果 | 策略与能力允许时安排退避 |
| 已产生效果且可按原身份查询 | 本地未接受结果，外部可能有回执 | 进入 unknown，显式查询原回执 |
| 非幂等/无法查询的效果超时 | 无法区分已执行与未执行 | 进入可见核对队列，保留 blocked |
| 文件替换后结果未保存 | 文件可能已改变，PostgreSQL 无法回滚文件 | 保留原 operation 和 attempt，等待明确核对 |

检查工具超时是否先限制本次等待，再保存 unknown 观察。终止本地任务不能证明外部工作已经取消；杀掉一个客户端进程更不能撤销已提交业务效果。即便工具声明幂等，也仍需当前 claim、资源与有限策略，不能跳过查询直接无限投递。

若发现相同 operation ID 被配上不同参数，应返回冲突并保持原业务效果数。更换参数和生成新的 operation ID 都不属于同一业务操作的安全重试。

## 6. 让 unknown 可见，并通过核对解除

创建一条无法权威查询、且回执丢失的 Mock 任务。它应该停在 blocked，当前调度意图为 reconcile。通过只读队列列出它，再按 Run ID 查看：

```sh
./scripts/mix lab.reconcile --run RUN_ID
./scripts/mix lab.reconcile --limit 20 --json
```

队列应能把任务、当前序号、operation、工具、未知原因和已有 attempts 关联起来。读取队列前后比较 Run seq、claim 代次、尝试数与业务效果数，全部应不变。队列是已提交事实的视图，不是另一个可以独立改成 completed 的任务表。

在 `./scripts/iex` 中创建独立任务，完成一次完整的队列观察：

```elixir
alias AgentSystemsLab.{DurableTools, ReconciliationQueue, Recovery}
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
unknown_id = "l08-unknown-#{suffix}"
call = %{operation_id: "charge-001", tool: "mock_write", arguments: %{"amount" => 1}}
{:ok, _} = Recovery.create_run(unknown_id, "核对一次模糊扣款",
  script: [{:call, call}, {:final, "核对完成"}],
  retry_policy: [], mock_mode: :unqueryable, mock_response: :lost)
{:ok, blocked} = Recovery.resume(unknown_id)
:blocked = blocked.state.status
before = DurableTools.stats(unknown_id)
{:ok, [entry]} = ReconciliationQueue.list(run_id: unknown_id)
:manual = entry.safe_mode
true = entry.recoverable
"charge-001" = entry.operation_id
{:ok, _same} = ReconciliationQueue.get(unknown_id)
true = DurableTools.stats(unknown_id) === before
{:error, :reconciliation_required} = Recovery.reconcile(unknown_id)
{:ok, [_still_queued]} = ReconciliationQueue.list(run_id: unknown_id)
1 = DurableTools.stats(unknown_id).effects
```

`latest_attempt` 只展示最近一次投递或核对的摘要，完整 attempts 通过 `DurableTools.list/1` 读取。旧 Run 即便没有 Recovery 配置，已有 unknown 仍可见，条目标记 `recoverable: false` 并采用保守的 `:manual` 模式；可见性不为它补造配置或授予续跑资格。

`list/1` 支持 `run_id:` 与 `limit:`，默认最多 100 项、允许 1—1000，按最早进入待核对状态的顺序展示。`get/1` 读取指定 Run；任务已经离队时返回 `{:error, :not_in_reconciliation_queue}`。CLI 的 `--run`、`--limit` 与 `--json` 为同一只读视图提供过滤和机器可读输出。

对可查询的 Mock 显式调用 `Recovery.reconcile(id)`，查回原 operation 的回执后接受核对结果。核对增加的是查询 attempt，业务效果数不增加。仍无法查明时保留 blocked；反复 list/get 不触发查询或自动重投。

已启用重试策略的可查询任务，还会为只读查询保存独立的 `:reconcile` journal。查询暂时失败或等待超时后，`reconcile` 返回 `{:error, {:retry_not_due, due}}`；到期前再次调用不新增查询。机会耗尽仍保留 blocked，并继续允许明确人工证据。Run 的执行 deadline 过后可以核对已经可能发生的效果，查询受自己的有限 elapsed 窗口与次数约束；核对成功也不会重新授权超时任务执行新的模型或工具步骤。人工确认不占用自动查询配额。

人工确认继续使用第 8 周的明确证据入口：

```elixir
{:ok, observed} = Recovery.reconcile(unknown_id,
  result: {:ok, %{"verified" => "external receipt checked by operator"}},
  evidence: "操作人依据独立业务账本核对了此 Run 与 operation；记录工单编号与核对时间")
:running = observed.state.status
```

只在已通过外部事实核实后执行此示例。这个低并发教学入口会绑定调用当时的 Run、operation、tool 与当前序号，并保留原 unknown attempt 和证据；它无法自行判断人工声明是否真实。确认失败可以传 `{:error, payload}`，同样需要证据。人的审阅可能过期时，改用[运行手册第 6 节的 expected seq helper](../docs/recovery-runbook.md#6-人工证据与预期序号)，不能把旧判断自动绑定到新操作。这里没有 `:cancel` 核对结果；取消另走 `Recovery.cancel/2`。已知失败、成功或取消都不会自动回滚已经发生的文件或业务写入。

在确认完成后重新查询队列，任务应离开当前待核对列表；原始 attempt、unknown 观察与证据仍能通过持久工具账本审计。随后显式 resume 才继续后续模型步骤。

```elixir
{:ok, []} = ReconciliationQueue.list(run_id: unknown_id)
{:error, :not_in_reconciliation_queue} = ReconciliationQueue.get(unknown_id)
{:ok, completed} = Recovery.resume(unknown_id)
:succeeded = completed.state.status
1 = DurableTools.stats(unknown_id).effects
```

再用一个独立 Run 验证取消分支；不要取消上面已经核对完成的 Run。以下是受控 Mock 反例，没有人工核对结论：

```elixir
cancel_id = "l08-cancel-#{suffix}"
{:ok, _} = Recovery.create_run(cancel_id, "停止推进但保留未决效果",
  script: [{:call, call}, {:final, "不应执行"}],
  retry_policy: [], mock_mode: :unqueryable, mock_response: :lost)
{:ok, cancel_blocked} = Recovery.resume(cancel_id)
:blocked = cancel_blocked.state.status
{:ok, cancelled} = Recovery.cancel(cancel_id, :stop_task)
:cancelled = cancelled.state.status
:unknown = cancelled.state.operations["charge-001"].status
{:ok, []} = ReconciliationQueue.list(run_id: cancel_id)
{:error, :not_blocked} = Recovery.reconcile(cancel_id)
{:ok, same_cancelled} = Recovery.resume(cancel_id)
true = same_cancelled.state === cancelled.state
1 = DurableTools.stats(cancel_id).effects
```

队列离项在两条分支中含义不同：核对后离项表示已接受已知结果；直接取消后离项只表示 Run 终结，原 operation 仍 unknown，也没有因此新增核对证据。后者需要在终态 Run 之外交接调查；当前仓库没有通用的取消后调查台账。

## 7. 故障注入与时间边界

故障点必须由 hook/gate 确认，真实退出后从独立进程或 BEAM 重读数据库。不要靠普通 sleep 猜 COMMIT 窗口；退避到期检查本身可以使用确定的数据库时间测试边界。

Recovery 新增 `hook:` 阶段 `:after_retry_reserve` 与 `:after_retry_schedule`，分别在预先占用一次尝试及保存失败/下一次计划之后触发。`RetryStore.reserve/4`、`schedule/5` 和 `finish/3` 自身的 `hook:` 支持 `:before_commit` / `:after_commit`，用于验证 journal 的真实提交边界；这与 Recovery 最终业务转换的 `commit_hook:` 是不同事务。旧 L07 的 Provider、工具效果与业务转换 hooks 继续适用，不能把一个接口的 stage 传给另一个接口后假定故障已经注入。

reservation 在真正调用前提交。相同 token 二次 reserve 应拒绝；新 claim 发现遗留 inflight 时，模型/只读查询先把旧尝试记为放弃并安排有限退避，工具则保留效果可能已发生的 unknown。不要通过“新 worker 尚未见过这条请求”让它再获得一次没有记账的机会。

| 场景 | 重启后必须保留 | 不允许出现 |
| --- | --- | --- |
| 暂时失败后、due 保存前退出 | 原意图与已有请求开销 | 从零开始的重试预算 |
| due COMMIT 后、ACK 前退出 | 相同 attempt 计数、首次时间与 due | 同一失败被再次安排为第一次 |
| 退避尚未到期时换 worker | 原 due，零新模型/工具调用 | worker 内忙等或提前执行 |
| 到期后两个 worker 竞争 | 只有有效 claim 能创建下一次尝试 | 两份并发接受结果 |
| 最后一次失败后退出 | 明确耗尽原因与已消费资源 | 重启得到额外尝试 |
| 模型超时后的旧响应迟到 | 新资格与已接受历史 | 旧请求覆盖取消或新结果 |
| 非幂等工具等待超时 | 原 operation、unknown、reconcile 意图 | 自动重投或伪造失败回执 |
| 效果已发生、receipt 尚未接受 | 原外部效果和核对入口 | 第二个业务效果 |
| 核对 COMMIT 前 / 后退出 | 前者未接受，后者恰好接受一次 | 丢失证据、重复核对 Event |
| 队列读取失败或未来版本数据 | 明确错误，原历史保持不变 | 忽略不兼容行或执行修复副作用 |

每个探针至少记录 Run/seq、scope、attempt 数、due、claim 代次、cursor、预算、工具效果数和队列状态。对比当前与原始历史，确认重试 journal 不能替代 Kernel 已接受事实，队列也不能掩盖损坏的数据。

## 8. 完成标准

至少保留以下保护测试：

- 去掉总尝试上限、due 检查或总时间窗口时，相应耗尽与提前调用断言必须失败。
- 在新进程中重新分配预算或重新计算首次时间时，跨进程测试必须失败。
- 把工具模糊超时当作明确效果前失败时，非幂等工具的禁止重投断言必须失败。
- 使 queue list/get 自动 reconcile 时，零调用与状态不变断言必须失败。
- 移除旧 token、取消或 expected seq 校验时，迟到结果与竞争断言必须失败。
- 将失败半截流放进模型结果录制时，录制数量与配对断言必须失败。

最后执行 `env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check`，确认前序 fixture、历史重建、事务崩溃和第 8 周恢复测试仍通过。建议评分：分类与停止规则 15 分，有限持久重试与退避 25 分，超时和预算 20 分，unknown/队列/核对 20 分，真实故障与跨进程证据 15 分，边界说明 5 分。

三条硬性要求：次数和时间必须有限；重建与队列读取仍零效果；未知的非幂等业务不得自动重发。任一条件不满足均不算完成。参考解答见 [L08 解答](solutions/L08.md)。
