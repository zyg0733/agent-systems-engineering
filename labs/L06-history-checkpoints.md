# L06：从事实历史重建，而不是重新执行

对应第 7 周，建议用时 10—14 小时。前置实验为 L01—L05。本项目实验编号顺延，本周使用 L06；主题对应原研究计划中的事件重放、checkpoint 与模型录制。

本次要证明一个明确的边界：新进程读取已经提交的事实，可以重建相同的 Kernel State；重建期间不调用任何 Provider，也不执行任何工具。checkpoint 保存经过校验的历史前缀投影，模型录制保存已经接受的完整结果。两者帮助审计，但均不等于安全自动续跑。

## 1. 先分清三种操作

阅读 [ADR 0006](../docs/adr/0006-history-checkpoints-and-recorded-results.md)，给下列操作分别标出输入、校验和是否可能产生外部效果。

| 操作 | 读取什么 | 产出什么 | 本周效果边界 |
| --- | --- | --- | --- |
| History 重建 | 有序 Event 与原始 Kernel 选项 | Kernel State | 不调用 Provider 或工具 |
| checkpoint + tail | checkpoint 与其后的有序 Event | Kernel State | 不调用 Provider 或工具 |
| Recorded Provider | 显式选择的完整录制与精确输入 | 已保存的模型响应 | 不调用原 Provider；若宿主随后调度工具，仍可能产生效果 |
| Runtime 正常推进 | Context、模型响应、调度意图与工具 | 新 Event 与状态 | 可能调用模型或工具 |

History 消费的是 `run_started`、`tool_requested`、`tool_result_recorded`、`tool_reconciled` 和终态等已接受的事实。它通过纯 Kernel 的同一套规则演进状态；不会把 `tool_requested` 解释成“现在执行工具”。`unknown` 仍保留为 `unknown`，阻塞状态不会因为重建而自动解除。

Recorded 是显式调用的测试适配器。它可以返回先前保存的工具提议，但不替宿主推进 Run。不要把使用 Recorded 的新一轮执行称为无副作用的历史重建。

## 2. 运行完整演示并检查证据

在项目根目录执行：

```sh
./scripts/postgres start
./scripts/mix setup
./scripts/mix check
./scripts/mix lab.history
```

默认输出目录为 `artifacts/week07-history`；需要重复运行时使用新的目录：

```sh
./scripts/mix lab.history --output artifacts/week07-history-second
```

本周持久演示需要 PostgreSQL。演示先生成一条包含工具调用、配对结果和最终回答的运行历史，保存已接受模型结果与 checkpoint，再启动独立 BEAM 进程只读核对。检查 `report.json` 中全量重建、checkpoint 重建、新进程 State 比较和模型/工具调用计数。所有对应调用计数必须为 0，不能只根据新进程没有打印工具日志推断没有执行。

把演示报告中的 Run ID 代入只读命令：

```sh
./scripts/mix lab.rebuild RUN_ID
./scripts/mix lab.rebuild RUN_ID --checkpoint
```

这两个命令不启动 RunServer，不消费脚本，不 claim 调度意图，也不重发工具。checkpoint 模式没有现成 checkpoint 时采用全量路径，audit 明确报告 `mode: :full`；已有最新 checkpoint 损坏时明确报错，不能悄悄换成旧 checkpoint 或全量路径来掩盖损坏。

## 3. 先用纯值验证全量与 checkpoint + tail

启动 `LAB_DATABASE_ENABLED=false ./scripts/iex`。下面只构造 Elixir 值，不调用 Mock 或文件工具。

```elixir
alias AgentSystemsLab.{Checkpoint, History}
alias AgentSystemsLab.Kernel, as: LabKernel

id = "l06-pure"
opts = [max_turns: 6]
{:ok, queued} = LabKernel.new(id, opts)
{:ok, running, [started]} = LabKernel.dispatch(queued, {:start, "审查历史事实"})
call = %{operation_id: "call-001", tool: "mock_write", arguments: %{"value" => "saved"}}
{:ok, waiting, [requested]} = LabKernel.dispatch(running, {:model_response, {:call, call}})
{:ok, observed, [result]} = LabKernel.dispatch(waiting,
  {:tool_result, "call-001", {:ok, %{"receipt" => "historical"}}})
{:ok, finished, [succeeded]} = LabKernel.dispatch(observed,
  {:model_response, {:final, "历史已核对"}})
events = [started, requested, result, succeeded]

{:ok, rebuilt} = History.rebuild(id, events, opts)
true = rebuilt == finished
prefix = Enum.take(events, 2)
tail = Enum.drop(events, 2)
{:ok, checkpoint} = Checkpoint.new(id, prefix, opts)
:ok = Checkpoint.verify(checkpoint, prefix)
{:ok, resumed_projection} = History.from_checkpoint(checkpoint, tail)
true = resumed_projection == rebuilt
```

