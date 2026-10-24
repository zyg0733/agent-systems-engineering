# ADR 0012：持久队列准入、共享领取配额与有界执行

- 状态：已接受
- 日期：2026-10-21，Asia/Shanghai
- 对应阶段：第 13 周、P3、L12

## 背景

第 11—12 周通过持久意图、有限 Worker、lease、heartbeat 和 fencing 验证多消费者与旧代次暂停恢复。单个 Scheduler 的 Worker 上限仍无法限制数据库中新任务的积压；多个 Scheduler 的容量相加，也没有共同的在途配额。持续高优先级输入可能延迟低优先级意图。Heartbeat 能让一个没有进展的执行持续保留资格，单靠 lease 不能回收它。

本周增加显式命名的持久队列与任务执行预算，保持旧 Run 的行为。数据库继续保存业务事实、预算与领取资格；Scheduler 只保存有界的本地执行者和诊断，不复制一份待执行业务队列。命名队列准入和持久 dispatch 预算通过明确 opt-in 启用，不把不同范围的任务暗中归入同一个配额。所有后台 Worker 都增加本地执行 watchdog；旧未入队 Run 的持久策略格式与原 deadline 不变。

## 决策

### 准入与领取使用同一持久队列身份

队列创建时固定 capacity、max_inflight、aging_ms 和 starvation_ms。创建队列 Run 的事务先锁队列，再检查该队列尚未终结的 Run 数量，再原子提交 Run、初始 Event、Recovery 配置、预算与 intent。满载返回明确的拒绝；拒绝后不能留下孤立 Run、Event 或 intent。blocked 仍占用 capacity，因为未知效果尚未完成，不能靠不自动领取它而隐藏积压。终态释放准入名额，但保留历史和操作回执。

capacity 限制未完成工作，不是表大小或历史保留期。既有事件、checkpoint、幂等去重记录和核对证据不会因队列空出名额而删除。生产者收到拒绝后负责减速、保留输入或使用有界退避，不能在另一个无限进程或邮箱中排队。

领取队列任务时，所有消费者共享数据库中的 max_inflight 配额，并沿队列 → Run → Intent 顺序获取锁。它限制当前有效 lease 的总数，适用于同一队列的多个 Scheduler 和显式领取接口；续期不新增名额。旧 owner 的 lease 过期会释放逻辑配额，但暂停的旧进程可能仍在，因此有效 lease 配额不能等同于操作系统活进程总数。旧代次写入仍由既有 token/generation fencing 拒绝。

未加入命名队列的既有 Run 保持原语义；它们不获得新的全局容量保证。未指定 queue 的 Scheduler 只扫描未入队 Run，指定 queue 后只扫描该命名队列；仅加 run_ids 不会将一个默认 Scheduler 变成队列消费者。共享队列 quota 与每个 Scheduler 的 max_workers 分别约束数据库资格和本地执行数量，部署时必须同时计算两个范围。

### 有界扫描与优先级老化

队列候选基于已提交的当前 intent，排除有效 lease、尚未到期的 retry、blocked/manual 核对和终态。`scan_limit` 默认 32、范围 1—256，限制命名队列一次领取扫描的页大小；未入队路径保持前序完整扫描行为，不因这个选项中途漏掉任务。命名队列扫描能越过不可领取的前缀继续查找；不能让一批 future retry 永久遮住后面的到期任务。

基础优先级仍为 0—9，有效优先级为 `min(9, priority + floor(wait_ms / aging_ms))`；`wait_ms` 从当前 intent 的数据库创建时间计算。候选页内先比较有效优先级，再比较 intent ID。持久 ID 游标与本轮 ceiling 推进有界扫描，即使一页只有 future/损坏候选也继续向后；它提供轮转发现，不能解释成全队列每次严格选择最高分。此机制不抢占已领取步骤，不允许绕过租约、真实 retry due、权限或预算。

