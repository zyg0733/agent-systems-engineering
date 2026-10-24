# ADR 0018：有界观测与按 Run ID 的只读诊断

- 状态：接受，用于第 19 周教学实现；实际验收以 validation-week19 为准。
- 日期：2026-10-22。
- 依据：[研究计划](../../Agent%20Systems%20Engineering%20研究与落地计划.md)、[持久化执行](0002-transactional-storage.md)、[人工审批](0017-human-approvals-and-rework.md)、[L18](../../labs/L18-observability.md)。

## 问题

Run 的证据已经分布在事件、模型录制、工具台账、调度意图、预算、Workflow、人工 Case 和轮次中。仅看日志难以解释重复投递、失租、未知结果或审批失效。把观测同步写入外部系统又会让外部故障改变提交、延迟和恢复语义；先 cast 再裁剪的常见缓冲也不能限制生产者邮箱积压。

观测还容易泄露 prompt、模型正文、工具参数和结果、工作区路径、claim token、人工理由及异常消息。需要一个明确的数据最小化出口，且不能引入新的执行、权限或审批凭据。

## 决定

运行观测与 durable 诊断分开。`Observability.emit/4` 是允许丢失的通知；`Observability.Query.run/2` 是可信宿主触发的一次 repeatable-read、read-only SQL 元数据投影。后者沿原存储归属关联 Workflow、Case 和返工轮次，限制每类事实与关联 Run 数量，显式显示截断及投影不可用。两者均不推进业务、不执行恢复、不读取当前产物重新审批。

采用内部 schema v1。事件名、标识字段、数值字段和枚举属性均有固定 allowlist，不导出业务正文、自由错误文本或敏感 token。ID 保留必要的稳定业务关联，要求可信宿主不得把秘密编码进业务 ID。有限格式校验不构成匿名化或多租户访问控制。

Run trace ID 与逻辑 span ID 由版本化确定性哈希产生，分别输出 32 和 16 位小写十六进制。模型和工具 attempt 的开始、结束、录制或核对共享逻辑 span 关联；不同 Run 的 Workflow 依赖与 Case 轮次采用 links，不创建跨 trace 的 parent span。标识可以在新进程、新 BEAM 内重新计算；不依赖 PID，不授予 capability，不替代 fencing token，也不实现完整远端上下文传播或采样协议。

准入通过固定槽位 public ETS 与 atomics 条目/字节预留完成，竞争仅做有限次 CAS 尝试；满额、槽位冲突、超大或无效事件被丢弃并计数。原子 wake 标志合并消息，生产者不通过逐事件 cast 向邮箱排队。字节指标采用 external-term payload 长度，另有单行、槽位数、batch 与 recent 上限限制额外对象规模；不声称是精确 VM 内存、JSON 字节或磁盘配额。

默认 256 槽位、1 MiB 队列载荷、单事件 8 KiB、每批最多 32 行、一个 exporter Worker；recent 独立限制 128 行与 512 KiB。有限事件名和有限 outcome 构成 metric label，业务 ID 不进入 labels。Metrics 汇总已排出的观测，不能用于计费、预算执行或幂等证明。

每批先从队列移除，再交给 linked/monitored、带有限 timeout 的 exporter Worker。Observer 捕获 Worker 退出，exporter 返回错误、抛异常或退出均只增加有限错误与丢失计数；超时 kill Worker。失败批次不重试，之后退避；在途 batch 和后续积压仍受硬上限限制。`dropped`、`invalid`、`export_lost`、导出错误、超时、高水位与 recent 留存均通过宿主诊断接口可见，不保存任意异常 inspect。

`emit` 内不调用数据库、文件、网络、同步 GenServer 调用或宿主 callback，捕获自身异常并返回 `:ok`，不包裹、替换业务返回或业务异常。提交观测放在成功外层 COMMIT 之后；内部事务 helper 不提前发成功提交通知。即使带 committed 属性，通知仍不是 durable 证明，也不是授权。COMMIT 后通知前的故障窗口明确允许丢失，由只读 Query 查原事实。

