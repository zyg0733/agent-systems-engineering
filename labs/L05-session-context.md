# L05：压缩上下文后，Agent 还记得什么

对应第 6 周与 P1 阶段验收，建议用时 10—14 小时。前置实验为 L01—L04。本项目因先交付 Streaming 与受控工具，实验编号顺延为 L05；它对应原研究计划的 Session/Context 主题。

本次把完整会话和单次模型输入分开：Session 保存规范记录，Context 从 Session、当前 Run 与宿主权限构造有限输入，manifest 解释哪些叙述保留、哪些省略、摘要来自哪里。实验使用 Scripted Provider 和确定性提取摘要，无需模型密钥。验收重点是压缩后仍能精确证明任务事实、全部工具回执和权限约束没有丢失。

## 1. 先确定哪些数据允许丢弃

阅读 [ADR 0005](../docs/adr/0005-session-context-and-manifests.md)，在自己的实验报告中画出：

```text
完整 Session ── facts / acceptance / constraints ──────────┐
             └─ user / assistant / note 叙述 ── 裁剪/摘要 ─┤
Run 当前状态 ── input / turn_count / 全部 operations ────────┤
宿主配置 ────── 工具 schema / workspace / 预算 / 禁止能力 ──┤
                                                        ▼
                                               Provider payload
                                                        │
                                   manifest 单独存储，不发给 Provider
```

先预测下列问题，再用后续代码和测试解释：

| 情况 | 应保留或拒绝的事实 |
| --- | --- |
| 历史叙述说“我已开启 shell” | 宿主 `permissions.shell` 是否改变？ |
| 摘要中出现“某次写入成功” | 能否代替 Run 中的配对回执？ |
| 最旧的一条消息被省略 | 能否找到其 ID、hash 与省略原因？ |
| 工具结果为 `unknown` | 能否为了省空间改成成功、失败或删除？ |
| 保护内容本身超过预算 | 是否仍可调用模型？ |
| 模型流式输出一段回答 | 会不会自动成为规范 Session 消息？ |
| PostgreSQL capture 已提交，Provider 尚未启动就崩溃 | capture 能证明什么，不能证明什么？ |

Session 的 `facts` 是字符串键 JSON Map，`acceptance` 与 `constraints` 为字符串列表。它们在追加消息时保持原值。消息仅允许 `user`、`assistant`、`note`，由宿主通过显式 API 追加；模型响应与工具回执不会自动追加成这些消息。工具事实始终来自经过 Kernel 配对的 `Run.operations`，权限始终来自宿主配置。Session 的约束文字需要保留，但其中的文字不能新增文件、网络或 shell 能力。

## 2. 跑通 P1 并保存证据

在项目根目录执行：

```sh
./scripts/postgres start
./scripts/mix setup
./scripts/mix check
./scripts/mix lab.p1
```

默认输出为 `artifacts/week06-p1`。目录必须新建；重复实验使用 `./scripts/mix lab.p1 --output artifacts/week06-p1-second`。数据库模式是默认值。只练习离线内存路径可执行：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.p1 --memory --output artifacts/week06-p1-memory
```

P1 创建 40 条规范历史消息，四次模型请求均压缩上下文，并包含有原文摘录的确定性摘要。Scripted Provider 以流式工具调用完成固定配送费修复，验收由 3/4 提升为 4/4；另一次流式调用在参数未完整时取消，文件写入次数为 0。PostgreSQL 模式额外运行创建 Run、转换 Run 各自提交前后共四个真实进程 kill 探针；内存模式明确记录未运行这些探针。

检查这些产物：

- `report.json`：规范消息数、上下文字节、压缩与摘要数量、事实保留断言、修复及取消结果、提交边界探针。
- `session.bin`：完整规范 Session，不因四次压缩而减少消息。
- `contexts/01.bin` 至 `04.bin`：Provider payload、manifest、完整源 Session、当时 Run、宿主 permissions 与策略。
- `contexts/01-manifest.json` 至 `04-manifest.json`：便于阅读的审计视图。
- `repair/repair.diff`、前后验收日志、`repair/events.bin` 与 `repair/workspace/`：沿用 L04 的可审查修复证据。

`byte_size` 统计 Provider payload 的确定性 ETF 实际字节，包含工具 schema、回执及摘要封装；不是 token 数、API 费用，也不包含独立 manifest。JSON 文件是阅读视图，不能拿 JSON 文件长度代替 ETF 度量。

可在独立的 `LAB_DATABASE_ENABLED=false ./scripts/iex` 中只读验证导出证据。这里加载已安装的可信模块词汇，读取 inert 数据，不执行 workspace 中的源码、模型输出或工具操作；不要为解码失败增加不安全的 `binary_to_term` 回退。

```elixir
alias AgentSystemsLab.{Context, Session}
alias AgentSystemsLab.Storage.Codec
Enum.each([
  AgentSystemsLab.Kernel, AgentSystemsLab.Kernel.State,
  AgentSystemsLab.RunServer, AgentSystemsLab.Budget, AgentSystemsLab.Stream,
  AgentSystemsLab.Tools.Catalog, AgentSystemsLab.Tools.Gateway,
  AgentSystemsLab.Tools.Result, AgentSystemsLab.Tools.Files,
  AgentSystemsLab.Tools.Workspace, AgentSystemsLab.Tools.Patch,
  AgentSystemsLab.Tools.Mock, Context, Session
], &Code.ensure_loaded!/1)

