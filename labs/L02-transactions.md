# L02：提交成功与调用成功之间，任务去了哪里

对应计划第 3 周。建议实验时间 8—12 小时，分三次完成。前置知识为 L01、Ecto 基本查询、SQL 事务和进程监控。

完成后，你应能在真实 PostgreSQL 上证明：Run、Event 与调度意图同时提交或同时回滚；调用者没有收到成功时，数据库仍可能已经提交；事件与状态投影可以在进程退出后重新读取。你还应能明确指出，本实验为何尚未保证外部工具只执行一次。

## 1. 先预测故障结果

新建 `notes/L02-report.md`，先填写下面的预测表，运行实验后再补“实际观察”和证据位置。

| 故障点 | Run | Event | 当前 pending 意图 | 调用者收到成功了吗 |
| --- | --- | --- | --- | --- |
| 首次接收，COMMIT 前 kill | ? | ? | ? | ? |
| 首次接收，COMMIT 后、ACK 前 kill | ? | ? | ? | ? |
| 已有 Run 的转换，COMMIT 前 kill | ? | ? | ? | ? |
| 已有 Run 的转换，COMMIT 后、ACK 前 kill | ? | ? | ? | ? |

后两行要分别比较“旧版本”和“新版本”，不能只填“有数据”。写下四条不变量：

1. 一个已提交 Run 的 `state.seq` 与完整有序事件相符，重建状态等于持久投影。
2. 非终态只有与当前版本对应的 pending 意图；终态没有 pending 意图。
3. 转换失败不能留下单独的新事件、投影或意图。
4. 同一旧序号上的竞争转换最多一项提交。

阅读 [ADR 0002](../docs/adr/0002-transactional-storage.md)，画出 BEGIN、Kernel 决策、各表写入、COMMIT 和 ACK 的先后顺序，并标出两个 kill 点。

## 2. 准备真实 PostgreSQL

在仓库根目录运行：

```sh
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
./scripts/postgres status
./scripts/mix setup
env -u DATABASE_URL ./scripts/mix check
./scripts/mix lab.verify_db
```

本页后续命令在同一终端继续，IEx 继承这两项设置；新开终端时先重新执行两条 `export`。本实验使用真实 PostgreSQL，但手动检查调度意图，不启用后台 Scheduler。L01 的内存路径不能替代本册的提交边界验证。

项目脚本把 PostgreSQL 安装与数据放在项目本地目录。首次准备需要下载和构建；后续运行使用本地服务。默认连接为 `127.0.0.1:55432`、用户 `postgres`；开发库为 `agent_systems_lab_dev`，测试库为 `agent_systems_lab_test`。可用 `DATABASE_URL`，或 `PGHOST`、`PGPORT`、`PGUSER`、`PGPASSWORD` 指向你自己的实验实例。自备实例也要创建和迁移对应数据库。

`setup` 和测试会写数据库，先确认连接指向可丢弃的实验数据库。在报告中记录实际 PostgreSQL 版本、连接目标、`fsync`、`synchronous_commit` 和命令输出。数据库密码不写入报告。

如果还没有项目 Elixir/OTP 与依赖，先按 README 执行运行时安装、`local.hex` 和 `deps.get`。使用项目交互入口，保证运行时与缓存路径一致：

```sh
./scripts/iex
```

在 IEx 查看真实服务器配置：

```elixir
alias AgentSystemsLab.{Repo, Storage}
alias AgentSystemsLab.Kernel, as: LabKernel

Ecto.Adapters.SQL.query!(Repo, "SELECT version()", []).rows
Ecto.Adapters.SQL.query!(Repo, "SHOW fsync", []).rows
Ecto.Adapters.SQL.query!(Repo, "SHOW synchronous_commit", []).rows
```

本实验要求持久路径启用 `fsync`，提交使用同步确认。如果结果不同，先修正实验实例配置并重新验证，再解释哪些结论仍成立。应用进程 kill 不能代替数据库主机断电或磁盘损坏测试。

## 3. 接收、推进、重建

继续在同一 IEx 会话运行。每次练习使用新编号，避免把上次提交误认为这次提交：