Observer 放在现有 execution children 之后，采用 temporary child，避免重复观察进程故障耗尽业务父监督树重启预算。进程消失后，默认或陈旧 handle 的 emit 安全丢弃；host 可用 `Observability.restart/0` 单独恢复 observer。执行 Registry、ProviderSupervisor、RunSupervisor、Scheduler 与 Run 不因此重启。exporter 故障由 Worker 隔离，不应导致 observer 消失。反向链接确保 observer 被 kill 时挂起的 Worker 也终止，不遗留失去 timeout 的进程。Exporter 是可信宿主代码，不应自行修改 trap_exit 绕过生命周期清理。

准入不是跨 atomics/ETS 的事务：producer 在预留后、插入前被 kill，可能遗留有限 admission permit，造成观察容量下降；它不会放宽上限或改变业务。`queued_entries` 与 `buffer_entries` 的持续差异可供宿主诊断，短暂差异也可能是正常在途准入。Host 可显式 `Observability.restart/0` 丢弃并重建观察状态；此操作不重启执行 sibling，不自动补发通知，也不声称无损自修复。

默认 Null exporter。JSONL 仅使用显式宿主配置的绝对路径，在 Worker 内执行有限批量 append；导出模块是可信宿主扩展，不能接受模型提供的模块、函数或文件目的地。配置、flush、stats、recent 和 Query 都是宿主控制操作，不进入执行关键路径。本周不增加 Hex SDK 或持久化业务 schema，不声称实现 OTLP、完整 OpenTelemetry SDK、collector、远端分布式采样或网络 exporter。

## 源码与规范对照

[OpenTelemetry Trace API](https://opentelemetry.io/docs/specs/otel/trace/api/) 对 TraceId、SpanId、父子关系与 links 给出概念和尺寸约束。本实现采用兼容长度的本地逻辑标识和显式跨 Run links；确定性哈希、内部 schema 和 durable 事实投影是教学实现的选择，不能据此宣称完整标准协议兼容。

[OpenTelemetry 错误处理原则](https://opentelemetry.io/docs/specs/otel/error-handling/) 要求运行时观测故障不能通过未处理异常影响应用。本实现进一步用无 IO 准入、有限缓冲、单个 timed Worker 与 temporary observer child 隔离外部导出失败；宿主主动配置或诊断接口仍会显式返回自身错误。

[OpenTelemetry Metrics SDK](https://opentelemetry.io/docs/specs/otel/metrics/sdk/) 讨论 cardinality limits 与 overflow。这里使用有限事件/outcome 枚举，直接不允许业务 ID 作为 label；这是有限本地聚合，不实现 SDK View、完整 aggregation temporality、exemplar 或标准 reader/exporter 生命周期。规范对照以第 19 周核验的 OpenTelemetry 1.61.0 为背景，后续接入 SDK 需单独验收。

## 验证与后果

纯测试与 OTP 测试验证 schema、稳定 ID、attempt 配对、canary 最小化、有限标签、条目/字节/邮箱/recent 上限、配置拒绝、JSONL IO 失败以及 error/raise/exit/kill/hang exporter。重复 kill 默认 observer 后原执行 sibling 与活跃 Run 的 PID、状态不变；恢复观察器不会恢复或重置业务。

真实 PostgreSQL 演练对照导出开关与失败模式下的执行结果、已扣预算、claim generation、回执与未知核对；用只读 Query 关联模型、工具、调度、恢复、审批和返工，并证明查询前后事实不变且执行入口零调用。具体通过数量只填写实际验收结果。

代价是观测明确不保证完整或有序，故障批次允许丢失，丢失期间 metrics 会欠计数；默认 observer 丢失后需要宿主显式恢复。所得能力是执行语义独立于观察层、积压有硬上限、故障可见，以及按原 durable 归属解释多阶段任务。真实成本、当前产物授权和自动恢复仍由原业务层承担。
