# P3 阶段验收与总结

验收日期：2026-10-21，Asia/Shanghai。范围是原计划 W11—W14 的单 PostgreSQL、多 Worker 教学调度与恢复。正式命令为：

```sh
./scripts/mix lab.p3 --output artifacts/week14-p3 --repetitions 2
```

本次实际执行四个组件，全部 **22 项阶段判据通过**，随后在父进程与独立 BEAM 中审计 **63 个 Run**。总报告 `all_passed:true`，不是将前几周旧 JSON 合并后的结果。

63 个最终业务状态为 **59 succeeded、2 expected_failed、2 expected_blocked**。两个预算用例按契约失败，两个非幂等 unknown 用例保持人工核对；`outcomes.all_runs_succeeded:false` 是真实结果，不妨碍所有实验不变量通过。

## 四组件的实际结果

| 周次与组件 | 本次执行与结果 | 原始报告 |
| --- | --- | --- |
| W11 scheduling | 12 个批任务、两个各 2 Worker 的 pool，实际并行 4 个互异领取；模型/工具重试各 3 次；长调用观察 6 次续租；实际 kill 后 generation 1→2，效果仍 1；另有独立应用自动调度和 manual 占位 | [scheduling/report.json](../artifacts/week14-p3/scheduling/report.json) |
| W12 fencing | 5 个窗口各 2 轮，10 次真实 SIGSTOP 与 SIGCONT，8 个同 seq 接管 probe；实际旧 executor 调用均被拒，旧代次覆盖 0、重复效果 0 | [fencing/report.json](../artifacts/week14-p3/fencing/report.json) |
| W13 load | 容量 12 接收 12/24 次投递，12 个拒绝 ID 无 Run；共享有效 lease、Worker、executor、provider 峰值各 2；已测执行链进程峰值 8；aging 后低优先级紧随 incumbent 服务，等待 158.275ms；饥饿告警解除 | [load/report.json](../artifacts/week14-p3/load/report.json) |
| W14 database | 5 类独立连接故障各 2 轮，10/10 通过；实际截断 COMMIT 成功回报 2 次；6 个旧新执行代次的真实拒绝试验、2 次同 Scheduler 自动重连完成；工具效果后未知结果先保存 manual 证据再显式确认，效果仍 1 | [database/report.json](../artifacts/week14-p3/database/report.json) |

P3 的 `repetitions: 2` 只作用于信号暂停和数据库窗口；scheduling 与 load 各执行一次、每次 12 个批任务。没有把开发 smoke、ExUnit、前几周正式运行和这次结果混在同一计数中。

## 阶段不变量

| 判据 | 本次证据 |
| --- | --- |
| 没有确认的数据库资格不启动业务 | claim 在事务 COMMIT 返回后交给 Worker；真实断连与 SQL 等待超时测试验证无额外 Worker/业务记录 |
| 旧执行者无法覆盖 successor | 10 个信号窗口与 6 个数据库接管窗口检查真实旧调用及前后事实相等 |
| 外部效果不因未知回报盲目重发 | 固定 operation/参数哈希；已确认 receipt 复用；unqueryable 效果保留 manual 后才可信确认 |
| 连接恢复不是预算重置 | 原 Run deadline、模型尝试、帧扣账、dispatch 与 retry 计数跨代次保留；数据库错误不被记录成新 provider/tool 业务失败 |
| 流量与控制进程受限 | 队列准入、共享 lease、每 pool Worker、单一在途 claim/renew helper、通知合并与数据库退避分别约束各自范围 |
| 业务状态可只读重建 | 63 个 Run 在不同 PID 的 BEAM 中与原 State 严格一致，20 个执行入口计数全部为 0 |
| 预期阻塞保留可见性 | scheduling 和 load 各留下 1 个 manual blocked Run，仍有原 operation/核对入口，不能记成全部成功 |

本轮完整回归 **582 passed（580 tests、2 doctests）**，包括 W13 已有 562 项与本周新增 20 项。原 10/10 fixtures、四个 COMMIT 前后真实 kill 探针全部通过。没有新增依赖或迁移；Ecto/Postgrex 锁文件及原 14 个迁移继续使用。

## 数据库故障究竟验证了什么

父进程的 Repo 始终直接连接共享 PostgreSQL，子 BEAM 的 pool 通过仅本轮拥有的 loopback TCP 代理。每个 probe 保存原/新 backend PID 和数据库身份、proxy 事件、实际错误、恢复快照与子进程清理。没有停止数据库、杀无关 backend 或模拟一个手写的 driver error 来充当真实网络断连。

- `before_commit_rollback`：模型已经独立预留与扣账；最终结果事务在 COMMIT 前断连，其投影、Events 和录制未泄漏。父进程用原始 MVCC 行快照观察 gate，不等待被测事务持有的 Run 锁。已合法扣除的资源继续保留。
- `commit_ack_lost`：代理确实收到后端 `CommandComplete(COMMIT)`，随后丢弃客户端成功回报。父连接确认最终 State、seq、cursor 与唯一模型录制已提交；之后 resume 不再请求模型或改变原事实。
- `heartbeat_disconnect`：观察到实际续租后切断连接，原 Worker/executor 停止；等待数据库实际 expiry，再以同 intent/seq 的新 generation 接管。旧连接恢复后的真实 renew 被拒，successor 事实保持。
- `tool_effect_pending_disconnect`：目标效果已经提交，receipt 尚未确认；先存 prepared/effects=1，恢复同 operation 后进入 unknown/manual。保留 unknown 原始文件，再用独立父审计的明确证据人工确认，最终效果仍为 1。此人工审计不是给工具增加了自动查询权限。
- `auto_poll_reconnect`：切断并恢复专用连接，原 Scheduler PID 没有替换，由它自动发现到期意图并完成。父进程只在确定 gate 处核对，未代替消费者执行主体。

