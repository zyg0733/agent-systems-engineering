# L11：Lease、Heartbeat 与旧 Worker 复活

对应第 12 周，建议用时 12—16 小时；前置实验为 L01—L10。实验编号沿用仓库实际顺序，本次对应原计划中的 Lease 与 fencing 主题。先读 [ADR 0011](../docs/adr/0011-leases-heartbeats-fencing.md)、[恢复运行手册](../docs/recovery-runbook.md) 和 [第 12 周验收记录](../docs/validation-week12.md)。

本实验让旧 Worker 所在的独立 BEAM 被操作系统暂停，保持 PostgreSQL 与接管者运行，等待真实 lease 到期。接管者取得新资格后恢复旧 BEAM，要求旧执行代次无法接受迟到模型结果、写入工具回执、执行尚未开始的受控效果，或释放接管者的资格。

## 1. 验收目标与边界

| 机制 | 解决的问题 | 必须观察到的事实 |
| --- | --- | --- |
| Lease | 何时允许另一个消费者领取 | 以 PostgreSQL 时间判断真实 expiry；有效 lease 不被抢占，到期才能接管 |
| Heartbeat | 活跃执行如何保留资格 | 执行与续期可以并行；续期保持原 token/generation；失败不能复活旧资格 |
| 数据库 fencing | 旧 owner 恢复后还能写什么 | 当前 intent、seq、owner、token、generation 与数据库 expiry 均须通过校验 |
| 受控工具效果门 | 尚未开始的本地效果是否可执行 | 效果执行前重验当前资格，旧代次不能凭原先的准备记录开始新效果 |
| 目标能力契约 | 已发出的效果如何安全恢复 | 已确认 receipt 复用；可查询目标按原身份核对；不可查询模糊结果保持 blocked |

Heartbeat 是延长当前资格的尝试，不是已成功提交结果的证明。Lease 到期也不是回滚：旧进程可能仍存在，远端请求可能继续执行，文件可能已经写入。数据库能拒绝旧代次的本地更新；一个独立远端服务若要拒绝迟到请求，仍需它自身检查 fencing 或提供稳定幂等/查询协议。

## 2. 领取、续期与写入协议

```text
旧 Worker 领取 token A / generation N
  → 独立执行器运行，Worker 控制过程定期续期 A / N
  → SIGSTOP 独立 BEAM：执行器与续期者一起暂停
  → PostgreSQL 的 lease 自然到期
  → 接管者提交 token B / generation N+1
  → SIGCONT 旧 BEAM
  → A / N 的迟到写入被拒绝；不能延长或释放 B / N+1
  → 接管者读取原 operation / receipt / retry 事实，继续原业务身份
```

本册未入队示例的领取按 Run → Intent 锁定；命名队列的领取须先锁 Queue，再按 Queue → Run → Intent 取得权威。续期、release 与普通业务提交在 Run 锁内校验当前 Intent，不反向补取 Queue 锁。每次重新领取更换 token 并递增 generation；正常续期保留两者。`expires_at` 在 claim map 中是该次返回时的观察值，写入资格以数据库中的当前行和当前时间为准。仅修改调用者内存中的 expiry，不能延长数据库 lease。

续期还需要覆盖一个事务内部窗口：调用通过 `verify` 后可能暂停，即使它仍持有 Run 锁，等恢复到 UPDATE 时原 lease 也可能已经过期。续期 UPDATE 自身再次要求原 expiry 大于数据库当前时间，并在写入时计算新 expiry；已过期返回 `:claim_expired`，不能因为先前校验成功就重新延长旧 token。内部 `:before_renew_write` gate 只用于精确复现这个窗口，测试仍等待真实时间到期。

Worker 的续期 timer 携带每次新生成的 reference，只处理当前 tick；已取消、过期或重复的 tick 不会触发额外续期。这个 reference 用于本地计时器去重，数据库 token/generation 才决定持久写入资格。

不要把 seq CAS 的拒绝误当作 token fencing 的证明。如果接管者已经推进 seq，旧提交单凭 seq 变化就可能失败。因此本实验既覆盖 successor 已提交后的拒绝，也在 **同一个 seq、同一个 intent ID** 上保留 successor 的有效 claim，让旧调用确实经过 token/generation 边界。

### 只观察一个限定范围的 Heartbeat

确认沿 L10 准备的数据库仍在运行，再用 `LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/iex` 进入会话并连续执行以下代码。它只创建一个独立 Run，gate 暂停该 executor，Worker 继续续期；本段不发送操作系统信号：

