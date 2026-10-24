# P2 故障报告

验收日期：2026-10-21，Asia/Shanghai。验收对象是第 7—9 周形成的历史、恢复、幂等、重试和核对契约。环境为单机 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6，离线 Scripted Provider、持久 Mock 与受控文件工具。

## 验收结论与证据口径

正式执行 `./scripts/mix lab.p2 --repetitions 20`：**16 个确定故障窗口各 20 轮，共 320 个 probe、340 次真实 caller kill，全部通过**。每个 probe 使用独立 Run，原 operation ID 固定为 `once`，原参数固定，恢复始终使用原 Run ID。恢复中再次崩溃的 20 个 probe 各 kill 两次，其余每个 kill 一次。

| 硬性门槛 | 正式实测 |
| --- | ---: |
| 重复 Mock 业务效果 | 0 |
| 已确认本地回执丢失或被改写 | 0 |
| 陈旧凭证写入覆盖新事实 | 0 |
| 持久模型尝试超过当前脚本精确预期 | 0 |
| 完整历史重建与最终 State 不一致 | 0 |
| 完成演练后遗留待核对项 | 0 |
| 新 BEAM 续跑及严格状态比较 | 2 个 probe |
| 新 BEAM 纯重建的模型/工具等效果入口调用 | 18 个入口各 0 次 |

机器原始结果为 [report.json](../artifacts/week10-p2/report.json)，命令输出为 [run.log](../artifacts/week10-p2/run.log)。正式目录保留原 Run 与每次 kill 的完整证据；目录存在时拒绝覆盖。首轮验收在补强目标回执留档之前已通过，另存于 `artifacts/week10-p2-preliminary/`；本文数量只统计冻结后正式一轮。

正式 Run 前缀：`p2-1792514554085679-3653`。另以独立脚本核对报告的 16×20 分布、340 个无 ACK/KILL 记录及所有逐 probe 证据文件，计算结果保存于 [independent-audit.json](../artifacts/week10-p2/independent-audit.json)。

`accepted_cursor_rerequests` 由持久模型尝试数与固定脚本的精确预期比较得出，并交叉核对 cursor 2、两条已接受录制及原录制保留。它是当前受控 fixture 的证据，不是外部模型服务的独立请求遥测。模型接受前崩溃允许消耗另一次未确认请求；模型接受后必须继续当前意图。

## 故障矩阵

每行实际执行 20 轮。`seq / 效果` 是 kill 后、接管前的持久快照；效果来自本地 Mock 目标账本诊断。每次观察到指定屏障后真实 kill caller，收到 `:DOWN/:killed`，并验证 caller 没有返回 ACK，再等待数据库记录的原 lease 自然到期。

| case ID | 故障位置 | seq / 效果 | 恢复依据及实际结果 |
| --- | --- | --- | --- |
| `after_claim` | 领取已 COMMIT，尚未工作 | 1 / 0 | 接管原意图，完成一次工具效果 |
| `model_before_commit` | 模型接受事务 COMMIT 前 | 1 / 0 | 接受事实整体回滚；保留已经花费的尝试与输出，再请求未确认模型结果 |
| `model_after_commit` | 模型接受 COMMIT 后、ACK 前 | 2 / 0 | 原 cursor/录制已接受，直接处理工具意图 |
| `tool_after_prepare` | operation/attempt 准备 COMMIT 后 | 2 / 0 | 幂等 Mock 按原身份完成，目标效果最终为 1 |
| `tool_before_effect` | 工具效果临界区之前 | 2 / 0 | 当前资格重新验证，原身份安全执行 |
| `tool_after_effect` | 目标效果 COMMIT 后、本地回执之前 | 2 / 1 | 幂等目标返回原回执，目标行不增加、不改变 |
| `tool_before_receipt` | 本地回执确认之前 | 2 / 1 | 同一 operation 恢复，保留原目标回执 |
| `tool_after_receipt` | 本地回执 COMMIT 后 | 2 / 1 | 复用本地已确认结果，不重新执行目标 |
| `tool_result_before_commit` | Kernel 工具结果事务 COMMIT 前 | 2 / 1 | 结果 Event 尚未接受；重用回执补齐该事务 |
| `tool_result_after_commit` | Kernel 工具结果 COMMIT 后、ACK 前 | 3 / 1 | 下一意图已提交；直接继续模型，工具结果只接受一次 |
| `recovery_after_effect_twice` | 初始 worker 与恢复者均在效果后失联 | 2 / 1 | 两次退出分别留档，第三个 worker 保留原 operation 并完成；效果仍为 1 |
| `retry_after_reserve` | 预留 ordinal COMMIT 后 | 1 / 0 | 预留不返还，接管记录 abandonment，按原策略退避后完成 |
| `retry_after_schedule` | 暂时失败及 due COMMIT 后 | 1 / 0 | 原 due/错误分类保留，等待真实 due 后继续 |
| `query_before_commit` | 查询回执已确认、核对 Event COMMIT 前 | 3 / 1 | 自动查询最多一次；接管直接接受本地回执，不再消耗查询次数 |
| `query_after_commit` | 核对 Event COMMIT 后、ACK 前 | 4 / 1 | unknown 与核对事实保留，直接继续当前意图 |
| `manual_after_receipt` | unqueryable 的人工回执 COMMIT 后 | 3 / 1 | 自动查询额度不参与；新 owner 复用带原人工 evidence 的本地确认事实 |

