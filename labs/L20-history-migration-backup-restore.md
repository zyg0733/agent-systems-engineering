# L20：旧历史迁移、版本兼容与备份还原

对应第 21 周；前置 L01—L19，建议用时 12—16 小时。先读 [ADR 0020](../docs/adr/0020-history-migration-backup-restore.md)、[运行手册第 19 节](../docs/recovery-runbook.md#19-历史迁移版本兼容与备份还原) 和 [本周验收记录](../docs/validation-week21.md)。

实验目标是证明旧事实能被新进程正确解释，布局迁移前后状态一致，真实 PostgreSQL archive 能在另一新数据库还原，以及复制的旧 claim 无法成为新目标的执行许可。版本、原始字节、业务语义和接管授权分别核对；不要仅检查“还原命令退出 0”。

## 1. 准备与完整演练

使用现有本机 PostgreSQL 和项目固定运行时；关闭全局 Scheduler，不需要模型凭据。演练会创建随机、带 capability 和 owner marker 的新数据库，并在结束时精确清理自己拥有的目标；它不覆盖 dev/test 库，不停止共享 PostgreSQL，也不使用 force drop。

```sh
./scripts/postgres status
./scripts/mix ecto.migrate
./scripts/mix lab.upgrade --output artifacts/L20-history-upgrade
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

输出目录必须全新，重复演练请换目录。先观察 `report.json` 中兼容、迁移、只读核验、旧 claim 拒绝和安全续跑的各项结论，再核对 `database-cleanup.json`。数据库对象和工作区是分开的：本实验保留原授权工作区及文件，数据库清理不表示工作区文件也已归档或删除。报告不应包含凭据或 claim token；私有旧 claim fixture 仅用于本机故障验证，不能当公共观测附件。

## 2. 将版本域拆开

| 版本域 | 支持值 | 含义 |
| --- | --- | --- |
| Kernel/Event schema | 1 | 事件字段及状态转移语义 |
| Codec | 1 | 惰性、受限的持久化 payload 编解码 |
| History format | 1、2 | Event 的存储字节布局 |
| Workflow/审批等 sidecar schema | 1 | 原 sidecar 事实及绑定 |
| SQL migrations | 显式迁移列表 | 表、列、约束和 journal 的结构 |

`history_format=2` 不表示模型协议、Event schema 或 Codec 也变成 2。v2 envelope 保存固定 tag、布局版本、原始 Codec 字节与其 digest；解包后必须得到原字节和原事件。

追踪 `History.Encoding`、`HistoryMigration` 与 Storage 的读取顺序，回答：格式未知时在哪里失败，Run 和 Event 布局不一致如何拒绝，为什么 journal 要绑定迁移前缀而不绑定未来所有 Event。手工伪造一个“看起来能 decode”的 payload 不能越过 metadata、seq、Event type、schema、checkpoint 和投影一致性检查。

## 3. 生成真正旧库

打开 `fixtures/history_v1/manifest.json`，核对四份冻结模块的来源和 SHA-256。它们对应第 20 周验收快照中的 Run/Event schema、Storage 和 ModelResultStore；其余业务代码仍使用当前版本。

固定子 BEAM 先只应用前 20 个 DDL，再加载旧模块并生成历史；此时 `lab_runs`/`lab_events` 没有 `history_format` 列，也没有新 journal。主 BEAM 不替换模块。不要用新 schema 先写 v2 再把版本列改成 1，或修改冻结文件来制造“旧数据”。

旧夹具保留成功文件写入、pending 工具、non-idempotent unknown、预算耗尽、活跃旧 claim 和有返工历史的审批 Case。查看 `legacy-logical.json`、`scope.json` 和 `fixture-ids.json`，先建立需要保留的事实清单：Run 状态/seq、事件、录制结果、回执、权限、预算、deadline、Workflow/Case 与产物 subject。

## 4. 迁移布局而保留事实

SQL migration 只补结构，旧 Event 默认仍为 layout 1。宿主显式调用：

```elixir
{:ok, plan} = AgentSystemsLab.HistoryMigration.plan(run_id)
{:ok, result} = AgentSystemsLab.HistoryMigration.migrate(run_id, plan.expected_seq)
```

`plan/1` 不写行，也不执行 Provider/Tool。`migrate/3` 锁定 Run，要求 expected seq 和无活跃执行 claim；事务中封装 Event 原字节、更新 Run 格式并插入 journal，重建并比较迁移前后 snapshot。它不重录模型、不补发工具、不消费预算、不改权限和绝对 deadline。

同一个 Run 再次迁移应返回 `already_current`。活跃 claim 被拒绝是正确结果，不能为了让演示全绿而删除 token；复制到还原目标之后，只能通过显式 fencing 接管。4096 Event 或 32 MiB 上限用于本实验的有界迁移，超限应分开设计迁移方案，不能静默截断。

分别在提交前和提交后中断迁移，读取另一个新进程中的结果：提交前必须整笔回滚，提交后必须保持完整 journal 与 v2 历史。重试不重新执行模型/工具；检查 dispatch、工具 effect、预算计数和 checkpoint rebuild 仍对应原事实。

## 5. 用完整 proof 核验静止源

`ReadonlyProof.capture(scope)` 要求 scope 覆盖该实验数据库的全部 Run/Workflow/Case。它通过原 public readers 验证历史、全重建/checkpoint、录制、Context、工具配对、Session、预算、重试及审批，前后核对全列行、schema、约束和序列位置指纹。

对比三类证据：

- 原始数据库 hash：还原前后全列字节及序列等应相同。
- Run 重建 hash：从 Event/Checkpoint 独立重建得到相同状态。
- 受保护事实 hash：只排除接管必须改变的 claim 字段，权限、预算、回执、deadline 和业务状态仍相同。

hash 用于身份和损坏检查，不是签名，也不批准执行。源必须静止；检测期间变化应拒绝，不把两个时刻的混合事实当作一致快照。

## 6. 真实 dump 与只读还原

`Backup.dump(handle, absolute_new_directory)` 调用固定 `pg_dump` 生成 custom archive，保存工具/服务器版本、SQL migration 列表、大小与 SHA-256。Bundle 是当前主 BEAM 的可信内存 capability；磁盘 archive 不是可任意导入的执行授权。目录 0700、archive/manifest 0600；拒绝覆盖、符号链接、坏 hash 或工具版本改变。

`Backup.restore(bundle)` 只新建一个随机受管目标，执行单事务 `pg_restore`，不允许原数据库名目标、`--clean`、`--create` 或调用者提供 SQL。还原后普通新连接的默认事务只读，Scheduler 仍关闭。

还原目标的 `capture_connection/2` 只使用原生只读 SQL 解码重建，不调用含 `FOR SHARE` 的业务读取接口；PostgreSQL READ ONLY 事务会拒绝该锁。对比 verified source 与 readonly copy 时，全部原始事实、兼容矩阵和重建语义都应一致；不能先解除只读并续跑，再用已经变化的数据库证明“还原相同”。

数据库默认只读是宿主流程 gate。数据库 owner/superuser 可以主动改会话设置，因此它不是防恶意用户的安全边界。本实验也不允许把不可信 dump 交给可信工具执行：archive 可能包含任意源端 SQL，校验 hash 不会使其变安全。

## 7. 显式 fencing 后续跑

`History.RestoreGuard.activate(handle, scope, source_proof)` 核对该目标确实由对应源 archive 还原，事务内再次比对完整 proof，再撤销所有 pending intent 的 claim token/owner/expiry 并递增 generation。原业务状态、已消费预算和绝对 timeout 不变；成功后才解除默认只读 gate。相同 handle 的激活被串行化，已激活目标拒绝重复激活。

拿原源库保存的 claim 对新目标提交必须被拒绝。随后显式 `Recovery.resume/1`，验证：已完成文件不再写一次；pending 幂等工具恰好一个效果；unknown 非幂等工具仍 blocked 且留人工核对队列；预算耗尽仍 failed；旧活跃任务由新 claim 续跑；审批仍校验原产物与 subject hash。

旧 DDL 的 archive 要先还原到第三个 staging 数据库，保持全库默认只读，仅固定子 BEAM 的专用 Repo 会话可写 DDL/迁移，其他会话仍默认只读，Scheduler 关闭。生成完整 verified source proof 后，再从 staging 导出第三份 bundle，还原到第四个全新目标，重新走统一 exact proof → `RestoreGuard` fence → 显式激活。旧 staging 不直接解除全库 gate，也不执行裸 SQL fence 后跳过核验。

完整矩阵为四个 owned 数据库、三份 bundle：旧源升级前后各导出一份，current bundle 直接还原第二库；legacy bundle 还原第三库并离线升级，再导出到第四库。分别查各路径的 proof 与报告，不把第四库的成功当作第二库的证据。不要将“可以写 DDL”理解为“可以使用复制来的旧 token”。

## 8. 故障注入与明确拒绝

至少核对以下独立证据，不以一个总 `all_passed` 字段代替具体结果：

| 故障或边界 | 预期 |
| --- | --- |
| 未知 schema/Codec/layout | 明确不兼容错误；不回退猜测 |
| Run/Event 混合布局 | 读取与迁移拒绝 |
| envelope/journal/checkpoint 篡改 | hash、metadata 或重建校验失败 |
| seq 失效或活跃 claim | 迁移拒绝，业务事实不变 |
| COMMIT 前后崩溃 | 整笔回滚或完整提交；重试幂等 |
| archive/manifest 损坏、伪造 bundle | 分配还原目标前拒绝 |
| 旧输出、symlink、任意既有 DB 目标 | 拒绝覆盖或非法参数 |
| owner marker 改变 | cleanup 拒绝，不删除该 DB |
| 原生工具 timeout/输出超限/调用者死亡 | owned OS PID 消失；错误可见 |
| 只读 proof 不匹配 | 不解除目标 gate |
| 复制的旧 claim | fence 后拒绝提交 |
| unknown/budget/产物变化 | 原核对、预算、审批语义保留 |

失败目录保留日志与 manifest；不要把密码、token 或私有 receipt 复制到公开报告。清理仅接受精确 owned handle + marker；仍有连接时正常拒绝，不终止用户其他进程，也不 force drop。

## 9. 交付与限制

提交对应测试、L20 实验记录、实际命令日志与 proof/report，列明新建/还原的目标均已精确清理，并说明不兼容样本如何拒绝。实际测试和演练数量写入 [验收记录](../docs/validation-week21.md)，不能把文档预期当成执行结果。

本实验是同一可信宿主上的单数据库逻辑还原。它不备份 roles、tablespaces、WAL 或工作区，不提供生产 PITR；原工作区必须存在于同一已授权根，原回执/hash 仍要有效。换机器、改授权根或遗失外部副作用证据，需要另外的迁移和恢复设计。参考 [解答](solutions/L20.md) 比较关键判断。
