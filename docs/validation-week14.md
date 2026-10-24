# 第 14 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。沿用 Ecto SQL/Postgrex/DBConnection 的 mix.lock 与原 14 个迁移，没有新增依赖、没有安装 Oban。

## 交付与修复

完成原计划 W14：真实数据库连接故障、S6 Oban 领取/恢复源码对照、队列选型 ADR、P3 汇总及第 20 章初稿。代码继续使用一条教学 Scheduler/Recovery 调用链。

- `DatabaseFaultDemo` / `mix lab.database`：子 BEAM 与专用 loopback pgwire 代理，真实断开所属连接、拒绝重连，恢复后使用新 backend；真实截断 COMMIT 成功回报，而不是在 after_commit hook 抛异常冒充协议断连。
- `Scheduler.DatabaseTask`、`DatabaseError`：领取、续租和清理由有期限且数量受限的进程执行，控制面保留状态与 timer；连续基础设施失败退避，wake 不抢跑，没有确认的领取不启动业务。
- Worker：未知 renew 先停 executor 并等待，保留 lease 直到数据库事实明确或到期；executor 与在途 renewal 竞争时不丢失实际失租证据，也不把已确认业务成功改成失败。
- Recovery：Provider 帧扣账、带超时工具和核对查询的数据库异常保留基础设施归因，不能记录一次虚假的业务失败/retry；已扣资源和 prepared 证据保留。
- `P3Verification` / `mix lab.p3`：实际重跑 W11—W14 四组件，保存阶段判据、原始子报告、失败位置和真实业务分类；一个独立 BEAM 重建全部本轮 Run，并检查 20 个执行入口零调用。
- SchedulingDemo：开始即保存拥有的 Run namespace/manifest，失败时保留可定位身份；独立应用子进程改为有执行期限和实际退出观察的 Port，保留清理证据。

