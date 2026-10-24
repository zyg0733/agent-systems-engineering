# S6：Oban 领取、回执与恢复源码对照

本记录完成原计划第 14 周的 S6 定向研究。研究日期为 2026-10-21；对象为开源 Oban **2.24.2**，固定提交 **`0704bf0018bfc915560998fbdfb899dd508f5aff`**。官方 [v2.24.2 发布页](https://github.com/oban-bg/oban/releases/tag/v2.24.2) 的提交与实际下载归档一致，因此无需改变原计划版本。当前实现位于 `lib/oban/queues/`；旧笔记中的 `queue/` 路径不适用于该版本。`Oban.Plugins.Lifeline` 已是兼容代理，实际实现为 `Oban.Lifeline`。

研究执行了下载、逐行阅读和 SHA-256 校验，**没有安装 Oban、没有运行其上游测试，也没有接入 Oban Engine**。上游测试链接是验证入口，不能算作本实验室的通过结果。本地实验、全量回归与 P3 证据另见 [第 14 周验收记录](../validation-week14.md) 与 [P3 报告](../p3-report.md)。

## 1. 追踪问题与可核对入口

| 问题 | 固定实现 | 相邻测试或规范 |
| --- | --- | --- |
| 生产者如何把空闲槽位变成已领取工作 | [Producer start_jobs / dispatch](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/producer.ex#L224-L269)、[Basic fetch_jobs](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L92-L134) | [Engine 集成、优先级与耗尽测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/engine_test.exs#L819-L941) |
| perform 完成后如何提交成功或重试 | [Executor call / perform](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/executor.ex#L69-L93)、[ack_event](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/executor.ex#L220-L262) | [Executor 返回值、错误与超时测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/queues/executor_test.exs#L35-L94) |
| 迟到旧执行能否覆盖新执行 | [Basic ack_query](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L543-L548) | [stale executions 测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/engine_test.exs#L741-L780) |
| 谁重新发现 orphan | [Lifeline leadership / rescue](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/lifeline.ex#L130-L184)、[Basic rescue_jobs](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L180-L199) | [Lifeline rescue 测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/lifeline_test.exs#L31-L72) |
| 断连重试的是数据库操作还是业务动作 | [Repo transaction](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/repo.ex#L179-L272)、[Backoff with_retry](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/backoff.ex#L82-L129) | [Repo retry exhaustion](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/repo_test.exs#L11-L59)、[Backoff DB/timeout 测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/backoff_test.exs#L38-L74) |
| unique 是否等于执行互斥 | [Basic insert_unique](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L427-L479) | [Unique vs Concurrency](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/guides/learning/unique_jobs.md#L81-L112)、[插入事务测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/engine_test.exs#L324-L339) |

## 2. 领取链：先提交执行事实，再启动进程

`Producer.start_jobs/1` 调用 `Engine.fetch_jobs/3`，成功后才通过 TaskSupervisor 创建 Executor，并把 task ref、PID 与原 job 放入本地 `running`。Producer 使用单个 dispatch timer 合并短间隔调度，收到任务结果或 DOWN 后移除本地引用，再安排下一次 dispatch。这个 running map 是当前实例的槽位记账，不能直接当成整个集群的并发计数。[Producer](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/producer.ex#L69-L125)

Basic 根据 `limit - map_size(running)` 计算 demand，只选当前队列的 available job；按 priority、scheduled_at、id 升序选取，用 `FOR UPDATE SKIP LOCKED` 跳过竞争锁。CTE 固定候选集合，避免 PostgreSQL 优化后的嵌套循环使更新行数超出 LIMIT。事务将候选改为 executing，写 attempted_at、attempted_by 并递增 attempt；达到 max_attempts 的 job 不会从该更新返回。[Basic fetch](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L92-L134)

本实验室的相应链是 `Scheduler` → `IntentStore.claim_next/2` → `Scheduler.Worker` → `Recovery.execute_claim/2`。SQL 候选还必须满足当前 Run/intent 一致、持久配置合法、retry 真正到期、任务预算有效与命名队列共享配额；领取 token/generation 的 COMMIT 得到确认后才能启动执行。命名队列用持久游标和固定扫描页保留发现机会；它不是 Oban Basic 的 SQL 排序实现。两者 priority 数值方向也不同：这里 9 优先，而 Oban Basic 的排序以较小数值优先。相邻本地证据见 [scheduler_test](../../test/agent_systems_lab/scheduler_test.exs)、[queue_store_test](../../test/agent_systems_lab/queue_store_test.exs)。

## 3. ack 与重试：必须分清 perform 和 report_finished

Executor 的 `call/1` 先启动超时计时器、调用 Worker.perform、标准化返回值、记录运行时间并取消计时器。只有随后构造的完成函数进入 `Backoff.with_retry`；该函数处理 report_finished/ack，而不是再次调用 perform。成功走 complete_job，业务失败走 error_job 与 Worker.backoff，snooze/cancel/discard 各走相应持久转换。[Executor call](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/executor.ex#L69-L93)、[ack 分流](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/executor.ex#L220-L262)

Basic 的成功、失败、snooze 等 ack 通过 `ack_query` 同时匹配 job ID、允许的 state 与 **原 attempted_at**。这是一项实际存在的旧 attempt 保护，不能写成“Oban Basic 没有 fencing”。上游 stale-execution 测试改变 attempted_at 并提交新完成态后，逐个尝试旧 complete/discard/error/snooze/cancel，确认新状态保持。该保护限定在被检查的 job 更新，不会自动约束用户在 Worker 内写入的任意业务表或远端服务。[ack_query](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L543-L548)、[测试](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/test/oban/engine_test.exs#L744-L768)

本实验室使用 intent ID、Run ID、seq、owner、随机 token、单调 generation，以及数据库中当前尚未过期的 deadline，共同授权操作。`IntentStore.verify/4` 进入 Run 行锁内；`Storage.dispatch/4`、模型账单和工具台账均继续校验。renew 写 SQL 再检查数据库时间，不能用旧内存 expiry 复活已经过期的资格。这里的显式 claim 证明与 Basic attempted_at 比较不是相同协议，也不应把教学代码推论为更优的通用队列。[本地实现](../../lib/agent_systems_lab/intent_store.ex)、[fencing_safety_test](../../test/agent_systems_lab/fencing_safety_test.exs)

本地 `RetryStore` 记录的是业务 model/tool/reconcile 尝试；数据库不可用不是一次 provider 失败。断连后不能因为未得到成功 ACK 就再次执行工具。`DurableTools` 保留 prepare、effect、receipt 与接受结果的边界：已确认 receipt 复用，结果模糊则按原 operation 身份进入核对。[DurableTools](../../lib/agent_systems_lab/durable_tools.ex)、[Recovery](../../lib/agent_systems_lab/recovery.ex)

## 4. Lifeline：时间窗口负责发现，不证明旧进程已经死亡

Lifeline 默认每分钟检查一次，由 leader 运行 rescue；Basic 将超过 rescue_after 的 executing job 重新变为 available，或者在 attempt 耗尽时 discarded。判据是 attempted_at 年龄，没有在该函数中逐个询问旧 Executor 是否仍然运行。上游模块明确提示这种时间恢复可能导致重复执行。[Lifeline 约束](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/lifeline.ex#L1-L40)、[rescue 条件](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L180-L199)

本实验室也不能从 lease 到期推导旧 Worker 已退出。第 12 周 SIGSTOP/SIGCONT 正是反例：新代次可以获得资格，旧 BEAM 恢复后仍必须被数据库拒绝。第 13 周 watchdog 则处理活着但超时的本地执行，先停 executor 并等 DOWN，再核对事实；数据库断连时无法安全确认新的持久事实，应保持可恢复状态并等待数据库恢复。发现机会、提交权限、目标效果去重是三个独立问题。[FencingDemo](../../lib/agent_systems_lab/fencing_demo.ex)、[Worker](../../lib/agent_systems_lab/scheduler/worker.ex)

## 5. 数据库恢复：连接重建不恢复业务确定性

Oban 2.24.2 存在两层不同 DB retry。`Oban.Repo.transaction/3` 对识别出的连接错误和 SQL 冲突进行有界重试，默认普通错误最多 5 次、预期冲突最多 20 次；嵌套外部事务时模块要求禁用内部重试，以免掩盖已经失败的事务。相比之下，Executor 完成回报使用的 `Backoff.with_retry` 默认为无限次重试，间隔指数增长并带 jitter，指数上限限制延迟。这是数据库 ack 的保留策略，不能理解成无限重新执行 perform。[Repo](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/repo.ex#L179-L272)、[Backoff](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/backoff.ex#L82-L129)

Producer 对 fetch 的结果使用成功模式匹配；有界 transaction retry 耗尽后，失败可使 Producer 退出并交由监督树处理。Lifeline 则以 `on_exhausted: :log` 执行事务，失败会带 error 元数据、空 rescued/discarded 列表并安排下一轮。这些路径没有统一成一个“Oban 断连后总会无损自动恢复”的泛化保证。[Producer fetch](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/queues/producer.ex#L257-L269)、[Lifeline error 路径](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/lifeline.ex#L130-L184)

Postgres Notifier 使用可自动重连的 SimpleConnection；每次连接后根据 listener registry 重建 LISTEN。通知与 listener 恢复负责唤醒，不能把丢失的通知当成业务事实消失或业务效果未发生。[Notifier](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/notifiers/postgres.ex#L48-L62)、[重新 LISTEN](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/notifiers/postgres.ex#L103-L125)

本项目安装版本由 mix.lock 固定为 Ecto SQL 3.14.0、Postgrex 0.22.4、DBConnection 2.10.2。SQL adapter 将事务交给 DBConnection；Postgrex 处理 COMMIT 协议；DBConnection 在断连时清理连接状态，并尝试重新连接或按配置结束连接进程。这些机制恢复通信能力，但不能告诉业务方“丢失 COMMIT ACK 的事务一定回滚”。本实验必须在重连后查询原 Run/seq/operation，不能仅凭 ConnectionError 决定重发。[SQL adapter](https://github.com/elixir-ecto/ecto_sql/blob/v3.14.0/lib/ecto/adapters/sql.ex#L1471-L1487)、[Postgrex handle_commit](https://github.com/elixir-ecto/postgrex/blob/v0.22.4/lib/postgrex/protocol.ex#L636-L662)、[DBConnection disconnect](https://github.com/elixir-ecto/db_connection/blob/v2.10.2/lib/db_connection/connection.ex#L143-L182)

第 14 周本地实现把数据库领取与续租放入单个有界异步 helper，避免同步数据库等待把 Scheduler/Worker 的控制邮箱一起阻塞；连续数据库故障进入可见退避。claim 的 COMMIT 回报丢失时不启动业务，数据库事实待原 lease 到期后重新发现；renew 回报不确定时停止本次 executor，不释放一份无法确认的资格，也不把本地 expiry 当成授权。原 retry、预算、工具身份与已提交事件继续有效。具体断连故障点与观察范围见 [L13](../../labs/L13-database-outages-p3.md)。

## 6. unique、并发上限和业务幂等需要分别选择

Basic unique 在插入事务中使用 advisory lock 与字段/时间窗查询来查找冲突；它并不决定已经存在的不同 job 如何并发执行。上游 guide 也把 unique 限定在插入阶段。业务操作仍需稳定身份、目标幂等或查询证据。[unique 实现](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/lib/oban/engines/basic.ex#L427-L479)、[guide](https://github.com/oban-bg/oban/blob/0704bf0018bfc915560998fbdfb899dd508f5aff/guides/learning/unique_jobs.md#L81-L112)

| 责任 | 当前实验室 | 将来使用 Oban 仍必须解决的映射 |
| --- | --- | --- |
| 已接收任务的原子事实 | Run/Event/intent/固定配置/队列准入同一事务 | Job 的插入与业务事实同一事务，禁止“先接收后补 job” |
| 当前步骤所有权 | 显式 intent claim、DB-clock lease、generation 与 seq | 明确由谁拥有 lease；job ack 不等于业务事件提交 |
| 并发和背压 | queue capacity、共享 live lease quota、每实例 Worker 槽位 | 不能用 unique 或单 Producer limit 冒充这些范围 |
| 预算和 retry | 原 Run 持久计数、业务分类、到期条件 | 不能把 job attempt 简单替代 model/tool/reconcile 预算 |
| 工具未知结果 | 稳定 operation ID、receipt、unknown/manual | 重投 Job 不能自动重新执行业务；核对入口保持独立 |
| 恢复与观测 | 纯历史重建、fence、原始故障报告 | 保留原事件/模型录制契约及事故核对证据 |

本期继续使用教学队列，选择理由和未来替换门槛记录在 [ADR 0013](../adr/0013-queue-engine-selection-and-database-recovery.md)。这是责任边界比较，不是性能排名，也不评价未阅读的 Pro Smart Engine、Pro Lifeline 或其他商业能力。

## 7. 下载、校验和复现

[源文件 manifest](oban-v2.24.2-manifest.json) 保存 release/tag/SHA、归档 SHA-256、19 个已读上游文件的内容散列与行数，以及本地安装依赖的版本和文件散列。[实际散列校验记录](../../artifacts/week14-source/verification.json) 保留此次逐文件核对结果，并明确 upstream_tests_run=false。上游归档只下载到临时目录，没有把整份依赖或源码复制进本仓库；Apache-2.0 许可证文件也在 manifest 中。正文只记录事实与短符号引用，不复制大段源码。

从项目根目录复核。以下命令仅下载固定 SHA 的归档并读取 manifest 指定的成员，不执行上游代码，不解包到工作目录：

```sh
curl -fL 'https://github.com/oban-bg/oban/archive/0704bf0018bfc915560998fbdfb899dd508f5aff.tar.gz' -o /tmp/agent-systems-oban-2.24.2.tar.gz
python3 - <<'PY'
import hashlib, json, pathlib, tarfile
m = json.loads(pathlib.Path('docs/research/oban-v2.24.2-manifest.json').read_text())
a = pathlib.Path('/tmp/agent-systems-oban-2.24.2.tar.gz')
archive_matches = hashlib.sha256(a.read_bytes()).hexdigest() == m['archive_sha256']
with tarfile.open(a, 'r:gz') as archive:
    for row in m['files']:
        member = archive.extractfile(m['archive_root'] + '/' + row['path'])
        assert member is not None
        assert hashlib.sha256(member.read()).hexdigest() == row['sha256'], row['path']
print({'files_verified': len(m['files']), 'archive_bytes_match': archive_matches,
       'upstream_tests_run': False})
PY
```

归档封装字节若因上游重新打包改变，需要记录新的归档散列并检查原因；逐个源文件散列仍必须匹配，不能只看到相同 tag 就忽略内容变化。此次下载校验的归档 SHA-256 为 `8efce6e2252ddd0ac71946abb09906e17e75dae63c266922ae076009c3f98ceb`。代码未放在 Git checkout 中，实验室自身版本以第 14 周报告的源码 manifest 和运行环境记录为准。
