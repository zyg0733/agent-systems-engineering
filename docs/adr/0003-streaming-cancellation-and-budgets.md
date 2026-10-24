# ADR 0003：模型流、运行中取消与预算边界

- 状态：已接受
- 日期：2026-10-20
- 适用范围：Agent Systems Lab 第 4 周、L03
- 延续：[ADR 0001](0001-pure-kernel-and-explicit-effects.md)、[ADR 0002](0002-transactional-storage.md)

## 背景

L01 的模型调用一次返回完整响应，RunServer 在调用期间无法处理其他请求。真实模型逐段输出时，调用可能长时间不结束；用户需要在输出期间读取状态、取消任务，并限制输出量与执行时间。工具参数也可能被拆成多个 JSON 片段，任何一个片段都不足以授权执行工具。

本周建立与模型厂商无关的流协议和可重复测试。Scripted Provider 以独立工作进程逐帧生产数据，不需要密钥或网络。实际厂商的 HTTP/SSE 解析、计费 token 和远程取消协议留给后续适配器；当前预算按本地可明确计量的数据定义。

## 决策

1. Provider 增加逐帧生产接口，旧的完整响应仍可使用。正常流帧包括 `{:text_delta, binary}`、`{:tool_start, %{operation_id: id, tool: name}}`、`{:arguments_delta, binary}` 和 `:done`。旧响应通过完整响应帧适配。Scripted 的 `gate`、延时、崩溃与错误条目是测试控制项，不是业务输出。
2. RunServer 为一轮模型请求创建独立工作进程与唯一请求引用，以异步消息驱动流。GenServer 在等待模型时继续处理 `snapshot`、订阅与取消。`start_stream/1` 立即返回请求引用；`step/1` 保留“等待本轮结束再返回”的使用方式，等待者不会占住 GenServer 的回调。
3. 每个工作进程交付一帧后等待 Runtime 确认，再继续生产。本地逐帧确认限制生产者对 RunServer 邮箱的灌入量。它不是跨网络的完整背压协议，也不保证慢订阅者的邮箱有界。
4. 流累积器只保存本轮候选响应。文本片段按字节累积，在 `:done` 后校验完整 UTF-8；工具参数此时才解析为 JSON 对象，并校验工具标识、参数和响应形状。同一轮不接受混合文本与工具响应、多个工具或不完整的流。分片可以跨 UTF-8 字符边界，最终组装后再校验。旧完整文本响应保留原 binary 契约，不额外添加 UTF-8 限制。
5. 只有完整、合法、预算内的响应才发送给 Kernel。工具提议被接受后进入 `waiting_tool`，随后一次显式 `step/1` 才执行工具。半截 JSON、取消前的文本与被拒绝的候选响应都不会建立业务操作。
6. 对外通知形状为 `{:agent_stream, run_id, request_ref, seq, event}`。`event` 为 `:started`、原始流帧或 `{:finished, status}`；每轮从 `seq = 1` 开始。请求引用与序号用于关联观察，不替代 Kernel 的业务 Event 序号。订阅只发送后续通知，同一 PID 重复订阅不会重复投递。
7. `cancel(server, reason)` 通过原有 Kernel 取消命令提交终态。取消成功后停止活动工作进程、清理定时器并结束等待调用者。已终结请求的迟到消息不得追加响应、事件或工具效果。终态再次取消仍服从 Kernel 的终态保护。
8. Runtime 控制输出字节、单轮流事件、工具调用次数、单轮模型时间和 Run 时间；保留 Kernel 的 `max_turns`。达到上限仍允许，超过上限或到期时提交 `run_failed`。预算失败遵循与普通转换相同的内存或 PostgreSQL 提交路径。
9. PostgreSQL 模式持久化已接受的完整响应及取消、失败事实，继续在同一事务中更新 Run、Event 和调度意图。实时片段、工作进程、请求引用、计时器、流缓冲、输出与流帧计数不进入数据库。工具提议数从已接受的 `operations` 得出，工具限额策略仍是 Runtime 配置。

自动产生的 Provider 失败原因可能包含不能持久化的运行时值。持久模式将此类原因收敛成 `{:unpersistable_failure, codec_error, diagnostic_string}` 的有界诊断，再通过原事务提交失败终态，避免因诊断本身不可序列化而持续卡住。显式用户命令中的不可持久化取消或失败原因仍被拒绝；不静默改变调用者提供的业务命令。

## 两条独立序列

```text
Scripted worker ── frame / ACK ── RunServer ── agent_stream ── 订阅者
                                      │
                         完整、合法、预算内？
                                      │ 是
                                      ▼
                                Kernel 命令
                                      │
                      内存 Event / PostgreSQL 事务
                                      │
                           新状态与调度意图
```

实时通知回答“本轮看到了什么”，业务事件回答“系统已接受什么事实”。例如先看到两个 `arguments_delta` 不表示数据库已有 `tool_requested`。订阅者退出、漏读或重连不会影响已接受状态；当前实现也不提供流通知重播服务。

快照只保留最近 128 条流通知用于观察，流预算仍按本轮所有已计数帧计算。这个窗口不是持久审计日志。读取快照、业务事件重建、数据库读取均不重新调用 Provider。

## 预算契约

