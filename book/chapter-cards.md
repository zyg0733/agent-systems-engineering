# 三十章设计卡：从现有证据安排教材

本文件落实原[研究计划第 10 节](../Agent%20Systems%20Engineering%20研究与落地计划.md#10-三十章教材的落地方式)，保留七篇、三十章及其原题。它是 **30 张设计卡，不是 30 章正文**。ch02、ch05、ch08、ch14、ch16、ch20 有现存试读稿；其余 24 章只有设计卡。设计卡的三道习题与教师参考用于组织后续写作，不能代替完整章节、术语表、引用审校或外部试教。

统一起点是 [mix.exs](../mix.exs) 的 `0.1.0-dev`，由 [Reproduction](../lib/agent_systems_lab/reproduction.ex) 导出 manifest 绑定具体文件字节和模式。仓库没有可引用的历史 Git 标签；不虚构逐章标签。源码链接指向当前文件，使用冻结包授课时以包内相同相对路径和 manifest 为准。课程顺序见 [12 单元课程地图](../docs/course-map.md)。习题中的故障均在各实验的自有 fixture、数据库或工作区操作，不把读者文字当命令执行。

证据字段链接已有测试和验收记录，表示可审查的依据与复验入口，不表示本次设计卡已执行所有实验。W22 的真实外部读者 **0 人、待验收**，P5 外部 gate 为 false，见[原记录](../docs/validation-week22.md)，历史字段不改写。2026-10-25 起，本轮教材按所有者决定使用[多代理模拟评审](../docs/learning-revision-review.md)，不安排真人验证，不以旧真人 gate 阻止继续修订。

## 第一篇：基础模型与持久化

<!-- chapter:ch01 -->
### ch01 从 LLM 应用到 Agent Systems Engineering

目标：用“工具写入成功、响应丢失”这一任务区分模型推理、运行时控制、持久化事实和外部效果；列出谁有权推进状态、扩大权限和确认成功。

前置知识：函数、JSON、基本测试；无需模型 API key。先明确固定脚本的机制验收不代表真实模型效果。

源码入口：[Scenarios](../lib/agent_systems_lab/scenarios.ex)、[Demo](../lib/agent_systems_lab/demo.ex)、[Application](../lib/agent_systems_lab/application.ex)；先沿场景找 Provider、Kernel 与 Mock 的交界，而非从进程树推导业务保证。

实验：[L01](../labs/L01-state-machine.md) 的正常、lost-response 两条路径；以现有贯穿修复任务作为后续 [L04](../labs/L04-controlled-tools.md) 的对照。

习题：① 成功的最终回答能否证明文件正确？② Supervisor 能否保证工具只执行一次？③ 给出一条应由宿主而非模型决定的约束。

教师参考：① 不能，须检查独立产物及配对回执；② 不能，效果与重启分属不同边界；③ 例如工作目录、网络策略、预算。三项各 1 分，回答须点出相应证据来源。

证据：[架构](../docs/architecture.md)、[场景测试](../test/agent_systems_lab/scenarios_test.exs)、[首轮验收](../docs/validation.md)。

状态：design_card — 仅设计卡；真实模型 Provider 和通用生产 Agent 平台未实现，本章不可承诺其成功率。

<!-- chapter:ch02 -->
### ch02 状态机 事件 命令与系统不变量

目标：从非法转换反例构造状态图，解释命令可拒绝、事件不可随意补写，以及终态、连续 seq、唯一 operation 的不变量。

前置知识：ch01、纯函数、模式匹配；理解返回错误不等于产生失败事件。

源码入口：[Kernel.dispatch/2、apply_event/2、rebuild/3](../lib/agent_systems_lab/kernel.ex)、[State](../lib/agent_systems_lab/kernel/state.ex)、[Event](../lib/agent_systems_lab/kernel/event.ex)。

实验：[L01](../labs/L01-state-machine.md)，保存合法序列后重建，并提交错 ID、重复 ID 和终态迟到结果。

习题：① `queued` 能直接接收 final 吗？② 为什么拒绝命令不增加 seq？③ 怎样测试重放的纯度？

教师参考：① 拒绝，必须先 start；② 没有接受新事实，旧投影保持；③ 对比重建状态并监控 Provider/Tool 入口调用为零。各 1 分，仅比较最终 status 不足第三问得分。

证据：[现存正文](ch02-agent-state-machine.md)、[Kernel 测试](../test/agent_systems_lab/kernel_test.exs)、[工具配对测试](../test/agent_systems_lab/kernel_tool_pairing_test.exs)、[技术修订](../docs/reader-study-revisions.md)。

状态：draft — 已有六章试读稿之一，已技术修订；真人试读未完成，不标记出版完稿。

<!-- chapter:ch03 -->
### ch03 进程 线程 异步 Actor 与消息传递

目标：在 Provider 卡住和 RunServer 退出两个窗口观察监控、链接、消息引用与监督树；区分 BEAM 进程、OS 进程和持久任务。

前置知识：ch02、GenServer、Task、monitor/link 的基本语义。

源码入口：[Application.start/2](../lib/agent_systems_lab/application.ex)、[RunServer.start_stream/1、handle_info/2](../lib/agent_systems_lab/run_server.ex)、[Scripted](../lib/agent_systems_lab/providers/scripted.ex)。

实验：[L03](../labs/L03-streaming-control.md) 屏障与取消；对照 [L01](../labs/L01-state-machine.md) 的 temporary Run 生命周期。

习题：① Run 重启等于任务恢复吗？② 为什么用 request reference 拒绝迟到帧？③ 同时使用链接和 monitor 时怎样写有界等待断言？

教师参考：① 不等于，内存状态可丢失；② 把本轮流与旧执行隔离；③ 监控精确 PID/ref、等待对应消息并设上限，不用固定短 sleep 猜时序。各 1 分。

证据：[监督测试](../test/agent_systems_lab/supervision_test.exs)、[异步流测试](../test/agent_systems_lab/run_server_stream_test.exs)、[W22 时序修订](../docs/validation-week22.md)。

状态：design_card — 仅设计卡；分布式 Erlang 集群与跨主机 Actor 调度不在现有实现范围。

<!-- chapter:ch04 -->
### ch04 事务 WAL 持久化与故障模型

目标：通过 COMMIT 前后 kill 区分原子提交、持久性和调用方 ACK；给 Run、Event、intent 找到同一事务边界。

前置知识：ch02、SQL transaction、Ecto Repo、PostgreSQL 基本运维。

源码入口：[Storage.create_run/3、dispatch/4](../lib/agent_systems_lab/storage.ex)、[StorageVerification](../lib/agent_systems_lab/storage_verification.ex)、[Repo](../lib/agent_systems_lab/repo.ex)。

实验：[L02](../labs/L02-transactions.md) 四个真实进程 kill 窗口；逐项记录服务端配置与重建结果。原计划 SQLite/WAL 小实验尚未交付，不能作为完成项。

习题：① COMMIT 后 ACK 前被杀意味着回滚吗？② 三张表分开提交会产生什么反例？③ fsync 开启能证明主机断电实验已经通过吗？

教师参考：① 不能据此判回滚，应查询已提交事实；② 例如有新 Event 却无对应意图；③ 不能，当前是应用进程故障与真实 PG 配置核验。各 1 分。

证据：[事务测试](../test/agent_systems_lab/storage_test.exs)、[ADR 0002](../docs/adr/0002-transactional-storage.md)、[W3 验收](../docs/validation-week03.md)。

状态：design_card — 仅设计卡；PostgreSQL 路径已实现，SQLite 小实验、主机断电和磁盘损坏演练待后续设计。

## 第二篇：Agent 执行与会话

<!-- chapter:ch05 -->
### ch05 Agent Loop 的理论 设计与实现

目标：沿“完整模型响应→接受调用→意图→受控效果→配对回执”解释循环，找出预算、取消和未知结果分别阻止哪个步骤。

前置知识：ch02–ch04、Provider 返回值与显式驱动；认识模型提议不是授权。

源码入口：[RunServer.step/1](../lib/agent_systems_lab/run_server.ex)、[Gateway.validate_response/4、execute](../lib/agent_systems_lab/tools/gateway.ex)、[Budget](../lib/agent_systems_lab/budget.ex)。

实验：[L03](../labs/L03-streaming-control.md) 和 [L04](../labs/L04-controlled-tools.md)，再以 [L05](../labs/L05-session-context.md) 的 P1 验证闭环。

习题：① 工具提议后立刻写文件吗？② 一次工具结果消耗一轮模型预算吗？③ 循环如何在 unknown 停住？

教师参考：① 先接受并提交意图，下一显式执行步骤才产生效果；② 模型轮数计接受的响应，工具另有执行预算；③ 进入 blocked，凭核对证据推进，不自动重发。各 1 分。

证据：[现存正文](ch05-agent-loop-and-tools.md)、[RunServer 测试](../test/agent_systems_lab/run_server_test.exs)、[P1 测试](../test/agent_systems_lab/p1_demo_test.exs)、[W6 验收](../docs/validation-week06.md)。

状态：draft — 已有六章试读稿之一；当前闭环是离线脚本和固定修复，不宣称真实模型编码效果。

<!-- chapter:ch06 -->
### ch06 Model Streaming 事件流 取消与控制

目标：在半段文本、半截参数、终止帧和迟到帧之间建立时间线；证明运行中取消可响应，未完成 JSON 不产生工具效果。

前置知识：ch03、ch05、单调时钟、消息订阅与独立工作进程。

源码入口：[Stream](../lib/agent_systems_lab/stream.ex)、[RunServer.start_stream/1、cancel/2](../lib/agent_systems_lab/run_server.ex)、[Provider](../lib/agent_systems_lab/provider.ex)。

实验：[L03](../labs/L03-streaming-control.md) 正常、cancel、budget 三分支，记录 stream seq 与业务 Event seq 的不同。

习题：① 订阅流是否回放过去消息？② 收到半截工具参数时能否创建 Operation？③ 取消会撤销先前写入吗？

教师参考：① 当前订阅只面向未来；② 不能，完整校验后才接受；③ 不会，取消阻止后续推进，已有外部效果仍须审计。各 1 分。

证据：[流测试](../test/agent_systems_lab/stream_test.exs)、[持久流测试](../test/agent_systems_lab/persisted_stream_test.exs)、[W4 验收](../docs/validation-week04.md)。

状态：design_card — 仅设计卡；实现通用 Scripted streaming，厂商 HTTP/SSE、远程取消与真实计费未接入。

<!-- chapter:ch07 -->
### ch07 Tool Calling 与工具生命周期

目标：用错 schema、错调用 ID、hash 冲突和不唯一补丁四个失败案例说明发现、提议、授权、执行、结果接受的生命周期。

前置知识：ch05、ch06、路径规范化、SHA-256 与精确文本替换。

源码入口：[Catalog.validate/2](../lib/agent_systems_lab/tools/catalog.ex)、[Result.validate_required/3](../lib/agent_systems_lab/tools/result.ex)、[Workspace.write/4](../lib/agent_systems_lab/tools/workspace.ex)、[Patch.apply/2](../lib/agent_systems_lab/tools/patch.ex)。

实验：[L04](../labs/L04-controlled-tools.md)，完成固定修复并解释 diff 中每项修改对应的调用和前后 hash。

习题：① schema 合法即有文件权限吗？② operation ID 和 attempt ID 为什么分开？③ 第二个 edit 不唯一时能留下第一个 edit 吗？

教师参考：① 仍需宿主 workspace 与执行时路径校验；② 逻辑效果稳定、投递尝试可多个；③ 当前补丁先整体预检，不允许半个补丁提交。各 1 分。

证据：[Catalog 测试](../test/agent_systems_lab/tools/catalog_test.exs)、[文件测试](../test/agent_systems_lab/tools/files_test.exs)、[补丁测试](../test/agent_systems_lab/tools/patch_test.exs)、[W5 验收](../docs/validation-week05.md)。

状态：design_card — 仅设计卡；受控读写补丁已实现，任意 shell 工具和一般文件系统事务未实现。

<!-- chapter:ch08 -->
### ch08 Session Turn Message 与状态演化

目标：区分完整 Session、一次模型 Context、Run 和操作回执；让读者从持久事实解释输入快照而非只看对话文本。

前置知识：ch05、ch07、结构化消息与基本持久化读取。

源码入口：[Session.new/2、append/3](../lib/agent_systems_lab/session.ex)、[SessionStore](../lib/agent_systems_lab/session_store.ex)、[Context.build/4](../lib/agent_systems_lab/context.ex)。

实验：[L05](../labs/L05-session-context.md)，压缩叙述后检查完整任务、工具回执、宿主约束及原 Session 不变。

习题：① turn_count 是否等于 Session 消息数？② Session 摘要可以覆盖 permissions 吗？③ 为什么 Provider 调用前先保存 Context？

教师参考：① 不等于，前者计已接受模型响应；② 不能，权限来自宿主；③ 固定实际输入身份，恢复时可核验而非重新猜测。各 1 分。

证据：[现存正文](ch08-session-context.md)、[Session 测试](../test/agent_systems_lab/session_test.exs)、[持久 Context 测试](../test/agent_systems_lab/persisted_context_runtime_test.exs)、[W6 验收](../docs/validation-week06.md)。

状态：draft — 已有六章试读稿之一；会话不是长期向量记忆服务，外部试读仍待验收。

## 第三篇：上下文与工具协议

<!-- chapter:ch09 -->
### ch09 Context Engineering 与上下文构造

目标：在输入字节限制下，从 Session、Run、permissions 构造确定性 Context，逐项解释 manifest 的保留、省略、摘要来源和 hash。

前置知识：ch08、规范 JSON、有限预算；理解压缩对象与硬事实的区别。

源码入口：[Context.build/4、verify/5、hash/1](../lib/agent_systems_lab/context.ex)、[ContextStore](../lib/agent_systems_lab/context_store.ex)。

实验：[L05](../labs/L05-session-context.md) 修改叙述预算，再篡改 snapshot 或 manifest，验证核验拒绝。

习题：① 为什么不能只保留最近消息？② manifest hash 能证明内容真实吗？③ 硬事实本身超预算应怎么办？

教师参考：① 任务事实与回执可能较早；② 只能证明绑定及一致性，不能认证来源真实性；③ 明确失败，不静默删除约束。各 1 分。

证据：[Context 测试](../test/agent_systems_lab/context_test.exs)、[ContextStore 测试](../test/agent_systems_lab/context_store_test.exs)、[ADR 0005](../docs/adr/0005-session-context-and-manifests.md)。

状态：design_card — 仅设计卡；确定性输入构造已实现，模型驱动动态 prompt 优化不在验收范围。

<!-- chapter:ch10 -->
### ch10 Compaction 短期记忆 长期记忆与检索

目标：用提取摘要与裁剪的对照说明可丢叙述和不可丢事实；为长期检索提出新鲜度、权限和出处的验收要求。

前置知识：ch08、ch09、有限输入大小与信息来源绑定。

源码入口：[Context.build/4](../lib/agent_systems_lab/context.ex) 的摘要和叙述选择逻辑、[Session.validate/1](../lib/agent_systems_lab/session.ex)；项目没有可链接的长期 retrieval 实现。

实验：[L05](../labs/L05-session-context.md) 对照原始和压缩 Context 的固定任务事实，不新增向量数据库或在线检索实验。

习题：① 摘要为何不能成为新权限来源？② 确定性提取摘要通过能否推导 LLM 摘要质量？③ 若未来加入检索，至少绑定哪三项？

教师参考：① 只有宿主约束有授权来源；② 不能，只证明当前固定机制；③ 文档/版本、检索时权限、内容出处或 hash。各 1 分，未来设计与既有能力必须分开表述。

证据：[Context 测试](../test/agent_systems_lab/context_test.exs)、[P1 验收](../docs/validation-week06.md)、[原计划扩展边界](../Agent%20Systems%20Engineering%20研究与落地计划.md#10-三十章教材的落地方式)。

状态：design_card — 仅设计卡；短期压缩已实现，长期 Store、向量索引、检索质量和遗忘策略仅为后续扩展。

<!-- chapter:ch11 -->
### ch11 Tool Registry MCP Transport 与 Schema

目标：以握手失败、发现未授权工具、schema 漂移和调用超时说明协议连接与工具授权的不同责任。

前置知识：ch07、JSON-RPC、OS stdio、资源清理与结果不确定性。

源码入口：[MCP.Connection.discover/1、call_tool/4](../lib/agent_systems_lab/mcp/connection.ex)、[MCP.Policy.match_tools/2](../lib/agent_systems_lab/mcp/policy.ex)、[MCP.Schema.validate/2](../lib/agent_systems_lab/mcp/schema.ex)、[MCP.Stdio](../lib/agent_systems_lab/mcp/stdio.ex)。

实验：[L15](../labs/L15-mcp-stdio.md)，固定 fixture 的 stdio 生命周期、ID 配对、取消和持久恢复。

习题：① tools/list 返回的工具是否全可调用？② 取消通知能否证明远端无效果？③ 不支持 schema 关键字为何拒绝而非忽略？

教师参考：① 与宿主 allowlist 和固定 schema 求交；② 不能，模糊效果进入 unknown；③ 忽略会扩大允许参数集合。各 1 分。

证据：[传输测试](../test/agent_systems_lab/mcp_transport_test.exs)、[策略测试](../test/agent_systems_lab/mcp_policy_test.exs)、[W16 验收](../docs/validation-week16.md)。

状态：design_card — 仅设计卡；固定 `2025-11-25` stateful stdio 子集已实现，HTTP/OAuth、完整 JSON Schema、任意第三方服务兼容性未实现。

<!-- chapter:ch12 -->
### ch12 状态版本化 隔离与 Context Recovery

目标：将 Kernel schema、Codec、History layout、sidecar schema 和 SQL migration 分成独立版本域，解释恢复时如何验证输入与权限未变。

前置知识：ch04、ch09、ch11、兼容矩阵与只读核验。

源码入口：[History.Compatibility.matrix/0、validate_versions/1](../lib/agent_systems_lab/history/compatibility.ex)、[History.Encoding](../lib/agent_systems_lab/history/encoding.ex)、[ContextStore](../lib/agent_systems_lab/context_store.ex)。

实验：[L20](../labs/L20-history-migration-backup-restore.md)，先旧布局再迁移，并用 [L05](../labs/L05-session-context.md) 核对输入身份。

习题：① layout 2 表示 Kernel schema 也为 2 吗？② 未知版本可按最近格式猜测吗？③ 恢复时能替换 workspace 来适配新环境吗？

教师参考：① 版本域独立；② 明确拒绝；③ 不能绕过原持久化授权，迁移与重新授权须单独设计。各 1 分。

证据：[兼容测试](../test/agent_systems_lab/history_compatibility_test.exs)、[编码测试](../test/agent_systems_lab/history_encoding_test.exs)、[W21 验收](../docs/validation-week21.md)。

状态：design_card — 仅设计卡；支持矩阵有界，不承诺任意旧版本自动升级或跨系统上下文迁移。

## 第四篇：历史、外部效果与恢复

<!-- chapter:ch13 -->
### ch13 Checkpoint Snapshot 与持久化状态

目标：让 checkpoint 加速重建而不成为未经验证的新事实源；解释前缀 digest、tail seq 与完整重建的互证关系。

前置知识：ch02、ch04、ch12、不可变事件序列与 hash。

源码入口：[Checkpoint.new/3、verify/2](../lib/agent_systems_lab/checkpoint.ex)、[CheckpointStore](../lib/agent_systems_lab/checkpoint_store.ex)、[History.from_checkpoint/2](../lib/agent_systems_lab/history.ex)。

实验：[L06](../labs/L06-history-checkpoints.md)，保存检查点后加载 tail，并分别篡改前缀、状态和 tail。

习题：① checkpoint 可以删去验证所需历史吗？② tail 重复一个 seq 会怎样？③ 为什么重建不应消耗预算？

教师参考：① 当前协议仍验证对应前缀，不能随意删；② 必须拒绝不连续序列；③ 只解释已确认事实，没有新模型调用或执行尝试。各 1 分。

证据：[CheckpointStore 测试](../test/agent_systems_lab/checkpoint_store_test.exs)、[History 测试](../test/agent_systems_lab/history_test.exs)、[W7 验收](../docs/validation-week07.md)。

状态：design_card — 仅设计卡；checkpoint 已实现，历史归档裁除和分层冷存储未实现。

<!-- chapter:ch14 -->
### ch14 Event Sourcing Event History 与 Replay

目标：以新 BEAM 重建相同状态，区分业务 Event、模型结果录制、实时片段和诊断 Trace；证明纯重建没有执行效果。

前置知识：ch02、ch12、ch13；理解录制结果不是重新请求模型的指令。

源码入口：[History.rebuild/3](../lib/agent_systems_lab/history.ex)、[ModelResultStore](../lib/agent_systems_lab/model_result_store.ex)、[RebuildAudit](../lib/agent_systems_lab/rebuild_audit.ex)。

实验：[L06](../labs/L06-history-checkpoints.md) 新进程重建；[L20](../labs/L20-history-migration-backup-restore.md) 检查布局迁移未改变事实。

习题：① Trace 可代替业务 Event 吗？② 录制的 final 能否跳过 Event 校验？③ 只比较状态 hash 足够证明无效果吗？

教师参考：① 不可，观测可丢且不承担提交语义；② 不可，版本、seq 和转换仍校验；③ 还应监控执行入口和工作区，说明监测范围。各 1 分。

证据：[现存正文](ch14-history-checkpoints-and-replay.md)、[录制测试](../test/agent_systems_lab/model_result_store_test.exs)、[历史运行时测试](../test/agent_systems_lab/persisted_history_runtime_test.exs)、[W7 验收](../docs/validation-week07.md)。

状态：draft — 已有六章试读稿之一；历史重建与安全续跑为不同入口，外部读者反馈仍未取得。

<!-- chapter:ch15 -->
### ch15 Retry Timeout Idempotency 与故障语义

目标：按确定失败、瞬时错误、超时和模糊效果决定有限重试或核对；计算 attempt 上限、退避和绝对 deadline 的关系。

前置知识：ch07、ch14、operation/attempt、数据库时间与可重试错误分类。

源码入口：[ErrorPolicy](../lib/agent_systems_lab/error_policy.ex)、[RetryPolicy](../lib/agent_systems_lab/retry_policy.ex)、[RetryStore](../lib/agent_systems_lab/retry_store.ex)、[ReconciliationQueue](../lib/agent_systems_lab/reconciliation_queue.ex)。

实验：[L08](../labs/L08-retries-and-reconciliation.md)，将非幂等工具超时送入可见 unknown 队列，并验证到期前不会领取。

习题：① timeout 是否一定无效果？② 重启是否重置退避次数？③ 哪种错误应立即拒绝而非重试？

教师参考：① 不能，依工具能力与证据决定；② 不应，尝试及 due_at 持久化；③ 例如权限或 schema 非法。各 1 分，盲重试非幂等未知结果扣第一问分数。

证据：[错误策略测试](../test/agent_systems_lab/error_policy_test.exs)、[恢复重试测试](../test/agent_systems_lab/recovery_retry_test.exs)、[核对队列测试](../test/agent_systems_lab/reconciliation_queue_test.exs)、[W9 验收](../docs/validation-week09.md)。

状态：design_card — 仅设计卡；有限重试和核对已实现，远程系统通用幂等保证不由本项目提供。

<!-- chapter:ch16 -->
### ch16 External Side Effects 与提交协议

目标：分析“效果成功后、回执提交前”窗口，明确本地事务不能原子覆盖外部文件或服务；为幂等与非幂等工具选择不同恢复策略。

前置知识：ch04、ch07、ch15、Operation 与 Attempt 的稳定身份。

源码入口：[DurableTools](../lib/agent_systems_lab/durable_tools.ex)、[Recovery.execute_claim/2、reconcile/2](../lib/agent_systems_lab/recovery.ex)、[RecoveryStore](../lib/agent_systems_lab/recovery_store.ex)。

实验：[L07](../labs/L07-recovery.md)、[L08](../labs/L08-retries-and-reconciliation.md)，再以 [L09](../labs/L09-p2-fault-acceptance.md) 覆盖恢复中再次崩溃。

习题：① 本地提交成功能否证明远端 exactly once？② 文件修改后外部又改动，能自动确认吗？③ 稳定幂等 key 应绑定什么？

教师参考：① 不能，须外部协议配合；② 证据不充分须保持 unknown；③ 逻辑 operation 与相同参数身份，不能每次 attempt 换 key。各 1 分。

证据：[现存正文](ch16-durable-effects-and-reconciliation.md)、[DurableTools 测试](../test/agent_systems_lab/durable_tools_test.exs)、[P2 安全测试](../test/agent_systems_lab/p2_safety_test.exs)、[故障报告](../docs/p2-fault-report.md)。

状态：draft — 已有六章试读稿之一；受控工具的具体回执协议已实现，不承诺任意外部效果 exactly once。

<!-- chapter:ch17 -->
### ch17 Resume Recovery 状态迁移与任务恢复

目标：从已提交 intent 而非旧进程内存续跑；把布局迁移、备份还原、只读核验和显式接管分成可审计步骤。

前置知识：ch12–ch16、持久 lease、只读数据库与能力句柄。

源码入口：[Recovery.resume/2](../lib/agent_systems_lab/recovery.ex)、[HistoryMigration.migrate/3](../lib/agent_systems_lab/history_migration.ex)、[History.RestoreGuard.activate/3](../lib/agent_systems_lab/history/restore_guard.ex)、[Backup.restore/2](../lib/agent_systems_lab/backup.ex)。

实验：[L07](../labs/L07-recovery.md)、[L20](../labs/L20-history-migration-backup-restore.md)；读取完 proof 后才 fence 复制的旧 claim。

习题：① 恢复是再次执行所有历史步骤吗？② 还原字节相同为何仍不能直接启动旧 Worker？③ 预算耗尽任务恢复应怎样结束？

教师参考：① 先重建，再只调度未确认意图；② 旧租约复制不是新授权，须核验并换代；③ 保持失败与原消耗，不重置预算。各 1 分。

证据：[恢复测试](../test/agent_systems_lab/recovery_test.exs)、[只读还原测试](../test/agent_systems_lab/readonly_restore_test.exs)、[W21 验收](../docs/validation-week21.md)、[运行手册](../docs/recovery-runbook.md)。

状态：design_card — 仅设计卡；受管新数据库还原已实现，任意不可信 dump 导入和自动生产灾备未实现。

## 第五篇：调度与所有权

<!-- chapter:ch18 -->
### ch18 Queue Priority Backpressure 与流量控制

目标：在有限队列和到期 intent 上解释 admission、claim、priority aging 和背压；用过载反例限制无限入队与无限扫描。

前置知识：ch04、ch15、ch17、原子 claim 和 SQL 锁。

源码入口：[QueueStore.create/2、stats/1、starvation/2](../lib/agent_systems_lab/queue_store.ex)、[IntentStore](../lib/agent_systems_lab/intent_store.ex)、[Scheduler](../lib/agent_systems_lab/scheduler.ex)。

实验：[L10](../labs/L10-background-scheduling.md)、[L12](../labs/L12-backpressure-budgets-fairness.md)、[L13](../labs/L13-database-outages-p3.md)，将持久队列上界与内存进程上界分别量测。

习题：① priority 是否足以防饥饿？② 背压应该在领取之后才发生吗？③ retry 的 due_at 为什么属于数据库事实？

教师参考：① 需 aging 和可见等待指标；② 还要有入队限制及执行并发限制；③ 重启与多 Worker 必须遵守同一到期时间。各 1 分。

证据：[QueueStore 测试](../test/agent_systems_lab/queue_store_test.exs)、[负载测试](../test/agent_systems_lab/load_demo_test.exs)、[P3 报告](../docs/p3-report.md)。

状态：design_card — 仅设计卡；教学 Queue 已实现，生产 Oban 集成只做源码责任对照，未替换为其执行引擎。

<!-- chapter:ch19 -->
### ch19 Worker Pool 并发控制与公平调度

目标：在饱和和数据库阻塞时验证 Worker、领取任务和扫描数量有界；测量等待、服务份额与饥饿而非只报总吞吐。

前置知识：ch03、ch18、进程监控、任务预算与 timeout 回收。

源码入口：[Scheduler.status/1、wake/1](../lib/agent_systems_lab/scheduler.ex)、[Scheduler.Worker](../lib/agent_systems_lab/scheduler/worker.ex)、[TaskBudgetStore.reserve/1、timeout/2](../lib/agent_systems_lab/task_budget_store.ex)。

实验：[L12](../labs/L12-backpressure-budgets-fairness.md)，用固定负载测量高低 priority 的等待并观察 deadline 到期回收。

习题：① 为什么运行中进程有界仍可能排队无界？② 用一次 20ms sleep 能证明未饥饿吗？③ Worker 超时后预算可以归零重来吗？

教师参考：① admission 必须另限队列；② 不能，应记录实际等待与 aging 后 priority；③ 不可，持久消费与绝对 deadline 保留。各 1 分。

证据：[Scheduler 测试](../test/agent_systems_lab/scheduler_test.exs)、[deadline 测试](../test/agent_systems_lab/scheduler_deadline_test.exs)、[W13 验收](../docs/validation-week13.md)。

状态：design_card — 仅设计卡；同数据库多 Worker 已实现，跨租户资源公平性与跨机容量调度未实现。

<!-- chapter:ch20 -->
### ch20 Lease Heartbeat 超时与任务所有权

目标：通过真实 SIGSTOP/SIGCONT 让旧 Worker 停顿、租约过期、新 Worker 接管、旧 Worker 恢复，并观察本地提交与受控效果端 fencing。

前置知识：ch17–ch19、lease 时间、token/generation 与事务条件更新。

源码入口：[IntentStore](../lib/agent_systems_lab/intent_store.ex)、[Scheduler.Worker](../lib/agent_systems_lab/scheduler/worker.ex)、[FencingDemo](../lib/agent_systems_lab/fencing_demo.ex)。

实验：[L11](../labs/L11-leases-heartbeats-fencing.md)，再用 [L13](../labs/L13-database-outages-p3.md) 验证数据库中断时不越权提交。

习题：① 心跳停了能证明旧进程死了吗？② token 只在领取时检查足够吗？③ fencing 能撤销已发送的普通远程请求吗？

教师参考：① 不能，可能暂停或网络隔离；② 关键写入和效果端均须检查；③ 不能，外部端需支持对应拒绝协议，否则 unknown/reconcile。各 1 分。

证据：[现存正文](ch20-scheduling-and-recovery.md)、[lease 测试](../test/agent_systems_lab/lease_heartbeat_test.exs)、[fencing 安全测试](../test/agent_systems_lab/fencing_safety_test.exs)、[W12 验收](../docs/validation-week12.md)。

状态：draft — 已有六章试读稿之一；受控效果端配合 fencing，不将本地 lease 等同于通用远程执行唯一性。

<!-- chapter:ch21 -->
### ch21 Distributed State Consistency 与 Replication

目标：从同一 PostgreSQL 上的多 Worker 出发，解释事务一致性与跨数据库复制的不同故障模型；为只读副本案例列出延迟、读写路由和接管约束。

前置知识：ch04、ch17、ch20；先理解当前权威事实只有单个 PostgreSQL 实例。

源码入口：[Repo](../lib/agent_systems_lab/repo.ex)、[Storage.dispatch/4](../lib/agent_systems_lab/storage.ex)、[History.ReadonlyProof](../lib/agent_systems_lab/history/readonly_proof.ex)；后者核验静止还原副本，不是流复制。

实验：以 [L02](../labs/L02-transactions.md)、[L20](../labs/L20-history-migration-backup-restore.md) 为已实现对照；复制延迟与只读 replica 仅保留纸面故障推演，不计实验通过。

习题：① 多 Worker 是否等于多数据库 HA？② 从滞后副本读 lease 后写主库有哪些风险？③ archive 还原副本能当作实时 replica 证据吗？

教师参考：① 不是；② 所有权判断必须在权威写库原子核验，旧读不可授权；③ 不能，只证明一个静止快照还原。各 1 分，必须明确未实现的复制链路。

证据：[事务测试](../test/agent_systems_lab/storage_test.exs)、[备份测试](../test/agent_systems_lab/backup_test.exs)、[W21 范围记录](../docs/validation-week21.md)。

状态：design_card — 仅设计卡；replication、只读 replica 路由、Raft 与跨机一致性均为概念或后续实验，项目未实现。

<!-- chapter:ch22 -->
### ch22 故障转移 资源调度与多租户隔离

目标：分别画应用 Worker 接管、单数据库断连恢复、数据库主从切换和租户隔离的责任图，防止用前两项冒充后两项。

前置知识：ch18–ch21、有限资源、受管数据库身份与最小权限。

源码入口：[Faults.DatabaseProxy](../lib/agent_systems_lab/faults/database_proxy.ex)、[DatabaseFaultDemo](../lib/agent_systems_lab/database_fault_demo.ex)、[QueueStore](../lib/agent_systems_lab/queue_store.ex)。

实验：[L13](../labs/L13-database-outages-p3.md) 的 loopback 代理断连恢复；多租户和主从 failover 仅设计新的独立验收矩阵。

习题：① 代理恢复是否证明数据库自动故障转移？② 私有工作区是否等于强租户隔离？③ 将来加租户至少在哪里绑定身份？

教师参考：① 不是，仍为原数据库实例；② 不是，同宿主账户和资源仍共享；③ 接收授权、持久对象、claim、工具能力和审计至少贯通前三项，并列出其余约束。各 1 分。

证据：[DB 代理测试](../test/agent_systems_lab/database_proxy_test.exs)、[调度 DB 测试](../test/agent_systems_lab/scheduler_database_test.exs)、[W14 验收](../docs/validation-week14.md)。

状态：design_card — 仅设计卡；实现应用恢复和受控断连演练，数据库 failover、租户身份、配额隔离和云资源调度未实现。

## 第六篇：编排、安全与审批

<!-- chapter:ch23 -->
### ch23 Task Planning DAG 与 Workflow Engine

目标：从静态图验证依赖、并行、结果汇合、失败传播与恢复，不让下游节点在前驱未确认时启动。

前置知识：ch17–ch20、有向无环图、节点预算分配与持久 intent。

源码入口：[Workflows.Definition.new/2、ready/2](../lib/agent_systems_lab/workflows/definition.ex)、[Workflows.Join.build/2](../lib/agent_systems_lab/workflows/join.ex)、[Workflows.Coordinator](../lib/agent_systems_lab/workflows/coordinator.ex)。

实验：[L16](../labs/L16-dag-workflows.md)，对照串行及并行路径，并在 fork/join 中间 kill 后恢复。

习题：① 模型可以动态追加任意节点吗？② 上游失败时下游应如何处理？③ 汇合输入为何需要绑定前驱身份和结果？

教师参考：① 当前只接受宿主静态图；② 按既定失败传播终结或阻塞，不伪造成功依赖；③ 防止串错任务或使用迟到结果。各 1 分。

证据：[图定义测试](../test/agent_systems_lab/workflow_definition_test.exs)、[Join 测试](../test/agent_systems_lab/workflow_join_test.exs)、[W17 验收](../docs/validation-week17.md)。

状态：design_card — 仅设计卡；静态 DAG 已实现，LLM 动态规划、任意循环工作流和通用分布式编排未实现。

<!-- chapter:ch24 -->
### ch24 Multi Agent Handoff Reviewer 与人工审批

目标：以有独立工作区的固定角色对照解释协调成本，令人工审批绑定确切产物与返工轮次，而非绑定可变路径名。

前置知识：ch07、ch16、ch23、artifact hash、审批决定与暂停状态。

源码入口：[Approvals.decide/3、release/3](../lib/agent_systems_lab/approvals.ex)、[Approvals.Artifact](../lib/agent_systems_lab/approvals/artifact.ex)、[Approvals.Cases](../lib/agent_systems_lab/approvals/cases.ex)、[WorkflowDemo](../lib/agent_systems_lab/workflow_demo.ex)。

实验：[L16](../labs/L16-dag-workflows.md) 与 [L17](../labs/L17-human-approvals.md)，审批后改变产物，再核验旧批准失效和受控返工。

习题：① Reviewer 输出 passed 能替代人工批准吗？② 暂停会重置任务 deadline 吗？③ 为什么批准应绑定 subject hash 而非路径？

教师参考：① 不能；② 不重置，控制面与预算事实独立；③ 路径可指向新内容，hash 绑定实际批准对象及版本。各 1 分。

证据：[审批 Case 测试](../test/agent_systems_lab/approval_cases_test.exs)、[产物测试](../test/agent_systems_lab/approval_artifact_test.exs)、[W18 验收](../docs/validation-week18.md)。

状态：design_card — 仅设计卡；固定脚本角色、静态编排与本地人工决定已实现，真实模型自主 handoff、通用多 Agent 协议与身份认证未实现。

<!-- chapter:ch25 -->
### ch25 Sandbox 文件系统 进程与网络隔离

目标：让固定 C 探针直接 open/connect/fork，区分参数拒绝与 OS 阻断，并在超时、取消、调用者退出后核验进程树清理。

前置知识：ch03、ch07、ch16、OS PID 与 BEAM PID、资源限额。

源码入口：[Isolation.execute/4、capabilities/0](../lib/agent_systems_lab/isolation.ex)、[Isolation.Policy](../lib/agent_systems_lab/isolation/policy.ex)、[原生探针](../priv/isolation/probe.c)。

实验：[L14](../labs/L14-isolated-execution.md) 的私有 canary、网络、CPU、输出、文件限额及残留进程验证。

习题：① ENOENT 是否能证明越界读取被拒？② 后端不可用能退回宿主执行吗？③ close Port 就能证明所有 OS 子进程已消失吗？

教师参考：① 不能，应先证明 canary 存在并检查权限错误；② 必须失败关闭；③ 不足，还需核验实际 owned PID 和 guardian 退出。各 1 分。

证据：[隔离策略测试](../test/agent_systems_lab/isolation_policy_test.exs)、[隔离测试](../test/agent_systems_lab/isolation_test.exs)、[W15 验收](../docs/validation-week15.md)。

状态：design_card — 仅设计卡；已验收 Darwin arm64 Seatbelt 后端，Linux namespace/cgroup、总内存/磁盘强限制和多租户安全边界未实现。

<!-- chapter:ch26 -->
### ch26 Authentication Authorization Secrets 与 Audit

目标：从模型伪造权限和观测泄露反例识别宿主授权、能力快照、审批记录与审计脱敏；列出尚缺的真实身份与 secrets 管理层。

前置知识：ch09、ch11、ch24、ch25，信任边界与最小能力。

源码入口：[Tools.Gateway.validate_call/4](../lib/agent_systems_lab/tools/gateway.ex)、[MCP.Policy](../lib/agent_systems_lab/mcp/policy.ex)、[Approvals.Audit](../lib/agent_systems_lab/approvals/audit.ex)、[Observability.Schema](../lib/agent_systems_lab/observability/schema.ex)。

实验：[L14](../labs/L14-isolated-execution.md)、[L15](../labs/L15-mcp-stdio.md)、[L17](../labs/L17-human-approvals.md)、[L18](../labs/L18-observability.md) 的拒绝和脱敏用例。

习题：① Context 中的文字“已授权”会改变能力吗？② 审批人字符串证明登录身份吗？③ Trace 应包含 claim token 或完整 prompt 吗？

教师参考：① 不会，权限来自宿主持久策略；② 不会，当前记录者身份由可信宿主声明；③ 不应，使用有限关联字段和脱敏。各 1 分。

证据：[Gateway 测试](../test/agent_systems_lab/isolation_tool_gateway_test.exs)、[MCP 权限测试](../test/agent_systems_lab/mcp_tool_gateway_test.exs)、[观测测试](../test/agent_systems_lab/observability_test.exs)。

状态：design_card — 仅设计卡；工具授权与有限审计已实现，用户登录、OAuth/OIDC、secret vault、RBAC/ABAC 平台及防恶意同账户的隔离未实现。

## 第七篇：观测、评估与系统验收

<!-- chapter:ch27 -->
### ch27 OpenTelemetry Trace Span 与 Metrics

目标：按 Run ID 串联模型、工具、claim、恢复、审批和返工，证明观测导出失败时执行事实不变且缓冲有界。

前置知识：ch14、ch20、ch24，trace/span 关系、计量单位与高基数风险。

源码入口：[Observability.emit/4、span_start/3、span_stop/3](../lib/agent_systems_lab/observability.ex)、[Buffer](../lib/agent_systems_lab/observability/buffer.ex)、[Query](../lib/agent_systems_lab/observability/query.ex)。

实验：[L18](../labs/L18-observability.md)，注入抛错、阻塞与超时 exporter 并检查队列上界和原始业务 Event。

习题：① 丢 Trace 等于丢业务提交吗？② 100% exporter 成功能证明关键关联完整吗？③ Metrics label 能否放 operation 全量参数？

教师参考：① 否，两条路径独立；② 仍需核验固定关联与 span 配对；③ 不可，参数可能敏感且基数无界。各 1 分。

证据：[观测执行测试](../test/agent_systems_lab/observability_execution_test.exs)、[查询测试](../test/agent_systems_lab/observability_query_test.exs)、[W19 验收](../docs/validation-week19.md)。

状态：design_card — 仅设计卡；项目内部 trace/metrics 与受控 exporter 已实现，未接入完整 OpenTelemetry SDK/OTLP Collector 生产链路，不以章题冒充已接入。

<!-- chapter:ch28 -->
### ch28 Agent Evaluation Dataset Rubric 与 Scorer

目标：固定任务、dev/holdout、profile 与独立 scorer，报告所有计划样本的成功率、成本、延迟和失败分类，保留真实回归判定。

前置知识：ch07、ch25、ch27，配对比较、缺失值、固定产物 oracle 与预算口径。

源码入口：[Evaluation.Suite.load/1](../lib/agent_systems_lab/evaluation/suite.ex)、[Runner.execute/6](../lib/agent_systems_lab/evaluation/runner.ex)、[Scorer.score/5](../lib/agent_systems_lab/evaluation/scorer.ex)、[Comparison](../lib/agent_systems_lab/evaluation/comparison.ex)。

实验：[L19](../labs/L19-repeatable-evaluation.md)，同套任务比较 reference/regressed；保留原始 comparison，而非用示例演示的通过覆盖性能退步。

习题：① harness error 可从分母删除吗？② 模型自报成功为何不足？③ 相同语义/成本是否必然同延迟？

教师参考：① 不可，所有计划样本有行且错误可见；② 用独立产物字节评分及身份配对；③ 否，原延迟和门槛仍如实报告。各 1 分。

证据：[报告测试](../test/agent_systems_lab/evaluation_report_test.exs)、[Scorer 测试](../test/agent_systems_lab/evaluation_scorer_test.exs)、[W20 验收](../docs/validation-week20.md)、[W22 演示修订](../docs/validation-week22.md)。

状态：design_card — 仅设计卡；离线 Scripted 数据集和合成价格表已实现，真实模型能力评测、真实账单与在线 benchmark 未实现。

<!-- chapter:ch29 -->
### ch29 Replay Testing Regression 与 Fault Injection

目标：把不变量转为明确故障点、可重复注入、原始证据和结果索引；区分测试通过、独立环境复现与真人试读三种结论。

前置知识：ch13–ch28、失败窗口、固定种子、源 manifest 与环境记录。

源码入口：[P2Verification](../lib/agent_systems_lab/p2_verification.ex)、[P3Verification](../lib/agent_systems_lab/p3_verification.ex)、[Reproduction.verify/1](../lib/agent_systems_lab/reproduction.ex)、[ReaderStudy.assess/3](../lib/agent_systems_lab/reader_study.ex)。

实验：[L09](../labs/L09-p2-fault-acceptance.md)、[L13](../labs/L13-database-outages-p3.md)、[L20](../labs/L20-history-migration-backup-restore.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md)；[L22](../labs/L22-release-readiness.md) 只核验发布前材料和接口。

习题：① 再跑直到绿能替代解释失败吗？② 内存模式排除 DB 用例可算全量通过吗？③ agent 技术审阅能计作外部真人吗？

教师参考：① 应保留失败、定位和修复证据；② 不可，排除数量与完整 PG 回归分报；③ 不可，当前真实读者 0 人。各 1 分。

证据：[P2 测试](../test/agent_systems_lab/p2_verification_test.exs)、[P3 测试](../test/agent_systems_lab/p3_verification_test.exs)、[复现测试](../test/agent_systems_lab/reproduction_test.exs)、[W22 验收](../docs/validation-week22.md)。

状态：design_card — 仅设计卡；已有受控故障矩阵，不能推导任意主机故障、跨平台、真实模型或真人试读已通过。

<!-- chapter:ch30 -->
### ch30 完整 Agent 系统设计 实现 测试与部署

目标：围绕一份冻结源码向读者交付入口、运行手册、测试、限制和待办；在答辩中证明运行时的权限、预算及恢复事实没有因发布检查被改写。

前置知识：C01–C12 的实验报告、ch01–ch29 的责任边界；理解设计卡和已完成正文的差别。

源码入口：[mix.exs](../mix.exs)、[固定运行入口](../scripts/mix)、[Reproduction.export/2](../lib/agent_systems_lab/reproduction.ex)、[ReaderStudy.prepare/1](../lib/agent_systems_lab/reader_study.ex)；版本冻结不等于生产部署许可。

实验：[课程地图](../docs/course-map.md) 的 12 单元，最后完成 [L22](../labs/L22-release-readiness.md) 发布前核验；W24 冻结验收矩阵与 v0.1 候选发布仍为下一周任务。

习题：① 写了 30 卡可宣称全书完成吗？② v0.1-dev 加源 manifest 可替代不存在的历史 tag 吗？③ 什么会阻止宣称 P5 全部通过？

教师参考：① 不可，只有六章稿和 30 卡；② 可准确标识本次快照，不能伪造历史演进标签；③ 真实外部 3–5 人试读及其 fresh-workspace 复现尚未验收。各 1 分，交付报告须明确范围。

证据：[课程地图](../docs/course-map.md)、[完整运行手册](../docs/recovery-runbook.md)、[W22 原始结论](../docs/validation-week22.md)、[L22](../labs/L22-release-readiness.md)。

状态：design_card — 仅设计卡；本机教学交付准备已安排，W24 候选包、生产部署、多租户服务及商业出版均不在本周完成声明中。