公平性报告同时给出队列状态、当前可领取候选的 intent 等待时间与不同任务的服务次数。饥饿检测只解释观察时已经具备领取资格、intent 年龄超过阈值的工作；未来 retry、活跃 lease、人工核对不能作为被 Scheduler 忽略的任务计入。它没有保存累计 eligible 时长；刚到 due 的旧 intent 也可能立刻越过年龄阈值，应结合原 due 解释。观测本身只读，不领取、不 renew、不执行模型/工具，也不修改 due 或 priority。

老化给出本实验负载与持续服务假设下的公平机会，不能保证任意到达速率、无限高优先级流、数据库长锁或故障条件中的完成期限。阈值越过是可见告警，不是自动重发或改写优先级的授权。

### 每任务预算与执行回收相互配合

命名队列 Run 默认持久保存 `task_budget: [max_dispatches: 32, execution_timeout_ms: 5000]`，创建时可明确设置。预算在领取执行前扣减，新的 Worker、token、generation 或 BEAM 不能重置计数；同一有效 claim 不重复扣除同一次预留。模型字节、stream event、tool call、turn、绝对 Run deadline 与 retry 有限次数继续采用已有独立约束。调度次数衡量交付机会，不能解释为模型 token、业务效果数或成功次数。

Worker 的本地 watchdog 独立于 heartbeat。Scheduler 的单次执行上限默认 30000ms；任务固定执行超时和原 Run 绝对 deadline 进一步取更早者。超时后先停止并确认本次 executor 退出，再在当前 claim 下读取持久事实；不能先释放资格再让旧执行继续提交。已确认 receipt 复用，准备后无法证明结果的工具进入 blocked 核对流程；没有工具台账的未完成执行进入明确 failed。调度机会耗尽为 `{:budget_exceeded, :dispatches}`，执行回收为 `{:budget_exceeded, :execution_timeout}`。核对已发生的结果不因调度预算耗尽而失去入口，不能凭本地超时清除已扣资源或换业务身份重发。

watchdog 是本地回收机制，数据库 fencing 才是迟到提交的持久约束。数据库不可用、当前进程暂停或底层不可中断执行时，本地 timer 不是严格实时终止保证。已发出的远端请求仍需目标自身的幂等、查询或 fencing 契约。

### 本地执行与唤醒保持有界

Scheduler 不预领一批任务放入内存等待：可用 Worker 槽位才触发领取。重复 wake 合并为一次待处理提示，周期扫描仍能在通知丢失后发现工作。队列扫描批次、在途 Worker、executor 与该路径派生的 Provider/owner watcher 受明确槽位约束；结束或回收前等待执行者实际退出，再归还本地槽位。TaskSupervisor 本身不是全应用的硬子进程配额，其他调用者也可以创建自己的任务。

这些界限适用于声明范围内的项目执行路径。其他实例、任意外部调用者、无界 subscriber 邮箱、独立远端进程与历史表保留需要各自的资源策略，不能由一个 max_workers 数字推导整个机器资源有界。

## 后果与验证

满载现在形成可观察的拒绝，并让生产者面对容量事实；blocked 长时间占位会压低吞吐，但这种可见性比自动丢弃未知任务更符合恢复协议。共享队列锁串行化准入和配额判断，是教学实现的清晰一致性边界，也可能成为高负载热点；后续选型应比较真实测量与组件契约。

验收覆盖并发准入、跨实例共享配额、重复 wake、有界扫描、调度预算的跨进程保留、执行超时后的 receipt/unknown 去向，以及饱和负载下 Worker 和进程高水位。公平性需保留服务顺序、等待分布和饥饿条目，不能仅以最终完成数替代。已有 P2 故障窗口、P3 lease/fencing 与全部历史测试继续通过。

实际 API、命令和测量结果见 [L12](../../labs/L12-backpressure-budgets-fairness.md)、[恢复运行手册第 11 节](../recovery-runbook.md#11-背压任务预算与饥饿告警) 和 [第 13 周验收记录](../validation-week13.md)。本周不宣称生产吞吐/延迟 SLO、OS 资源沙箱、多租户隔离或任意远端 exactly-once。数据库断连与组件源码对照仍按第 14 周计划单独验收。
