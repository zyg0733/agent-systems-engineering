# 候选版本安装与运行操作

适用项目版本为 `0.1.0-dev`，W24 教学候选包标签为 `v0.1.0-rc.1`；`0.1.0` 是待验收目标。W24 候选创建时没有 Git 仓库；现已开始[本地首次入库准备](github-onboarding.md)，尚无发布 tag。W23 源码准备、W24 实际矩阵与包验证各有报告，不能互相替代，真实外部试读仍为 0。先读[公开入口](public-interfaces.md)、[候选交付](candidate-release.md)、[结果索引](results-index.md)与[已知限制](known-limitations.md)。

## 1. 固定安装输入

本项目已经验证的本机组合是 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。`.tool-versions`、项目 wrapper 与 bootstrap 对应这些版本；`mix.exs` 的语言兼容范围仍为 `~> 1.18`，不代表该范围内所有组合已被验证。

六个实际 Hex 锁定依赖为 Ecto SQL 3.14.0、Ecto 3.14.2、Postgrex 0.22.4、DBConnection 2.10.2、Decimal 3.2.0、Telemetry 1.4.2，完整校验值保留在 `mix.lock`。不要为完成演练运行 `deps.update` 或删除 lock。声明的本机缓存还包括 Hex 2.5.3 与 Rebar3；缓存 hash 校验完整性，不认证来源。

已有项目安装可先运行 `./scripts/postgres status` 与 `./scripts/mix --version`，确认项目 wrapper 实际选择的运行时。全新 macOS 目录需要 C 编译器、make、curl、tar、unzip 和 shasum：

```sh
sh scripts/bootstrap_runtime.sh
./scripts/mix local.hex --force
./scripts/mix deps.get
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
./scripts/mix setup
```

首次联网 `local.hex --force` 按当时 Hex 分发安装，不能称为由源码锁定的 Hex 2.5.3 重放。严格同宿主复现用 [L21](../labs/L21-reader-study-and-clean-reproduction.md) 的已声明工具缓存、provenance 与隔离构建步骤。bootstrap 使用固定上游版本 URL；PG 源码另验证官方 SHA 文件，OTP/Elixir archive 当前不具备独立签名认证流程。

Linux 可自备对应 BEAM/PostgreSQL。[CI 配置与日志](github-ci.md)声明 Ubuntu 24.04、相同 BEAM 与 `postgres:18.6` 服务，并编译项目内固定版本备份工具；当前本机验收不声称已执行 Linux CI。Action 使用 `checkout@v4`、`setup-beam@v1` 与 `upload-artifact@v4` 版本 tag，服务镜像使用版本 tag，均非 immutable digest 供应链承诺。隔离执行器只有 macOS Seatbelt 后端，其他宿主明确拒绝执行，不降级为无隔离。

## 2. 明确连接与应用配置

| 项目 | 默认或当前行为 | 操作要求 |
| --- | --- | --- |
| `LAB_DATABASE_ENABLED` | `true` | 内存实验用单命令前缀 `false`；完整 check 必须启用数据库 |
| `LAB_SCHEDULER_ENABLED` | `false` | 首次验收与维护保持关闭；启用前确认队列、预算及唯一执行所有者 |
| `PGHOST/PGPORT/PGUSER` | `127.0.0.1 / 55432 / postgres` | 核对实际 cluster/端口；不要把共享库当本轮新库 |
| `PGPASSWORD` | 未设置 | 以受控子进程环境提供；不写日志或报告 |
| `DATABASE_URL` | 未设置；设置时交给 Ecto URL 解析 | 与分项连接配置一起核查；独立复现明确 unset，避免连原库 |
| 数据库名 | `agent_systems_lab_dev` / `agent_systems_lab_test`，依 Mix env | check 使用 test；普通任务默认 dev；不能仅凭任务名猜测 |
| Repo | pool 10，`synchronous_commit=on` | 真实故障演练不关闭 durability 来提速 |
| Scheduler | max_workers 2、poll 100 ms、lease 5000 ms、renew 1000 ms | 这是默认值，不是所有负载的 SLA；调参不能绕过持久配额与 fencing |

`scripts/mix` 在本地运行时存在时优先使用它，否则落到宿主 Mix；它总把 cwd 设回项目根，并固定项目内 `MIX_HOME/HEX_HOME`。因此运行前确认 wrapper 所在副本，不在错误项目停止 PostgreSQL。工作区、隔离策略、MCP server 和审批身份由创建任务的宿主登记，不能从模型提示词中导入。

## 3. 首次启动与准备检查

```sh
./scripts/mix lab.release check
./scripts/mix lab.release plan
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
LAB_DATABASE_ENABLED=false ./scripts/mix lab.demo
```

前两项不启动应用；编译可能写 `_build`，但检查与 plan 不执行课程 argv、不连接数据库、不生成 tag。check 的 `source_ready=true` 只说明当前源码与受支持元数据一致；`release_ready=false`、`external_humans=not_assessed`、`week24_matrix=pending`、`tag=not_created` 保留未完成 gate。保存 JSON 与退出码，不能将 stdout 的版本 pin 误报为现场检测的运行时版本。

