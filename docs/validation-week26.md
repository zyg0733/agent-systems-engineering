# 第 26 周验收记录

验证日期：2026-10-24（Asia/Shanghai）。完成新主机冷安装、Linux 核心适用执行和有界环境证据采集流程。最终在本机新工作区执行成功；真实冷主机、Linux 与真人证据仍待验收。配套 [L25](../labs/L25-cross-environment-validation.md)、[参考解答](../labs/solutions/L25.md)、[ADR 0025](adr/0025-cross-environment-validation.md)及[操作手册](cross-environment-validation.md)。

## 最终源码与实际环境

最终冻结目录为 `artifacts/week26-frozen-source-final/`，包含 **525 个源文件、585 个条目、4,178,614 字节**；原始 source manifest SHA256：

`1a160b096d755dd58d156ae58462e9de00672e4d0f100b12af3f1454e6e9e6ca`

最终执行器 SHA256 为 `171cd2ad37060138319213e10530bffc13ec59d8b05f1a051678c67d78dfe9df`。首次冻结 `artifacts/week26-frozen-source/` 与失败工作区保留，不改绑到此身份。测试实际使用最终冻结的源码副本；本文件在原工作区补录实际结果，冻结副本中的原始待补录说明保持不变。

实际宿主为 macOS 26.7.1 / Darwin 25.6.0、arm64，Python 3.9.6、普通非 root 用户；Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6。现有安装 prefix 与包缓存被明确复用，源码工作区、deps、build 与 PGDATA 新建；这属于 **同宿主 warm-cache 复现**。`host-observation.json`、`environment-availability.json` 记录实测与资源可用性；没有发现可用 Linux runner，也没有取得新 macOS 主机。

## 最终执行结果

执行目录 `artifacts/week26-current-environment-verified/`，原始 `execution.json` 记录 11 条固定命令，退出码全部为 0；实际读取与编译的源码在执行后再次校验一致。

| 项目 | 实际结果 |
| --- | --- |
| 格式、编译、source readiness | 全部通过，编译启用 `--warnings-as-errors` |
| 完整 `./scripts/mix check` | **1093 项通过：1091 tests + 2 doctests，0 排除**；ExUnit 324.9 秒 |
| 内存 `LAB_DATABASE_ENABLED=false ./scripts/mix test` | **628 项通过：626 tests + 2 doctests，465 项 database 排除**；ExUnit 186.3 秒 |
| 原固定 fixture 与 COMMIT 窗口 | 10/10 fixture、PostgreSQL 提交前后真实崩溃检查通过 |
| 新 Elixir 专项 | 20 项，已包含在完整/内存总数中；不是额外加算 |
| Python 执行器专项 | **36/36 通过**；原始记录 `python-runner-tests-final.log` |
| 六个主实验 | verify、p1、history、recover、fence、upgrade 全部通过 |
| 权限、事实、回执与历史 | P1 事实/权限/完整回执保留；history 与 live/expected/checkpoint 一致；恢复、fencing、upgrade 报告均 all_passed |

本机完整模式没有 Seatbelt 排除。内存模式的 465 项数据库排除已在完整模式执行，不能把它们称作内存模式通过。ExUnit 仍提示 support fixture 文件命名不匹配过滤器；没有删除用例、额外排除或放宽断言消除提示。

## 独占资源、证据与只读边界

最终新集群端口 **55597**、PID **99489**、system identifier **7699937250738697368**，初始实验数据库数为 0；SQL 实测 `fsync/synchronous_commit/full_page_writes=on`。PID、PGDATA、端口与系统标识用于所有权核对。结束后 `owned_postgres_stopped`、`port_released`、`owned_processes_exited` 均为 true；独立复查本轮 55591、55593、55597 均无监听且可复用。旧失败回执不因此改写。

`EnvironmentValidation` 实际采集与重验了成功的 W26 记录和失败的 W24 记录。最终成功 bundle 为 `artifacts/week26-current-environment-bundle/`；失败候选 bundle 为 `artifacts/week26-candidate-environment-bundle/`，其 v1 发行环境索引保持空列表，避免失败记录填满发行门槛。`report.json` 由原始证据重算，不信任缓存值。

全新 BEAM 在 DB/Scheduler 配置均为 true、PGPORT=65531 的条件下，完成计划、采集、重验与发行评估：应用和 Repo/Scheduler/RunSupervisor 未启动，**55 个模型、工具、SQL、进程和系统命令边界的计数全部为 0**。候选包内部输出路径被实际拒绝，未创建目录。原始证明为 `admission-probe.json`。

