# 第 7 周验收记录

验证日期：2026-10-20，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。没有新增 Hex 依赖。

## 实现结果

`History` 提供严格全量重建和可信 checkpoint + tail 重建。两条路径只调用纯 Kernel，按原始顺序验证 Run ID、连续序号、精确 schema_version、规范字段、合法转换及工具配对，不排序、不补洞、不重新询问模型。pending、unknown、取消原因与完整回执均保留。非法或 improper 历史容器返回错误。

`Checkpoint` 绑定 Run、last_seq、max_turns、完整 State，以及确定性前缀/状态 SHA256。独立纯 API 检查自一致性；`Checkpoint.verify/2` 重新验证原始前缀。`CheckpointStore` 在 Run 共享锁与 expected sequence 下真实提交不可覆盖的 checkpoint。读取核对完整权威日志、持久投影与意图，再核对 checkpoint 前缀并应用 tail，结果须与全量重建逐值一致。没有 checkpoint 时显式报告 full；最新 checkpoint 损坏则拒绝，不静默选择旧记录。

`Recording` 保存已接受的完整模型响应，独立检查录制封装版本、模型协议版本和安全 Codec 版本。输入与响应 hash 保留原始 Elixir 类型，包含非 JSON 的合法旧参数。`ModelResultStore` 把录制绑定到 Context capture、当时真实历史前缀和接受该响应的 Event。正常 PostgreSQL Runtime 通过同一个 Ecto.Multi 提交 Run、Event、调度意图和模型结果；输入 capture 仍在 Provider 启动前独立提交。

半截流、取消后的候选、Provider 错误、预算或 schema 拒绝及陈旧并发响应不生成可复用录制。手工模型命令继续表示显式导入事实，不伪装成 Provider 调用。内存 Mock 原有的任意参数 Map 契约保留：PID、reference、function、非白名单 struct 等临时值仍可完成合法转换，但不会生成 inert Recording；`snapshot.recording_errors` 用 `reason: {:invalid_recording_payload, detail}` 和输入/事件序号明确记录这一点。PostgreSQL 的安全数据限制不放宽。

`Providers.Recorded` 由宿主显式构造，匹配下一条录制的精确输入 hash，不匹配时不消费记录。它与历史重建完全分开，重建期间也要求 Recorded 调用计数为零。

新迁移添加 `lab_checkpoints` 和 `lab_model_results`，设置版本/序号约束、唯一性及 Run/Context/Event 外键；Run 删除级联清理。原 State/Event 形状保持不变，没有修改旧业务历史或伪造版本迁移。

## 自动化验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

完整结果：**322 passed，包含 320 个测试与 2 个 doctest，0 失败**。第 6 周原有 265 项全部保留通过，新增 57 项。格式、无警告编译、测试库迁移、10/10 原有场景与原创建/转换四个提交边界 kill 探针全部通过。

| 新增组别 | 数量 | 主要验证 |
| --- | ---: | --- |
| History / Checkpoint / Codec | 11 | 每个前缀切点、非默认 max_turns、pending/unknown/终态、缺口/重复/错 Run/非法字段、版本类型、伪造与原前缀核对 |
| CheckpointStore | 10 | 持久前缀和 tail、不可覆盖、CAS、嵌套写拒绝、缺失与最新损坏、真实 COMMIT 前后 kill |
| Recording / Recorded | 12 | 独立版本、精确 hash 与旧参数、非 UTF-8 Run ID、输入错配不消费、stream ACK 与数据损坏 |
| ModelResultStore | 14 | 与业务事实同事务、Context/真实 Event 绑定、伪造来源、版本/元数据/响应篡改、异常和真实 kill |
| 内存 Runtime | 6 | tool/final 自动录制、流式组装、done 后取消、拒绝候选、手工命令区分、临时旧值兼容 |
| 持久 Runtime / 独立 BEAM | 4 | pending checkpoint、自动录制与 Event 序号、取消/陈旧结果不录制、新 VM 同状态且零执行 |

关闭数据库时：**232 passed，90 个数据库测试按标签排除**。该结果不能替代 PostgreSQL 验收。

日志保存在 [完整 check](../artifacts/week07-history/check.log) 和 [内存测试](../artifacts/week07-history/memory-tests.log)。真实 kill 会产生 Postgrex 连接随 caller 退出的日志，这是故障注入的预期观察；所有断言及后续独立连接核对均通过。

## 正式新进程演示

开发库和测试库均已迁移。实际执行：

```sh
./scripts/mix lab.history
./scripts/mix lab.rebuild history-1792509793517855-3650
./scripts/mix lab.rebuild history-1792509793517855-3650 --checkpoint
```

