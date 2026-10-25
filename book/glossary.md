# 六章共用术语表

本表统一当前六章与实验的用词。小写英文表示概念；`State`、`Run`、`Operation` 等代码名以具体模块和数据结构为准。同一词在其他框架中可能有不同含义。

## 状态与转换

| 术语 | 本书含义 | 容易混淆的边界 |
| --- | --- | --- |
| state（状态值） | 某一时刻的完整 `Kernel.State`，包括任务编号、seq、status、操作台账与预算等 | `status` 只是 state 的一个字段，不能只比较 status 就声称状态完全一致 |
| status（状态标签） | `queued`、`running`、`waiting_tool`、`blocked`、`succeeded`、`failed`、`cancelled` 之一 | `waiting_tool` 是等待待处理操作；`blocked` 表示当前操作结果 unknown，不能据此继续模型轮次 |
| command（命令） | 希望系统做出的转换请求，由 `dispatch/2` 校验 | 可以被拒绝；调用方提出命令不表示系统已接受事实 |
| event（事件） | 已接受转换的规范事实，含 Run ID、连续 seq、类型与数据 | 不是日志的一行描述；重建仍校验 schema、身份、顺序与转换合法性 |
| reducer / apply_event（事件应用） | 根据已有状态和一个合法事件计算下一状态 | 纯计算，不在其中执行模型或工具 |
| dispatch（命令决策） | 从 state 与 command 得到新 state 和事件列表，或返回错误 | 纯 Kernel 的成功返回没有自动持久化，也没有执行外部效果 |
| invariant（不变量） | 每个允许状态或转换都必须满足的规则 | 需要反例与断言；一次成功演示不能证明所有输入都满足规则 |
| terminal（终态） | `succeeded`、`failed`、`cancelled` | 终态拒绝迟到命令；cancelled 不表示外部已发生效果被撤销 |

入口：[第 2 章](ch02-agent-state-machine.md)、[L01](../labs/L01-state-machine.md)。

## 会话与历史

| 术语 | 本书含义 | 容易混淆的边界 |
| --- | --- | --- |
| Session / Message | 规范会话与其中的具体消息；当前 Session 保存 messages/version 等字段 | 本项目不另建 Session Turn 层级；模型接受轮数见下一行，不等于用户完整往返、Provider 游标或 Event seq |
| Kernel turn_count（模型接受轮数） | 被 Kernel 接受的模型响应次数，工具提议与 final 各占一轮 | 工具执行不是新模型轮；Provider 已返回但响应被拒绝，不代表此计数增加，请求/输出资源却可能已消耗 |
| Context（上下文） | 从某个 Session 版本构造的模型输入 | 不等于完整会话，也不自动拥有授权能力 |
| ETF（Erlang External Term Format） | Erlang/Elixir 值的外部二进制编码；本项目以确定性编码长度度量 Context | 本地序列化字节不是自然语言字符数、模型 token 数或费用 |
| hard facts / narrative | 必须保留的宿主事实、权限与回执 / 可以按预算裁剪的叙述 | 叙述摘要不能替代权威权限、回执或真实执行结果 |
| manifest（清单） | 记录输入或源码的组成、来源、hash 等信息；具体字段依清单类型而定 | context manifest 与 source manifest 用途不同；hash 一致不证明材料作者、读者身份或系统安全 |
| rebuild（重建） | 从合法历史计算状态；例如 `Kernel.rebuild/3` | 不恢复执行，不调用 Provider 或工具；原始 `max_turns` 等运行选项仍需一致 |
| replay（重放） | 按顺序重新应用历史事件，是重建中的计算过程 | 在本书中不指重新向真实工具发送请求，也不指重新请求真实模型 |
| resume（恢复执行） | 核对持久状态、配置、预算、权限与当前资格后，继续尚未完成的步骤 | 可能调用外部系统；不能把 rebuild 成功当作自动 resume 的授权 |
| checkpoint（检查点） | 与历史前缀对应、需要校验的状态切片 | 自洽 hash 不等于可信；当前实现仍校验前缀，不承诺加速 |
| recording（录制结果） | 按本项目契约保存的模型响应或输入相关材料 | 不等于 Event history；不能任意更换录制结果而保持同一历史含义 |

