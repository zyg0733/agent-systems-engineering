# L04：模型提议怎样变成受控文件修改

对应计划第 5 周。建议实验时间 10—14 小时，分三次完成。前置实验为 L01—L03。本册沿用实际交付编号；原计划中的工具实验在 Streaming 实验之后交付，编号顺延为 L04。

这次让 Agent 在明确指定的私人工作目录中读取、修补和写入文件，完成一次离线修复，并生成可审查的 diff。模型由 Scripted Provider 代替，不使用 API 密钥。验收目标不是“文件最后变对了”，而是解释每个修改由哪次调用授权、参数如何验证、结果如何与调用配对，以及失败时哪些事实还能证明。

## 1. 先画出授权与结果两条路径

新建 `notes/L04-report.md`，阅读 [ADR 0004](../docs/adr/0004-controlled-tools-and-call-pairing.md)，画出：

```text
完整模型响应 → 工具名与参数 schema → Kernel 接受调用 → tool 意图提交
                                                           │
                                                下一次显式 step
                                                           ▼
路径 / 文件 / hash 预检 → 文件效果 → 带调用标识的结果 → Kernel 配对 → model 意图
```

把以下标识分别写在图中，说明谁生成、谁校验、作用域多大：Run ID、Streaming 请求引用、业务 Event 序号、`operation_id`。本周 `operation_id` 同时承担 Provider 调用标识和逻辑操作标识，每个操作只有一次执行尝试；尚未引入独立 attempt ID。不要把临时请求引用当成工具调用 ID。

先预测下表，再补上观察与测试位置：

| 情况 | 接受工具提议？ | 可发生文件修改？ | 后续状态/事实 |
| --- | --- | --- | --- |
| 没有配置 `workspace`，模型要求 `file_write` | ? | ? | ? |
| 完整 JSON 带未知参数字段 | ? | ? | ? |
| 字段形状合法，但路径包含 `..` | ? | ? | ? |
| 未知工具名称 | ? | ? | ? |
| 调用已接受，执行前取消成功 | ? | ? | ? |
| SHA-256 与当前文件不一致 | ? | ? | ? |
| 第二个补丁 edit 不能唯一匹配 | ? | ? | ? |
| 已写入后取消 | ? | ? | ? |
| 结果中的 ID 或工具名与待处理调用不同 | ? | ? | ? |

至少写下五条不变量：未启用的文件能力不能由模型获得；文件 schema 拒绝未知字段；文件路径与内容必须通过执行时检查；完整补丁预检失败时文件不变；工具结果与待处理调用的 ID、工具名配对；重建业务事件不执行文件操作。未知工具名称沿用旧行为：可以记为一次调用提议，执行时得到受控的 unsupported-tool 错误，不能获得白名单以外的效果。

## 2. 准备环境并运行离线修复

在项目根目录运行：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
./scripts/mix lab.repair
```

本页后续命令在同一终端继续；新开终端时先选择实例、清除 `DATABASE_URL` 并重新执行两条 `export`。这段准备面向完整 PostgreSQL 验收，后台 Scheduler 保持关闭；`lab.repair` 自身运行内存文件工具路径。默认输出目录为 `artifacts/week05-repair`。命令拒绝覆盖已存在的输出目录；再次实验请提供一个新的目标：

```sh
./scripts/mix lab.repair --output artifacts/week05-repair-second
```

查看输出目录中的 `repair.diff`、`report.json`、`before-test.log`、`after-test.log` 与 `events.bin`。缺陷是 `lib/shipping.ex` 的免运费条件用了 `subtotal > 100`；修复后为 `subtotal >= 100`，金额恰好 100 时也免运费。固定验收修复前 3/4 通过、exit code 2，修复后 4/4 通过、exit code 0。该演示由宿主程序核对源文件与测试的精确字节后才执行受信任 fixture；没有向模型公开 shell 或任意代码执行工具。找出以下四个边界的证据：读取缺陷文件、补丁修改、写入修复说明、最终回答。正常路径应有 4 个接受的模型响应、3 次工具执行，其中 1 次读取、2 次写入。

记录 diff 中每个被修改的文件与对应 `operation_id`。不要只贴最后的 `succeeded`：保留原始内容 hash、修改后的 hash、配对结果和可重建的业务历史。新目录要求避免把旧输出误认为本次 Agent 的产物。

第 3—6 节在 IEx 执行。只做这些内存工具练习时可跳过本节数据库准备，在项目根目录执行：

```sh
export LAB_SCHEDULER_ENABLED=false
LAB_DATABASE_ENABLED=false ./scripts/iex
```

完整验收及第 7 节仍需启用数据库的 IEx 会话；数据库配置与可丢弃数据要求沿用 L02。

## 3. 用三次调用完成最小读、补丁与写入

下面的 setup 由学习者在 IEx 中执行，负责创建本次专用目录与初始文件。模型只获得之后公开的三个文件工具，不能自行扩大目录范围。

```elixir
alias AgentSystemsLab.{RunServer, Storage}
alias AgentSystemsLab.Kernel, as: LabKernel

suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
id = "l04-files-#{suffix}"
workspace = Path.join(File.cwd!(), "artifacts/l04-practice-#{suffix}")
File.mkdir_p!(workspace)
File.chmod!(workspace, 0o700)
source = "total = subtotal - tax\n"
File.write!(Path.join(workspace, "invoice.txt"), source)
sha256 = fn text -> Base.encode16(:crypto.hash(:sha256, text), case: :lower) end

call = fn operation_id, tool, arguments ->
  {:call, %{operation_id: operation_id, tool: tool, arguments: arguments}}
end

script = [
  call.("read-001", "file_read", %{"path" => "invoice.txt"}),
  call.("patch-001", "file_patch", %{
    "path" => "invoice.txt",
    "expected_sha256" => sha256.(source),
    "edits" => [%{"old" => "subtotal - tax", "new" => "subtotal + tax"}]
  }),
  call.("note-001", "file_write", %{
    "path" => "repair-notes.txt",
    "content" => "Changed subtraction to addition.\n",
    "expected_sha256" => "absent"
  }),
  {:final, "修复与说明已完成"}
]

{:ok, server} = AgentSystemsLab.start_run(
  run_id: id, input: "修复税额方向并记录说明", workspace: workspace,
  model_timeout_ms: 300_000, run_timeout_ms: 600_000,
  script: script
)

{:ok, planned} = RunServer.step(server)
{planned.state.status, planned.state.pending_operation_id}
# => {:waiting_tool, "read-001"}

{:ok, read_done} = RunServer.step(server)
read_done.state.operations["read-001"].result
# => 带 type、operation_id、tool、output 的结果封装；output 含读取内容与 hash

{:ok, patch_planned} = RunServer.step(server)
patch_planned.state.pending_operation_id
# => "patch-001"
File.read!(Path.join(workspace, "invoice.txt")) == source
# => true，工具提议不是效果

{:ok, patch_done} = RunServer.step(server)
File.read!(Path.join(workspace, "invoice.txt"))
# => "total = subtotal + tax\n"

{:ok, finished} = RunServer.run_until_pause(server)
{finished.state.status, finished.state.turn_count, map_size(finished.state.operations)}
# => {:succeeded, 4, 3}
File.read!(Path.join(workspace, "repair-notes.txt"))
# => "Changed subtraction to addition.\n"

{:ok, rebuilt} = LabKernel.rebuild(id, finished.events,
  max_turns: finished.state.max_turns)
rebuilt == finished.state
# => true
```

`file_read` 参数只有 `path`；`file_write` 必须提供 `path`、`content`、`expected_sha256`；`file_patch` 必须提供 `path`、`expected_sha256`、`edits`，每个 edit 只有 `old` 和 `new`。参数使用字符串键，不接受额外字段。`"absent"` 只用于创建新文件；修改现有文件必须使用当前内容的 SHA-256。

查看 `finished.file_stats` 与 `finished.tool_stats`。前者应为 `%{requests: 3, reads: 1, writes: 2}`，后者继续属于旧 Mock，不能把两个计数混为一谈。全部检查完成后再 `GenServer.stop(server)`。

## 4. 检查模型可见的 schema 与结果配对

仍使用上节的 `finished` 快照：

```elixir
first_context = hd(finished.provider.requests)
Enum.map(first_context.available_tools, & &1["name"])
# => 包含 mock_write、file_read、file_write、file_patch

read_receipt = read_done.state.operations["read-001"].result
Map.take(read_receipt, [:type, :operation_id, :tool])
# => %{type: "tool_result.v1", operation_id: "read-001", tool: "file_read"}