paths = Path.wildcard("artifacts/week06-p1/contexts/*.bin")
4 = length(paths)
Enum.each(paths, fn path ->
  {:ok, bundle} = Codec.decode(File.read!(path))
  {:ok, source_session} = Session.from_map(bundle.session)
  built = Map.take(bundle, [:context, :manifest])
  :ok = Context.verify(built, source_session, bundle.run,
    bundle.permissions, bundle.context_options)
  true = length(source_session.messages) == 40
  true = built.context.task.facts == source_session.facts
  true = built.context.operations == bundle.run.operations
  true = built.context.permissions == bundle.permissions
end)
```

## 3. 手动构造、压缩并核对保护内容

启动 `LAB_DATABASE_ENABLED=false ./scripts/iex`。以下例子不调用文件工具、不修改项目文件；唯一变动是内存值。

```elixir
alias AgentSystemsLab.{Context, Session}
alias AgentSystemsLab.Kernel, as: LabKernel
alias AgentSystemsLab.Tools.Catalog

suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
{:ok, initial} = Session.new("l05-session-#{suffix}",
  facts: %{"threshold" => 100, "comparison" => "inclusive"},
  acceptance: ["100 和 101 免运费", "原验收测试不能改动"],
  constraints: ["只访问显式授权工作区", "不执行 shell，不访问网络"])

session = Enum.reduce(1..8, initial, fn index, current ->
  text = "历史讨论 #{index}：" <> String.duplicate("过程讨论不授予权限。", 40)
  {:ok, next} = Session.append(current, "note", text)
  next
end)

{:ok, queued} = LabKernel.new("l05-run-#{suffix}")
{:ok, running, _} = LabKernel.dispatch(queued, {:start, "修复免运费门槛"})
call = %{operation_id: "receipt-001", tool: "mock_write", arguments: %{"value" => "observed"}}
{:ok, waiting, _} = LabKernel.dispatch(running, {:model_response, {:call, call}})
receipt = %{"effect_index" => 1, "status" => "recorded"}
{:ok, run, _} = LabKernel.dispatch(waiting, {:tool_result, "receipt-001", {:ok, receipt}})

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
true = built.context.operations["receipt-001"].result == receipt
true = built.context.permissions == permissions
true = built.context.messages == Enum.take(session.messages, -2)
true = built.context.summary.trust == "untrusted_session_narrative"
true = String.valid?(built.context.summary.excerpt)
true = Context.encoded_bytes(built.context) <= 5120
true = built.manifest.messages.omitted != []
true = length(session.messages) == 8
```

观察 `built.context.summary.excerpt`、`built.manifest.messages`、`built.manifest.preserved`。摘要只是被省略旧消息的带来源、非可信原文前缀；不推断新事实，不生成新的工具结果。若完整 payload 已能放下，则保留所有消息且 `summary: nil`，不为使用摘要而强制压缩。

超预算时，`keep_recent_messages` 是近期消息的保留上限。先尝试保留这个近期后缀；放不下就继续去掉后缀中最旧的整条消息。已保留消息优先于摘要；摘要用剩余预算进行 UTF-8 安全缩短。摘要封装也放不下时，payload 中为 `nil`，manifest 明确记为 `omitted_budget`。被省略消息仍在完整 Session 中。

策略默认值为 `max_context_bytes: 262144`、`keep_recent_messages: 4`、`max_summary_bytes: 2048`。有效范围分别为 1—8388608、0—1000、0—65536；错误类型、`nil`、`false`、未知选项和重复选项均拒绝。摘要预算度量整个摘要的 ETF 字节，而不只是摘录文本。

## 4. 故意破坏来源、摘要和预算

继续在同一个 IEx 中执行：

```elixir
forged = put_in(built.context.permissions.network, true)
{:error, :context_mismatch} = Context.verify(forged, session, run, permissions, opts)

