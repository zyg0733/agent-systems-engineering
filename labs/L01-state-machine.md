# L01：让 Agent 的每一次状态变化都可以解释

对应计划第 1—2 周。本手册包含源码阅读、测试、故障注入与复盘，可分段完成。第一次进入时先做第 0 节小练习；安装下载与实际学习、执行、排错用时分别记录。

本实验使用 Scripted Provider 与 Mock Tool，完全离线运行。完成后，你应能解释：谁决定状态转换；模型提议何时成为工具请求；为什么回执丢失不能直接重试；重放事件和持久化恢复之间还缺什么。

先修：能在终端进入项目目录，读懂 Elixir 的元组、map 和模式匹配。需要补读时先看[阅读准备](../book/prerequisites.md)与[术语表](../book/glossary.md)。首次安装和依赖下载需要网络；安装完成后的本实验不调用真实模型或远端工具。

<a id="first-exercise"></a>

## 0. 首次小练习：预测、运行与断言

先按 [README](../README.md)准备运行时与依赖。此处不需要 PostgreSQL，也不需要先运行整套测试。在**项目根目录的终端**执行：

```sh
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/iex
```

进入 IEx 后先预测三件事，写在纸上即可：

1. Kernel 接受工具提议时，Mock 的请求数、效果数各是多少？
2. 等待 `first-op` 时收到 `wrong-op` 的结果，seq 会增加吗？
3. 完成后重建历史，会再执行一次 Mock 吗？

下面是 **IEx 输入**。逐段粘贴，不把注释中的预期值当成终端命令。`true = ...` 和元组匹配是本练习的断言，预期不成立时会直接报错。

```elixir
alias AgentSystemsLab.Kernel, as: LabKernel
alias AgentSystemsLab.Tools.Mock

{:ok, tool} = Mock.start_link([])
{:ok, s0} = LabKernel.new("l01-first")
{:ok, s1, e1} = LabKernel.dispatch(s0, {:start, "保存一条模拟记录"})
call = %{operation_id: "first-op", tool: "mock_write", arguments: %{value: "hello"}}
{:ok, s2, e2} = LabKernel.dispatch(s1, {:model_response, {:call, call}})
true = {s2.status, s2.seq} == {:waiting_tool, 2}
true = Mock.stats(tool) == %{requests: 0, effects: 0}

{:error, {:unexpected_operation_id, "first-op", "wrong-op"}} =
  LabKernel.dispatch(s2, {:tool_result, "wrong-op", {:ok, :unexpected}})
true = {s2.status, s2.seq} == {:waiting_tool, 2}
```

到这里工具还没有执行。接下来显式调用 Mock，再将匹配的回执交回 Kernel：

```elixir
{:ok, receipt} = Mock.execute(tool, "first-op", call.arguments)
{:ok, s3, e3} = LabKernel.dispatch(s2, {:tool_result, "first-op", {:ok, receipt}})
{:ok, s4, e4} = LabKernel.dispatch(s3, {:model_response, {:final, "已确认"}})
true = {s4.status, s4.seq} == {:succeeded, 4}

before_rebuild = Mock.stats(tool)
true = before_rebuild == %{requests: 1, effects: 1}
{:ok, rebuilt} = LabKernel.rebuild("l01-first", e1 ++ e2 ++ e3 ++ e4)
true = rebuilt == s4
true = Mock.stats(tool) == before_rebuild
{rebuilt.status, rebuilt.seq, Mock.stats(tool)}
# => {:succeeded, 4, %{effects: 1, requests: 1}}（map 显示顺序无关）
GenServer.stop(tool)
```

用一句话核对每个预测：工具提议是接受的事实，不是工具执行；错 ID 没有产生新事件；重建只应用事件，Mock 的请求与效果都没有增加。这里直接调用 Kernel，没有调用 Provider；计数断言只观察本次 Mock 实例，不是所有效果边界的全局零调用审计。

本练习只使用内存状态与事件列表，关闭 IEx 后不会保留它们。它也没有证明任意远端工具恰好执行一次。现在可以 `Ctrl+C` 两次退出 IEx，再进入下面的完整实验；后文第 4—7 节请新开一个 IEx 会话，按各节变量重新开始。

## 1. 先写下你要证明的事

开始编码前，新建 `notes/L01-report.md`，写出下面五条不变量，每条附一个会违反它的反例：