second_context = Enum.at(finished.provider.requests, 1)
second_context.operations["read-001"].result == read_receipt
# => true

Enum.map(finished.events, &{&1.seq, &1.type})
# => [{1, :run_started}, {2, :tool_requested}, {3, :tool_result_recorded},
#     {4, :tool_requested}, {5, :tool_result_recorded},
#     {6, :tool_requested}, {7, :tool_result_recorded}, {8, :run_succeeded}]
```

schema 是 Runtime 向 Provider 提供的输入契约；服务端仍执行自己的校验，不能相信模型“看过 schema 就一定遵守”。新开一条没有 `workspace` 的 Run，检查 `available_tools` 只公开旧 Mock。让它提议 `file_write`，应在建立 `tool_requested` 和 tool 意图之前拒绝，没有文件效果。

新文件工具结果采用：

```elixir
{:ok, read_receipt}
```

内层 receipt 精确包含 `type`、`operation_id`、`tool`、`output`；外层 outcome 也可以是 `:error` 或 `:unknown`。Kernel 内的 `operation.result` 保存内层封装，`operation.status` 保存 outcome。Kernel 对显式 `tool_result.v1` 封装检查配对；当前 RunServer 对文件工具还强制要求封装，Gateway 总会添加封装。旧 `mock_write` 结果及已有未带版本封装的 v1 历史保留兼容，不强行改写原有 receipt。这个兼容分支也包括过去恰好把 `file_read` 等名称当作未知工具记录的错误结果。

新建一条只到 `waiting_tool` 的文件调用，保存 `before = RunServer.snapshot(server)`。通过 `RunServer.command/2` 提交错误 ID、错误工具名、缺失封装或额外封装字段的结果，分别断言返回错误，且状态、业务事件、文件与预算均不变。即使外层 `operation_id` 正确，内层 ID 或工具名错误也必须拒绝。另从旧 fixture 重放未带封装的历史，证明兼容分支仍可用。工具结果内容是数据；把读取到的字符串解释成下一条命令需要新的模型提议和同样的校验。

## 5. 故障矩阵：每条失败都要检查文件

每项使用新的调用 ID；涉及 Runtime 的失败使用新的 Run，避免终态、已耗预算或已完成调用掩盖目标边界。失败可能在 schema、工作目录能力或执行时发生，应报告具体位置与实际错误，不能要求所有拒绝都产生相同事件。

| 故障 | 构造方式 | 必须证明 |
| --- | --- | --- |
| schema 不符 | 文件工具缺字段、额外字段、atom 键、非字符串内容 | 完整响应未变成工具意图；没有文件执行 |
| 未知工具 | 使用不在目录中的名称 | 保留旧受控错误路径，调用可被接受，但执行无效果并返回 unsupported-tool 错误 |
| 路径越界 | 绝对路径、`../outside.txt`、含反斜杠、保留元数据路径及 `.GIT`、`depſ` 别名 | 请求被拒绝，外部文件 hash 不变 |
| 链接 | 文件或父目录的 symlink 指向外部；普通文件有多个硬链接 | 拒绝访问，外部目标不变 |
| 类型与大小 | 目录、非 UTF-8、NUL、超过 64 KiB 的文件/输出 | 失败不造成部分写入，结果保留调用身份 |
| 父目录不存在 | 向不存在的子目录创建文件 | 不隐式创建目录，没有部分目标文件 |
| 陈旧内容 | 读后由测试宿主修改文件，再使用旧 hash patch/write | 原有外部修改保留，工具不覆盖 |
| 创建冲突 | 对已有文件使用 `expected_sha256: "absent"` | 不覆盖已有文件 |
| 补丁不确定 | `old` 为空、不存在或出现两次 | 文件保持原样，不随意选一个匹配 |
| 后续 edit 失败 | 第一个 edit 可匹配，第二个不能唯一匹配 | 前一个 edit 也没有被落盘 |
| 补丁过多 | 超过 32 个 edit | 没有执行一部分补丁 |
| 取消 | 接受写工具后、执行 step 前 cancel | 已有调用事实保留，目标文件不变 |
| 配对错误 | 结果 ID/工具名与 pending 调用不同 | 不记账、不追加事件、不放行下一轮 |

补丁先在内存中按顺序验证并应用全部 edit，只有最终内容通过约束后才替换目标。把“多个 edit”理解为同一文件的一次提交，不是多个文件的事务。更新使用同目录临时文件、同步和重命名降低半写文件风险；这不使 PostgreSQL 与文件替换成为同一原子事务。

文件工具面向没有恶意并发写者的私人目录。路径检查和 hash 能拒绝确定越界、链接和已知陈旧内容，但不是内核沙箱；检查与实际读写之间仍有 TOCTOU 窗口，也没有跨进程 lease 或 fencing。不要对不受信任者能随时换目录项的共享目录宣称同样保证。

路径组件还拒绝 `.git`、`.runtime`、`.agents`、`.codex`、`.aws`、`.ssh`、`_build`、`deps` 及内部临时文件前缀；workspace 根路径及其祖先也不能包含保留组件。比较前先做 Unicode casefold，因此 `.GIT`、`.awſ`、`depſ` 等文件系统别名也被拒绝。根路径和相对路径禁止全部 C0 与 DEL 控制字符，包括 NUL、换行、CR 和 tab，避免伪造 diff header。失败结果可从 `operation.status == :error` 和 `operation.result.output` 读取，例如 hash 不符为 `:base_mismatch`、补丁无匹配为 `:patch_not_found`、多个匹配为 `:patch_ambiguous`。目录内某个文件不存在则通常是 `{:filesystem, :enoent}`；核对精确错误，不把普通 IO 失败误认为 schema 拒绝。

## 6. 分清去重、调用 ID 与重试

使用文件适配器测试证明两类行为：

1. 同一适配器实例收到相同 ID、工具名和参数，返回原结果，不重复文件效果。
2. 相同 ID 搭配不同工具或参数，得到冲突，不执行第二次动作。

可在 IEx 用独立子目录验证执行侧台账：

```elixir
alias AgentSystemsLab.Tools.Files
ledger_workspace = Path.join(workspace, "ledger-demo")
File.mkdir!(ledger_workspace)
File.chmod!(ledger_workspace, 0o700)
{:ok, files} = Files.new(ledger_workspace)
args = %{"path" => "once.txt", "content" => "once\n", "expected_sha256" => "absent"}
{{:ok, receipt}, files} = Files.execute(files, "once-001", "file_write", args)
{{:ok, repeated}, files} = Files.execute(files, "once-001", "file_write", args)
repeated == receipt
# => true，即使目标已存在，也从台账返回原调用结果