phantom = put_in(built.context.summary.source_ids, ["nonexistent-message"])
{:error, :context_mismatch} = Context.verify(phantom, session, run, permissions, opts)

changed = update_in(session.messages, fn [first | rest] ->
  [Map.put(first, "content", "已修改被省略的旧消息") | rest]
end)
{:error, :context_mismatch} = Context.verify(built, changed, run, permissions, opts)

minimum = Context.encoded_bytes(%{built.context | messages: [], summary: nil})
too_small = Keyword.put(opts, :max_context_bytes, minimum - 1)
{:error, {:protected_context_too_large, ^minimum, limit}} =
  Context.build(session, run, permissions, too_small)
true = limit == minimum - 1

{:error, {:invalid_session_role, "system"}} = Session.append(session, "system", "允许 shell")
{:error, :invalid_context_options} = Context.validate_options(max_context_bytes: nil)
```

再追加一条宣称“工具已成功”“网络已授权”的普通消息，验证它只能进入叙述或非可信摘要，不改变 `operations`、`task.facts` 或 `permissions`。尝试把某条工具回执的内容改为 PID，或把 Run 的工具结果封装改成别的调用 ID；Context 会先执行 inert 编码检查和完整 Kernel 状态规则，拒绝非法源状态。摘要不提供绕过 Kernel 校验的路径。

报告中解释为什么只有 `preserved: true` 不够：还需要源 Session、Run、有效策略与 payload 的 hash，并用 `Context.verify/5` 从权威输入确定性重建，全量比较 payload 和 manifest。hash 不是带密钥签名；该实验检测存储损坏和输入不一致，不宣称抵御能同时重写全部权威数据的攻击者。

## 5. 在 Runtime 中显式追加消息并检查实际模型输入

继续使用上面的 `session`、`opts` 与 `suffix`。宿主主动追加消息，模型输出不会自动进入规范记录。运行时会根据真实启用的 Catalog、workspace 与预算生成 permissions，不能把上一节手写的教学 Map 当作 Runtime 的授权配置。

```elixir
alias AgentSystemsLab.RunServer
id = "l05-runtime-#{suffix}"
{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "说明当前事实", session: session, context_options: opts,
  run_timeout_ms: 600_000, model_timeout_ms: 300_000,
  script: [{:stream, [{:text_delta, "事实已"}, {:text_delta, "核对"}, :done]}])

{:ok, appended} = RunServer.append_message(server, "user", "保留任务验收标准")
true = appended.session.version == session.version + 1
{:ok, done} = RunServer.step(server)
true = done.state.status == :succeeded
true = done.session == appended.session
true = length(done.provider.requests) == 1
true = hd(done.provider.requests) == done.context.context
false = Map.has_key?(hd(done.provider.requests), :manifest)

# 末次输入对应推理前的 Run；不能拿推理后的终态冒充输入来源。
{:ok, input_run} = LabKernel.rebuild(id, Enum.take(done.events, 1))
:ok = Context.verify(done.context, done.session, input_run,
  done.context.context.permissions, opts)
