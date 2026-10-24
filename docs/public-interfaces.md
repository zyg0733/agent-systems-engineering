# 当前公开入口与兼容边界

适用工作区版本：`0.1.0-dev`，W26；历史候选 rc.1 保留原合同。计划中的 `0.1.0` 尚未发布。本页整理实验支持的调用入口，不承诺所有 Elixir 模块、结构体或错误元组已经成为稳定的通用 SDK。源码版本、持久化版本和实验报告版本分别管理；发布准备检查通过也不改变它们。

## 1. 可信宿主与模型的边界

CLI、IEx、SQL 连接、工作区根、审批身份和策略都由可信宿主选择。模型只能提出已广告工具的调用，不能执行 Mix 命令、登记 Provider、扩大文件/网络权限、修改预算或认领审批。文档中的命令应在已核实的项目目录与数据库执行。

本页把入口分为三类：可信宿主的教学 API；Provider/工具的数据与回调合同；实现内部模块。`def` 可见不代表宿主可以绕开协调器、锁、claim 或事务直接修改内部账本。

## 2. 教学 API

下表列出实际存在的主要函数。`/2,3` 表示两个 arity 均由默认参数提供。完整 option、返回类型和错误以链接源码及对应实验为准；调用者应处理 `{:error, reason}`，不要把列举的错误当作穷尽的枚举。

| 入口 | 当前支持的主要函数 | 执行语义 |
| --- | --- | --- |
| [AgentSystemsLab](../lib/agent_systems_lab.ex) | `start_run/1` | 在应用 Supervisor 下创建逐步驱动 Run；默认内存模式；不是持久恢复接管入口 |
| [RunServer](../lib/agent_systems_lab/run_server.ex) | `snapshot/1`、`step/1`、`start_stream/1`、`subscribe/1`、`append_message/3`、`command/2`、`cancel/1,2`、`run_until_pause/1,2`、`reconcile_from_mock/1` | snapshot 读取；step/stream 会执行；通知为易失预览；取消不撤销效果；mock 核对只针对本地 Mock |
| [Recovery](../lib/agent_systems_lab/recovery.ex) | `create_run/2,3`、`load/1`、`resume/1,2`、`step/1,2`、`reconcile/1,2`、`cancel/1,2` | 创建时固定 Scripted 配置；load 只读；resume/step 可能执行；reconcile 查询原身份或处理可信证据，不重发未知业务 |
| [Workflows](../lib/agent_systems_lab/workflows.ex) | `create/2,3`、`load/1`、`rebuild/1`、`sync/1,2`、`pause/1,2,3`、`resume/1,2`、`cancel/1,2,3`、`start_link/1`、`status/1`、`wake/1`、`stop/1` | 静态 DAG；sync 推进依赖；stop 仅停止当前 Coordinator；审批所属图的暂停恢复须走 Approvals |
| [Approvals](../lib/agent_systems_lab/approvals.ex) | `create/2,3`、`load/1`、`rebuild/1`、`sync/1,2`、`pause/2,3`、`resume/2,3`、`cancel/2,3`、`decide/2,3`、`release/2,3`、`start_link/1`、`status/1`、`wake/1`、`stop/1` | 人工请求绑定 request ID、seq、subject hash；身份认证由宿主负责；release 返回重验后的字节，不发布或应用补丁 |
| [Session](../lib/agent_systems_lab/session.ex) / [Context](../lib/agent_systems_lab/context.ex) | `Session.new/1,2`、`append/3`、`validate/1`；`Context.build/3,4`、`verify/4,5`、`options/0,1` | 纯构造与校验；原 Session 不因裁剪改写；受保护任务事实、回执和权限装不下时拒绝 |
| [CheckpointStore](../lib/agent_systems_lab/checkpoint_store.ex) | `create/2,3`、`load/1`、`latest/1`、`rebuild/1,2` | create 持久化；rebuild 只读、无模型或工具执行；已有损坏 checkpoint 明确拒绝 |
| [HistoryMigration](../lib/agent_systems_lab/history_migration.ex) | `plan/1`、`migrate/2,3`、`limits/0` | plan 只读；migrate 以 expected seq 显式提交；不迁移业务权限、期限或效果事实 |
| [Backup](../lib/agent_systems_lab/backup.ex) | `create_lab_database/1`、`dump/2`、`restore/1,2`、`metadata/1`、`bundle_metadata/1`、`drop/1` | 仅受当前 BEAM capability 与 owner marker 约束的新实验库；restore 默认只读；激活必须依 [L20](../labs/L20-history-migration-backup-restore.md) 的 exact proof 与 fencing 流程 |
| [Observability.Query](../lib/agent_systems_lab/observability/query.ex) | `run/1,2` | 有界只读诊断；不驱动任务；实时 Metrics 不是业务记账 |
| [Reproduction](../lib/agent_systems_lab/reproduction.ex) | `export/1,2`、`verify/1`、`stage_cache/1,2`、`plan/1,2` | 可信宿主的源码/缓存准备；plan 只返回数据；不会安装、执行或起停数据库 |
| [ReaderStudy](../lib/agent_systems_lab/reader_study.ex) | `prepare/1`、`load/1`、`add_feedback/2`、`report/1,2`、`report_from_file/2` | 有界文件读写与自报汇总；反馈文本不执行；技术 gate 与真人 gate 分开 |
| [ReleaseReadiness](../lib/agent_systems_lab/release_readiness.ex) | `check/0,1`、`plan/0,1` | W23 源码准备检查；只读源码元数据；不启动应用，不证明测试已执行，不创建 tag |
| [FrozenFaultMatrix](../lib/agent_systems_lab/frozen_fault_matrix.ex) | `plan/0`、`run/0,1`、`validate_report/1`、`verify/1` | plan/validate/verify 不执行业务；run 为固定 12×20 受控故障实验，真实访问 PG 和工具；只操作本轮 fixture |
| [CandidatePackage](../lib/agent_systems_lab/candidate_package.ex) | `build/1,2`、`verify/1` | 有界源码/证据准备与校验；不启动业务应用、不执行证据文字、不创建 tag 或上传；候选 label 不等于正式发行 |
| [ReleaseStudy](../lib/agent_systems_lab/release_study.ex) | `prepare/2`、`load/1`、`verify/1`、`add_feedback/2`、`append/2`、`report/1` | 显式选择冻结源码；原始反馈与追加 hash 链；verify/report 只读；同源码修复须原读者复验，改源码须新协议；不认证真人 |
| [ReleaseAssessment](../lib/agent_systems_lab/release_assessment.ex) | `policy/0`、`assess/1` | 有界只读候选、同源码试读与外部材料评估；保留原发布政策；不批准或发布，缺外部证据 pending |
| [EnvironmentValidation](../lib/agent_systems_lab/environment_validation.ex) | `plan/1,2`、`collect/1`、`verify/2` | 显式冻结 source，profile 计划与有界文件采集/核验；candidate 可选但必须同源码；不执行 argv、不启动业务或访问 PG，缺真实环境仍 pending |

