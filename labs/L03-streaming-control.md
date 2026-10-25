# L03：流还没结束，谁能让任务停下来

对应计划第 4 周。建议实验时间 8—12 小时，分三次完成。前置知识为 L01、L02、GenServer 普通消息、进程监控与单调时钟。

实验册按实际交付编号：本周新增流与控制实验使用 L03；原研究计划第 5 周的工具实验后续另册交付，编号顺延，不改变其阶段目标。

完成后，你应能证明：模型逐帧输出期间，Runtime 仍能响应状态读取和取消；完整校验前的工具参数不能产生操作或效果；预算耗尽会留下可解释的失败事实；实时片段与 PostgreSQL 中的业务 Event 各自承担不同职责。

本实验用 Scripted Provider 驱动真正的逐帧工作进程，不调用真实模型，无需 API 密钥。这里实现的是 Provider 通用协议；厂商 HTTP/SSE 协议、远程计费与远程取消需后续适配。

## 1. 先写下两条时间线

新建 `notes/L03-report.md`，阅读 [ADR 0003](../docs/adr/0003-streaming-cancellation-and-budgets.md)，画出：

1. 工作进程生成片段 → Runtime 接收与校验 → 订阅者看到实时通知。
2. 完整响应被接受 → Kernel Event → Run、Event、意图的事务提交。

标出取消、输出超限、模型超时可以发生的位置。先预测下表，运行后填写实际观察与测试证据。

| 观察点 | Run 状态 | 已接受的模型轮数 | 业务操作数 | Mock 效果数 |
| --- | --- | ---: | ---: | ---: |
| 文本已到一半，还没 `:done` | ? | ? | ? | ? |
| 工具参数只到半截 JSON | ? | ? | ? | ? |
| 完整工具响应刚被接受 | ? | ? | ? | ? |
| 执行下一次工具 `step` 后 | ? | ? | ? | ? |
| 半截 JSON 时取消成功 | ? | ? | ? | ? |
| 已产生工具效果后取消 | ? | ? | ? | ? |

不变量至少包含：完整且合法的响应才可进入 Kernel；一轮至多接受一个响应；终态不会被迟到帧改写；流通知序号与业务 Event 序号各自连续；取消不撤销已发生的工具效果。

## 2. 准备环境与观察工具

在项目根目录运行：

```sh
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL ./scripts/mix check
./scripts/mix lab.stream
./scripts/mix lab.stream --cancel
./scripts/mix lab.stream --budget
./scripts/iex
```

如果运行时或数据库尚未安装，先按 README 准备。本页后续命令在同一终端继续；新开终端时先重新执行两条 `export`。完整验收需要真实 PostgreSQL，后台 Scheduler 保持关闭。只做第 3—6 节内存练习时，可跳过数据库启动与 setup，先执行 `export LAB_SCHEDULER_ENABLED=false`，再用 `LAB_DATABASE_ENABLED=false ./scripts/iex`；第 7 节另用启用数据库的会话。数据库目标、配置和可丢弃数据的要求沿用 L02。

在同一 IEx 会话定义这些辅助函数：

```elixir
alias AgentSystemsLab.{RunServer, Repo, Storage}
alias AgentSystemsLab.Kernel, as: LabKernel

new_id = fn prefix ->
  "#{prefix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
end

collect = fn collect, run_id, request_ref, acc ->
  receive do
    {:agent_stream, ^run_id, ^request_ref, seq, event} ->
      next = [{seq, event} | acc]
      case event do
        {:finished, _status} -> Enum.reverse(next)
        _ -> collect.(collect, run_id, request_ref, next)
      end
  after
    5_000 -> raise "没有收到本轮 finished；检查请求引用、预算和工作进程"
  end
end

await_gate = fn gate_ref ->
  receive do
    {:scripted_gate, ^gate_ref, worker} -> worker
  after
    5_000 -> raise "没有到达 Scripted 屏障"
  end
end
```

`collect` 只收指定 Run 与请求引用的消息。不要把其他 Run 的消息、上一次请求的 `finished` 或屏障通知误认为本轮输出。订阅只发未来消息，所以先订阅再开始；它不是历史回放接口。

## 3. 接收第一条文本流