以上 320 个 probe 最终均 `succeeded`。这反映这些固定场景具有幂等 Mock 契约或明确的宿主人工证据；**不意味着所有 unknown 都应恢复成功**。文件、核对额度耗尽和不可查询结果的正确暂停另由保护测试验证。

## 两个已修复缺陷

### P2-01：不可查询工具已确认回执无法重新接受

触发：开启 retry，unqueryable 或文件工具已经 unknown；人工 `DurableTools.confirm` 将完整配对回执和 evidence COMMIT，caller 在 Kernel `:reconcile` 接受前被 kill。数据库 operation 已 `completed`，Run 仍 `blocked`。

原行为：`query_reconcile` 先判断查询能力，直接返回 `:reconciliation_required`；重复人工提交也因 `:already_confirmed` 被拒绝。已知回执仍在，却无法推进原 Run。

修复：`Recovery.reconcile(id)` 在没有新人工 result 时，先通过 `DurableTools.confirmed_receipt/3` 在当前 claim 下校验本地 operation、输入绑定、配对结果和完整 attempt 审计。已有确认结果直接交给 claim/seq 校验的接受事务，不查询目标、不新增 Attempt、不占新 ordinal。缺少确认结果时才进入原查询或人工核对规则。

验证：unqueryable 关闭/开启 retry 两组、`file_write` 与 `file_patch` 的人工确认后真实 kill 均通过；文件后的独立人工修改保留。不同人工结果仍被拒绝，原回执与 evidence 不变。正式 `manual_after_receipt` 再重复 20 次。

### P2-02：最后一次查询已拿到回执却因额度耗尽卡住

触发：`max_attempts: 1` 的查询已确认回执，caller 在核对接受事务 `:before_commit` 退出；Retry journal 仍 `inflight`。

原行为：新 caller 先预留新的查询，旧预留被视为 abandonment，返回 `retry_exhausted`，即使本地回执已经完整保存。

修复使用同一条本地确认结果优先路径。接受原事实不属于再次查询；Kernel 接受时同事务将原 retry 行完成，不更改 attempts。

验证：最后一次查询后真实 kill，新进程在目标 gate 禁止查询的情况下成功接受；原 attempts 仍为 1、状态变为 `succeeded`。正式 `query_before_commit` 和 `query_after_commit` 各重复 20 次。

两个缺陷均先由测试复现，再完成修复；没有新增数据迁移、依赖或后台调度功能。对本地确认结果的读取仍会拒绝过期/陈旧 claim、错误 operation 和损坏审计，不能凭“completed”字符串绕过校验。

## 额外保护测试与正确暂停

[P2SafetyTest](../test/agent_systems_lab/p2_safety_test.exs) 的 18 项真实 PostgreSQL 测试进一步覆盖：

- 原 worker 在效果后暂停、真实 lease 到期，successor 完成；旧 worker 随后返回时无法提交或覆盖，效果仍为 1。
- `file_write` / `file_patch` 在效果后或回执后被 kill，再由独立操作者修改文件。模糊结果进入 blocked，不自动覆盖；已确认回执只复用事实，同样保留后续文件修改。
- 文件 unknown 经人工回执确认后，核对接受事务又被 kill；新进程能只用本地回执恢复，不读取文件内容猜测成功。
- 取消保留既有业务效果和 operation/attempt/receipt，不执行后续模型或工具。
- 两次查询预留后失联，真实等待 lease、abandonment 和退避；有限额度耗尽后多次调用仍 blocked、队列可见、效果不增长。明确人工 evidence 可以结束核对。
- 不兼容的 checkpoint/数据库 schema/payload、陈旧凭证、篡改 operation 和损坏人工审计均失败关闭，不进入目标效果 gate。