```elixir
id = "l02-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
{:ok, accepted} = Storage.create_run(id, "写一条模拟草稿")
{accepted.state.status, accepted.state.seq, length(accepted.events), accepted.intent.kind}
# => {:running, 1, 1, "model"}

{:ok, loaded} = Storage.load(id)
loaded.state == accepted.state
# => true

{:ok, rebuilt} = LabKernel.rebuild(id, loaded.events, max_turns: loaded.state.max_turns)
rebuilt == loaded.state
# => true
```

`create_run` 接收并开始任务，因此第一次成功快照已经是 `running`，不是未开始的 `queued`。意图只说明下一步要做什么，创建它不会调用 Provider。

提交一个工具提议：

```elixir
call = %{
  operation_id: "draft-001",
  tool: "mock_write",
  arguments: %{"key" => "draft.txt", "value" => "hello"}
}

{:ok, waiting} =
  Storage.dispatch(id, accepted.state.seq, {:model_response, {:call, call}})

{waiting.state.status, waiting.state.seq, waiting.intent.kind}
# => {:waiting_tool, 2, "tool"}

Enum.filter(Storage.pending_intents(), &(&1.run_id == id))
```

最后一行应只找到当前版本的待办；第一次的 model 意图已在同一事务中被标记为 superseded。意图的 `kind` 和 `status` 是数据库字符串，Kernel 的 status 是 atom。阅读迁移与 Storage 源码，查询这项任务的历史意图：

```elixir
Ecto.Adapters.SQL.query!(Repo,
  "SELECT seq, kind, status FROM lab_intents WHERE run_id = $1 ORDER BY seq", [id]).rows
# => [[1, "model", "superseded"], [2, "tool", "pending"]]
```

分别指出旧、新意图的版本与状态。不要把历史记录数与 pending 意图数混淆。

这里没有实际执行 Mock。向 Storage 发送以下结果只代表你作为实验调用者提交事实：

```elixir
{:ok, resumed} =
  Storage.dispatch(id, waiting.state.seq, {:tool_result, "draft-001", {:ok, %{"saved" => true}}})

{:ok, finished} =
  Storage.dispatch(id, resumed.state.seq, {:model_response, {:final, "草稿完成"}})

{finished.state.status, finished.intent}
# => {:succeeded, nil}
Enum.filter(Storage.pending_intents(), &(&1.run_id == id))
# => []
```

独立任务：重新走一条含 `{:unknown, reason}` 的路径，验证 `blocked` 的意图为 reconcile，核对后改回 model，取消后没有 pending 意图。每一步都 `load`、重建并比较状态；不能只检查内存变量。

再阅读 `Storage.Codec`。v1 使用带版本的未压缩 ETF，`binary_to_term` 启用 `:safe`，并额外限制可保存的数据类型、大小与嵌套深度。它保留本地 BEAM 的数据形状，不能创建接收 VM 尚不存在的 atom。业务参数与任意结果优先用字符串键和值；本实验中的 Kernel atom 属于预先加载的代码词汇。这个格式不承诺跨语言兼容；未来换格式需新 codec 版本和显式迁移，不能改成不安全解码以“修复”旧数据。独立补一条测试，证明 PID 或函数等运行时值不会被持久化。

## 4. 先拒绝非法更新，再制造竞争

创建一个新任务，记录完整快照，然后尝试不合法的工具结果。应得到错误，重新读取后的状态、事件和当前意图都与原快照相同。

另建一个任务，让两个独立进程使用同一 `expected_seq` 提交不同的最终回答。用 `Task.async` 启动两次调用，收集两个返回值；要求恰好一个成功、一个版本冲突，数据库只多出一个事件，终态只有其中一个回答。另一个调用失败后，不应更换序号自动提交到已完成任务。

这一步验证“调用者基于哪个版本作了决策”。数据库行锁让两次检查按顺序进行；它不代表某个 Worker 拥有长期执行权，也还没有实现 lease 或 fencing。

## 5. 在两个提交边界 kill 调用进程

先阅读项目崩溃测试，再独立写出自己的版本。测试必须使用真实连接提交，不能给整条测试套 SQL Sandbox 外层事务。

