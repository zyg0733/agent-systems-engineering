# 第 23 周验收记录

验证日期：2026-10-23（Asia/Shanghai）。本周按原计划整理接口、锁定版本、补齐操作手册、12 个课程单元及 30 张章节设计卡。**技术准备与回归通过**；代码版本保持 `0.1.0-dev`，目标 `0.1.0` 尚未发布。W22 真实外部读者仍为 0，P5 外部准入待验收；W24 冻结矩阵、候选标签及正式教学发布另外验收。

配套 [L22](../labs/L22-release-readiness.md)、[参考解答](../labs/solutions/L22.md)、[ADR 0022](adr/0022-release-readiness.md)、[公开接口](public-interfaces.md)、[发布操作](release-operations.md)、[已知限制](known-limitations.md)与[运行手册第 21 节](recovery-runbook.md#21-发布准备版本契约与课程入口)。

## 交付与接口整理

| 交付 | 实际结果 |
| --- | --- |
| [课程地图](course-map.md) | C01—C12 对应原计划十二主题，完整覆盖实际 L01—L22；每单元含统一源码起点、学生任务、解答、固定测试 argv、成功标准及平台要求；不虚构历史 Git 起始标签 |
| [章节设计卡](../book/chapter-cards.md) | 原七篇三十章，每卡含目标、前置、真实源码、实验、3 道习题及教师答案、证据、状态；6 个 draft、24 个 design_card，不计为三十章正文完成 |
| [公开接口](public-interfaces.md) | 30 个实际 `lab.*` CLI 与教学 API 清单，区分读取、宿主文件操作、业务执行和内部函数；核实 arity 与结果配对 |
| [ReleaseReadiness](../lib/agent_systems_lab/release_readiness.ex) | 有界、只读源码检查及固定计划；不启动应用、不查询数据库、不执行课程命令；固定返回 `release_ready=false`，不替代真人与 W24 gate |
| [版本清单](../fixtures/release/manifest.json) | 13 个关键源码/配置 pin + 21 个 migration 的 SHA-256、bytes、mode；固定课程/章节身份及独立版本域；不执行 mix.lock 或其他源码来读取版本 |
| CI | 固定 `ubuntu-24.04`，保留已有 OTP/Elixir/PG 版本，在原 full check 外加入 source readiness 和内存回归；本轮未执行远端 Linux CI |

接口核对明确两项现有限制：Provider behaviour 不是当前 RunServer/Recovery 的任意模块注入 API；工具也没有通用自注册 behaviour。扩展仍须修改可信宿主适配并验证权限、预算、调用配对和恢复合同。本周没有为“整理接口”重写旧执行逻辑。

课程实际顺序为 C01—C06 → C07 的 L10 → C08 的 L11 → C07 的 L12/L13 → C09—C12，以满足 lease/fencing 到背压/断连的前置依赖。课程编号和原连续实验编号分别保留。

## 版本与准备检查

```sh
./scripts/mix lab.release check
./scripts/mix lab.release plan
```

检查核对 **261 个关联源码/文档/测试文件**、13 个 pin、21 个迁移、30 张卡、12 个课程入口；固定版本为 Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6，Kernel/Codec 1、history layouts 1/2。六个锁定 Hex 依赖、`mix.exs`、`.tool-versions` 和旧引导脚本不升级。不能把该源码检查当成对安装环境或数据库兼容性的检测。

实际验收另保存了 [Elixir/OTP 输出](../artifacts/week23-acceptance/runtime_version.log)、[安装 OTP release marker](../artifacts/week23-acceptance/otp-release-observation.json)及 [PG binary version](../artifacts/week23-acceptance/postgres_binary_version.log)。marker 内容为 28.4，Elixir 为 1.20.4，PG 二进制为 18.6；这些是现场观测，不是上游包签名认证。

正式 [check 日志](../artifacts/week23-acceptance/release_check.log)与 [plan 日志](../artifacts/week23-acceptance/release_plan.log)中：`source_ready=true`、`release_ready=false`、`external_humans=not_assessed`、`week24_matrix=pending`、`tag=not_created`。准备检查不读取旧真人报告来自动批准发布，也不创建标签。

manifest 文件 SHA-256 为 `cd0f25e40ad2e2b3dd19cb1b08fb1d84a0ab412096d6f84c3fdfc46b46c055e4`，261 文件检查 digest 为 `38189d9d7f40f627f3c8deb26942cf67bce91ce35233a1c20fdead27453f1129`。这两个身份在完整与内存回归后的 [recheck](../artifacts/week23-acceptance/release_recheck.log)完全相同。

冷启动 Mix 可能在 JSON 前打印正常编译信息。原首启输出保留在 [first-launch](../artifacts/week23-release-source-check-first-launch.log)；自动验收先独立编译并保留全部 stdout/stderr，解析成功退出后的末行 JSON，不把编译横幅当成任务执行或无效 JSON。

## 新增测试与完整回归

```sh
./scripts/mix test test/agent_systems_lab/release_readiness_test.exs
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

新增 **33 项专项**：普通环境 33/33（5.6s），`umask 077` 下 33/33（5.3s），见 [umask 日志](../artifacts/week23-release-focused-umask077.log)。覆盖完整/缺失清单、固定版本/门槛/命令篡改、源文件漂移、迁移增删、脚本执行位、空章节字段、问题/教师答案配对、破损或越界源码链接、缺失课程入口/命令、文件上界、符号/硬链接与新 VM 无应用启动。

| 正式回归 | 实际结果 | 日志 |
| --- | --- | --- |
| 完整 `mix check` | **1010 passed**，1008 tests + 2 doctests，0 失败；ExUnit **151.8s**，整条命令 152.557s | [full_check](../artifacts/week23-acceptance/full_check.log) |
| 无数据库模式 | **547 passed**，545 tests + 2 doctests；**463 个数据库用例排除**；ExUnit **30.3s** | [memory_check](../artifacts/week23-acceptance/memory_check.log) |

1010 = 原 W22 的 977 + 新增 33；547 = 原内存 514 + 新增 33。旧用例、超时、比较门槛和业务预算均未改。完整 check 包括格式、warnings-as-errors、测试库迁移、全部 W1—W23 用例、原 **10/10 fixtures** 和创建/更新两类操作的四个真实 COMMIT 前后 kill 窗口。463 个数据库用例已经在完整 check 运行，内存排除数不算通过数。

正式 [execution.json](../artifacts/week23-acceptance/execution.json)记录 **9 个固定步骤全部退出 0**：现场版本、编译、check、plan、只读探针、完整回归、内存回归、最终 recheck。执行驱动不启动、停止或删除共享 PostgreSQL。

## 只读与源码副本实证

在全新、未启动业务应用的 BEAM 中，用实际加载配置 `LAB_DATABASE_ENABLED=true`、`LAB_SCHEDULER_ENABLED=true`，并给出非业务数据库端口，执行公开 check/plan。结果见 [readonly-probe.json](../artifacts/week23-acceptance/readonly-probe.json)：

- 前后业务应用均未启动；Repo、Scheduler、RunSupervisor 均不存在。
- 对 **55 个**模型、工具、恢复、审批、观测、评分、应用/Repo 启动、SQL 和进程启动入口启用真实 call_count，全部为 **0**。
- 将完整 **488 个文件**仅源码导出到全新私有目录；不复制 runtime、deps、build、PGDATA 或原 artifacts。对副本 check，结果与原目录一致，之后 Reproduction.verify 确认源码 bytes/mode 不变；只删除本次临时副本。

这是源码副本与只读行为核验，没有把本周描述为新 runtime、冷机器、Linux 或新 PostgreSQL 全套复现。W22 的同宿主 warm-cache 干净构建证据仍保留原范围。

另一次独立代理的源码副本探针见 [independent-source-export-probe](../artifacts/week23-independent-source-export-probe.json)，它针对稍早的文档快照；不将其 hash 冒充正式最终候选。章节与课程作者另核对 370 个本地链接及 66 个显式函数符号/arity；接口手册核对 30 个 CLI 集合及主要函数和回调。

## 独立文件审计与数据保护

[独立 Python 审计](../artifacts/week23-acceptance/audit.py)实际 **483/483 通过**，见 [audit.json](../artifacts/week23-acceptance/audit.json)。脚本只读文件，独立重算 pin、mode、261 文件 digest 和日志 hash，核对课程/章节、测试尾行、固定计划、源码副本、旧数据与旧试读包。它不导入项目代码、不执行子进程、SQL 或反馈；55 个零调用和无应用启动来自实际探针的保存证据，不伪称审计再次执行了它们。

证据索引 [evidence-manifest.json](../artifacts/week23-acceptance/evidence-manifest.json)绑定 **31 个文件**，文件 SHA-256 为 `986ba58d5ffc0c71832cf516ea369ac9e9d461a024dadb5ca22bd342904e5c40`。

原 [475 文件基线](../artifacts/week23-source-before.json)与 [488 文件执行候选](../artifacts/week23-acceptance/source-before.json)对照，新增 4 个核心工具/测试/套件文件及 9 个教材/操作/验收文件。核心源码范围由 369 增至 **373**。既有文件只有 README、recovery-runbook 和 CI 改变；旧 lib/config/test/priv/scripts/fixtures、所有 21 个 migration、mix.exs 与 mix.lock 的 bytes/mode 全部保持。执行结束时 [488 文件核验](../artifacts/week23-acceptance/source-after-check.json)无漂移。

本记录是在执行后补录的派生文档，冻结执行候选中的副本保留执行前说明；最终只有本文件发生这一预期变化。源码准备所检查的 261 文件不包含本派生记录，因此其 digest 不被结果补录循环影响。

既有开发库 **22 张业务表、18,722 行**全列行 hash 前后相同，见 [comparison](../artifacts/week23-main-db-comparison.json)。before/after 文件 SHA-256 均为 `488b79123ea7388157fbd3b8370494c78151923c42934e0e6d9d48b2056b9017`。原 Run、Event、回执、unknown 核对、预算和审批未改写。

W22 正式试读包 **480 个文件** bytes/mode/hash 完全不变，feedback 目录仍为空；真实读者 0、P5 外部 gate false。没有覆盖旧包、挪用旧协议、生成真人反馈或根据技术通过自动批准发布。

## 修订与待验收项

开发专项发现并修正了 Unix 根路径拼接、读取自身改变 atime 的比较，以及仅检查标签导致空内容/坏入口误通过的问题。稳定文件检查只排除读取造成的 atime，仍核对 inode/device/type/size/mode/mtime/ctime/nlink；加入有界实际读取、内容与链接校验。执行位漂移单列测试，防止脚本字节相同却无法启动时仍报告 source ready。正式完整与内存运行各一次通过，没有修改旧运行时以消除失败。

已知限制继续保留：Provider/工具不是通用插件平台；隔离仅已验收 macOS Seatbelt；备份只含数据库；非幂等模糊结果须核对；hash 不认证来源；action 和镜像仍为版本 tag；未执行 Linux CI、外部 3–5 人试读或 W24 至少 20 次建议冻结故障矩阵。原权限、已扣预算、绝对 deadline、unknown/reconcile、产物绑定审批和 fencing 由原实现及全部回归继续维持。
