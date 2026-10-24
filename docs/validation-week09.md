# 第 9 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6，没有新增 Hex 依赖。

## 实现结果

新增 `ErrorPolicy`、`RetryPolicy` 与 `RetryStore`。分类包括 transient、permanent、timeout、conflict、cancelled、unknown；未识别错误默认 permanent。分类记录 scope、工具能力、效果是否可能发生与原始原因的惰性表示。分类只说明资格，不能授予重复执行非幂等效果的权限。

重试通过 `Recovery.create_run(..., retry_policy: [...])` 显式启用；默认 nil 保留第 8 周行为。策略、确定性离线尝试脚本和 Mock 故障计划以不可变 sidecar 随 Run 创建提交，原 v1 核心配置与进度格式不变。sidecar 独立校验版本、hash 和安全 Codec，续跑不能改策略、脚本、权限或故障计划。

`RetryStore` 按 Run/当前意图序号/阶段持久预留每次尝试，保存失败分类、投递审计、下次到期时间与耗尽原因。退避为有上限的指数延迟，受总尝试次数、阶段 elapsed 窗口和执行 Run deadline 约束。模型还保留原全局 `max_model_attempts`、输出字节、帧、turn 和工具调用预算。预留后崩溃也消耗该 ordinal；接管未完成模型请求或只读查询时先记录 abandonment 并退避，工具执行的不确定性则进入核对流程。

`Recovery.resume` 读取未来 waiting 状态时返回暂停快照，不持有 lease 睡眠或循环请求；`step` 在尚未到期时返回 retry_not_due。接受模型或工具事实时，retry journal 与 Run/Event/意图、录制和 cursor 在同一事务关闭；失败关闭保留 exhaustion_reason。模型流的字节扣账继续在 ACK 前保存，重试不会归零。

只有幂等 Mock 适配器确认的 transient/no-effect 结果允许自动再次投递；同一 operation 的参数不变，旧 Attempt 保留。工具超时会先停止并等待 worker 退出：本地已有已确认回执时直接复用，否则保存 unknown 和 observation Attempt。文件或 unqueryable 工具的模糊结果不会自动重发。

`ReconciliationQueue` 从已提交 blocked Run、unknown 事实与 reconcile 意图构建可见队列，无需额外 enqueue 事务。列表校验历史与本地台账，展示原调用、原因、等待时间、最近尝试和 queryable/manual 能力；不查询目标或调用模型/工具。显式 `Recovery.reconcile` 对可查询目标使用独立有限查询窗口，执行 Run 已过期仍可核对已有效果，但不授权新的执行。人工结果与 evidence 是独立事实，不受自动查询额度耗尽限制。

## 完整自动化验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

完整结果：**451 passed，含 449 个测试与 2 个 doctest，0 失败**。第 8 周原有 391 项保留通过，新增 60 项。格式、无警告编译、测试库迁移、10/10 原有场景，以及原 Run 创建/转换的四个 COMMIT 边界 kill 探针全部通过。

| 新增组别 | 数量 | 主要证据 |
| --- | ---: | --- |
| ErrorPolicy / RetryPolicy | 8 | 分类保守性、效果能力、严格版本/参数、有上限指数延迟、次数/elapsed/deadline 边界 |
| RetryStore | 20 | 持久预留、到期门控、不可变策略、弃置尝试、真实 COMMIT 前后 kill、来源/版本/审计损坏、原子关闭与耗尽原因 |
| 工具重试 / 核对队列 | 13 | 安全 no-effect 重试、不可变 Attempt、超时观察、已确认回执、队列入队/离队/legacy、只读边界计数 |
| Recovery 重试集成 | 12 | 模型/工具/查询超时、退避提前调用、有限耗尽、取消、真实预留/调度后 kill、非幂等 unknown 阻塞 |
| Runtime 安全补强 | 6 | sidecar 原子性与篡改、未来版本、脚本 cursor 槽、内部 deadline 参数、执行窗口已过时禁止启动工具 |
| 正式演示 / 独立 BEAM | 1 | 调度后 kill、新 VM 保留 due、模型三次只录制一次、工具 0→0→1、耗尽与可见 manual unknown |

无数据库模式：**240 passed，211 个数据库测试按标签排除**，包含新增纯分类与退避算法，以及全部原内存实验。

日志：[完整 check](../artifacts/week09-retries/check.log)、[内存测试](../artifacts/week09-retries/memory-tests.log)。真实调用进程 kill 导致的 Postgrex 断连日志符合故障注入预期。

## 正式演示与新进程

实际运行：

```sh
./scripts/mix lab.retry
./scripts/mix lab.reconcile --run retry-demo-1792513234454866-3-manual --json
```

正式目录为 [artifacts/week09-retries](../artifacts/week09-retries/)，已有目录拒绝覆盖。演示真实等待持久 due，不修改数据库时间戳绕过等待。

| 场景 | 实际结果 |
| --- | --- |
| 模型暂时错误 | unavailable → rate_limited → 完整回答，3 次尝试、cursor 1、1 条已接受录制 |
| 重试调度后崩溃 | 在 after_retry_schedule 观察到边界后真实 kill caller；新 BEAM 读取的 due 与原值一致 |
| 持续错误 | 最多 3 次，实际等待 25 / 50 ms，进入 failed/retry_exhausted；没有录制、没有热循环 |
| 幂等工具暂时失败 | 同一 operation，3 次 delivery，效果依次为 0 / 0 / 1，最后 succeeded |
| unqueryable 工具效果后超时 | 目标效果为 1，worker 已退出，unknown/blocked 入队，自动重复投递为 0 |
| 可查询工具效果后超时 | 先 blocked，显式查询原回执后 succeeded，目标效果仍为 1，队列项移除 |