checkpoint 位于 `waiting_tool`，但后续只应用保存的 `tool_result_recorded`。没有执行 `mock_write`。`max_turns` 是原始 Kernel 配置，必须与生成历史时一致；仅有 Event 列表不足以自动推导所有配置。checkpoint 的精确字段为 `schema_version`、`run_id`、`last_seq`、`max_turns`、`state`、`history_sha256` 与 `state_sha256`，绑定前缀与状态的 hash。

`History.from_checkpoint/2` 只看到 checkpoint 和 tail。调用方必须已经信任或独立核对 checkpoint；自己重新计算一份伪造 State 的 hash 不能让它成为可信历史。数据库路径会重新读取并严格核对完整前缀，因此本阶段 checkpoint 提供验证边界，不承诺减少冷启动读取量或回放成本。

## 4. 故意制造无法重建的历史

在同一 IEx 中逐个试验，每次从原 `events` 开始：

```elixir
assert_error = fn result ->
  true = match?({:error, _}, result)
  result
end

# 缺口、重复、乱序、Run 不匹配都不能被排序或去重掩盖。
assert_error.(History.rebuild(id, [started, result, succeeded], opts))
assert_error.(History.rebuild(id, [started, requested, requested, result, succeeded], opts))
assert_error.(History.rebuild(id, [requested, started, result, succeeded], opts))
assert_error.(History.rebuild("other-run", events, opts))

# 版本是精确协议值，未知版本不会按“最新兼容”处理。
future_event = %{requested | schema_version: 2}
assert_error.(History.rebuild(id, [started, future_event, result, succeeded], opts))
future_checkpoint = Map.put(checkpoint, :schema_version, 2)
assert_error.(Checkpoint.verify(future_checkpoint, prefix))

# 修改前缀后，旧 checkpoint 不能继续作为该前缀的证明。
changed_started = put_in(started.data.input, "已经修改输入")
assert_error.(Checkpoint.verify(checkpoint, [changed_started, requested]))
assert_error.(History.from_checkpoint(checkpoint, [succeeded]))
```

另做三项破坏：把工具回执内的调用 ID 改成其他 ID；在终态之后追加 Event；给 checkpoint 增加未知字段或修改 `last_seq`。报告应保存具体错误与原值未变化的证据。未来 Event、checkpoint、模型录制、Codec 版本各有自己的验证入口；支持其中一个版本不能替代另一个版本检查。当前没有自动迁移器，不能把 `schema_version` 改回 1 冒充迁移。

hash 用于发现数据损坏、来源替换和绑定不一致，不是带密钥签名。若有人能一致地重写完整权威历史、状态和所有 hash，本实验没有外部可信锚点证明原始事实。

## 5. 持久 checkpoint 与提交边界

PostgreSQL 保存 checkpoint 时，必须使用当前 Run ID 和 expected sequence。事务锁定 Run，读取并校验已有历史和投影，再保存 checkpoint；陈旧 writer 不能把旧状态发布为当前 checkpoint。读取核对行元数据、版本、完整前缀 hash 与 State，全量重建和 checkpoint + tail 必须逐值相等。

在 `./scripts/iex` 中用独立 Run 做一个有非空 tail 的例子：

```elixir
alias AgentSystemsLab.{CheckpointStore, Storage}
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
stored_id = "l06-stored-#{suffix}"
{:ok, first} = Storage.create_run(stored_id, "保存历史再只读核对", max_turns: 6)
{:ok, captured} = CheckpointStore.create(stored_id, first.state.seq)
{:ok, final} = Storage.dispatch(stored_id, first.state.seq,
  {:model_response, {:final, "已接受的事实"}})
{:ok, loaded_checkpoint} = CheckpointStore.load(captured.id)
true = loaded_checkpoint.checkpoint.state == first.state
{:ok, full} = CheckpointStore.rebuild(stored_id, mode: :full)
{:ok, checked} = CheckpointStore.rebuild(stored_id, mode: :checkpoint)
true = full.state == checked.state and checked.state == final.state
:checkpoint = checked.audit.mode
1 = checked.audit.verified_prefix_events
1 = checked.audit.replayed_tail_events
{:error, {:stale_sequence, _, _}} = CheckpointStore.create(stored_id, first.state.seq)
```