```elixir
id = new_id.("l03-text")
{:ok, server} = AgentSystemsLab.start_run(
  run_id: id,
  input: "输出两段文本",
  script: [{:stream, [{:text_delta, "hello "}, {:text_delta, "world"}, :done]}]
)

:ok = RunServer.subscribe(server)
{:ok, request_ref} = RunServer.start_stream(server)
notifications = collect.(collect, id, request_ref, [])
Enum.map(notifications, fn {_seq, event} -> event end)
# => [:started, {:text_delta, "hello "}, {:text_delta, "world"},
#     :done, {:finished, :succeeded}]

finished = RunServer.snapshot(server)
{finished.state.status, finished.state.output, finished.state.turn_count}
# => {:succeeded, "hello world", 1}
Enum.map(finished.events, & &1.type)
# => [:run_started, :run_succeeded]

{:ok, rebuilt} = LabKernel.rebuild(id, finished.events,
  max_turns: finished.state.max_turns)
rebuilt == finished.state
# => true
GenServer.stop(server)
```

比较两条序列：实时通知有多个条目，业务 Event 只追加一个 `run_succeeded`。文本片段不是一轮轮模型回答，也不消耗一个个模型轮数。`snapshot.stream.request_id` 保留最近一轮引用，是否仍在执行看 `active?`；快照只保留最近 128 条流通知，完整业务历史仍看 `snapshot.events`。

独立任务：把一条中文字符串拆在 UTF-8 字符的字节中间，验证最终文本能正确重组；让最终字节仍无效，断言其失败原因为 `{:provider_error, {:invalid_stream, :invalid_text_utf8}}`。旧完整响应保留 L01 的 binary 契约，不额外施加 UTF-8 限制。旧脚本 `[{:final, "done"}]` 也必须继续通过 `step/1` 和 `run_until_pause/1` 工作。先阅读 Provider 测试，再写自己的边界断言。

## 4. 在半截工具 JSON 处停住

这次使用明确屏障；收到通知后，工作进程才确定已经停在半截参数的位置。不要用 `Process.sleep/1` 猜测时机。为了给人工观察留出时间，这组交互练习将单轮时限放宽到 5 分钟、Run 时限放宽到 10 分钟；第 5、7 节沿用相同选项。默认时限仍是 5 秒和 60 秒，预算测试另设较短窗口。

```elixir
id = new_id.("l03-tool")
gate_ref = make_ref()
frames = [
  {:tool_start, %{operation_id: "draft-001", tool: "mock_write"}},
  {:arguments_delta, "{\"key\":\"draft.txt\","},
  {:gate, self(), gate_ref},
  {:arguments_delta, "\"value\":\"hello\"}"},
  :done
]

{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "模拟保存草稿",
  model_timeout_ms: 300_000, run_timeout_ms: 600_000,
  script: [{:stream, frames}, {:final, "草稿完成"}]
)
:ok = RunServer.subscribe(server)
{:ok, request_ref} = RunServer.start_stream(server)
worker = await_gate.(gate_ref)

partial = RunServer.snapshot(server)
{partial.state.status, partial.state.turn_count,
 map_size(partial.state.operations), partial.tool_stats.effects}
# => {:running, 0, 0, 0}
partial.stream.active?
# => true
Enum.map(partial.events, & &1.type)
# => [:run_started]

send(worker, {:release, gate_ref})
notifications = collect.(collect, id, request_ref, [])
planned = RunServer.snapshot(server)
{planned.state.status, planned.state.pending_operation_id, planned.tool_stats.effects}
# => {:waiting_tool, "draft-001", 0}
planned.state.operations["draft-001"].arguments
# => %{"key" => "draft.txt", "value" => "hello"}

{:ok, after_tool} = RunServer.step(server)
{after_tool.state.status, after_tool.tool_stats}
# => {:running, %{requests: 1, effects: 1}}
{:ok, finished} = RunServer.step(server)
{finished.state.status, finished.state.output, finished.tool_stats.effects}
# => {:succeeded, "草稿完成", 1}
GenServer.stop(server)
```

`start_stream/1` 只启动模型请求。工具完整提议被接受后，它不会自动执行工具；后一次 `step/1` 是单独的效果边界。`step/1` 等待一轮模型请求结束，但 RunServer 的回调没有阻塞，所以其他进程仍可调用 `snapshot/1` 和 `cancel/2`。

