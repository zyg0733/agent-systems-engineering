# 第 19 周验收记录

验证日期：2026-10-23（Asia/Shanghai）。环境为 macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6。沿用 mix.lock，无新增 Hex 依赖与业务迁移，开发和测试库仍为原 20 个迁移。

配套 [L18 实验](../labs/L18-observability.md)、[参考解答](../labs/solutions/L18.md)、[ADR 0018](adr/0018-observability-and-diagnostic-evidence.md) 与[运行手册第 17 节](recovery-runbook.md#17-trace-metrics-与按-run-id-诊断)。

## 交付与契约

| 组件 | 已实现行为 |
| --- | --- |
| Context / Schema | 内部 schema v1；版本化确定性 32 位 Trace ID、16 位 Span ID；固定事件、关联字段、数值与枚举 allowlist；拒绝自指 parent，不导出自由正文或令牌 |
| 执行关联 | 模型 Context、tool attempt、intent generation 的实时开始/结束及提交观察与持久投影关联；Kernel Event 使用独立 span；调度、续租、失租、超时、重试和恢复使用原 Run ID |
| Query | repeatable-read、read-only 元数据投影；沿原 Workflow/Case 归属找到模型、工具、预算、控制、审批与返工；跨 Run 因果用 links |
| 查询上限 | 多行历史集合默认 100、最多 200；关联 Run 至多 24，预算/恢复每选中 Run 一行；Workflow/Case 另有固定轮次界限；截断与不可用投影显式标记 |
| Buffer | 固定槽位 public ETS、atomics 条目/载荷字节准入与有限 CAS；合并 wake；独立 recent 限额；一个导出 Worker，不逐事件 cast 到邮箱 |
| Exporter | 默认 Null；宿主显式 JSONL；error/raise/exit/kill/hang 隔离、timeout、丢弃失败批次与退避；observer 被 kill 同时清理挂起 Worker |
| Metrics | 固定 `{event_name, outcome}` 标签及有限数值聚合；不将 Run/operation/attempt ID、路径或自由错误作为 labels |
| 生命周期 | 末尾 temporary observer 不耗尽执行父监督树的重启预算；缺失时 emit 安全丢弃；宿主 restart 只重建观察状态 |

业务 emit 不做 SQL、文件、网络、同步 GenServer.call 或宿主 exporter 回调，始终返回 `:ok`。真实外层 COMMIT 后才发提交观察，内部事务 helper 不提前宣布成功。观察器不包装业务返回、退款预算、解除 unknown、批准产物或替代 fencing。查询不执行恢复、sync、capture 或放行。

## 自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终冻结代码完整 **854 passed（852 tests、2 doctests），0 失败**，测试用时 **99.4s**。格式检查、warnings-as-errors 编译、测试库迁移、W1—W19 全部测试、原 **10/10 fixtures** 以及创建/更新四个 COMMIT 前后真实进程 kill 检查全部通过。日志：[week19-check-complete.log](../artifacts/week19-check-complete.log)。

无数据库模式 **429 passed（427 tests、2 doctests），425 个数据库测试排除**，用时 **11.7s**。日志：[week19-memory-tests.log](../artifacts/week19-memory-tests.log)。排除不代表持久化用例通过；完整验收实际运行 PostgreSQL 和本机 Seatbelt/MCP 旧测试。

| 本周新增测试组 | 数量 | 主要判据 |
| --- | ---: | --- |
| Observability | 18 | 确定性 ID、schema/红线字段、attempt 配对、防自指、配置恢复、固定标签、并发条目/字节/邮箱/recent 上限、error/raise/exit/kill/hang、observer/依赖重启与有限 permit 残留 |
| Execution | 12 | 真实 COMMIT 后观察、回滚及内部登记静默、模型/工具/事件 Span 对齐、stale claim、unknown 单次效果、retry due、四类导出故障执行等价、Worker 超时及失租 |
| Query | 12 | 元数据最小化、只读无副作用、新 BEAM 稳定关联、DAG/Case/返工因果、模型无结果 capture、限额/legacy/unavailable、外层回滚、缺失观察器的 pause/resume |
| RunServer | 2 | 内存模型/工具同次尝试配对及 canary 缺失；真实 gated stream 取消关闭观察且不接受部分输出 |
| ObservabilityDemo | 4 | 严格选项、旧证据保护、全局消费者拒绝、失败报告、八项真实场景及证据/配置恢复 |

本周新增 **48 项**，原 W18 **806 项**保持。测试只作语义验证，不将 Scripted Provider 的固定输出当模型能力 benchmark。

## 最终正式演练

```sh
./scripts/mix lab.observe --output artifacts/week19-observability-final
./scripts/mix lab.trace RUN_ID --json
```

最终 **8/8 场景通过**，创建 **16 个唯一 Run、1 个审批 Case、2 个 Workflow**；Run 为 **15 succeeded、1 blocked/manual**，Case 为 approved，两个 Workflow 均 succeeded。all_passed 表示符合预期，保留 unknown 的 Run 不能自动确认为成功。

| 场景 | 实际判据 |
| --- | --- |
| correlated_execution | 私有队列的后台 Worker 在真实模型门闩期间续租，之后文件效果一次；模型、工具、意图与 Run 共享可验证关联 |
| unknown_reconcile | 两个非幂等模糊结果各产生一次效果；一个经可信人工证据确认后成功，另一个仍留 manual 核对队列 |
| approval_rework | 一个 Case 的两轮 Workflow、四个子 Run 可从旧轮 Run ID 找到；返工存在因果 link，当前 subject 由宿主批准并取得不可变字节 |
| export_failure_equivalence | Null、error、raise、exit、hang 五组的最终状态、seq、工具回执 hash、完整模型响应 hash、效果数、模型录制与已扣预算完全相同 |
| buffer_saturation | 16 个生产者提交 16,000 条观察；槽位、载荷字节、recent、邮箱及 metric series 有界；饱和明确丢弃 |
| observer_absence | 停止默认观察器后真实 Run 仍成功，效果一次；Registry/ProviderSupervisor/RunSupervisor PID 不变；durable Query 仍可读取 |
| commit_windows | 创建事务 COMMIT 前后门闩处真实 kill；提交前查不到原 Run，提交后可见；按原 ID 安全继续，不以实时通知决定提交 |
| readonly_projection | 相同事实两次 Query 完全相同；limit=1 显式 partial；47 个执行/控制/捕获/emit 入口全部零调用，状态、录制、预算与操作指纹不变 |

报告：[report.json](../artifacts/week19-observability-final/report.json)；日志：[week19-observability-final.log](../artifacts/week19-observability-final.log)。每场景保存 JSONL、summary、按 Run ID 的安全 Trace JSON、Trace hash 和原业务事实 hash。故障比较与饱和边界另有独立文件。初次演练目录 `artifacts/week19-observability/` 保留，不覆盖或移动其中的原工作区；本次验收数字只计算最终 namespace。

## 回归中发现并修正的问题

交叉审查修复三处观测问题：被强杀的 observer 原先可能遗留挂起 exporter，现用 linked/monitored 生命周期清理；Kernel Event 原先误用 Run 根 span，现与 Query 的独立事件 span 对齐且拒绝自指 parent；RunServer 拒收候选模型结果时，结束观察现按 error 返回分类，不再把它标成 ok。所有修复均不改变原事务、权限、预算或恢复决策。

首次完整回归出现 14 项新测试失败，均因测试假定默认 observer 始终存在。原 Registry 子树故障测试触发 rest_for_one，temporary observer 按设计停止且不会自动复活。已在需要观察的测试 fixture 中显式执行宿主恢复，并新增真实 Repo 重启验证：等待全部执行依赖替换，确认 observer 仍缺失、数据库及执行基础设施可用，随后只恢复观察器。没有改变监督策略来迁就测试。

原监督测试与全部 W19 套件采用首次失败 seed 30371 混合执行，**49/49 通过**，日志：[week19-lifecycle-mixed.log](../artifacts/week19-lifecycle-mixed.log)。首次全量失败保存在 [week19-check-initial.log](../artifacts/week19-check-initial.log)，最终完整验收另行记录。

## 独立新 BEAM 与冻结证据

最终目录在执行停止后由独立新 BEAM（OS PID 42778）读取全部 **16 Run、1 Case 和2个 Workflow**，逐个与正式 Trace JSON、原状态、模型录制、预算和 operation 指纹比较。每 Run 47 个执行/控制/捕获/emit 入口，再对 Case 执行同样审计，**799 个调用计数全部为零**。与只在同 VM 重启观察器的测试区分，此处真实启动新的 OS 进程。

相关 **21 张持久表**的全列原始行及 hash 在审计前后完全相同；最终范围包含 **56 个 Kernel Event、41 个意图、27 个模型输入 capture／录制、12 个工具 operation、14 个 attempt 和9个 Mock effect**。工具文件效果另按产物验证，不能把 Mock effect 行数当作全部工具效果数。

独立 Python **222/222 通过**：核对完整报告、红线字段与 canary 缺失、模型/工具 attempt 的实时与持久 Span 精确对应、Kernel Event 关联、审批返工 links、五组执行等价、manual unknown 单次效果，以及新 BEAM 的零执行和原事实不变。最终 JSONL 记录 **1 次真实续租**；旧 intent generation 按保留观察与同 intent ID/seq 关联，不要求最终单行投影伪装成完整租约历史。

饱和演练 **16,000 次**发出中 **36 admitted、15,964 dropped**，高水位 **32 条／13,448 字节**，未超过 **32／16,384** 上限；采样时 recent **4 条／1,682 字节**，上限 **8／8,192**；mailbox 为 **0**，只有一个 metric series。采样时 exporter 仍在途，因此 exported=0 不等于未准入；单独超时、清理与导出故障测试负责验证后续收敛。

正式起跑前后的 **266 个可执行源码、配置、测试、脚本与 fixture 文件**的 hash 和 mode 全部相同，并保存源码快照。README/文档在取得实际数字后补写，不在冻结范围。此审计证明保存的事实与最终冻结代码一致，不冒充再次注入所有故障。

证据：[independent-audit.json](../artifacts/week19-observability-final/independent-audit.json)、[independent-rebuild.json](../artifacts/week19-observability-final/independent-rebuild.json)、[原表前](../artifacts/week19-observability-final/raw-database-before.json)与[后](../artifacts/week19-observability-final/raw-database-after.json)、[source-manifest.json](../artifacts/week19-observability-final/source-manifest.json)、[源码快照](../artifacts/week19-observability-final/source-snapshot)。三份独立审计脚本与日志也在最终目录。

初次独立审计曾要求已被新 generation 覆盖的 intent span 仍与最终行精确一致；该判据错误，已收窄为真实 attempt 精确对应、旧 intent 代次保留原 ID/seq 及小于最新 generation 的证据。初次报告与脚本保留在原演练目录，未修改运行源码或原始数据来让审计通过。

## 当前边界

本周是内部 v1 逻辑 Trace、有限 Metrics 与本地 JSONL，不实现完整 OpenTelemetry SDK、OTLP 网络传输、collector、远端采样或真实模型质量评估。规范对照与官方链接见 ADR 0018。

实时观察可能丢失、重复或乱序。Case/Workflow 的无变化或幂等操作可重复观察同一已提交快照；实时 Metrics 计的是已排出观察，不是唯一人工决定、返工次数、API 费用或业务成功数。权威计数继续读取原 durable 事件与账本。

模型录制绑定已接受结果；未配对录制的 Context 只证明输入 capture，不证明实际调用或失败。历史尝试可能只保留扣账。Intent 行仅保存最新 claim generation，旧代次只能通过仍保留的运行观察关联同一 intent ID/seq，Query 不补造完整旧租约历史。行时间不是真实 provider latency；人工等待可由原 Case 事件时间解释，本周没有独立的人审等待计时器。

队列载荷字节按 Erlang external term 计算，不是精确 VM 内存或磁盘配额；JSONL 文件轮换由宿主负责。producer 在 atomics 预留后、ETS 插入前死亡，可能遗留有限 permit、降低容量；不会超界或改变执行。queued/reserved 的持续差异可供诊断，宿主 restart 可清除，但不保证自动无损恢复。restart 从静态配置/默认 Null 重建，临时 exporter 设置需宿主另存并恢复。

Query 是可信宿主元数据投影，不替代严格 load/rebuild、当前产物 release 或多租户访问控制。输出排除 prompt、模型正文、工具参数/回执、路径、人工身份/理由与 claim token/owner；宿主仍必须保证业务 ID 本身不包含秘密。两个 CLI 在 app.start 前拒绝全局 Scheduler 或禁用数据库，独立四项保护检查通过；在已运行应用调用 Query 时，原先已有的后台调度仍由宿主管理。
