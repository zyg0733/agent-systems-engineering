# 第 10 周验收记录

验证日期：2026-10-21，Asia/Shanghai。沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6；没有新增 Hex 依赖或数据库迁移，原 11 个迁移保持兼容。

实际数据库启用 `fsync=on`、`synchronous_commit=on` 和 `full_page_writes=on`，见[环境记录](../artifacts/week10-p2/environment.log)。这些设置不把当前进程 kill 演练扩展成断电或介质故障验证。

## 完成结果

完成 P2：新增可重复的 `P2Verification` 与 `mix lab.p2`，16 个窗口默认各重复 20 轮。系统验证领取、模型接受、工具准备/效果/回执/Run COMMIT、恢复者再次崩溃、retry 预留/调度和查询/人工核对等边界。故障发生在明确观察到的 gate，真实 kill caller，等待数据库 lease 或 due 自然到期，不修改历史或时间资格。

修复两个由新增故障测试复现的恢复缺陷：人工回执已确认却被不可查询分支挡住，以及最后一次查询的回执已确认却因查询额度耗尽而无法接受。`Recovery.reconcile` 先在当前 claim 下验证并读取本地已确认回执，再决定是否需要查询。没有增加新的执行权限，也没有改变原有未知结果、重试或人工证据规则。详见[P2 故障报告](p2-fault-report.md)。

## 全量回归

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终完整结果：**473 passed，含 471 个测试与 2 个 doctest，0 失败**。原第 9 周 451 项全部保留通过，新增 22 项。格式检查、无警告编译、测试库迁移、原 10/10 fixtures，以及创建/更新各 COMMIT 前后四个真实 kill 探针全部通过。

| 新增组别 | 数量 | 验证 |
| --- | ---: | --- |
| P2Verification | 4 | 参数边界、拒绝覆盖、16 窗口单轮真实 kill/新 BEAM/CP、进度消费者出错保留失败报告 |
| P2Safety | 18 | 已确认回执后再次崩溃、最后查询额度、实际过期旧 worker、受控文件独立修改、取消、有限核对、schema 与审计损坏 |

无数据库模式：**243 passed，230 个数据库测试按标签排除**。新增三个参数/目录/失败报告保护检查无需 PostgreSQL；全部原内存实验继续通过。

日志：[完整 check](../artifacts/week10-p2/check.log)、[无数据库测试](../artifacts/week10-p2/memory-tests.log)。真实 caller 在数据库事务中被 kill 导致的 Postgrex 断连信息符合故障注入预期，最终测试无失败。

## 正式 P2 演练

```sh
./scripts/mix lab.p2 --output artifacts/week10-p2 --repetitions 20
```

冻结后正式结果：**320/320 probe 通过、340 次真实 caller kill**；目标业务效果重复、已确认本地回执丢失、陈旧 token 覆盖与固定脚本超预期模型尝试均为 **0**。每个 Run 只有一个逻辑工具 operation，最终效果为 1、cursor 为 2、已接受模型录制为 2。已存在原目标账本行与已确认 receipt 严格保持一致。

两个 probe 使用新 BEAM 续跑同一 Run，再在新 BEAM 对 full/真实 seq 2 checkpoint + tail/原 State 做严格比较，18 个效果入口计数均为 0。完整报告含逐次的初始、每次 KILL 后、接管前与接管后审计，case 及重复轮次能回溯到原数据库 Run。

证据：[report.json](../artifacts/week10-p2/report.json)、[运行日志](../artifacts/week10-p2/run.log)。具体故障表、根因和口径见[P2 故障报告](p2-fault-report.md)。首轮在补强原目标回执导出前已经通过，另保留 `artifacts/week10-p2-preliminary/`；正式结果只统计冻结后的一轮。

正式矩阵均为可确认的受控 Mock 场景，完成后没有遗留核对项；不能用这个结果要求真实 unknown 自动成功。额外 18 项保护测试验证文件 unknown、核对额度耗尽、manual 可见暂停和禁止重发。第 9 周专门保留的非幂等核对项未被修改或删除，本周再次只读确认仍为 blocked/seq 3/manual/unknown，见[保留条目快照](../artifacts/week10-p2/preserved-manual-queue.json)。

## 文档与运行手册

新增 [L09 实验](../labs/L09-p2-fault-acceptance.md)、[解答](../labs/solutions/L09.md)、[ADR 0009](adr/0009-p2-fault-acceptance.md)、[P2 故障报告](p2-fault-report.md) 和[恢复运行手册](recovery-runbook.md)，README 已登记命令及阅读入口。

运行手册的 **5 个 Elixir 代码块**从 Markdown 原样提取，在独立 BEAM 与测试 PostgreSQL 执行，替换原 Run ID 占位符。两个专用 Run 验证只读采证、同 ID 续跑、固定审阅 seq/operation 的人工 helper 和错误分支：`review_required`、`invalid_reconciliation_evidence`、`intent_claimed`、`not_in_reconciliation_queue`、`not_blocked`、`step_limit`。人工确认后原效果仍为 1，专用文档验证 Run 已清理。

证据：[手册执行日志](../artifacts/week10-p2/runbook-check.log)。交互示例绑定变量供操作员检查，提取为一次性脚本时产生未使用变量提示，不属于项目严格编译警告。实验目录的二进制均保持安全 Codec 限制。

## 当前边界

P2 冻结当前已声明的进程恢复契约，没有新增生产 scheduler、后台扫描或自动定时重试。200 ms lease 用于可重复本机实验；报告分开记录 lease 等待与继续执行时间，不给出生产 SLO。没有验证主机断电、数据库进程故障、真实远端工具或供应商计费；文件内容不能代替权威回执。远程 CI 未运行，本地完整检查与实际故障演练已通过。
