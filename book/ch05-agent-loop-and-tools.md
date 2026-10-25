# 第 5 章：Agent Loop 的理论、设计与实现

本章始写于第 22 周，主题沿用原计划第 5 章。实际实验顺序已调整：状态机见 [L01](../labs/L01-state-machine.md)，Streaming 与取消见 [L03](../labs/L03-streaming-control.md)，工具与离线修复见 [L04](../labs/L04-controlled-tools.md)。原计划的实验编号不能直接当作当前文件名使用；第 6、7 章的深入内容仍可在这两册实验中先行学习。

读完后，你应能解释一次循环为什么至少有“模型请求、接受提议、执行效果、提交结果”四个边界，并能在其中停住、取消或核对。这里使用 Scripted Provider 与受控工具；固定脚本证明机制，不证明真实模型的修复能力。本轮采用多代理模拟评审，范围与实际执行证据见[修订评审记录](../docs/learning-revision-review.md)。

## 阅读准备与路线

先完成[第 2 章](ch02-agent-state-machine.md)的一条合法轨迹与一次拒绝，能解释 `waiting_tool`、`blocked`、`operation_id` 和 final 计轮。动手还需会按顺序调用进程 API、区分进程快照与纯 State；无需先会写 GenServer，也不要求先读尚未成文的第 3、4、6、7 章。缺少这些概念时用[先修桥接](prerequisites.md)和[统一术语表](glossary.md)补齐。

第一次只做到 5.3：在三个 `step` 之间观察效果数，得到一条可解释的成功轨迹。第二次再走 5.4—5.5 的 unknown 和取消；文件修复在 5.7 独立进行，不必第一次就完成整册 L03/L04。本章之后进入[第 8 章](ch08-session-context.md)，研究每次 Provider 请求究竟看到了什么。现有六章路线是 **2 → 5 → 8 → 14 → 16 → 20**，见[课程地图](../docs/course-map.md)。

| 本章词语 | 与上一章的连接 |
| --- | --- |
| Provider / 宿主 | 产出待验证响应 / 决定配置、接受与执行的程序 |
| proposal / effect / receipt | 工具提议 / 外部变化 / 对原操作结果的记录，不是同一个动作 |
| stream / event | 暂态输入片段 / 已接受的业务事实；半截参数不会成为工具意图 |

## 5.1 循环要推进事实，也要决定何时停止

最小 Agent Loop 常写成“调用模型，调用工具，再调用模型”。这条叙述隐藏了三个决定：模型回答是否合法；这次工具调用是否被授权；返回值能否归属到当前操作。循环只有在这些决定都成功后才能推进。

```text
running
  → 构造并验证本次 Context
  → 请求 Provider，收齐并验证完整响应
  → 校验工具 schema、权限和预算
  → Kernel 接受响应，记录工具意图
waiting_tool
  → 显式执行原操作
  → 校验回执身份并提交结果
running / blocked / terminal
```

最终回答消耗一轮模型预算并进入 `succeeded`。工具提议也消耗一轮；工具执行不是新的模型轮数。`run_until_pause/2` 只是一层有界驱动，它在终态或 `blocked` 停下，也可能因为步数上限返回 `:step_limit`；步数用完不能制造成功。

## 5.2 谁拥有哪部分责任

| 组件 | 拥有的责任 | 不应从它推导的结论 |
| --- | --- | --- |
| [Kernel](../lib/agent_systems_lab/kernel.ex) | 确定性转换、轮数、操作与结果配对 | 通用调用已通过文件授权 |
| [Scripted](../lib/agent_systems_lab/providers/scripted.ex) | 固定响应、游标、请求记录 | 回答已获业务接受 |
| [RunServer](../lib/agent_systems_lab/run_server.ex) | 串行决策、异步模型工作、取消与预算策略 | 进程内状态能够跨重启恢复 |
| [Gateway](../lib/agent_systems_lab/tools/gateway.ex) | 工具可用性、schema 与结果封装 | 所有远端效果都天然幂等 |
| [Files/Workspace](../lib/agent_systems_lab/tools/files.ex) | 路径边界、预期 hash、受控读写 | 能抵御同一宿主用户恶意并发改目录 |

