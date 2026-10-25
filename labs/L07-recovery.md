# L07：崩溃后安全续跑

对应第 8 周，建议用时 12—16 小时。前置实验为 L01—L06。本周使用 L07，主题是已提交事实之上的执行恢复。

本次要证明：原执行进程退出后，新进程能够读取持久配置与历史，领取当前调度意图，继续尚未完成的工作；已经完成的逻辑操作不会因回执丢失或重复投递再次产生 Mock 业务效果。无法核实的文件效果必须保留为未知，停在明确的人工核对边界。

## 1. 先划清重建、恢复和重试

阅读 [ADR 0007](../docs/adr/0007-recovery-and-operation-attempts.md)，为下面每项写出它需要的事实。

| 操作 | 需要什么 | 可以产生新效果吗 |
| --- | --- | --- |
| History / checkpoint 重建 | 合法 Event、原 Kernel 选项和经验证的 checkpoint | 不可以；仅重建 State |
| Recovery load | 合法历史，以及原先持久保存的执行配置、预算、游标和 deadline | 不执行；只返回可审计快照 |
| Recovery resume / step | 经验证的配置与进度，以及当前意图的有效 claim | 可以；resume 推进到暂停，step 推进一步 |
| 意图领取 | 当前 Run/seq、pending 意图、owner、有效 lease 与代次 token | 不执行模型或工具；建立推进资格 |
| 工具投递 | 逻辑 operation、独立 attempt、工具能力与有效资格 | 可以；依赖幂等或核对协议 |
| 结果核对 | 已保存回执、可查询的外部事实或明确人工证据 | 通常只读；确定结果后提交新 Event |

`waiting_tool` 只说明 Kernel 尚未接受结果，不能证明工具尚未执行。`blocked` 说明结果未知，不能解释为失败或“可以重新执行”。caller 没有拿到 ACK，也不能证明数据库没有提交。

本周新增独立 Recovery 驱动。原 RunServer 继续提供前几周的易观察进程实验；它的 Provider 游标、预算和工具台账仍是临时状态。旧 Run 没有保存 Recovery 配置时，应明确拒绝续跑，不能从事件数猜 Provider cursor，也不能创建新 Mock 后假装恢复了旧台账。

## 2. 运行恢复演示

在项目根目录执行：

```sh
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
env -u DATABASE_URL ./scripts/mix check
./scripts/mix lab.recover
```

后续命令与 IEx 沿用这个终端；另开终端时先重新设置上述两个环境变量。本实验需要启用 Repo，由观察者显式调用 step/resume，不让全局 Scheduler 抢先领取示例意图；关闭后台调度不会禁止演示自己的受控执行。

演示产物、准确测试计数和实际故障点见 [第 8 周验收记录](../docs/validation-week08.md)。重复运行使用新的输出目录，避免覆盖已有证据：

```sh
./scripts/mix lab.recover --output artifacts/week08-recovery-second
```

检查演示是否把以下三种数量分别报告：模型请求 attempt 数、工具 delivery attempt 数、业务效果数。三个数不能互换。一个逻辑工具操作可以被投递多次；每次投递有自己的 attempt 身份，而外部系统按稳定 operation 身份去重。

保存一份运行前后对照表：

| 事实 | 崩溃前 | 新进程读取后 | 续跑完成后 |
| --- | --- | --- | --- |
| Run ID 与已接受 Event seq | 原值 | 相同 | 按新事实增长 |
| Provider cursor | 已持久记录的值 | 相同 | 按接受规则增长 |
| 累计预算与绝对 deadline | 已持久记录的值 | 不重置 | 只能按规则消费 |
| logical operation ID 与参数 | 原值 | 相同 | 保留原回执和配对 |
| delivery attempt | 已开始或完成 | 可审计 | 可以新增投递，不能改 operation 身份 |
| Mock 业务效果数 | 已提交效果数 | 相同 | 同一 operation 最多一个效果 |

然后用 `./scripts/iex` 创建独立的可续跑 Run，明确区分 `load`、`step` 与 `resume`：