第 9 周有意保留的 manual unknown Run 仍可供只读操作演练，见[原核对队列证据](../artifacts/week09-retries/queue-cli.json)。它不计入本周 320 个新 Run，也没有为完成 P2 而被强行确认或删除。

## 新 BEAM、checkpoint 与时间

`tool_result_after_commit/1` 与 `recovery_after_effect_twice/1` 在故障前真实创建 seq 2 checkpoint。新 BEAM 不传新脚本、权限或预算，加载同一 Run 完成续跑；随后另一个新 BEAM 执行纯重建。

纯重建检查 full State、checkpoint + tail State 与父进程原 State 的严格相等，验证 checkpoint ID、seq 2、已验证前缀 2 条与回放 tail 2 条。全部 18 个模型、工具及恢复执行入口 call counter 为 0。日志位于两个 probe 的 `fresh-resume.log` 和 `fresh-rebuild.log`；hash 是辅助证据，严格 State 比较在子进程内完成。

| probe | 新 BEAM 续跑 | 新 BEAM 纯重建 |
| --- | --- | --- |
| `tool_result_after_commit/1` | [日志](../artifacts/week10-p2/tool_result_after_commit/1/fresh-resume.log) | [日志](../artifacts/week10-p2/tool_result_after_commit/1/fresh-rebuild.log) |
| `recovery_after_effect_twice/1` | [日志](../artifacts/week10-p2/recovery_after_effect_twice/1/fresh-resume.log) | [日志](../artifacts/week10-p2/recovery_after_effect_twice/1/fresh-rebuild.log) |

验收使用 200 ms 的短 lease 以便重复实验，实际等待 PostgreSQL `clock_timestamp()` 上保存的 expiry；没有回拨时间、直接改 expiry/due 或手工修补 Run。`lease_wait_ms` 单独统计等待资格的时间，`continuation_ms` 统计之后的恢复工作，包含其中的 retry 等待；新 BEAM 样本还包括子进程启动时间。具体分布由正式 `report.json` 的逐 probe 值计算。这些数据描述本机教学夹具，不用于生产恢复 SLO。

| 每 probe 时间（ms） | 最小 | 中位数 | P95 | 最大 | 320 次合计 |
| --- | ---: | ---: | ---: | ---: | ---: |
| lease 等待 | 0 | 199 | 398 | 401 | 55,036 |
| 之后继续执行 | 5 | 21 | 153 | 466 | 13,038 |

P95 使用排序后第 `ceil(0.95 × 320)` 个值；两次崩溃的 lease 等待在一个 probe 内相加。已完成转换的意图没有活 lease，所以某些窗口等待为 0。表格不包含演练创建、采证与全部 CLI 开销，不能相加后解释成服务恢复时延。

## 原始审计与复现

```sh
./scripts/mix check
./scripts/mix lab.p2 --output artifacts/p2-another-run --repetitions 20
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

每个 `case/repetition/` 保存：

| 文件 | 内容 |
| --- | --- |
| `initial.bin` | 注入前基线 |
| `crashes.bin` | 每次观察到的 gate、caller PID、旧 claim、无 ACK、KILL 及该次退出后的完整审计 |
| `before.bin` | 最后一次退出后、开始接管前的审计 |
| `after.bin` | 恢复后的审计 |
| `summary.json` | seq、效果、attempts、cursor、录制、队列、fencing、资源与时间断言摘要 |

二进制文件使用 Codec v1，将导出 struct 转为 inert map，不更改数据库原始格式或放宽安全解码。审计含完整 Run/Event/intent/recovery、retry、operation/attempt/receipt、模型录制、派生队列以及目标 `MockEffect` 原始行。已存在目标回执行在恢复前后严格相等。正式 DB 行继续保留，能结合原 Run ID 再做独立只读检查。

故障未通过会写 `all_passed:false` 和 `failed_probe`，保留可读取的失败快照；不能只看已完成子集的零计数。全量测试、文档执行结果见[第 10 周验收记录](validation-week10.md)。操作现有事故 Run 按[恢复运行手册](recovery-runbook.md)，不要把演示命令误作恢复入口。

## 未覆盖范围

当前证据针对进程失联、真实本地事务和指定工具能力；没有模拟主机断电、磁盘故障、数据库进程崩溃、网络分区或真实模型供应商故障。没有生产后台 dispatcher、自动唤醒、完整分布式暂停接管或任意远端 exactly-once。匹配文件内容、超时和本地缺少 ACK 都不证明效果未发生。扩展外部工具时，应先提供其稳定身份、幂等/查询/fencing 契约并重新验收。