Storage 写接口主动拒绝外层 Repo 事务，返回 `{:error, :nested_transaction_not_supported}`。独立加一个测试确认这项保护，不要通过移除它让 Sandbox 测试“变绿”。

下面是 IEx 可运行的屏障练习。`spawn_monitor` 避免把被杀进程链接到 IEx；它只在到达指定边界后才通知父进程。整个练习应逐块运行，不用 `sleep` 猜测提交时机：

```elixir
parent = self()
crash_id = "l02-kill-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
phase = :before_commit

hook = fn reached ->
  if reached == phase do
    send(parent, {:at_boundary, self(), reached})
    receive do
      :continue -> :ok
    end
  end
end

{pid, ref} = spawn_monitor(fn ->
  result = Storage.create_run(crash_id, "检查提交边界", hook: hook)
  send(parent, {:call_returned, self(), result})
end)

receive do
  {:at_boundary, ^pid, ^phase} -> :boundary_reached
after
  5_000 -> raise "未到达屏障；先检查调用进程与数据库"
end

Process.exit(pid, :kill)

receive do
  {:DOWN, ^ref, :process, ^pid, :killed} -> :caller_killed
after
  5_000 -> raise "未观察到调用进程退出"
end

Storage.load(crash_id)
# 提交前 => {:error, :not_found}

Ecto.Adapters.SQL.query!(Repo, """
SELECT
  (SELECT count(*) FROM lab_runs WHERE id = $1),
  (SELECT count(*) FROM lab_events WHERE run_id = $1),
  (SELECT count(*) FROM lab_intents WHERE run_id = $1),
  (SELECT count(*) FROM lab_intents WHERE run_id = $1 AND status = 'pending')
""", [crash_id]).rows
# 提交前 => [[0, 0, 0, 0]]
```

先预测最后一行，再执行。提交前退出应没有这项 Run，也没有孤立事件或意图；还要从数据库分别查三张表，不能只把 `load` 返回不存在当作全部证据。读取应从父进程执行，位于被杀事务之外。

换一个全新 `crash_id`，把 `phase` 改成 `:after_commit`，完整重做上面练习。此时调用进程仍未返回 `{:ok, snapshot}`，但父进程应读到 `running`、首个 Event 和 model 意图。用 `pending_intents/0` 找到该 Run，再重建并比较快照。这证明即使 ACK 丢失，已提交待办仍可由扫描发现。

独立任务：

1. 把同样的屏障用于已有任务的 `dispatch`。提交前 kill 应保持完整旧版本；提交后 kill 应得到完整新版本。
2. 对新版本检查事件序号、投影、旧意图 superseded 和新 pending 意图，不只检查 status。
3. 两个边界都验证没有收到 `{:call_returned, pid, {:ok, _}}`，说明客户端知识与数据库事实可以不同。
4. 将测试中的 `:kill` 临时换成抛异常，再比较日志和退出原因；最终保留真正的 kill 测试。能抛异常回滚，不代表已覆盖不可捕获终止。

数据库连接在事务所有者突然退出后需要清理。对“提交前无数据”的验证可用有截止时间的短轮询等到连接清理完成，但不能把任意长 sleep 作为同步机制。提交屏障和进程 DOWN 是主要证据。

## 6. 换一个 BEAM 再读取

在开发库创建一项任务，记下固定 Run ID。退出 IEx，重新运行 `./scripts/iex`。新 IEx 不继承原会话的别名或变量；先执行：

```elixir
alias AgentSystemsLab.Storage
```

再把记下的完整 Run ID 字符串传给 `Storage.load/1`，比较事件和状态；不能继续引用旧会话的 `id`、`loaded` 等变量。再停止、重新启动项目 PostgreSQL，重复读取。

这项练习使用正常关闭和重启，证明数据不依赖原 IEx 内存；不能据此声称已验证断电、数据库介质损坏或异地故障转移。报告写出你实际上停止了哪一层。

进一步阅读 RunServer 的 `storage: :postgres` 路径，完成一个持久模式的正常任务，检查进程快照与 Storage 快照相符：

