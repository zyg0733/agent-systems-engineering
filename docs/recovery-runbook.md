# 恢复运行手册

适用版本：第 12 周 P3，2026-10-21，Asia/Shanghai。适用于创建时通过 `Recovery.create_run/3` 登记的持久 Scripted Run，以及本仓库明确声明能力的工具。没有登记的旧 Run 可以只读重建、检查 unknown 队列，但不能猜测脚本、cursor、权限或预算后接管。第 11 周新增默认关闭的后台调度器；启用时，未 blocked 的合格意图及到期 retry 可以自动执行。第 12 周完善续租写入边界，并以独立 BEAM 的真实暂停验证旧代次恢复后的 fencing。

操作目标：读取已提交事实，用原业务身份继续安全的下一步，或明确交接仍未知的结果。`blocked` 是需要核对的可见状态；取消和失败也不会撤销已发生的外部效果。

下文创建新 Run 的教学演练及完整 `check` 只在自己的可丢弃实验实例执行，先按[完整回归的环境准备](command-reference.md#完整回归的环境准备)确认 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 与默认测试库。演练代码段清除父终端 `DATABASE_URL`、启用数据库并关闭全局 Scheduler；单次 `env -u` 不会修改父终端。事故的只读采证与原 Run 处置仍应指向原事故数据库，不要为了做回归切换或清理事故资源。

## 1. 先识别命令是否会执行

| 入口 | 作用 | 是否可能调用模型或工具 |
| --- | --- | --- |
| `Storage.load/1`、`Recovery.load/1` | 校验历史、投影及恢复配置/进度 | 否 |
| `CheckpointStore.rebuild/2`、`mix lab.rebuild RUN_ID` | 完整或 checkpoint 纯重建 | 否 |
| `ModelResultStore.list/1`、`RetryStore.list/1`、`DurableTools.list/1` | 读取并校验已保存审计 | 否 |
| `ReconciliationQueue.list/1`、`mix lab.reconcile` | 查看已提交的待核对队列 | 否；不查询目标 |
| `Recovery.resume/2`、`Recovery.step/2` | 领取当前意图，执行已登记策略 | 是 |
| `Scheduler.start_link/1`、启用 `LAB_SCHEDULER_ENABLED=true` | 周期领取范围内的持久意图，多 Worker 执行并续期 | 是；包括到期 retry |
| `Scheduler.status/1` | 查看进程配置、在途资格、诊断计数与最近错误 | 否；其他 Worker 可能正在执行 |
| `Scheduler.wake/1` | 异步提示后台尽快扫描 | 是；返回 `:ok` 不表示完成 |
| `IntentStore.claim_next/2` | 原子领取一个合格意图 | 不调用目标；会提交写入资格 |
| `Recovery.execute_claim/2` | 在调用者已领取的资格下执行一个步骤 | 是；由 delivery owner 负责续期与释放 |
| `Recovery.reconcile/2` | 显式查询原回执，或接受人工证据 | 可能查询；不重发未知业务 |
| `Recovery.cancel/2` | 保存取消事实，停止未来执行 | 不撤销已有效果 |
| `mix lab.recover`、`mix lab.retry`、`mix lab.p2`、`mix lab.schedule` | 创建新的独立实验 Run | 是；不续跑指定旧 Run |

为旧 Run 续跑时不要重新 `create_run`，不要更换 Run ID 或 operation ID。下文 IEx 的 `run_id` 应替换成事故记录中的原值。

## 2. 只读采证

确认使用正确数据库与代码版本，以及是否存在活动的后台 Scheduler，再进入 IEx：

```sh
./scripts/postgres status
./scripts/iex
```

先采集同一业务身份的事实：

```elixir
alias AgentSystemsLab.{CheckpointStore, Context, DurableTools, ModelResultStore,
  ReconciliationQueue, Recovery, RetryStore, Storage}
run_id = "从事故记录复制原 Run ID"
{:ok, snapshot} = Storage.load(run_id)
state_digest = Context.hash(snapshot.state)
{:ok, full} = CheckpointStore.rebuild(run_id, mode: :full)
{:ok, checkpoint} = CheckpointStore.rebuild(run_id, mode: :checkpoint)
true = full.state === checkpoint.state
{:ok, model_results} = ModelResultStore.list(run_id)
{:ok, tool_journal} = DurableTools.list(run_id)
{:ok, retry_journal} = RetryStore.list(run_id)
queue = ReconciliationQueue.get(run_id)
recovery = Recovery.load(run_id)
```

这些读取分别校验各自的事务快照。若另一个 worker 正在推进，连续 API 调用可能观察到不同 seq；重新加载并按 seq 对齐，不能把它误报成同一快照的不一致。需要稳定人工审阅时先按第 9 节停止相关后台领取；`status` 本身不会暂停工作。采集后保留时间、代码版本、数据库标识和完整错误返回。`Context.hash` 是完整性比较，不能充当签名或外部业务回执。

`checkpoint.audit.mode` 在无 checkpoint 时为 `:full`，表示明确回退到完整重建；已有最新 checkpoint 损坏则报错，不会偷偷挑旧行。当前实现始终校验原始前缀，不承诺 checkpoint 加速。

检查恢复配置：

```elixir
case recovery do
  {:ok, saved} ->
    %{seq: saved.state.seq, status: saved.state.status,
      progress: saved.recovery.progress, current_retry: saved.recovery.retry,
      pending_operation_id: saved.state.pending_operation_id}
  {:error, :run_not_resumable} ->
    :legacy_run_requires_explicit_review
  {:error, reason} ->
    {:stop_and_preserve_error, reason}
end
```

采集项应包括：

- Run ID、status、seq、pending operation、完整原始 Events、投影摘要。
- 当前 intent ID/seq/status、available_at 提示、Run priority、claim owner/generation/expiry；token 属于写入凭证，只在受控证据中保存。
- Recovery 配置及其版本/hash；cursor、model attempts、output bytes、request token 与两个绝对 deadline。
- 当前及历史 Retry journal 的 scope、attempts、first attempt、due、classification、deliveries 与 exhaustion reason。
- 原 operation 的 tool、精确参数、receipt，以及每次 execution/lookup/observation/manual attempt 与 evidence。
- 模型录制与 Context 来源、checkpoint 身份和 seq、队列 safe_mode/recoverable/unknown 原因。

`DurableTools.stats/1` 是本地教学诊断。统计为 0 不证明真实外部没有效果，统计为 1 也不能替代不可查询工具缺少的权威回执。Queue 的 `safe_mode: :queryable` 当前仅对应配置为幂等的持久 Mock；它不赋予任意工具相同能力。

采集敏感输入时沿用项目的数据处理约束，分享故障报告只放需要的摘要，保留原始证据的位置与 hash。不要用不安全 ETF 解码、随意加载新 atom 或修改历史来让读取“通过”。

## 3. 决定下一步

| 观察 | 动作 | 处理依据 |
| --- | --- | --- |
| `succeeded` / `failed` / `cancelled` | 校验终态与业务回执，结束或交接 | `resume` 对终态只返回快照；不重开任务 |
| `running` / `waiting_tool`，当前 owner 有效 | 停止第二份执行；联系 owner 或等 lease 自然到期 | lease 到期改变领取资格，不说明效果未发生 |
| retry 为 `waiting` 且 due 未到 | 保存原 due；后台启用时等扫描，否则到期后显式续跑 | 不持有 lease 睡眠；不重算 due |
| 可恢复、执行资格有效、没有 blocked | `Recovery.resume` 原 Run ID | 原配置、资源和当前意图决定下一步 |
| blocked，queryable | 先检查本地确认回执，再显式 `reconcile` 查询 | 复用已确认 receipt，或按原身份查目标 |
| blocked，manual | 保留队列，收集可信外部证据，再人工核对 | 不能从 timeout、缺少 ACK 或内容相等断言成功/失败 |
| 自动核对次数/窗口耗尽 | 保持 blocked，人工交接 | 额度耗尽不产生回执，也不授权业务重发 |
| 执行 Run deadline 已过 | 可以核对既有模糊效果；禁止新模型/工具执行 | 查询有独立有限窗口，执行期限不会恢复 |
| `run_not_resumable` | 只读采证；按旧路径审阅 | 不能补造登记配置、游标、预算或权限 |
| 版本不兼容、hash/来源/投影损坏 | 保留错误，停止执行并交给数据/版本调查 | fail closed；不能删坏行或绕过 Codec |
| 数据库无法读取或提交结果不明 | 等待持久事实可读，再对齐 seq 和回执 | 连接错误不代表没有 COMMIT，也不代表外部未执行 |

## 4. 安全续跑已有 Run

先完成只读检查，确认没有有效的并发 owner，再显式继续原 Run：

```elixir
{:ok, before_resume} = Recovery.load(run_id)
result = Recovery.resume(run_id, owner: "operator-ticket-123", max_steps: 20)
```

`max_steps` 是本次调用的工作上限，不修改原持久预算。`resume` 到终态、blocked 或未来 due 时返回 `{:ok, snapshot}`；这不自动代表业务成功。步数耗尽返回 `{:error, :step_limit}`，可读事实不回滚。每次调用后重新读取状态再决定下一步。

due 前 `resume` 快速返回原等待快照，`step` 返回 `{:error, {:retry_not_due, due}}`。操作人可以在 IEx 外等到 due 后再调用；启用了相应范围的 Scheduler 时则由后续扫描自动领取。Runtime 不为退避持有 lease。Run 超时、模型全局尝试上限、输出字节和工具调用预算均继承原值，不调整配置“救活”任务。

遇到有效 owner，返回 `{:error, :intent_claimed}`。遇到 `stale_claim`、`claim_expired` 或序号冲突，丢弃旧写入资格并重新采证。不要把这些错误吞掉后继续使用旧结果或释放新 owner 的 claim。原 caller 可能只丢失 ACK；读取已提交记录才能判断是否已经完成。

如果接管时原 Run deadline 已过，执行器不会启动新效果。待执行工具没有任何准备台账时直接保存超时失败；已有 `completed` 回执时先接受原工具事实，后续模型仍按原期限失败；已有 prepared/unknown 投递但结果未确认时，归档 unknown 并保留 blocked 核对项。超时不能把可能发生的效果从人工交接中移除，也不能让已确认回执失去可追溯性。

## 5. unknown 的显式查询

只读查看当前条目：

```sh
./scripts/mix lab.reconcile --run RUN_ID --json
```

`reconcile` 首先消费已经确认的本地 receipt；这一步不需要重新执行目标，也不因目标不可查询或查询配额耗尽而丢弃已知事实。没有本地确认回执时，queryable Mock 才使用原 operation 身份进行有限查询。manual 工具仍需可信证据。

```elixir
{:ok, entry} = ReconciliationQueue.get(run_id)
result = Recovery.reconcile(run_id, owner: "operator-ticket-123")
{:ok, observed} = Recovery.load(run_id)
```

可能返回：

- `{:ok, snapshot}`：核对事实已接受；重新检查 status、seq、队列与 receipt。
- `{:error, {:retry_not_due, due}}`：原查询退避尚未到期，或本次暂时查询失败已安排 due；不热循环。
- `{:error, :reconciliation_required}`：仍无法权威确认，保留 blocked 并交接。
- `{:error, :not_blocked}`：状态已改变，重新采集，不能继续套用旧核对决定。

核对成功后，没有相应后台调度器时再显式 `Recovery.resume(run_id)` 执行下一步；后台范围包含此 Run 时，新的可执行意图可以被自动领取。需要核对后再次人工审阅的事故流程，应先停止相关后台领取。如果原执行 deadline 已过，后续步骤会按原停止规则结束；核对不会重新分配执行时间。`ReconciliationQueue.get/1` 在离队后返回 `{:error, :not_in_reconciliation_queue}`，历史中的 unknown 和核对证据仍保留。

## 6. 人工证据与预期序号

只有独立业务账本、明确的目标回执或可信操作员调查，才能支持人工 `:ok` / `:error`。记录工单、操作员、核对时间、原 Run/operation/tool、精确参数、外部回执位置和判断依据。不要只写“已检查”。证据是操作员的审计声明，程序不能验证其现实真实性。

低并发教学演练可以通过 `Recovery.reconcile(id, result: ..., evidence: ...)` 自动绑定当前配对。事故处理中，人的判断可能在另一个 worker 推进后过期，宜显式固定审阅的 seq 与 operation，再取得短期 claim。以下 helper 只定义操作流程；调用前必须提供已经核实的结果和证据：

```elixir
alias AgentSystemsLab.{DurableTools, IntentStore, Recovery, Storage}
alias AgentSystemsLab.Tools.Result

confirm_reviewed = fn id, expected_seq, reviewed_operation, verified_result, evidence ->
  with {:ok, claim} <- IntentStore.claim(id, "operator-ticket-123", lease_ms: 30_000) do
    try do
      with true <- claim.seq === expected_seq || {:error, :review_required},
           {:ok, current} <- Recovery.load(id),
           true <- current.state.status === :blocked || {:error, :review_required},
           actual = Map.fetch!(current.state.operations, current.state.pending_operation_id),
           true <- actual === reviewed_operation || {:error, :review_required},
           paired = Result.wrap(verified_result, actual.operation_id, actual.tool),
           config = current.recovery.config,
           {:ok, receipt} <- DurableTools.confirm(claim, actual, paired, evidence,
             workspace: config.workspace, mock_mode: config.mock_mode,
             mock_response: config.mock_response),
           {:ok, _} <- Storage.dispatch(id, expected_seq,
             {:reconcile, actual.operation_id, receipt}, claim: claim) do
        Recovery.load(id)
      end
    after
      IntentStore.release(claim)
    end
  end
end
```

`reviewed_operation` 取自只读审阅快照，`verified_result` 为 `{:ok, payload}` 或 `{:error, payload}`。不要把 `{:unknown, ...}` 当作人工最终确认。`review_required` 表示审阅前提已变，必须重新采证；不自动改用当前 seq 重试。`IntentStore.release/1` 在成功转换后可能返回 stale，因为旧意图已经被消费；它不会释放 successor 的 claim。

人工证据需 1—8192 字节有效 UTF-8、非空白且不含 NUL；缺失返回 `:invalid_reconciliation_evidence`，结果配对不正确会被拒绝。相同 operation 更换参数返回冲突，不能生成新 operation 绕过去重。人工确认不会赋予后续自动重投权限。

若人工 receipt 已确认、Kernel reconciliation 尚未 COMMIT 就再次崩溃，先重读本地 journal；随后显式 `Recovery.reconcile` 复用原确认 receipt。不要再次提交不同人工结论，也不要删除 `completed` 记录。若接受事务已经 COMMIT，则只读状态已前进，后续按新意图继续。

## 7. 恢复中再次崩溃

把恢复者当作普通 worker 处理：记录其原 Run、claim、故障阶段和最后已提交证据，确认进程是否已经退出。尚未退出且 lease 已到期时，也不能假设外部不会迟到；外部效果仍依赖工具自身的稳定身份与能力契约。

按相同流程重新采证、等待 lease 资格、用原 Run 接管。不要用旧 owner 内存里的 response 覆盖新事实。两次失联之间新增的 attempts、已确认 receipt、已扣资源和 due 都应保留。第三个 worker 的结果必须能从这些记录解释，而非依赖前两个进程还活着。

本周 P2 演练包含工具效果后恢复者再次失联，以及人工核对 receipt 后失联。实际 gate、重复轮次和结果见 [P2 故障报告](p2-fault-report.md)，相关实验为 [L09](../labs/L09-p2-fault-acceptance.md)。

## 8. 关闭事故与交接

完成或交接前再次读取并保存：

1. Run status/seq、完整与 checkpoint 重建一致、当前意图与恢复进度对齐。
2. 原 operation 与参数不变、目标权威回执或人工证据可追溯，attempt 历史保留。
3. 模型录制只对应已接受的完整响应；cursor、累计预算、retry 次数与期限没有被重置。
4. 队列正确离项，或仍 blocked 并明确负责人、未知原因及下一次核对条件。
5. 旧 token 的迟到提交没有改变终态或覆盖新事实。

若任务已经终态，不通过创建同业务新 Run 猜测补偿。补偿是新的业务决策，需要单独的明确意图与授权。取消只改变未来动作，已写文件与业务效果仍需独立处理。

## 9. 后台调度启停与事故隔离

默认 `LAB_SCHEDULER_ENABLED=false`。手动 `Scheduler.start_link(run_ids: [...])` 只处理明确范围，ID 列表须非空；`run_ids: []` 会被拒绝。省略 `run_ids` 才处理全库合格意图。应用级启用应在迁移完成后启动：

```sh
./scripts/mix setup
LAB_SCHEDULER_ENABLED=true ./scripts/iex
```

当前应用配置是命名 Scheduler、2 个 Worker、100 ms 扫描、5000 ms lease 和 1000 ms 续期。库级 `start_link/1` 的默认并发为 4，默认 lease 为 30 秒；以实际 `Scheduler.status` 为准。数据库关闭却启用 Scheduler 会拒绝启动，不会退回内存队列。

查看应用监督的实例：

```elixir
alias AgentSystemsLab.Scheduler
view = Scheduler.status(AgentSystemsLab.Scheduler)
```

`view.active` 包含 Worker、执行 Recovery 的 executor、claim 与本次续期数。`counters`、最多 20 条 `errors` 是本进程诊断，重启会清零；`completed` 表示步骤正常返回，不能解释成 Run 成功数量。错误中可能包含数据库或校验原因，保留原始日志和持久 journal 再判断。发现坏候选时会记录拒绝，健康候选可继续；若范围内仅剩坏候选，claim-next 返回拒绝集合。坏记录不会因为重复扫描而获得执行权限。

独立手动实例使用 `Scheduler.stop(pid)` 停止。应用监督的 Scheduler 是永久子进程，单独 `Scheduler.stop(AgentSystemsLab.Scheduler)` 会被 supervisor 重启；需要人工冻结领取时使用明确的监督操作：

```elixir
:ok = Supervisor.terminate_child(AgentSystemsLab.Supervisor, AgentSystemsLab.Scheduler)
nil = Process.whereis(AgentSystemsLab.Scheduler)
```

正常停止会先终止并等待本地 executor 退出，再尝试释放本次仍有效的 claim；已消费、过期或被替换的资格不能释放 successor。异常 kill 可能留下有效 lease，等 PostgreSQL 的原到期时间再接管。无论采用哪种停机，本地退出都不证明真实远端效果已经撤销。尚未确认的 operation 仍按原台账和 unknown 规则处理，不能删除准备记录。

确认审阅与操作完成后，按同一个应用配置恢复扫描：

```elixir
{:ok, _pid} = Supervisor.restart_child(AgentSystemsLab.Supervisor, AgentSystemsLab.Scheduler)
```

仅修改 `Application.put_env` 不会停止已经启动的进程。需要改变领取范围或并发时，应先明确停止旧实例，再以新配置启动；不要把第二份 Scheduler 的出现误认为替换。多个实例共享数据库资格，但各自的 Worker 上限相加，不是全库配额。

优先级 0—9 在 Run 创建时固定，值大者先考虑，同级按意图 ID 排序。`SKIP LOCKED` 允许先处理其他未锁 Run，实际完成顺序不保证 FIFO。已有执行不被抢占，优先级也不能绕过租约、原 retry due、权限或资源。`available_at` 是观察提示；当前 SQL 不用它硬过滤候选，扫描在 Run 锁下读取权威 Retry，旧 NULL、提前或延后提示不改变真实资格。不要通过编辑 hint、priority、claim 或 journal 临时加速事故恢复。

blocked/reconcile 始终排除自动业务领取，操作员仍按第 5—6 节显式查询或提交可信证据。周期扫描和 wake 只提供自动发现，不承诺生产网络分区接管、全局公平/背压或任意外部 exactly-once。数据库不可用、版本损坏及真实目标查询不明时，保存不确定性并交接，等待可验证的持久事实。实验与验收见 [L10](../labs/L10-background-scheduling.md) 和 [第 11 周验收记录](validation-week11.md)。

## 10. 旧 Worker 暂停、接管与恢复

第 12 周增加真实 SIGSTOP/SIGCONT 故障验证；适用行为与证据见 [L11](../labs/L11-leases-heartbeats-fencing.md) 和 [第 12 周验收记录](validation-week12.md)。Lease 决定何时可以另行领取，Heartbeat 尝试延长当前资格，fencing 拒绝失去资格后的本地写入。任一机制都不证明外部效果已经停止或回滚。

发现长时间无进展时，先按第 2 节采集原 Run/operation/intent、当前 token 摘要、generation、数据库 expiry、原预算与 retry due，以及 Scheduler 的在途诊断与续期错误。只暂停 executor 可能仍有独立续期；操作系统停止态也不等于进程退出。不要从日志的最后时间或进程列表直接推导可以重发业务。

恢复步骤：

1. 明确事故范围并隔离不相关的后台领取；保留原始状态和旧进程身份，不清空 claim 或删除准备台账。
2. 数据库保持可读，等待当前 lease 的真实自然 expiry。连接不可用或 COMMIT 不明时先停止判断；不修改时间字段、owner、token、generation 或 due 来强行接管。
3. 用原 Run 和原 operation 经既有领取接口取得新资格。新 token/generation 才是当前凭证；同 seq 也不能复用旧资格。
4. 新 owner 重新读取已提交的结果、资源、Retry 与工具台账。receipt 已确认则复用；可安全查询的模糊效果按原身份核对；文件或不可查询工具保留 blocked/manual。到期本身不授权重发。
5. 旧 Worker 恢复后，其迟到结果、续期、release 和 receipt 更新须失败；重新读取状态确认 successor 与已提交结果未被覆盖。遇到 `stale_claim`、`claim_expired`、seq 冲突或 `lease_lost`，弃用旧资格，不能改字段重试。
6. 结束时按第 8 节对齐完整历史、checkpoint、模型录制、原预算与操作回执。记录真实效果和 unknown 去向，确认本地残留执行者已清理；外部已发送请求继续按目标契约核对。

调度器的 `status` 与错误记录是当前进程诊断，重启会清零。Heartbeat 成功可能发生在本地看见 ACK 之前，业务提交也可能在续期者下一次观察之前消费 intent；最终以数据库读取为准。`lease_lost` 是执行资格丢失，不自动代表 Run 失败或业务效果不存在。

在途项的 `heartbeat` 包含 `sequence`、`acknowledged_at_monotonic_ms`、`duration_ms` 与 `lease_expires_at`，`heartbeat_age_ms` 表示当前 BEAM 距离最近 ACK 的观察时长；首次 ACK 以前两项诊断为 nil。Monotonic 时间不能当作 UTC 或跨 BEAM 比较。诊断用于发现延迟，确认有效资格仍须读数据库；timer reference 只抑制陈旧本地 tick，不能替代持久 token。

续期已通过初次校验后也可能暂停。UPDATE 在写入时再次检查原 lease 尚未到期，再计算新 expiry；恢复时已过期则 `:claim_expired`，不能通过传入更大的 `lease_ms` 复活旧 token。此时按原资格失效处理，重新采证并等待/领取新代次，不修改旧 claim 重试。

真实暂停实验统一使用创建新 Run 的 runner，避免人工信号误伤共享进程：

```sh
./scripts/mix lab.fence --output artifacts/week12-fencing-incident-drill --repetitions 5
```

Runner 只给自己本次创建并核验身份的子 BEAM 发信号，数据库与接管进程持续运行。清理时先 CONT，再终止并等待自己的子进程；不要对事故中身份不明的进程照抄 PID。若无法确认控制目标或清理结果，保留证据并交给环境负责人，不将本轮报告成通过。

本周验证受控效果前的本地授权和数据库写入 fencing。一个独立远端服务要拒绝旧代次请求，仍需目标自身支持相应 fencing 或稳定幂等/查询协议；文件内容相等与数据库 lease 变化均不能代替这种证据。网络分区、真实数据库断连、背压、公平性与生产 SLO 仍各有独立验收范围。

## 11. 背压、任务预算与饥饿告警

第 13 周为显式命名队列增加持久准入、跨消费者有效 lease 配额、每任务调度预算与单次执行 watchdog。前序未指定队列的 Run 保持原行为；第 9—10 节中的周次范围声明继续说明当时的验收边界。新接口与负载实验见 [L12](../labs/L12-backpressure-budgets-fairness.md)、[ADR 0012](adr/0012-backpressure-and-fairness.md) 和 [第 13 周验收记录](validation-week13.md)。

### 先采集队列与本地执行事实

在原应用配置的 IEx 中，使用事故中已经保存的队列名和 Scheduler 身份，不创建替代队列或新 Run：

```elixir
alias AgentSystemsLab.{QueueStore, Scheduler}
{:ok, queue} = QueueStore.stats(queue_name)
{:ok, starved} = QueueStore.starvation(queue_name, limit: 100)
IO.inspect(queue, label: "QUEUE")
IO.inspect(starved, label: "STARVATION")
IO.inspect(Scheduler.status(scheduler), label: "SCHEDULER")
```

`QueueStore` 两个观察接口使用只读一致快照，不领取、续期或执行模型/工具。分别采样会有不同观察时间；Scheduler 的 status 属于当前进程诊断，不能当作与数据库同一事务的快照。

`active` 是该队列未终结 Run 数，含 `blocked`；`available_slots` 是剩余准入名额。`live_leases`/`claimed` 是数据库中的有效资格，`inflight_slots` 是剩余共享资格名额。`ready`、`waiting_retry`、`blocked` 与 `invalid_candidates` 帮助解释“有积压但没有执行”：前者才适合继续检查调度发现，未来 retry 须等原 due，blocked 须走核对流程，损坏候选须先保留原证据排查。capacity 限未完成工作，终态保留的事件、operation、receipt 等历史不计入这个容量。

`oldest_ready_wait_ms` 与饥饿条目的 `wait_ms` 从当前 intent 的数据库创建时间计算，观察时仅纳入 ready 候选；它不是累计 eligible 时长。刚到 retry due 的旧 intent 可能立即超过 starvation 阈值，应结合 due、最近领取与完成记录解释。有效优先级是 `min(9, priority + floor(wait_ms / aging_ms))`；有界候选页内比较该分数与 intent ID，持久游标继续向后扫描，不能期待全队列每次严格最高分顺序。

确认 Scheduler 的 `queue` 与事故队列相同；省略 queue 的实例只扫描未入队 Run，单独设置 run_ids 不能改变这一范围。命名队列 scan_limit 默认 32、范围 1—256，限制一次领取页；未入队 legacy 扫描沿用前序完整扫描。Scheduler 的 wake_requests、wake_pending、message_queue_len 解释本地提示和邮箱，不能替代原 intent、due 或提交事实。

### 满载与饥饿的处置

收到 `:queue_full` 时让生产者停止继续提交，保留原输入并采用有界等待或退避。拒绝创建没有留下 Run/Event/intent，使用原请求 ID 重试仍需调用原准入接口；不能绕过 queue 参数或改走无界内存列表来隐藏积压。已接受 Run 使用原身份继续恢复，不能为了补提交而再创建一份相同业务。

`blocked` 长期占位是未完成结果的真实信号，按第 5—6 节核对；不要删除准备台账或将任务标成成功来空出 capacity。终态会自然空出准入名额，历史保留与清理由独立策略决定。队列配置创建后固定；扩容或迁移要有单独实施与审阅，不能直接改数据库 limit、priority、scan cursor、claim 或 retry due。

有 ready 饥饿项时，记录 `observed_at_ms`、原 intent ID、seq、priority/effective_priority、wait_ms，再核对所有消费者的队列范围、共享 quota、active、heartbeat、回收与错误。检查是否持续提供服务、是否受 Run 锁或数据库延迟影响、是否被未到期前缀遮挡，以及扫描游标是否推进。饥饿条目是可见告警，不授权操作员重发工具、提高预算或覆盖原资格。老化与轮转在声明负载中提供机会；无限输入、长锁和环境故障下没有完成期限保证。

### 任务超时与预算耗尽

命名队列任务自动保存 `task_budget`，默认 `max_dispatches: 32`、`execution_timeout_ms: 5000`，可以在 Run 创建时显式设置固定政策。调度机会在执行前持久扣除，Worker、Scheduler 或 BEAM 重启不能清零；输出字节、stream event、tool call、turn、绝对 Run deadline 与 retry 限额仍独立生效。不要通过新建同业务 Run、改 budget 或清除计数绕过耗尽。

只读 `AgentSystemsLab.TaskBudgetStore.load(id)` 返回固定 config 和 progress，后者包含 `dispatches`、`last_claim_token`、`last_seq` 与 `execution_deadline_at_ms`；没有启用时为 `{:ok, nil}`。调度预算耗尽理由为 `{:budget_exceeded, :dispatches}`，单次执行回收理由为 `{:budget_exceeded, :execution_timeout}`。Scheduler 的执行上限默认 30000ms，任务固定上限及原 Run 绝对 deadline 进一步取更早者。

watchdog 超时后先停止并等待本次 executor 退出，再以当前 claim 读取提交事实并回收。已确认 receipt 应继续使用；prepare 后无法证明结果的工具保持 blocked 核对路径，没有工具台账的未完成执行明确 failed。不能因 executor 已退出就宣称“没有发生”；预算耗尽也不取消核对已经发生结果的入口。数据库不可用或 COMMIT 不明时按第 7 节保存不确定性，重新读取后再判断。旧资格失效的回收调用同样受 fencing 约束，不能越过 successor。

观察本地 Worker 上限和数据库有效 lease 时分别记录。跨 Scheduler 的同队列有效资格受共享 max_inflight 限制，各实例 max_workers 约束自己尚未结束的 Worker。到期旧进程可能暂时仍存在，正在清理的执行者也不能提前当作已空出的本地槽位。重启 Scheduler 不能证明旧远端请求消失。

负载演练使用创建新队列和新 Run 的 `./scripts/mix lab.load --output artifacts/week13-load-incident-drill --jobs 12`，不对事故任务直接施压。它保留拒绝、等待、服务顺序和进程高水位的独立证据。本周预算与 watchdog 覆盖项目受控执行路径，不提供 OS 资源沙箱、任意远端 exactly-once、生产吞吐/延迟 SLO；第 14 周新增的受控数据库断连恢复见第 12 节。


## 12. 数据库断连与恢复

数据库错误首先表示未获得可靠确认，不能直接解释为业务失败或事务回滚。先停止输入扩张，保留原 Run、seq、operation、claim 与已有回执；按原业务身份核对，不新建同业务 Run“补发”。本节对应单 PostgreSQL 的可恢复客户端连接故障，实验不停止共享数据库。

### 先保留不依赖数据库的控制面

在原应用 IEx 中，对已知事故 Scheduler 查询：

```elixir
status = AgentSystemsLab.Scheduler.status(scheduler)
IO.inspect(Map.take(status, [:database, :pending_claim, :active, :counters, :errors,
  :database_timeout_ms, :execution_timeout_ms, :message_queue_len]), label: "DATABASE_INCIDENT")
```

status 只读本地进程状态，不为这个调用再发 SQL。database.state 是最近基础设施探测的诊断；consecutive_failures、retry_in_ms、last_error 解释退避，pending_claim 显示唯一在途领取 helper。active 中的 claim/heartbeat 仍是观察值，不能替代数据库当前资格。一次查询恢复不证明所有连接都健康。

每个 Scheduler 最多一个领取 helper，每个 Worker 最多一个续租或清理 helper，策略读取在 executor 中完成。默认 database_timeout_ms 为 1000，初始 database_backoff_ms 为 100，max_database_backoff_ms 为 5000；范围分别为 10—60000、1—60000、初始值—60000ms。连续失败采用有上限的指数退避；wake 不绕过尚未结束的退避。错误记录只保留最近 20 条，不能把这份窗口当作完整事故审计。

这些运行控制不重置原模型尝试、输出字节、dispatch、Run deadline 或业务 retry。数据库异常若发生在 Provider 帧扣账、工具 receipt 或核对查询内，同样不能冒充 provider/tool 确定失败并安排一次业务 retry。故障前已合法预留和扣除的资源继续保留，恢复中的新执行机会仍按原预算计费。

### 区分三种不确定性

| 窗口 | 应保留的事实 | 恢复动作 |
| --- | --- | --- |
| 创建或转换提交前断连 | 可能回滚的本次事务与之前独立确认的预算/事件分开 | 重连后读取原 ID，检查完整历史与当前 seq；不能从 error 推断所有事实都不存在 |
| COMMIT 已执行但 ACK 丢失 | 数据库可能已经提交 Run、Event、下一 intent 或 claim | 重新读取原事实，已提交结果直接接受；没有确认的 claim 不启动 executor |
| 工具效果后断连 | prepare、稳定 operation 与可能已发生的目标效果 | 复用已确认 receipt；否则按工具能力查询或进入 blocked/manual，禁止盲目重发 |

领取回报未知时，本地 helper 停止不证明数据库回滚。已提交 lease 仍占队列配额，到期前不得凭空创造资格。续租回报未知时，Worker 先停止并等待 executor，再停止该 helper；不依据旧内存 expiry 主动释放不确定资格。后继等待数据库中实际 lease 到期并获得新 token/generation，旧调用仍由提交门校验。

若业务结果已经收到成功确认，而一条同时在途的 heartbeat 随后返回陈旧资格，不能把已确认的业务结果改写成失败。执行器与续租结果竞争时，Worker 会等有期限的在途续租结束；本地槽位不提前归还。

### 恢复连接后继续原任务

先确认原数据库身份、连接配置和服务已经恢复。生产现场使用自己的服务运行手册；本项目的 `./scripts/postgres start/status` 只管理专用开发实例，不能拿它代替远程数据库处置。不要为演练停止共享服务或终止全库 backend。

基础设施恢复后，原 Scheduler 会在退避结束后自动重新扫描，不需要通过反复 wake 或重启制造探测流量。再次读取 status，确认 state 回到 available、失败计数清零，并结合原 Run 的完整 Storage/Recovery 事实检查前进。若原 Run 总 deadline 已经过期，按原超时协议归档，恢复连接不会给它新期限。

对已有事故 ID 使用只读入口：

```elixir
AgentSystemsLab.Recovery.load(run_id)
AgentSystemsLab.DurableTools.list(run_id)
AgentSystemsLab.TaskBudgetStore.load(run_id)
AgentSystemsLab.ReconciliationQueue.get(run_id)
```

数据库仍不可用时这些调用可能返回错误或驱动异常，应保留真实错误，不能用本地缓存填造提交状态。不要同时手动 resume 和让未隔离的后台消费者争抢同一事故任务；确需手工接管时先按第 9 节限定消费者范围，再使用原 ID 和完整 fencing 协议。

对 blocked 任务，遵循第 5—6 节的查询/人工证据入口。人工核对只能确认原效果，不能创建新 operation、删除准备记录、重置尝试次数或放宽原权限。确认回执与 Kernel 接受结果仍是两个提交边界，异常后继续读取原 receipt，避免重复查询或重发。

### 演练、证据与阶段关闭

```sh
./scripts/mix lab.database --output artifacts/week14-database-incident-drill --repetitions 2
./scripts/mix lab.p3 --output artifacts/week14-p3-incident-drill --repetitions 2
```

使用新目录，保持全局 Scheduler 关闭；两个命令创建自己的 Run，不注入真实事故任务。数据库演练使用独立子 BEAM 和专用 loopback pgwire 代理，只断开它拥有的连接。五个 case 分别是 before_commit_rollback、commit_ack_lost、heartbeat_disconnect、tool_effect_pending_disconnect、auto_poll_reconnect。COMMIT ACK 探针实际看到后端 CommandComplete 后才截断回报；before_commit 在行锁内 gate 时用原始 MVCC 只读行快照核对，不让审计本身等待相同 Run 锁。

逐次目录保留初始/断连/恢复事实、代理事件、旧新连接 backend ID、真实调用错误、旧 claim 拒绝、PID/nonce 与子进程清理。auto_poll_reconnect 以原 Scheduler PID 自动继续；工具窗口先保留 unknown/manual 证据，再依据父审计显式确认效果一次。它不代表该工具向 Worker 提供了自动查询能力。

P3 实际重跑 scheduling/fencing/load/database，保存每项门槛及原子更新的阶段报告；失败组件与已完成证据保留。全部符合实验预期与全部 Run 成功分别统计：manual blocked 和预算耗尽 failed 不能被改成成功来凑通过率。另由单个独立 BEAM 重建全部本轮 Run，所有模型/工具/执行入口计数须全部为零，再复核原持久事实不变。第 16 周补上新 Gateway/MCP 入口后现为 27 个；W15/W14 原始历史证据仍按当时 23/20 个保存。

正常与异常路径会清理自己的代理和子 BEAM 并等待实际退出；父进程被不可捕获的 OS kill 时仍没有独立外部 watchdog。现场遗留进程只按已保存 PID、nonce、Port/进程身份核验清理，不能按模糊名字批量 kill。保留原始报告后才能关闭事故；调度器“活着”或连接池“已重连”都不等于业务结果已经核对。

源码对照、选择保留教学引擎的依据，以及将来 Oban adapter 的单一调度权威要求见 [S6](research/oban-scheduling-recovery.md) 与 [ADR 0013](adr/0013-queue-engine-selection-and-database-recovery.md)。本次结论不覆盖 PostgreSQL 节点宕机/复制切换、介质损坏、任意 SQL/代理兼容或任意远端 exactly-once；发布前的重复次数、独立试读和平台验收仍单独追踪。

## 13. 隔离执行与清理

### 开启前固定宿主权限

`sandbox_exec` 默认关闭。由可信宿主调用 `Isolation.Policy.new/1`，配置真实私人目录、位于可写目录之外的绝对可执行文件白名单、`network: :deny` 与有限资源，再通过 `RunServer` 或 `Recovery.create_run/3` 的 `isolation_policy:` 登记。完整可运行示例见 [L14](../labs/L14-isolated-execution.md)。模型的工具参数只有 `command` 与 `args`，额外的 workspace、environment、profile、timeout 或 network 字段会被拒绝。不要把来自消息、摘要或工具输出的文字当成宿主授权。

策略不提供 PATH 搜索、隐式 shell、网络放行或任意原生选项。工作目录和祖先不得为符号链接，拒绝 home/系统根、大小写别名、受保护元数据路径与执行器所在目录。命令必须是独立、非 setuid/setgid 的普通可执行文件。启动前最多检查 10000 个 workspace 条目，拒绝已有普通文件硬链接；运行时禁止创建硬链接。符号链接仍由内核根据实际目标限制。宿主需要保持根目录与命令文件可信；这不是抵抗另一恶意宿主进程同时替换目录的 inode 固定协议。

持久策略在创建事务中作为带 hash 的 sidecar 保存，原 v1 配置兼容；读取、领取与工具运行都校验其版本和内容。`Recovery.load(id).recovery.isolation_policy` 的含义是使用 `{:ok, snapshot}` 中的字段，不是提供修改入口。不要改数据库的 policy/hash 来重试被拒绝命令；改变权限应经过新的宿主评审和新实验身份，保留旧操作证据。

### 支持范围和资源口径

本周验证的后端为 Darwin arm64 上的 `seatbelt.v1`。`Isolation.capabilities/0` 的 available 只表示本机具备候选设施，`enforcement_verified: false` 明确不以文件存在冒充实测；必须执行探针才能证明当前环境应用了 profile。自定义 Seatbelt / sandbox_init 已弃用，不作为生产、多租户或可移植安全承诺。Linux 尚无执行后端；不支持或初始化失败时直接报错，没有普通宿主执行回退。

| 限制 | 默认 | 实际执行方式与范围 |
| --- | ---: | --- |
| `wall_time_ms` | 5000ms | guardian 的单调时钟与原生 timer，超时 kill 自有目标；不依赖 BEAM 继续接收消息 |
| `cpu_seconds` | 2s | 目标硬 `RLIMIT_CPU`；CPU 计时与墙钟分别记录 |
| `max_file_bytes` | 1048576B | 硬 `RLIMIT_FSIZE`，针对单文件，不是总 workspace 占用 |
| `max_output_bytes` | 65536B | 捕获返回值上限；观察超出即终止，终止前及管道中残留的字节仍计入观察值，不能用它代替返回值上限 |
| `max_processes` | 1 | 内核拒绝 fork/posix_spawn；计一个目标，另有可信 guardian 与 BEAM 控制器 |
| 固定 FD | 64 | 硬 `RLIMIT_NOFILE`，包含 stdin/stdout/stderr；继承的其它 FD 在 exec 前关闭 |
| 网络 | deny | 默认拒绝全部网络；有效 loopback 服务也不能连接 |

硬内存配额、总磁盘配额、允许网络白名单和任意目标后代均未实现，不能把 CPU/单文件/FD 限制换算为这些能力。内核上限在目标运行时生效；OS 暂停 guardian、系统调度停滞或不可中断内核操作下没有实时清理承诺。输出通道写入有界等待，原生 timer 仍可终止目标；若控制协议缺失，执行返回错误，不伪造清理成功。

### 解释结果与恢复状态

`Isolation.execute/4` 的外层 `{:ok, result}` 表示拿到了完整执行和清理报告；程序成功与否读取 `result.status`。值包括 succeeded、failed、timed_out、output_limit、resource_limit、cancelled。非零退出不是目标未产生效果的证明。外层 error 表示启动拒绝、后端/协议或清理未确认，保留原错误与 prepared 记录再判断。

报告包括有限 output、exit_status/signal、CPU/墙钟耗时、guardian/target 的本次 OS PID，以及 cleanup 的 target_exited、guardian_exited、process_group_gone。trusted 控制帧通过独立管道送入 Runtime，目标 stdout 只能作为输出数据；不接受输出中自称“已清理”的 JSON。PID 本身可复用，事后处置还要结合报告的 nonce、来源、时间和当前身份。

DurableTools 先提交 prepared，再在短事务中复验当前 claim、原策略、Run/任务/retry 期限和数据库时钟。此次 wall 上限取全部期限与观测 lease expiry 的最小值；setup 后、Port 启动前再扣除实际过去的时间。没有确认的 SQL 授权或已经过期的额度不启动目标。运行不持有 SQL 锁，结果回执另以 token/generation/seq 校验提交。授权 COMMIT 与 OS exec 不能原子化；两者之间的取消仍可能出现受限 workspace 副作用，但迟到结果不能覆盖取消或新状态。

RunServer 的隔离工具在独立 Task 执行，状态读取、取消和 Run 总超时可响应。取消停止本次 BEAM 执行任务；Port owner 丢失后 guardian 独立终止并 reap 目标。这个任务停止与原生清理完成是不同观察，现场应读真实进程证据，不能只凭 Task DOWN 宣告 OS 进程已经退出。直接调用 `Isolation.cancel(handle)` 可经本次私有 Port 取消，并由尚在等待的 execute 返回完整清理报告。

准备完成后发生崩溃而没有已确认回执，`sandbox_exec` 被视为非幂等且不可自动查询。后继保留 unknown 并进入可见核对流程，绝不因进程已死而重新执行。按本手册第 5—6 节读取原 operation、确认工作区效果、保存可信证据；已确认 receipt 会被复用。不要删除 prepared、换 operation_id、放宽策略或重置预算来“解锁”。已经写入的文件不会被取消自动回滚。

### 演练与现场收尾

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
LAB_DATABASE_ENABLED=false ./scripts/mix lab.isolate --output artifacts/week15-isolation-incident-drill
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

选择新目录。18 项探针使用自有 canary、固定 C 程序、真实 loopback 基线与直接 syscall；同名恶意 profile、预置硬链接、未知命令与策略格式另有自动测试。检查总报告 expected_probe_count=18、probe_count=18、all_passed=true，再比对每份 raw execution、summary、canary hash 和 cleanup。取消/调用方崩溃必须先看到目标发布的 nonce/PID 文件，与 trusted target PID 相等，再注入故障并独立等待目标和 guardian 不存在。失败报告与已完成证据都应保留。

正常完成和可捕获异常会等待 guardian 退出，再删除此次随机临时目录及宿主私有 profile。调用进程被强杀时由独立 guardian 回收目标，BEAM janitor 尝试清理临时文件；整个 BEAM 立即退出可能留下不再使用的私人控制目录。恢复后先按自有 manifest 核验实际 OS 进程是否结束，再删除确认已失效的随机目录；不要批量 kill 名字相似的进程，也不要清空其它运行的 control 目录。工作区实际产物和原报告继续保留。

当前树清理的证明依赖“一个目标、禁止 fork/spawn、目标为 session/group leader”；不能为了兼容 shell 脚本打开 fork 后继续沿用同一证明。将来 Linux 或多进程后端必须重新验证 namespace/cgroup、后代逃逸、资源与宿主生命周期边界。当前验收证据和明确未支持范围见 [第 15 周记录](validation-week15.md) 与 [ADR 0014](adr/0014-isolated-execution.md)。

## 14. MCP stdio 连接与核对

### 先核对宿主登记与协议版本

只有宿主显式设置 `mcp_policy:`，模型才能使用 `mcp.<server>.<remote>`。登记包括固定 command/args、隔离 workspace、断网和资源政策、批准工具的精确 input schema、宿主描述。发现额外工具或收到“readOnly/idempotent”提示均不会扩大授权。不要从服务器 description、instructions、工具输出、消息或摘要导入配置，也不要让模型提交服务器命令、环境变量、profile 或预算覆盖。可运行例子见 [L15 第 3 节](../labs/L15-mcp-stdio.md#3-第一次真实-stdio-调用)。

本实现只支持 MCP **2025-11-25**：initialize → initialized → tools/list → tools/call。2026-07-28 已改为每请求能力传递并取消该握手；不能只改版本字符串或根据 latest 文档混用。版本不符或缺 tools capability 时结束连接；没有静默协商到未实现版本。HTTP、OAuth、远端服务器、Resources/Prompts、Sampling/Roots/Elicitation 与 Tasks 都没有获得授权。对反向 ping 可回复，其它反向请求以 method-not-found 拒绝，不触发模型或提供文件 roots。

新端点接入应先核对当前有限 schema 子集，固定 inputSchema 与 host tool 名，再验证真实服务端的协议行为。当前工具名比完整规范更窄，只支持有界 ASCII 字母、数字、下划线、连字符；本地完整名称固定点分前缀。完整 JSON Schema 的 `$ref`、组合器、正则或未知关键字直接拒绝，不可删除校验绕过兼容问题。

### 连接、时限与结果解释

`MCP.execute(policy, local_tool, arguments)` 为单次操作创建有限生命周期的连接，完成后关闭，不自动重连重投。Connection 是更低层的显式会话接口，同样检查 host 白名单/schema，不能凭 discovered 名称调用额外工具。每条连接最多一个在途请求，JSON-RPC ID 在本连接内不复用；Runtime 的 operation_id 独立保留逻辑身份。成功与协议/工具错误均带传输配对信息，不能把另一个 request ID 的响应装进原操作回执。

默认 connect_timeout_ms=2000、request_timeout_ms=5000，max_message_bytes=65536、max_tools=32、max_pages=8。连接整体仍受 W15 isolation wall/CPU/单文件/FD/总输出限制；stdout 与 stderr 的总捕获也计入该输出预算，stderr 只保留有界诊断，不进入 JSON-RPC parser 或模型结果。消息以换行分隔，不能采用 LSP Content-Length 或把普通 stdout 日志当消息。

DurableTools 在启动前提交 prepared，并在短事务中复验 claim、policy hash 和最早 Run/任务/retry/观测 lease 期限；传入单调时钟 deadline，连接 setup 后、真正起跑前再扣除过去的时间。每个请求进一步取本地时限与宿主截止时间的更早者。后台 Worker 仍按既有协议续租和回收；不可靠的 SQL 授权不能换来更宽的 MCP 时限。进程等待不占 Run 行锁，receipt 提交再次验证 token/generation/seq。

| 观察 | Runtime 映射 | 处置 |
| --- | --- | --- |
| 未授权工具/参数，版本/capability/schema 漂移 | tools/call 前 error | 查 host policy 与原始发现信息，禁止扩大配置后盲目重发同一已准备操作 |
| JSON-RPC error | `{:error, %{"type" => "mcp_rpc_error", ...}}` | 保存 code/message 与 mcp 请求身份；收到错误不证明副作用为零 |
| 合法 result 且 isError=true | 配对 `mcp_tool_error` | 保留 content/structuredContent 与 ID，交后续决策处理，不冒充网络故障 |
| 调用发出后断连/非法 JSON/错误 ID/超帧 | paired unknown | 保留原操作，进入 manual 核对；不得自动重连重投 |
| request timeout/显式取消 | 发原 request ID 的 cancelled，返回 unknown | 取消是 advisory，服务端可忽略；不能据此断言回滚 |
| 目标和 guardian 退出 | 本地生命周期证据 | 继续核对效果与 receipt，不等同于未发生 |

初始化超时不会发送对 initialize 的 cancelled；关闭传输解决本地连接生命周期。正常关闭先刷新已接受的输入再给 EOF，有限等待后回收自有目标。直接取消会将连接标记 tainted，迟到回复被忽略，不能恢复 ready 或接受新的工具调用。调用者死亡同样由连接/原生 guardian 监控回收；不要只凭 BEAM DOWN 声称 OS 进程已经不存在。

Server 启动本身可能写文件。初始化或发现失败只能证明没有发出 tools/call，不能推导任何服务器都没有启动副作用。本机固定 fixture 仅有实验内 trace；接入新的服务器必须重新检查它的启动行为。权限仍是 W15 私人 workspace/断网/单目标，不包含 Docker socket、宿主秘密环境、任意子进程或新增网络例外。

### 未知结果与持久恢复

在原应用中使用只读入口核对原身份：

```elixir
{:ok, snapshot} = AgentSystemsLab.Recovery.load(run_id)
snapshot.recovery.mcp_policy
AgentSystemsLab.DurableTools.list(run_id)
AgentSystemsLab.ReconciliationQueue.get(run_id)
```

policy 是不可变 sidecar，不能在 resume/step 时注入新配置；sidecar/hash 损坏会拒绝加载和领取。不要直接改表或重置预算来绕过拒绝。读取数据仍使用既有安全 Codec，不执行数据库提供的代码；新 BEAM 必须可解码当前运行时产生的回执和错误词汇。

MCP 一律按非幂等、不可自动查询的操作处理。prepared 后崩溃、效果后断连或结果未确认时，新 claim 不能再次发送原 tools/call；即使对方声明 idempotentHint/readOnlyHint 也不改变这个规则。队列应显示 safe_mode=manual 与 journal_status=unknown，`Recovery.reconcile(id)` 没有证据时返回 reconciliation_required。已确认 receipt 在重复投递时复用，绝不为“验证一下”再起服务器。

确认真实目标、工作区或外部系统中的实际效果，再遵循本手册第 5—6 节提交可信人工 evidence 和原 operation 的配对结果。人工确认记录与 Kernel 接受仍是两个提交边界，异常后继续读取原回执；不能换 operation_id、删除 prepared 或把确认变成第二次执行。正常错误与 unknown 不得混为可重试的 transient-none，远端 exactly-once 仍不由 MCP 提供。

RunServer 保持宿主显式取消/总超时的终态行为；MCP Task 非预期退出则保守记录 paired unknown 并 blocked，不允许使用 Mock 核对 MCP。其内存 blocked 与 Recovery 持久人工队列是不同入口。取消会拒绝迟到提交，但取消与授权提交/OS exec 之间仍有竞态，已经发生的文件效果不会自动撤销。

### 演练与事故关闭

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.mcp --output artifacts/week16-mcp-incident-drill
LAB_DATABASE_ENABLED=false ./scripts/mix lab.mcp --memory --output artifacts/week16-mcp-memory-drill
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

默认完整演练 20 项，包括 18 个 stdio/权限/生命周期窗口与两个真实持久恢复窗口。memory 明确只跑 18 项，recovery_verified=false；不得把它当成数据库恢复验收。使用全新目录，保持全局 Scheduler 关闭；不将真实事故 Run 当作故障 fixture。

核对 report 的 expected_case_count、case_count、all_passed、mode/recovery_verified，再核对逐项 raw execution、服务端自有 trace、request ID 与取消 ID、native cleanup、实际 PID 退出和数据库重建结果。effects-before-reply 的最终 blocked 是预期核对状态，不能为了“全部成功”自动确认。失败位置、已完成记录和旧目录都保留；格式错误或源码变化后用新目录复跑。

停止本次连接后再按已保存 PID/nonce/来源核验本地进程，禁止按名字批量 kill。private control 临时文件收尾与 W15 一致，整 BEAM 强杀后的残留要在核验进程已退出后清理。当前正式报告、独立复核与源文件 manifest 见 [W16 验收](validation-week16.md)；它们证明本地受控子集，不证明任意第三方 server、Linux、完整 MCP 或生产安全认证。

## 15. DAG 编排与子任务恢复

### 先查看原图与子 Run

保留 Workflow ID、定义哈希、节点 ID、稳定子 Run ID、事件 seq、原预算、绝对 deadline 和各自工作区。读取不会推进依赖或执行工作：

```elixir
alias AgentSystemsLab.{Workflows, Recovery, DurableTools, ReconciliationQueue}
{:ok, workflow} = Workflows.load(workflow_id)
{:ok, ^workflow} = Workflows.rebuild(workflow_id)
workflow.status
workflow.unresolved_nodes
workflow.nodes
{:ok, child} = Recovery.load(workflow.nodes["implementer"].run_id)
DurableTools.list(child.state.run_id)
ReconciliationQueue.get(child.state.run_id)
```

图为可信宿主的静态定义，最多八节点、宽度三。只有全部直接依赖成功的节点可以创建 Run；其他节点的稳定 ID 可以已经显示，但数据库里尚无 Run。汇合保留完整来源和回执，不能通过改写依赖状态、截掉证据或手建子 Run 绕过拒绝。`:reviewer` 和输出 `approved` 都不授予权限。五维额度为静态预留，不退款、不转移；不能把失败节点预算改大后称为同一次恢复。

### 暂停、续跑与持久取消

```elixir
{:ok, coordinator} = Workflows.start_link(workflow_id: workflow_id)
Workflows.status(coordinator)
Workflows.stop(coordinator)
# 后续在同一应用或新 BEAM 用原 workflow_id 启动新的 Coordinator。
{:ok, coordinator} = Workflows.start_link(workflow_id: workflow_id)
# 需要持久终止时：
{:ok, stopped} = Workflows.cancel(workflow_id, "operator decision")
```

`stop` 只停止本 Coordinator 及其拥有的 Scheduler；如果其他 Coordinator 或人工 Scheduler 也消费此图私有队列，它们仍能领取。需要暂停所有交付时，应按已保存的 PID 停止所有自有消费者。重复 Coordinator 不会增加数据库共享的 `max_parallel`，也不构成新的执行权威。

取消先 COMMIT 父门禁，再逐个收敛子 Run。失败同样关闭父门禁并停止未终态兄弟节点，未创建下游设为 skipped。父图 failed/cancelled 以后，领取、续租、模型扣账、工具准备/执行及迟到回执均受门禁限制；原工具人工核对仍允许。父取消不撤销已经发生的文件或远端效果。

取消或失败的收敛若中途遇到数据库故障、helper 超时或进程死亡，保留原 ID，再执行 `Workflows.sync(workflow_id)`，或重新启动 Coordinator，让其首先补齐停止流程。父图终态不代表所有子工具已经确定；检查 `unresolved_nodes` 和原核对队列。

### unknown 的人工核对

prepared 后崩溃、效果已发生但回执未知的子节点保留 blocked/manual，绝不自动再执行。取消窗口中 journal 可能仍为 prepared，也可能已经归档 unknown；两者都不能当成 effect:none。已有 completed 回执优先复用，不为取消或恢复把它改成 unknown。

按本手册第 5—6 节核实原目标，使用原 Run/operation 提交可信人工 evidence；`Recovery.reconcile` 没有证据时继续返回 reconciliation_required。**核对后再执行 `Workflows.sync(workflow_id)`**：已终止图的 Coordinator 会停止轮询，人工接受结果可能暂时让子 Run 回到 running，但父门禁阻止新模型意图被执行，sync 将其归档 cancelled 并更新 unresolved。父图不会重新开启，也不会解锁后代。仍在运行或 blocked 的父图则可在核对成功后按原依赖继续。

### 崩溃与数据库故障

| 观察 | 操作与判据 |
| --- | --- |
| 根图创建 COMMIT 不确定 | load 原 ID；不存在则以完全相同定义重试，存在则校验后续跑。不得换 ID 规避不确定提交 |
| 依赖释放 COMMIT 前后进程死亡 | sync 原图；子节点、恢复配置、事件、intent 与身份一起存在或一起回滚，不能创建第二个子 Run |
| Coordinator 被 kill | 原 Scheduler 接收 OTP 父退出并清理；新 Coordinator 读取原持久事实。它不同于真正遗留 claim 的 Worker 强杀 |
| Worker 被 kill | 原租约到期后由新代次领取；旧 token/generation 拒绝续租及迟到写入，已确认工具回执仍复用 |
| 数据库不可用或 SQL 等待 | status 显示单个 pending_sync、退避和错误；wake 合并，不绕过退避；恢复后原实例继续。不要停止共享 PostgreSQL 做事故演练 |
| 超过总 deadline 或子预算 | 显式 failed，保留实际支出；下游创建时间不重置父 deadline |
| Join/Context 保护输入超限 | 留下明确 failure 与来源，不裁剪完整回执后重新称为相同任务 |
| schema/hash/history/membership 不匹配 | 停止交付，保留数据库与日志检查；不直接修表、重置 seq 或使用旧源码跳过校验 |

锁顺序沿用 Queue → Run → Workflow；编排推进使用 Queue → Workflow，并仅以 MVCC 读取旧 Run 的已验证状态，不持有 Workflow 锁后再反向锁旧 Run。外部工具继续在 SQL 事务外运行；编排事务不是跨进程或外部效果的原子事务。

### 复现与关闭事故

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.workflow --output artifacts/week17-workflow-incident-drill
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

演练要求真实 PostgreSQL 与关闭的全局 Scheduler，输出目录必须全新。九个 case 涵盖同图单/双 Worker、同预算单/双 Run、失败、取消、模糊效果、控制器强杀、下游准入两个 COMMIT 窗口与 deadline。检查 expected_case_count/case_count/all_passed、每项 summary、完整 Join、预算分配/支出、真实门闩与单次效果。预期 failed/cancelled/manual 状态保留，不能为凑成功率自动确认。

`Workflows.Audit.run(id)` 在空闲独立 BEAM 读取图与子历史，31 个执行/推进入口必须为零；计数是 VM 全局的，不与执行演练并行。将状态、录制、预算及原始表事实与正式演练快照比较，单次自相等不证明与上次一致。完整结果及冻结源码 manifest 见 [W17 验收](validation-week17.md)。本周是静态 Scripted 编排机制，尚无动态 Planner、返工、人工发布审批或真实模型质量评估；既有隔离后端限制继续有效。

## 16. 人工审批、暂停与受控返工

### 识别审批对象与原始事实

审批 Case 与单个 Workflow 不同：Case 固定整个有限返工计划、总预算、审批者及绝对 deadline；每轮仍是原 Workflow/Run 执行引擎。先读取原身份和已保存事实，读取不会重捕获产物内容或续跑：

```elixir
alias AgentSystemsLab.{Approvals, Workflows, Recovery, ReconciliationQueue}
{:ok, review} = Approvals.load(case_id)
{:ok, ^review} = Approvals.rebuild(case_id)
review.status
review.generation
review.subject
review.approval
review.decisions
{:ok, workflow} = Workflows.load(review.workflow_id)
workflow.control
```

`load` 返回最近一次持久化的观察，saved approved 不表示当前磁盘仍与批准相符。需要当前验证时使用 `Approvals.sync` 或 `release`；不能只取 `review.approval` 就调用工具。工作区、策略、模型/工具 schema 和原核对语义保持不变。旧 W17 无 control 的图不因升级多出授权或控制事件。

### 人工请求与可信宿主边界

宿主应先认证真实操作者，再将 Plan allowlist 中的 actor 传入。项目只提供实验边界与审计记录，没有登录、签名服务或多租户身份认证。不得从模型、MCP server、Reviewer 输出或普通工具消息中提取一个 actor 字符串就授予审批权限。

```elixir
{:ok, review} = Approvals.sync(case_id)
request = %{
  actor: "lab-human",  # 示例；由已认证宿主选择
  reason: "已检查本轮产物与基线",
  request_id: Ecto.UUID.generate(),
  expected_seq: review.seq,
  subject_hash: if(review.subject, do: review.subject.subject_hash),
  action: :approve
}
{:ok, approved} = Approvals.decide(case_id, request)
```

请求必须精确包含这些字段；只有 `decide` 接收 action。approve/rework/reject 不是模型工具。相同 request ID 和相同内容可重试，改动内容复用 ID 会冲突；旧 seq 或 subject 被拒绝。出现 stale_sequence 后读取当前 Case，核实改变，再以新请求作出新的决定，不盲目覆盖。如果 COMMIT 回报不确定，保留原 request ID 和完整请求，在原 Case 重试；不要自动生成新 ID。

### 哈希、基线与安全放行

subject hash 包括 Case/Plan、轮次、generation、成功 Workflow 证据、每个被批准文件的内容哈希和原基线。`initial` 只在该轮准入时检查原输出版本；`baselines` 是审批及放行期间仍需保持的 protected 文件，必须与输出路径分离。输出未知或缺失、基线不符、路径/链接越界、文件/总字节超限均不能产生可用批准。

```elixir
release_request = %{
  actor: "lab-human",
  reason: "取得刚批准的不可变产物",
  request_id: Ecto.UUID.generate(),
  expected_seq: approved.seq,
  subject_hash: approved.subject.subject_hash
}
{:ok, %{snapshot: snapshot, approval: decision, case: current}} =
  Approvals.release(case_id, release_request)
```

release 重新读取当前文件与 protected baseline，包括重复 request ID。文件发生变化时持久撤销当前 approval、递增 generation 并返回 approval_invalidated。之后改回原字节也不能复活旧批准。基线冲突留下 nil subject 和可见原因，不能强行 approve；可以拒绝，或请求下一轮预声明返工。

返回值包含获批的不可变字节。真正的后续消费者应使用这些字节，并在应用补丁时以 snapshot 中的基线哈希做 compare-and-swap；不要拿批准后再读路径得到的新内容。本模块不应用补丁或发布；已经交给外部消费者的旧字节无法撤回，外部系统的取消、幂等与核对仍是独立责任。跨多个文件的读取不是文件系统事务，暂时改变又在观测前完全恢复也不由本实验检测。

### 暂停、恢复与未知效果

`Workflows.stop` 或 `Approvals.stop` 只是停止一个进程树；持久暂停使用 pause。审批所属的 Workflow 不允许通过公开 `Workflows.resume` 绕过 Case。

```elixir
{:ok, review} = Approvals.load(case_id)
control_request = %{
  actor: "lab-human", reason: "等待人工检查",
  request_id: Ecto.UUID.generate(), expected_seq: review.seq,
  subject_hash: if(review.subject, do: review.subject.subject_hash)
}
{:ok, paused} = Approvals.pause(case_id, control_request)
# 确认可以继续后读取当前 paused，再发送新的 request ID、seq 与 subject_hash。
{:ok, resumed} = Approvals.resume(case_id, %{control_request |
  request_id: Ecto.UUID.generate(), expected_seq: paused.seq,
  subject_hash: if(paused.subject, do: paused.subject.subject_hash)})
```

暂停遵守 Queue → 已有 Run（稳定顺序）→ Workflow → Control 锁顺序，撤销原 claim token/owner/expiry，下一代重新领取。快速 pause/resume 也不会复活旧资格，旧 frame/effect/receipt 提交仍失败。Case 操作先锁 Case，执行路径不反向锁 Case。Control 的 owner 与 Workflow 不可变 owner 字段交叉绑定，单个控制记录删除或 owner 剥离会拒绝执行。

已经越过启动检查的工具仍可能产生真实外部效果，暂停不会回滚。prepared/unknown 原操作继续核对；非幂等模糊结果不可自动重投。通过原 `Recovery.reconcile` 提交可信 evidence 后，暂停门禁仍不允许模型继续；只有显式恢复可重新交付。检查原 Run/operation、receipt、效果次数和 `ReconciliationQueue.get(run_id)`，不得换 ID 绕过歧义。

原 Run、Session、权限、预算和 deadline 保留。暂停以及人工等待不延长墙钟总期限，支出不退款。暂停已批准 Case 后，resume 同样检查当前产物；不能利用 pause/resume 保留已经变化的批准。重启应用后由宿主按原 Case ID 启动 `Approvals.start_link(case_id: case_id)`；它只启动当前运行轮的一个 Workflow Coordinator，审批后继续观察产物变化。

### 受控返工与冲突

在 awaiting_review 发出 action=:rework 的新请求，使用当前 seq 和 subject hash（冲突下 subject 可以为 nil）。只选择 Plan 的下一轮，最多三轮；没有新脚本、路径、权限、网络或预算选项。新 Workflow、owned Control 和 Case 切轮在同一事务内登记。旧轮保持暂停、历史回执不变；相同请求不会启动两次返工。

所有轮次的五维最大分配在首次创建前就已计入总 cap，包括未被采用的轮次；不能把未用额度转给下一轮或退还旧支出。新轮自己的计数不代表 Case 预算重置，每轮上限是原计划的保守预留。Case 原 deadline 约束所有轮次。超过轮次返回 approval_round_not_found，基线冲突或完整产物装不下时留明确失败/冲突，不自动放宽策略。

### 提交窗口、事故关闭与验证

批准、暂停、返工的 COMMIT 前后强杀都按原 Case 和请求恢复：提交前整个事务回滚；提交后批准/控制/新轮一次存在，重试不重复决策。只读重建验证每个历史投影的 Artifact spec、请求、CAS、generation、冻结 Plan/Workflow 与原控制归属，不仅核对最终投影。schema、hash、历史或绑定损坏应停止交付并留证，不修表绕过。

取消或失败先关闭 owned Control，再补齐原 Workflow 的收敛；中断后用 `Approvals.sync(case_id)` 重复收敛。人工核对不会重开被取消的 Case。实际 round blocked/manual 继续可见；不能为让阶段验收全成功而自动确认。

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.approval --output artifacts/week18-approval-incident-drill
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

使用真实 PostgreSQL、关闭全局 Scheduler、选择全新输出目录。十一项演练包含实际 effect 门闩、审批/返工提交前后 kill、改回原字节仍失效、基线冲突及原 Run 暂停恢复；synthetic actor 是实验输入，不是真实发布批准。报告检查 all_passed、expected_case_count、逐项快照、原预算/操作台账与只读审计。空闲独立 BEAM 的 `Approvals.Audit.run(case_id)` 必须无模型、工具、控制变更或 Artifact.capture/check_baselines 调用；计数为 VM 全局，不与执行并行。核对正式快照、录制、预算及原始表事实没有变化。结果见 [W18 验收](validation-week18.md) 与 [P4 总结](p4-report.md)。

## 17. Trace Metrics 与按 Run ID 诊断

### 从原 Run 读取事实

```sh
./scripts/mix lab.trace RUN_ID
./scripts/mix lab.trace RUN_ID --json
./scripts/mix lab.trace RUN_ID --scope run --limit 100 --max-related-runs 24
```

命令先加载配置，PostgreSQL 未启用或全局 Scheduler 已启用时，在启动应用之前拒绝。查询采用 repeatable-read、read-only 事务，不调用模型、工具、Recovery.step/resume/reconcile、Workflow/Case sync 或 Artifact.capture。应用已运行时可由可信宿主直接调用 `AgentSystemsLab.Observability.Query.run(run_id, scope: :related)`；查询不会唤醒调度器，宿主仍需控制它原本已有的后台任务。

先确认 `run_id`、`trace_id`、`evidence_origin` 与 `partial`。事件、模型、Context、操作、尝试、意图、retry、节点等多行集合的 `limit` 默认 100，可设 1—200；Run 集合与每 Run 的预算、恢复单例另由 `max_related_runs` 限制，最多 24。Workflow/Case 归属查询另有固定轮次上限，不是所有集合都按 limit 截断。`scope: :related` 只沿原 Workflow/Case 归属选取已登记轮次，`scope: :run` 限制为原 Run。截断列在 `truncation`；预算等惰性载荷最多解码 1 MiB，无法投影会显式标记 unavailable 和 partial。不要把截断列表当完整业务历史。它是元数据投影，严格版本/完整事件历史验证继续使用原 load/rebuild。

`spans` 包含 Run、Kernel Event、已接受模型录制、未配对录制的 Context capture、operation、tool attempt、调度意图、retry、预算、恢复及 Workflow/Case 控制事实。Context capture 只证明保存了请求输入，不证明模型实际被调用、失败或成功；历史模型失败尝试可能只有已扣次数，不能伪造完整生命周期。行时间标为 created/updated/recorded，不冒充 provider latency。运行时 start/stop 的单调时钟差值才是该观察到的调用耗时。

同一模型 Context、工具 attempt、当前 intent generation 使用稳定逻辑 Span ID，与对应实时事件对齐。每个 Run 有独立 trace；DAG 依赖、Case 轮次与返工因果用 `links`，跨 Run 不伪造父 span。ID 是关联数据，不能用来提交结果、续租、批准或提升权限。原 token/generation、预留预算、工具回执及 subject hash 的校验保持有效。

### 实时观察与导出

```elixir
alias AgentSystemsLab.Observability
alias AgentSystemsLab.Observability.Exporters.JSONL
:ok = Observability.flush()
previous = Observability.configuration()
:ok = Observability.configure(exporter: {JSONL, [path: "/private/tmp/lab-observations.jsonl"]},
  export_timeout_ms: 200, backoff_ms: 1000)
Observability.stats()
Observability.metrics()
Observability.recent()
# 宿主完成观察后：
:ok = Observability.flush()
:ok = Observability.configure(previous)
```

默认 Null，不需要外部 collector；这里是内部 v1 JSONL，不是完整 OpenTelemetry SDK 或 OTLP。目的路径、exporter 模块与选项只由可信宿主配置，不能来自模型、MCP 消息或工具参数。导出是带 timeout 的单个 linked/monitored Worker，业务 emit 只投递经过 allowlist 的有限数据，不做 IO 或同步调用。配置、flush、读取诊断是宿主操作；不要把它们放进执行关键路径。JSONL 文件需由宿主轮换和设定保留期限，内存缓冲上限不构成磁盘配额。

输出没有 prompt、模型正文、工具参数/结果、工作区路径、actor、reason 原文、claim token/owner 或异常 inspect。有限 ID 字符校验不等于匿名化；业务 ID 本身不得包含秘密。Query 是可信宿主诊断接口，本周没有多租户访问控制或远端传播。

实时观察可能丢失、乱序或重复，包括无变化/idempotent Case、Workflow 操作再次观察到同一提交快照；`event_id` 可关联同一观察对象，不能证明唯一业务发生。Metrics 的有限 `{event_name, outcome}` 标签不包含 Run/operation/attempt ID，汇总已排出事件的次数和有限数值总和。需要真实决定/返工次数、扣账或 receipt 时读 durable 事件与原账本，不能用观察计数驱动业务。

### 导出故障、饱和与观察器重启

默认队列 256 槽位、external-term 载荷 1 MiB，单事件 8 KiB；每批至多 32 行且仅一个 exporter Worker。recent 独立限制 128 行/512 KiB；在途 batch 也受批数与单行上限约束。数值反映载荷，不是整个 VM 的精确内存。生产者使用有限 CAS 与固定 ETS 槽位，竞争、满额或超大事件可丢弃；合并 wake 不把每条事件加入 observer 邮箱。

检查 `dropped`、`invalid`、`export_lost`、`export_errors`、`export_timeouts` 与高水位。导出返回 error、raise、exit 或挂起时，当前批不重试，超时 Worker 被终止，之后退避；它不能触发业务重试、预算退款、自动确认 unknown 或改变批准。COMMIT 后、emit 前崩溃允许没有实时成功通知，仍从原 Run ID 查数据库；收到通知也不能替代提交证据。

观察器位于监督树末尾，是 temporary child。被 kill 或停止后业务 sibling 继续运行，陈旧 handle 安全丢弃；挂起 exporter 随 owner 退出，不能遗留失去 timeout 的子进程。需要恢复时由宿主执行：

```elixir
{:ok, pid} = Observability.restart()
```

restart 同样可以显式清空仍存活观察器，重建队列、recent、指标与准入计数，不补发历史通知，也不重置业务。它使用 Application 的静态 `:observability_options`（未配置时为 Null 默认值），不会自动保留运行中 configure 的路径或 timeout/backoff；需要保留临时配置时，在存活期间保存 `previous = Observability.configuration()`，restart 后显式 `Observability.configure(previous)`。producer 在 atomics 预留后、ETS 插入前被 kill，可能遗留有限 permit、使容量下降；长期 `buffer_entries` 大于 `queued_entries` 可供诊断（短暂差异可能只是正常准入）。本周没有自动无损 permit 回收。重启只动 observer，不重启 Registry、ProviderSupervisor、RunSupervisor 或已有 Run；自定义 exporter 是可信代码，不应修改 trap_exit 绕过清理。

### 演练和关闭事故

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.observe --output artifacts/week19-observability-incident-drill
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

演练需真实 PostgreSQL、关闭全局 Scheduler 和全新目录，只消费自己创建的队列/Run。八项检查包括实际续租门闩、unknown 的人工核对、审批返工四个子 Run 的关联、五种导出模式执行等价、16,000 条并发观察、有观察器缺失的真实执行、COMMIT 两窗口进程 kill 及只读审计。保存的 manual unknown 仍需按原核对流程处理，不能为关闭观测事故而重发工具。

完整证据、冻结源码和独立新 BEAM 的零执行复核见 [W19 验收](validation-week19.md)。运行时通知缺失应作为观测损失记录；业务是否提交、效果是否确定、审批是否当前有效，分别由原事务、核对和 release 流程回答。

## 18. 可重复评测与回归比较

### 固定协议与分割

```sh
./scripts/mix lab.eval --output artifacts/L19-dev-baseline --split dev --profile reference --repetitions 2
./scripts/mix lab.eval --output artifacts/L19-dev-candidate --split dev --profile regressed --repetitions 2 --baseline artifacts/L19-dev-baseline/report.json
./scripts/mix lab.eval --output artifacts/L19-holdout-baseline --split holdout --profile reference --repetitions 2
```

执行前确认 PostgreSQL 可用，关闭全局 Scheduler 和其他会竞争这些新 Run 的消费者，使用全新目录。CLI 在 app.start 前拒绝禁用数据库和启用全局 Scheduler。每个样本创建独立 Run/工作区，原有工具权限、预算、未知结果核对与持久化提交语义继续有效。框架不会恢复旧业务任务，也不会为了评分重发模糊工具效果。

默认 dev、reference、每任务两次，CLI 可选 1—10 次。固定集为 6 dev、4 holdout；两个分割分别运行和比较，不能混成更好看的分母。manifest 保存完整计划与预分配 Run ID，绑定任务文件、oracle、Scorer、定价、分割、重复数、运行时与执行合同。合同含原 Run 预算、step 上限、执行等待和评分等待；改变它们后需新基线。种子 0 表示固定按 task ID/trial 排序，不表示真实模型采样可确定。

本周为公开 Scripted 教学数据；reference 产物由固定响应产生，holdout 文件也能从源码读取。它验证评测管线与执行回归，不构成防泄题的模型能力盲测。不要将结果外推成真实模型成功率或生产吞吐。

### 独立评分与真实消耗

实际 `artifact.txt` 经受控读取后保存到单独评分目录。可信固定 Scorer 在新 OS BEAM 中只检查文件 hash/字节，不执行产物代码，不启动项目应用或继承数据库/API 凭据；请求与结果绑定 task/sample/artifact/scorer 身份。模型自报成功不授予分数，产物正确而 Run 已预算失败也不能计任务成功。

Scorer 默认 3 秒、输出上限 8 KiB；独立 guardian 持有 Port 并监控调用者，在超时、输出超限和调用者被 kill 时尝试终止本次自有 OS 子进程、关闭 Port 并有界轮询。当前 helper 最多轮询约 1.5 秒，到截止时仍可返回 `:ok`，评分结果没有独立的 `cleanup_verified` 字段；返回本身不认证退出，现场须按本次记录的自有 PID 独立核对进程已消失，仅关闭 Port 也不足以证明清理完成。它不是用于执行不可信代码的安全 sandbox，也不对抗同宿主账户恶意改文件。产物快照只读标志、hash 与评分前后原事实指纹用于发现变化；变化或读取失败会使 usage 未知，不能把旧的部分计数当完整成本。

成本权威来源是原持久账本，公式为 `1000 × model_attempts + output_bytes + 250 × tool_attempts`，单位 synthetic lab units；dispatches 报告但不加价。output_bytes 包括已扣模型输出，不是 token，也不代表文件总大小。USD 始终 null；没有真实 provider usage/价格时不编造真实费用。失败消耗不退款、不丢样本；usage 缺失时保留 known sum/unknown count，总成本为 null。

每个 task/trial 都在样本成功率分母中；任务成功率另要求该任务所有重复均成功。finite failure_class 区分 incorrect、permission、budget、timeout、unknown、scorer_error 和 harness_error。模型、工具或评分器出错属于完整样本的结果；批次设置或报告写入中断则整个批次 incomplete，不把剩余任务伪造为已测样本。

延迟用单调时钟微秒测量 execution、scoring、total；execution 含样本初始化及数据库执行，scoring 含产物捕获、启动新 BEAM 和评分，total 另含原事实读取等开销。失败也进入延迟统计。p50/p95 使用 nearest rank，不能把分组 p95 再平均。当前是顺序单宿主实验，缓存、并发负载和冷启动会影响实测数值。

### 保存报告与回归门槛

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.eval.compare \
  artifacts/L19-dev-baseline/report.json artifacts/L19-dev-candidate/report.json \
  --output artifacts/L19-regression-check
```

文件比较只加载配置和代码，不启动应用、Repo、Scheduler、模型或 Scorer。它限制报告大小，拒绝重复 JSON 键，重新验证完整 task/trial 覆盖、唯一 Run ID、底层样本、派生统计和所有 hash。suite、scorer、pricing、分割、任务/版本、重复数、运行时、合同或计量范围不一致时拒绝比较；profile 可不同。不要用编辑 summary 的方式修复失败基线。

成功率默认允许下降 0 个百分点；成本默认相对和绝对增量均为 0；延迟默认相对 25% 且绝对 50,000 微秒。成本与延迟均需同时越过相对和绝对门槛才标回归，零基线单独处理；门槛严格大于才越线。检查同时覆盖总体和逐任务、执行/评分/总耗时的 p50/p95，避免平均改善掩盖单任务退步。门槛是预先选择的政策，不是显著性检验。

```sh
./scripts/mix lab.eval.compare BASE/report.json CAND/report.json \
  --output artifacts/L19-explicit-policy \
  --success-drop-pp 0.0 --cost-increase-pct 0.0 --cost-increase-units 0 \
  --latency-increase-pct 25.0 --latency-increase-us 50000
```

比较保存 baseline/candidate report hash、阈值、总体和逐任务 checks 及配对变化。regressed 或 indeterminate 都令 CLI 非零退出；带 baseline 的 lab.eval 同样先保存完整报告再失败退出。scorer/harness error 或未知成本不会被当成“更快更便宜”的通过。需要修改阈值时，在新目录另存 comparison 并解释原因，不覆盖原政策来追求通过。

### 中断、复现与关闭问题

目录包含预先保存的 manifest、逐样本安全摘要、samples.jsonl、status、完整 report，附原 Run ID、产物快照、原事实指纹和评分子进程元数据。status 为 incomplete 或没有完整 report 时，保留原目录及 Run 供调查；当前不支持中断批次自动续跑，重测创建新目录和新 Run。不能删除最差 trial 或只提交成功样本。

完整 report hash 包含当次真实 Run ID 与延迟；可重复语义签名排除这些变量。相同 profile 重复应保持任务结果、规范化回执、产物和成本，不能要求 OS PID 或耗时逐字节一致。hash 用于内容身份，不是签名或可信来源证明；回归还需核对原账本和实际文件。实时 Trace/Metrics 是可丢观察，不作为评测费用来源。

```sh
# 先用 PGHOST/PGPORT/PGUSER/PGPASSWORD 选定本轮专用实验实例
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.eval.verify --output artifacts/L19-acceptance-repeat
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

完整演练分别运行两个分割的 reference、重复 reference 和 regressed，再检查稳定语义/成本、逐任务退步、篡改与不兼容拒绝、只读比较零执行。独立审计脚本以实际目录验证统计、oracle、持久源、原表行 hash 与既有数据保留，见 [W20 验收](validation-week20.md)。本周未宣称完成外部六章试读或真实模型评估。

## 19. 历史迁移版本兼容与备份还原

### 识别版本和停止投递

先关闭涉及源库和目标库的 Scheduler、Coordinator 与手工驱动，并确认没有仍在执行的 Worker。只读 proof 要求静止数据库；前后指纹变化会拒绝，不能宣称在线原子快照。保留原始备份和故障日志，记录当前 SQL migration 列表、Run seq、checkpoint、工作区根、审批 subject、原始 deadline 和已经扣除的预算。

本周业务 Kernel/Event schema 与 Codec 仍为 1；新增的是独立 `history_format=1/2`。新建 Run 默认 1，显式迁移后的 Run 及追加 Event 使用 2。不同 Run 可以处于不同已支持格式，同一个 Run 的 Event 不允许混合。未知 schema、Codec、format、sidecar 或数据库结构必须明确拒绝；不要修改版本列来绕过校验，也不要删除损坏 checkpoint 让读取回退。

### 只计划、显式迁移和提交窗口

在结构升级到第 21 个 SQL migration 后，先 `HistoryMigration.plan(run_id)`，再用刚验证的 `expected_seq` 调用 `HistoryMigration.migrate(run_id, expected_seq)`。先检查真实源历史、投影和调度意图，再在 Run 锁中封装原 Event 字节、写迁移 journal，并重新验证相同 snapshot。每个 Run 最多 4096 个 Event、源及目标 payload 合计各最多 32 MiB；超界需另设计分批协议，不能取消限制。

有活跃 claim 时迁移拒绝；先停止旧 Worker，按原 lease 语义等待或执行明确接管，不要凭迁移需求提前改预算、截止时间或确认工具结果。COMMIT 前进程崩溃应整笔回滚，COMMIT 后崩溃应保留完整结果；重新读取后重试返回 `already_current`。迁移过程不调用模型、工具、执行驱动、审批写入口或观测导出。journal 校验已迁移前缀，正常追加新 Event 不会使其失效。

### 原生备份和隔离目标

运行完整演练：

```sh
./scripts/mix ecto.migrate
./scripts/mix lab.upgrade --output artifacts/L20-unique-history-upgrade
```

只使用全新输出目录。`Backup` 通过随机 DB 名、当前主 BEAM 内的 capability 和数据库 owner marker 共同限定目标；不接受任意既有数据库作还原目标，不使用 `--clean`、`--create` 或 force drop。Archive、manifest 为私有文件，校验 SHA-256、工具版本与大小后才创建目标。只接受当前可信宿主 registry 创建的 Bundle；重启后的磁盘文件不能直接导入为新 capability。

PostgreSQL custom archive 的成功退出只说明导出/还原命令成功。还原目标默认只读，先比较 22 张 lab 表及 `schema_migrations` 的所有列和行、序列的 `last_value/is_called`、列类型/默认值/约束/索引，以及兼容性矩阵。约束使用 PostgreSQL pretty canonical 表示，避免原生还原对等价括号规范化产生假差异；不是忽略约束。Raw Event/checkpoint 必须独立重建相同状态；源端 verified readers 还验证录制、Context、预算、工具回执、Workflow 与审批绑定。

这是单数据库逻辑备份，不包括 roles、tablespaces、WAL 和工作区文件，也不提供生产 PITR。实验保留同一已授权绝对根下的原文件，不能将 DB 中的回执当作外部文件已经恢复的证明。换宿主或丢失原工作区需另有文件归档、权限和外部副作用核对流程。包含私有 token 的 archive 和 `private-source-claim.bin` 不放入公开观测报告。

### 明确激活和安全续跑

只有 verified source proof 与只读目标完全一致，才调用 `History.RestoreGuard.activate(handle, scope, source_proof)`。它按 Queue → Run → Intent 锁顺序，在同一事务内撤销所有 pending intent 的复制 lease、递增 generation，确认受保护事实和 Run 状态未变后提交，再解除默认只读 gate。旧 Worker 即使源 lease 仍未过期也不能提交；新的执行者必须重新领取，原 dispatch 消耗不退款，deadline 不重置，unknown 不自动确认。

Fencing COMMIT 与管理连接解除 gate 是两步。若在中间崩溃，目标仍只读且复制的 claim 已撤销；原始 exact proof 再次比较会拒绝。保留该目标证据，从原可信 bundle 还原全新受管目标重新核验激活；不要手动关 gate 或重置账本。本实验的默认只读设置是防误操作门闩，有 owner/superuser 权限的人可以改变会话设置。

旧 20 个 DDL 的备份先还原为只读 staging；固定、关闭 Scheduler 的维护子 BEAM 仅在专用 Repo 会话中允许 DDL/迁移，其他会话保持默认只读。生成升级后的 verified proof 后重新 dump，再还原到第四个新目标，走同一个 `RestoreGuard` 流程。不能因为允许专用维护会话写 DDL，就直接让业务使用复制的 claim。

解除 gate 后，先在新 BEAM 用公开 readers 比较完整语义和 protected hash，再显式续跑。已完成文件工具不得重复写；pending 工具按原幂等语义执行；非幂等 unknown 留在人工核对队列；预算失败保持失败；审批 release 仍重验产物哈希、subject 和原授权。活跃 claim 曾阻止的 v1 历史可在 fence 后显式迁移。

### 关闭演练或事故

核对 `report.json`、两条路径的 proof、原生 archive manifest、子 BEAM 日志及 `database-cleanup.json`。失败证据保留；清理只接受本次精确 handle+marker，仍有连接则拒绝，不终止其他用户进程。数据库清理不删除原工作区。复核格式/编译、完整测试、内存模式和不兼容历史拒绝用例后，再恢复源或目标的单一投递入口。

配套 [L20](../labs/L20-history-migration-backup-restore.md)、[解答](../labs/solutions/L20.md)、[ADR 0020](adr/0020-history-migration-backup-restore.md) 与[第 21 周验收记录](validation-week21.md)。

## 20. 六章试读与干净环境复现

### 冻结阅读入口

W22 按原计划完成六章修订、实验步骤和干净复现；业务权限、预算、恢复机制本周不扩展。六章为 ch02/ch05/ch08/ch14/ch16/ch20，具体链接见[试读指南](../book/reader-study/README.md)，现行实验映射见 [L21](../labs/L21-reader-study-and-clean-reproduction.md)。原计划实验号不能直接替代已经顺延的现行编号。

`./scripts/mix lab.reading prepare --output artifacts/reading-unique` 生成源码自含包、protocol、无效模板与0人报告，不启动应用或数据库。协议绑定所有源码manifest及章稿/实验/指南/手册hash；用Reproduction.verify核对source。更改源码或协议须重新冻结，不重用旧反馈。包内的笔记、运行产物和练习修改应放在约定的包外/独立副本位置。

### 准备独立环境

使用自己新建的短路径目录，`lab.reproduce export|verify|cache|plan --output ABSOLUTE_PATH` 分别导出源码、验证、声明复制缓存和生成固定执行计划。plan只输出数据，不安装、不运行、不起停数据库；不接受读者反馈文本作为命令。路径实体、文件类型/链接、SHA、mode、体积和源前后扫描均应通过。不要在原源码目录或其大小写/Unicode别名下创建导出。

安装缓存可包括固定OTP/Elixir archive、PG源码/SHA、Hex/Rebar3构建工具与包；不包含原deps/_build/已安装runtime/PGDATA。把缓存来源写入报告，重新解压runtime、编译PG新prefix和依赖。此次保证是同宿主、声明warm cache、新build与cluster，不是新机器或冷下载。无模型密钥，无新增Hex版本。

### 防止连接原库

按plan完整设置子进程环境，尤其unset DATABASE_URL；unset PGSERVICE/PGSERVICEFILE/PGOPTIONS/PGHOSTADDR/PGDATABASE以及Mix/ERL注入项，显式设置新端口、本地PGHOST、测试库用户和独立MIX/HEX/deps/build路径。Scheduler保持关闭。不要长期export内存模式后忘记切回；内存测试使用单命令前缀。

启动前确认导出中PGDATA/deps/_build均不存在，选择空闲端口；若端口已用则换端口，不停止占用者。初始化全新cluster后保存data_directory、system identifier、端口、fsync/synchronous_commit/full_page_writes及迁移前空库的证据。运行依赖解析、完整check、内存测试和verify/p1/history/recover/fence/upgrade六项主实验，逐步保存退出码、日志/报告hash和判据。

### 诊断和关闭

同一份源码若失败，保留失败输出，不更改原权限根、不重置预算或deadline、不盲重发unknown、不略过审批或fencing。重新运行用新输出。区分安装缺失、缓存无效、路径太长、环境污染、源码漂移和真实断言失败；未定位原因不能写成已确定的资源竞争。

结束时再次verify导出源码，检查实验产物具体断言。仅在确认本轮拥有的导出目录与PGDATA后，运行该目录的postgres stop，记录停止/端口释放；不得在原工作区stop共享PG或删除原dev/test。工具不会按端口或名字前缀强杀其他进程。所有数据库/外部效果仍沿用原恢复语义。

### 外部反馈是另一个gate

可信宿主通过`lab.reading add STUDY --feedback FILE`收集实际匿名反馈，`report STUDY [--technical FILE]`汇总。JSON只作为有界数据，反馈命令/evidence不执行；模板、agent、作者、重复ID、缺章、过时protocol、未知字段或不完整passed拒绝。技术文件同样有界、拒绝链接并验证固定schema；flags是宿主提交的执行声明，须配实际日志，不是认证。

技术通过不能代替3–5名完整外部读者、至少一份全新工作区主实验自报通过、零未解决blocker。无真人记录时保持external pending、P5 false。用户本轮已确认先交付技术与试读包，后续再补真人记录。未取得的易读性和完成率不能编造，作者/代理发现见[修订记录](reader-study-revisions.md)。验收结果见[W22记录](validation-week22.md)。

## 21. 发布准备、版本契约与课程入口

### 确认正在准备的版本

W23 整理接口、版本、课程与操作材料，当前项目仍为 `0.1.0-dev`，目标发布为 `0.1.0`。本周不创建候选标签、不声称已完成 W24 的冻结矩阵或外部试读。先读 [公开接口](public-interfaces.md)、[版本与发布操作手册](release-operations.md)、[已知限制](known-limitations.md)和 [L22](../labs/L22-release-readiness.md)。

```sh
./scripts/mix lab.release check
./scripts/mix lab.release plan
```

两条命令只编译并读取受限源码元数据，不启动应用或 Repo、不执行模型、工具、SQL、Shell 计划或反馈文本。固定清单记录 `.tool-versions`、依赖锁、运行时与数据库引导脚本、CI 配置、21 个 SQL migration，以及业务 schema/Codec/history layout 的独立版本域。静态 hash 不能证明安装包来源、实际依赖目录或数据库状态；这些需要运行时日志、迁移检查和回归命令另行证明。

`check` 的 source readiness 不等于 release readiness。缺失入口、固定版本漂移、迁移清单变化、损坏 JSON 或不安全链接应明确失败；保留原输出，定位实际差异，不能删除锁校验来获得通过。`plan` 仅给出固定可信课程命令与未完成 gate，人工选择运行环境后按原实验执行。

### 给学生和操作者稳定入口

[C01—C12](course-map.md) 是原十二个主题的课程组织编号，对照现有 L01—L22，不重命名历史实验。[三十张章节卡](../book/chapter-cards.md)记录设计与旧发行契约；当前全书已有 30 章正文草稿，入口见[阅读路线](../book/reading-route.md)，原六章试读稿仍保留此前冻结身份。没有历史 Git 起始标签时，使用明确 hash 的冻结源码副本与参考解答，不编造 start tag。

公开命令、只读诊断入口、宿主维护动作和内部模块在接口手册中分列。Provider 行为契约不代表当前 RunServer 可以任意注入 Provider；工具也不能靠模型自报名称或 schema 注册。修改适配器必须重新验证权限、参数、operation/attempt 绑定、回执、取消与恢复测试。源码准备工具不为调用者授予执行、审批或续跑能力。

### 故障、升级与回退

实际回归先按[完整回归的环境准备](command-reference.md#完整回归的环境准备)选定自己的可丢弃 PostgreSQL，再运行 `env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check`；内存检查使用单命令前缀 `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test`。另开终端时重新选择实例并清除 `DATABASE_URL`，不要让之前的 URL 改指完整回归。平台特定用例排除须写明，不能将未运行 Linux CI 或未执行的 20 次冻结故障矩阵写为通过。CI 固定 Ubuntu 24.04、OTP/Elixir、PostgreSQL 版本并加入准备检查和内存回归；现有 action 版本标签和镜像标签不等于不可变供应链签名。

任何版本或文档变更先保留前一版 manifest、实际源码和证据，再按受控流程修订清单、运行对应专项及全量回归。业务历史迁移/还原继续走第 19 节：默认只读目标、完整 proof、撤销复制 lease、提升 fencing generation、显式激活及重新领取；不把源码 hash 相等当作数据库兼容证明。回退代码也不能跳过历史版本校验或使用已经失效的旧 claim。

保留 unknown 核对、已扣预算、绝对 deadline 和产物绑定审批。失败时暂停本次受管入口并保留证据；不得盲重发非幂等操作、手工退款、重置代次、删除共享库或停掉未知进程。安装与干净复现沿用第 20 节的独立目录/端口、明确缓存和精确 owned 清理，不覆盖 W22 已冻结试读包。

### 交接到冻结验收

核对本周 [验收记录](validation-week23.md)、全部课程入口、章节卡、版本清单、公开接口与已知限制。W22 真人反馈仍为 0 时保持 P5 pending；W24 的全量故障重复、候选标签、发布结果索引与最终材料打包另外验收。本周可以完成准备工作，但不能由 source readiness 自动解除这些 gate。

## 22. 冻结验收与候选包交付

### 先冻结，再执行

以 [L23](../labs/L23-frozen-candidate-release.md) 和[候选说明](candidate-release.md)为入口。保留旧依赖锁、所有 SQL migration、权限、已扣预算、绝对 deadline、operation/attempt 身份、审批 subject 与 claim generation。W23 `lab.release check` 只检查源码准备，报告中固定的 W24 pending 是该工具的边界；本周执行结论来自实际冻结矩阵、回归日志和候选证据索引。

在全部修改和专项验证完成后，将源码导出到全新自有目录，保存 reproduction manifest 的原始字节 SHA-256。记录执行工作区与导出中每个源码文件的 bytes/mode 相同；执行后再次核对。结果文档的冻结副本先写明待补录，最终派生验收记录留在原工作区，不能修改已运行源码以插入“通过”。

### 矩阵与教学验收

原计划 F01—F12 分别对应提交前崩溃、漏通知、claim 后效果前崩溃、效果成功回执前崩溃、结果后下一轮前重启、租约接管旧 Worker 复活、100 个同操作并发、同 key 改参数、有限重试、审批产物变化、数据库断连、不兼容版本。每行至少 20 次真实尝试，保存精确屏障、进程死亡/信号、效果和回执计数及重建状态。

已有组件的 repetition 上限不放宽；需要时运行多个独立批次。调度或饱和组件只运行一次的结果不得扩算为 20 次。报告必须列出实际完成范围，部分执行保持 incomplete；遇到失败保留原目录、日志和子证据，不覆盖后再称为全量通过。故障类型由精确注入决定，不能用一次全量测试通过代替逐行重复。

另外执行完整 `mix check`、单命令内存模式及课程主演示，分别记录通过数、数据库/平台排除数和产物判据。内存排除不计通过，模型脚本不计真实模型能力，技术代理不计真人。

### 使用独立数据库，精确关闭

冻结实验可用项目已安装 PostgreSQL 二进制初始化本次私有 PGDATA 和短 socket 路径，选择未占用回环端口，明确 MIX_ENV/PGHOST/PGPORT 并清除 DATABASE_URL 等继承路由。先记录 PGDATA 不存在和初始实验库为空，再记录 system identifier、端口及三项持久性配置。复用已安装 runtime/build 必须如实声明，不称为冷环境或新机器。

完成或中断后，只在核对本次新 PGDATA、postmaster.pid 绑定及端口后停止本次集群，确认端口释放。不得停止原共享实例、删除原 dev/test 或按名字前缀清理其他用户连接。保留矩阵、owned 数据库子演练的 cleanup 以及原开发库前后行哈希。

### 打包和核验

候选源码、矩阵、完整/内存原始日志和声明的子证据用同一个源码 manifest 身份绑定，生成有界文件清单。候选目录包含源码、课程材料、说明、manifest 和 `candidate-evidence/`；不复制运行时、deps、BEAM build、PGDATA、凭据或旧真人包。证据仅按字节校验，不执行其中的命令、ETF 或历史 Run。

先 verify 候选目录，再仅归档其已声明的普通文件和目录，记录 tar.gz 的 SHA-256。移入新的私有目录后核对归档成员：拒绝绝对路径、上级逃逸、重复成员、链接、设备以及数量/大小超限；核验源码和证据后才按安装手册创建新的学习环境。不能通过解包历史证据恢复原授权工作区或重新使用旧 claim。

### 候选状态与交接

`v0.1.0-rc.1` 是 W24 创建时无 Git 仓库情况下的包清单标签，不能声称创建了 Git tag。技术候选与正式 release 分开。W22 原包保持冻结、真人 0 与 P5 外部准入待验收；Linux CI、冷机器安装和未实现的功能继续写在[已知限制](known-limitations.md)。证据、未完成 gate 与下一步验收条件分别见[结果索引](results-index.md)、[backlog](backlog.md)和[W24 最终记录](validation-week24.md)。

## 23. 版本化发行评估与追加式试读闭环

### 保留原包与原政策

先核对 rc.1 目录/归档及 W22 原试读包的前后 hash、文件集合和模式。W25 工具生成新协议和独立评估，不回写旧 manifest、原 feedback 或 gate。项目继续为 `0.1.0-dev`，目标 `0.1.0` 未发布；没有自动 tag、上传或部署。入口见 [L24](../labs/L24-versioned-release-assessment.md)、[发行评估操作](release-assessment.md)与 [ADR 0024](adr/0024-versioned-release-assessment.md)。

原政策继续要求 3—5 名真实独立读者、六章、至少一次新工作区固定主实验、零未解决 blocker、冷 macOS 主机和完整 Linux 隔离/冻结验收。尚无外部材料继续 pending；作者/代理/fixture 不能补人数，Linux 排除 Seatbelt 后的子集不能补完整平台门槛，本机新目录不能补冷主机。

### 显式绑定源码和反馈

由可信宿主选择通过 `Reproduction.verify/1` 的冻结 source，与全新绝对输出；`lab.reading.frozen prepare --source ... --output ...` 将本轮协议绑定到复制后相同的 manifest 原始字节身份。报告只读重算，原始反馈字节独占保存。旧 W22 `lab.reading` 合同保持原样，不拿旧 feedback 改 hash 后充当新协议。

同源码修复仅涉及外部环境或另附解释；修订包内章稿、代码、安装文件时重新冻结并新建协议。保留旧反馈与失败，重新取得受影响章节/实验的适用证据。读者声明、command ID 和 evidence 文本是自报数据，不执行、不认证身份、不读取任意目标。

### 追加中断先保留现场

问题闭环按 finding→fix→原读者最近 fix 的 retest 追加。fix 不关闭 blocker，失败复验仍未解决；成功后旧 finding 与失败也继续保留。事件序号、前一 hash、事件 hash 与 `head.json` 必须一致，独占 `.append.lock` 防止并发覆盖。

若遇残留锁、部分写入、缺尾、链漂移、head 不匹配或未知结构，停止追加，记录错误并保留整个目录。不要自动删锁、截断或覆盖 head/hash。核对可信外部保存的源、协议、原始反馈和 head，确认写入状态后制定显式修复流程；工具没有自动账本修复入口。缺少外部可信锚点时，hash 链不保证不可回滚或认证记录人。

### 只读发行评估与交接

从可信工具工作区运行 `lab.release.assess --candidate ... [--study ...] [--evidence ...]`；不在未验证候选里编译。命令不启动应用、连接数据库、执行证据或起停资源；Mix 编译可能写工具工作区。保存原 stdout、退出码与 JSON，分别读取证据完整、批准和发布状态；有效 pending 的成功退出不能解释成 release_ready。

材料缺失保留待验收，损坏/未知版本/错 source 或 protocol 明确拒绝；不填默认 true、不拼接不同源码的通过。评估按固定政策重算，不改变旧候选，不批准或发布。业务恢复继续走原 Run、预算、绝对 deadline、unknown/reconcile、审批产物 hash 与旧 claim fencing；发行文件失败不会赋予任何执行或资源清理权限。

## 24. 跨环境执行证据与独占资源清理

入口为 [L25](../labs/L25-cross-environment-validation.md)、[跨环境操作](cross-environment-validation.md)与 [ADR 0025](adr/0025-cross-environment-validation.md)。先选择通过校验的显式冻结源码、固定 profile、全新绝对输出和空闲回环端口；可信 W26 工具与被测源码身份分别保存。旧候选/试读包不直接运行或写入。

`lab.environment plan` 和 Python `plan` 不执行实验；Python `run` 执行固定 argv、安装/回归/主实验并操作独占 PostgreSQL；`lab.environment collect/verify` 只处理文件，不执行记录里的命令或连接 PG。不要把未知结果或错误日志重写成成功，也不要从不可信 JSON 启动清理命令。

本轮集群必须有新 PGDATA、实际 SQL data_directory/system identifier/端口、PID 文件与 ownership 记录。结束或中断后重新核对这些身份，只停止本轮确属自有的集群，确认端口释放、自有进程退出，保留所有退出码与原始日志。不要调用共享工作区 `scripts/postgres stop`、停止 55432、按名称前缀清库或 force drop。强制死亡留下现场时先检查身份；无法确认归属就不自动接管或删除。

完整性错误包括错 source/candidate、未知 schema、路径/链接/容量、引用缺失与 hash 漂移，应保存现场并拒绝；尚未取得的环境保持 pending。修复受版本管理的工具后生成新源码身份并重跑适用验证，不在旧包改 manifest 或补假日志。

本机 warm-cache 不证明冷主机；`--new-host` 与安装来源只是宿主自报，SHA 不是身份认证。Linux core 保留 Seatbelt 排除和实际失败，不升级为完整 Linux 隔离/矩阵通过。原发行 gate 保持，未取得真实机器/读者继续待验收；[W26 实测](validation-week26.md)单独记录。本流程不接管既有业务 Run，不重置权限、已用预算、原绝对 deadline、unknown、审批产物或 fencing；业务恢复仍用前述原身份流程。
