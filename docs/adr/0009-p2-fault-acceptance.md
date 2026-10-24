# ADR 0009：用确定故障窗口完成 P2 恢复验收

- 状态：已接受
- 日期：2026-10-21，Asia/Shanghai
- 对应阶段：第 10 周、P2、L09

## 背景

第 7—9 周建立了严格历史重建、模型录制、持久 Recovery、claim fencing、operation/attempt 台账、有限 retry 与 unknown 队列。单次正常完成不能证明这些机制跨崩溃组合后仍保持正确，尤其目标业务成功与 Runtime 接受结果之间、恢复者再次失联和人工核对 receipt 已确认但 Event 尚未接受的窗口。

P2 需要冻结明确契约下的行为，并给操作员提供按事实恢复的流程。验收依据应能区分“正确暂停”“确认复用”和“重复业务后得到相同终态”，同时继续拒绝损坏或不兼容记录。

## 决策

### 确定边界与真实退出

新增独立的 `P2Verification` 验收编排和 `mix lab.p2`。每个场景先到达指定 hook/gate，记录位置后真实终止调用进程；独立读取已提交数据，等待 PostgreSQL lease 自然到期，再以原业务身份处理。正式默认每个窗口重复 20 次，并增加新 BEAM 与恢复中再次崩溃的证据。

故障编排不修改 Run 的业务语义、原配置、预算、cursor、due 或 claim 时间。以 sleep 猜 COMMIT 时机不算确定窗口；等待已保存 lease/due 到期是明确资格测试。Provider 或工具 worker 的失败与真正 caller 退出分别记录，不能混称同一种故障。

### 接受标准是不变量

每个场景声明预期结果和保护断言，保留注入前 `initial.bin`、故障后首次采证 `before.bin` 与处理后 `after.bin`，并用 `crashes.bin` 保存实际退出记录。正确 manual blocked 也可作为通过的验收结果；不要求所有验收 Run 最终 succeeded。硬性标准为：

- 已确认效果不重复，原 operation 与参数绑定不改变。
- 未知的非幂等/不可查询效果不自动投递，reconcile 意图与队列保持可见。
- 新 owner 保留原 cursor、资源、绝对期限、预留次数和 due；旧 token 无法写入或释放 successor 的 lease。
- Run/Event/意图、模型录制与恢复接受进度在既定事务中保持一致。
- 纯重建、审计和队列读取不触发 Provider 或工具。

### 本地已确认 receipt 优先

核对先检查完整配对、参数绑定且已确认的本地 receipt，再决定是否需要外部查询。外部不可查询、自动查询次数耗尽或查询窗口关闭，不能使已知的本地结果失去可接受性。此规则修正现有核对路径在确认后崩溃时可能卡住的情况，没有增加新的投递权限。

消费已确认 receipt 只补齐尚未接受的 Kernel 事实；若 Event 已 COMMIT，当前 seq 自然进入下一意图。缺少已确认 receipt 时，queryable 工具才按既定有限策略查询；manual 工具继续保留 unknown。人工证据也需 claim、预期 seq、原 operation/tool 与不可变审计，不可直接修改投影或删除旧 attempt。

### 原始证据与运行手册

正式验收保存机器可读汇总、各场景的前后快照/审计和跨 BEAM 日志。报告区分 probe 数、真实 kill 数、业务效果、执行/查询 attempts 与正确暂停，不使用单一“成功率”掩盖人工交接。

[恢复运行手册](../recovery-runbook.md) 指导操作员先只读对齐历史、配置、retry、operation 与回执，再选择 resume、查询或人工证据。演示命令创建新 Run；已有 Run 始终通过原 ID 续跑。数据库错误不能解释成 COMMIT 未发生或目标无效果。

## 后果

确定边界可以稳定重现 caller 未收到 ACK、目标效果已发生、接管者再次失联与核对提交歧义，使错误实现能被保护断言捕获。保留完整注入前、故障后与处理后证据便于审阅恢复决定和故障报告，而非只看最终 State。

20 次重复说明指定边界已多轮验证，不构成生产 SLO、概率保证、全时序模型检查或任意外部 exactly-once。当前范围仍是单机 PostgreSQL、离线 Scripted Provider 与声明能力的 Mock/受控文件工具；主机断电、介质故障、真实网络与供应商行为、生产 dispatcher 和完整分布式暂停接管另行验证。

## 验证

正式实测、故障矩阵、精确数量与日志见 [P2 故障报告](../p2-fault-report.md) 和 [第 10 周验收记录](../validation-week10.md)。实验步骤与保护要求见 [L09](../../labs/L09-p2-fault-acceptance.md)。全量前序测试、纯重建和队列零效果断言继续作为 P2 的回归门槛。
