# 第 22 周验收记录

验证日期：2026-10-23（Asia/Shanghai）。macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6。本周按原计划进行六章修订、试读准备与干净环境复现，不增加 Agent 业务功能、SQL migration 或依赖。用户确认“尚无记录，先完成试读包与技术验收”：技术验收通过，真实外部读者 **0 名**，3–5 人试读及 P5 外部准入仍待验收。

配套[六章指南](../book/reader-study/README.md)、[修订记录](reader-study-revisions.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md)、[解答](../labs/solutions/L21.md)、[ADR 0021](adr/0021-reader-study-and-clean-reproduction.md)、[运行手册第 20 节](recovery-runbook.md#20-六章试读与干净环境复现)。

## 交付与边界

| 交付 | 实际行为 |
| --- | --- |
| 六章试读稿 | 新增 ch02/ch05/ch08/ch14/ch16，修订 ch20，明确命令拒绝、预算归属、纯重建与续跑、外部效果 unknown、lease/fencing 边界；逐项链接现行实验号 |
| ReaderStudy / lab.reading | 输出自含冻结项目、18 个章稿/实验/指南/手册资产的 hash、协议、故意无效的空模板、反馈目录和报告；技术与真人 gate 分开 |
| 有界反馈 | 单条 256 KiB、最多 5 份、汇总 2 MiB；完整六章、固定 command ID、UTC 起止时间与协议校验；拒绝模板、代理标签、缺章、重复、未知字段及伪完整结果 |
| Reproduction / lab.reproduce | 固定入口的源码导出与 bytes/mode/hash 校验、明确缓存来源、固定环境 plan；不执行 plan、读者反馈或反馈路径文本，不自动安装或起停数据库 |
| 文件边界 | 拒绝已有目标、符号/硬链接、超限、源漂移，以及大小写和 NFC/NFD 别名指向源目录的目标；创建前核验祖先，拒绝不能留下源树内副本 |

反馈和技术 flags 是可信宿主提交的声明，hash 只证明完整性，不认证真人或代替实际执行证据。正式包不添加合成反馈；作者与代理的技术发现保留独立标签，见修订记录 R01–R18。章内纯值示例、8 个相邻测试 **116 passed**、Streaming 三分支、离线修复与 P1 内存演示已实际执行，详情见 [A 组记录](reader-review-a.md)和 [B 组记录](reader-study-review-b.md)。

## 测试结果

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

| 环境与命令 | 实际结果 | 日志 |
| --- | --- | --- |
| 原工作区 mix check | **977 passed**，975 tests + 2 doctests，0 失败；ExUnit 147.9s | [workspace-check](../artifacts/week22-workspace-check.log) |
| 干净导出 mix check | **977 passed**，975 tests + 2 doctests，0 失败；ExUnit 156.0s，命令含编译等 163.568s | [full_check](../artifacts/week22-clean-reproduction-release/full_check.log) |
| 干净导出内存模式 | **514 passed**，512 tests + 2 doctests；**463 个数据库用例排除**；ExUnit 23.9s | [memory_check](../artifacts/week22-clean-reproduction-release/memory_check.log) |

两次完整 check 都包括格式检查、warnings-as-errors 编译、测试库迁移、原 10/10 fixtures，以及创建/更新两种操作在 COMMIT 前后的四个真实进程 kill 窗口。463 个数据库用例已在完整 check 运行，不把内存排除视为通过。

相较第 21 周 937 项，新增 **40 项**：ReaderStudy 22 项、Reproduction 17 项、EvaluationDemo 1 项。新工具分别在 `umask 077` 下通过 22/22 与 17/17；最终全量干净执行同样使用该 umask。测试覆盖冻结与篡改、首条/重复反馈、真人 gate、报告上界、惰性文本、模式与源漂移、全新目标、源目录别名及完整环境 plan。EvalDemo 专项 5/5（含 60 个真实离线评测样本）通过。

## 真实干净复现

正式证据保存在 [week22-clean-reproduction-release](../artifacts/week22-clean-reproduction-release/execution.json)，工作目录 `/private/tmp/aslw22-d901ab/project`。这是**同宿主、声明安装缓存、新源码目录、新 runtime prefix、新依赖编译和新 PostgreSQL 集群**的复现；不声称另一台机器、冷网络安装、跨 OS 或真实模型验证。

导出包含 **475 个文件、532 个文件/目录条目、3,510,529 bytes**，不含原 `.runtime/deps/_build/artifacts/PGDATA`。实际从缓存提取 OTP/Elixir，在新 prefix 对 PostgreSQL 源码执行 SHA 校验、configure、make、install；随后离线解析 6 个锁定依赖并重新编译。执行前 installed runtime、deps、build、PGDATA 均不存在，初始实验 dev/test 库数量为 0；之后从零应用全部 **21 个 SQL migration**。

缓存 manifest 保存 **151 个条目、106,527,297 bytes**，包含运行时 archive、PG 源码及 SHA 文件、Hex 2.5.3、Rebar3 和锁定包。Hex 正常使用后改写 `hex/cache.ets`：初始原字节另存 `staged-registry-cache.ets`，初始/使用后 SHA 和私有副本 mode 明确记录；其余缓存输入继续严格逐项核对，不能用该例外忽略 archive 或可执行文件变化。

独立 cluster system identifier 为 `7699875282970310117`，监听 `127.0.0.1:55586`，PGDATA 属于上述新目录，`fsync/synchronous_commit/full_page_writes` 均为 on。环境 plan 清除 DATABASE_URL 和 Mix/Hex/build/ERL 等继承项，PGSERVICE 等可选 libpq 路由变量真正 unset，调度器默认关闭。原工作区共享实例未被停止。

全部 **20 个固定执行步骤**退出 0，逐步保存 argv、cwd、UTC 时间、耗时、日志 SHA。全量/内存检查后，以下六个主实验逐一实际执行：

| 实验 | 主要结果 |
| --- | --- |
| [verify](../artifacts/week22-clean-reproduction-release/verify.log) | 原 10/10 scripted fixtures 通过 |
| [P1](../artifacts/week22-clean-reproduction-release/reproduction-p1/report.json) | 修复前退出 2、修复后退出 0；4 份压缩 Context 保留任务事实、完整回执与权限；原 Session 不变；取消无写入；四个 PG COMMIT 窗口符合预期 |
| [history](../artifacts/week22-clean-reproduction-release/reproduction-history/report.json) | 新进程全量/检查点重建与 live/expected 状态一致，文件不变，27 个被监测执行入口零调用；2 份模型结果录制 |
| [recover](../artifacts/week22-clean-reproduction-release/reproduction-recovery/report.json) | 5 个故障探针、7 次 kill，含效果成功后崩溃和恢复中再崩溃/新 VM；重复效果 0，模糊文件结果保守阻塞后凭证据确认 |
| [fence](../artifacts/week22-clean-reproduction-release/reproduction-fence/report.json) | 5 个真实 SIGSTOP/SIGCONT 探针；旧 Worker 原提交被拒绝，42 个附加旧 claim 操作全部 fenced；状态覆盖和重复效果均为 0 |
| [upgrade](../artifacts/week22-clean-reproduction-release/reproduction-upgrade/report.json) | 旧布局迁移和两条还原路径逻辑一致；两组各 49 个被监测入口零调用；旧 claim 拒绝、unknown 留人工、预算失败不重置、审批重验；四个 owned DB 精确清理 |

随后再次核验源码 bytes/mode 不变。结束时只按本次 PGDATA、PID 文件及端口确认的 owned cluster 执行 stop，记录 `owned_cluster_stopped=true` 和 `owned_port_released=true`。归档及工作区保留，不按端口前缀清理其他进程。

## 独立核验与冻结试读包

独立只读 Python [审计脚本](../artifacts/week22-clean-reproduction/audit_independent.py)对正式目录核验 **1034/1034 通过**，见 [audit-independent.json](../artifacts/week22-clean-reproduction-release/audit-independent.json)及 [confirmation](../artifacts/week22-clean-reproduction-release/audit-independent-confirmation.json)。它独立计算源码/缓存/日志/备份文件的 hash 和 mode，交叉核对实际测试尾行、21 个迁移、步骤及实验报告；不连接数据库、不执行 SQL/任务/反馈，不把保存的运行时布尔值或调用计数当作自己重新执行的结果。

完整 [evidence-manifest.json](../artifacts/week22-clean-reproduction-release/evidence-manifest.json)绑定 **170 个证据文件**，其文件 SHA-256 为 `386194a091d32263e8bf399bf65a2abb511fdc821048fd17f5f558c8601b0d39`，即 [technical-evidence](../artifacts/week22-technical-evidence.json) 中的 digest。

正式 [试读包入口](../artifacts/week22-reader-packet/START-HERE.md)已经生成。它的 `project/` 与上述实际执行候选的源码 manifest **逐字节一致**，见 [binding](../artifacts/week22-clean-reproduction-release/packet-source-binding.json)：

- source manifest 文件 SHA-256：`ef4c29ba2c1ce0614e6a3a8457760f55ed0d4810cb922e2af1236b57ef053928`。
- reader protocol hash：`332a1a54ca8c47151985fd87c72fb373b4ce966f61349a31dabd37e5064d1146`。
- 正式 [report.json](../artifacts/week22-reader-packet/report.json)：`technical_status=passed`，`external_reader_count=0`，`external_reader_status=pending`，`external_fresh_reproductions=0`，`p5_external_gate_met=false`。

本验收记录是执行结束后的派生结果。冻结导出和试读包内的该文档保持执行前版本，已经明确标注结果将在原工作区补录；没有为写入通过结论而改动已执行源码或重算试读协议。后续反馈必须绑定该原协议；若修订章稿，重新冻结并重新收集适用记录。

## 失败记录、修复与原语义保护

三次未完成的干净运行全部保留，没有覆写为成功：

| 原证据目录 | 实际问题与处置 |
| --- | --- |
| [首次运行](../artifacts/week22-clean-reproduction/execution.json) | 初始化核验将 PGSERVICE 置空字符串，libpq 拒绝空服务名；在业务库创建前失败。改为 nil/unset；原 cleanup 也受该变量影响，保留原失败并另存 [精确 owned 清理记录](../artifacts/week22-clean-reproduction/cleanup-after-initial-error.json)，停止并释放 55583 |
| [第二次运行](../artifacts/week22-clean-reproduction-final/execution.json) | 当时 976 项中 963 通过、13 失败；暴露 `umask 077` 下复制目录 mode/固定 chmod 夹具问题，以及旧异步 kill 100ms、队列等待 20ms 的测试假设。只修夹具和观测断言；已停止本次 55584 |
| [第三次运行](../artifacts/week22-clean-reproduction-acceptance/execution.json) | 当时 976 项中 975 通过、1 失败；重复评测总延迟 p95 实测 245825→317050μs，正确触发默认性能回归。修复仅限演示验收口径；已停止本次 55585 |

第二次发现的旧测试修复为：monitor 等待改用有界 5s；公平性核对已服务低优先级 Run 的真实等待/priority，不再假定同一时间窗内另一 Run 永不老化。没有放宽业务 lease、deadline、预算或调度阈值。新夹具复制时保留目录原 mode，mode 漂移测试相对原权限切换；生产校验继续严格。

第三次发现的 EvalDemo 修复将“相同语义和成本”与“性能回归”分开。Comparison/Report/Runner/Scorer 和默认 **25% + 50000μs** 门槛不变，raw latency、comparison passed/status 继续如实保存。仅 Demo 的 repeat gate 接受完整、确定且通过的质量/成本/scoring 检查；报告明确 `latency_reproducibility_claimed=false`。新增测试用真实纯 Comparison 构造全局及单 task 性能回归，确认真实 regressed 判定不被改成 passed，质量退步、unknown cost、缺失/未知检查仍拒绝。

对照第 21 周冻结的 **362** 个核心源码/测试/配置/fixture/脚本，当前为 **369** 个：新增 7 个本周工具/套件/测试文件；既有文件仅上述 EvalDemo 与三个相关测试文件变化，见 [source-delta](../artifacts/week22-source-delta.json)。原 Agent 业务模块、所有 21 个 migration、config、mix.exs 和 mix.lock 不变。原权限、预算、绝对 deadline、工具回执、unknown/reconcile、审批 subject 和 fencing 语义由原实现与完整回归继续保持。

原开发库前后 **22 张业务表、18,722 行**的全列行 hash 逐项一致，见 [comparison](../artifacts/week22-main-db-comparison.json)。before/after 文件 SHA-256 都为 `488b79123ea7388157fbd3b8370494c78151923c42934e0e6d9d48b2056b9017`。原 Run/Event、回执、核对队列、预算和审批记录未改写。

剩余外部验收只包括实际招募 3–5 名读者、收集同协议完整记录及至少一次外部 fresh-workspace 主实验自报、处理真实 blocker。当前不填造访谈、易读性、完成率或读者耗时，不把技术通过写成 P5 全部完成。