`CheckpointStore.latest(run_id)` 返回 `{:ok, wrapper}`，没有 checkpoint 时为 `{:ok, nil}`；wrapper 含 `id`、`run_id`、`last_seq` 和 `checkpoint`。同一 Run/序号重复创建报 `checkpoint_already_exists`，不覆盖原值。上面的 `Storage.dispatch` 只写事实，故意不传模型录制选项；正常 RunServer 接受的模型响应由 Runtime 自动录制，下一节验证这条路径。

对创建 checkpoint 的 `hook: fn stage -> ... end` 运行两次真实进程 kill 探针，阶段分别为 `:before_commit` 和 `:after_commit`。模型结果录制使用 `Storage.dispatch/4` 已有的相同故障注入边界，与新业务状态、Event 和调度意图处于同一事务。

| 崩溃点 | 应能读取的事实 | 不应据此推断 |
| --- | --- | --- |
| checkpoint COMMIT 前 | 不存在本次 checkpoint，原 Run/Event 不变 | 不能说 checkpoint 已发布 |
| checkpoint COMMIT 后、ACK 前 | checkpoint 已存在且可验证 | caller 未收到 ACK 不代表未提交 |
| 模型响应事务 COMMIT 前 | 原 Run/Event/意图，输入 capture 可已存在；无本次录制 | 输入已保存不代表结果已接受 |
| 模型响应事务 COMMIT 后、ACK 前 | 新 Run/Event/意图与完整录制同时存在 | 未收到 ACK 不能据此重发模型或工具 |

不要用一个外层回滚事务代替这些测试。外层事务会移动真正的 COMMIT 边界；本项目写 API 拒绝外层嵌套事务，保证 ACK 语义仍然清楚。checkpoint 不删除旧 Event，也不承担 RunServer 的 Provider cursor、Streaming、运行时预算或文件效果台账恢复。

## 6. 模型录制究竟绑定了什么

输入 capture 发生在 Provider 启动前，保存当时 Session、Run、宿主权限、payload 与 manifest。新的模型录制发生在完整响应通过协议、预算与 Kernel 校验后，与接受该响应的 Run/Event/下一调度意图一起提交。

录制封装保存版本、Run/输入序号、Context 绑定、Provider 标签、精确输入 hash、完整响应及其 hash。读取时，ModelResultStore 同时核对 ContextStore 的原始输入和实际接受的 Event：工具提议对应 `tool_requested`，最终文本对应 `run_succeeded`。只检查响应 hash 而不检查 Event，会把没有被接受的候选误当成事实。

以下内容不是可复用模型录制：尚未完成的流式片段、取消后迟到的候选、Provider 错误、未通过预算或配对校验的响应。这里记录的是已接受结果，不宣称捕获所有模型尝试、网络重试、token 使用或厂商原始流。Provider 标签是审计元数据，不是厂商身份认证。

内存模式保留旧 Mock 的临时值兼容性：合法工具参数 Map 中可以含 PID、reference、函数或任意 struct，接受转换不会因此被新增录制能力拒绝。这类值不满足 inert 录制条件，不生成无效 recording；snapshot 的 `recording_errors` 条目为 `%{input_seq: ..., event_seq: ..., reason: {:invalid_recording_payload, detail}}`，明确标记不可录制。普通 inert 完整结果照常录制；PostgreSQL 路径继续严格拒绝无法持久化的临时值，不为兼容性放宽 Codec。

Recorded 适配器必须由宿主明确构造。向它提供与录制不同的 payload，哪怕只改一条消息、一个权限值或工具回执，也应得到输入不匹配错误；不能忽略 run_id 或靠提示词相似度选录制。读取录制、校验录制与 History 重建均不执行 Provider。只有显式调用 Recorded 才返回保存的模型响应；如果宿主把这个响应继续交给正常 Runtime，仍应重新执行 schema、预算和工具权限检查。