正常宿主入口保留现有权限、五维预算、已用额度、absolute deadline、operation ID、unknown 队列、审批 generation 与 claim fencing。不能靠重新创建 Run、替换 ID、直接更新 Ecto schema 或回退二进制重置这些事实。

## 3. Provider 合同与当前接入限制

[Provider](../lib/agent_systems_lab/provider.ex) 定义两个必需回调：

```elixir
respond(context, state) # {:ok, response, next_state} | {:error, reason, next_state}
stream(context, state, emit) # {:ok, next_state} | {:error, reason, next_state}
```

完整 response 为 `{:final, text}` 或 `{:call, %{operation_id: id, tool: name, arguments: map}}`，call 必须恰有这三个 atom key。工具参数本身沿用 schema 要求的 string key。`Provider.valid_response?/1` 校验形状，不授权执行。

stream frame 为 `{:text_delta, binary}`、`{:tool_start, %{operation_id: id, tool: name}}`、`{:arguments_delta, binary}`、`:done` 或 `{:complete, response}`。Provider 必须同步等待每次 `emit.(frame)` 返回，遇到错误停止；`:done` 后 Provider 自身仍可能失败，只有回调成功返回及运行时事务接受后，结果才成为事实。部分帧不能触发工具。

当前 [RunServer](../lib/agent_systems_lab/run_server.ex) 与 [Recovery](../lib/agent_systems_lab/recovery.ex) 固定使用 [Scripted](../lib/agent_systems_lab/providers/scripted.ex)，并非通过任意 module option 动态装配 Provider。该 behaviour 是源码适配的合同；真实网络 Provider 仍需显式接入、录制、错误、取消、预算与恢复测试。实现回调本身不构成已支持的即插即用模型集成。