正式产物位于 [artifacts/week07-history](../artifacts/week07-history/)。先前一轮演示另行保存在 `artifacts/week07-history-initial/`；最终证据使用上述正式目录，没有覆盖既有演示。

| 观察项 | 实际结果 |
| --- | --- |
| Run ID | `history-1792509793517855-3650` |
| checkpoint ID / seq | `31aa916d-175c-4a2d-b390-ee91d381aafd` / 2 |
| checkpoint 时刻 | waiting_tool，模型提议已提交，文件效果尚未执行 |
| 原始真实文件写入 | 1 次，`workspace/result.txt` 内容为 `one recorded file effect\n` |
| 完整模型录制 | 2 条，工具提议 Event seq 2、最终回答 Event seq 4 |
| 完整输入 capture | 2 条，均在对应 Provider 调用前提交 |
| 重建终态 / seq | succeeded / 4 |
| checkpoint 前缀 / tail | 验证 2 个前缀事件，应用 2 个 tail 事件 |
| State SHA256 | `3823f6b1c4ecdf06878edcbb3f9446b15d746e82449fbf16490183c0736a9ea6` |
| 原 State / 全量 / checkpoint | 独立 VM 内以 `===` 完整比较，相等 |
| 重建前后文件 | 字节完全不变，原 RunServer 写入计数仍为 1 |
| 显式 Recorded 复用 | 在重建之外，用首个精确输入返回原工具提议；没有调度该工具 |

父进程把完成时的原始 State 经安全 Codec 编码传给新 BEAM，仅用于比较。子进程独立从 PostgreSQL 重建 State，在审计区间中核对 full、checkpoint 和 expected 三者全值相等，返回布尔结果与 hash。expected State 不作为重建起点；子 VM 不复用原 RunServer、Provider 游标、ETS 或工具台账。

新 VM 使用 BEAM `:call_count` 覆盖以下入口，计数全部为 **0**：

- Scripted `respond/2`、`stream/3`。
- Recorded `respond/2`、`stream/3`。
- Gateway、Files、Mock 的 `execute/4`。
- RunServer `start_link/1`。

计数器覆盖整个新 VM。另用独立 probe 实际调用 Scripted.respond/2，观察计数从 0 增至 1，确认检测有效。审计 API 要求在新 VM 或无其他业务活动的 VM 中运行，以避免把并行业务调用计入重建区间。

证据为 [总报告](../artifacts/week07-history/report.json)、[新 VM 日志](../artifacts/week07-history/fresh-vm.log)、[全量 CLI](../artifacts/week07-history/rebuild-full.log)、[checkpoint CLI](../artifacts/week07-history/rebuild-checkpoint.log) 和安全编码的 `events.bin`。两个 CLI 输出相同 State hash，模式分别为 full 和 checkpoint。

## 提交与损坏边界

checkpoint 和模型结果均测试真实调用进程被 kill，未使用外层回滚 Sandbox 替代实际提交。

| 故障点 | 原始数据库观察与最终核对 |
| --- | --- |
| checkpoint COMMIT 前 | 没有本次 checkpoint，Run/Event 不变 |
| checkpoint COMMIT 后、ACK 前 | checkpoint 可读取并验证，Run/Event 不变 |
| 模型响应 COMMIT 前 | 没有模型结果，新响应 Event/Run/意图全部回滚；先前输入 capture 可保留 |
| 模型响应 COMMIT 后、ACK 前 | 模型结果、新响应 Event、Run 投影及意图同时存在 |

针对未知/错误类型版本、损坏 checkpoint、非法原始 Event、自一致但伪造的状态或输入来源、录制与接受事件错配，读取明确失败，不调用模型修复或工具补偿。safe ETF 继续拒绝新 atom 创建与可执行临时值，没有不安全回退。任意用户 atom 在全新 VM 中仍可能无法解码；跨进程数据应优先使用字符串。

## 实验手册与范围

[L06 手册](../labs/L06-history-checkpoints.md)、[参考解答](../labs/solutions/L06.md)、[ADR 0006](adr/0006-history-checkpoints-and-recorded-results.md) 与 README 已补齐。四段 Elixir 交互示例已按脚本实际执行通过，包括纯重建/损坏拒绝、PostgreSQL checkpoint + tail、Runtime 自动录制与 Recorded 精确匹配。

checkpoint 仍验证完整权威历史，不声称减少冷启动成本。hash 是完整性检查，不是签名。录制仅保存已接受结果，不保存所有模型尝试、原始流、token 或费用。历史重建不消费调度意图，不恢复预算、Provider 游标或文件去重台账；不提供自动续跑或外部效果 exactly-once 保证。仍使用离线 Provider，远程 CI 未执行。