1. 终态不会被迟到的模型响应或工具结果覆盖。
2. 一次只允许一个待处理操作，工具结果必须匹配操作编号。
3. 同一任务不能重复申请一个已经使用过的操作编号。
4. 工具结果未知时，任务进入 `blocked`，正常继续执行须先核对；显式取消可以进入终态，但不能消除未知的外部事实。
5. 拥有完整事件列表时，按原顺序重放会得到相同状态，而且不会再次产生工具效果。

请先独立画一张状态图，再对照 [架构说明](../docs/architecture.md)。图中必须有 `queued`、`running`、`waiting_tool`、`blocked`、`succeeded`、`failed`、`cancelled`，并明确非法命令的处理方式。

## 2. 准备与基线

先按照 README 准备 Elixir/OTP，在仓库根目录运行。项目的 `scripts/mix` 优先使用 `.runtime/` 中的项目运行时，也兼容已安装的全局 Mix：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test
LAB_DATABASE_ENABLED=false ./scripts/mix lab.verify
LAB_DATABASE_ENABLED=false ./scripts/mix lab.demo
LAB_DATABASE_ENABLED=false ./scripts/mix lab.demo --lost-response
```

把 Elixir/OTP 版本、测试结果和任务集结果保存到实验记录。演示用于认识调用链；只运行这些命令不算完成本实验。

实验期间无需真实模型 API key，也无需网络工具。工具参数中的文件名只是模拟数据，不代表本实验会写入那个路径。

## 3. 读懂四个角色

| 角色 | 负责什么 | 本实验中的观察方法 |
| --- | --- | --- |
| Kernel | 检查命令，计算状态和事件 | 直接调用 `dispatch/2` |
| Scripted Provider | 消耗脚本，返回固定响应 | 显式传递 Provider 状态 |
| Mock Tool | 模拟效果，记录操作台账 | 比较 `requests` 与 `effects` |
| RunServer | 驱动步骤，保存当前进程状态 | 观察 demo，再回看其调用链 |

命令可能被拒绝；事件表示已经接受的事实。`dispatch` 产生事件前，不能把模型的一句提议理解为已经执行了工具。事件应用与重放只计算状态，不调用外部服务。

阅读 [ADR 0001](../docs/adr/0001-pure-kernel-and-explicit-effects.md)，用自己的话在记录中解释“纯内核”以及“显式副作用”。

## 4. 亲手完成一次工具调用

使用项目交互入口，它同时设置运行时、Hex 与 Mix 缓存路径：

```sh
LAB_DATABASE_ENABLED=false ./scripts/iex
```

进入 IEx 后逐段粘贴：

```elixir
alias AgentSystemsLab.Kernel, as: LabKernel

{:ok, s0} = LabKernel.new("l01-ok")
s0.status
# => :queued

{:ok, s1, e1} = LabKernel.dispatch(s0, {:start, "写一条模拟草稿"})
s1.status
# => :running

call = %{
  operation_id: "draft-001",
  tool: "mock_write",
  arguments: %{key: "draft.txt", value: "hello"}
}

{:ok, s2, e2} = LabKernel.dispatch(s1, {:model_response, {:call, call}})
{s2.status, s2.pending_operation_id}
# => {:waiting_tool, "draft-001"}

{:ok, s3, e3} = LabKernel.dispatch(s2, {:tool_result, "draft-001", {:ok, %{saved: true}}})
s3.status
# => :running

{:ok, s4, e4} = LabKernel.dispatch(s3, {:model_response, {:final, "草稿完成"}})
{s4.status, s4.turn_count}
# => {:succeeded, 2}
```

这里的工具结果是你手动输入的：它只用于学习 Kernel 契约，尚未证明任何外部效果发生。第 7 步才会调用真实的 Mock 进程。

现在做三件事，并记录实际输出：

```elixir
LabKernel.dispatch(s4, {:cancel, :too_late})
LabKernel.dispatch(s2, {:tool_result, "wrong-id", {:ok, :value}})
LabKernel.dispatch(s0, {:model_response, {:final, "未经开始的完成"}})
```

三次都应返回 `{:error, reason}`。不要只记录“出错了”，还要说明拒绝原因和拒绝后应该保持的状态。

## 5. 收集事件，再重建状态

继续在同一 IEx 会话运行：

```elixir
events = e1 ++ e2 ++ e3 ++ e4
{:ok, recovered} = LabKernel.rebuild("l01-ok", events)
recovered == s4
# => true
```

再把整段命令写成一个测试，使用全新的初态重复执行两次，比较最终状态和完整事件序列。任务编号、输入、操作编号和选项必须相同；不要把当前时间或随机 UUID 引入这个确定性测试。

如果你使用了非默认的 `max_turns`，重建时也要传入同一选项，例如 `LabKernel.rebuild(run_id, events, max_turns: 1)`。事件列表不包含完整运行配置。

完成后回答：

- 如果只有最终状态，缺少了哪些解释执行过程的信息？
- 如果有事件但事件顺序错乱，重放是否应该接受？请写测试验证。
- 如果 BEAM 退出，内存事件列表也丢失，`rebuild` 从哪里读取事件？

最后一题的答案应明确：本阶段没有磁盘事件存储。这个实验只验证“已持有合法事件列表时能重建”，没有证明断电恢复。

## 6. 使用 Scripted Provider

```elixir
alias AgentSystemsLab.Providers.Scripted