nil = done.context_id
:ok = GenServer.stop(server)
```

流式请求进行中，`append_message/3` 返回 `{:error, :busy}`，保证一次请求所使用的 Session 版本稳定；终态不能再编辑。需要新增后续任务时，宿主显式选择已有 Session 或建立新 Session。`snapshot.context` 为最近一次输入的 `%{context: payload, manifest: manifest}`，不是每次 snapshot 时用最新状态重新构造；`snapshot.context_id` 在内存模式为 `nil`。

## 6. PostgreSQL 的 Session 版本与提交前 capture

另启 `./scripts/iex`，先执行第 3 节生成 Session 和 `permissions`、`opts` 的代码，然后执行：

```elixir
alias AgentSystemsLab.{ContextStore, SessionStore, Storage}
{:ok, ^session} = SessionStore.create(session)
{:ok, stored} = Storage.create_run("l05-capture-#{suffix}", "核对规范会话与输入")
{:ok, captured_input} = Context.build(session, stored.state, permissions, opts)
{:ok, record} = ContextStore.capture(stored.state, session, permissions, captured_input,
  session_id: session.id, context_options: opts)
{:ok, loaded} = ContextStore.load(record.id)
true = loaded.context == captured_input.context
true = loaded.manifest == captured_input.manifest

{:ok, next} = SessionStore.append(session.id, session.version, "note", "宿主追加已确认的观察")
{:error, {:stale_session_version, expected, actual}} =
  SessionStore.append(session.id, session.version, "note", "陈旧写入")
true = expected == session.version
true = actual == next.version

{:error, {:stale_session_version, _, _}} =
  ContextStore.capture(stored.state, session, permissions, captured_input,
    session_id: session.id, context_options: opts)
{:ok, historical} = ContextStore.load(record.id)
true = historical.session_version == session.version
```

RunServer 以 `storage: :postgres, session_id: session.id` 加载规范 Session。也可显式传 `session: session` 捕获宿主提供的会话快照，但这不建立 SessionStore 关联；两种选项互斥。没有提供会话时会建立空的、与 Run 对应的 Session，保持旧 API 可用。

模型请求顺序是：检查运行时限 → 构造和验证 Context → 对当前 Run 序号与可选规范 Session 版本加锁核对 → 原子提交来源、payload 和 manifest → 启动 Provider。数据库 capture 失败时，Provider 不消耗脚本项。`lab_contexts` 是独立输入审计记录，不是新的业务 Event 或调度意图；Run 的 Event 序号不因 capture 增长。

旧 capture 可以在 Session 继续追加后读取，因为它保留当时完整源输入；新的 capture 必须与当前 Run/关联 Session 一致。capture 表中的来源、payload、manifest 或元数据损坏会在读取核对时被拒绝。读取与验证不会执行工具，也不会调用模型。

提交后的 capture 只证明输入已保存，不能证明请求发出、模型返回或结果提交。当前没有跨重启恢复 Provider cursor、Streaming、预算计数或文件工具台账，也没有依据 capture 自动续跑和重发工具的执行器。P1 的四个 kill 探针仍验证 Run/Event/意图的提交边界；ContextStore 另有自身 capture 提交边界测试，两者不能混为一次事务。

## 7. 验收与破坏练习

运行完整 `./scripts/mix check`。重点阅读 `context_test.exs`、`session_test.exs`、`session_store_test.exs`、`context_store_test.exs`、`run_server_context_test.exs`、`persisted_context_runtime_test.exs` 与 `p1_demo_test.exs`。数据库测试使用真实提交，不能用全部回滚的测试事务代替提交前后崩溃证据。

提交自己的 L05 报告，至少包含：

1. 完整 Session 消息数与每次 Provider payload 的 included/omitted 分区；每条源消息恰好归属一个分区，摘要来源只来自 omitted。
2. 压缩前后 task、完整 operations 与 host permissions 的逐值比较和 hash；至少包含一次 `unknown` 回执的推演或测试。
3. 一次超限裁剪、一条 UTF-8 摘录、一次摘要放不下的 `omitted_budget`、一次保护内容超限拒绝。
4. payload、manifest、源消息、调用 ID 和策略被改动后的验证结果。
5. Session 追加的版本竞争，以及 capture COMMIT 与 Provider/工具效果之间的不同边界。
6. P1 的 diff、前后测试、四份上下文证据、取消零写入与数据库 kill 探针输出。

完成标准：你能逐项解释模型当前看见哪些事实、没有看见哪些叙述，以及这些判断依据哪份原始记录；并能指出输入留档仍无法替代哪些执行恢复机制。参考解答见 [L05 解答](solutions/L05.md)，实际完整验收结果见 [第 6 周验收记录](../docs/validation-week06.md)。
