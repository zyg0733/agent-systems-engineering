# 第 12 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6；没有新增依赖或数据库迁移，原 12 个迁移与历史格式保持兼容。

## 实现与修复

完成 lease、heartbeat 与旧代次 fencing 的补强和真实暂停验证。新增 `FencingDemo` / `mix lab.fence`，每轮启动本任务拥有的独立 BEAM 和 scoped Scheduler，确认实际 heartbeat 后用 SIGSTOP 暂停整个子进程，保持 PostgreSQL 与父接管者运行。用 `ps` 确认停止态，等待数据库原 lease 自然到期，接管同一个 intent，再通过 SIGCONT 恢复旧 BEAM。

本轮修复了一个被真实期限测试复现的续租窗口：`verify` 时 lease 尚有效，调用方在 UPDATE 前暂停至过期后，原实现仍能给旧 token 延长期限。续租 UPDATE 现在自身检查原 expiry 大于 PostgreSQL 当前时间，并在实际写入时计算新 deadline；零行更新返回 `:claim_expired`，不能依赖先前校验复活过期代次。锁顺序保持 Run → Intent，COMMIT 后才返回成功。

Worker 的每轮续期 timer 使用新 reference，重复与陈旧 tick 被忽略，不会放大 heartbeat 循环。`Scheduler.status(pid).active` 保留原字段，增加 `heartbeat` 与 `heartbeat_age_ms`，记录 sequence、ACK 的 monotonic time、往返 duration 和返回的 lease expiry。首次 ACK 前为 nil；这些诊断不持久化、不跨 BEAM 比较，也不替代数据库资格。

现有写入继续绑定 intent ID、seq、owner、token、generation 和数据库 expiry；generation 在一个 intent 内递增，不是可直接送给任意远端服务的全局递增计数。已有模型录制、资源扣账、原 retry due、工具 operation/attempt/receipt 与 unknown 规则均保留。

## 全量自动化验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

完整结果：**535 passed，含 533 个测试与 2 个 doctest，0 失败**。第 11 周原有 512 项全部保留通过，新增 23 项。格式检查、无警告编译、测试库迁移、原 10/10 fixtures，以及 Run 创建和转换的 COMMIT 前后四个真实 kill 探针全部通过。

| 新增测试组 | 数量 | 主要验证 |
| --- | ---: | --- |
| FencingSafety | 14 | 真实 lease 到期、同 seq 接管与身份混配、旧 expiry/伪造 future expiry、模型 attempt/frame/result、工具效果/回执/人工确认/观察、retry 与取消；迟到调用后完整持久事实不变 |
| LeaseHeartbeat | 3 | 前置校验后过期的续租不能复活；重复/陈旧 tick 不增加循环；恢复后的 heartbeat 输给同 seq successor 并停止旧 executor |
| FencingDemo | 6 | 严格参数/目录保护、应用级 Scheduler 隔离、5 个真实信号窗口、子进程停止时异常清理、未启动时失败报告 |

无数据库模式：**249 passed，286 个数据库测试按标签排除**。新增四项参数/目录/隔离/起始失败检查不启动信号子进程；原内存实验全部通过。

日志：[完整 check](../artifacts/week12-fencing/check.log)、[无数据库测试](../artifacts/week12-fencing/memory-tests.log)。事务中真实 kill 引起的 Postgrex 断连符合故障注入预期。原独立 BEAM 的 full/checkpoint/原 State 严格相等及 **20 个效果入口零调用**测试继续通过，纯重建没有启动模型、工具或 Scheduler。

## 正式 SIGSTOP/SIGCONT 演练

```sh
./scripts/mix lab.fence --output artifacts/week12-fencing --repetitions 5
```

正式前缀：`fence-1792517345364291-3586`。**5 个窗口各 5 轮，共 25/25 probe 通过，25 次 SIGSTOP、25 次 SIGCONT，20 个同 seq fencing probe**。所有子 BEAM 的 `ps` 状态包含 `T`，每轮暂停前实际成功续租一次；接管 generation 从 1 到 2，token 更换，原 Run/intent 身份不变。