首次运行时 Mix task loader 可能先输出 `Compiling ...`，再输出一行 JSON。需要机器读取时先运行 `./scripts/mix compile` 并单独保存编译日志，或从成功命令的最后一行提取 JSON；同时保留原始 stdout 与退出码，不把整个冷启动输出直接作为 JSON 文件解码。

完整 `mix check` 会创建/迁移测试库、执行全部测试及两项 fixture 验收，故必须使用可写的实验数据库。内存模式只覆盖其适用子集，不能替代数据库回归。一次成功后若无源码变化或新失败，不反复重跑来筛选“幸运结果”；延迟波动仍保留真实比较结果。

## 4. 首个任务与阶段演示

先从 [课程地图](course-map.md) 选 C01—C12 的入口，按其前置知识运行现有 L01—L22，再做 [L23](../labs/L23-frozen-candidate-release.md) 综合冻结验收；课程号不等同于实验号。运行有产物的演练时使用全新目录，例如：

```sh
./scripts/mix lab.p1 --output artifacts/release-p1-unique
./scripts/mix lab.history --output artifacts/release-history-unique
```

保留原始 stdout/stderr、退出码、report/manifest、diff 和具体断言；不把仅有 `report.json` 当作通过，也不把相同文件 hash 当作来源认证。脚本模型验证机制，不比较真实模型能力。其余 P2/P3、隔离、MCP、DAG、审批、观测、评测和升级命令在[入口清单](public-interfaces.md#5-cli-清单与副作用)与对应实验中列出。

## 5. 事故、unknown 与恢复

先确认原 Run ID、数据库、seq、operation ID、claim generation、预算、deadline 与审批对象，再走[恢复手册](recovery-runbook.md)第 1—8 节只读采证；按 Run ID 查询可用 `lab.trace`，已提交 unknown 可用 `lab.reconcile` 列出。查询不等于续跑，缺少 ACK 不等于失败，租约过期不证明外部效果未发生。

`Recovery.resume/2` 只用于创建时登记的原 Run，保留已扣额度与绝对截止时间。可查询工具按原身份核对；不可查询或非幂等的模糊效果留在人工队列，收集真实证据。不要重新 create、换 operation ID、重置预算、手改历史、删除坏 checkpoint 或盲目重发来消除 blocked。

需要后台执行时依手册第 9—12 节启停、租约与数据库断连流程。`status` 不暂停 Worker；停止当前 Coordinator 也不等于持久取消父图。审批对象走 Approvals；产物改变后旧批准失效，release 必须重验 hash，且不会自动发布或应用补丁。

## 6. 备份、升级与回退

按[恢复手册第 19 节](recovery-runbook.md#19-历史迁移版本兼容与备份还原)与 [L20](../labs/L20-history-migration-backup-restore.md) 执行：停止相关调度与手工驱动，确认无活动 Worker，记录原迁移/版本、Run seq、工作区、审批 subject、预算和 deadline。先只读 proof，再备份到私有目录；新 restore 默认只读，比较完整数据库事实后通过 RestoreGuard 撤销复制 claim，再显式激活。

数据库备份不含文件工作区、外部效果、角色、tablespace 或 WAL；它不能独自恢复文件和业务权限。当前 capability 只在创建它的主 BEAM 中有效，不支持把重启后磁盘 archive 直接重新登记为任意可信 Bundle。历史 layout 1→2 迁移与 SQL DDL、Kernel schema、Codec 是不同版本域，不改列号假装兼容。

失败时保留源库、只读目标、错误和 archive。需要回退代码时，先确认旧读者确实支持目标历史与 schema；当前没有通用 down-migration 或一键降级承诺。若源库仍是可信原状态，选择单一源端恢复原执行入口；目标激活后要处理已有效果，不能简单切回旧库制造重复。恢复阶段崩溃按原 proof/fencing 流程重新生成新受管目标，不手动解除 gate。

只用精确 capability+owner marker 清理本轮实验库；不要 force drop、按名前缀批量删除、终止其他用户连接，或停止共享 PostgreSQL。只有确认独立导出的 PGDATA 属于本轮，才从那个副本执行 `./scripts/postgres stop`；保留停止与端口释放证据。

## 7. 源码导出与发布移交

[L21](../labs/L21-reader-study-and-clean-reproduction.md) 的 Reproduction 以 allowlist 导出源码，排除 `.git/.runtime/deps/_build/artifacts/cover`，固定 manifest 的 hash、模式和大小。使用缓存要声明来源，重新安装 runtime、编译 PG 新 prefix/依赖并初始化新 cluster。W22 证据只支持同宿主 warm cache 新构建，不能写成新机器、冷下载或多 OS 验收。

[L22](../labs/L22-release-readiness.md) 核对接口、版本、30 张章卡与 12 次课程入口；[L23](../labs/L23-frozen-candidate-release.md) 执行冻结矩阵和教学候选包验收。W22 冻结试读包保持其原协议，不把新源码覆盖进去复用旧反馈；真人现为 0 人，P5 外部准入仍待验收。每轮新源码都重新生成自己的导出与证据，保留失败记录和当前限制。

## 8. W24 冻结与候选包操作

按 [L23](../labs/L23-frozen-candidate-release.md)先冻结源码，记录实际 runtime/PG 身份，再对同一源码完成全量/内存回归、F01—F12 各 20 次和已选择的核心演练。矩阵 `run` 真实执行业务、信号与连接故障；`plan`/`verify` 不启动应用。关闭全局 Scheduler，不并行运行其他重故障演练；不要为了缩短时间减少轮次或改 durability、预算、lease/fencing 语义。

可信宿主准备全新绝对路径 `matrix_output`、`evidence_input`、`candidate_output`，固定入口为：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze plan
LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.freeze run --output "$matrix_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze verify --output "$matrix_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate build --output "$candidate_output" --evidence "$evidence_input"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate verify --output "$candidate_output"
```

矩阵报告 `complete/all_passed` 与逐行证据都必须成立；复合子探针数量不替代 12×20。候选构建校验固定证据 schema、源码身份、完整/内存日志与矩阵，拒绝已有目标、漂移、缺失和不兼容输入，不执行数据中的路径或命令。源码检查 `lab.release` 仍固定返回其 W23 范围的待验收项，W24 实测状态从新报告读取。

包根是项目目录，根入口 `START-HERE.md` 与 `candidate-evidence/index.json` 不依赖作者机器路径；排除 runtime、deps、build、PGDATA、既有开发库备份、凭据和原反馈。本轮受管合成升级库 `.dump`、P2 `.bin` 和 `.jsonl` 只作为有界惰性字节证据纳入，不执行、反序列化或导入；archive 不携带原主 BEAM capability，不能直接作为可信 restore 输入。索引列明故意的隔离符号链接、无扩展名 native 探针与缓存等排除项，原始实验目录保留。

宿主仅从已验证文件集合生成 `.tar.gz` 与 `.sha256`，新解压目录再次核对集合并验证包。编译可能写 `_build`；归档 checksum 不是来源认证。

候选身份 `v0.1.0-rc.1` 明确是 manifest label，不是 Git tag；项目继续为 `0.1.0-dev`。技术候选状态与 `release_ready=false`、0 名真实读者、Linux 待验收同时保留。失败保留原目录和原始日志；所有权不明时先采证，不停止共享 PG。最终派生实测见 [W24](validation-week24.md)，未完成项见[backlog](backlog.md)。

## 9. W25 同源码试读与发行评估

按 [L24](../labs/L24-versioned-release-assessment.md)和[发行评估操作](release-assessment.md)建立新材料。先核对旧 rc.1 与 W22 原包完整性，再显式选择已经验证的冻结源码；不要从变化后的工作区默选源码或复用旧 protocol。可信宿主设置全新的绝对输出路径：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen prepare --source "$frozen_source" --output "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output"
```

新试读 `add` 保存原始反馈字节，`append` 追加 fix/retest，`report` 只读重算。修复须原读者针对最近 fix 成功复验才关闭；改包内源码/章稿须新冻结、新协议及适用复验。锁、链或 head 不一致时保留现场并停止，不自行删锁或重写历史。报告/证据中的文本和路径不执行。

发行评估保留既有 3—5 名真人、固定主实验、冷 macOS 主机和完整 Linux 隔离/冻结门槛；缺少外部材料继续 pending。已有原始日志与完整受界环境证据时才增加 `--evidence "$external_evidence"`，Linux 子集不能冒充完整覆盖。自报不认证真人、机器或执行；hash 只绑定字节。`evidence_complete`、批准记录、发布状态分别评估，本工具不执行批准或发布，不改变旧候选。原权限、已用预算、deadline、unknown、审批 hash 与 fencing 始终保持。

## 10. W26 跨环境执行与证据移交

按 [L25](../labs/L25-cross-environment-validation.md)与[跨环境操作](cross-environment-validation.md)选择显式冻结 source。`lab.environment plan` 是惰性计划；Python `scripts/environment_validate.py run` 是固定命令执行器，真实启动进程、独立 PostgreSQL 和实验；`lab.environment collect/verify` 只读取有界材料，不执行 argv、不启动业务或连接 PG。三个边界不能互相替代。

从可信 W26 工具宿主控制，在新工作副本执行被测源码。rc.1 是旧 W24 身份，其 project 没有 W26 CLI；当前 W26 新源码不能绑定旧候选。实际 macOS warm-cache、真实新主机 macOS cold、Linux core 分别记录，来源包含安装输入/hash、缓存复用、工具身份、退出码、日志和精确 cleanup。

Linux 核心测试排除 Seatbelt 不关闭原完整隔离门槛；没有实际新主机/Linux 就继续 pending。新输出不覆盖旧材料，结束只按 PGDATA/PID/端口绑定停止本轮集群并确认端口释放，不停止共享 55432 或删除旧库。采集错误保留输入和日志，不能改成功字段。将符合原 v1 合同且同源码的 bundle 交给只读 `lab.release.assess`；退出 0 仍需查看 gate，不能据此批准或发布。实测与剩余外部门槛见 [W26](validation-week26.md)。