script = [
  {:call, %{
    operation_id: "provider-op-001",
    tool: "mock_write",
    arguments: %{key: "answer", value: 42}
  }},
  {:final, "已完成"}
]

{:ok, p0} = Scripted.new(script)
{:ok, response1, p1} = Scripted.respond(%{input: "演示"}, p0)
{:ok, response2, p2} = Scripted.respond(%{input: "演示"}, p1)
{response1, response2}
Scripted.respond(%{}, p2)
# => {:error, reason, next_provider}，脚本已耗尽
```

独立任务：写一个测试，证明同一个 `p0` 调用两次会得到相同第一条响应；使用返回的 `p1` 才会推进到第二条。然后写另一个测试，把两条响应依次送入 Kernel，在两者之间加入匹配的工具结果，完成任务。

在记录里画出 Provider 游标与 Kernel `turn_count` 的区别。Provider 返回响应不代表 Kernel 一定接受响应；只有合法命令才能推进业务状态。

## 7. 注入“效果已发生，回执却丢失”

```elixir
alias AgentSystemsLab.Tools.Mock

{:ok, tool} = Mock.start_link([])
args = %{key: "draft.txt", value: "hello"}

lost_result = Mock.execute(tool, "lost-001", args, response: :lost)
Mock.stats(tool)
# => %{requests: 1, effects: 1}

{:ok, receipt} = Mock.lookup(tool, "lost-001")
```

注意：`lost_result` 是 `{:unknown, reason}`，但效果数已经是 1。工具调用方看到的响应与外部已发生的事实不同。

构造一个新的 Kernel 任务，把相同 `lost-001` 工具提议送入内核，再把 `lost_result` 作为工具结果送回：

```elixir
{:ok, u0} = LabKernel.new("l01-unknown")
{:ok, u1, _} = LabKernel.dispatch(u0, {:start, "模拟回执丢失"})
unknown_call = %{operation_id: "lost-001", tool: "mock_write", arguments: args}
{:ok, u2, _} = LabKernel.dispatch(u1, {:model_response, {:call, unknown_call}})
{:ok, u3, _} = LabKernel.dispatch(u2, {:tool_result, "lost-001", lost_result})
u3.status
# => :blocked

LabKernel.dispatch(u3, {:model_response, {:final, "假装已完成"}})
# => {:error, reason}

{:ok, u4, _} = LabKernel.dispatch(u3, {:reconcile, "lost-001", {:ok, receipt}})
u4.status
# => :running

