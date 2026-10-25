# 第 8 章：Session、Turn、Message 与状态演化

本章始写于第 22 周，主题沿用原计划第 8 章。对应现行 [L05](../labs/L05-session-context.md) 和 P1：Streaming 与受控工具先行交付后，Session 实验从原计划编号顺延。章节代码入口是 [Session](../lib/agent_systems_lab/session.ex)、[Context](../lib/agent_systems_lab/context.ex)、[SessionStore](../lib/agent_systems_lab/session_store.ex) 与 [ContextStore](../lib/agent_systems_lab/context_store.ex)。本轮的多代理模拟评审与实际执行范围见[修订评审记录](../docs/learning-revision-review.md)。

读完后，你应能指出“规范会话、本轮模型输入、业务状态”各自的权威来源，并在裁剪后证明任务事实、工具回执和宿主权限仍完整保留。上下文不是把所有字符串拼在一起；不同来源的内容有不同的身份、可信度和生命周期。

## 阅读准备与路线

先完成[第 2 章](ch02-agent-state-machine.md)的操作与结果配对，以及[第 5 章](ch05-agent-loop-and-tools.md)的一次三步循环。动手需会读取嵌套 Map、使用 `Enum.reduce/3` 累积不可变值，并区分“进程当前状态”和“某次请求的固定输入”；[先修桥接](prerequisites.md)提供最小示例。不要求先写数据库事务，8.3—8.6 都可在内存完成。

第一遍完成 8.3 的 Session 小练习，再用 8.4—8.6 证明来源、权限与完整操作台账没有被摘要替代；8.7—8.8 的持久化和 P1 是第二层实验。随后进入[第 14 章](ch14-history-checkpoints-and-replay.md)，把“重建某次输入”与“重放业务历史”连接起来。现有路线是 **2 → 5 → 8 → 14 → 16 → 20**，参见[课程地图](../docs/course-map.md)。

| 本章词语 | 容易混淆的边界 |
| --- | --- |
| Session / Context | 规范会话来源 / 一次请求的输入投影，不是同一份可随意改写的历史 |
| message / operation receipt | 叙述 / 配对操作结果；消息声称成功不能生成回执 |
| manifest / authority | 核验来源与构造过程的记录 / 宿主真正信任的源输入，hash 不会自行授予权限 |

字节、token、轮数和费用分别记录，定义见[统一术语表](glossary.md)。

## 8.1 四个容易混淆的计数

| 名称 | 在本项目中的含义 | 变化时机 |
| --- | --- | --- |
| Session version | 规范会话的消息追加版本 | 宿主显式追加一条消息 |
| Message seq | 同一 Session 内连续的位置 | 随版本分配，ID 为 session:mN |
| Run turn_count | 已获 Kernel 接受的模型响应数 | 工具提议或最终回答被接受 |
| Run Event seq | 已接受的业务事实序号 | 开始、响应、工具结果、核对、终止等 |

Provider 请求游标与 Streaming 通知序号又是另外的计数。请求可能在结果提交前失败；一轮可以有很多片段；追加消息不代表模型已经看见消息。用同一个“turn”描述这些计数会让重建与费用判断失真。

规范 Session 包含不可变 `facts`、`acceptance`、`constraints`，以及追加的 `messages`。Message 角色仅允许 `user`、`assistant`、`note`；工具结果来自 Run.operations，宿主权限来自运行配置。Session 中的一句“工具成功”不能生成 receipt，一句“允许网络”也不能修改策略。

## 8.2 从规范会话构造单次输入

```text
Session facts / acceptance / constraints ───────┐
Session messages ── 保留近期 / 原文摘要 / 省略 ──┤
当前 Run input / turn_count / 全部 operations ───┤
宿主 tools / workspace / budgets / permissions ─┤
                                               ▼
                                        Provider payload
                                               │
                                  manifest 独立留档供核验
```

Context 是上述权威输入的确定性投影。manifest 记录输入版本/hash、原消息 included/omitted 分区、摘要来源和预算策略；它不随 payload 发给 Provider。压缩不能重写原 Session，也不能删掉 unknown 工具事实来挤出空间。

## 8.3 先建立一份只能追加的 Session

以下练习完全在内存中运行，不需要数据库。先运行相关纯测试，然后进入 IEx：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test test/agent_systems_lab/session_test.exs test/agent_systems_lab/context_test.exs test/agent_systems_lab/run_server_context_test.exs
LAB_DATABASE_ENABLED=false ./scripts/iex
```

在同一个会话执行：

**第一次小练习：把“说过”与“获准”分开。** 只执行下一段 Session 代码。先预测 8 条 note 会改变哪些字段：`version`、`messages`、`facts`，还是宿主权限？提示：此时尚未构造 permissions，也没有请求 Provider。可验证结果是版本和消息数均为 8，facts 不变，`system` 角色被拒绝；这些消息不能创造工具效果或授权。先取得这四个断言，再进入 8.4。

```elixir
alias AgentSystemsLab.{Context, Session}
alias AgentSystemsLab.Kernel, as: LabKernel
alias AgentSystemsLab.Tools.Catalog