在演示 Run 上读取 `ModelResultStore.list(run_id)`，逐条查看对应 `context_id` 和响应 Event 序号。下面的例子可独立在 `./scripts/iex` 执行，创建正常 PostgreSQL Runtime；`recorded` 之后的操作都是只读核对和纯适配器调用。

```elixir
alias AgentSystemsLab.{ContextStore, ModelResultStore, Recording, RunServer}
alias AgentSystemsLab.Providers.Recorded
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
recorded_id = "l06-recorded-#{suffix}"
{:ok, server} = AgentSystemsLab.start_run(run_id: recorded_id, storage: :postgres,
  input: "返回固定离线回答", script: [{:final, "已保存回答"}],
  run_timeout_ms: 600_000, model_timeout_ms: 300_000)
{:ok, done} = RunServer.step(server)
:succeeded = done.state.status
:ok = GenServer.stop(server)

{:ok, [saved]} = ModelResultStore.list(recorded_id)
{:ok, capture} = ContextStore.load(saved.context_id)
:ok = Recording.verify(saved.record, capture.context)
{:ok, adapter} = Recorded.new([saved.record])
{:ok, {:final, "已保存回答"}, consumed} = Recorded.respond(capture.context, adapter)
1 = consumed.cursor
changed_input = Map.put(capture.context, :input, "换了任务")
{:error, :recorded_input_mismatch, ^adapter} = Recorded.respond(changed_input, adapter)

future_record = %{saved.record | schema_version: 2}
{:error, {:unsupported_model_schema_version, 2}} = Recording.validate(future_record)
changed_response = %{saved.record | response: {:final, "伪造回答"}}
{:error, :recorded_response_mismatch} = Recording.validate(changed_response)
```

Recorded 不按提示词相似度选择录制；不匹配时 cursor 与 requests 保持原值。封装的 `version: 1` 是录制格式版本，`schema_version: 1` 是响应协议版本；与 Codec 版本分别检查。适配器不是把完整执行历史变成“任意输入都可复用”的缓存。

## 7. 新进程重建与验收

`lab.history` 的独立 VM 核对必须满足：

1. 不复用原 RunServer PID、进程字典、Provider cursor、Mock 台账或 ETS 缓存。
2. 从 PostgreSQL 读取已提交 Event、Context、录制和 checkpoint，安全解码后逐项校验。
3. 父进程将原 State 通过 safe Codec 编码传给子进程；子进程在 trace 审计范围内用 `===` 直接核对全量 State、checkpoint State 与解码后的 expected State，再返回比较布尔值与 hash。比较涵盖所有 operations、调用 ID、结果与终态原因，不能仅以 hash 相等代替这一步。
4. 对 Provider `respond`/`stream` 和工具 Gateway/Mock/Files 的相关入口计数；重建期间每项为 0。
5. 未知版本、损坏前缀/状态/元数据、录制响应与 Event 不匹配时失败，不自动调用模型修复，不执行工具补偿。

safe ETF 只接受已加载的可信模块词汇和 inert 值。遇到未加载词汇应修复已安装模块的加载路径；不要去掉 `[:safe, :used]`，不要执行录制中的源码，也不要把错误变成不受限解码。任意用户 atom 跨独立 VM 仍不可移植；用户数据继续优先使用字符串键和值。

完整运行 `./scripts/mix check`，并保存本周报告。评分建议：历史顺序/版本与状态核对 25 分，checkpoint 前缀与 tail 校验 20 分，模型录制的输入/Event 绑定 20 分，真实提交边界 15 分，新进程零执行证明 15 分，明确能力边界 5 分。任一重建路径执行模型或工具，或 silently 接受未知版本，均不算完成。

参考解答见 [L06 解答](solutions/L06.md)，实际测试计数、演示产物和新进程结果见 [第 7 周验收记录](../docs/validation-week07.md)。

## W22 试读修订：版本现状与旧周次边界

本实验正文保留 W7 的交付边界。当前 W21 已增加显式 `HistoryMigration` 和独立 `history_format` 1→2；业务 Event schema 与 Codec 仍为 1。不要把早期“没有迁移器”理解为当前仍无迁移能力。升级的成功、拒绝、原生备份还原和复制 lease fencing 见 [L20](L20-history-migration-backup-restore.md)，跨环境复现见 [L21](L21-reader-study-and-clean-reproduction.md)。checkpoint 仍验证完整前缀，不承诺跳过旧事件或减少本实验的读取成本；rebuild 只重建，resume 才可能执行模型和工具。
