# L12：背压、任务预算与公平性

对应第 13 周，建议用时 12—16 小时；前置实验为 L01—L11。实验编号沿用仓库实际顺序，本次完成原计划的背压、每任务预算、超时回收和饥饿检测主题。先读 [ADR 0012](../docs/adr/0012-backpressure-and-fairness.md)、[恢复运行手册第 11 节](../docs/recovery-runbook.md#11-背压任务预算与饥饿告警) 和 [第 13 周验收记录](../docs/validation-week13.md)。

本实验将输入压到可用执行容量之上，要求系统明确拒绝额外工作，并让已接受任务继续使用原 Run、intent 与 operation 身份恢复。它还让高优先级工作持续占用执行机会，测量低优先级任务的等待和服务情况。

## 1. 先区分四个上限

| 限制 | 约束范围 | 不能据此推导的保证 |
| --- | --- | --- |
| 命名队列 `capacity` | 该队列尚未终结的 Run，包括 blocked | 历史表行数、文件总大小或记录保留期有界 |
| 命名队列 `max_inflight` | 该队列当前有效的数据库 lease | 暂停的旧 Worker、远端请求或全机器进程数等于这个值 |
| Scheduler `max_workers` | 该实例尚未结束的 Worker | 多个实例总 Worker 数仍等于单实例上限 |
| 每任务预算 | 原 Run 的调度机会与单次执行时间 | 模型字节、turn、工具效果或原 retry 预算被替代 |

命名队列为显式 opt-in；已有未入队 Run 沿用前序行为。多个 Scheduler 的本地上限相加，但同一个队列的有效 lease 仍受共享配额约束。lease 过期后旧进程可能仍存在，数据库 fencing 必须继续拒绝其迟到写入。

`Scheduler.start_link(queue: name, ...)` 才会扫描这个命名队列；省略 queue 的 Scheduler 只扫描未入队 Run，单独设置 run_ids 不会改变队列范围。队列名保存的是固定持久身份，不能用第二个近似名字绕开原 capacity 或 quota。

## 2. 准备

在项目根目录的同一终端执行；另开终端时先选择实例、清除 `DATABASE_URL` 并重新执行下面两条 `export`。显式启用数据库、关闭应用级 Scheduler，避免继承内存实验或其他实验留下的配置：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
./scripts/mix lab.load
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

`lab.load` 创建自己的命名队列与实验 Run，不接管已有事故任务。默认输出目录为 `artifacts/week13-load`，默认任务数为 12，`--jobs` 范围是 6—100；已有目录不能覆盖，复测应选择新的路径：

```sh
./scripts/mix lab.load --output artifacts/week13-load-repeat --jobs 24
```

查看原始报告时，把拒绝、已接受、完成、blocked、投递、模型请求和真实效果分开计数，不能把主动拒绝算成丢失任务。

## 3. 持久准入与背压

队列创建后设置固定 capacity 和 max_inflight，再在同一队列并发创建超过 capacity 的 Run。创建事务锁住队列、检查未终结 Run 数量并提交全部初始事实；超过上限的请求得到明确拒绝，不能留下只写入了一半的 Run/Event/intent。

blocked 仍占 capacity，因为它代表未完成且需要核对的真实工作。终态释放准入名额，操作回执、事件和去重身份仍保留。不要为了“释放队列”直接删除 blocked Run、operation、attempt 或准备记录。

生产者收到满载拒绝后应停止继续提交，等待容量或使用有界退避。把拒绝任务转交给无限 spawn、无界 mailbox 或另一个内存列表，只会把积压移到看不见的位置。本实验只承诺使用命名队列准入接口接受的未完成工作有界；历史保留与任意外部生产者仍需独立策略。

### 一个限定范围的准入示例

在上述同一终端用 `./scripts/iex` 进入会话后连续执行。示例只创建一个新队列和自己的 Run，并只启动该队列的 Scheduler；第三个 ID 被拒绝后没有持久事实。任务完成后保留演示历史，重复执行会使用新的名字：

```elixir
alias AgentSystemsLab.{QueueStore, Recovery, Scheduler, Storage, TaskBudgetStore}
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
queue = "l12-queue-" <> suffix
ids = for n <- 1..3, do: "l12-run-#{suffix}-#{n}"
[first, second, rejected] = ids
{:ok, _} = QueueStore.create(queue, capacity: 2, max_inflight: 1,
  aging_ms: 100, starvation_ms: 500)
for id <- [first, second] do
  {:ok, _} = Recovery.create_run(id, "L12 bounded admission",
    queue: queue, script: [{:final, "done"}],
    task_budget: [max_dispatches: 4, execution_timeout_ms: 2000])
end
{:error, :queue_full} = Recovery.create_run(rejected, "must be rejected",
  queue: queue, script: [{:final, "unreachable"}])
{:error, :not_found} = Storage.load(rejected)
{:ok, %{active: 2, available_slots: 0, live_leases: 0}} = QueueStore.stats(queue)
{:ok, scheduler} = Scheduler.start_link(queue: queue, workers: 2,
  lease_ms: 1000, renew_interval_ms: 100, poll_interval_ms: 20)

try do
  :ok = Enum.reduce_while(1..200, {:error, :l12_timeout}, fn _, _ ->
    done = Enum.all?([first, second], fn id ->
      {:ok, saved} = Recovery.load(id)
      saved.state.status == :succeeded
    end)
    if done and Scheduler.status(scheduler).active == [] do
      {:halt, :ok}
    else
      Process.sleep(25)
      {:cont, {:error, :l12_timeout}}
    end
  end)
  {:ok, %{active: 0, available_slots: 2, live_leases: 0}} = QueueStore.stats(queue)
  {:ok, []} = QueueStore.starvation(queue)
  for id <- [first, second] do
    {:ok, %{progress: %{dispatches: 1}}} = TaskBudgetStore.load(id)
  end
  IO.inspect(%{queue: queue, completed: [first, second], rejected: rejected},
    label: "L12_ADMISSION_SUCCESS")
after
  if Process.alive?(scheduler), do: Scheduler.stop(scheduler)
end
```

`QueueStore.create/2` 的 capacity 范围为 1—10000，max_inflight 为 1—capacity；aging_ms、starvation_ms 范围均为 1—86400000，默认分别为 1000 与 10000ms。配置创建后固定；同名队列返回已有队列错误，不把它当作空白实验环境复用。`stats/1` 与 `starvation/2` 只读，starvation 的 limit 默认 100、范围 1—1000。

本例已通过独立脚本验证；[执行日志](../artifacts/week13-docs/admission-check.log) 与 [脚本](../artifacts/week13-docs/admission-check.exs) 保留验证记录。脚本的清理仅删除它本次生成的独立演示 ID 和队列，不是事故恢复步骤；实际事故记录按恢复运行手册保留。

## 4. 饱和负载与共享配额

启动至少两个限定同一队列的 Scheduler，让总 Worker 槽位大于 queue max_inflight，Provider 在受控 gate 中等待。持续采样：

- 队列未终结数、有效 lease、可领取数和 retry 等待数。
- 每个 Scheduler 的 active、Worker/executor 与相关 TaskSupervisor 子进程数。
- 重复 wake 前后的待处理唤醒与扫描行为，不能因通知风暴不断预领或扩张 Worker。
- 解除 gate 后的成功结果、原 operation 效果数、回收中执行者与最终退出情况。

最危险的观测点是在饱和期间，不能仅在结束后数零个 Worker。报告保留高水位及约束，分清实时采样最大值和设计硬上限。VM 的基础进程、数据库连接与固定 supervisor 会形成基线；完整机器进程数不能直接等于业务 Worker 数。

`Scheduler.status/1` 增加 queue、scan_limit、execution_timeout_ms、wake_requests、wake_pending 与 message_queue_len。wake_requests 是本次实例看见的提示次数，wake_pending 表示已合并的待处理提示；它们均为本地诊断，重启后清零。原始 `$gen_cast` 或其他外部消息不属于 `Scheduler.wake/1` 的合并契约；这也不是任意 subscriber 邮箱有界的声明。

共享 quota 在领取事务中判断，显式领取也应受同一个命名队列约束。旧 lease 到期后允许接管，旧 Worker 可能尚未退出；此时逻辑资格仍有界，真实本地进程继续受各实例槽位与清理协议约束。第 12 周的 token/generation fencing 继续决定谁能提交。

## 5. 每任务预算与超时回收

命名队列 Run 默认固定保存 `task_budget: [max_dispatches: 32, execution_timeout_ms: 5000]`，创建时可明确设置。每次执行前扣除调度机会，同一 claim 的同一次预留不重复计数；重新启动 Scheduler、换 Worker、lease 接管或新 BEAM 续跑均不能把计数清零。未入队且未指定 task_budget 的既有 Run 不增加持久 dispatch 上限。已有输出字节、stream event、工具调用、turn、绝对 Run deadline 和有限 retry 政策继续独立生效。

使用只读 `TaskBudgetStore.load(id)` 查看固定 config 与 progress，后者保留 dispatches、last_claim_token、last_seq 和 execution_deadline_at_ms；未启用预算时返回 `{:ok, nil}`。Scheduler 的 `execution_timeout_ms` 默认 30000ms，实际执行还受任务预算和原 Run 绝对 deadline 的更早上限约束。预算超限理由分别是 `{:budget_exceeded, :dispatches}` 和 `{:budget_exceeded, :execution_timeout}`，不能当作工具确定未发生的证明。

max_dispatches 范围为 1—1000000；任务与 Scheduler 的 execution_timeout_ms 范围均为 1—86400000。对启用 task_budget 且已经启动的同一 claim 再执行返回 `:dispatch_already_started`，保留原预留而不重复启动业务；换新 claim 会消耗下一个机会。核对已经发生的结果不消耗一次新的业务调度机会。

对一个停在 gate 的执行，让 Worker 继续 heartbeat，观察单次执行 watchdog 仍能回收。它先停止并等待自己的 executor 退出，再在当前 claim 下读取已提交事实并处理本次超时。heartbeat 的成功不代表任务仍有执行预算，也不能让挂起任务无限占据配额。

分别在模型完成前、工具 prepare 后、工具效果后和 receipt 后注入超时。已确认 receipt 应复用；有准备记录但无法证明结果的工具保持 blocked 并按原能力核对；没有工具台账的未完成执行明确 failed。核对结果仍可在调度预算耗尽后继续，非幂等未知结果不能自动重发。不能因为进程退出或 budget 归零就声明效果未发生，也不能换 operation ID 重新执行业务。

本地 watchdog 依赖当前进程与数据库可响应，不是 OS 沙箱或实时终止保证。一个已发送的远端请求可能继续执行；预算回收不能替代目标幂等、查询和 fencing。

## 6. 公平性测量与饥饿检测

使用不同基础优先级的 Run，记录当前 intent 的创建时间、实际领取时间与服务顺序。`wait_ms` 是当前 intent 从数据库创建到观察时的年龄，有效优先级为 `min(9, priority + floor(wait_ms / aging_ms))`。有界候选页内先比较有效优先级，再比较 intent ID；持久 ID 游标与本轮 ceiling 使扫描逐页推进。它不保证每次全队列严格最高优先级，也不抢占正在执行的步骤，不能绕过 lease、预算、retry 的真实 due 或人工核对。

让低优先级候选先等待，再持续加入高优先级工作。验证低优先级任务最终获得服务，并保留等待时间与服务次数；仅看到全部任务最终成功，无法解释短时饥饿。报告同时说明样本规模、负载长度、aging 与 starvation 阈值，避免把一次开发机测试解释成生产公平 SLO。

饥饿检测是只读观察。观察时已具备领取资格且 intent 年龄超过 starvation 阈值的候选应可见；future retry、活跃 lease、blocked/manual 与终态不能被误报成调度器忽略的任务。这不是累计 eligible 时间指标；旧 intent 刚到 retry due 后可能立刻告警，应结合原 due 解释。检测不允许领取、续期、变更 priority、删除 retry 或执行模型/工具。

还应安排一批未到期 retry 排在可领取候选之前，验证有界扫描能够越过这一前缀继续发现任务。一次查询有 LIMIT 并不足以证明活性：如果每次都重扫同一批 future 项，后续任务仍可能永远无法获得机会。

命名队列的 scan_limit 默认 32、范围 1—256，限制一次领取的扫描页；持久 scan_cursor 与 scan_ceiling 记录轮转进展。一次 poll 最多为当前空闲 Worker 槽位逐次领取，不预先保存业务批次；未入队 legacy 路径不使用这个页上限，保留前序完整扫描契约。观察时不要手动移动 cursor 或修改 ceiling。

## 7. 验收与交付

| 场景 | 必须保留的证据 |
| --- | --- |
| 并发超量准入 | 只接受 capacity 内任务；拒绝 ID 无 Run/Event/intent；blocked 持续占位 |
| 多 Scheduler 饱和 | 共享有效 lease 与每实例 Worker 均未越界，执行/Task 数高水位受控 |
| 重复 wake | 唤醒可合并，无业务队列复制或无限计时器增长 |
| 单次执行超时 | 本次执行者实际退出；确认结果与 unknown 分别保持正确去向 |
| 调度预算耗尽 | 原计数跨新进程保留，耗尽后不启动额外业务动作 |
| 优先级老化 | 服务顺序、低优先级等待及持续高优先级输入有原始记录 |
| 饥饿检测 | 可领取超阈值候选可见；future retry/live lease/manual 不误报 |
| 扫描活性 | future 前缀之后的到期任务可被发现，单批工作仍有界 |

交付包括新增测试、负载 runner 的原始报告与采样、[第 13 周验收记录](../docs/validation-week13.md)、[运行手册](../docs/recovery-runbook.md) 与 [参考解答](solutions/L12.md)。所有既有测试继续通过。公平性与负载结果绑定此次开发机和离线 Provider/受控工具；第 14 周的数据库断连、组件对照与 P3 汇总需要独立验证。

`lab.load` 保留 `report.json`、同内容的 `metrics.json`、逐次采样 `timeline.json` 和 inert `journals.bin`。三阶段分别为 saturation、fairness、budgets；报告列出自己的 run_ids 与 queue_names。饱和阶段用两个各有 2 Worker 槽位的实例共享 max_inflight 2，提交 2 × jobs 个任务，只接受 capacity 内的 jobs 个；它同时检查拒绝 ID 没有 Run、400 次 wake 提示可排空，以及终态后可以再次准入。公平性阶段让低优先级候选自然等待，持续加入六个高优先级任务，保留服务前饥饿条目、服务顺序和等待。预算阶段覆盖 dispatch 上限、慢模型回收、工具效果后超时与可见 manual 占位；预期 blocked 是保留未知事实的正确结果。
