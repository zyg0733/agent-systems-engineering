# 第 29 章：Replay Testing、Regression 与 Fault Injection

一条成功轨迹只能说明系统在某组条件下完成了任务。要相信它在故障中仍守住原事实，需要把“哪里可能坏、坏后应保留什么、由谁独立读取”写成可重复检查。回归测试、历史重建与故障注入服务于这个目标，但不能互相冒充证据。

本章对照 [Scenarios](../lib/agent_systems_lab/scenarios.ex)、[P2Verification](../lib/agent_systems_lab/p2_verification.ex)、[P3Verification](../lib/agent_systems_lab/p3_verification.ex)、[Reproduction](../lib/agent_systems_lab/reproduction.ex)及现有测试。实际结果绑定源码提交、运行时、参数与本次输出；章节里的预期值是学习判据，不能直接填进未执行的验收报告。

## 阅读准备与学习目标

应能解释历史纯重建、外部效果、claim、预算及受控故障窗口。顺序阅读还应知道[第 28 章](ch28-evaluation-datasets-and-scorers.md)评估任务能力与机制测试的区别。若跳读，本章首次练习只要求前面的 Kernel/RunServer 基础，完整故障矩阵则按 L09/L13/L20 的实际前置推进。

读完应能从不变量设计一个反例，区分纯值、内存、数据库及 OS 故障证据，保存完整失败，再用独立进程检验。还应能准确说明排除用例、warm cache、模拟读者与首因未知各限制了哪种结论。

## 29.1 先写失败后仍应成立的句子

“没有异常”太弱，“最终 status 一样”也可能漏掉重复效果。先把重要要求写成可反驳的不变量，例如：拒绝命令不产生新 Event；相同 operation 不覆盖不同参数；COMMIT 前无半笔事实；已确认回执不因 caller 退出丢失；旧 generation 不能提交；重建不调用执行入口。

每条不变量至少要有一个会使它失败的具体反例。若怀疑结果配对，就提交错 operation ID；若检查时间资格，就在 due 前扫描；若检查纯度，就监控模型/工具入口，而不是只等控制台保持安静。测试触发条件与实际观察要直接关联，避免把无关的“程序跑完了”当作证明。

| 层次 | 一个合适的问题 | 常见证据不足 |
| --- | --- | --- |
| 纯状态/策略 | 非法输入是否被精确拒绝 | 只看返回值不是 nil |
| 进程协议 | 指定屏障处能否取消、旧 ref 是否拒绝 | 短 sleep 后猜测执行位置 |
| 数据库事务 | COMMIT 前后独立读取是否完整 | 在原事务里读取自己的未提交值 |
| 外部效果 | 重投后真实效果是否仍符合合同 | 只数请求、不数效果 |
| 新进程重建 | 状态一致且执行入口零调用 | 在原 VM 复用内存缓存 |

## 29.2 第一次小练习：全部检查通过，不等于所有任务成功

在仓库根目录终端进入关闭数据库和后台 Scheduler 的会话：

```sh
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/iex
```

先预测：一个专门检查取消或拒绝的 fixture，要得到 succeeded 才算通过吗？下面会实际驱动固定的内存 RunServer 与 Mock，包含受控效果；它不是整段零执行的重建器，也不是模型能力 benchmark。

```elixir
alias AgentSystemsLab.Scenarios
results = Scenarios.verify_all()
true = length(results) == 10
true = Enum.all?(results, & &1.passed)
true = Enum.any?(results, &(&1.status == :cancelled))
true = Enum.any?(results, &(&1.status == :failed))
true = Enum.any?(results, &(&1.effects > 0))
true = Enum.all?(results, & &1.replay_matches)
```

预期断言同时成立。passed 表示该 fixture 的实际行为符合它的预期，包括正确停止或拒绝；不是所有任务都获得成功终态。fixture 的源是仓库内受信任 Elixir 数据，不能把这个入口改造成执行模型生成脚本或任意外部路径的加载器。

相同检查也可退出 IEx 后用 `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.verify` 观察逐项输出。应保留每项 id、期望与实际状态、效果数及重建结果，而不是只截取最后的 10/10。一次固定脚本通过没有测量真实模型选工具、理解需求或修复新任务的能力。

## 29.3 矩阵先覆盖窗口，再计算重复数

故障矩阵的行不是随意凑出的错误名称，而是协议中的交界：领取后、模型提交前后、工具 prepare/效果/receipt 前后、结果提交前后、核对与重试安排窗口。每行说明被中断的是谁、屏障已证明什么、下一 owner 应读取什么。