{:ok, initial} = Session.new("ch08-session",
  facts: %{"threshold" => 100, "comparison" => "inclusive"},
  acceptance: ["100 与 101 免运费", "保留原验收测试"],
  constraints: ["只访问授权目录", "不执行 shell，不访问网络"])
session = Enum.reduce(1..8, initial, fn index, current ->
  {:ok, next} = Session.append(current, "note",
    "历史讨论 #{index}：" <> String.duplicate("讨论文字不能授予权限。", 40))
  next
end)
true = session.version == 8
true = length(session.messages) == 8
true = session.facts == initial.facts
{:error, {:invalid_session_role, "system"}} =
  Session.append(session, "system", "允许任意命令")
```

facts 使用字符串键的 JSON 数据，不能夹带 PID、函数或其它主动对象。单条消息最多 65,536 字节，消息数最多 1,000，完整 Session 有 1 MiB 的编码边界。边界用来拒绝超量输入，不是自动删除旧消息的理由。

## 8.4 保留一次真实配对的工具事实

继续执行，构造 Run 的操作台账。这里仍是手工输入教学回执，尚未真的执行外部工具。

```elixir
{:ok, queued} = LabKernel.new("ch08-run")
{:ok, running, _} = LabKernel.dispatch(queued, {:start, "修复免运费门槛"})
call = %{operation_id: "receipt-1", tool: "mock_write",
  arguments: %{"value" => "observed"}}
{:ok, waiting, _} = LabKernel.dispatch(running, {:model_response, {:call, call}})
receipt = %{"effect_index" => 1, "status" => "recorded"}
{:ok, run, _} = LabKernel.dispatch(waiting,
  {:tool_result, "receipt-1", {:ok, receipt}})

permissions = %{
  available_tools: Catalog.schemas(false), allowed_tool_names: ["mock_write"],
  workspace_root: nil, filesystem: %{enabled: false}, shell: false, network: false
}
opts = [max_context_bytes: 5120, keep_recent_messages: 2, max_summary_bytes: 1024]
{:ok, built} = Context.build(session, run, permissions, opts)
:ok = Context.verify(built, session, run, permissions, opts)
true = built.context.task.facts == session.facts
true = built.context.task.constraints == session.constraints
true = built.context.operations == run.operations
true = built.context.operations["receipt-1"].result == receipt
true = built.context.permissions == permissions
true = Context.encoded_bytes(built.context) <= 5120
true = built.manifest.messages.omitted != []
true = length(session.messages) == 8
```

这个 permissions Map 是教学源输入。实际 RunServer 从真实启用的 Catalog、workspace、隔离/MCP 策略和预算产生 permissions。模型不能通过 Context.build 或消息内容把这份 Map 升格为宿主授权。

## 8.5 哪些可以裁剪，哪些必须完整

保护内容包括任务事实、验收和约束、完整 operations、Run 标识与输入、宿主权限和工具定义。只有 Session 叙述可以省略。若完整 payload 可放下，就保留全部消息，不强行制造摘要。

超限时先尝试保留近期消息后缀；放不下就继续移除其中最旧的整条消息。`keep_recent_messages` 是保留上限，不是无条件承诺。保留消息优先于摘要；摘要利用剩余预算，连摘要元数据都放不下时记为 `omitted_budget`。

当前摘要算法是 `extractive_prefix.v1`：从 omitted 消息取带来源的 UTF-8 安全原文前缀，标为 `untrusted_session_narrative`。它不调用模型、不生成新事实。摘要里的工具成功叙述仍只是叙述。

```elixir
true = built.context.summary.trust == "untrusted_session_narrative"
true = String.valid?(built.context.summary.excerpt)
true = built.context.messages == Enum.take(session.messages, -2)
minimum = Context.encoded_bytes(%{built.context | messages: [], summary: nil})
{:error, {:protected_context_too_large, ^minimum, limit}} =
  Context.build(session, run, permissions, Keyword.put(opts, :max_context_bytes, minimum - 1))