## 4. 工具合同与权限

当前没有通用 `Tool` behaviour 或自注册插件 API。[Catalog](../lib/agent_systems_lab/tools/catalog.ex) 定义固定 schema，[Gateway](../lib/agent_systems_lab/tools/gateway.ex) 在意图创建前及效果执行前检查。宿主只能显式启用固定适配器：

| 工具 | 必需参数 | 当前约束 |
| --- | --- | --- |
| `mock_write` | map | 旧教学合同允许任意 map；幂等能力依 Mock 模式，不能推广至任意外部目标 |
| `file_read` | `path` | 有界 UTF-8 常规文件；宿主授权的私有 workspace 内 |
| `file_write` | `path`, `content`, `expected_sha256` | hash 必须匹配；新文件使用 `"absent"`；拒绝多余字段 |
| `file_patch` | `path`, `expected_sha256`, `edits` | 1–32 个精确唯一替换；每项 `old/new`；不能用 `"absent"` |
| `sandbox_exec` | `command`, `args` | 绝对命令路径与宿主 allowlist；不经 shell；文件、网络、资源策略仍由宿主固定 |
| `mcp.<server>.<tool>` | 由发现并校验的 schema 决定 | 受 [MCP.Policy](../lib/agent_systems_lab/mcp/policy.ex) 本地名称、参数和连接策略约束；发现不授予权限 |

文件/隔离/MCP 结果通过 [Result](../lib/agent_systems_lab/tools/result.ex) 的 `wrap/3` 形成 `{:ok | :error | :unknown, %{type: "tool_result.v1", operation_id: id, tool: name, output: value}}`；`validate_required/3` 要求精确四字段且匹配原调用。历史 replay 保留已支持的旧 opaque 结果语义，不能按新工具名反推旧结果授权。

`Files.new/1,2`、`execute/4` 与 `lookup/2` 的 ledger 仅在进程内有效，重启后不提供持久 exactly-once。持久恢复必须经 Recovery/DurableTools 的原逻辑操作与核对流程。网络隔离不自动覆盖可信宿主启动的任意程序或任意 MCP server；MCP 命令、路径与能力须由宿主登记。

## 5. CLI 清单与副作用

以下是当前 `lab.*` Mix task 的入口，所有示例前缀均为 `./scripts/mix`。方括号表示可选参数，不是 shell 中要输入的字符。命令行参数错误或验收失败通常经 `Mix.raise` 非零退出；成功退出也不能替代检查产物的具体断言。

`R` 表示不驱动业务的读取；`F` 表示宿主文件准备/报告；`X` 表示会创建或推进实验、执行工具或注入故障。Mix 加载/编译本身可能写 `_build`，R 不是整个文件系统绝对零写入。所有启动应用的 R 命令都应先确保 `LAB_SCHEDULER_ENABLED=false`，避免启动独立后台执行者；`lab.trace` 还会主动拒绝全局 Scheduler。