{:ok, u5, _} = LabKernel.dispatch(u4, {:model_response, {:final, "已查询并确认效果"}})
u5.status
# => :succeeded
```

独立任务：

1. 重复向 Mock 提交 `lost-001` 和相同参数，观察请求数增加、效果数保持 1。
2. 用同一编号和不同参数再提交，验证冲突被拒绝，效果数仍为 1。
3. 新开一个 Mock 进程，用 `:fail_before_effect` 执行新操作，验证效果数为 0。
4. 为上述三种行为各写一个 ExUnit 断言。比较客户端返回值与服务端台账，不能用一条“调用成功”日志代替效果数断言。

把这个结果写成一个四行表格：故障点、客户端观察、外部效果、下一步合法动作。请解释为什么直接把 `unknown` 当作 `failed` 会误导后续处理。

## 8. 故意破坏，再用测试修复

先写会保护系统的测试，再临时改动实现。一次只做一种破坏，看到预期失败后立刻恢复规则，并重新运行全套测试。将改动和失败原因记录到实验报告；不要把破坏后的实现当作交付。

| 破坏 | 先写的保护测试 | 预期暴露的问题 |
| --- | --- | --- |
| 允许终态再次接受最终回答 | 成功后再送一个最终回答，要求返回错误 | 迟到消息覆盖终态 |
| 去掉结果操作编号校验 | 等待 A 时送入 B 的结果，要求拒绝 | 把其他操作的结果记到当前任务 |
| 将 `unknown` 当作普通成功 | 丢回执后要求处于 `blocked` | 没核对就继续执行 |
| 重放时再次执行工具 | 重放前后比较 Mock `effects` | 重建状态产生重复业务效果 |

最后一种练习可以只在自己写的测试驱动中模拟错误：把工具执行放进重放循环，再删掉这条副作用。不要为了制造它而把 Mock 依赖加入 Kernel。

至少实际完成前三项中的两项，保存每次失败的测试名称与关键断言。第四项必须有一个可运行的“重放不增加效果数”测试。

## 9. 加入边界与反例

在 `test/` 下新增自己的 L01 测试文件，至少覆盖：

- 在 `queued` 收到模型响应时拒绝。
- `waiting_tool` 时拒绝另一个模型工具提议；已完成后再次申请同一操作编号也拒绝。
- `blocked` 核对时只能指定当前操作；错误操作编号不能解除阻塞。
- `max_turns: 1` 时，第一轮工具提议可接受，工具返回后第二轮模型响应被预算规则拒绝，Kernel 仍是 `running`；显式 `fail` 才进入 `failed`。对照 RunServer 如何执行这项结束策略。
- `cancelled` 后迟到的工具结果不会改变任务状态；取消不代表已经发生的工具效果可以撤销。
- 对一组自己生成的合法命令轨迹逐条 `dispatch`，每一步检查状态与不变量；再重建并比较最终状态。生成规则必须保证前置条件成立。

最后一项可先用固定种子与普通 Elixir 循环实现，不要求引入属性测试库。保留生成规则、样本数和种子，确保失败可以复现。测试有意义的反例优先于盲目增加随机次数。

## 10. 验收与提交

运行：

```sh
./scripts/mix format --check-formatted
LAB_DATABASE_ENABLED=false ./scripts/mix test
LAB_DATABASE_ENABLED=false ./scripts/mix lab.verify
```

提交内容包括自己的测试、状态图、命令与事件轨迹、故障表、破坏再修复记录，以及包含结论的 `notes/L01-report.md`。不要仅提交命令输出。

`fixtures/tasks.exs` 中的 10 条任务是受控场景目录，`lab.verify` 检查这些场景的机制结果。它们的通过率不等于真实模型的任务完成率；输入文本不会交给真实模型，也不能据此声称通用 Agent 能力。

### 评分标准

| 项目 | 分值 | 可复核证据 |
| --- | ---: | --- |
| 状态图与不变量 | 20 | 前置条件清晰，每条不变量有反例 |
| 合法轨迹与事件重放 | 20 | 两次轨迹一致，重放一致，无工具再执行 |
| 非法命令与边界测试 | 20 | 编号不匹配、重复编号、终态、预算边界均有独立断言 |
| 丢回执与效果台账 | 20 | `blocked`、查询核对、请求数与效果数、参数冲突都有证据 |
| 破坏再修复 | 10 | 至少两次实际失败，并说明断言保护的规则 |
| 解释与复盘 | 10 | 清楚区分进程重启、事件重放和持久化保证 |

通过门槛为 80 分，并且满足三条硬性要求：未知结果不能自动当作成功或失败；重放不得再次执行工具；报告明确说明当前没有断电恢复保证。若硬性要求未满足，先修复再验收。

## 11. 思考题

1. 为什么 Kernel 要拒绝同一任务内重复的操作编号，而 Mock 还要支持相同编号的幂等重传？
2. 工具已经执行，任务随后被取消，这两件事能同时为真吗？
3. `:lost` 与 `:fail_before_effect` 的业务含义差在哪？
4. 监督树让 Mock 重启后，原来的台账还存在吗？你如何设计测试证明自己的回答？
5. 如果事件只存在 RunServer 的列表里，“我看到了 run_succeeded”是否意味着重启后还可以查到成功？
6. 下一阶段引入持久化时，工具效果与事件记录之间最危险的空隙在哪里？需要新增哪些事实和故障注入点？

独立完成后再阅读 [参考解答入口](solutions/L01.md)。参考解答解释关键推理，不替代你自己的失败记录。