```elixir
alias AgentSystemsLab.Recovery
suffix = "#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
id = "l07-simple-#{suffix}"
call = %{operation_id: "save-001", tool: "mock_write", arguments: %{"value" => "saved"}}
{:ok, first} = Recovery.create_run(id, "完成一次离线保存",
  script: [{:call, call}, {:final, "保存完成"}],
  max_turns: 4, max_model_attempts: 8,
  run_timeout_ms: 600_000, model_timeout_ms: 30_000)
:running = first.state.status
{:ok, unchanged} = Recovery.load(id)
true = unchanged.state === first.state
{:ok, proposed} = Recovery.step(id, owner: "l07-worker-a")
:waiting_tool = proposed.state.status
{:ok, done} = Recovery.resume(id, owner: "l07-worker-b")
:succeeded = done.state.status
"保存完成" = done.state.output
```

`create_run` 在接收任务时保存 Recovery 配置。`load` 不领取意图、不消费脚本、不调用工具。`resume` 是执行入口，会在当前状态允许时调用模型和工具，直到完成、失败或需要核对。它不是只读重建的别名；`step` 只处理当前一步。`owner` 默认生成新的 UUID；示例使用明确名字便于查看竞争记录。

可选创建配置包括已验证的 immutable `session:`、`context_options:` 和受控文件 `workspace:`。同一 Run 的后续 resume 不重新传这些策略；配置留在数据库，避免新 worker 不小心扩大权限或重新分配预算。`mock_mode: :idempotent | :unqueryable` 和 `mock_response: :ok | :lost | :fail_before_effect` 是离线能力/故障策略，不是运行中任意更改业务结果的接口。

查看进度与工具账本：

```elixir
alias AgentSystemsLab.DurableTools
2 = done.recovery.progress.cursor
2 = done.recovery.progress.model_attempts
true = done.recovery.progress.output_bytes > 0
%{effects: 1, operations: 1, attempts: 1} = DurableTools.stats(id)
{:ok, [operation]} = DurableTools.list(id)
"completed" = operation.status
1 = length(operation.attempts)
```

`stats.effects` 只统计持久 Mock 的业务效果，不统计文件写入，也不授权核对结果。`list` 校验 operation 与历史中的参数绑定，并返回包括 claim 代次、投递类型、结果和人工证据的 attempts。读取旧 Run 的 Kernel 事实仍可使用 `Storage.load/1`；缺少 Recovery 配置时，`Recovery.load/1` 返回 `{:error, :run_not_resumable}`。

## 3. 解释一次安全 step 的提交顺序

从源码画出模型路径与工具路径。至少标出以下边界：

1. 读取并验证 Run/Event/意图与 Recovery 配置。
2. 领取当前 pending 意图，获得 owner、lease 与代次 token。
3. 持久保存请求或投递 attempt，并在产生效果前保存必要身份与输入。
4. Provider 在长期数据库事务之外运行；本地工具在短临界区重新核对 claim 后执行，效果与最终 Runtime 结果仍分开提交。
5. 使用仍有效的 claim 与 expected seq 提交结果；同一事务更新 Run、Event、旧意图与下一意图，并写入应当一起提交的录制或 Recovery 进度。
6. ACK 丢失时重新读取事实，不根据旧调用栈判断成功或失败。

模型请求先保存 Context。完整候选通过 schema、预算和 Kernel 校验后，才成为已接受的响应与录制。未完成的流不能直接作为已接受回答，也不能用它拼接一条“恢复后的旧网络连接”。本周使用确定性的离线 Scripted Provider；持久脚本需要通过安全 Codec，不能把测试 owner PID、reference 或匿名函数写进 Recovery 配置。

本地 Mock/Files 的短临界区持有 Run 锁，防止取消或接管刚好越过授权检查；这不是让文件系统参加数据库事务。文件已经替换后，数据库回滚仍不能撤销它。不要把这个仅面向有界本地工具的临界区照搬成等待任意远程 API 的长期事务。