| Task 与参数 | 类别 | 数据库、结果与关键边界 |
| --- | --- | --- |
| `lab.demo [--lost-response]` | X | 离线内存事件轨迹；lost response 显式查询 Mock |
| `lab.verify` | X | 10 个固定离线场景；执行教学模型/工具，不是能力 benchmark |
| `lab.verify_db` | X | PostgreSQL；先 create/migrate，再真实事务崩溃验收 |
| `lab.stream [--cancel \| --budget]` | X | 内存流式轨迹；两个 flag 互斥；输出状态、效果与重建比较 |
| `lab.repair [--output PATH]` | X | 私有修复样例、diff、前后验收日志 |
| `lab.p1 [--output PATH] [--memory]` | X | 默认 PostgreSQL；memory 需配 `LAB_DATABASE_ENABLED=false`，明确跳过数据库窗口 |
| `lab.history [--output PATH]` | X | PostgreSQL；文件写入、checkpoint、录制及独立 BEAM 零执行审计 |
| `lab.rebuild RUN_ID [--checkpoint]` | R | PostgreSQL；只重建原 Run，不续跑 |
| `lab.recover [--output PATH] [--repetitions N]` | X | PostgreSQL；创建新故障 Run；不是接管指定旧 Run |
| `lab.retry [--output PATH]` | X | PostgreSQL；有限退避、耗尽和 unknown 演练 |
| `lab.reconcile [--run RUN_ID] [--limit N] [--json]` | R | PostgreSQL；仅列已提交 unknown，不查询外部目标 |
| `lab.p2 [--output PATH] [--repetitions N]` | X | PostgreSQL；真实 kill、多故障窗口；保留报告 |
| `lab.schedule [--output PATH] [--runs N]` | X | PostgreSQL；私有调度池、多 Worker、续租与到期重试 |
| `lab.fence [--output PATH] [--repetitions N]` | X | PostgreSQL；仅暂停/恢复本轮拥有的 BEAM；SIGSTOP/SIGCONT |
| `lab.load [--output PATH] [--jobs N]` | X | PostgreSQL；饱和、背压、公平性、预算与进程采样 |
| `lab.database [--output PATH] [--repetitions N]` | X | PostgreSQL；本轮独立代理连接的断连、ACK 丢失与重连 |
| `lab.p3 [--output PATH] [--repetitions N]` | X | PostgreSQL；调度、fence、load、DB 四组件与只读审计 |
| `lab.isolate [--output DIR]` | X | macOS Seatbelt 与可信 native guardian；不支持时拒绝无隔离回退 |
| `lab.mcp [--output DIR] [--memory]` | X | stdio fixture；默认持久恢复，memory 明确只验 stdio 部分 |
| `lab.workflow [--output DIR]` | X | PostgreSQL；静态 DAG、汇合、故障与预算演练 |
| `lab.approval [--output DIR]` | X | PostgreSQL；合成宿主审批请求、返工与 hash 失效 |
| `lab.observe [--output DIR]` | X | PostgreSQL；拒绝全局 Scheduler；有界观测故障等价验收 |
| `lab.trace RUN_ID [--json] [--scope run\|related] [--limit 1..200] [--max-related-runs 1..24]` | R | PostgreSQL；拒绝全局 Scheduler；有界脱敏元数据 |
| `lab.eval [--output DIR] [--split dev\|holdout] [--repetitions 1..10] [--profile reference\|regressed] [--baseline REPORT]` | X | PostgreSQL，关闭全局 Scheduler；report/status/comparison；回归保留产物后非零退出 |
| `lab.eval.compare BASELINE CANDIDATE [--output DIR] [--success-drop-pp N] [--cost-increase-pct N] [--cost-increase-units N] [--latency-increase-pct N] [--latency-increase-us N]` | F | 不启动应用；校验后写 comparison；实际回归非零退出 |
| `lab.eval.verify [--output DIR]` | X | PostgreSQL，关闭全局 Scheduler；六组固定评测验收；保留真实延迟判定 |
| `lab.upgrade [--output PATH]` | X | PostgreSQL；创建四个受管新库、迁移/还原/精确清理；不是任意生产库升级 CLI |
| `lab.reproduce export\|verify\|cache\|plan --output ABSOLUTE_PATH [--port N]` | F/R | 不启动应用；port 仅 plan；新目录、source/cache manifest；plan 只输出 JSON 数据 |
| `lab.reading prepare --output PATH`；`add STUDY --feedback FILE`；`report STUDY [--technical FILE]` | F | 不启动应用；冻结包、反馈作为数据、分开的技术/真人 gate |
| `lab.release check`；`lab.release plan` | R | 不接受附加参数；只编译并检查源码；JSON 输出；不运行课程命令、不发布 |
| `lab.freeze plan`；`run --output ABS_PATH`；`verify --output ABS_PATH` | R/X/R | plan 与 verify 不启动应用；run 固定每行 20 次，真实故障并保留逐轮证据；不提供任意命令或减少轮次入口 |
| `lab.candidate build --output ABS_PATH --evidence ABS_PATH`；`verify --output ABS_PATH` | F/R | 不启动应用；绑定源码与固定 schema 的本轮证据；不安装 runtime、起停 PG、创建归档/tag、上传或部署 |
| `lab.reading.frozen prepare --source ABS_PATH --output ABS_PATH`；`add STUDY --feedback FILE`；`append STUDY --event FILE`；`report STUDY` | F/R | 不启动应用；独立新协议绑定显式冻结源码；反馈输入字节独占保存、事件按链追加；report 只读；文字与证据 hash 不执行、不认证真人 |
| `lab.release.assess --candidate ABS_PATH [--study ABS_PATH] [--evidence ABS_PATH]` | R | 不启动应用；只读评估固定原政策和同源码材料；有效缺项 pending，结构/来源绑定不一致拒绝；不批准、创建 tag 或发布 |
| `lab.environment plan --source ABS_PATH --profile macos-warm\|macos-cold\|linux-core [--candidate ABS_PATH]`；`collect --source ABS_PATH --execution ABS_PATH --output ABS_PATH [--candidate ABS_PATH]`；`verify --source ABS_PATH --bundle ABS_PATH [--candidate ABS_PATH]` | R/F/R | 不启动应用、执行 argv 或连接 PG；计划只输出数据，采集拒绝覆盖并绑定有界文件，verify 重算忽略缓存报告；Linux core 不通过完整隔离 gate |