```elixir
alias AgentSystemsLab.{IntentStore, Recovery, Scheduler}
id = "l11-heartbeat-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
owner = self()
hook = fn
  :after_input ->
    send(owner, {:l11_input, self()})
    receive do
      :l11_continue -> :ok
    after
      10_000 -> raise "L11 observation gate expired"
    end
  _ -> :ok
end
await = fn predicate ->
  Enum.reduce_while(1..200, {:error, :observation_timeout}, fn _, _ ->
    if predicate.() do
      {:halt, :ok}
    else
      Process.sleep(25)
      {:cont, {:error, :observation_timeout}}
    end
  end)
end
{:ok, _} = Recovery.create_run(id, "观察 Heartbeat",
  script: [{:final, "heartbeat observed"}], model_timeout_ms: 15_000)
{:ok, scheduler} = Scheduler.start_link(workers: 1, run_ids: [id],
  lease_ms: 1000, renew_interval_ms: 100, poll_interval_ms: 25,
  recovery_options: [hook: hook])

try do
  executor = receive do
    {:l11_input, pid} -> pid
  after
    2000 -> raise "L11 executor did not reach gate"
  end
  :ok = await.(fn -> Scheduler.status(scheduler).counters.renewed >= 2 end)
  [first] = Scheduler.status(scheduler).active
  Process.sleep(1100)
  [current] = Scheduler.status(scheduler).active
  true = current.claim.token == first.claim.token
  true = current.claim.generation == first.claim.generation
  true = current.renewals > first.renewals
  true = current.heartbeat.sequence == current.renewals
  true = current.heartbeat.duration_ms >= 0
  true = current.heartbeat_age_ms >= 0
  true = current.heartbeat.lease_expires_at == current.claim.expires_at
  {:error, :intent_claimed} = IntentStore.claim(id, "l11-observer")
  IO.inspect(%{run_id: id, heartbeat: current.heartbeat,
    heartbeat_age_ms: current.heartbeat_age_ms}, label: "L11_HEARTBEAT")
  send(executor, :l11_continue)
  :ok = await.(fn ->
    {:ok, saved} = Recovery.load(id)
    saved.state.status == :succeeded
  end)
  {:ok, saved} = Recovery.load(id)
  1 = saved.recovery.progress.model_attempts
  1 = saved.recovery.progress.cursor
  :ok = await.(fn -> Scheduler.status(scheduler).active == [] end)
  IO.puts("L11_HEARTBEAT_SUCCESS=" <> id)
after
  if Process.alive?(scheduler), do: Scheduler.stop(scheduler)
end
```

`active` 条目增加 `heartbeat` 和 `heartbeat_age_ms`；首次续期 ACK 之前两者为 `nil`。Heartbeat 包含 `sequence`、`acknowledged_at_monotonic_ms`、`duration_ms` 和返回的 `lease_expires_at`。Sequence 记录本次 Worker 的续期 ACK；持续时间与 age 使用同一 BEAM 的 monotonic clock，可能具有负的绝对起点，不能解释成 UTC 时间或跨 BEAM 比较。所有这些诊断重启后清零，数据库当前 claim 仍是资格依据。

## 3. 准备与运行

在项目根目录的同一终端执行；另开终端时先重新执行下面两条 `export`。显式启用数据库、关闭应用级 Scheduler，避免继承内存实验或其他实验留下的配置：