独立补齐以下反例：缺少 `:done`、JSON 未闭合、JSON 是数组而非对象、先传参数后声明工具、一轮混合文本与工具、第二个 `tool_start`、`:done` 后继续输出。要求每种失败都没有接受工具提议，`operations` 为空，Mock 的 requests 和 effects 均为 0。不要只断言“返回了某种错误”。

## 5. 运行中取消与迟到消息

重新建立一条工具流，把屏障仍放在半截 JSON 后。为了完整演示，将上节从 `id = ...` 到 `worker = await_gate.(gate_ref)` 的代码重新运行一次，换一个全新 Run ID；不运行释放屏障或后续 `step`。

```elixir
worker_monitor = Process.monitor(worker)
before_cancel = RunServer.snapshot(server)
{:ok, cancelled} = RunServer.cancel(server, "learner_requested")
{cancelled.state.status, cancelled.state.terminal_reason,
 map_size(cancelled.state.operations), cancelled.tool_stats.effects}
# => {:cancelled, "learner_requested", 0, 0}

receive do
  {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :worker_stopped
after
  5_000 -> raise "取消后工作进程仍未结束"
end

notifications = collect.(collect, id, request_ref, [])
List.last(notifications) |> elem(1)
# => {:finished, :cancelled}

send(worker, {:release, gate_ref})
after_late_release = RunServer.snapshot(server)
after_late_release.state == cancelled.state
# => true
after_late_release.events == cancelled.events
# => true
RunServer.step(server)
# => {:error, {:not_runnable, :cancelled}}
RunServer.cancel(server, "again")
# => {:error, ...}，终态保护
```

给已停止 worker 发送释放消息，证明取消后旧 fixture 无法继续生产；它还不能独立证明 Runtime 能拒绝旧请求的帧。保持这个 RunServer 存活，用内部协议补一条拒绝断言：

```elixir
GenServer.call(server, {:stream_frame, request_ref, worker, {:text_delta, "late"}})
# => {:error, :stale_request}
send(server, {:model_timeout, request_ref})
after_stale = RunServer.snapshot(server)
{after_stale.state == cancelled.state, after_stale.events == cancelled.events,
 after_stale.tool_stats == cancelled.tool_stats}
# => {true, true, true}
GenServer.stop(server)
```

同步调用明确进入帧身份检查，后一个同步快照作为旧 timer 的处理屏障。当前协议还核对调用者 PID 必须为活动 worker；独立编写一条“引用与 worker 字段正确，但调用者 PID 不同”的拒绝测试。内部元组仅用于这项故障实验，不是调用者提交模型响应的公共 API。

再在一个独立调用进程中运行 `step/1`，主测试进程等到 gate 后取消，验证等待 `step` 的调用者也能结束。仅测试 `start_stream/1` 立即返回，不能证明同步调用者在取消时得到正确回复。

最后故意让 Mock 先产生一次效果，再取消非终态 Run：取消后 effects 仍应为 1，原操作和结果仍可检查。用 `mock_response: :lost` 重做，使任务在 `blocked` 时取消；解释为什么“任务已取消”不能推出“原工具没有执行”。本周模型调用支持运行中控制，短时同步 Mock 调用不代表任意真实慢工具也能即时取消。

## 6. 对每种预算做边界实验

