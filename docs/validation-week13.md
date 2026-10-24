# 第 13 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。没有新增依赖；新增第 13、14 个迁移，开发库与测试库均已应用。

## 已交付行为

新增显式命名的 `QueueStore`，固定保存 capacity、max_inflight、aging_ms、starvation_ms 和扫描 cursor/ceiling。Run 保存 queue_name，准入事务先锁队列再检查未终结数量，随后原子写入 Run、Events、intent、Recovery 配置和任务预算。超过容量返回 `:queue_full`，整个创建回滚。直接向命名队列创建未登记 Recovery 的旧式 Run 会返回 `:queue_requires_recovery`，队列任务不能省略预算。

共享 max_inflight 限制同一队列的有效数据库 lease，多个 Scheduler 和显式领取都遵守它。锁顺序为 Queue → Run → Intent；既有转换、续租与释放只锁 Run，不反向请求队列锁。终态释放准入名额；blocked/manual 保留名额。显式人工核对仍会占用有效 lease，诊断计数与实际配额一致。未指定 queue 的旧调度入口只发现无队列 Run。

命名队列一次领取最多验证 scan_limit 个候选，默认 32、范围 1—256。持久 ID cursor 和固定 cycle ceiling 让 future retry、损坏历史或缺失预算的前缀可以被跳过；持续新增意图不会无限延长同一轮扫描。页内按 `min(9, priority + floor(intent_age_ms / aging_ms))` 排序，同分旧 intent 优先，提供轮转发现与老化。旧无队列路径保留前序完整扫描语义。

新增不可变 `TaskBudgetStore` 策略与持久预留。队列任务默认 max_dispatches 32、execution_timeout_ms 5000；原有未启用任务预算的无队列 Run 不增加持久 dispatch 计数。新的 claim token 在 hook、模型或工具执行前消费一次机会，同一 token 再次执行被拒，崩溃与独立 BEAM 不能重置计数。原模型次数、turn、stream 字节/事件、工具调用、Run 绝对 deadline 和 retry 限额继续有效。

所有后台 Worker 增加执行 watchdog，取 Scheduler 单次上限（默认 30000ms）、任务固定上限与 Run 剩余时间的较小值。回收先杀停并等待 executor，再在当前 claim 下处理原事实：无工具记录则 failed，确认回执复用，prepared/unknown 进入可见 blocked 核对。原 Run 总期限先到时保留 `:run_timeout` 归因。任务 deadline 同时约束模型启动、持久 request deadline、frame 扣账、模型结果接受和新工具效果，直接 `Recovery.step` 也不能在任务超时后启动模型。

`Scheduler.wake/1` 使用 Registry 中的原子 gate 合并通知，不为每次提示都新增一条待消费业务消息。实例退出后注册自动清理，周期轮询不依赖通知可靠性；任意外部直接发送原始消息不属于该接口的合并保证。

## 全量回归

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终 **562 passed：560 个测试和 2 个 doctest，0 失败**。第 12 周原有 535 项全部保留通过，新增 27 项。格式、warnings-as-errors 编译、14 个迁移、原 10/10 fixtures，以及 Run 创建/转换的 COMMIT 前后四个真实 kill 探针全部通过。

| 新测试组 | 数量 | 主要证据 |
| --- | ---: | --- |
| QueueStore | 15 | 并发准入、拒绝原子回滚、创建与领取 COMMIT 后 kill、显式领取配额、lease 到期接管、默认入口隔离、aging、只读饥饿检测、future/坏记录前缀分页与缺失预算 |
| TaskBudgetStore | 9 | 严格策略/版本/hash/progress、领取后预算被删除、重复 token、Worker kill 与新代次、独立 BEAM 预算耗尽、hook 回收、迟到模型/工具效果检查、直接 API 到期前检查、10000 次 wake 合并 |
| LoadDemo | 3 | 参数与目录保护、完整饱和/公平性/预算演练、进程实际退出与 manual 占位 |

其中 wake 测试在暂停 Scheduler 控制进程后，由 10 个并发调用者发出 10000 次提示，直接检查邮箱只出现一个 wake cast；恢复后计数为 10000。新 BEAM 预算测试先在父进程持久预留并释放两次，再由独立 VM 续跑：原 dispatch 上限仍为 2，未调用模型或工具，Run 明确 failed。

无数据库模式 **251 passed：249 个测试和 2 个 doctest，311 个数据库测试排除**。原内存状态机、Provider、工具、Streaming 和 OTP 行为保持通过。

证据：[最终 check](../artifacts/week13-check-final.log)、[无数据库测试](../artifacts/week13-memory-tests.log)。事务中真实 kill 引发 Postgrex 断连是故障注入预期。开发期首轮完整回归发现手动 step 的 owner/lease 参数转发兼容问题，已修复并通过原 P2/恢复探针；任务 deadline 归因与直接 API 启动边界也已补回归。最终日志与开发期失败日志分开保存。

## 正式饱和负载实验

```sh
./scripts/mix lab.load --output artifacts/week13-load-final --jobs 12
```

最终实验前缀为 `load-1792518749001816-7173`，结果 `all_passed:true`。所有队列与 Run 都由本轮新建，沿用原身份完成与核对；没有消费已有事故任务或删除前序证据。

| 饱和指标 | 本次观测 |
| --- | ---: |
| 并发投递 / 容量 | 24 / 12 |
| 接受 / 明确拒绝 | 12 / 12 |
| 拒绝 ID 遗留 Run | 0 |
| 两个 pool 的配置槽位总和 | 4 |
| 共享 max_inflight | 2 |
| 未终结 Run 峰值 | 12 |
| 有效 lease / Worker / executor / provider 峰值 | 各 2 |
| 相关任务进程峰值（含 owner watcher） | 8 |
| 发送 wake 提示 | 400，随后邮箱排空 |
| 完成后再次成功准入 | 2 |

