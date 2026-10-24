# ADR 0019：固定任务评测与配对回归门槛

- 状态：接受，用于第 20 周教学实现；实际验收以 validation-week20 为准。
- 日期：2026-10-23。
- 依据：[研究计划](../../Agent%20Systems%20Engineering%20研究与落地计划.md)、[有界观测 ADR](0018-observability-and-diagnostic-evidence.md)、[L19](../../labs/L19-repeatable-evaluation.md)、[运行手册第 18 节](../recovery-runbook.md#18-可重复评测与回归比较)。

## 问题

系统已有持久化执行、权限、预算、恢复和诊断，但一次演示成功不足以判断后续修改是否造成任务质量、成本或延迟回归。日志允许丢失，不能作为完整计量；模型自报成功不能证明产物正确；只报告成功样本会系统性低估成本。任务、oracle、预算和环境不一致时，两个漂亮汇总也没有可比性。

需要一个可重复、失败可见且能核对原事实的评测框架，同时避免把小型 Scripted Provider 机制演练误述为真实模型能力评测。

## 决定

采用原创公开 corpus，冻结六项 dev 与四项 holdout，各自显式选择运行，不共享 task ID。每个任务统一生成 `artifact.txt`，覆盖文本、CSV、汇总、脱敏、去重与预算边界。Manifest schema v1 只接受固定字段、oracle 和有限 profile mode，不能指定任意模块、命令或生成评分代码；严格拒绝重复键、版本错误、重复任务、错误分割、越界路径、符号链接与超大文件。

suite identity 绑定 manifest 原始字节、全部任务文件及 Suite/Scorer 源码；task identity 绑定本任务源文件和 oracle。定价另有固定 hash。哈希用于内容身份和变更检测，不提供签名、认证或可信来源。公开 reference/golden 允许阅读，因此 holdout 只代表独立分割，不宣称保密盲测、泛化能力或外部 benchmark 结果。

`Evaluation.run/1` 先保存完整 planned task/trial 清单，再按固定顺序执行，每项使用新的持久化 Run 和独立目录。执行通过原 Recovery、模型录制、受控文件工具及预算完成，保留原权限、结果配对、unknown 和恢复语义。全局 Scheduler 必须关闭。宿主 fixture enrollment 写入输入，Provider 请求仅含任务 input；golden/oracle 正文与 grader 请求不进入初始工作区或模型输入。

reference/regressed 仅选择固定宿主响应，不改变输入、预算、工具许可或 oracle。主动回归包含实际错误产物与一次固定预算耗尽；正确产物不能覆盖执行失败，自报成功不能覆盖错误产物。初始输入属于宿主 enrollment，不计作模型工具调用。

评分使用新 OS BEAM 的固定宿主 scorer。执行器通过受控读取捕获实际文件到单独只读快照，子进程只读 hash 与大小并运行固定 `exact_bytes_v1` oracle，不执行候选代码。子进程不启动项目应用，不继承数据库/API 凭据；请求与结果绑定 sample、task、artifact 与 scorer identity。超时、有限 stdout 超额、非零退出、错误协议和错配均可见。独立 guardian 持有 Port 并监控调用者；异常、超时、超量输出或调用者被 kill 时终止实际 owned OS PID、关闭 Port 并等待退出，不能以调用者 try/after 或 Port.close 替代进程清理。

评分前后核对原业务 source fingerprint 和快照 hash。只读 chmod 与独立进程用于可信固定 grader，不构成执行任意不可信代码的安全 sandbox，也不能防止同一宿主账户的恶意并发修改。后续引入生成测试或外部 grader 必须另行设计隔离与授权。

完整报告的成功分母覆盖所有计划样本。sample 成功要求执行成功、事实稳定和独立评分通过；task 成功要求该任务所有重复成功。有限 failure class 区分 incorrect、permission、budget、timeout、unknown、scorer error 和 harness error，不能删去最差 trial。

用原持久化事实统计 `model_attempts`、`output_bytes`、工具 execution attempts 与 dispatches。固定合成成本为 `1000 × model_attempts + output_bytes + 250 × tool_attempts`；dispatches 单列，不加价，USD 为 null。输出字节不是 token，合成单位不是供应商账单。失败消耗保留；source 不可用或评分前后漂移时 usage 标为未知；usage 未知时保留 known sum 和 unknown count，完整总成本为 null，不能补零。

真实延迟采用 monotonic 微秒，分 execution、scoring 和 total；scoring 包含外部 BEAM 启动，total 包含证据读取等额外开销。所有样本参与 nearest-rank p50/p95。语义签名只绑定稳定任务结果、产物与计量等事实，排除 Run ID、PID 和延迟；完整 report hash 仍记录本次实际样本。不要求时间测量或 report 字节完全相同。

比较只接受完整报告，重新构造每个派生值并验证样本身份和唯一性。协议须严格一致：suite/scorer/pricing hash、split、任务及其 hashes、重复数、execution contract、runtime version、measurement scope。profile 不属于兼容性约束，允许同协议下更换候选固定响应；不同分割各自建立基线。

回归检查同时作用于总体和每个任务，并输出 task/trial 配对变化。默认成功率允许下降 0 pp，成本允许增加 0% 且绝对 0 units，延迟允许增加 25% 且绝对 50,000 us。成本、延迟均须同时超过相对和绝对阈值才判回归；严格大于才越线，零基线显式处理。延迟覆盖三种 scope 的 p50/p95。Scorer/harness error 或计量缺失使对应检查返回 indeterminate，不允许通过；整体还存在已证回归时 status 为 regressed。阈值是预先约定的政策和噪声门槛，不声称统计显著性。

每次调用创建新输出目录，拒绝覆盖；先写 manifest/status，逐项写 sample JSON 与有限字段 JSONL，最后才写经校验完整 report。中断或 suite 运行中变化保留 incomplete status 与已有证据，不生成有效基线。正常任务失败仍是完整 cohort 的成员。保存比较不启动应用、Repo、scorer 或执行器，不能推进原业务。

## 方案依据与边界

[SWE-bench 官方评测指南](https://www.swebench.com/SWE-bench/guides/evaluation/) 将提交候选与外部运行测试的评测路径分开。这里借鉴独立检查实际产物的思路，使用原创字节 oracle；没有采用其任务数据、容器 harness、测试覆盖或 benchmark 分数，也没有声称同等安全隔离。

未采用模型自评作为成功标准，也未用 lossy Trace/Metrics 结算成本。参考脚本、golden、评分器和报告都是可信宿主维护的教学内容；安全摘要不含完整 prompt、工具参数、结果或凭据，原业务台账仍按原权限保留。主机控制、原始台账审计和文件访问控制仍由原系统承担。

## 验证与后果

测试覆盖固定分割和全部哈希依赖、严格 schema、oracle 不进入请求输入、实际错误产物、自报成功、预算耗尽、独立进程及凭据环境、超时/超量输出/非零退出与 PID 清理、样本错配、原事实稳定、未知成本、分母完整、nearest-rank、协议不兼容、逐任务门槛、零基线、双阈值、派生报告篡改与 incomplete 拒绝。正式演练分别运行两个分割的参考、参考重复与主动回归，再独立核对实际持久化来源和产物；实际数量以验收记录填写。

代价是评测顺序运行且每次评分有真实进程启动成本，短任务的延迟主要受本机调度与启动噪声影响；公开小样本不能提供统计能力结论。得到的能力是完整失败分母、可核对计量、稳定语义对照、严格兼容基线与可审查回归门槛，为后续真实 Provider、扩展任务、隐藏评测和更强 grader 隔离提供明确协议边界。
