# ADR 0006：只读历史重建、可信前缀 checkpoint 与已接受模型结果录制

- 状态：已接受
- 日期：2026-10-20
- 范围：第 7 周、L06
- 延续：[ADR 0002](0002-transactional-storage.md)、[ADR 0004](0004-controlled-tools-and-call-pairing.md)、[ADR 0005](0005-session-context-and-manifests.md)

## 背景

Run/Event/调度意图已有事务性持久化，ContextStore 已能证明模型请求使用的输入。下一步需要在全新进程中核对相同 Run State，保存有明确前缀边界的 checkpoint，并记录真正被接受的完整模型结果。若将 pending 工具解释为待重发指令，或将输入 capture 当成模型结果，重建就会产生重复效果或虚构事实。

## 决策

1. History 只使用纯 Kernel 重建。全量路径从原 run_id 与 Kernel 选项开始，按原始顺序验证并应用 Event；不排序、不去重、不补洞。全过程不读取 Provider cursor，不调用任意 Provider 或工具，不 claim 持久调度意图。
2. 沿用 State 与 Event 形状。Event、checkpoint、模型录制与 Codec 各自检查精确支持版本；未知、未来、错误类型版本 fail closed。当前不提供自动迁移，也不把版本值改回 1 视为迁移。
3. Checkpoint 是版本 1 的 inert 纯值，包含 run_id、seq、原始 Kernel 选项、State 和前缀/State hash。创建先完整验证前缀；验证时重建前缀并逐项比较。tail 从 seq+1 开始按原状态规则演进；终态后追加、跨 Run、重复或缺口都拒绝。
4. 仅有 checkpoint 与 tail 的纯 API 假定 checkpoint 已有可信来源。hash 只能检查自一致性，不能凭空证明未提供的原历史。CheckpointStore 冷读取核对完整权威前缀和持久投影，再比较 checkpoint 路径与全量路径；本阶段不承诺 checkpoint 提升冷启动性能，也不删除原 Event。
5. CheckpointStore 创建在 Run 锁和 expected sequence 下保存校验后的投影；拒绝陈旧序号和外层嵌套事务。before_commit/after_commit 故障注入沿用 COMMIT 前后 ACK 语义。最新 checkpoint 损坏时明确拒绝，checkpoint 模式不 silent fallback；显式 full 模式可独立用于审计。
6. Recording 是版本 1 的完整已接受模型结果封装，绑定 Run/输入序号、Context、精确输入 hash、Provider 标签、response 与 response hash。只接受通过协议、预算、Kernel 转换校验的完整最终文本或工具提议；流片段、取消后迟到响应、Provider 错误和拒绝候选不构成可复用录制。不宣称保存所有请求尝试或厂商原始流。
7. PostgreSQL 模型响应的录制与接受该响应的 Run、Event、旧意图 supersede 和下一意图位于同一 Ecto.Multi。COMMIT 前崩溃全部不提交；COMMIT 后、ACK 前崩溃全部存在。输入 capture 仍在调用 Provider 前独立提交，因此可能存在没有接受结果的 Context。
8. ModelResultStore.load/list 只读安全解码，并核对行投影、Recording 封装、ContextStore 原始输入和实际接受的模型 Event。工具提议必须对应同值 tool_requested，最终文本必须对应同值 run_succeeded；来源、版本、hash 或 Event 不一致时拒绝，不调用模型修复。
9. Recorded 是宿主明确选择的 Provider 测试适配器，按精确输入 hash 返回保存的完整响应，不调用原 Provider 或工具。History 不依赖、也不调用 Recorded。Recorded 返回工具提议后若宿主继续正常执行，仍可能调度工具；它不提供无副作用运行或任意输入的语义缓存。
10. Runtime 在内存模式保留接受结果的 recording 值，在 PostgreSQL 模式为接受响应传入事务录制选项。内存旧 Mock 的合法参数 Map 仍允许 PID、reference、函数或任意 struct；这些非 inert 值可按旧协议转换，但不生成无效 recording，而在 snapshot.recording_errors 追加 `%{input_seq: ..., event_seq: ..., reason: {:invalid_recording_payload, detail}}`。普通 inert 结果照常录制；PostgreSQL 的持久化与 Codec 校验不放宽。旧 Provider、Streaming、工具权限和业务事件语义保持不变；读取或重建 API 不自动启动 RunServer。
11. 新进程验证启动独立 BEAM VM。父进程将原 State 通过 safe Codec 编码传入；子进程读取已提交数据，在 trace 审计范围内以 `===` 比较全量 State、checkpoint State 与 expected State，再返回比较布尔值与 hash，不以 hash 替代全值比较。同时跟踪 Provider respond/stream 与工具 Gateway、Mock、Files 入口，相关调用均为 0。独立进程不得依赖原进程缓存、活动 worker 或内存台账。

## 数据与边界

```text
ContextStore：完整输入 capture ── COMMIT ── Provider.stream
                                                 │ 完整且有效的响应
                                                 ▼
                       一个事务：Run + Event + intent + Recording
                                                 │ COMMIT
                                                 ▼
                            不可变历史与已接受结果供只读审计

Event 前缀 ── 纯重建/校验 ── checkpoint(State/seq/options/hash)
     │                              │
     └─ 全量重建                    └─ 校验可信前缀 + tail 重建
              └─────────────── 同一个 Kernel State
                        Provider 调用 0，工具执行 0
```

`waiting_tool` 与 `blocked` 均可被原样重建。保存 pending 或 unknown 不表示授权重试；已发生的文件效果也不因重建或取消而撤销。本阶段没有恢复 Provider cursor、Streaming、运行时预算或持久文件效果台账，不自动执行调度意图，不提供 exactly-once 外部效果承诺。

hash 检测数据损坏和绑定不一致，不是签名。若全部权威历史和所有派生数据被一致改写，需要本阶段以外的可信锚点。safe ETF 继续使用可信已加载模块词汇与 inert 值，不增加 unsafe fallback；用户数据优先使用字符串以保证跨 VM 可移植性。

## 验证与代价

测试覆盖完整状态等价、pending/unknown 与终态保留、顺序缺口/重复/错 Run、未来版本、非法 Event/State、checkpoint 前缀与元数据损坏、可信 checkpoint + tail、录制输入/响应/Event 绑定、显式 Recorded 成功与输入拒绝，以及 checkpoint 和模型响应事务 COMMIT 前后真实进程 kill。

存储保留完整 Event、输入来源、录制和 checkpoint，会增加容量与校验成本。冷路径核对完整前缀优先保证可解释的正确性；以后若要截断历史、复用可信远端快照或自动续跑，需要另行定义可信来源、兼容迁移、调度 ownership 和效果幂等协议。

实验步骤见 [L06](../../labs/L06-history-checkpoints.md)，实际验收见 [第 7 周记录](../validation-week07.md)。
