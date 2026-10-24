# ADR 0011：以数据库资格 fence 旧代次，并用真实暂停验证

- 状态：已接受
- 日期：2026-10-21，Asia/Shanghai
- 对应阶段：第 12 周、P3、L11

## 背景

第 11 周已从持久意图原子领取，独立续期，并支持有限 Worker 与到期重投。进程退出测试证明接管流程可继续，但暂停的进程没有退出；它可能在 successor 已取得资格后恢复，继续发送原模型结果、确认 receipt 或执行清理。只依靠 lease 或 seq CAS，无法完整说明旧代次在这些边界的行为。

本周围绕 lease、heartbeat 与 fencing 增加可观测约束和真实 SIGSTOP/SIGCONT 验证。保持已有 Run/Event/intent 原子性、operation/attempt/receipt、有限 retry、绝对预算与 unknown 核对协议，不引入第二份执行事实。

## 决策

### Lease 与 Heartbeat 约束同一资格

数据库时间决定当前意图的领取和续期资格。续期必须验证当前 Run、intent、seq、owner、token、generation 和未过期 lease；成功只延长当前 expiry，不更换代次。原 claim 已过期、被取消或被 successor 替换时，续期失败，不复活旧凭证。

仅在 UPDATE 前验证还存在暂停窗口：调用在 `verify` 之后持有 Run 锁，但恢复时 lease 可能已过期。续期 UPDATE 自身以数据库当前时间检查原 expiry，并在实际写入时计算新的 deadline；未更新返回 `:claim_expired`。内部 `:before_renew_write` gate 精确验证这个边界，不能因锁仍在手中而复活旧 token。

Heartbeat 与执行独立，执行等待不阻塞续期；其生命周期又必须绑定本次 Worker/executor。续期失败后停止旧执行并等待清理，原 attempt/receipt 保留。进程诊断帮助定位续期和资格丢失，不成为数据库事实的替代品。

Worker 为每次续期 timer 使用新的 reference，仅处理当前 tick，忽略陈旧与重复通知。`Scheduler.status` 的在途项保留 Worker/executor/claim/renewals，增加 Heartbeat sequence、ACK monotonic time、duration、返回 expiry 与 age；首次 ACK 前诊断为 nil。时间和计数仅属于当前 BEAM/Worker，不持久化、不跨进程启动比较，也不成为租约授权。

### 在每个受保护写入边界验证 fencing

领取互斥只授权某段时间内的执行，不能保证旧进程永不恢复。结果接受、模型资源更新、工具效果前授权、receipt 确认、retry 更新、renew 和 release 均沿用当前资格校验，保持 Run → Intent 锁顺序。旧 owner 无法通过伪造 claim map 的未来 expiry、仅保留相同 intent/seq 或执行退出清理覆盖 successor。

数据库校验保护本地已提交状态与本仓库受控效果门。已经发出的独立外部请求仍按目标能力处理；lease 到期不证明效果回滚。支持稳定身份的幂等/查询目标可以核对原 operation，未知的非幂等工具继续 blocked/manual。任意外部服务若要拒绝迟到代次，必须在目标自身实现对应作用域的 fencing 契约。

### 用独立 BEAM 验证操作系统暂停

故障 runner 仅创建和控制自己拥有的独立子 BEAM；停止整个子进程，同时暂停 Worker 控制过程、Heartbeat 与 executor。PostgreSQL 和父接管者持续运行，以真实数据库时间等待自然 expiry，再提交新的 token/generation。禁止修改 SQL 到期字段、清空 claim 或只暂停 executor 代替故障。

真实信号与精确 gate 配合使用。CONT 后，fixture 暂时保留 Worker 控制过程的 gate，让旧 executor 真正跨过 Storage/工具提交边界并获得拒绝，再释放控制过程验证续期失败与清理。这样同时验证持久 fencing 和本地停机；不会因 Heartbeat 抢先杀死 executor 而遗漏迟到提交的窗口。

同 seq 场景让 successor 保持相同 intent/seq 的有效新 claim，旧写入的拒绝必须依赖当前资格。另一个场景先提交 successor 状态，再恢复旧结果，证明已经前进的状态和模型录制不被覆盖。工具在效果前、效果后和 receipt 后分别暂停，确保拒绝迟到写入的同时没有丢失真实效果、重复业务或隐藏 unknown。

### 信号与证据属于实验进程

Runner 根据本次创建的子进程和握手身份确认控制目标，保存 PID、停止态、信号返回、自然 expiry、接管前后快照、实际迟到调用返回与清理结果。每轮失败均保留证据并报告失败，不能悄悄跳过不支持的暂停检查。

正常结束、异常与超时的清理路径先尝试恢复被暂停的自有子进程，再终止并等待退出；不对共享应用、数据库或猜测 PID 发信号。父进程被不可捕获的 OS kill 时无法运行 `after`，当前没有独立 watchdog；这种故障仍需按已保存身份人工核对清理。导出继续遵循现有 inert Codec，不因诊断放宽反序列化权限。

## 后果

旧执行可能继续存在甚至短暂恢复，但它的本地写入资格受数据库事实约束。Heartbeat 失联造成等待或额外投递，不能授权旧结果；新 owner 仍读取已扣预算、原 due、稳定 operation 和已确认 receipt。拒绝日志与前后快照共同解释失败，进程计数不能被当作持久业务指标。

本周证明单机 PostgreSQL 与受控离线模型/工具下的真实暂停接管。它不提供任意远端 exactly-once、不宣称已完成独立远端服务 fencing、网络分区、全局背压、公平性或生产恢复 SLO。Lease 取值需要后续负载测量；把它调得过短会增加误判和接管，不能靠重置预算修复。

## 验证

五类信号窗口覆盖同 seq 模型结果、工具效果前、工具效果后、receipt 后，以及 successor 提交后的旧模型结果。检查旧 renew/release、模型 attempt/frame、结果接受与工具确认均不能改变 successor；已确认 receipt 可继续，模糊结果依原能力保留，历史重建保持无效果。

全部前序测试继续作为门槛。实际重复轮次、通过数量、进程信号和证据位置见 [第 12 周验收记录](../validation-week12.md)；实验步骤与事故操作见 [L11](../../labs/L11-leases-heartbeats-fencing.md) 和 [恢复运行手册](../recovery-runbook.md)。