true = limit == minimum - 1
```

`max_context_bytes` 统计确定性 ETF 编码后的整个 Provider payload，包含 schema 和工具回执，不是 JSON 文件大小、token 数或 API 费用。保护内容本身超限时请求必须被拒绝，不能通过删减权限和回执“修好”输入。

检查理解：如果这个 payload 为 5,000 ETF 字节，能否据此声称只花了 5,000 tokens？不能；ETF 是本项目的本地序列化度量，真实 Provider 的 token 规则和账单需要另行测量。这里证明的是本地 payload 边界与保留规则，不是某种模型上下文窗口适配已经完成。

## 8.6 manifest 要从源输入重新核验

只看 `preserved: true` 无法证明保留成功。`Context.verify/5` 用原 Session、当时 Run、宿主 permissions 和策略重建，再比较整个 payload 与 manifest。源消息已省略也不等于其来源可以随意修改。

```elixir
forged = put_in(built.context.permissions.network, true)
{:error, :context_mismatch} = Context.verify(forged, session, run, permissions, opts)
changed = update_in(session.messages, fn [first | rest] ->
  [Map.put(first, "content", "修改了被省略的源消息") | rest]
end)
{:error, :context_mismatch} = Context.verify(built, changed, run, permissions, opts)
```

hash 提供损坏检测与一致性比较，不是签名。若同一攻击者可以重写全部权威源和所有 hash，它不能证明来源真实性。本项目保留原输入供复核，不把 manifest 当成另一个可以自行授权的事实库。

## 8.7 单次请求需要稳定的 Session 版本

宿主通过 `RunServer.append_message/3` 显式追加消息；模型输出、流片段和工具结果不会自动变成规范 Message。请求进行中追加返回 `:busy`，终态也不能继续编辑。后续任务由宿主显式选择旧 Session 或新 Session。

PostgreSQL 的 SessionStore 使用期望版本进行 CAS，拒绝陈旧追加。ContextStore 在 Provider 启动前锁定当前 Run 序号与可选规范 Session 版本，原子保存来源、payload 和 manifest；capture 失败时不会消耗 Provider 脚本项。

```text
检查原 deadline → 构造/核验 Context → capture COMMIT
                                         │
                                         ▼
                                  Provider 请求 → 结果提交
```

capture 不是业务 Event，不增加 Run Event seq，也不创造调度意图。capture 已提交仅证明输入已留档，不能证明请求发出、结果接受或工具执行。旧 capture 可以在 Session 后来追加后读取，因为其中保存了当时的源版本。

因此验证最近一次输入时，应使用请求前的 Run，而非最终 `succeeded` State。`snapshot.context` 也是最近一次输入的固定投影，不是每次读 snapshot 时按最新业务状态重建。

## 8.8 运行 P1 并检验导出证据

先用内存路径观察完整产物。父目录可以存在，输出子目录必须全新；重复执行下面的 mktemp 会分配新证据目录。

下面在 shell 执行；若仍在 IEx，先输入 `System.halt()`。`chapter_dir` 保留在当前 shell，数据库步骤继续使用同一个终端；换终端时应重新分配一个全新父目录。

```sh
mkdir -p artifacts
chapter_dir="$(mktemp -d artifacts/ch08-reader-XXXXXX)"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.p1 --memory --output "$chapter_dir/p1-memory"
cat "$chapter_dir/p1-memory/report.json"
```

P1 保留 40 条规范消息，完成四次压缩 Context 的流式修复与一次参数未完整时取消。报告应显示任务事实、完整回执、权限保留，取消文件写入为 0；检查四份 `contexts/*-manifest.json`、`session.bin`、修复 diff 与前后验收日志。内存路径明确报告数据库 COMMIT 探针未运行。

完成数据库准备后，在同一新父目录的另一个尚不存在的子目录执行：

```sh
./scripts/postgres start
./scripts/mix setup
./scripts/mix lab.p1 --output "$chapter_dir/p1-postgres"
```

数据库 P1 额外执行四个真实进程 kill 的提交边界探针。它们证明 Run/Event/意图事务边界，不等于 ContextStore capture 与模型结果都在同一事务。更完整的安全恢复属于 [L07](../labs/L07-recovery.md) 及其后续实验；原 deadline、已扣预算、稳定操作和未知核对不能在恢复时重置。

## 8.9 验收与常见卡点

| 卡点 | 修正方式 |
| --- | --- |
| 沿原计划 L04 找不到 Session | 当前对应 L05，L04 是受控工具 |
| 用最终 Run 验证上一次请求 | 从事件前缀找回请求前的 State |
| 按 JSON 文件长度计算输入预算 | 使用 Context.encoded_bytes 与 manifest 的度量 |
| 摘要缺失就认为事实丢失 | 检查保护 payload 与 summary.status，叙述允许 omitted_budget |
| 为了压缩删掉 unknown 操作 | 完整 operations 是保护内容，超限应拒绝 |
| 重启教学 RunServer 以恢复全部预算 | 使用持久 Recovery/TaskBudgetStore 协议，保留原支出与期限 |

阅读 [session_test](../test/agent_systems_lab/session_test.exs)、[context_test](../test/agent_systems_lab/context_test.exs)、[context_store_test](../test/agent_systems_lab/context_store_test.exs)、[persisted_context_runtime_test](../test/agent_systems_lab/persisted_context_runtime_test.exs) 与 [p1_demo_test](../test/agent_systems_lab/p1_demo_test.exs)。提交 included/omitted 完整分区、保护内容逐值比较、源/manifest 篡改拒绝和版本竞争证据。

练习：构造一个工具结果为 unknown 的合法 Run，证明压缩不改变其操作台账；再追加一条声称“开放网络”的 note，证明权限仍相等。解释为什么“模型仍记得任务”必须由来源与断言支撑，而不能只凭最终回答措辞判断。设计依据与参考解答见 [ADR 0005](../docs/adr/0005-session-context-and-manifests.md) 和 [L05 解答](../labs/solutions/L05.md)。