预算策略、已消费量、请求尝试与绝对 deadline 都必须来自持久数据。每个模型 attempt 在 Provider 调用前占用 `max_model_attempts` 的一次机会；每个输出 frame 在 ACK 前持久扣除累计字节和当前请求帧数。崩溃时已经扣除的字节保留，下一个 attempt 的请求帧计数重新开始；cursor 只有完整响应与 Event/录制一起接受时才前进。重启后重新执行 `Budget.new/1`、把 output_bytes 清零、重新生成一段完整 run timeout，都属于预算绕过。Kernel 的 `max_turns` 只约束已接受模型响应，不能单独代表所有失败或中断请求的资源支出。

## 4. 同一意图只能有一个有效推进者

两个 worker 同时读取相同 pending 行是正常竞争。领取操作要在数据库中互斥，不能先查后改，也不能只依赖本机 Registry。

完成四组实验：

1. Worker A 领取后，Worker B 立即领取同一意图。B 应得到忙或无可领取结果，而不是同时成为 owner。
2. A 续租，原 token 继续有效；伪造 owner/token 的续租或释放应拒绝。
3. A 的 lease 过期，B 取得新代次。A 再提交旧结果应失败，Run/Event 不变化。
4. A 持有 claim 时取消 Run。取消 supersede 原意图；A 迟到的提交应失败，不能覆盖取消终态。

比较的是持久代次与当前意图状态。仅比较 `owner == "worker-a"` 不够：同一 owner 名字可以在重启后再次使用，旧消息仍可能迟到。lease 到期也不会终止旧 worker；它只让新的领取成为可能，因此提交时必须重新验证。对于数据库之外的工具效果，还需要稳定 operation 身份和工具自己的去重或核对能力。

本周实现每个意图必需的最小领取、续租、释放和 fencing。它不是公平调度器，没有常驻扫描 daemon、优先级、多队列、公平性或生产级 worker 管理。

用另一个 Run 直接观察领取协议，完成后释放给 Recovery：

```elixir
alias AgentSystemsLab.IntentStore
claim_id = "l07-claim-#{suffix}"
{:ok, _} = Recovery.create_run(claim_id, "检查领取", script: [{:final, "领取完成"}])
{:ok, original} = IntentStore.claim(claim_id, "worker-a", lease_ms: 10_000)
{:error, :intent_claimed} = IntentStore.claim(claim_id, "worker-b")
{:ok, renewed} = IntentStore.renew(original, lease_ms: 60_000)
true = renewed.token === original.token and renewed.generation === original.generation
:ok = IntentStore.release(renewed)
{:ok, next} = IntentStore.claim(claim_id, "worker-b")
true = next.generation === original.generation + 1
{:error, :stale_claim} = IntentStore.release(original)
:ok = IntentStore.release(next)
{:ok, _} = Recovery.resume(claim_id)
```

过期测试通过专用测试 Run 的数据库时间边界控制，接管后再次提交旧 token；不要修改真实运行中的行制造接管。过期只改变领取资格，不自动产生任何业务 Event 或外部效果。

## 5. 逻辑操作、投递尝试与业务回执

用同一 Run 中的一次 `mock_write` 完成实验。先记录 operation ID、tool、完整参数及其绑定，再使回执在效果提交后丢失。

| 记录 | 表达什么 | 不能代替什么 |
| --- | --- | --- |
| operation | 稳定的业务意图与精确参数 | 不能仅用 attempt ID 作为去重键 |
| delivery attempt | 一次具体执行或查询经过 | 不意味着又发生一个业务效果 |
| receipt | 外部系统已知的业务结果 | 不能用 timeout 或本地提交缺失伪造 |
| Kernel result Event | Runtime 已接受的观察结果 | 缺少它不证明外部没有效果 |

重复提交同 operation 与相同参数应返回原回执；同 operation 搭配不同参数必须冲突，业务效果数不增长。新进程重新创建一个临时 Mock，再看见它的计数为 0，不算去重证明。这里应读取本周持久 Mock 外部账本，从独立连接或独立 VM 看到原效果。

观察外部效果提交与 Runtime 结果提交之间的窗口。若前者已经完成而后者没有发生，恢复者应先查 operation 回执。查到同一参数绑定的回执后，记录核对结果并推进；不要先重发再查询。幂等工具确需再次投递时仍使用原 operation 身份，另开 delivery attempt，不能为了避开冲突生成新 operation ID。