Provider 输出是待验证输入。工具 description、历史消息和模型“我已获批准”的文字都不能增加 workspace、shell、网络或预算能力。实际权限由宿主配置产生，必要时再次由执行器强制限制。

## 5.3 把循环拆成可观察的三步

先运行不需要 PostgreSQL 的测试，再进入 IEx。`LAB_DATABASE_ENABLED=false` 只关闭 Repo；同时关闭后台调度器，示例显式使用内存 RunServer。本章后续 shell 命令沿用同一终端，新开终端时先重新设置 `LAB_SCHEDULER_ENABLED=false`。

```sh
export LAB_SCHEDULER_ENABLED=false
LAB_DATABASE_ENABLED=false ./scripts/mix test test/agent_systems_lab/run_server_test.exs test/agent_systems_lab/run_server_files_test.exs test/agent_systems_lab/run_server_stream_test.exs
LAB_DATABASE_ENABLED=false ./scripts/iex
```

在同一个 IEx 会话执行：

**第一次小练习：停在“提议已接受”。** 运行到 `planned` 的四个断言后先停下，不调用第二次 `step`。预测报告是否已经写入、下一步会增加哪个计数。提示：`tool_requested` 表示 Kernel 接受意图，不能证明工具执行。可验证结果应为 `waiting_tool`、Provider 游标 1、`requests=0`、`effects=0`；再执行第二步后才会看到 `requests=1`、`effects=1`。这就是本次小练习的完成点，第三步的 final 用来收尾。

```elixir
alias AgentSystemsLab.{Demo, RunServer}
id = "ch05-#{System.unique_integer([:positive])}"
{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "记录报告", storage: :memory,
  run_timeout_ms: 600_000, script: Demo.script())

{:ok, planned} = RunServer.step(server)
true = planned.state.status == :waiting_tool
true = planned.provider.cursor == 1
true = planned.tool_stats == %{requests: 0, effects: 0}
true = List.last(planned.events).type == :tool_requested

{:ok, received} = RunServer.step(server)
true = received.state.status == :running
true = received.tool_stats == %{requests: 1, effects: 1}
true = received.state.operations["write-report-1"].status == :ok

{:ok, done} = RunServer.step(server)
true = done.state.status == :succeeded
true = done.state.turn_count == 2
true = done.provider.cursor == 2
:ok = GenServer.stop(server)
```

第一步只有工具提议，没有效果；第二步才执行工具；第三步接受最终回答。把这三个观察点画成时间线，标出取消发生在第一步后和第二步后的差别。取消前已确认的效果仍留在 operations 中。

交互练习将 Run 总时限放宽到 10 分钟，给逐段观察留出时间；默认仍是 60 秒，且从进程启动时计时，包含等待人工 `step` 的时间。若练习期间已到截止，应使用新 Run 重新观察，并保留这次超时结果。

这里的工具是 Mock 进程。其请求数和效果数是独立事实：同一 operation ID 可收到多次请求，但参数相同才可复用原结果，效果数不能随重投增长。ID 冲突不是新任务，不能悄悄换参数继续。

## 5.4 未知结果让循环停在可解释的位置

使用新的 Run，模拟效果成功但响应丢失：

```elixir
id = "ch05-lost-#{System.unique_integer([:positive])}"
{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "核对报告", storage: :memory,
  run_timeout_ms: 600_000, script: Demo.script(), mock_response: :lost)
{:ok, paused} = RunServer.run_until_pause(server)
true = paused.state.status == :blocked
true = paused.tool_stats == %{requests: 1, effects: 1}
true = paused.provider.cursor == 1
{:error, :reconciliation_required} = RunServer.step(server)
{:ok, _} = RunServer.reconcile_from_mock(server)
{:ok, done} = RunServer.run_until_pause(server)
true = done.state.status == :succeeded
true = done.tool_stats.effects == 1
:ok = GenServer.stop(server)
```