提交类 probe 没有旧 claim 时，stale 检查保存为 null/不适用；只有真正发生新旧领取的三类窗口才统计旧资格拒绝。不会用预先写下的 `:stale_claim` 预期值冒充调用证据。

## 本轮修复与工程取舍

领取和续租从同步回调转为数量受限的异步数据库 helper。默认一次数据库窗口 1000ms，连续失败按 100→200→…→5000ms 退避，wake 不能抢跑。控制进程保留 status、停止、watchdog 与槽位记账。停止 helper 不撤销可能已经提交的 SQL，因此未知 claim 不创建执行，未知 renew 停止执行并保留 lease，后继按数据库事实接管。

异步化暴露了一个原本由同步顺序隐藏的竞争：executor 的迟到结果先返回，而一个 renewal 仍在途。Worker 现在等待这条有时限的 renewal 完成，保留它实际观察到的 lease loss；若业务结果已经确认成功，也不能被随后陈旧 heartbeat 改成业务失败。原真实 SIGSTOP/SIGCONT 回归重新通过。

Provider 帧扣账和带超时工具子进程中的数据库异常也需要保持基础设施归因。新增保护让它们返回可识别的数据库错误，保留原进行中资源/操作证据；不记录一次虚假的模型失败、不提交“工具确定失败”、不安排普通业务 retry。类型异常注入测试负责这项分类组合，专用代理测试另行负责实际断连。

S6 固定读取 Oban 2.24.2（`0704bf0018bfc915560998fbdfb899dd508f5aff`），校验 19 个文件，追踪 Producer→Basic fetch→Executor perform/ack→Lifeline rescue。Basic 的 attempted_at ack 保护确实存在；Unique、执行并发和目标幂等也必须分开。[研究记录](research/oban-scheduling-recovery.md) 与 [源码 manifest](research/oban-v2.24.2-manifest.json) 给出固定行号和相邻测试，未安装 Oban、未运行上游测试。选型结论见 [ADR 0013](adr/0013-queue-engine-selection-and-database-recovery.md)：本期保持一条教学调度权威，未来 adapter 须经过同一业务故障契约验证。

## 审计与原始证据

独立历史子进程 PID 为 **99598**，Scheduler 明确禁用且没有启动。它对 63 个原 State 同时进行 full/checkpoint 路径核对与 20 个执行入口计数；没有 checkpoint 的 Run 使用既有 full fallback，不能据此宣称它们都保存过 checkpoint。子进程退出被实际观察到，父进程随后再次检查投影、效果和录制完全不变，最终没有有效 lease。

| 文件 | 用途 |
| --- | --- |
| [P3 总报告](../artifacts/week14-p3/report.json) | 22 项判据、四个原始子报告、63 个 Run、真实 outcome 分类 |
| [父进程历史审计](../artifacts/week14-p3/history-audit.json) | 重建、业务投影/效果/录制前后核对及有效 claim 0 |
| [独立 BEAM 审计](../artifacts/week14-p3/fresh-history-audit.json) | 全部 Run 严格 State 对比、20 个效果入口零调用 |
| [独立进程日志](../artifacts/week14-p3/fresh-history.log)、[退出证据](../artifacts/week14-p3/fresh-history-cleanup.json) | 实际子 PID、日志和观察到的退出 |
| [正式 CLI 日志](../artifacts/week14-p3-run.log) | 各组件实际运行与审计进度 |
| [完整 check](../artifacts/week14-check.log) | 最终全量回归、fixtures 与真实事务 kill |

各组件目录额外保留 journals、timeline、OS 信号、pgwire 代理、模型录制和核对证据。独立复核结果保存在同目录的 independent-audit.json，范围和局限以该文件为准；它核对原始证据与数据库，不声称事后重新执行了故障注入。

## P3 的结论与后续范围

本阶段通过“多 Worker 竞争→旧 Worker 暂停复活→饱和负载→数据库断连恢复”的组合，验证了单 PostgreSQL 教学 Runtime 的提交权威、背压和可见未知结果。下一阶段可以在这些边界上推进隔离、MCP、DAG 与审批；不能因为 P3 通过就放宽原工具权限或把未核对的效果当作没有发生。

本次每个信号/数据库故障点各 2 轮，满足本周可复现阶段验收，未完成原计划后续 v0.1 每点至少 20 轮的建议发布门槛。没有验证数据库节点宕机、复制切换、跨区高可用、介质损坏、恶意 SQL、任意远端 exactly-once 或生产吞吐/公平 SLO。父进程被 OS 强杀仍需按已保存身份清理，没有独立外部 watchdog。

第 20 章作为已验证代码对应的初稿交付，尚待另一位读者实际执行、试读反馈和技术审校；远程 CI 未运行。操作流程见[运行手册第 12 节](recovery-runbook.md#12-数据库断连与恢复)，复现与练习见 [L13](../labs/L13-database-outages-p3.md)。
