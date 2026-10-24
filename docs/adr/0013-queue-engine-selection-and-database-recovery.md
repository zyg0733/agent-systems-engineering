# ADR 0013：队列组件选型与数据库恢复边界

- 状态：接受，用于第 14 周教学系统与 P3 验收。
- 日期：2026-10-21。
- 依据：[原研究计划 W14/S6](../../Agent%20Systems%20Engineering%20研究与落地计划.md)、[Oban 源码研究](../research/oban-scheduling-recovery.md)、[ADR 0010](0010-background-scheduling.md)、[ADR 0011](0011-leases-heartbeats-fencing.md)、[ADR 0012](0012-backpressure-and-fairness.md)。

## 问题

第 11 至 13 周已经将领取、执行资格、业务恢复和流量控制拆开。数据库断连让这些边界暴露得更明显：没有收到 COMMIT 回报不等于事务回滚，连接池重连也不等于原 Worker 仍有提交权。同步领取或续租若阻塞控制进程，会使 status、取消与 watchdog 一起等待数据库。

Oban 是值得复用的成熟作业组件；本期需要确定是否立即替换教学调度器，以及替换后哪些业务协议仍属于 Runtime。本次研究只覆盖开源 Oban 2.24.2，固定提交 `0704bf0018bfc915560998fbdfb899dd508f5aff`；没有运行其测试、评估其吞吐或接入其商业组件。

## 决定

P3 继续保留现有教学队列，不加入第二个调度所有者。使用已安装 Ecto SQL/Postgrex/DBConnection 处理连接与事务，本地调度器增加有界异步数据库请求、可见断连状态与有上限的退避。claim 的 COMMIT 未确认时不启动 executor；已提交 claim 保持原租约，恢复后通过数据库重新发现。renew 不确定时停止本次执行，不主动释放无法确认的资格；后续 Worker 依靠原 lease 到期与新 generation 接管。

数据库错误属于基础设施故障，不消耗一次新的业务 provider/tool retry，不生成伪造业务失败或完成事件。已确认事件、调度预算与工具记录不回退；unknown 继续进入原核对流程。停止本地 executor 也不能证明外部请求未生效。

`Scheduler` 的数据库超时和退避配置是运行控制，不修改原 Run 的固定业务策略。默认数据库 helper 超时为 1000ms，退避初始 100ms、上限 5000ms；以最终 API 校验和测试为准。控制 helper 的停止不取消已经在 PostgreSQL 提交的事实，必须把结果未知作为恢复输入。

## 对照结论

Oban Basic 事务领取使用 SKIP LOCKED 和 CTE；Producer 按本地 demand 启动工作。Executor 的 perform 与随后 ack 分开，完成回报的数据库重试不重新调用 perform。Basic ack 比较 ID、state、attempted_at，确实具备旧 attempt 保护；本地显式 token/generation/DB-clock lease 是不同契约。Lifeline 按时间救援 executing job，可能与尚活着的旧执行重叠。unique 限制插入冲突，不能替代执行并发、共享容量或业务幂等。固定源码和相邻测试见 [S6](../research/oban-scheduling-recovery.md)。

这些差异说明，替换队列可以复用 Job 生命周期，却不能删除业务 operation 台账、纯事件重建、核对、预算和权限。继续教学实现是为了让目前已经验证的不变量与实验保持一条明确调用链，不构成对 Oban 可靠性或性能的负面判断。

## 未来 Oban adapter 的进入条件

1. 明确一个调度权威。迁移某个队列时暂停原消费者，核对活动 claim/unknown 后切换；不得让两个引擎各自独立拥有同一业务步骤。
2. 将 Run/Event/intent 与 Job/outbox 在同一个 PostgreSQL 事务中提交；把 Job ID、run_id、intent seq、稳定 operation ID 的映射定义成可验证契约。
3. 保留业务提交时的权威检查。不能仅因为 job 是 executing 或唯一就允许旧 attempt 写业务投影；明确采用 adapter 的哪一种 lease/fence、clock 与代次来源。
4. 原 retry due、每任务预算、取消与权限先通过契约测试，再映射 job attempt、snooze、cancel、rescue。核对已发生结果与重新执行业务必须使用不同入口。
5. 对 adapter 重跑 W3、W7 至 W14 的关键窗口：COMMIT 前后、效果后无 receipt、恢复再崩溃、SIGSTOP/SIGCONT、renew 回报不确定、断连重连、饱和背压与公平性。Job 完成不是这些测试的替代证据。
6. 在同一固定环境分别测量吞吐、尾延迟、数据库锁、连接池与待 ack 任务数量；明确历史保留、通知丢失和部署退出策略，再决定迁移范围。

## 后果与边界

好处是 P3 的故障结果继续对应可读的本地机制，并且控制面不会因为一个同步数据库调用长期失去响应。代价是继续维护一套教学队列与有限观测，不具备成熟组件的完整管理能力；共享队列锁和逐 Run 校验也可能成为瓶颈。

本期验证单 PostgreSQL、受控连接故障和有限 Worker，不完成数据库主从切换、跨区高可用、连接池代理兼容、恶意 SQL 隔离或任意远端 exactly-once。P3 报告必须保留每项重复次数和原始结果；第 24 周建议的每故障点至少 20 次是后续 v0.1 发布门槛，不能用本周默认演示次数替代。