{{:error, :operation_id_conflict}, files} =
  Files.execute(files, "once-001", "file_write", %{args | "content" => "changed\n"})
Files.stats(files)
# => %{requests: 3, reads: 0, writes: 1}
File.read!(Path.join(ledger_workspace, "once.txt"))
# => "once\n"
```

`Files.execute/4` 返回 `{result, next_state}`，必须传递新状态才能保留去重台账；它返回的底层结果尚未包含 Gateway 添加的配对封装。requests 包含有效 ID 的重复与冲突，reads/writes 只计实际成功访问。然后与 Kernel 做对比：模型在同一个 Run 中再次提出已经接受的 `operation_id`，即使参数完全相同，也应得到重复 ID 拒绝。Runtime 不通过“接受第二条同 ID 的模型操作”实现去重；适配器台账是执行侧的另一道保护。

该台账保存在内存，重启后丢失。重复调用的缓存读取结果不代表文件现在仍保持原内容；缓存写入结果也不能证明重启后的新实例知道先前效果。记录一次文件已经替换、结果尚未写入数据库时崩溃的时间线：再次执行可能遇到旧 hash 失配，但这不能替代原操作的持久回执。解释为什么本周不自动重试未知文件效果。

结果中的 diff 使用整个文件的单一 hunk，能被标准 unified/Git patch 工作流审查和应用；它不是最小变更行的美化 diff。新建非空文件用 `/dev/null` 作为原文件，创建空文件使用 Git 的 `new file mode` 扩展头。diff 由有界前后文件派生，可能超过单文件的 64 KiB 限额。

取消限制未来动作。若文件写入已发生，随后取消不会还原它；若结果为 `unknown`，不能据取消状态断言文件没有改变。继续沿用 L01 的核对原则，而不是把新文件工具误认为数据库事务的一部分。

## 7. PostgreSQL 只保存已接受事实

若前面使用关闭 Repo 的内存会话，先退出 IEx；完成第 2 节数据库准备后，在 shell 用 `LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/iex` 新开会话。

用全新 Run ID 重做第 3 节，加入 `storage: :postgres`。每个接受的工具提议后检查：

```elixir
{:ok, saved_plan} = Storage.load(id)
{saved_plan.state.status, saved_plan.intent.kind}
# => {:waiting_tool, "tool"}
```

每次工具完成后检查：

```elixir
{:ok, saved_result} = Storage.load(id)
saved_result.state == RunServer.snapshot(server).state
# => true
saved_result.state.operations["read-001"].result.type
# => "tool_result.v1"
```

最终状态应是 `succeeded`，无 pending 意图；Run、Event 和意图转换继续遵守 L02 的事务提交。读取结果与调用身份一起进入业务历史，因此可在新 BEAM 中安全读取与重建。Provider 游标、文件适配器台账、执行中的文件操作和 W4 运行时预算仍不构成持久 checkpoint。

为了证明重建没有副作用，先保存最终文件 hash 与适配器统计，再重复 `LabKernel.rebuild/3` 和 `Storage.load/1`，断言状态一致、文件 hash 与统计不变。进一步在停掉 RunServer 后由测试宿主移动或删除本次练习文件，再读取已提交历史；历史内容不应依赖重新读取文件。实验结束仅清理自己创建的目录与 Run 数据。

再测试数据库先取消一条 `waiting_tool` Run，旧 RunServer 的工具 `step` 必须拒绝，文件保持未修改。已知陈旧状态检查仍不能消除读完数据库到文件替换之间的竞争，不要把这条回归写成跨系统事务或 fencing 已完成。

## 8. 临时破坏实现并收集反例

先写保护测试并确认通过，每次只临时引入一个缺陷；观察目标测试失败后恢复。至少完成两项。

| 临时破坏 | 应触发的保护测试 |
| --- | --- |
| schema 忽略额外参数 | 未知字段被接受，或产生本不该有的 tool 意图 |
| `Path.expand` 后只做字符串前缀检查 | 同名前缀目录、`..` 或链接越界的反例失败 |
| 不检查当前 SHA-256 | 陈旧 patch 覆盖宿主的新内容 |
| 每个 edit 匹配成功后立刻写文件 | 第二个 edit 失败却留下第一个 edit 的修改 |
| 只校验外层结果 ID | 内层 ID 或工具名伪造仍可记账 |
| 去重只比较 ID | 改参数后返回旧成功，而不是冲突 |
| rebuild 调用工具执行器 | 重建后文件 hash 或执行统计发生变化 |

破坏实验应指向真实分支和明确断言。不能用“命令报错了”代替“目标文件没有被修改”，也不能只测试当前文件内容而漏掉外部链接目标、临时文件残留或业务事件。

## 9. 验收与评分

运行完整验收和一条新的离线修复：

```sh
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
./scripts/mix lab.repair --output artifacts/week05-repair-review
```

交付 `notes/L04-report.md`、保护测试、修复前后验证输出、`repair.diff`、调用与结果配对表、持久事件证据、至少两次破坏与恢复记录。报告中区分“自动化已验证”“本次人工观察”与“尚未提供的保证”。

| 项目 | 分值 | 可复核证据 |
| --- | ---: | --- |
| schema 与能力公开 | 20 | 无 workspace 的目录能力、严格参数、非法响应未建工具意图 |
| 调用与结果配对 | 20 | 唯一 ID、封装 ID/工具名校验、下轮 Provider 确实收到结果 |
| 文件边界与补丁 | 30 | 路径/链接/大小/内容/hash/多 edit 失败均无部分效果 |
| 离线修复 | 15 | 固定 fixture 修复前失败、修复后通过，diff 可关联到调用 |
| 持久化与解释 | 15 | 新 VM 读取、重建无文件效果、两次破坏、跨系统崩溃窗口 |

通过门槛为 80 分，并同时满足：模型没有 shell 或任意目录能力；新文件工具结果严格配对；补丁预检失败不留下部分内容；现有完整测试通过；没有声称本地台账是持久 exactly-once、文件与 PostgreSQL 同事务或私人目录检查是操作系统沙箱。

独立完成后再阅读 [参考解答](solutions/L04.md)。
