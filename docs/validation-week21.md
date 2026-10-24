# 第 21 周验收记录

验证日期：2026-10-23（Asia/Shanghai）。macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6，沿用原 `mix.lock`，无新增 Hex 依赖。新增第 21 个 additive SQL migration：Run/Event 的独立 history format 以及第 22 张业务表 `lab_history_migrations`；既有 20 个 migration 不变。

配套 [L20](../labs/L20-history-migration-backup-restore.md)、[解答](../labs/solutions/L20.md)、[ADR 0020](adr/0020-history-migration-backup-restore.md) 与[运行手册第 19 节](recovery-runbook.md#19-历史迁移版本兼容与备份还原)。

## 交付范围

| 组件 | 行为与边界 |
| --- | --- |
| Encoding / Storage | 业务 Kernel/Event schema 与 Codec 仍为 1；独立 layout 1/2，v2 保存原始 v1 payload 字节、tag、版本及 digest；显式 per-Run 版本，拒绝未知/混合布局 |
| HistoryMigration | 只读 plan、expected seq、Run 锁、真实外层 COMMIT、活跃 lease 拒绝、4096 Event / 32 MiB 源目标边界；迁移前缀 journal 校验三层 hash；重复迁移幂等，追加新 Event 仍可验证 |
| Compatibility | 严格检查当前 22 张业务表、列、独立版本域和恰好 21 个已知 SQL migration；未来/缺失版本明确拒绝 |
| ReadonlyProof | 静止库的完整 scope；公开 verified readers、全列行/序列/schema 指纹、raw Event/checkpoint 重建；前后变化拒绝；完整 proof 结构校验，缺失字段不能以 nil 相等通过 |
| Backup | 固定原生 pg_dump/pg_restore、可信当前 BEAM capability、随机 owned 数据库、owner marker、临时 dump→完成 archive、0600/0700、hash/工具版本/大小核验、有限命令输出与时间、OS PID 和连接 owner-death 清理 |
| RestoreGuard | 目标默认只读，完全一致后按 Queue→Run→Intent 锁撤销 pending lease 并提升 generation；保留下一次领取空间；保护业务事实和预算，随后显式解除 gate |
| UpgradeDemo / CLI | 固定可信旧存储夹具与新 OS BEAM，真实 20→21 DDL，四个新 DB／三份 archive 的迁移与还原矩阵；迁移零模型/工具/执行/审批写入口/观测调用，随后显式安全续跑 |

这是离线、同一可信宿主、单数据库逻辑备份实验。数据库只读设置是防误操作门闩，hash 是完整性证据；均不替代认证。工作区保留在原已授权绝对根，不宣称备份了外部文件、roles、tablespaces、WAL 或生产 PITR。

## 新增测试

```sh
./scripts/mix test test/agent_systems_lab/history_encoding_test.exs \
  test/agent_systems_lab/history_migration_test.exs \
  test/agent_systems_lab/backup_test.exs \
  test/agent_systems_lab/history_compatibility_test.exs \
  test/agent_systems_lab/readonly_restore_test.exs \
  test/agent_systems_lab/history_upgrade_demo_test.exs
```

专项 **31/31 passed**，用时 **8.9s**，见[专项日志](../artifacts/week21-focused-tests.log)。

| 组 | 数量 | 实际判据 |
| --- | ---: | --- |
| Encoding | 3 | 原始字节往返、未知 Codec/layout、混合格式、隐式降级、篡改 envelope 和可执行 term 拒绝 |
| HistoryMigration | 12 | 真正 COMMIT 前后进程 kill、并发迁移幂等、seq/live lease/嵌套拒绝、journal 三层 hash、前缀追加、真实未来 schema/Codec 拒绝、迁移上界及原权限/预算/回执/录制字节保留 |
| Backup | 7 | 真 custom archive/read-only restore、损坏与伪造、旧输出/符号链接、marker 精确清理、activation 序列化、timeout/超量/调用者死亡后的实际 PID 和连接清理 |
| Compatibility / Readonly / Restore | 6 | 两格式语义一致、严格 proof 和 SQL version 拒绝、23 表与序列相同、50 个 effect/观测/迁移边界零调用、坏 proof/generation 耗尽保持 gate、旧 claim 拒绝及新 BEAM 续跑 |
| UpgradeDemo | 3 | 非法参数和旧证据保护、真实旧表生成、完整两条还原路径、fence 后迁移与续跑、四个 owned DB 全清理 |

旧未来 schema/Codec 的数据库注入在外层回滚事务内走迁移共用的 `Storage.snapshot_in_transaction` 校验入口；公开 migrate 拒绝嵌套事务，因此不把该注入伪称为成功启动的外层迁移。独立 Encoding 和原有业务测试同样覆盖未知版本。崩溃测试没有用仅 `{:error,...}` 返回替代进程死亡。

## 完整回归

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

冻结代码完整 **937 passed（935 tests、2 doctests），0 失败**，用时 **134.6s**。格式检查、warnings-as-errors 编译、测试库迁移、W1—W21 全部测试、原 **10/10 fixtures** 和四个创建/更新 COMMIT 前后实际进程 kill 检查均通过。日志：[week21-check-complete.log](../artifacts/week21-check-complete.log)。本次完整运行一次通过；未修改旧测试、超时或既有 20 个 migration。

无数据库模式 **474 passed（472 tests、2 doctests），463 个数据库用例排除**，用时 **14.4s**，见[内存模式日志](../artifacts/week21-memory-tests.log)。这 463 个数据库用例已在完整验收实际运行，不把排除视为通过。新增 31 项等于原第 20 周 906 项加到本次 937 项。

## 正式四库与三份原生备份

正式命令 `./scripts/mix lab.upgrade --output artifacts/week21-upgrade-acceptance` 成功退出，见[命令日志](../artifacts/week21-upgrade-acceptance.log)与[report.json](../artifacts/week21-upgrade-acceptance/report.json)。固定旧夹具的四份源码来自第 20 周 335 文件冻结快照，逐字节 SHA-256 固定在 `fixtures/history_v1/manifest.json`；主 BEAM 不热替换模块。其余业务模块使用当前实现，因此这是精确定义范围的真实旧存储夹具，不是整套旧发行版镜像。

演练包括 7 Run、2 Workflow、1 个经历返工后批准的 Case：成功文件效果与 checkpoint、pending 工具、非幂等 unknown、预算耗尽失败、仍未到期且已经扣 dispatch 的旧 claim，以及两个审批轮次。升级前没有 history_format 列；DDL21 只增加结构并默认 v1，再显式迁移事件布局。6 Run 迁移、每次重复均 `already_current`；有活跃 claim 的第 7 个明确拒绝，在还原 fence 后才允许迁移。迁移前后完整任务逻辑签名一致。

第一份 archive 是旧 20 DDL 源库，第二份是该源库升级后的当前结构。当前 archive 还原到第二库后保持只读，23 表（22 lab + schema_migrations）、全部序列、schema、raw Event/checkpoint 与源 proof 相同，才激活并在新 BEAM 复验完整语义和受保护 hash。旧 archive 还原第三 staging 库后，仅固定维护子 BEAM 的专用会话可升级，数据库默认 gate 不解除；重新生成第三份 archive，还原第四库，再走同一 proof/fence/激活协议。

每条升级路径都在独立 BEAM 用 49 个模型、工具、调度、恢复、审批、返工、观测和评测入口计数，全部零。两个目标各对 3 个 pending intent 撤销旧 lease、generation +1；原始 DB hash 允许因这些字段变化而不同，protected/raw semantic/verified semantic hash 必须保持相同。旧源 Worker 的未过期 claim 被拒绝，新 Worker 用原领取与扣账机制续跑。

完成文件不重复写；pending 幂等工具效果 1 次；非幂等 unknown 效果仍 1 次并继续留人工核对；预算失败仍失败；审批 release 重验同一产物和 subject。实验不改变绝对授权根、原任务 deadline 或已扣预算。四个 owned DB 只通过精确 capability+marker 清理，实际结果见[清理记录](../artifacts/week21-upgrade-acceptance/database-cleanup.json)。工作区和 archive 证据保留。

## 独立证据与既有数据保护

`python3 scripts/audit_week21.py artifacts/week21-upgrade-acceptance` 完成 **85/85** 离线证据核对，见[audit-python.json](../artifacts/week21-upgrade-acceptance/audit-python.json)。独立计算三个 archive 的实际 SHA-256、检查文件权限和原生 `pg_restore --list` inventory（TABLE DATA 分别 22/23/23，SEQUENCE SET 各 6）、四个旧夹具固定 hash，并交叉核对两条 proof、49 个入口集合、fencing、续跑和清理记录。脚本不连接数据库、不执行 SQL，不重新计算 ETF 的 Context.hash，也不把保存的零调用断言当作重新执行了业务的证据。

最终冻结 **362 个源码、测试、配置、fixture、脚本与依赖文件**；正式演练后 bytes 和 mode 全部相同。对照第 20 周 335 文件冻结快照，仅四个旧存储文件改变，旧测试、前 20 个 SQL migration 和 mix.lock 均不变；新增文件包含四份逐字节固定的历史源码，主代码和旧夹具的用途已分开。冻结清单位于[source-before.json](../artifacts/week21-upgrade-acceptance/source-before.json)，源码副本保存在 `artifacts/week21-source-snapshot/`。

正式演练前后对既有开发库 **22 张业务表、18,722 行** 的全列行 hash 逐项相等。Run、事件、工具回执、核对队列、预算与审批原记录均未修改。见[source-and-existing-database-audit.json](../artifacts/week21-upgrade-acceptance/source-and-existing-database-audit.json)及 `artifacts/week21-main-db-before.json` / `week21-main-db-after.json`。开发库已应用 additive DDL21，既有 Run/Event 仍为默认格式 1；本次实际迁移和续跑全部在 owned 隔离库完成。

## 拒绝路径与故障保留

开发阶段记录并修正：演练选项不符合原 Recovery API、私有 claim 中 DateTime 不被 Codec 接受、兼容性读取的动态 Repo 选择、原生还原把等价 CHECK 的括号规范化导致 DDL 文本假差异，以及旧证据目录错误分类。保留 `week21-upgrade-initial*` 目录及各自 cleanup 结果；没有把失败目录覆盖成成功结果。约束最终使用 `pg_get_constraintdef(oid,true)` 的 PostgreSQL pretty 表示比较，所有原始行和序列继续要求一致。

独立评审还发现部分标签 proof 可能因缺字段 nil 相等误通过，及 fence 代次上界未为新领取预留空间；均已修复并加入拒绝测试。旧 DDL 路径最初提出的提前解 gate 设计已撤销，正式实现保持 staging gate 并通过新目标统一 Guard 激活。

fence COMMIT 与解除默认 gate 不是跨管理连接的原子事务。两步之间故障保留只读状态；保留该目标证据并从可信原 bundle 恢复新目标，不手动重置预算或跳过 proof。这里只验证组件故障及保守恢复合同，没有宣称完成生产灾备或跨 PostgreSQL 版本升级。
