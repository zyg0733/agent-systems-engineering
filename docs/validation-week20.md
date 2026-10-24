# 第 20 周验收记录

验证日期：2026-10-23（Asia/Shanghai）。环境为 macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6。沿用 mix.lock，无新增 Hex 依赖或业务数据库迁移，开发与测试库仍使用原 20 个迁移。

配套 [L19](../labs/L19-repeatable-evaluation.md)、[参考解答](../labs/solutions/L19.md)、[ADR 0019](adr/0019-repeatable-evaluation-and-regression.md) 与[运行手册第 18 节](recovery-runbook.md#18-可重复评测与回归比较)。

## 交付与口径

| 组件 | 已实现行为 |
| --- | --- |
| Suite | 原创公开的 6 dev／4 holdout；manifest schema v1，50 个任务源文件；任务、oracle、Suite/Scorer 源码、定价和分割均绑定内容 hash |
| Runner | 每 task/trial 新 Run 和独立 workspace；原 Recovery、文件工具、结果配对、权限、预算与提交语义继续生效；不使用日志计费 |
| 执行合同 | 固定 Run/模型/工具/dispatch 预算、step 上限、执行等待和评分等待；合同 hash 进入可比较协议 |
| Scorer | 固定 `exact_bytes_v1` 在真正新 OS BEAM 读实际产物；不启动项目应用、不继承数据库/API 凭据；请求/结果绑定 task/sample/artifact/scorer；有限输出与 timeout |
| 生命周期 | 独立 guardian 持有 Port 并监控调用者；超时、超量输出或调用者被 kill 时清理实际评分子进程 |
| Report | 完整 task/trial 覆盖与唯一 Run；样本/任务成功率、有限失败分类、持久成本和实测延迟；重算所有派生值与 hash 后才能加载 |
| Comparison | 严格同协议配对；总体及逐任务质量/成本/延迟门槛；零基线、绝对/相对噪声双门槛、未知计量和评分故障明确拒绝通过 |
| Evaluation / CLI | 创建前保存完整计划；逐样本安全证据、JSONL 和 status；中断保留 incomplete，禁止覆盖和充当基线；比较文件不启动应用或执行 |

成本单位为 `1000 × model_attempts + output_bytes + 250 × tool_attempts` 的 **synthetic lab units**；dispatches 单列不加价，USD 为 null。output_bytes 来自原执行扣账，不是 token，也不等于文件大小。失败样本的消耗计入；源不可读、前后指纹或产物不稳定时 usage 为 null，完整总成本不可用，不补零。

样本成功要求 Run 成功、源事实稳定且独立产物评分通过。模型自称完成没有评分权限；正确产物也不能覆盖预算失败。任务成功另要求该任务全部重复成功。所有已计划样本都在完整 cohort 分母中；框架中断则整个批次 incomplete，不使用尚未完成的少数样本生成有效基线。

延迟来自单调时钟的 execution、scoring、total 微秒值，包含失败样本。scoring 包含启动外部 BEAM；total 还包含源事实读取等开销。p50/p95 使用 nearest rank，不平均分组分位数，也不编造可完全重复的耗时。

## 自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终冻结代码完整 **906 passed（904 tests、2 doctests），0 失败**，测试用时 **123.8s**。格式、warnings-as-errors 编译、测试库迁移、W1—W20 全部测试、原 **10/10 fixtures** 及创建/更新四个 COMMIT 前后实际进程 kill 检查全部通过。日志：[week20-check-complete.log](../artifacts/week20-check-complete.log)。

无数据库模式 **467 passed（465 tests、2 doctests），439 个数据库测试排除**，用时 **13.6s**。日志：[week20-memory-tests.log](../artifacts/week20-memory-tests.log)。排除的数据库用例在完整验收中实际运行；无数据库运行仍验证纯报告/回归计算、固定集、外部评分与原内存实验。

| 新增测试组 | 数量 | 主要判据 |
| --- | ---: | --- |
| Suite / Scorer | 17 | 固定分割/身份依赖、严格载荷与路径、独立 OS 评分、错配/伪成功拒绝、凭据环境、超时/超量/退出及调用者死亡后的实际 PID 清理 |
| Runner | 10 | 新 Run/工作区重复语义、错误产物、自报成功、真实同预算耗尽、step 与执行/评分 timeout、观察器缺失、稳定/未知 usage、证据不覆盖 |
| Report / Comparison | 17 | 分母完整、唯一身份、派生值篡改、缺失成本、分位数、零基线、双阈值、逐任务平均掩盖、不兼容协议与 JSON 往返 |
| Evaluation | 4 | 严格选项/旧目录/消费者保护、不完整批次、重复 cohort、真实退步、保留集及文件比较 |
| EvaluationDemo | 4 | 严格验收选项、旧证据保护、有限失败报告、六组 60 个新样本与 49 个零执行比较入口 |

本周新增 **52 项**，原 W19 **854 项**保持；新增测试专项 **52/52 通过**，日志：[week20-focused-tests.log](../artifacts/week20-focused-tests.log)。

首次完整运行有一项旧 WorkflowDemo 的 absolute_deadline 场景失败（该场景使用 150 ms 期限），其完整原因被 ExUnit 的大报告截断，**根因未确定**。没有改源码、期限或隐藏失败：相同 seed 592953 的专项测试 **4/4** 和另一个独立新进程的九场景演练 **9/9** 均通过，然后停止并行审计再完整复验取得上述 906/906。首次日志保存在 [week20-check-initial.log](../artifacts/week20-check-initial.log)，独立复现证据为[专项日志](../artifacts/week20-workflow-investigation-tests.log)及[独立 DAG 报告](../artifacts/week20-workflow-investigation/report.json)。不把未证实的数据库竞争假设写成已定位原因。

## 最终正式评测

```sh
./scripts/mix lab.eval.verify --output artifacts/week20-evaluation-acceptance
```

正式 **10/10 验收场景通过**，包含六组 cohort、稳定语义/成本复现、主动回归、协议/篡改拒绝和只读比较。两个分割各执行 reference 基线、相同 reference 重复与 regressed 候选，每任务两次，共 **60 个唯一新 Run**。开发集与保留集保持独立，不把多个 cohort 混成一个模型能力成功率。

| cohort | 成功／计划样本 | 样本成功率 | 合成总成本 | execution p50／p95，µs | scoring p50／p95，µs | total p50／p95，µs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dev-baseline | 12／12 | 100% | 28,698 | 57,866／184,265 | 143,345／147,855 | 210,033／345,291 |
| dev-repeat | 12／12 | 100% | 28,698 | 54,592／58,713 | 142,911／146,671 | 206,794／210,998 |
| dev-regressed | 8／12 | 66.67% | 28,782 | 54,301／60,198 | 142,957／145,308 | 206,005／210,857 |
| holdout-baseline | 8／8 | 100% | 19,096 | 52,448／57,695 | 143,064／146,756 | 203,717／209,778 |
| holdout-repeat | 8／8 | 100% | 19,096 | 54,899／62,156 | 152,117／185,896 | 217,781／256,139 |
| holdout-regressed | 6／8 | 75% | 19,096 | 53,938／56,329 | 143,993／146,401 | 207,115／208,801 |

每种分割的 baseline/repeat **semantic_signature 与成本完全一致**，Run ID 全新。完整 report hash 与实测延迟不同，这是预期。default comparison 的总体和逐任务门槛均通过相同 profile 重复；没有要求真实时钟相等。

主动退步固定在三个任务：dev-sort-inventory 错误排序导致两个产物不通过；dev-bounded-response 在原单次工具额度下请求额外调用，两个 Run 失败而产物评分通过；holdout-deduplicate-events 错误次序导致两个任务样本失败。两组 regressed comparison 都被拒绝通过。开发集额外 84 合成单位和质量下降分别可见；保留集成本相同仍不能掩盖成功率下降。

60 个样本中运行状态为 **58 succeeded、2 failed**，外部任务结果为 **54 success、4 incorrect、2 budget**；因此 Run succeeded 不能直接用作任务成功率。两个预算失败仍保留正消耗，评分器错误、harness error 和未知成本在本次正常正式 cohort 中为零，其故障路径由专项测试验证。

报告：[总验收](../artifacts/week20-evaluation-acceptance/report.json)、[开发基线](../artifacts/week20-evaluation-acceptance/dev-baseline/report.json)、[开发退步比较](../artifacts/week20-evaluation-acceptance/dev-regressed/comparison.json)、[保留基线](../artifacts/week20-evaluation-acceptance/holdout-baseline/report.json)、[保留退步比较](../artifacts/week20-evaluation-acceptance/holdout-regressed/comparison.json)；日志：[week20-evaluation-formal.log](../artifacts/week20-evaluation-formal.log)。每 cohort 保存预先计划、逐样本安全摘要、完整 JSONL、评分只读产物及原事实指纹。

## 故障与回归契约

源码审查补齐两个故障窗口：仅用调用方 try/after 不能在其被 kill 时清理挂起评分 BEAM，现由独立 guardian 持有 Port；评分期间源事实或捕获产物不稳定时，不能继续把先前读取的部分 usage 当完整成本，现统一标为未知。专项测试验证实际 owned PID 退出及稳定/不稳定计量的区分，没有修改旧执行引擎。

默认成功率允许下降 0 pp；成本相对/绝对增量为 0；延迟相对 25% 且绝对 50,000 µs。成本及延迟需同时严格越过两条门槛，零基线有单独分支。检查覆盖总体和逐任务，以及三种耗时的 p50/p95；比较保存阈值与每项判据。scorer/harness error 或未知计量使 gate 不能通过，不能当作更快更省的成功。

篡改 summary/派生 hash、缺样本、重复 task/trial 或 Run、任务/oracle/scorer/定价/预算/分割/重复数/运行时不兼容均被拒绝。无效基线在创建输出和执行之前拒绝，完整但任务失败的报告仍能参与比较；不完整批次不能参与。保存报告的 file comparison 验证 **49 个执行/评分/控制/观测入口为零调用**。

## 独立审计与内容冻结

正式开始前，用独立宿主进程在数据库内计算所有应用表每行完整列的 SHA-256，仅导出排序行 hash。正式后用真正新 BEAM 重读全部 60 个 Run，验证完整报告、原账本 usage、原事实 fingerprint、运行状态、评分前后不变、独立评分器未启动项目应用及实际 PID 已退出；重算所有保存的 comparison。

新 BEAM **443/443 检查通过**，**49 个执行、评分、控制与观测边界调用计数全部为零**。相关 **21 张表**的完整列行 hash 在只读审计前后相同；正式评测前的每个既有行也逐列保留，允许的新增仅为本次演练事实，没有修改旧 Run 或旧核对数据。这里是整个审计期间的 49 个全局计数，不将它伪报为逐 Run 安装 49 次计数器。

独立 Python **806/806 通过**，从原 fixture 字节与实际产物重算任务/oracle/scorer/suite 身份、成功率分母、成本公式、nearest-rank 分位数、全部报告 hash、语义签名、配对变化和双阈值。两种独立审计合计 **1,249/1,249**。六组样本共记录 **120 个模型尝试、60 个工具 execution attempt、180 个 dispatch、8,466 个已扣模型输出字节**；这是实验记账总量，不是不同分割合并后的模型能力分数。

正式起跑前后的 **335 个源码、配置、测试、脚本与 fixture 文件**的 hash 和 mode 完全一致，另检查文件集合没有增删，合计 336 项内容冻结判据通过。保存了完整源码快照；README/文档在取得真实数字后补写，不在冻结范围。

证据：[Python 审计](../artifacts/week20-evaluation-acceptance/audit-python.json)、[新 BEAM 审计](../artifacts/week20-evaluation-acceptance/audit-fresh-beam.json)、[正式前数据库行 hash](../artifacts/week20-evaluation-acceptance/database-before.json)、[内容冻结](../artifacts/week20-evaluation-acceptance/audit-source-freeze.json)、[源码快照](../artifacts/week20-evaluation-acceptance/source-snapshot)、[实际重跑命令](../artifacts/week20-evaluation-acceptance/audit-commands.json)。审计工具首次在 threshold 字符串转 existing atom 前没有加载 Comparison，已保留失败日志，并用显式预加载命令成功重跑；冻结源码、原始报告和数据库未为此改变。

实际 CLI 另有 **6/6 保护验证**：禁用数据库或启用全局 Scheduler 时，eval/verify 在启动前拒绝且不建输出；同时设置数据库禁用和 Scheduler 启用时，纯文件 replay 比较仍退出 0，主动退步比较先保存完整 comparison 再退出 1。若该纯命令启动了应用，该组合配置本应被拒绝，成功运行也验证了未启动应用。日志：[week20-cli-checks.log](../artifacts/week20-cli-checks.log)。

## 当前边界

本次是公开原创小任务与宿主固定 Scripted 响应的机制验收；reference 含预制正确产物，holdout 源码可读。没有声称秘密盲测、真实模型泛化能力、SWE-bench 成绩、供应商账单或生产吞吐。独立 scorer 不执行候选代码，也不是任意不可信代码的安全 sandbox。

每次评分创建新进程，短任务的 scoring 主要体现外部 BEAM 启动成本；缓存与本机负载影响实测。两次重复不足以证明统计显著性或真实尾延迟总体，门槛属于宿主政策。后续真实 Provider、私有保留集、usage 定价和更强评分隔离应另定协议与基线。

内容 hash 不是签名；任意人能改底层样本并重算全部 hash，所以正式证据必须继续对照原 Run 与实际文件。评分只读 chmod 也不抵御同一宿主用户恶意并发改写。框架只处理自己创建的样本，没有自动续跑中断 cohort 或清理旧业务数据。六章外部试读不在本次完成声明中。
