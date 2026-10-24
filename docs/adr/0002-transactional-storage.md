# ADR 0002：Run、Event 与调度意图的单事务提交

- 状态：已接受
- 日期：2026-10-20
- 适用范围：Agent Systems Lab 第 3 周、L02
- 延续：[ADR 0001](0001-pure-kernel-and-explicit-effects.md)

## 背景

L01 能在持有完整内存事件时重建状态。进程退出后，任务状态和事件也随之丢失。直接给 RunServer 加一次数据库写入仍不够：如果任务投影已更新、事件未写完，或者二者已提交却没有留下下一步工作，恢复者无法判定应继续什么。

本阶段需要证明两个边界：事务提交前应用进程崩溃，不留下部分事实；事务提交后、调用者收到确认前崩溃，完整事实仍可从独立连接读取。调度器尚未实现，因此必须把“存在待调度意图”与“已被可靠执行”分开。

## 决策

1. 引入 Ecto Repo、Postgrex 与 PostgreSQL。Kernel 继续作为纯状态机，数据库和序列化均留在外层 Storage。
2. 接收任务时，`Storage.create_run/3` 在一个事务中创建 Run、接受 `start` 命令产生的 Event、保存状态投影并写入首次调度意图。调用返回成功位于事务提交之后。
3. 后续 `Storage.dispatch/4` 在同一事务内锁定 Run、比较 `expected_seq`、调用 Kernel、追加事件、更新投影、将旧的 pending 意图标记为 superseded，并按新状态写入当前意图。非法命令或版本冲突不产生部分写入。
4. Event 的 `(run_id, seq)` 唯一，序号与 Kernel 的已提交状态对应。`expected_seq` 表达调用者读到的版本，防止两个调用者把同一旧状态各推进一次。行锁负责串行化数据库提交；它不授予持续的 Worker 执行权。
5. 当前意图由状态决定：`running → model`、`waiting_tool → tool`、`blocked → reconcile`；终态没有 pending 意图。意图与产生它的状态版本绑定。历史意图保留，只有当前版本的 pending 意图供后续扫描。
6. `Storage.load/1` 返回持久化状态、顺序事件和当前意图，并检验事件重建与投影的一致性。`pending_intents/0` 提供已提交待办的扫描入口。读取不会执行模型或工具。
7. RunServer 默认保留 L01 的内存模式；显式使用 `storage: :postgres` 时，每次被接受的转换通过 Storage 提交。恢复只还原已提交事实，不自动重放尚未确认的外部动作。
8. 保留 `hook: fn phase -> ... end` 测试钩子。`:before_commit` 位于事务内部、所有写入完成之后；`:after_commit` 位于真实提交之后、公共函数返回之前。钩子只建立测试屏障，不承载业务副作用。

## 数据格式与数据库约束

持久化表为 `lab_runs`、`lab_events`、`lab_intents`，对应 `Storage.Run`、`Storage.Event`、`Storage.Intent`。Run 保存状态投影及可查询的 status、seq、预算字段；Event 保留 `schema_version`；序列化负载单独保存 `codec_version`，两种版本不混用。

数据库外键保证 Event 与 Intent 不能脱离 Run。Event 的 `(run_id, seq)` 唯一，Intent 通过复合外键绑定产生它的 Event。局部唯一索引限制每项 Run 最多一个 pending 意图。数据库约束处理结构性错误，Storage 的重建校验继续检查语义一致性，不能由其中一层取代另一层。

Codec v1 使用带版本的未压缩 Erlang External Term Format。解码使用 `binary_to_term` 的 `:safe` 选项，之后校验 inert 数据；拒绝 PID、port、reference、函数、不规范列表和未知结构体，并限制 8 MiB 与 64 层嵌套。读取前加载 Kernel、RunServer 和内置适配器的可信代码词汇，使新 VM 能理解内置回执和失败标记；加载代码不会执行模型或工具。业务 payload 推荐字符串键和值。

`:safe` 不能创建接收 VM 尚未存在的 atom。若业务 payload 保存了仅原进程动态创建的 atom，换 VM 后读取可能明确失败。这个教学格式只面向本地 BEAM 数据，未提供跨语言协议或任意旧版本兼容；未来格式变更需新 codec 版本和显式迁移，不用不安全解码回退掩盖问题。

## 提交协议

```text
create / dispatch
    │
    ├─ BEGIN
    ├─ 锁定并校验版本（dispatch）
    ├─ 纯 Kernel 决策
    ├─ Run 投影 + Event + 旧意图 superseded + 新意图
    ├─ before_commit 屏障          ← 此时 kill：全部回滚
    ├─ COMMIT
    ├─ after_commit 屏障           ← 此时 kill：事实完整，调用方未收到 ACK
    └─ {:ok, snapshot}             ← 本地 API 的 ACK
```