| 配置 | 默认值 | 计量范围 | 终止原因 |
| --- | ---: | --- | --- |
| `max_turns` | 4 | 已接受的模型响应数；Kernel 状态与数据库已有此字段 | `:turn_budget_exceeded` |
| `max_output_bytes` | 65,536 | 同一 Run 进程累计模型输出字节，包含文本、工具标识和参数 | `{:budget_exceeded, :output_bytes}` |
| `max_stream_events` | 4,096 | 单轮模型请求的流帧数 | `{:budget_exceeded, :stream_events}` |
| `max_tool_calls` | 16 | 同一 Run 进程接受的工具调用提议数 | `{:budget_exceeded, :tool_calls}` |
| `model_timeout_ms` | 5,000 | 一轮模型请求的总时限 | `{:budget_exceeded, :model_timeout}` |
| `run_timeout_ms` | 60,000 | 当前 Run 进程的总时限 | `{:budget_exceeded, :run_timeout}` |

流式文本与参数取实际 `byte_size`；`tool_start` 还计 operation_id 与工具名称字节，防止大标识绕过限额。旧完整工具响应的参数按 ETF 序列化字节计量，标识也计入。`:done` 不增加字节但占一帧，完整响应适配条目占一帧；`:started`、`finished` 和 Scripted 控制项不计 Provider 帧数。不同响应表示的本地成本可能不同。

字节不是字符或厂商 token；这些限额不表示货币预算。`model_timeout_ms` 是整轮截止时间，收到新片段不会重置。Run 时限包含等待下一次手动推进的时间；暂停和阻塞不使本进程的总时限重新开始。计时使用单调时钟与带身份的消息，清除旧 timer 后仍需拒绝已进入邮箱的旧超时消息。

计数用于阻止 Runtime 继续接受超额数据，不是外部服务的完整计费记录。超限帧不会先被计入已接受计数；数据库版本冲突时，本地候选响应与预算变更一起撤回。若需要核算已生成但未被接受的远程成本，必须另建尝试级消费记录。

Runtime 接收和累积本地流的资源边界不等于外部服务的资源边界。工作进程被停止后，远程服务可能仍在生成、计费或完成已发送的动作；实际适配器需要各自的取消协议。该教学实现也不是对恶意、无限大单个 BEAM 消息的完整隔离层。

## 取消与竞争

取消与流完成最终都由同一个 RunServer 顺序处理。若取消先被接受，后续流完成消息不能把任务改回成功；若完整响应已经先提交为终态，后来的取消不能覆盖它。不能对并发到达的调用承诺固定胜者，应断言最多接受一个终态且事件可重建。

`cancel/2` 的成功返回在持久模式下仍位于数据库提交之后。若数据库发现 `expected_seq` 过期，Runtime 不能把本地取消当成已经提交的事实。L02 的版本检查、提交边界和 ACK 不确定性继续适用。

取消限制未来动作，不能回滚已经发生的工具效果。`blocked` 中可能存在已经生效但未确认的操作；取消后仍保留该操作的记录，不能将其解释为工具“从未执行”。Mock 的台账仍是内存数据，取消也不会将它升级为持久回执。

本周仅模型调用异步执行；Mock 工具是短时同步调用，不提供任意慢工具执行期间的即时取消。PostgreSQL 模式在执行工具前重新核对已提交序号与状态，已知陈旧的 RunServer 不执行工具；读完状态后仍可能发生跨进程竞争，因此这不是跨外部调用的 fencing。长期工具、lease、代次验证与外部幂等仍需后续协议。

## 验证方式

使用 Scripted 屏障：工作进程通知 `{:scripted_gate, gate_ref, worker_pid}` 后，等待 `{:release, gate_ref}`。测试进程收到屏障才读取快照、取消或检查数据库。正确性测试不靠 `sleep` 猜测流是否进行到一半。

测试至少覆盖逐帧文本与工具 JSON、跨字节分片、旧脚本兼容、缺少结束帧、非法混合与参数、工作进程异常、流中取消、迟到帧和超时消息、预算等于与超过上限、终态保护。持久模式在屏障前后核对完整业务事件与意图：中间片段不增加业务事件；取消或失败后没有 pending 意图；成功时投影与重建一致。原 L01/L02 测试和提交前后 kill 验收继续执行。

实验要求见 [L03](../../labs/L03-streaming-control.md)。实际测试数和运行结果由第 4 周验收记录提供，不在 ADR 中冻结。

## 代价与后续

每轮模型调用增加工作进程、监控、帧确认和定时器管理。流通知与业务事件分开后，UI 能看到未提交的候选文本，必须明确它尚未成为最终结果；`finished` 中的状态和业务快照才说明已接受的结果。

`max_turns` 之外的 Runtime 预算策略、输出计数和活动请求没有 checkpoint。本周不提供重启后续接半条流、恢复 Provider 游标、重建 Mock 台账或自动重试未知外部效果。未来若要跨进程重启延续全局预算，需将预算预留、消费与尝试身份纳入持久协议，不能从业务 Event 条数倒推所有失败流的成本。

## 官方资料

- [Elixir GenServer：普通消息与异步处理](https://hexdocs.pm/elixir/GenServer.html#module-receiving-regular-messages)
- [Elixir Process：进程监控](https://hexdocs.pm/elixir/Process.html#monitor/1)
- [Elixir Process：定时发送与定时器](https://hexdocs.pm/elixir/Process.html#send_after/4)

GenServer 文档要求在回调中通过 `handle_info/2` 处理普通消息；在回调中自行 `receive` 会阻塞它的正常处理。这是把模型等待放在工作进程、把控制权留在 RunServer 的依据。