| 场景 | 轮数 | 接管时是否保持原 seq | 原执行器恢复后的实际结果 |
| --- | ---: | --- | --- |
| `model_before_accept_same_seq` | 5 | 是 | 完整旧模型响应提交返回 `:stale_claim`，没有旧录制或 cursor 覆盖 |
| `tool_before_effect_same_seq` | 5 | 是 | 准备后恢复，效果前授权返回 `:stale_claim`，旧代次不能开始效果 |
| `tool_after_effect_same_seq` | 5 | 是 | 真实效果已提交；旧 receipt 确认返回 `:stale_claim`，接管仍按原操作完成 |
| `tool_after_receipt_same_seq` | 5 | 是 | 本地回执已确认；旧 Kernel 结果提交返回 `:stale_claim`，接管复用原回执 |
| `model_after_takeover_commit` | 5 | 否；successor 已提交 | 旧模型响应返回 `{:stale_sequence, ...}`，终态与录制不被覆盖 |

前四类在旧调用时保留 successor 的有效 claim，intent ID 与 seq 均相同。因此它们证明当前 token/generation 资格隔离，不能只靠 seq CAS 拒绝过期结果。另有 210 次显式陈旧调用来自恢复后的子 BEAM，覆盖 renew/release、模型预留/帧/结果、工具效果/回执/结果，以及“当前 seq 配旧 token”和“当前 seq 配旧 generation”；全部被拒。

25 个原 executor 的真实返回也被独立观测，全部是陈旧资格或序号错误。拒绝不是父测试手写的预期值。接管后的完整 State、Events、恢复进度、当前 intent/claim、operation/attempt/receipt、模型录制与效果计数，在所有旧调用前后严格相等。**陈旧写入覆盖为 0，重复 Mock 效果为 0**；三个工具窗口的每个逻辑操作最终效果均为 1，两个纯模型窗口效果为 0。最终历史重建与 State 相同。

正式结果为 [report.json](../artifacts/week12-fencing/report.json)，命令输出为 [run.log](../artifacts/week12-fencing/run.log)。另以独立脚本核对 5×5 分布、所有逐轮证据、接管前后 JSON 严格相等及 cleanup 退出状态，结果见 [independent-audit.json](../artifacts/week12-fencing/independent-audit.json)。这些计数只描述本次正式一轮，不混入开发 smoke、ExUnit 或异常清理探针。

## 两道保护如何分别观察

正常恢复时，过期 heartbeat 可能抢先杀死 executor，遮住迟到写入边界。因此 fixture 在确认实际续租后使用显式控制 gate 暂停 Worker 控制过程，让 executor 留在事务外的确定位置；随后仍真正 SIGSTOP 整个 BEAM。

SIGCONT 后先让旧 executor 真正触发数据库/工具门校验，并观察它向 Worker 返回的真实结果；再恢复控制过程，让已到期 heartbeat 尝试续租。每轮都观察到 `lease_lost`，旧 Worker 和 executor 均停止。这分别验证持久 fencing 与本地清理，控制 gate 的用途、时间线和标记保存在报告中。它不模拟整个网络分区，也不能把局部 gate 当作 SIGSTOP 的替代。

所有故障 gate 位于事务之外，旧 BEAM 暂停时不持有 Run 事务锁，不会把“无法接管，因为旧事务占锁”误报成安全接管。续租事务内的校验/UPDATE 竞态另由 `LeaseHeartbeatTest` 精确覆盖，使用自然到期而非修改数据库时间。

## 原始证据与清理

每个 `case/repetition/` 目录保留：

| 文件 | 内容 |
| --- | --- |
| `process.json`、`ready.json` | 本次子进程 PID、nonce、真实 claim 与已发生 heartbeat |
| `initial.*`、`paused.*` | 注入前及 OS 停止后的完整快照 |
| `takenover.*`、`after-old.*` | successor 接管/提交后，以及所有旧调用后的可比较证据 |
| `after.*` | 原身份下安全完成的最终事实 |
| `command.json`、`result.json` | 控制命令、真实迟到调用返回与 heartbeat 失租/进程停止结果 |
| `child.log`、`summary.json` | 独立子 BEAM 日志、信号/停止态、逐轮门槛与时间 |
| `cleanup.json` | 是否需要清理信号、观察到的实际退出状态 |

