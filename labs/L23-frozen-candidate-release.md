# L23：冻结验收矩阵与 v0.1 候选教学材料

对应 W24，前置 L01—L22。任务是在同一冻结源码上执行原计划 12 类故障各至少 20 次，校验完整/内存回归，打包 12 个课程单元、30 张章节卡、六章试读稿与证据。当前项目版本保持 `0.1.0-dev`，`v0.1.0-rc.1` 是本地候选包标签；没有 Git tag，也不自动上传、部署或转为正式发行。

先读[候选说明](../docs/candidate-release.md)、[结果索引](../docs/results-index.md)、[已知限制](../docs/known-limitations.md)、[后续清单](../docs/backlog.md)和 [ADR 0023](../docs/adr/0023-frozen-candidate-release.md)。真实外部读者仍为 0；按既有决定先交付试读包与技术验收，P5 外部准入另行完成。

## 1. 冻结源码和环境

先完成所有代码、测试和静态文档，再用 `lab.reproduce export` 导出全新私有源码副本，保存 source manifest。不要把原 `.runtime`、`deps`、`_build`、PGDATA 或 artifacts 复制成所谓干净源码。独立安装/构建应按 [L21](L21-reader-study-and-clean-reproduction.md)记录来源与环境；复用声明缓存也必须照实写明，不能称冷机器。

确认实际 Elixir/OTP/PG 版本、数据库 system identifier、地址、PGDATA、`fsync/synchronous_commit/full_page_writes`、可写实验库和本轮资源所有权。保留 `LAB_SCHEDULER_ENABLED=false`，避免全局 Scheduler 与故障探针争用。不要停止共享 PG、按库名前缀删除、杀不明 PID 或临时关闭 durability 提速。矩阵固定执行可信 fixture，不接入真实模型或真实外部业务目标。

从冻结副本运行，记录 cwd、argv、开始/结束时间、退出码、源码身份及日志 hash。矩阵运行中不修改源码；发生修订后明确新身份和受影响验证，保留原失败证据。不要并行启动另一组重负载故障演练，让短 lease 测量混入无关压力。

## 2. 读计划，再实际执行固定矩阵

纯计划无需 PostgreSQL，不启动应用，不执行其 JSON 中的文字或命令：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze plan
```

对照原[路线第 8 节](../Agent%20Systems%20Engineering%20研究与落地计划.md#08-十二个实验与故障验收)，在实验报告中逐行预测：

| 行 | 故障点 | 需要检查的事实 |
| --- | --- | --- |
| F01 | 本地事务提交前 | Run/Event/调度意图无半笔提交；保持原状态或完整新事实 |
| F02 | 提交后通知前 | 不发显式 wake，周期扫描仍发现已提交任务 |
| F03 | claim 后工具执行前 | 当前进程失效后，等待 lease 到期可接管，不永久悬挂 |
| F04 | 外部效果成功后回执前 | 丢响应再 kill；幂等 Mock 效果为 1，不可查询动作保持可见 unknown |
| F05 | 保存工具结果后下一轮前 | 新应用进程使用已录制结果继续，已确认工具不重做 |
| F06 | lease 到期后 | 真实 SIGSTOP、接管、SIGCONT；旧 claim 迟到提交被拒 |
| F07 | 同一逻辑操作并发提交 | 每轮 100 个同 operation ID 同参数请求，台账唯一、逻辑结果相配 |
| F08 | 同 key 改参数 | 并发的不同 args hash 明确冲突，不复用错回执 |
| F09 | 重试持续失败 | 有限次数/时间预算耗尽后停止，无热循环、不退款 |
| F10 | 审批后产物改变 | 实际改变产物或基线后旧批准失效，不发布变更字节 |
| F11 | 数据库短暂不可用 | 受控连接故障恢复后已提交事实仍在；未确认不能虚报完成 |
| F12 | 版本不兼容 | 支持的事件正常重建；未知 Event schema、history layout、Codec 与兼容版本明确拒绝，不静默解释；旧布局迁移另由升级实验验证 |

在宿主核实的全新绝对路径设置 `matrix_output`，执行：

```sh
LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.freeze run --output "$matrix_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze verify --output "$matrix_output"
```

`run` 真实启动业务应用、访问实验 PostgreSQL、执行固定工具/文件/审批和 kill、信号、代理断连场景；不是只读 check。固定每行 **20 次**，不提供减少次数的 `--repetitions` 或任意场景/命令入口。F01—F12 合计 **240 个行级 observation**；已有 P2、fencing、DB 等组合探针会额外生成实际子窗口，不把子探针总数当作“每类都运行过 20 次”。原有 2 次、旧周 20 次和本轮次数分开。

`verify` 只对保存文件做有界 schema/hash 校验，不重跑故障、不调用数据库或模型/工具。退出 0 后还应阅读 `report.json` 的 schema、`complete`、`all_passed`、全部行和逐轮证据，并检查外层执行索引把该报告 hash 绑定到冻结源码身份。断言未知或缺项不能以默认 true 补齐。报告或产物缺失时保留失败，不用手改 JSON 成功值修补。

逐行记录零重复效果、零丢失已确认任务、零旧 token 覆盖的具体证据。unknown/manual 是正确的可见保守结果，不能为追求终态成功而重发非幂等工具；取消不撤销效果。20 次是这组受控测试的门槛，不是任意远端服务的 exactly-once、生产 SLA 或全时序证明。

## 3. 全量回归与核心教学路径

在同一源码身份上运行并保存完整原始日志：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

读取真实 tests/doctests、0 失败和数据库排除数。完整 check 包括格式、warnings-as-errors、测试库迁移、全套测试、原 fixture 和真实 COMMIT 窗口；内存排除不计通过。不要照抄 W23 数量。若同配置延迟跨过原性能门槛，保存真实 regression；语义/成本可重复不意味着耗时相同，也不能放宽门槛使候选变绿。

沿 [C01—C12](../docs/course-map.md)读取学生任务、参考解答和验收命令，再对本轮实际选择的 P1、history、调度/负载、隔离、MCP、DAG、审批、观测、评测、升级逐项保留新目录和报告。固定矩阵不代替所有课程练习；旧实验记录不得改成本周重跑。平台不支持隔离时明确拒绝，不降级成无隔离后声明完整通过。

核对本周未改业务模块、21 个 SQL migration、依赖锁、版本域、权限、五维预算、已用额度、absolute deadline、结果配对、unknown/reconcile、审批 subject/hash/generation 和旧 claim fencing。保存开发库事实与旧 W22 试读包的前后保护证据，不能覆盖旧包再复用其协议。

## 4. 构建与验证教学候选

可信宿主将本轮实际执行、全量/内存日志、矩阵和有界结果按 [CandidatePackage](../lib/agent_systems_lab/candidate_package.ex) 的固定证据 schema 整理到独立 `evidence_input`，先核对其文件、退出码、源码绑定和相对路径。任意 report 的自由文本都不能转成命令。输出使用全新绝对路径 `candidate_output`：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate build --output "$candidate_output" --evidence "$evidence_input"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate verify --output "$candidate_output"
```

