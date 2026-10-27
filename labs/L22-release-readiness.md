# L22：公开入口、版本与课程发布准备

对应 W23，前置 L01—L21。本周将已有运行时整理成可核对的教学候选：接口边界、固定版本、完整运行操作、30 张章节卡与 12 次课程入口。原计划 W24 的最终故障矩阵、冻结、tag 和发布决定仍待后续执行；本实验不新增业务 Agent 功能，也不把待完成的真人试读写成通过。

先读[公开入口](../docs/public-interfaces.md)、[运行操作](../docs/release-operations.md)、[已知限制](../docs/known-limitations.md)、[30 张章节卡](../book/chapter-cards.md)、[课程地图](../docs/course-map.md)和 [ADR 0022](../docs/adr/0022-release-readiness.md)。当前项目版本保持 `0.1.0-dev`，`0.1.0` 是目标而非现有发布。

## 1. 判断入口是否会执行

从公开接口表各选一个：只读业务查询、宿主文件准备、会执行业务的入口。写下它是否启动应用、是否可能受全局 Scheduler 影响、是否连接数据库、是否写输出。特别区分 `lab.reconcile` 列队列与 `Recovery.reconcile/2` 实际查询；`lab.rebuild` 重建与 `Recovery.resume/2` 续跑；`Approvals.release` 获批字节与真正发布。

检查 Provider 的 `respond/2`、`stream/3` 与工具 result envelope。当前 Provider behaviour 不意味着 RunServer 接受任意 module，固定工具目录也不等于具备任意 Tool 自注册 API。说明新接入为何还需权限、预算、录制、错误和 unknown 测试。

## 2. 执行源码准备检查

无需 PostgreSQL，命令只编译并读取受支持源码元数据：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release check
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release plan
```

不接受额外参数或任意 manifest/path 注入。`check` 核对固定 inert manifest、文件 hash、版本 pin、21 个迁移、30 张章卡、12 次课程与文档入口；失败以非零退出并保留原因。它不执行课程命令，不启动 Repo/Scheduler，不安装 runtime，也不验证本机实际运行时版本。Mix 编译可能写 `_build`。

保存 stdout JSON 和退出码。成功报告应有 `schema_version=1`、`source_ready=true`、当前/目标版本、runtime pins、独立 schema 版本、migration/course/chapter 数、manifest/source checks hash。仍须有 `release_ready=false`、`external_humans=not_assessed`、`week24_matrix=pending`、`tag=not_created`。前一个 bool 不能覆盖后面的未完成事实。

冷启动可能由 Mix loader 先打印编译进度。机器解析前可单独执行 `./scripts/mix compile`，或在检查成功退出后提取末行 JSON；原始日志仍需完整保留，不能把编译提示当作损坏报告或忽略失败退出码。

`plan` 输出固定课程 argv 与待验收 gate；它是数据，不是自动执行器。人工查看每条固定课程测试入口、前置知识与现有 L 编号，不能从任意报告/反馈字符串拼接 shell 命令。将计划写到包外证据目录后，由可信宿主显式选择执行。

## 3. 核对版本域与依赖

比对 `.tool-versions`、`mix.exs`、`mix.lock`、bootstrap/wrapper、CI 与 [release manifest](../fixtures/release/manifest.json)。语言范围 `~> 1.18` 不等于已测试矩阵；本机实际验证的固定组合为 Elixir 1.20.4 / OTP 28.4 / PostgreSQL 18.6。CI runner 与 Action tag 不是 immutable binary 身份。

解释为什么 Kernel/Event schema 1、Codec 1、history layout 1/2 与项目 `0.1.0-dev` 可以同时成立。W23 不添加第 22 个 migration，不改旧文件 hash 来“更新”数据库，不覆盖 W22 冻结试读包。若 pin 意外漂移，应调查来源；不要仅为让 check 成功自动重写 manifest。

故障探针由新测试在临时副本中完成：缺失/未知 manifest 字段、版本与 checksum 漂移、迁移增删、无效课程/章卡关联、链接/超限/源码边界输入均应明确拒绝，并且不启动模型、工具或数据库。不要为了练习直接修改工作目录中的原 migration 或旧证据。

## 4. 检查课程与章节产物

30 张章卡应逐章有问题、学习目标、前置知识、源码/实验入口、练习、验收标准及能力边界；卡片不替代正文。当前全书 30 章正文草稿另见[阅读路线](../book/reading-route.md)与[全书复核](../docs/book-completion-review.md)，原六章试读正文仍按此前冻结身份保留。12 次课程是现有 L01—L22 的教学路径，不能把 C12 写成“只运行 L12”，也不能以课程测试 argv 代替实验里的真实 OS/数据库故障演练。

选择一条课程，沿所有本地链接读取相应章卡、实验、解答和源码；确认参数确实受当前 CLI 支持。对照运行操作说明安装输入、配置、首次启动、事故核对、备份还原和回退；若发现遗漏，补文档并重新检查源码候选。

## 5. 全套回归与语义保护

在已明确身份的实验 PostgreSQL 上关闭全局 Scheduler：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

完整 check 包含数据库创建/迁移与所有测试；内存模式按既有 tag 排除数据库用例。保留实际数量与日志，不照抄前周通过数。W23 新工具不得引入任意命令执行、反馈执行、业务写入、权限变更、预算重置、unknown 自动确认、审批绕过或旧 claim 的迟到提交。

已有 P1/P2/P3/P4、评测、升级与 W22 复现证据可作为来源明确的历史证据；不能把它们的日期、源码身份或次数改成本周重跑。W24 最终完整矩阵仍需针对届时冻结候选实际执行，不能因本周 regression 通过自动盖章。

## 6. 移交与验收

保存本周 check/plan JSON、格式/编译及测试日志、文档链接核查和当前限制，核对原业务模块、SQL migration 与依赖未被无关改动。最终清单应写“W23 技术准备通过，正式发布 gate 待验收”，明确 0 名真人反馈与 P5 外部 gate 未通过。

本周不打 tag、不上传发行包、不发布服务，也不重建虚构真人记录。后续从同一候选或明确新候选完成外部反馈和 W24，重新绑定源码/测试/故障矩阵，再由宿主作发布决定。实际执行结果见[W23 验收](../docs/validation-week23.md)，判断参考见[解答](solutions/L22.md)。