入口：[第 8 章](ch08-session-context.md)、[第 14 章](ch14-history-checkpoints-and-replay.md)。

## 外部效果与结果

| 术语 | 本书含义 | 容易混淆的边界 |
| --- | --- | --- |
| operation（逻辑操作） | 一次业务意图，以稳定 `operation_id` 关联请求、结果与核对 | 同一操作的重传不应换新身份冒充新业务；不同参数复用同一身份应拒绝 |
| attempt（尝试） | 对一个逻辑操作或执行步骤的一次执行尝试；持久路径记录其预算与状态 | 新 attempt 不表示新的业务意图，也不应重置总 deadline 或授权 |
| receipt（回执） | 工具或受控效果端保存、返回的执行证据，需与操作和工具身份匹配 | 客户端没收到回执不等于效果没发生；一条日志也不自动成为权威回执 |
| effect（效果） | 外部可观察到的变化，如 Mock 台账新增一条效果、文件被写入 | 请求数、attempt 数、已接受 Event 数与效果数是不同计数 |
| idempotency（幂等） | 在约定范围内，以相同身份和参数重传仍复用同一业务结果 | 依赖效果端的契约、保存期限和参数校验；不是所有远端工具都提供 |
| error（已知错误） | 按该 API/适配器契约可确认的错误返回；例如 `:failed_before_effect` | 不能仅凭 timeout 或任意错误字符串就确认远端无效果；工具 error 也不自动令 Run failed |
| unknown（结果未知） | 现有证据不能确认操作最终结果 | 不是错误结果的别名；可与“效果已经发生”同时成立。当前 Kernel 将其置为 blocked |
| reconcile（核对） | 根据权威查询或可验证证据，把 unknown 归为已知结果 | 不应凭相同文件内容、主观猜测或重复调用把结果改成成功；当前 Run 的合法核对命令还受状态约束 |

取消可停止本任务继续执行，但不能证明外部效果不存在，也不消除已有 unknown 事实。当前实现中取消会使 Run 进入终态，并从活动 blocked 核对队列移除；不能承诺取消后该队列仍自动承担跟进。细节与边界见[第 16 章](ch16-durable-effects-and-reconciliation.md)。

入口：[第 16 章](ch16-durable-effects-and-reconciliation.md)、[L07](../labs/L07-recovery.md)、[L08](../labs/L08-retries-and-reconciliation.md)。

## 租约与执行资格

| 术语 | 本书含义 | 容易混淆的边界 |
| --- | --- | --- |
| intent（调度意图） | 与当前 Run/Event 一起提交、描述下一步可执行工作的持久记录 | 不是已经开始执行的证明；过时 seq 的旧意图不能继续授权 |
| claim（领取） | 通过数据库事务取得某个当前意图的执行资格 | “读取到待处理记录”不等于已领取；领取成功也不证明外部效果唯一 |
| lease（租约） | 当前资格的有效时间范围，由权威数据库记录并校验 | 过期不等于旧进程死亡，不会自动撤销在途远端请求 |
| heartbeat（续期/心跳） | 按契约尝试延长当前有效 claim；诊断视图也记录本地续期 ACK | 发出续期请求不等于续期成功；本地 heartbeat age 不替代数据库资格判断 |
| token / generation | 当前 claim 的身份与递增代次，供续期、提交及受控效果端核验 | 仅比较 Event seq 不足以区分同一步骤的旧、新领取者 |
| fencing（拒绝旧资格） | 在关键提交或参与协议的效果端拒绝旧 token/generation 等失效资格 | 未参与校验的任意远端服务不会自动获得这层保证 |
| deadline / timeout | 总截止时刻 / 某次等待或执行的时间限制 | timeout 不证明远端失败；重启、重试、暂停都不应重置原总截止时间 |

入口：[第 20 章](ch20-scheduling-and-recovery.md)、[L10](../labs/L10-background-scheduling.md)、[L11](../labs/L11-leases-heartbeats-fencing.md)。