## 6. 未知结果如何解除

分别验证“可查到已完成”“确定尚未发生”“无法确定”三种情况。`not_found` 只有在工具契约明确给出权威否定、且不存在仍会迟到的旧执行时，才可能支持安全后续动作；一个临时缓存没找到记录不是权威否定。

Mock 可以按稳定身份查询持久回执，因此 lost receipt 可通过核对恢复。一般文件替换没有与 PostgreSQL 的共同事务，也没有能够证明“由这个 operation 完成”的外部回执。已经准备文件操作、但没有可靠保存结果时，即便看到目标内容刚好符合预期，也不能据此断言成功：其他进程可能写入同样内容，原操作可能只完成部分步骤。

下面创建一条回执丢失的独立任务，验证查询与执行分开：

```elixir
lost_id = "l07-lost-#{suffix}"
{:ok, _} = Recovery.create_run(lost_id, "核对丢失回执",
  script: [{:call, call}, {:final, "核对完成"}], mock_response: :lost)
{:ok, unknown} = Recovery.resume(lost_id)
:blocked = unknown.state.status
%{effects: 1, attempts: 1} = DurableTools.stats(lost_id)
{:ok, observed} = Recovery.reconcile(lost_id)
:running = observed.state.status
{:ok, recovered} = Recovery.resume(lost_id)
:succeeded = recovered.state.status
%{effects: 1, attempts: 2} = DurableTools.stats(lost_id)
```

`resume` 遇到 blocked 会返回暂停快照，不自行查询或重发。必须显式调用 `reconcile`；在该例中新增的是 lookup attempt，业务效果数仍为 1。

这类歧义必须保持 unknown 并阻塞，交由人工明确核对。人工决定应绑定 Run、operation、精确预期序号与证据；明确为成功或失败后提交 reconciliation 事实。人工核对不能删除原 attempt，不能直接改 State，也不能假装取消已经撤销外部写入。

`Recovery.reconcile(id)` 默认只查询；不能查明时保留 blocked。可信操作人可以明确提供 `result: {:ok, payload}` 或 `{:error, payload}`，并附非空 `evidence:`。Recovery 会为未包装的 result 生成当前配对封装；也可以显式使用 `Tools.Result.wrap/3` 绑定原 operation ID 与 tool。证据只作为可信操作人的审计声明保存，程序不能自行判断它是否反映真实外部世界。换成 `mock_mode: :unqueryable, mock_response: :lost` 运行上例时，默认 reconcile 应返回 `{:error, :reconciliation_required}`；这时才进入明确人工核对流程。

