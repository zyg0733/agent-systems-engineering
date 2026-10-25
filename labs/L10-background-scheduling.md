# L10：持久调度意图与多 Worker

对应第 11 周，建议用时 12—16 小时；前置实验为 L01—L09。实验编号沿用仓库的实际顺序，本次对应原计划中的 Queue 与 Worker 主题。已有 Recovery 协议负责决定什么可以执行；本周把周期发现、有限并发和到期再领取接到这些已提交事实上。

阅读 [ADR 0010](../docs/adr/0010-background-scheduling.md)、[恢复运行手册](../docs/recovery-runbook.md) 和 [第 11 周验收记录](../docs/validation-week11.md)。这里的后台进程是应用内教学调度器；启动它就可能调用离线模型与工具。

## 1. 验收目标

| 机制 | 必须观察到的事实 |
| --- | --- |
| 原子领取 | 多消费者竞争同一意图时，只产生一个当前有效 claim |
| 有限并发 | 每个 Scheduler 的在途执行不超过配置的 Worker 数 |
| 周期发现 | 已提交意图即使没有 wake 提示也能被后续扫描发现 |
| 租约续期 | 长于初始 lease 的工作由同一 token/generation 续期；其他消费者不能接管有效 lease |
| 重复投递 | 重复 wake 或重新扫描不产生第二份已接受结果；已确认工具回执仍复用 |
| 到期重试 | 失败提交时保存 due，due 前不新增尝试；到期后自动领取且不重置预算 |
| 崩溃接管 | Worker 失联后等待数据库 lease 到期，再按原身份接管 |
| unknown | blocked/reconcile 不进入自动业务执行；待核对项继续可见 |

“claim 唯一”“Event 只接受一次”和“外部效果唯一”是三项断言。前两项依赖数据库事务与 fencing；最后一项仍取决于目标工具的稳定身份、幂等或权威查询能力。租约到期不证明旧进程或真实远端效果已经停止。

## 2. 先读调度协议

```text
Run / Event / 下一调度意图在同一事务提交
  → 周期扫描，或收到 wake 提示
  → 锁 Run（SKIP LOCKED）
  → 校验当前意图、Recovery 登记、租约与真实 retry due
  → 锁意图并提交新 token / generation / lease
  → 一个 Worker 执行一个 Recovery 步骤，独立续期
  → 提交结果与下一意图，或保存退避 due
  → 释放本次资格，再参加下一轮领取
```

