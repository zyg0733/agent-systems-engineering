# 第 3 周验收记录

验证日期：2026-10-20，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。

## 实现与依赖

`mix.lock` 已锁定 Ecto 3.14.2、Ecto SQL 3.14.0、Postgrex 0.22.4 及其依赖。PostgreSQL 从官方源码下载，校验发布的 SHA256 后在项目 `.runtime/` 内编译、初始化并启动。

Run、Event 与调度意图使用一次 `Ecto.Multi` 提交。转换先锁定 Run，再比较 expected_seq；旧意图 superseded 与新意图插入也在该事务内。数据库约束保护外键、事件序号、合法状态及每项 Run 最多一个 pending 意图。Storage 拒绝嵌套写事务，以保持真实 COMMIT 与 API ACK 的边界。

## 自动化检查

```sh
./scripts/mix check
```

结果：**75 passed，包含 73 个测试和 2 个 doctest**。原有 53 项全部保留通过，新增 22 项覆盖真实存储与运行器持久化集成。10/10 原有 fixture 通过。格式检查和项目编译警告检查通过。

新增测试包括四类提交边界 kill、异常回滚、并发 CAS、意图替换、终态、损坏数据拒绝、数据库约束、嵌套事务拒绝、持久 RunServer 与独立 BEAM 读取。数据库测试不使用 SQL Sandbox 外层事务，按自建 Run ID 清理。

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

结果：原有 **53 passed，22 个数据库测试明确排除**。该模式只用于 L01，不能替代完整检查。

## 实际崩溃证据

`lab.verify_db` 在写入调用进程到达 hook 屏障后执行真正的 `Process.exit(pid, :kill)`；父进程使用独立数据库连接，在屏障处和终止后分别检查事实。

| 操作与故障点 | Run 数 | Event 数 | 历史意图数 | pending 数 | API ACK |
| --- | ---: | ---: | ---: | ---: | --- |
| 创建 COMMIT 前 | 0 | 0 | 0 | 0 | 未收到 |
| 创建 COMMIT 后、返回前 | 1 | 1 | 1 | 1 | 未收到 |
| 从 seq 1 转换，COMMIT 前 | 1 | 1 | 1 | 1 | 未收到 |
| 从 seq 1 转换，COMMIT 后、返回前 | 1 | 2 | 2 | 1 | 未收到 |

屏障处和进程终止后的计数一致。转换提交前保留完整旧版本；提交后保留完整新版本及旧意图 superseded。按原 ID 与序号查询可以区分两者；已提交转换用旧序号重试被拒绝。

## 独立进程与数据库重启

独立 BEAM 回归测试证明：内置 Mock 回执及运行器失败标记可以在新 VM 中安全解码，事件重放结果与投影一致。它防止同一 VM 已加载的 atom 词汇掩盖恢复问题。

另外实际使用三个独立演示 Run 保存正常完成、预算失败、unknown 待核对状态。退出写入 VM 后，在另一 VM 读取成功；正常停止、重新启动项目 PostgreSQL，再用新 VM 读取，仍得到 succeeded/seq 4、failed/seq 4、blocked/seq 3。验证后仅删除这三个自建 Run。

服务器实测配置为 fsync=on、synchronous_commit=on、full_page_writes=on，监听地址为 127.0.0.1、端口为 55432。

## 手册与环境入口

[L02](../labs/L02-transactions.md) 中 7 个 Elixir 代码块已按顺序在真实测试数据库执行通过，覆盖正常提交、意图历史查询、提交前后终止、pending 扫描和持久 RunServer。`scripts/iex` 已实际启动并执行输入，统一项目运行时及 Hex/Mix 缓存。

GitHub Actions 配置已加入 PostgreSQL 服务与依赖安装；本次没有推送或执行远程 CI。

## 本阶段边界

上述 kill 测试终止的是事务调用的 BEAM 进程；独立 VM 和数据库重启实验使用正常退出、正常服务重启。没有把它们等同于主机断电、磁盘损坏或复制故障转移。

待调度意图可持久扫描，尚未实现后台 dispatcher、领取、lease、fencing 或自动续跑。Provider 游标与 Mock 台账仍在内存中，本地事务不提供外部效果 exactly-once 保证。Codec v1 是安全的本地 ETF 格式，任意业务 payload 推荐字符串键和值；不安全解码回退未启用。