```elixir
alias AgentSystemsLab.{P2Verification, P3Verification}
windows = P2Verification.cases()
true = length(windows) == 16
true = length(Enum.uniq(windows)) == 16
planned_probes = length(windows) * 20
320 = planned_probes
true = P3Verification.components() == ["scheduling", "fencing", "load", "database"]
```

这段只列计划，没有运行故障。当前 P2 默认十六窗口各二十轮，是 320 probe；实际 kill 数还依各窗口协议而定，不等于简单套用 probe 数。W24 另有自己的冻结矩阵，不能把其十二类口径与 P2 的十六窗口拼成一个通过数。

重复用于暴露时序和资源问题，不能弥补缺失窗口。反过来，覆盖一个窗口的一轮 smoke，也不能标成正式二十轮矩阵。实验若缩小参数，应在命令、报告和结论中保留该范围，并说明哪些正式条件尚未执行。

## 29.4 屏障、故障、独立读取组成一条证据链

```mermaid
flowchart LR
    Invariant[不变量与预期事实] --> Gate[到达明确协议屏障]
    Gate --> Fault[只中断本轮自有角色]
    Fault --> Observe[确认进程或连接的实际故障]
    Observe --> Read[另一进程读取持久事实]
    Read --> Assert[比较配对、状态、预算与效果]
    Assert --> Archive[保存原始证据与源码身份]
```

COMMIT 前后窗口必须由真正的事务边界界定。一个 caller 被杀，只说明进程退出；COMMIT 是否成立，要用另一连接或新 BEAM 读取。内存 worker 的 kill 也不能代替 PostgreSQL 服务端持久性配置或主机断电测试。每种故障只支持它实际触及的层次。

真实 SIGSTOP/SIGCONT 演示只作用于 runner 自己创建并记录的 OS 子 BEAM。不能对照整个进程列表随意暂停另一个实验，再把恢复结果归入本次矩阵。数据库代理同样只控制本次 loopback 通道，保留 parent 独立连接以核对真实事实；不应停共享服务器或任意终止 backend PID。

恢复时还要等待原持久 lease/due 的时间资格，不能改 SQL 时间戳来制造更快的接管。固定 fixture 可声明较短窗口，但仍需记录实际到期与领取；测试缩短准备时间不等于允许业务恢复重置原 deadline。

## 29.5 报告必须能追到原始材料

每次运行选择尚不存在的输出目录。旧目录被拒绝是保护证据，不是应删除的障碍。至少记录完整 argv、可公开的环境范围、源码/运行时、Run 与 operation 身份、窗口、重复编号、原始日志、逐项退出码和报告 hash；私有凭据及 claim token 不进入公开报告或阅读站。

总报告应在中途停止时仍显示未完成，而不是保留上一轮 all_passed。子报告、被杀角色、进程退出确认、清理结果和新进程审计，要与总报告所列 id 对应。只有一份总结文字、没有原始目录，就无法区分“检查没通过”与“检查根本未执行”。

源码 manifest 绑定文件字节、大小和模式等身份。验证导出包与实际运行源码相同，是将结果归属到某个版本的前提；它不认证下载者、授权执行或证明模型能力。核心便携包与阅读站工具链也有不同范围，应按真实 manifest 说明，不能因网页能打开就称全部实验环境已复现。

对于还原演练，数据库 handle 的所有权、archive 来源、完整 proof 和实际清理要一起保留。输出目录中出现 cleanup 文件，也不能独立证明本次所有目标都清理成功；应读取精确对象及每一项结果，异常就明确交接而非 force drop。

## 29.6 纯重建需要独立检查零调用

History、checkpoint 与录制结果能否还原同一个 State，是语义一致性检查。Provider、工具、shell 或网络入口有没有被再次调用，是执行纯度检查。两份 State hash 相等不能相互替代；一个错误重建器可能先写了一遍文件，最后仍得到同样状态。

当前 history/P3 演示分别保存 parent 与新 BEAM 的审计，比较 Run 列表、原状态、全量/检查点结果和执行入口计数。审计计数覆盖当前 VM，应在新或空闲进程环境执行；其他业务同时调用会污染结果。看不到日志、同一个 PID 或复用旧 ETS，不足以证明独立重建。

命令本身可能先创建演示事实并执行工具，再进入只读阶段。报告应把两段分开：先解释如何产生待审数据，再指出哪段承诺零调用。不要把整个 `lab.history` 或 P3 命令都称为无效果路径，读者否则会错误理解它为何有真实工作区与效果计数。