`.*` 包括 `.json` 和安全 Codec `.bin`。导出 struct 转为 inert 数据；非 UTF-8 二进制用带 encoding 标记的 Base64 表示，没有放宽数据库 Codec 或 schema 校验。正常完成的 25 个子进程退出状态均为 0，并已被 Port 观察到退出；尚未退出的自有子进程才会在清理时补发 CONT 和 KILL。

专门的失败测试在 `ps` 已确认子进程为停止态时抛异常，断言报告 `all_passed:false`、记录原 PID/case/轮次，并观察到 CONT、KILL 和非零实际退出；随后 `ps` 找不到该 PID。清理等待超时会失败，不会继续宣称通过。起始回调失败则没有启动子进程，失败 PID 为 nil。

Runner 拒绝覆盖已有目录，也在应用级全库 Scheduler 已启用时返回 `:global_scheduler_enabled`；子进程还主动关闭继承的全库模式，只启动 scoped pool，避免另一调度器破坏确定时间线。运行前不要为相同 Run 另起未受控消费者。

## 时间与解释范围

使用 400 ms 实验 lease、80 ms heartbeat 间隔，等待由 PostgreSQL 时钟决定。续租写入和 lease 等待计算均显式使用 UTC，不能混用 timestamp-without-timezone 与会话本地时区。到期等待拆成有上限的短轮询，总观察期限为 10 秒；不改 expiry/due，也不用睡眠猜测故障注入位置。

| 每 probe 时间（ms） | 最小 | 中位数 | P95 | 最大 |
| --- | ---: | ---: | ---: | ---: |
| 停止确认后到成功接管 | 376 | 384 | 395 | 396 |
| 接管后完成本轮继续处理 | 52 | 68 | 84 | 131 |

P95 为排序后第 `ceil(0.95 × 25)` 个值。时间包含实验控制、读取与旧进程收尾，未把子进程启动等全部开销计入；它们不是生产接管 SLO，也不提供随机故障覆盖概率。

## 文档与示例

新增 [L11 实验](../labs/L11-leases-heartbeats-fencing.md)、[参考解答](../labs/solutions/L11.md)、[ADR 0011](adr/0011-leases-heartbeats-fencing.md)，更新 README 与[恢复运行手册](recovery-runbook.md)第 10 节。

L11 的 scoped heartbeat 示例从 Markdown 原样提取并在新 BEAM 执行成功：跨过初始 lease 后仍是同 token/generation，观察到 heartbeat sequence 12、duration 2 ms、age 92 ms，竞争领取被拒；最终一个模型尝试、cursor 1、一次录制，Run 成功。示例不发 OS 信号；两个精确自建示例 Run 已检查成功后清理，正式故障 Run 与原历史不删除。

证据：[heartbeat-example.log](../artifacts/week12-fencing/heartbeat-example.log)、[示例清理记录](../artifacts/week12-fencing/doc-cleanup.log)。Heartbeat 的 monotonic ACK 可能带负起点，不能解读为 UTC，也不能与另一个 BEAM 的绝对值比较。

## 当前边界

数据库 fencing 与本仓库受控工具效果门已在真实进程暂停下验证；这不等于独立远端目标已经支持 fencing，也不能从 lease 变化证明外部请求停止或文件回滚。不可查询模糊结果仍需可见 blocked/manual 与可信证据，原有文件、期限、unknown 和重试测试保持通过。

父 runner 被不可捕获的 OS kill 时，`after` 不能执行；当前没有独立 watchdog，需按已保存身份核对清理，不能宣称该故障自动收尾。本周没有新增生产背压、公平性、网络分区、数据库断连或任意外部 exactly-once；这些仍各有独立验收范围。本地完整验收通过，远程 CI 未运行。