新 BEAM 模型 Run：`retry-demo-1792513234454866-3-model`。父进程在调度提交后被 kill；子进程不传新策略或脚本，从数据库读取原 due 和故障计划，等待到期后继续。最终 State hash 与父进程随后只读加载一致：

```text
42673cef37ff170fcfe2e7d18b99149aedba3ae298bbbf926e302f49dd344140
```

原始记录见 [report.json](../artifacts/week09-retries/report.json) 和 [fresh-vm.log](../artifacts/week09-retries/fresh-vm.log)。各轮 RetryStore delivery、失败分类、绝对时间、原始 operation/attempt/receipt 以 [journals.log](../artifacts/week09-retries/journals.log) 与安全编码的 `journals.bin` 保存；导出 DTO 中的时间转为 ISO 字符串，没有放宽 Codec 对 struct 的限制。

## 可见的非幂等核对项

正式保留的未解决条目为：

```text
run_id:       retry-demo-1792513234454866-3-manual
operation_id: once
tool:         mock_write
status:       blocked
seq:          3
safe_mode:    manual
reason:       tool_timeout / effect unknown
```

该场景声明 unqueryable 能力。工具效果提交后在 hook 中超时，worker 被停止并等待退出，随后保存 observation Attempt 和 unknown。多次 resume 不新增效果或 delivery；默认 reconcile 返回 reconciliation_required，条目继续可见。诊断效果计数为 1，但它不能替代该工具契约缺失的权威回执查询。

证据：[队列快照](../artifacts/week09-retries/queue-open.json)、[实际只读 CLI 输出](../artifacts/week09-retries/queue-cli.json)。该 Run 有意保留 blocked 供后续实验；人工 evidence 核对后可以离队，但后续执行仍受原绝对 Run deadline 约束。report 中的 1 个 open entry 指本次五个演示 Run，不假定全库只有这一项。

队列测试以 BEAM call_count 核对列表期间 Scripted.stream、Files.execute、DurableMock.execute/lookup 调用均为 **0**。手工证据核对与取消都能使条目从派生队列移除，同时保留历史。旧 blocked Run 也可见，标为 recoverable:false/manual，不伪造新的恢复配置。

## 超时、退避与故障窗口

故障测试使用确定 hook、真实进程 kill 和独立读取。主要覆盖：

- RetryStore COMMIT 前终止没有预留；COMMIT 后 ACK 前终止，次数和身份仍保留。
- after_retry_reserve 后 caller 失联，预留 ordinal 不返还；模型接管先记录 abandonment 与退避。
- after_retry_schedule 后 caller 退出，原 due 和失败分类跨新进程保留。
- 等待期多次 resume 不增加 claim 或尝试；第三次持续失败后停止，不再启动 Provider。
- 模型或查询超时先停止 worker，后续尝试保留原输出账、cursor 和总 deadline；模型只录制真正接受的完整结果。
- 非幂等工具在效果前或效果后的 timeout 均保守处理；无法证明时进入可见 unknown，不能凭本地缺少 ACK 重发。
- 工具回执已经提交但 worker 超时退出，观察路径直接复用回执，不制造 unknown。
- 观察路径不继承执行阶段的故障 hook，避免 after_receipt 等 gate 在主调用进程里再次触发死锁。
- 重试阶段窗口已过时不启动新工具，并在实际 effect 的 Run 锁内再次校验；模型启动、帧 ACK 和结果提交也受持久期限约束。
- 自动查询具有独立有限次数与 elapsed 窗口，提前查询不调用目标；额度耗尽仍保留 blocked，不伪造成功。人工证据不占用该自动查询配额。

历史重建零执行审计已扩展至新增超时观察和当前 Mock 入口，共 **18 个边界**；原新 BEAM 重建测试继续通过，没有因加入重试而推进 pending 意图。

## 全新数据库与文档

开发库和测试库完成升级后，另建本任务专用空库，从零执行 **11 个迁移**。实际验证模型暂时失败/到期成功，以及工具效果后超时 → 可见 manual 队列 → 明确人工 evidence → 续跑成功，效果仍为 1。验证后已删除专用临时库，原开发库、测试库和正式证据保留。

证据：[全新迁移日志](../artifacts/week09-retries/clean-migrations.log)、[新安装验证](../artifacts/week09-retries/clean-probe.log)。

[L08 手册](../labs/L08-retries-and-reconciliation.md)、[参考解答](../labs/solutions/L08.md)、[ADR 0008](adr/0008-bounded-retries-and-reconciliation.md) 与 README 已更新。手册中 **8 个 Elixir 代码块全部实际执行通过**，使用独立 build 和测试 PostgreSQL，专用示例数据已清理。

## 当前范围

重试由显式调用驱动，没有后台 dispatcher、自动定时唤醒、生产队列公平性或真实 Provider HTTP/SSE。退避是确定性教学策略，没有随机 jitter。配置中的尝试脚本和故障计划用于离线验证，不代表真实供应商错误、计费或幂等契约。

未知效果依然需要能力匹配的查询或可信人工证据；超时不证明效果未发生，幂等 Mock 的效果唯一性也不等于任意外部 exactly-once。数据库不可用时无法持久确认，调用方应等待可读事实后再恢复，不能将错误当成未执行。hash 提供完整性检查，不是签名；远程 CI 未执行。