## 29.7 怎样处理偶发失败与没有复现

先保留首次失败的源码、seed、参数、环境、退出码与原始子报告，再寻找具体窗口。若日志截断，就修复取证路径，不能凭一段不完整摘要认定超时。修复必须对应明确机制，并在同类窗口复验；一次后续绿色没有证明首因已经修好。

项目第二轮曾在 P3 的数据库组件未完成时返回失败，原输出截断、子目录随测试清理删除，因此具体首因仍未知。后续增加失败摘要及原始目录保留，CI 与有界本地复验通过，但记录仍保持“未复现，首因未知”，见[第二轮记录](../docs/learning-round2-review.md)与[后续复核](../docs/learning-followup-review.md)。

这个例子还说明：诊断代码与业务修复是两种改动。当前诊断覆盖返回失败的分支，返回成功后再出现断言失败或超时，仍是不同的证据保留路径。应如实注明缺口，再决定下一次需要什么材料；不能反复运行直到绿色并覆盖之前目录。

缩小调度器数或调整测试环境时，也需记录变化与原因。结果只能说明该次实际条件，不自动等价于原失败环境。尤其不要为了消除失败放宽业务断言、删除保护窗口，或把测试超时直接改写成已确认的业务根因。

## 29.8 测试范围、平台与读者证据分别归属

Linux core 明确排除 Seatbelt；内存回归还排除 database。应同时报告通过、失败和排除数量，排除不是通过。一个 macOS warm-cache 新目录可以证明同宿主的源码与材料复验，却没有证明新主机冷安装、另一架构或完整 Linux 隔离已经成立。

多 subagent 模拟读者和交叉技术审查可发现理解卡点与答案错误；它们不是外部真人，不能填进旧 ReaderStudy 的真人反馈字段。本轮按所有者决定使用代理推进教材，旧发行工具保留历史契约，不把招募真人设为继续写作的条件，也不编造满意度或学习完成率。

每批按影响范围运行必要检查，再让提交对应的两套 Actions验证源码和阅读站。书稿、实验命令、解答和结果索引应相互指向实际证据；正式版本、平台能力和公开范围分别决定。完成全部章节草稿，也不等于所有工程扩展或全部真实使用场景已经验收。

## 29.9 练习与教师参考

每题按不变量、反例与证据三项各 0—2 分，至少 5/6；不得把排除计作通过、抹掉失败目录或用模拟身份冒充真人。

1. 29.2 全部 fixture passed，为什么仍能出现 cancelled 和 failed？报告需要保存哪些逐项值？
2. 矩阵列出十六个窗口并计算 320，是否说明正式 P2 已执行？重复次数和窗口覆盖分别解决什么问题？
3. 最终 State hash 相同，为什么仍需新 BEAM 的执行入口计数？如果其他业务同时运行，计数非零应怎样调查？
4. 首次失败日志不完整，后来三次通过，怎样写准确结论？诊断补充和根因修复分别需要什么证据？

<details>
<summary>教师参考：让结论不超过实际证据</summary>

1. passed 表示符合具体预期，正确取消、拒绝或预算停止也可通过。保留 fixture id、期望/实际状态、效果数、事件及重建结果；总数不能替代每行判断，更不是模型成功率。
2. 没有，只形成计划。覆盖决定检查哪些协议交界，重复增加暴露时序问题的机会；没有运行日志、退出码与原始 probe 报告，不能填写完成数量。一轮 smoke 也不等于二十轮正式验收。
3. 错误实现可能重复效果后仍得到同一 State。独立进程和调用计数检验读取阶段是否跨执行边界；受污染时先核对当前 VM 的其他调用及范围，不把混合观察直接判为重建器错误。
4. 写“本次未复现，首因仍未知”，保留全部尝试及环境差异。诊断补充要证明能保留具体窗口和原始材料；根因修复则需明确故障机制、对应变更和同类反例复验，不能由绿色次数推导。

</details>

## 术语与继续阅读

Regression 检查旧合同仍成立；fault injection 在明确窗口施加受控故障；replay 只重新解释历史；reproduction 绑定源码与环境范围。具体入口见 [L09](../labs/L09-p2-fault-acceptance.md)、[L13](../labs/L13-database-outages-p3.md)与[P3 测试](../test/agent_systems_lab/p3_verification_test.exs)。下一章[完整系统设计与交付](ch30-complete-system-design-and-delivery.md)把这些证据组织成可审阅的系统案例。