这里的 ACK 指公共函数把成功结果交给调用者，不是 PostgreSQL 协议中单独的一条消息。数据库可能已经提交，调用者却没有得到返回值。因此“没有收到成功”不能推导为“没有写入”。调用者应使用稳定 Run ID 和预期序号查询事实；不能换一个 Run ID 盲目重发同一业务。

## 验证方式

崩溃测试使用真实 PostgreSQL、独立调用进程与监控消息。在 hook 发出到达通知后，测试才执行 `Process.exit(pid, :kill)`。`kill` 不运行该进程的清理回调。验证连接必须位于被杀事务之外。

测试不包裹外层 SQL Sandbox 事务。嵌套在 Sandbox 内的“提交”不能证明其他连接已经看到真实 COMMIT，进程被杀后的 Sandbox 回滚还会掩盖已提交事实。测试数据使用独立 Run ID 并显式清理。

Storage 写接口在检测到已有 Repo 事务时返回 `{:error, :nested_transaction_not_supported}`。这项限制让成功返回始终对应本接口控制的真实提交边界；业务方不能把它嵌入更大的事务后仍沿用相同 ACK 语义。

至少覆盖：创建时提交前崩溃、创建时提交后 ACK 前崩溃、转换时提交前崩溃、转换时提交后 ACK 前崩溃。转换前的旧快照必须完整保存；成功提交后的新快照必须完整替换旧版本，包括旧意图的状态。另测非法命令回滚、竞争版本拒绝、终态没有 pending 意图、事件与投影可重建一致。

## 保证与限制

| 问题 | 本阶段的保证 |
| --- | --- |
| 应用进程在 COMMIT 前退出 | 该事务不留下部分 Run、Event 或调度意图 |
| COMMIT 后、ACK 前应用进程退出 | 从独立连接可以读到完整已提交事实，扫描可以发现 pending 意图 |
| 两个调用者使用同一 expected_seq | 最多一项转换提交，另一项得到版本冲突 |
| 数据库持久提交 | 使用 PostgreSQL 的 WAL 与实际服务器持久化配置；实验记录 `fsync` 和 `synchronous_commit` |
| 工具是否只产生一次外部效果 | 本地事务无法独立保证，仍需工具幂等键、结果查询或核对协议 |
| 谁领取、重试和推进 pending 意图 | 留待后续 Worker、lease、fencing 与恢复协议实现 |

应用进程 kill 证明事务原子性和提交结果独立于调用进程的内存，不等于完成了数据库主机断电实验。`fsync=on` 与同步提交是本实验的持久配置前提；介质损坏、副本切换、存储设备是否诚实持久化均不在本阶段验收内。

调度意图具有 outbox 的提交边界，但本阶段没有 dispatcher。扫描到同一意图多次、Worker 执行后尚未记录结果、旧 Worker 恢复等问题仍需后续协议。数据库 COMMIT 不会把 PostgreSQL 与外部 API 变成一个原子事务，也不会自动产生 exactly-once 效果。

Provider 游标与 Mock 操作台账仍是内存数据。即使 Run 已持久化，创建新的 Mock 也不能代替原服务的持久回执。遇到不确定的外部效果，不能根据新 Mock 返回 `not_found` 就认定旧效果不存在。

## 代价与后续

本地开发与 CI 都需要真实数据库，测试不再完全离线开箱即用。固定运行时、依赖锁文件、迁移与项目内 PostgreSQL 脚本降低环境差异。内存模式保留，便于独立研究 Kernel 与 L01。

后续在当前意图上增加领取与恢复协议，显式区分逻辑操作、传输尝试与结果事实。多 Worker 的 lease 与 fencing 不用当前行锁冒充；外部效果不会放进长期数据库事务。

## 官方资料

- [Ecto Repo：事务与回滚](https://hexdocs.pm/ecto/Ecto.Repo.html#c:transaction/2)
- [Ecto.Multi：组织事务操作](https://hexdocs.pm/ecto/Ecto.Multi.html)
- [Ecto SQL Sandbox：测试事务与连接所有权](https://hexdocs.pm/ecto_sql/Ecto.Adapters.SQL.Sandbox.html)
- [PostgreSQL：事务](https://www.postgresql.org/docs/current/tutorial-transactions.html)
- [PostgreSQL：行锁](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS)
- [PostgreSQL：WAL 与持久化配置](https://www.postgresql.org/docs/current/runtime-config-wal.html)
- [PostgreSQL：同步与异步提交](https://www.postgresql.org/docs/current/wal-async-commit.html)

实际依赖版本以 `mix.lock` 为准；PostgreSQL 实验版本与配置写入验收记录。