数据库 helper 默认时限 1000ms，连续失败按 100ms 起、上限 5000ms 的指数退避。每个 Scheduler 至多一个领取 helper，每个 Worker 至多一个续租或清理 helper；这些数值与队列 capacity、共享 lease、Worker 槽位及业务预算分别约束各自范围。完整契约见 [ADR 0013](adr/0013-queue-engine-selection-and-database-recovery.md) 和[运行手册第 12 节](recovery-runbook.md#12-数据库断连与恢复)。

## 全量自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终 **582 passed（580 tests、2 doctests），0 失败**。W13 已有 562 项全部通过，本周新增 20 项；格式、无警告编译、14 个迁移、原 10/10 fixtures 和四个 COMMIT 前后真实 kill 探针全部通过。

| 新增测试组 | 数量 | 主要验证 |
| --- | ---: | --- |
| SchedulerDatabase | 7 | 连接与业务错误分类、严格时限/退避、受控 SQL 锁下状态可响应与超时、wake 不绕过退避、stop 等待领取 helper、阻塞 renew 不拖住 executor 回收、帧与工具回执数据库异常不伪造业务 retry |
| DatabaseFaultDemo | 5 | 参数/目录/全局隔离/未完成回调、五类真实连接窗口、故障回调异常后 heal/kill/实际退出与代理清理 |
| DatabaseProxy | 2 | loopback 连接实际断开/拒绝/恢复、分片 pgwire COMMIT 识别与后端成功回报截断 |
| P3Verification | 6 | 严格参数/目录/隔离、起始失败、部分阶段失败保留、四组件完整运行与独立 BEAM 审计 |

正式 check 用时 61.1 秒。无数据库模式 **262 passed（260 tests、2 doctests），320 个数据库测试排除**，原内存、Provider、工具、Streaming 与 OTP 实验继续通过。

证据：[完整 check](../artifacts/week14-check.log)、[无数据库测试](../artifacts/week14-memory-tests.log)。故障中 Postgrex 的连接断开和被杀 SQL owner 日志是预期注入结果。开发回归曾发现异步续租与 executor DOWN 的顺序变化遮住原 lease-loss 观测，已修复并重跑真实 SIGSTOP/SIGCONT；[最终相关回归](../artifacts/week14-core-fencing-final.log) 14 项通过。[数据库与业务 retry 组合回归](../artifacts/week14-database-retry.log) 25 项通过；类型异常注入与真实 socket 故障分别计证据。

## 正式 P3 运行

```sh
./scripts/mix lab.p3 --output artifacts/week14-p3 --repetitions 2
```

**4/4 组件、22/22 阶段判据通过**。信号 5 个窗口 ×2、数据库 5 个窗口 ×2；scheduling/load 各运行一次，12 个批任务。63 个 Run 逐个审计，结果为 **59 succeeded、2 expected_failed、2 expected_blocked**，总报告 all_passed=true，outcomes.all_runs_succeeded=false。

| 组件 | 实际结果 |
| --- | --- |
| scheduling | 16 个 Run；两个 pool 实际并行 4 个互异领取；真实 kill 后原 operation 效果 1、generation 1→2；retry due 和续租有效；保留 1 个 manual blocked |
| fencing | 10 个 probe，10 次 STOP/CONT，8 次同 seq 接管；实际旧执行返回被拒，旧覆盖 0、重复效果 0 |
| load | 27 个 Run；24 次投递接受 12、拒绝 12，拒绝 ID 遗留 0；共享 lease/Worker/executor/provider 峰值各 2、已测执行链峰值 8；低优先级等待 158.275ms、服务顺序与饥饿解除符合预期 |
| database | 10 个 probe、10 次独立 backend 重建；真实 COMMIT ACK 截断 2、同 Scheduler 自动重连 2、实际旧 claim 拒绝 6；效果后 unknown/manual 证据 2 份，确认后各效果仍 1 |
| fresh history | 独立 BEAM PID 99598 重建 63 个原 State；每份 20 个入口计数全部 0；父进程前后投影、工具与录制不变；最终有效 claim 0 |

这里 8 是 W13 分类的 Worker/executor/provider/watcher 实测峰值，不包含 W14 新增的数据库 helper，也不是整机或整个 BEAM 的进程上限。队列 capacity 只约束未终结工作，历史保留量另行管理。

数据库事务窗口没有旧 claim 时保存 stale 结果 null/不适用；只在实际接管的 heartbeat/tool/auto 三类窗口中统计旧请求。COMMIT 丢失是代理实际看见后端 CommandComplete 后截断；服务器提交事实、唯一录制与 resume 无新增事实另由直接父连接验证。工具窗口保留未知证据后再人工确认，不能把最终成功掩盖中间必须核对的状态。

总报告：[report.json](../artifacts/week14-p3/report.json)。逐组件、逐窗口证据及解释见 [P3 阶段报告](p3-report.md)。命令输出为 [week14-p3-run.log](../artifacts/week14-p3-run.log)。

## 独立复核

原正式进程结束后，另一个 BEAM 只读访问当前开发库，独立重建全部 63 个 Run，并将投影、历史、模型录制和工具台账哈希与原始证据逐项比较：全部一致，实际分类 59/2/2，有效 lease 0。

复核逐个检查 10 个数据库 probe 的 backend 改变、2 次协议 ACK 丢失、2 次同 Scheduler PID 自动恢复、2 份 unknown-before-manual 和 6 次实际陈旧资格返回；10 个实验子 BEAM 进程 PID 均已不存在，代理 listener 拒绝连接、socket 数为 0，cleanup 正常退出。还核对 10 个 fencing 的 takenover 与 after-old 严格相等及退出证据。

独立复核：[independent-audit.json](../artifacts/week14-p3/independent-audit.json)。它独立重建当前数据库并复核原追踪，不声称事后重新执行 SIGSTOP 或 pgwire 故障；原 63×20 的入口零调用是原始独立历史子进程的实际计数。完整局限已写入该 JSON。

## 源码与文档

S6 固定 **Oban 2.24.2 / 0704bf0018bfc915560998fbdfb899dd508f5aff**。核对 19 个上游文件，归档 SHA-256 为 `8efce6e2252ddd0ac71946abb09906e17e75dae63c266922ae076009c3f98ceb`；保存文件级 manifest、固定行号和相邻测试链接。研究追踪 Basic fetch/ack/rescue、Producer、Executor、Lifeline、Repo/Backoff 和 unique：Basic attempted_at 的旧 attempt 保护不能省略，ack 的重试与重新 perform、Unique 与执行互斥分别对照。

没有安装或运行 Oban 上游测试；下载与校验不算功能/性能验收。选型结论是保留教学引擎，未来 adapter 先定义原子映射、单一调度权威、业务 fencing 与原 retry/预算语义，再通过同一故障契约。

- [源码研究](research/oban-scheduling-recovery.md)、[manifest](research/oban-v2.24.2-manifest.json)、[实际源文件校验](../artifacts/week14-source/verification.json)。
- [L13 实验](../labs/L13-database-outages-p3.md)、[参考解答](../labs/solutions/L13.md)、[ADR 0013](adr/0013-queue-engine-selection-and-database-recovery.md)。
- [P3 报告](p3-report.md)、[恢复运行手册第 12 节](recovery-runbook.md#12-数据库断连与恢复)、[第 20 章初稿](../book/ch20-scheduling-and-recovery.md)。

第 20 章包含故障开篇、机制、权衡、源码、实验和 5 道习题/教师答案。它仍是初稿，尚待独立读者执行与技术审校；没有 Git 发布版本或出版完成声明。

## 当前边界

本次验证可恢复的、实验拥有的客户端连接故障；共享 PostgreSQL 未停止，没有验证节点宕机、复制切换、介质故障、跨区高可用、任意 SQL/代理兼容或任意远端 exactly-once。数据库调用的本地期限不是任意 OS 暂停或不可中断执行下的实时上界。

正式每个信号/数据库故障点各 2 次，未完成后续 v0.1 每点至少 20 次的建议发布门槛。没有运行远程 CI。父进程被 OS 强杀时没有独立外部 watchdog；异常清理的已测范围与现场身份核验要求见运行手册。
