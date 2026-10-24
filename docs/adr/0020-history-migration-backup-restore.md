# ADR 0020：历史布局迁移、明确兼容性与受管备份还原

- 状态：接受，用于第 21 周教学实现；实际验收以 [validation-week21](../validation-week21.md) 为准。
- 日期：2026-10-23。
- 关联：[L20](../../labs/L20-history-migration-backup-restore.md)、[运行手册第 19 节](../recovery-runbook.md#19-历史迁移版本兼容与备份还原)、[历史重建 ADR](0006-history-checkpoints-and-recorded-results.md)。

## 问题

事件历史、checkpoint、模型录制、工具回执、预算和审批已经是运行时事实。修改持久化布局后，仅让新建 Run 通过测试不够：旧库必须可读或得到明确拒绝，迁移必须证明业务事实一致，备份必须实际还原到另一数据库并独立核验。恢复数据库还复制了调度 claim，不能将旧 token 当成新目标的执行授权；工作区中的文件也不属于数据库 dump。

需要分开回答四个问题：SQL schema 是否具备读取条件、数据 envelope 是否受支持、原始事实是否完整、目标是否已获得显式续跑许可。某一层检查通过不能替代其余三层。

## 决定

保留业务 Kernel/Event schema v1 与惰性数据 Codec v1，新增独立的 `history_format` 域。布局 v1 是原 Codec 字节；布局 v2 用固定 tag、版本、原字节和 SHA-256 包裹同一字节，不重解释 Event，不迁移模型输出，也不重新执行工具。Run 与各 Event 必须同布局；混合布局、未知版本、错误 envelope、校验不符和缺失迁移 journal 明确拒绝，没有猜测解码或静默降级。

SQL migration 为 Run/Event 增加默认 1 的格式列，并创建 `lab_history_migrations`。默认值只为旧列提供已知解释，不代表旧行已经迁到 v2。Journal 记录源/目标布局、迁移前缀长度、源与目标字节 hash、业务语义 hash 和 Codec 版本；后续 v2 Event 可以追加，读取仍验证已迁前缀。

`HistoryMigration.plan/1` 只读；`migrate/3` 是显式宿主动作，要求当前 seq、真正外层事务和无活跃执行 claim。它在 Run 锁内验证原投影、事件、工具结果配对及调度意图，再改变布局并写 journal，提交前比较完整 snapshot 一致；权限、预算等 sidecar 保持原字节，综合 proof 另行验证其语义。失效 seq、活跃 claim、嵌套事务和超限历史被拒绝。每个 Run 上限 4096 个 Event、32 MiB 历史字节；先检查聚合大小再载入数据。重复调用验证当前 journal 后返回 `already_current`，不能悄悄修复损坏。

兼容矩阵独立声明 Kernel/Event schema、Codec、sidecar schema 均为 1，history format 为 1/2。离线检查逐表核对预期表、列和版本，未知版本或未预期结构失败。语义读取继续使用已有 Storage/Recovery/Context/模型录制/工具/预算/Workflow/审批校验，不能仅凭版本号认为数据有效。

旧库来自固定的真实第 20 周夹具：四个存储相关模块逐字节冻结在 `fixtures/history_v1/runtime/`，manifest 绑定各文件 SHA-256。专用新 OS BEAM 在全新受管数据库执行前 20 个 SQL migration，再只在该子 BEAM 加载旧模块并生成旧历史；主 BEAM 不替换模块。该夹具明确固定存储读写与 schema，其余业务模块使用当前实现；没有声称保存了整套旧应用二进制。

## 备份与还原边界

`Backup.create_lab_database/1` 从当前 Repo 的可信宿主连接配置派生管理员连接，仅创建随机 `lab_w21_<32 hex>` 数据库，使用 `TEMPLATE template0`。句柄是内存 capability；数据库 COMMENT 保存单独 owner marker，每次操作同时验证 registry、精确名称和 marker。没有任意数据库目标参数，不覆盖主 dev/test 库，不接受按名称清理，也不使用 `DROP ... FORCE`。删除时仍有连接会拒绝，失败保留证据供宿主处理。

使用固定 PostgreSQL 18.6 `pg_dump --format=custom --no-owner --no-acl` 与 `pg_restore --exit-on-error --single-transaction --no-owner --no-acl`。还原总是新建另一个受管目标，不允许 `--clean`、`--create` 或调用者提供任意 SQL。Bundle 目录为 0700，archive/manifest 为 0600；拒绝旧输出、符号链接和损坏字节。Manifest 记录 archive 大小、SHA-256、工具/服务器版本和 SQL migration 列表；还原重验 archive、manifest 和工具版本。

Bundle 仅由当前主 BEAM 内存 registry 接受，不能从磁盘导入为可信输入。Archive 中的 SQL 必须来自可信宿主；hash 只是损坏检测与内容身份，不能认证来源。Bundle 丢失或 BEAM 重启后，应重新进行受控演练，不能将任意 dump 加 hash 后交给本接口执行。

原生工具通过无 shell 的固定 executable/args 启动。独立 guardian 持有 Port，监视调用者、限制 timeout 和 stdout；超时、超量输出或调用者死亡时终止该 Port 的实际 owned OS PID。密码仅经子进程环境传递，不进入命令参数、manifest 或摘要。Dump 运行中每 20 ms 检查文件大小，上限 256 MiB；检测可能有单次轮询超量，这不是硬磁盘 quota。单命令 timeout 最多 120 秒，stdout 最多 64 KiB。

还原后通过数据库默认 `default_transaction_read_only=on` 设置操作门闩；全局 Scheduler 保持关闭。它防止普通新连接误写，是宿主流程互锁，不是对 database owner/superuser 的安全隔离，不能阻止有权用户显式关掉会话只读设置。

## 一致性核验与显式激活

`ReadonlyProof` 要求静止数据库和完整 Run/Workflow/Case scope。可信源的 public readers 校验全重建与 checkpoint 重建、模型录制、工具配对、权限预算及审批绑定；前后对全列行、schema、约束、序列位置和 SQL migration 取指纹，拒绝期间变化。还原目标用原生只读 SQL 核对字节，并独立解码/重建 Run 和 checkpoint；原有 `FOR SHARE` 读接口不适合直接在 PostgreSQL READ ONLY 事务运行，因此不以临时关闭全库 gate 绕过只读核验。

目标 raw proof 必须与已验证源的完整事实相同。只有源 proof 与目标 scope 一致后，`RestoreGuard.activate/3` 才可在专用事务按 Queue → Run → Intent 顺序锁定，撤销复制的 pending claim、递增 fencing generation，再核对受保护事实和 Run 语义不变。权限、工具结果、预算消耗、绝对 deadline、unknown/reconcile 队列和审批 subject 都不能重置。旧 token 被拒绝；新执行必须显式续跑并重新领取。

关闭默认只读 gate 是独立的后续宿主操作；fence 事务失败时继续只读。相同 handle 的激活串行化，已激活目标拒绝重复激活。若 fence 已提交而随后 gate 解除失败，目标留在保守状态，必须保留故障证据并核对现状，不能把整个流程当作跨数据库原子事务重复执行。

真旧 SQL dump 还原到第三个 staging 数据库后，保留全库默认只读。固定子 BEAM 仅为专用 Repo 会话关闭只读，补 SQL DDL、验证旧历史迁移并建立完整源 proof；其他会话仍默认只读，Scheduler 关闭。该 staging 再次 dump，并还原到第四个全新目标，走相同 `RestoreGuard` exact proof、fence 和激活路径。没有在旧 staging 直接解除全库 gate，也没有以裸 SQL fence 代替统一接管验证。

演练矩阵是四个 owned 数据库、三份可信 bundle：旧源库在升级前后分别导出 legacy/current 两份；current bundle 还原到第二库；legacy bundle 还原第三库做离线升级；升级后的第三库导出第三份 bundle，还原第四库再验证与接管。实际成功结论仍由报告和独立审计给出。

## 语义保留与范围

已成功文件工具的回执不能变成一次新写入；pending 幂等工具仍最多一个外部效果；非幂等 unknown 继续留在人工核对队列；预算耗尽的失败不能因还原得到新额度；旧审批必须重新验证同一产物 hash。恢复不能将旧目录更换为任意新路径而复用原授权。

本实现是单数据库 logical backup，不备份 roles、tablespaces、WAL 或时间点恢复链。工作区文件不在 archive 中；演练保留原已授权根和实际文件，核对原 receipt/hash。没有在另一机器重建文件根、生产备灾、加密离线保管、跨版本 PostgreSQL 升级或 PITR 保证。真实迁移必须单独设计数据库与外部副作用的共同恢复边界。

## 验证与后果

测试覆盖双布局读、未知/混合格式及 journal 损坏拒绝、只读 plan、重复迁移、seq/claim/嵌套事务边界、提交前后故障窗口、迁移不调用模型/工具、原始与语义证明、真实 custom dump/restore、损坏/伪造 bundle、旧输出/符号链接、owner marker、只读 gate、激活失败与 stale claim、原生 timeout/输出上限/调用者死亡后的实际 PID 清理。正式旧库及两条还原路径使用新的数据库和独立 BEAM，数量及审计结论以本周验收记录为准。

代价是 offline/quiescent 的宿主流程和有限历史规模；不会自动迁移每个 Run，也不会把失败 archive 变成可接受输入。得到的是可核对的布局变更、明确拒绝、可还原的真实证据和显式接管边界。

## 依据

[PostgreSQL 18 pg_dump](https://www.postgresql.org/docs/18/app-pgdump.html) 描述单数据库逻辑导出的事务一致性及 cluster 级对象边界。[PostgreSQL 18 pg_restore](https://www.postgresql.org/docs/18/app-pgrestore.html) 提醒还原可能执行源数据库提供的代码。本项目据此要求可信 archive 来源、固定宿主命令和独立新目标；这些限制来自本实验设计，不是由 SHA-256 自动提供的认证能力。