Elixir 与 Python 的 Linux core 计划同为 **9 条固定命令**，明确 `excluded_tags=["seatbelt"]`；这只是计划。macOS 上实际请求 Linux profile 被拒绝，未创建输出目录。真实 Linux 结果仍不存在，更没有完整 Linux 隔离证据。

共享开发库的 22 张表、18,722 行全列哈希前后一致，快照 SHA256 均为 `488b79123ea7388157fbd3b8370494c78151923c42934e0e6d9d48b2056b9017`。原 W22 包、rc.1 目录/归档、W24 证据/冻结源码及 W25 冻结源码、试读包与证据保持原样。既有 lib/config/priv/fixtures、依赖锁、迁移和原安装/CI 固定文件未改；8 个原测试仅修正临时目录的平台假设。权限、已用预算、绝对 deadline、unknown/reconcile、审批 hash 与 fencing 语义保持。

## 保留的三次实际失败

1. `artifacts/week26-environment-macos-warm/`：首次执行把 psql 的 passfile WARNING 合入身份 stdout，拒绝继续。分别处理 stdout/stderr、使用私有普通 passfile，并覆盖相关测试。现场核对 PID 70978、PGDATA、55593 和系统标识后仅停止该自有集群，证明在 `first-attempt-owned-cleanup.json`；原失败与 cleanup 字段未改。
2. `artifacts/week26-environment-macos-warm-final/`：W24 源码完整 1034 项通过，内存模式 **568/569、1 项失败**，为 IsolationDemo 的 controlled_file 探针。后续命令标为未执行，集群正常停止。独立诊断 `old-source-isolation-diagnostic-01/` 的 18/18 探针通过，但原测试 teardown 已删除临时执行回执，无法确定当时 status/errno/输出，**原失败根因仍未定位**；后验成功不覆盖原失败。
3. `artifacts/week26-current-environment-final/`：首次 W26 完整回归 **1092/1093、1 项失败**，新增候选集成测试在并行文件校验时触发 60 秒超时。改为模块串行，保留默认 60 秒和全部断言，永久补入候选包字节/模式不变断言后重新冻结、全量通过。原清理另有 port_released=false；后来端口确认为空闲。TIME_WAIT 可触发相同误报机制已通过真实套接字复现，检查改用 SO_REUSEADDR，仍拒绝活动监听器；不声称已经反向证明原误报的唯一原因。

执行器的空日志、信号退出码、超时、日志上限、SIGINT/SIGTERM，以及 Popen 创建/注册期间中断的进程泄漏窗口均有测试；保护覆盖固定可信命令的受管进程组，不宣称任意恶意后代进程清理。

## 待验收、已知限制与后续工作

- 冷安装 macOS：pending；新目录、新 PGDATA 和本机成功不等于新主机。
- Linux 适用执行与完整隔离：均未取得真实环境证据；core 排除不能解除原完整 Linux gate。仍需真实运行、无平台排除、18 个隔离探针与 12×20 矩阵才能评估 full。
- 真人试读：0，pending；fixture、审计与代理不计真人。
- 旧候选隔离失败：保留未定位问题；后续先完善失败回执保留，再以同源码多轮复现定位，不能写成已修复。
- 输入摘要和自报主机身份只提供来源/完整性记录，不认证发布者、机器或真实执行；预安装工具链不等于冷下载。

原完整 Linux 发行政策和候选包均保留，`evidence_complete=false`、`approval_recorded=false`、`release_ready=false`，未发布、未创建 tag。下一步按 [W27 计划](next-stage-plan.md)取得真实环境和读者记录；源码变动须新冻结、重跑适用验证，不能直接继承另一源码的通过数。

## 结果索引

`artifacts/week26-acceptance/` 保存准备记录、Python 专项、原始失败与独立诊断、两个 Linux 计划、平台拒绝、资源复查、共享库前后快照引用、采集/重验与发行评估报告。`evidence-index.json` 将这些原始材料、最终冻结源码及 bundle 逐文件绑定；独立审计见 `independent-audit.json`，交付后核验见 `final-delivery-check.json`。实际工作副本、安装缓存与保留的 PGDATA 不打包成“冷安装证据”。

独立审计 **8/8 组通过**；实际只读 CLI 与 API 报告逐项一致。文件清单、最终源码及历史材料保护均已核验。最终结果索引包含 1384 个普通文件、17,621,311 字节，另有 1 个受控 fixture 符号链接仅记录链接身份、不跟随读取；索引 SHA256 为 `d1b74b1cfd9c3411c6c7ddd0d565bbbbef874bb31303b014b13805b459d1b3f4`。