两者不启动业务应用或数据库；构建只导出 allowlist 源码和受校验证据，验证只读。包根即项目根，包括 `START-HERE.md`、`candidate-manifest.json`、`reproduction-source-manifest.json` 和 `candidate-evidence/index.json`；不要求原作者机器路径。包外宿主另打 `.tar.gz`、计算 `.sha256`，解压到新目录后，从准备好的可信工作目录指向该候选再验证，确认解压字节与已验证文件集合一致，不把 runtime、PGDATA、既有开发库备份、凭据或旧个人反馈带进包。保留未改候选，另建工作副本安装和运行；在待验包内先编译会增加未声明 `_build`，严格候选校验应拒绝。

本轮受管合成升级库的 `.dump` 可以作为有界字节证据纳入，P2 `.bin` 和 `.jsonl` 分别为惰性状态与日志；不执行、反序列化或导入。复制 `.dump` 不携带原主 BEAM capability，不能直接登记为可信 restore 输入。索引记录故意的隔离符号链接、无扩展名 native 探针和缓存等排除项，原始实验目录继续保存。

核对 `candidate_label=v0.1.0-rc.1` 与 `candidate_label_kind=local_manifest_label_not_git_tag`。`technical_candidate_ready=true` 必须依本轮完整证据；同时保留 `release_ready=false`、`external_humans=0` 和 `linux_validation=pending`。源码 `0.1.0-dev` 不自动改成 `0.1.0`。真实 Git tag、上传与正式发布另需明确操作，包 label 不充数。

对篡改、缺日志、未知字段、少轮次、源码不匹配、链接、已有输出和超限的拒绝测试应在私有临时副本运行，不改正式材料来演示失败。核对验证前后业务应用未启动与敏感执行入口零调用；“Mix 没有启动应用”仍不等于编译没有写 `_build`。

## 5. 提交与自评

提交源码 manifest、固定 plan、逐轮矩阵、真实回归、核心结果索引、包验证、归档 checksum、限制/backlog 与资源清理记录。最终实测写进包外派生验收文档；不反向修改冻结源码。使用包内相对路径，原日志中的旧 cwd 只作来源，不成为读者运行前提。

按[参考判断](solutions/L23.md)逐项解释：一次通过说明了什么、哪条证据证明没有重复效果、哪些故障只覆盖连接代理而非 PG 介质损坏、为何旧 Worker 醒来仍无资格、为何 0 人试读不能自动变成 P5 通过。实际本轮结论见 [W24 验收](../docs/validation-week24.md)；运行中断按[恢复手册](../docs/recovery-runbook.md)先确认所有权和原 Run，再继续或精确回收本轮资源。