```elixir
alias AgentSystemsLab.Storage
run_id = "l02-server-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
{:ok, server} = AgentSystemsLab.start_run(
  run_id: run_id, input: "持久化最终回答", script: [{:final, "完成"}], storage: :postgres)
{:ok, runtime} = AgentSystemsLab.RunServer.run_until_pause(server)
{:ok, durable} = Storage.load(run_id)
{runtime.state == durable.state, runtime.events == durable.events, durable.intent}
# => {true, true, nil}
GenServer.stop(server)
```

读取已持久化 Run 的入口是 `Storage.load/1`。RunServer 当前按新任务创建，同一 Run ID 再次启动会返回 already_exists；没有自动续跑接口。load 不会补回 Provider 的内存游标和 Mock 的旧台账。不要用重建一个新 Mock 然后自动执行 waiting_tool 来冒充安全恢复。

## 7. 故意破坏，再用测试修复

每次先保存一条保护测试，确认其通过，临时制造一种缺陷，看见预期失败后恢复实现并重新跑完整检查。至少实际完成下表两项，并保存失败断言与原因。

| 临时破坏 | 应失败的证据 |
| --- | --- |
| Run 与 Event 提交后，再另开事务写意图 | 在两事务之间 kill 后出现有 Run、无 pending 意图 |
| 删除 expected_seq 检查 | 同一个旧版本的两个转换被接受，或失败原因不再反映版本冲突 |
| 转换时保留旧 pending 意图 | 当前扫描得到多个版本的待办 |
| 在事务提交前向调用者发送成功 | 收到成功后 kill，独立连接却找不到完整事实 |
| 读取时只相信投影、不核对事件 | 人为破坏投影或事件后，load 未报告不一致 |

破坏数据只在可丢弃的测试任务上操作，并在练习后清理。不要把故障钩子移到不相干的位置后继续声称测试覆盖了 COMMIT 边界。

## 8. 三种保证分别写清楚

把下面三个问题各写成一段，引用你自己的具体证据：

- **ACK 丢失**：调用者没有成功返回，为什么仍然可能查到完整 Run？如何用稳定 ID 和序号确认事实？
- **存储持久性**：`fsync` 和 `synchronous_commit` 分别影响什么？应用进程 kill、BEAM 重启、数据库正常重启各验证了哪一层？
- **外部效果**：调度意图已提交后，工具执行成功、结果尚未提交时进程退出，会发生什么？为什么本地事务和 pending 扫描不能独立保证工具效果只发生一次？

将 L01 的丢回执路径接到你的图上。注意 `blocked → reconcile` 表达待核对工作，尚不意味着后台核对器已经实现。

## 9. 验收与评分

运行并保存结果：

```sh
env -u DATABASE_URL ./scripts/mix check
./scripts/mix lab.verify_db
```

交付自己的 ExUnit 测试、提交时序图、四行故障表、数据库配置、跨进程读取证据、至少两次破坏再修复记录和 `notes/L02-report.md`。`lab.verify_db` 是项目提供的验收入口，只运行它不能替代独立实验。

| 项目 | 分值 | 可复核证据 |
| --- | ---: | --- |
| 事务模型与不变量 | 15 | 三类事实的原子边界、ACK 位置与四行预测 |
| 正常转换与重建 | 15 | model/tool/reconcile 意图、终态、历史 superseded 与事件一致性 |
| 提交前后崩溃 | 30 | create 与 dispatch 各两个边界；独立连接、真 kill、三张表断言 |
| 并发与错误回滚 | 15 | 旧序号竞争只有一个成功；非法命令不产生部分事实 |
| 破坏再修复 | 15 | 至少两次预期失败及规则恢复后的完整检查 |
| 故障模型解释 | 10 | 清晰区分 ACK、数据库持久提交、外部效果与后续调度 |

通过门槛为 80 分，同时满足四条硬性要求：崩溃测试没有外层 Sandbox 事务；使用明确提交屏障和真正的进程 kill；检查 Run、Event 与意图三类事实；不把本地事务描述为外部效果 exactly-once 保证。未满足硬性要求，先修复再验收。

实验完成后可停止本地服务：

```sh
./scripts/postgres stop
```

独立完成后再阅读 [参考解答](solutions/L02.md)。