Provider 停在实际观察到的 gate 时连续采样，再释放已观察的 provider 并等待任务完成；结果不是只在结束时数空池。timeline 保存采样值与时点，表中峰值是本次样本最大值。邮箱采样最大值为 0，表示采样点没有积压，不能解释成瞬时邮箱永远为零；暂停控制进程的专门测试另外验证通知合并。

## 公平性与饥饿证据

公平性队列 max_inflight 为 1，aging_ms 为 10，starvation_ms 为 40。先让 incumbent 占位，创建 priority 0 的低优先级候选，再持续加入 6 个 priority 9 候选，随后释放 incumbent。低优先级 intent 自然老化至 9，并以较旧 ID 在本页优先获得服务。

- 释放前检测到低优先级饥饿条目，且有效 lease 的 incumbent 不被误报。
- incumbent 后第 1 个获得服务的是低优先级 Run，其原始等待时间为 **159.906ms**。
- 8 个任务均继续处理，完成顺序最大间隔为 14ms；服务结束后饥饿列表清空。
- 原始等待通过 PostgreSQL 中首次 Context 创建时间减去原 intent 创建时间测量，另行保存完成延迟；没有把整个执行时长算作排队等待。

此处时间是观察到的输入开始时间代理，包含领取、Worker 启动与 Context 构造成本，不等于精确 claim COMMIT 时刻。饥饿接口只筛选观察时 ready 的候选，并使用当前 intent 年龄；没有累计连续 eligible 时长。刚到 retry due 的旧意图也可能立即超过阈值，必须结合 due 解释。分页老化没有全队列每次严格最高分或无限负载完成期限的保证。

## 预算与超时结果

| 场景 | 结果 |
| --- | --- |
| max_dispatches=1，首步模型请求工具 | 预留 1，接受模型结果 1，下一步因 dispatch 耗尽失败；工具效果 0 |
| 慢模型超过 150ms 执行窗口 | 原 provider 被实际监控并确认退出，录制结果 0，任务 failed/execution_timeout；后续任务成功 |
| unqueryable 工具效果后 gate 超时 | executor 被监控并确认退出，原效果 1，unknown → blocked/manual；后续任务成功 |
| manual 占位 | capacity 2 中 active 1、blocked 1、available_slots 1、live_leases 0；准入名额没有因退出执行器而错误归还 |

正式保留的核对 Run：`load-1792518749001816-7173-manual-timeout`。可用只读入口查看：

```sh
./scripts/mix lab.reconcile --run load-1792518749001816-7173-manual-timeout --json
```

它是预期实验结果，不能把“最终仍 blocked”算作执行器泄漏，也不能为排空队列换 operation 身份重发。核对已发生的原结果仍可在预算耗尽后操作；新效果继续受原权限、期限与结果配对协议约束。

## 文档与原始证据

新增 [L12](../labs/L12-backpressure-budgets-fairness.md)、[参考解答](../labs/solutions/L12.md)、[ADR 0012](adr/0012-backpressure-and-fairness.md)，更新 README 和[运行手册第 11 节](recovery-runbook.md#11-背压任务预算与饥饿告警)。L12 的独立队列准入示例已实际执行成功：容量 2 拒绝第 3 个 ID 且无记录，两个接受任务成功、各消费 1 次 dispatch、最终归还 2 个名额。清理只针对该示例自己的 ID 和队列。

| 文件 | 内容 |
| --- | --- |
| [report.json](../artifacts/week13-load-final/report.json)、[metrics.json](../artifacts/week13-load-final/metrics.json) | 同内容的完整结果、身份、阈值与测量 |
| [timeline.json](../artifacts/week13-load-final/timeline.json) | 饱和采样和阶段时点 |
| [journals.bin](../artifacts/week13-load-final/journals.bin) | Codec 编码的 inert State/Event、恢复/预算、操作/尝试/录制证据 |
| [运行日志](../artifacts/week13-load-final-run.log) | 最终正式命令输出 |
| [独立复核](../artifacts/week13-load-final/independent-audit.json) | 27 份归档逐一对应数据库、13 次采样峰值重算、拒绝 ID 与公平性时间复算 |
| [独立准入示例](../artifacts/week13-docs/admission-check.log) | L12 示例实际运行与精确清理 |

独立只读复核已确认全部 27 个归档与当前数据库事实相同，重算 13 个采样及 12 个拒绝 ID，最终有效租约为 0。进程退出由正式 runner 当时监控并等待 DOWN，归档保留成功断言；没有单独保存历史 PID 事件轨迹。独立复核验证持久后果与排空采样，不能事后重放这段进程退出历史。

## 解释范围

准入 capacity 限制尚未终结工作，终态历史与去重/回执保留量不受这个数字约束。共享 quota 限制有效 lease；已经失租但尚未退出的旧进程继续由 fencing 与各 pool 的本地槽位约束。采样的进程范围是两个实验 pool 派生的执行链，包含其 owner watcher，不是整个 BEAM 或整机进程上限。

本地 watchdog 依赖 BEAM 和数据库可响应，当前实现不承诺任意 SQL 长锁、OS 暂停或远端请求都能在毫秒期限内收尾。模糊效果必须保留 unknown 并核对；没有新增任意远端 exactly-once、生产吞吐/公平 SLO、OS 资源沙箱或多租户隔离保证。第 14 周的数据库断连、组件源码对照与 P3 汇总仍需独立验收。远程 CI 未运行。