上图描述未入队 Run 的领取，锁序为 Run → 当前 Intent；命名队列先取得 Queue 锁，再按 Queue → Run → Intent 领取。renew/release 在 Run 锁内校验当前 Intent，不可把不同入口理解为可以交换锁序。队列范围和提交门见[第 20 章](../book/ch20-scheduling-and-recovery.md#203-先提交领取再执行效果)。`SKIP LOCKED` 允许另一个消费者先处理未被锁住的 Run；它不是吞掉错误或跳过校验。

`IntentStore.claim_next/2` 返回与指定 Run 领取相同的七个字段：intent ID、Run ID、seq、owner、token、generation、expires_at。`{:ok, nil}` 表示本次没有符合条件的工作，不代表数据库已经永远清空。领取只有 COMMIT 后才返回成功。

扫描排除终态、不是当前 seq 的旧意图、尚有有效 lease 的意图、未登记 Recovery 的旧 Run，以及 blocked/reconcile。调度器只调用已领取步骤，不再使用 Run ID 二次领取，否则自己的有效 lease 也会成为冲突。

## 3. 启动与观察

在项目根目录准备数据库：

```sh
./scripts/postgres start
./scripts/mix setup
./scripts/mix check
./scripts/mix lab.schedule
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

`lab.schedule` 创建独立示例 Run 并运行多 Worker 演示，实际结果见输出报告。它不会接管某个事故 Run。为已有 Run 开启自动执行前，先按运行手册核对原配置、权限、预算与 unknown 状态；测试或演示应始终限定 `run_ids`，避免消费同一数据库中的其他练习。

默认应用启动不会执行旧 Run。专用实验数据库准备并迁移完成后，可用 `LAB_SCHEDULER_ENABLED=true ./scripts/iex` 启动应用监督的命名调度器；当前配置为 2 个 Worker、100 ms 扫描、5000 ms lease、1000 ms 续期。它没有限定 Run 范围，会消费数据库中所有符合资格的工作，因此下面练习使用默认关闭的应用和显式限定范围的实例：

```sh
./scripts/iex
```

在 IEx 中创建三个独立 Run：长模型步骤、一次工具调用，以及可到期重试的模型。脚本均为可持久化数据，不含 PID、reference 或匿名函数：

```elixir
alias AgentSystemsLab.{DurableTools, ModelResultStore, Recovery, RetryStore, Scheduler}
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
slow_id = "l10-slow-#{suffix}"
tool_id = "l10-tool-#{suffix}"
retry_id = "l10-retry-#{suffix}"
ids = [slow_id, tool_id, retry_id]

{:ok, _} = Recovery.create_run(slow_id, "跨初始 lease 的步骤",
  script: [{:stream, [{:sleep, 1500}, {:text_delta, "slow done"}, :done]}],
  priority: 9, run_timeout_ms: 120_000)
{:ok, _} = Recovery.create_run(tool_id, "一次受控 Mock 效果",
  script: [
    {:call, %{operation_id: "once", tool: "mock_write", arguments: %{"value" => 7}}},
    {:final, "tool done"}], priority: 1, run_timeout_ms: 120_000)
{:ok, _} = Recovery.create_run(retry_id, "按原 due 自动重试",
  script: [{:final, "retry done"}],
  retry_policy: [base_delay_ms: 3000, max_delay_ms: 3000, max_elapsed_ms: 60_000],
  model_attempt_scripts: %{0 => [{:error, :unavailable}, {:final, "retry done"}]},
  run_timeout_ms: 120_000)

{:ok, scheduler} = Scheduler.start_link(workers: 2, run_ids: ids,
  poll_interval_ms: 25, lease_ms: 600, renew_interval_ms: 100)
for _ <- 1..20, do: Scheduler.wake(scheduler)
view = Scheduler.status(scheduler)
true = length(view.active) <= view.max_workers
```

`start_link/1` 未提供 `name` 时返回未注册实例；后续把 `scheduler` PID 传入 API。默认 `workers` 为 4，也可改用同义 `max_workers`，两者不能同时提供。`poll_interval_ms` 默认为 100，`lease_ms` 默认为 30_000，`renew_interval_ms` 默认为 lease 的三分之一；续期间隔须为正且小于 lease。`run_ids` 必须是非空 ID 列表，空列表会被拒绝；省略该项才是全库可执行范围。

用有上限的观察者等待条件成立。这里的 sleep 只用于实验观察，不占用 Scheduler Worker 的 retry lease：

```elixir
await = fn predicate ->
  Enum.reduce_while(1..400, {:error, :observation_timeout}, fn _, _ ->
    if predicate.() do
      {:halt, :ok}
    else
      Process.sleep(25)
      {:cont, {:error, :observation_timeout}}
    end
  end)
end
:ok = await.(fn ->
  {:ok, current} = Recovery.load(retry_id)
  match?(%{status: :waiting}, current.recovery.retry)
end)
{:ok, waiting} = Recovery.load(retry_id)
due = waiting.recovery.retry.next_attempt_at_ms
1 = waiting.recovery.progress.model_attempts

:ok = await.(fn ->
  Enum.all?(ids, fn id ->
    {:ok, current} = Recovery.load(id)
    current.state.status == :succeeded
  end)
end)
view = Scheduler.status(scheduler)
true = view.counters.renewed > 0
1 = DurableTools.stats(tool_id).effects
{:ok, retried} = Recovery.load(retry_id)
2 = retried.recovery.progress.model_attempts
1 = retried.recovery.progress.cursor
{:ok, [record]} = ModelResultStore.list(retry_id)
{:final, "retry done"} = record.record.response
{:ok, [journal]} = RetryStore.list(retry_id)
2 = journal.attempts
:ok = Scheduler.stop(scheduler)
```

以上观察应在创建后立即连续完成；停留超过原 Run deadline 或 retry 窗口会按原预算结束。`status.active` 的 claim 包含 token，属于写入凭证；分享截图或报告时只保留需要的身份摘要。`claimed/completed/failed/renewed/scans` 是当前进程诊断计数，重启会清零；`completed` 计的是一次步骤调用正常返回，不是业务 Run 成功数。

`Scheduler.status/1` 返回配置、在途 Worker/executor、续期次数与最近错误。历史事实仍通过 `Recovery.load`、Retry/operation journal 与 Events 查询。`wake/1` 是异步提示，返回 `:ok` 不代表工作已被领取或完成。

## 4. 优先级与领取范围

优先级在 Run 创建时固定为 0—9，默认 0，值越大越先考虑。同级按意图 ID 从小到大挑选；多消费者、`SKIP LOCKED` 和并发提交意味着实际完成顺序可以不同。优先级不抢占正在执行的工作，也不延长预算或绕过 due。

每次只执行一个持久步骤，然后重新竞争下一意图。不要让某个 Worker 为一个 Run 调用无界循环，也不要在退避期间占据执行槽位。`workers` 限制的是一个 Scheduler 的在途工作；启动两个 Scheduler 时，总容量是两者配置之和，数据库 claim 仍约束同一意图的有效 owner。

持续出现高优先级任务可能推迟低优先级任务。第 11 周不宣称跨优先级无饥饿，也没有每租户配额、全局背压、抢占或生产吞吐 SLO；公平性与饱和测量在后续阶段继续完成。

## 5. 到期时间必须是持久事实

意图的 `available_at` 是观察投影；Retry journal 中的原始 due 仍是资格依据。失败保存 retry 状态时，在同一个事务中更新对应意图的提示。当前 SQL 不用该字段硬过滤候选，而是在 Run 锁下解析权威 journal；它不是大型队列的查询优化承诺。新进程不能从自己的启动时刻重新计算退避。

旧行没有提示时仍要读取原 retry；提示意外提前也不能提前调用模型或工具，意外推迟也不能永久隐藏已经到期的任务。领取在 Run 锁下根据持久 journal 再校验；hint 不提供绕过预算、版本或损坏记录的权限。

补充故障练习：工具效果或本地回执提交后杀死 Worker，停止原调度器，等待原 lease 与 Run deadline 自然到期，再由新实例接管。未确认的投递应进入 blocked 队列；已确认回执应接受为原工具事实，后续模型按原期限失败；无准备台账的过期工具直接失败。三种结果都不得重新执行目标或延长预算，参考 `SchedulerDeadlineTest`。

安排一个首次失败、第二次成功的模型脚本，保存第一次 attempt、due、cursor 与模型录制数。due 前反复 `wake`，这些值应保持不变且 lease 不被空占。到期后由周期扫描取得下一次资格，最终模型 attempts 为 2、cursor 为 1、已接受模型录制为 1。再安排持续可重试失败，确认达到原次数或时间边界就停止。

故障点放在 retry schedule 已 COMMIT、Worker 尚未收到确认的位置。重新启动 Scheduler 后仍应读到同一 due；不要改 SQL 时间字段或删除旧 Retry 行来加快练习。

## 6. 并发、续期与重复投递

并发领取采用 gate 同时释放多个消费者，让它们争用同一个已提交意图。记录每个返回值与独立数据库读取，只允许一个当前有效 token。另做多个 Run 的并发领取，证明消费者能跳过被锁定的 Run，而不把所有工作排成单队。

续期实验让模型步骤持续超过初始 lease，记录续期前后的 expiry。续期保持 token/generation 不变；即使经过初始 expiry，其他消费者仍无法领取。续期失败、claim 已过期或被取消时，停止旧工作并丢弃该资格；不能清掉 successor 的 lease，也不能只更新内存中的截止时间。

对同一 Run 连续发送多次 wake，并让两个独立 Scheduler 扫描同一范围。检查 Event 序列连续、模型接受数与逻辑调用相符、持久 Mock 的效果数为 1。Wake 只是降低发现延迟，不能作为完整、唯一或可靠的任务来源。

在本地确认工具 receipt 后、Kernel 接受结果前杀 Worker，等待原 lease 自然到期。新 Worker 继续同一 operation 并复用回执；新的 delivery/attempt 可以增加，目标效果不能增加。若没有 receipt 且目标不可查询，正确结果是 blocked，随后扫描不能再次执行该业务。

## 7. 停止与故障处理

停止调度器只改变未来领取，不撤销已发生效果。停机时的在途 Worker、续期者与工具子进程须按真实生命周期清理；无法证明已退出的工作不能提前释放为“肯定未执行”。异常退出留下的有效 claim 到期后，接管仍走原 Recovery 协议。

数据库异常、schema/hash 损坏与未知结果应有可读诊断，不能被当作 `{:ok, nil}` 掩盖，也不能从连接错误推断事务未 COMMIT。操作员先关闭或限定后台领取范围，采集原始状态与回执，再选择安全续跑或人工核对。详见 [恢复运行手册](../docs/recovery-runbook.md)。

本周验证进程失联、租约续期与到期接管；完整操作系统 SIGSTOP/SIGCONT、网络分区、受控外部目标 fencing 与全局背压尚不是本周的完成声明。

## 8. 交付检查

提交原子 claim-next、后台 Scheduler、有限 Worker 执行与测试，并保存以下证据：

- 同一意图多消费者竞争与不同 Run 的并发执行；锁顺序与跳过已锁 Run 的断言。
- 长步骤真实续期、Worker 退出后的到期再领取、旧 token 无法提交或释放新资格。
- 重复 wake / 重复扫描、已确认 receipt 复用、不可查询 unknown 不自动重发。
- 原 due 前零新尝试、到期自动继续、次数耗尽停止与重启不重算 due。
- Scheduler 默认关闭、数据库关闭模式正常启动，全部前序测试仍通过。
- 报告区分扫描次数、delivery、已接受结果和目标效果，说明并发上限是每个 Scheduler 的配置。

参考解答见 [L10 解答](solutions/L10.md)。正式测试数量、演示产物与验证日志见 [第 11 周验收记录](../docs/validation-week11.md)。