这个便利入口绑定调用当时的当前操作，适用于低并发教学演练；它没有让调用方传入审阅时 `expected_seq` 的选项。事故处理时，先固定审阅的 seq 和完整 operation，再使用[运行手册第 6 节的 helper](../docs/recovery-runbook.md#6-人工证据与预期序号)；前提变化应返回 `:review_required` 并重新采证。人工核对只接受 `:ok` / `:error`，取消是独立的 `Recovery.cancel/2`，不会产生核对结论。

练习：在文件效果之后、结果提交之前 kill worker。新进程 resume 时应保留原 operation，不再次执行写入。记录写入次数与文件内容；随后提供人工证据完成核对，再继续模型步骤。

## 7. 故障注入矩阵

用显式 hook 或 gate 把进程停在确定边界，再发送真实 `:kill`。不要只靠 `Process.sleep/1` 猜时机，也不要在一个外层回滚事务内模拟 COMMIT。独立进程重新读取数据库，才能排除进程字典、ETS 或未提交连接中的假象。

| 注入入口 | hook stage | 所处边界 |
| --- | --- | --- |
| `hook:` | `:after_claim` | claim 已提交，尚未处理当前工作 |
| `hook:` | `:after_input` | Context 已提交，尚未调用 Provider |
| `hook:` | `:after_frame` | 此 frame 已持久扣账；发生在 Provider worker 中 |
| `hook:` | `:after_model` | 完整候选已校验，尚未接受结果事务 |
| `hook:` | `:before_dispatch` / `:after_dispatch` | 业务转换事务之前 / 成功之后 |
| `tool_hook:` | `:after_prepare` / `:before_effect` | attempt 已准备 / 效果之前 |
| `tool_hook:` | `:after_effect` | 效果临界区已返回，receipt 尚未确认 |
| `tool_hook:` | `:before_receipt` / `:after_receipt` | ledger receipt 提交之前 / 之后 |
| `commit_hook:` | `:before_commit` / `:after_commit` | 最终 Storage 转换真正 COMMIT 之前 / 之后 |

`:after_dispatch` 与 `:after_commit` 是不同注入点。前者在 Storage 返回后，后者在 Storage 内、COMMIT 成功但 caller 尚未收到结果时。测试 `:after_frame` 崩溃时也要区分 Provider worker 与调用 Recovery 的执行进程；只 kill Provider worker 会得到 Provider 失败，不能冒充整个执行进程失联后的接管证明。单独测试 `IntentStore.claim/3` 可通过自己的 `hook:` 注入领取 COMMIT 前后。

| 崩溃位置 | 恢复必须做什么 | 禁止的捷径 |
| --- | --- | --- |
| claim 提交前 | 其他 worker 可正常领取，Run 不变 | 把 caller 未收到 ACK 当成永久 owner |
| claim 提交后、执行前 | 等待/释放/接管有效资格，核对是否已有 attempt | 绕过 lease 同时执行 |
| 请求 attempt 保存后、Provider 返回前 | 依据持久进度处理未完成请求，保留预算与 deadline | cursor 归零或重置资源上限 |
| 模型结果 COMMIT 前 | 不接受半个结果，核对原请求与进度 | 只写 cursor、不写 Event，或反之 |
| 模型结果 COMMIT 后、ACK 前 | 读取已接受结果，消费下一意图 | 再消费同一脚本响应 |
| 工具 attempt 保存后、效果前 | 先查询/核对；仅在能力契约允许时重投 | 假设“没回执”就是“没执行” |
| Mock 效果后、回执前 | 查询原 operation 回执，效果数不增长 | 换 operation ID 再执行 |
| 文件效果后、结果前 | unknown 阻塞并人工核对 | 自动重写或从内容相等猜成功 |
| 结果 COMMIT 后、ACK 前 | 读取已接受结果，继续下一步 | 重复追加工具结果 Event |
| lease 接管或取消之后 | 拒绝旧 token 的迟到结果 | 用旧 worker 内存覆盖新事实 |

每个探针报告原 Run seq、claim 代次、attempt 状态、业务效果数、恢复后的 State 与 Event。允许错误返回，但错误必须说明哪条前提已经失效，不能把冲突静默当作成功。

## 8. 保护测试与完成标准

至少保存以下保护测试，再逐一验证一处有意破坏会使相应断言失败：

- 移除领取互斥或代次校验，两个 worker 的竞争测试应失败。
- 将 cursor 或累计预算在 resume 时置零，跨进程恢复测试应失败。
- 将未知文件操作重新交给文件工具，未知结果测试应观察到禁止的重复执行。
- 给同 operation 更换参数，冲突测试应阻止第二个业务效果。
- 将旧 claim 结果提交到已取消 Run，迟到响应测试应保持终态不变。

恢复实现后执行 `env -u DATABASE_URL ./scripts/mix check`。本周评分建议：持久配置与预算恢复 20 分，claim/lease/fencing 20 分，operation/attempt/receipt 与幂等 20 分，未知结果核对 20 分，真实故障注入与独立进程证据 15 分，边界说明 5 分。

有三条硬性要求：重建路径仍是零效果；恢复不能重置预算或猜测 Provider 游标；未知的非幂等外部效果不得自动重发。任一条件不满足均不算完成。

参考解答见 [L07 解答](solutions/L07.md)。本周只提供离线 Scripted Provider 与明确能力契约下的恢复，不提供真实模型网络连接续接、任意外部系统的 exactly-once、自动回滚文件效果或完整生产调度系统。