核对通过 Mock 的原台账完成，没有重做效果。无法查询的非幂等工具不能照抄这个自动核对路径；仍要继续的任务必须等待可信证据，不能将等待超时解释成失败后换 ID 重试。[L08](../labs/L08-retries-and-reconciliation.md) 专门区分错误分类、有限重试和模糊效果。

也可以显式取消 `blocked` 的任务，但当前 Kernel 会保留 unknown 操作并进入终态，随后拒绝这个 Run 的 `reconcile`。这代表停止推进，不代表效果已查清；宿主若需要后续调查，必须另行保留和处理未决账目。完整反例见[第 2 章的两条分支](ch02-agent-state-machine.md#24-结果未知为什么要成为业务状态)。

## 5.5 模型流并不是业务事件流

模型工作放在 Task.Supervisor 下，RunServer 接收逐帧确认并保持状态读取、取消可响应。文本 delta 或半截 JSON 是暂态输入；只有完整、合法且在预算内的响应才进入 Kernel。RunServer 快照只保留最近一段有界流通知，完整业务事件另存。

下面改为 shell 命令。若仍在 IEx，可输入 `System.halt()` 返回 shell；不要把 `LAB_DATABASE_ENABLED=...` 当作 Elixir 代码粘贴。

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.stream
LAB_DATABASE_ENABLED=false ./scripts/mix lab.stream --cancel
LAB_DATABASE_ENABLED=false ./scripts/mix lab.stream --budget
```

这三个命令分别演示正常完成、在半截工具参数屏障取消、输出字节超限。它们没有 `--output` 参数，日志应由实验记录另行保存。预期取消与超限路径都没有 Mock 效果；不能仅根据没有最终回答推断效果数为零，必须检查打印的 requests/effects。

在 [L03](../labs/L03-streaming-control.md) 中使用显式 gate 到达半截参数位置。不要用固定 `sleep` 代替同步，否则测试可能在调用完成后才取消。未知工具、第二个 tool_start、未闭合 JSON、缺少 done 都应在效果边界之前拒绝。

## 5.6 工具 schema 与结果配对是两个检查点

[Catalog](../lib/agent_systems_lab/tools/catalog.ex) 校验当前工具名称与参数形状。文件工具使用字符串键的闭合参数对象；额外字段也会被拒绝。schema 通过后，文件层仍要拒绝绝对路径、`..`、受阻组件、符号/硬链接等越界路径。

写入和补丁使用 `expected_sha256` 对照当前文件版本；新文件才可使用 `"absent"`。补丁的每条 old 文本必须唯一匹配，所有 edits 先在内存验证，失败不会留下“前半份补丁”。不要通过删去 hash 检查来解决版本冲突。

当前受控工具结果由 [Result](../lib/agent_systems_lab/tools/result.ex) 封装为带 `type: "tool_result.v1"`、operation ID、tool 和 output 的值。Kernel 校验显式封装，Runtime 对当前文件调用要求配对封装；历史中原有 opaque v1 结果的兼容读取不等于允许新文件调用绕过校验。

## 5.7 完成一次可审查的离线修复

下面建立全新父目录，真正的输出子目录尚不存在。重复实验会取得新目录，不会要求删除旧证据。

```sh
mkdir -p artifacts
chapter_dir="$(mktemp -d artifacts/ch05-reader-XXXXXX)"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.repair --output "$chapter_dir/repair"
cat "$chapter_dir/repair/report.json"
cat "$chapter_dir/repair/repair.diff"
```

演练对固定配送费 fixture 进行读取、把 `subtotal > 100` 修成 `subtotal >= 100`、新建说明，再接受最终回答。查看输出中的前后验收退出码：`2 → 0`，以及 `requests=3, reads=1, writes=2`。四轮模型决策包括最终回答；不能把三次工具调用当成三轮总预算。

[Repair](../lib/agent_systems_lab/repair.ex) 的可信宿主驱动只执行仓库固定验收程序，并先逐字节检查允许的源码与测试。模型工具本身没有 shell 能力。这个小实验没有开放执行任意模型生成程序；更强进程边界属于 [L14](../labs/L14-isolated-execution.md)。

`repair.diff`、前后日志、`events.bin` 和 workspace 一起构成证据。diff 说明改了什么，回执说明哪次调用确认了什么，固定验收说明边界样例是否通过；单独一份 diff 不能替代权限或执行记录。

## 5.8 预算与持久恢复的接缝

[Budget](../lib/agent_systems_lab/budget.ex) 限制输出字节、单请求帧数、工具次数和时限；它是 RunServer 的进程内控制。输出字节跨请求累计，帧数每次请求重置。ETF（Erlang External Term Format，本地值编码）字节、模型 token 和货币费用是不同度量，见[术语表](glossary.md#会话与历史)。

Kernel 轮数耗尽只拒绝下一条模型响应；RunServer 会在额外 Provider 请求之前记录 `:turn_budget_exceeded`。本章教学 RunServer 当前先接受取消转换，再停止自己拥有的模型工作进程、清理 timer 并拒绝迟到帧；模型工作进程的停止请求本身没有等待 `:DOWN`，也不证明远端请求已结束。取消不退回预算或撤销已发生效果。持久 Recovery 的超时处理先停止并等待本地执行器退出，再归档 receipt/unknown，见[第 16 章 16.7 节](ch16-durable-effects-and-reconciliation.md)。

选择 `storage: :postgres` 能使 Run/Event/调度意图事务持久化，却不能把这个教学循环的 Provider 游标、流片段、内存预算与 Mock 台账变成完整恢复协议。跨崩溃续跑使用后续 [Recovery](../lib/agent_systems_lab/recovery.ex)、持久任务预算、稳定 operation、receipt、claim 与 fencing；不要从头重启 RunServer 冒充恢复。

## 5.9 验收与常见卡点

| 卡点 | 需要查看的证据 |
| --- | --- |
| 一次 step 后文件还没变 | 当前是否仅在 `waiting_tool`；下一步才执行效果 |
| 参数合法但工具仍被拒绝 | workspace/工具白名单与路径策略是否获宿主启用 |
| 修复命令报 output_exists | 为新实验使用本章全新输出子目录，保留旧证据 |
| 模型脚本走完却没最终回答 | final 也占一轮，检查 max_turns 与请求游标 |
| 超时后打算换 ID 重试 | 先查原 operation/receipt，确认是否未知效果 |

阅读 [run_server_test](../test/agent_systems_lab/run_server_test.exs)、[run_server_stream_test](../test/agent_systems_lab/run_server_stream_test.exs)、[files_test](../test/agent_systems_lab/tools/files_test.exs) 与 [patch_test](../test/agent_systems_lab/tools/patch_test.exs)。提交三步轨迹、取消前后效果对照、unknown 核对和修复证据，并解释每条不变量由哪个组件落实。

练习：将 `max_turns` 设为 1，证明不会发出第二次模型请求；在第一次工具提议后取消，证明效果数为 0；在工具成功后取消，证明效果数仍为 1。分别写出“资源控制、业务状态、外部效果”三列，不要混为一个布尔成功值。尝试后查 [L03 参考解答](../labs/solutions/L03.md)和 [L04 参考解答](../labs/solutions/L04.md)。设计依据见 [ADR 0003](../docs/adr/0003-streaming-cancellation-and-budgets.md) 与 [ADR 0004](../docs/adr/0004-controlled-tools-and-call-pairing.md)。