`check` 是 Mix alias：格式、warnings-as-errors 编译、测试库 create/migrate、全套 test、lab.verify 和 lab.verify_db，因而是 X。`setup` 也是建库/迁移操作。输出目录的覆盖与边界以各任务源码为准；操作规程统一要求选全新目录，并保留失败产物。

[Python 环境执行器](../scripts/environment_validate.py)与上述文件 API 分开：`plan|run --source ABS --profile PROFILE --output FRESH_ABS --operator-id ID --host-id ID [--candidate ABS] [--cache-from ABS] [--new-host] [--postgres-prefix ABS] [--port N] [--timeout SECONDS]`。plan 不执行；run 是 X，固定命令、源码副本、安装/回归、独占 PG 和精确清理。macOS warm 必须显式缓存，cold 禁止缓存并要求新主机自报；Linux core 要求显式可信 PG prefix 与固定 BEAM 工具链。无 Linux-full profile，不执行数据中任意命令。具体前置、来源与失败处理见[跨环境操作](cross-environment-validation.md)。

## 6. 持久化兼容和内部实现

当前 [兼容矩阵](../lib/agent_systems_lab/history/compatibility.ex) 支持 Kernel/Event schema 1、Codec 1、sidecar schema 1，以及独立 history layout 1、2；未知版本拒绝。21 个 SQL migration 是当前已声明的结构集合。W23—W26 不增加 migration、不重写旧历史、不改变预算或恢复版本。新发行评估、新试读与环境验证的 kind/schema 独立于这些业务版本域，未知版本同样拒绝。

`Storage.*` Ecto schema、`*_in_transaction` 函数、IntentStore 的 token/锁实现、Scheduler.Worker、Coordinator 的 handle callback、Codec/Encoding 的内部 envelope 和故障注入 hook 属于实现细节。实验可读源码对照；业务宿主不能把直接改表、构造 claim、调用私有维护入口或绕过 RestoreGuard 当作受支持恢复方案。

接口变更先记录合同与迁移方案，补齐 replay、结果配对、权限、预算、故障与幂等测试，再重新产生源码候选与证据。`ReleaseReadiness` 固定的 `week24_matrix=pending` 是其 W23 检查范围，不读取或推翻 W24 实测报告。正式矩阵与候选决定见 [L23](../labs/L23-frozen-candidate-release.md)、[候选说明](candidate-release.md)、[运行操作](release-operations.md)及[限制](known-limitations.md)。

W25 的 `ReleaseAssessment` 不回写 `CandidatePackage` 的 rc.1 判断，也不改变旧 `ReaderStudy`。固定政策仍要求 3—5 名真人、零未解决 blocker、新工作区主实验、冷 macOS 主机及完整 Linux 隔离/冻结证据。自报、hash、适用子集测试和本机新目录分别按其范围解释，不能替代身份或完整平台认证。精确材料与失败处理见[发行评估操作](release-assessment.md)和 [L24](../labs/L24-versioned-release-assessment.md)。