```sh
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
./scripts/mix lab.fence
env -u DATABASE_URL ./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

`lab.fence` 创建新的独立实验 Run，不续跑已有事故 Run。默认输出为 `artifacts/week12-fencing`，每个场景默认 5 轮；重复参数范围是 1—20。命令只接受 `--output` 和 `--repetitions`；错误参数直接报错。输出目录已存在时拒绝覆盖；复测使用新的目录：

```sh
./scripts/mix lab.fence --output artifacts/week12-fencing-repeat --repetitions 20
```

测试前保持应用级后台 Scheduler 关闭；runner 为自己的 Run 设置明确范围。不要同时对相同 Run 启动另一份未受控调度器。数据库应保持运行；暂停 PostgreSQL 会把“Worker 失去资格”变成不同的故障，无法验证本实验的时间线。

信号只发给 runner 本次创建、保存所有权证据的子 BEAM。不要照着系统进程列表猜 PID，也不要暂停当前 IEx、共享 Scheduler、其他实验或数据库。runner 在正常完成、异常与超时的清理路径先尝试 CONT，再终止并等待自己的子进程退出，避免留下停止态进程。父进程被不可捕获的 OS kill 时，`after` 无法执行；当前没有独立 watchdog，此类事故需按已保存身份核对并人工清理，不能宣称 runner 已完成收尾。

## 4. 五个精确暂停窗口

| 场景 | 旧执行停在哪里 | 接管后重点检查 |
| --- | --- | --- |
| `model_before_accept_same_seq` | 完整模型结果尚未接受 | 同 seq 的旧模型提交被拒，新的模型录制与 cursor 不被覆盖 |
| `tool_before_effect_same_seq` | 准备台账已保存、效果尚未开始 | 原 token 无法开始目标效果；新资格仍完整 |
| `tool_after_effect_same_seq` | 效果已发生、本地 receipt 尚未确认 | 迟到 receipt 不能越过新资格；已发生效果仍可按原身份核对 |
| `tool_after_receipt_same_seq` | 本地 receipt 已确认、Kernel 尚未接受 | 旧 Kernel 更新被拒，接管者复用原 receipt，不再次产生效果 |
| `model_after_takeover_commit` | 旧模型结果尚未接受 | successor 先提交新状态；旧结果、旧 release 与旧 renewal 均不能覆盖新事实 |

每个场景先确认子进程已经真实续期，再暂停。父进程检查操作系统停止态，并读取数据库中的原资格、实际 expiry 与停顿期间状态；接管不通过改 SQL 时间字段或清空 claim 加速。恢复后要求子进程返回真实旧调用的结果，不能由测试直接填写“应当 stale”。

为稳定观察最危险的迟到调用，fixture 在精确边界保留 Worker 控制过程的 gate：CONT 后先让旧 executor 到达真实 Storage/工具校验，再放开控制过程，让 Heartbeat 观察资格丢失并清理执行器。否则恢复后的第一条续期可能先终止 executor，只能证明本地停机，无法证明迟到提交本身会被数据库拒绝。这个控制 gate 不代替 SIGSTOP；整个独立 BEAM 的操作系统暂停与恢复仍须有 PID、停止态和信号返回证据。

## 5. 把拒绝与无损恢复分别验证

记录旧 claim 的 intent ID、seq、owner、generation 和 token 摘要。接管后检查新 claim 使用同一 intent/seq，token 已更换，generation 增加；直到同 seq 旧调用完成观察前，接管者不推进该意图。新资格应仍然有效，旧续期与旧 release 都应失败。

迟到写入拒绝后，再读取 Run、Events、Recovery progress、Retry journal、模型录制与 operation/attempt/receipt。仅看到 `{:error, :stale_claim}` 不足够：还要证明 state、seq、cursor、已扣预算与 successor claim 未被覆盖；需要错误分类的调用也不能落下一半新事实。

到 successor 已提交的窗口，保存提交后的状态摘要，再恢复旧进程；旧调用结束后摘要仍相同。最终按原身份完成可继续的任务；若工具能力不足以证明结果，保留可见 blocked 核对项。工具效果数、调用次数、投递次数与已接受结果分别计数。

对文件或其他非幂等工具，准备记录加 lease 到期不能证明“未执行”。旧资格被拒只能阻止仍受本仓库门控的未来动作；已开始的外部请求或已落盘内容仍需权威证据。不要以内容相等、进程退出或新 generation 代替 receipt，也不要通过换 operation ID 自动重发。

## 6. 查看证据

正式结果以 runner 输出的 `report.json` 和 [第 12 周验收记录](../docs/validation-week12.md) 为准。每个场景保留初始、停止、接管与旧进程恢复后的快照，以及子进程日志、信号/PID/操作系统状态与汇总。二进制导出遵守原 Codec 的 inert 数据约束；不要为了读取证据改用不安全 ETF 解码。

审阅报告时逐项检查：

- STOP/CONT 作用于同一个本次拥有的子 PID，数据库与接管者未暂停；清理后没有停止态子进程残留。
- 续期确实发生过；暂停后没有新的续期提交；真实 expiry 之后才成功接管。
- 同 seq 场景的 token/generation fencing 拒绝可观测，不能仅靠 seq 冲突充数。
- 接管前后的旧 renew/release、模型资源更新、结果接受与工具确认均不能覆盖新资格。
- 已确认 receipt 可继续，幂等 Mock 效果不重复；unknown 有明确可见去向，历史仍可纯重建。

Heartbeat/Worker 诊断是当前进程的观察，不替代数据库的已提交事实。若信号命令、停止态确认、数据库读取或子进程退出任一步失败，本轮应保留失败证据并报失败，不能跳过后仍宣称通过。

## 7. 讨论与交付

1. 为什么单独暂停 executor、让 Heartbeat 持续运行，通常不会出现接管？它验证了什么，又遗漏了什么？
2. successor 在接受旧结果前已经推进 seq，为何仍需另一个同 seq 用例？
3. 为什么新 generation 不能证明原文件写入已撤销？目标服务若要自己拒绝迟到请求，需要保存并检查什么事实？
4. 续期已经提交、响应丢失时，旧内存 expiry 能否判断当前资格？如何只读核对？
5. lease 过短导致频繁接管时，调大次数或删台账为何会破坏原预算与恢复语义？

交付包括真实信号 runner、lease/heartbeat/fencing 回归测试、每轮原始证据、成功与失败都可解释的报告，以及操作手册。全部 L01—L10 测试继续作为门槛。参考推理见 [L11 解答](solutions/L11.md)。本周不把单机受控暂停扩大解释为任意网络分区、任意远端目标 fencing、全局公平性或生产接管 SLO。