默认配置与失败原因见 [ADR 0003](../docs/adr/0003-streaming-cancellation-and-budgets.md#预算契约)。预算选项直接传给 `AgentSystemsLab.start_run/1`。查看 `snapshot.budget` 和 `snapshot.stream.output_bytes`，同时检查 `state.terminal_reason`，不要只观察 CLI 是否退出。

先观察字节预算：`"你好"` 是 6 个 UTF-8 字节。

```elixir
id = new_id.("l03-bytes")
{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "触发输出预算", max_output_bytes: 5,
  script: [{:stream, [{:text_delta, "你"}, {:text_delta, "好"}, :done]}]
)
{:ok, failed} = RunServer.step(server)
{failed.state.status, failed.state.terminal_reason, failed.state.turn_count}
# => {:failed, {:budget_exceeded, :output_bytes}, 0}
failed.tool_stats
# => %{requests: 0, effects: 0}
GenServer.stop(server)
```

将 `max_output_bytes` 改为 6，同一文本应成功。再拆成不同大小的片段，字节预算结果应相同。总输出预算按 Run 进程累计，不能在每次模型调用开始时重置。设计两轮工具交互，使每轮单独都没超过限额、累计却超过，确认第二轮在接受响应前失败。工具声明的 operation_id 与工具名称同样计入字节；旧完整工具响应的参数按 ETF 序列化字节计量，流式参数按实际 JSON 分片字节计量，报告需写明所用表示。

完成以下实验矩阵，每项至少保留一条恰好达到上限和一条超过上限的测试；时间预算改为“完成早于截止”与“gate 持续等待直到截止”。

| 预算 | 最小反例 | 必查证据 |
| --- | --- | --- |
| `max_output_bytes` | UTF-8 文本、工具参数和跨轮累计超限 | 没有接受半个响应，原因是 `:output_bytes` |
| `max_stream_events` | 大量很小的片段，总字节仍很少 | 原因是 `:stream_events`，不是字节超限 |
| `max_tool_calls` | 第一项工具已完成，第二项工具提议超限 | 第二项操作没有被接受，第二项效果没有发生 |
| `max_turns` | 工具完成后已无模型轮数 | 保留原原因 `:turn_budget_exceeded`，没有发起下一轮请求 |
| `model_timeout_ms` | 单轮停在 gate，不释放 | 原因是 `:model_timeout`，工作进程停止 |
| `run_timeout_ms` | Run 的总截止先于单轮截止 | 原因是 `:run_timeout`，没有继续推进 |

单轮流帧计数不包含 `:started`、`finished` 或 Scripted 的 gate 控制项。一个 `:done` 也是流帧；旧完整响应是一个适配帧。切分数据能改变帧数量，却不能减少输出字节成本。

模型时限是整轮时限，收到新片段不续期。Run 总时限从本进程启动开始，包含等待人工 `step` 的时间。用比被测时限明显更长的另一项时限，避免两个 timer 的胜负掩盖目标断言。测试以 `assert_receive` 等待具体 finished 与 worker DOWN，在宽松截止时间内断言；不要要求它在精确某一毫秒发生，也不要用 sleep 证明到达了业务边界。

预算与取消的终态具有先后竞争：已经被接受的成功不能被迟到 timer 改成失败，已经失败或取消的流不能被迟到 `:done` 改成成功。另写至少一条旧请求 timer 在下一轮活动时到达的反例，证明消息身份被校验。

## 7. 在 PostgreSQL 中核对接受边界

若前面使用关闭 Repo 的内存会话，先退出 IEx；完成第 2 节数据库准备后，在 shell 用 `LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/iex` 新开会话，并重新定义第 2 节的 alias 和辅助函数。

重复第 4 节的 gate 练习，使用新 ID，并在 `start_run` 选项中加入 `storage: :postgres`。在屏障处运行：

```elixir
partial = RunServer.snapshot(server)
{:ok, saved_before} = Storage.load(id)
{saved_before.state == partial.state, saved_before.events == partial.events,
 saved_before.intent.kind}
# => {true, true, "model"}

Repo.query!("SELECT seq, type FROM lab_events WHERE run_id = $1 ORDER BY seq", [id]).rows
# => [[1, "run_started"]]
Repo.query!("SELECT seq, kind, status FROM lab_intents WHERE run_id = $1 ORDER BY seq", [id]).rows
# => [[1, "model", "pending"]]
```

看到若干实时通知，数据库依然只有已接受的 `run_started`。在 gate 处取消，再查询：

```elixir
{:ok, cancelled} = RunServer.cancel(server, "database_exercise")
{:ok, saved_after} = Storage.load(id)
{saved_after.state == cancelled.state, saved_after.events == cancelled.events,
 saved_after.intent}
# => {true, true, nil}
Repo.query!("SELECT seq, type FROM lab_events WHERE run_id = $1 ORDER BY seq", [id]).rows
# => [[1, "run_started"], [2, "run_cancelled"]]
Repo.query!("SELECT seq, kind, status FROM lab_intents WHERE run_id = $1 ORDER BY seq", [id]).rows
# => [[1, "model", "superseded"]]

{:ok, rebuilt} = LabKernel.rebuild(id, saved_after.events,
  max_turns: saved_after.state.max_turns)
rebuilt == saved_after.state
# => true
GenServer.stop(server)
```

再各做一次完整文本成功和字节预算失败，检查持久快照、事件重建和没有 pending 意图。给工具成功路径核对 `model → tool → model` 的意图版本变化。原 L02 的提交前/后崩溃测试也必须继续通过；流能力不改变那条事务边界。

独立任务：在另一进程把同一 Run 推进到新序号后，再让旧 RunServer 提交一轮响应。它必须得到版本冲突，不能发布未提交的新状态；检查 Provider 游标与数据库事实的行为，并解释为何“流已经显示”不是“业务响应已经提交”。再让数据库先取消一个 `waiting_tool` Run，旧 RunServer 的 `step` 应拒绝执行且 effects 保持 0。这里的执行前检查只能拒绝已知陈旧状态，不能消除读状态与外部效果之间的竞争；它仍不是 lease 或 fencing。

Runtime 的输出计数、定时器、活动请求和缓存不是持久 checkpoint。退出 BEAM 后可以读取已提交 Run，却不能续接半条流或恢复该进程的预算消费；更不能据此自动重发未知外部工具。当前仍没有安全自动续跑接口。

## 8. 破坏实现，再验证保护测试

先保存可通过的独立测试，每次只临时引入一种缺陷。看见预期失败后恢复实现，并运行完整验收。至少实际完成下表两项。

| 临时破坏 | 应出现的失败证据 |
| --- | --- |
| 在 GenServer 回调里阻塞消费完整模型流 | gate 未释放时，snapshot 或 cancel 无法在截止前返回 |
| 收到 `tool_start` 就创建操作 | 半截 JSON 时 `operations` 已非空，或工具已执行 |
| 每轮开始重置总输出字节 | 两轮累计超限的保护测试错误地成功 |
| 以字符数代替字节数 | `"你好"` 在 5 字节预算下错误地通过 |
| 去掉请求身份或终态检查 | 取消后的旧帧或旧 timer 改写状态 |
| 每次收到片段都重置模型 timer | 持续慢速输出能无限延长单轮总时限 |
| 每个 delta 都写业务 Event | SQL 中出现额外事件，或重建无法解释这些片段 |

别在报告中把“发送了一条看起来像旧消息的元组”当成覆盖：检查测试使用的实际内部消息协议，证明消息确实进入目标处理分支。也别把 worker DOWN 与远程服务已停止生成、停止计费或撤销工具效果混为一谈。

## 9. 验收与评分

运行并保留完整结果：

```sh
env -u DATABASE_URL ./scripts/mix check
./scripts/mix lab.stream
./scripts/mix lab.stream --cancel
./scripts/mix lab.stream --budget
```

交付 `notes/L03-report.md`、新增 ExUnit 测试、两条时间线、预测与观察表、SQL 证据、预算边界矩阵、至少两次破坏与修复记录。项目测试通过是起点，独立实验还需给出可复核的断言。

| 项目 | 分值 | 可复核证据 |
| --- | ---: | --- |
| 流协议与接受边界 | 20 | 文本/工具分片、UTF-8、非法响应；半截参数没有操作与效果 |
| 运行中控制 | 25 | gate 期间 snapshot、取消、同步 step 等待者、worker DOWN 与迟到消息 |
| 预算与计时 | 25 | 六种限额、等于/超过边界、跨轮累计、旧 timer 与终态保护 |
| 持久事实 | 15 | gate 前后 SQL、事务意图、事件重建、L02 崩溃回归 |
| 解释与破坏练习 | 15 | 两次预期失败，清楚说明运行时预算与外部效果边界 |

通过门槛为 80 分，同时满足四条硬性要求：取消测试用明确 gate 而非 sleep 猜时机；半截工具 JSON 不产生操作或效果；取消/超限后迟到消息不能改变终态；没有将实时片段、本进程预算或取消动作描述为持久恢复或外部效果撤销保证。未满足时先修复再验收。

独立完成后再阅读 [参考解答](solutions/L03.md)。
