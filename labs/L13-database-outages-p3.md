# L13：数据库断连、恢复与 P3 验收

对应第 14 周；前置 L01—L12，建议用时 12—16 小时。原计划在这一周集中完成数据库故障、S6 组件源码对照和 P3 汇总，本实验沿用仓库连续编号。先读 [数据库恢复 ADR](../docs/adr/0013-queue-engine-selection-and-database-recovery.md)、[Oban 源码研究](../docs/research/oban-scheduling-recovery.md)、[恢复运行手册第 12 节](../docs/recovery-runbook.md#12-数据库断连与恢复) 与 [P3 报告](../docs/p3-report.md)。

实验结束时，应能用原始数据库事实解释：哪次事务回滚、哪次提交回报丢失、旧 Worker 为什么停下、哪项效果仍需核对。恢复后任务完成只是结果之一；没有多出效果、没有丢失已确认事实、没有旧代次写入同样需要检查。

## 1. 学习目标与不变量

- 区分事务未提交、事务已提交但客户端没有收到 ACK、连接重建与业务恢复。
- 在数据库不可用时保持调度控制面可响应，并让领取、续租和并发数量受控。
- 对原 Run/seq/operation 重新核对，不用新的业务身份掩盖不确定结果。
- 对照成熟队列的 fetch/rescue/ack，分别说明发现、所有权、预算与目标幂等的责任。
- 将 W11—W14 的并发、fencing、背压和数据库故障放入同一份 P3 验收。

必须保持以下条件：已确认的事件不因重连而消失；未得到数据库授权时不启动新业务；旧 claim 不得覆盖新代次；数据库错误不冒充模型失败、工具确定失败或任务成功；未知效果保留原身份并进入可见核对。

## 2. 准备与运行范围

在项目根目录的同一终端执行；另开终端时先选择实例、清除 `DATABASE_URL` 并重新执行下面两条 `export`。显式启用数据库、关闭应用级 Scheduler，避免继承内存实验或其他实验留下的配置：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/postgres start
./scripts/mix setup
./scripts/mix lab.database
./scripts/mix lab.p3
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

`lab.database` 默认输出 `artifacts/week14-database`，`lab.p3` 默认输出 `artifacts/week14-p3`，重复次数默认 2、范围 1—10。数据库 runner 对五个窗口各重复 N 次；P3 的 N 作用于信号暂停与数据库窗口，scheduling/load 组件各运行一次、每次 12 个任务。输出目录不得覆盖；再次运行使用新目录：

```sh
./scripts/mix lab.database --output artifacts/week14-database-repeat --repetitions 2
./scripts/mix lab.p3 --output artifacts/week14-p3-repeat --repetitions 2
```

这些 runner 只创建自己的实验 Run/命名队列和连接故障，不接管已有事故工作。不执行停止共享 PostgreSQL、终止全库连接或修改其他 Run 的命令。实际实现和报告定义了被切断的连接范围；不能把单连接或专用 pgwire 代理的故障结果写成数据库节点宕机或多数据库高可用证明。

数据库目录的 `report.json` 保留 expected_probe_count、fault_probe_count、failed_probe 与逐项 fault_probes。每次窗口保存 initial、before-fault、disconnected、before-heal、after、proxy、process、cleanup、summary 及 child.log 等证据；工具窗口另有 unknown 记录。P3 目录保留各组件子报告和 `history-audit.json`。失败必须给出非成功结果，不能把捕获异常、预期 blocked 或输出文件存在直接算作通过。实际文件、样本与最终测试数见 [第 14 周验收记录](../docs/validation-week14.md)。

## 3. 五个断连窗口

| case | 注入与需要区分的事实 | 恢复后的判据 |
| --- | --- | --- |
| `before_commit_rollback` | 在事务提交前切断实际连接，让本次事务无法提交 | 本次新写事实未泄漏；原已确认事实仍在；重连后可按原协议继续 |
| `commit_ack_lost` | pgwire 故障点让 PostgreSQL 收到 COMMIT，而客户端没有收到其成功回报 | 客户端不能虚报成功或假定回滚；数据库中已经提交的原事实可被重新查明 |
| `heartbeat_disconnect` | 活动 Worker 的续租失去确认，数据库恢复后重新发现到期工作 | 控制进程可响应；本次执行停止；后继拥有新代次，旧结果不能覆盖 |
| `auto_poll_reconnect` | 保持同一个 Scheduler 存活，切断其专用连接后再恢复 | 原 PID 自动发现到期意图并完成；不重启消费者，不借助父进程执行业务 |
| `tool_effect_pending_disconnect` | 原工具效果已经发生，在结果持久确认的窗口切断连接 | 不盲目重发效果；使用已确认 receipt 或原 operation 的查询/人工证据继续 |

对每次重复保留 run_id、原 seq、claim generation、故障触发点、调用返回、重连后的数据库状态、真实效果数和旧提交结果。把“触发了预定断连”与“恢复后的不变量通过”分别记录；未命中 gate 的测试不能假称覆盖该窗口。

### 提交前断连

先保存事务之前的事实，再在提交前切断连接。本 runner 通过 `Recovery.step/2` 驱动已登记 Run，在底层 `Storage.dispatch/4` 的 commit_hook 处暂停后断连。重连后对比原投影、事件连续性和当前 intent，确认本次转换回滚、前序确认事实保留；提交前已经独立扣除的模型尝试和输出预算也保留，不能只看事务函数返回 error。创建事务的“无部分 Event/配置/intent”继续由前序准入与事务测试覆盖；不要把本次 dispatch 窗口写成 create_run COMMIT 测试。对应原则来自第 3 周事务协议，故障注入现在使用真实连接错误。父进程在事务 gate 处用只读 MVCC 原始行快照观察已提交事实，避免正常 Storage.load 的共享 Run 锁与未提交写事务相互等待。

### COMMIT 回报丢失

在数据库提交和客户端确认之间设置故障点。这是“结果未知”，不是“回滚”。runner 的 pgwire 代理等到真实后端发回 COMMIT 的 CommandComplete，随后在成功回报送达客户端前断开连接；父进程通过独立连接确认原 Run 的终态与 seq+1。必须同时保留代理记录和服务器事实，不能用 after_commit hook 里抛异常替代协议回报丢失。

这次业务结果提交实验说明，重连后的事实判定优先于原调用的错误日志。推广到领取事务时，Scheduler 也不能因未收到 claim 就启动 executor，已提交 lease 占位，到期后由新的已确认 claim 接管；该控制策略另由相应组件测试验证。不得创建第二个 Run、重复追加同一 seq 或生成新 operation ID 来“保险重试”。本实验不承诺任意 SQL 或任意外部事务的自动无歧义重试。

### heartbeat 失去确认

renew 与控制邮箱分开。一个在途数据库 helper 有自己的时限；Worker 不能因同步数据库等待而无限推迟 watchdog。renew 出错或结果未知时先停止本次 executor 并等待退出，不用旧内存 expiry 继续授权，也不提前释放一份自己无法确认的资格。数据库恢复后，持久 lease 到期才允许新代次接管。

`Scheduler.status/1` 中的 database 诊断保留 state、consecutive_failures、retry_in_ms、last_error，pending_claim 显示在途领取。默认 `database_timeout_ms: 1000`、`database_backoff_ms: 100`、`max_database_backoff_ms: 5000`。等待与退避是运行控制；它不覆盖业务预算、retry due、队列配额或 fenced 提交。status 需要结合原始时序判断，不把单次 healthy 读数当作所有连接都健康。

### 同一 Scheduler 自动重连

`auto_poll_reconnect` 保存断连前后的实际 Scheduler PID。故障期间可以查询它的 database 状态、pending_claim 和退避；恢复代理后由这个原实例自动重新领取并完成工作。后继保持原 intent/seq，token/generation 更新，旧 claim 的真实 renew 被拒。父进程在 gate 处审计，不代替该实例执行业务。

### 效果后断连

工具效果不能随结果事务回滚。runner 采用不可查询的 durable Mock，在效果 COMMIT 后、receipt 之前切断连接；父进程独立确认真实 effects=1 与 prepared 台账，恢复同一 operation 后观察 blocked/manual 与 unknown.json，再使用明确审计证据人工确认，最终成功且 effects 仍为 1。不能把父进程在实验中的目标台账审计当成该工具对 Worker 自动开放的查询能力。

其他路径若读到已确认 receipt，就复用它；没有 receipt 时按该工具的能力查询原 operation，无法确定则保持 blocked/manual。manual 仍占 queue capacity，是未完成事实的可见性，不能为降低队列深度而删除。

停止旧 executor 只回收本地进程，不撤销已经发送或执行的远端效果。本实验的 Mock 台账和受控文件给出可验证证据，不推导任何任意远端系统的 exactly-once。

## 4. 观察控制面与资源

数据库请求失败期间采样 Scheduler status 的延迟、pending_claim、active Worker、进程数量及 database backoff。每个 Scheduler 最多一个领取 helper；每个 Worker 最多一个续租或清理 helper，策略读取在本次 executor 内完成。反复 wake 仍应合并成提示；不能在每个 wake、超时或 reconnect 上新增一批未结束的 helper/executor。活动槽位要等本次执行进程真正退出后才归还。这些额外 helper 应加入 W13 的 Worker/executor/provider/watcher 范围说明，不能沿用旧样本数字冒充所有新进程的全局上限。

恢复时间从数据库与目标 Worker 都已可用开始计时，并单列剩余 lease、扫描等待、排队与核对；人工处理不计入自动恢复延迟。记录配置及实测结果，不用一次开发机的 wall-clock 数值宣称生产上界。操作系统暂停、数据库长事务锁和底层驱动超时仍会影响观测。

## 5. S6：把组件源码变成契约比较

阅读固定 Oban 2.24.2 的 `Producer.start_jobs` → `Basic.fetch_jobs` → `Executor.call/report_finished` → `Basic.ack_query`；再读 `Lifeline` → `Basic.rescue_jobs`。每条调用链回答四项：谁拥有状态、提交在哪里、失败后谁继续、哪条相邻测试验证。

尤其检查三个反例：

1. unique job 不等于单个 job 串行执行；插入去重、执行并发和目标幂等分别是谁负责。
2. Basic ack 的 attempted_at 比较确实保护旧 attempt，不能声称它完全没有 fence；它与本项目 token/generation/DB-expiry proof 的差异是什么。
3. Executor 的数据库 ack 重试不重新执行 perform；Lifeline 的时间救援仍可能与活着的旧执行重叠，为什么两条结论可以同时成立。

提交阅读笔记时标明固定 SHA、实际文件/符号、相邻测试和是否运行上游测试。使用 [manifest 和复核命令](../docs/research/oban-scheduling-recovery.md#7-下载校验和复现) 核对源文件，不只保留 main 链接。当前任务只运行本实验室测试；上游测试保持“未运行”。

## 6. P3 门槛与交付

P3 汇总 W11 多 Worker、W12 租约/fencing、W13 背压/预算/公平性、W14 数据库故障。`lab.p3` 调用 `P3Verification.run/1`，实际执行 `scheduling`、`fencing`、`load`、`database` 四个组件并审计它们的原始结果，不能把旧报告的 success 字段当作新一轮实验。全局 Scheduler 若已启用或注册则拒绝执行，避免超出演示范围。

`report.json` 给出逐组件 acceptance_criteria、嵌入的原始报告、失败组件与真实计数；`history-audit.json` 保存父进程重建及事实前后对照，`fresh-history-audit.json` 记录独立 BEAM 的历史重建和当前 27 个执行入口的零调用审计，两者共同核对持久投影、效果和模型录制保持不变，以及最终没有有效 claim。历史报告的 20 个入口属于当时冻结版本，不作为当前计数。`all_passed` 可以为 true，同时 `outcomes.all_runs_succeeded` 为 false：预算实验的预期 failed 和 manual 实验的预期 blocked 是明确列出的正确结果，不能被改写成 succeeded。预期结果也必须通过相应不变量审计才算通过。

| 维度 | 需要保留的 P3 证据 |
| --- | --- |
| 领取和恢复 | 并发领取互斥、到期后接管、重复投递安全、原 retry due 持续有效 |
| 旧执行复活 | 真实 SIGSTOP/SIGCONT、接管代次、旧提交被拒绝且新结果保持 |
| 饱和与预算 | 准入拒绝无残留、共享 quota 和实例槽位不越界、dispatch 预算不重置 |
| 公平性 | 低优先级服务顺序、等待测量、饥饿可见且排除 future/live/manual |
| 数据库故障 | 五个窗口逐次命中、恢复后的持久事实、无重复效果与伪造完成 |
| 可重建性 | 新进程按历史得到相同业务状态，不调用模型或工具 |

同时交付新测试、[源码研究](../docs/research/oban-scheduling-recovery.md)、[队列选型 ADR](../docs/adr/0013-queue-engine-selection-and-database-recovery.md)、[P3 报告](../docs/p3-report.md)、[运行手册](../docs/recovery-runbook.md)、[第 20 章初稿](../book/ch20-scheduling-and-recovery.md) 与 [参考解答](solutions/L13.md)。

默认重复 2 次适合开发反馈，报告必须保留真实次数。原计划每个故障点至少 20 次是后续 v0.1 发布建议门槛；本周 P3 验收与该门槛分开表述，不因存在一个可配置参数就声称已经完成 20 次。所有既有测试继续通过；新进程历史验证、真实协议故障和普通单元测试也分别计数。
