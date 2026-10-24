# 第 4 周验收记录

验证日期：2026-10-20，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6；沿用第 3 周运行时、依赖锁和数据库配置，没有新增 Hex 依赖。

## 实现结果

Provider 新增 `stream/3`，Scripted Provider 在独立、与 RunServer 链接的监督任务中逐帧生产响应。每帧同步等待 Runtime 确认；RunServer 在等待模型时继续处理快照、取消和超时。旧 `respond/2`、完整响应脚本、`step/1` 与原有 fixture 保持可用。

纯 Stream 累积器在完成时校验最终 UTF-8 文本或 JSON 对象参数，拒绝缺少结束、混合模式、多个工具和完成后继续输出。旧完整响应保留原 Map 与二进制语义。工具提议必须等到 Provider 成功返回并提交转换后才被接受；实际工具效果仍需要后一次显式 step。

新增累计输出字节、单轮帧数、工具提议数、模型期限和 Run 总期限；延续已有模型轮数预算。限制使用严格整数配置，计时用单调时钟；收到新片段不延长期限。取消和超时终止活动任务、清理 timer、回复等待 step 的调用者，迟到帧和旧请求消息不能改写状态。

PostgreSQL 仍只保存已接受的完整业务事实。半截流不增加 Event 或调度意图；成功、取消或预算失败后先提交再确认。另补强两条错误路径：工具执行前拒绝已知陈旧的持久状态；不可编码的自动 Provider 错误转为有界诊断后保存失败终态。安全 Codec 没有放宽，显式用户命令仍受原校验约束。

## 完整自动化验收

```sh
./scripts/mix check
```

结果：**137 passed，包含 135 个测试与 2 个 doctest**，0 失败。第 3 周的 75 项全部保留通过，新增 62 项。格式检查、编译警告检查、测试库迁移、10/10 原有 fixture，以及四个 PostgreSQL 提交边界 kill 验证全部通过。

| 新增测试 | 数量 | 主要证据 |
| --- | ---: | --- |
| Stream / Scripted Streaming | 22 | 文本与 JSON 分片、跨 UTF-8 边界、协议失败、背压、gate 和旧响应兼容 |
| Budget | 7 | 严格配置、等于/超过边界、累计字节、空片段、工具标识计量 |
| RunServer Streaming | 25 | 非阻塞控制、同步 step 取消、迟到消息、超时、预算、worker 与订阅者清理 |
| PostgreSQL Streaming | 8 | 接受边界、取消、预算、owner kill、陈旧工具、错误规范化和新 VM 读取 |

取消、半截 JSON 和任务清理测试使用显式 gate 协调，不靠随机 sleep 命中边界。时间测试用 gate 持续等待期限；另将真实截止设为已过期，证明尚未处理 timer 时也不能继续执行工具。

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

结果：**107 passed，30 个数据库测试明确排除**。该模式证明内存实验无需数据库，但不能替代完整持久化检查。

## 演示实测

以下三条命令均实际运行，业务事件重建结果都与最终状态一致：

| 命令 | 终态 | 接受轮数 | Mock 请求 / 效果 | 接受输出字节 |
| --- | --- | ---: | --- | ---: |
| `./scripts/mix lab.stream` | `succeeded` | 2 | 1 / 1 | 87 |
| `./scripts/mix lab.stream --cancel` | `cancelled` | 0 | 0 / 0 | 40 |
| `./scripts/mix lab.stream --budget` | `failed` | 0 | 0 / 0 | 0 |

正常演示依次显示参数分片、`finished: waiting_tool`、工具结果和文本分片。取消演示在工具参数 gate 处结束，业务历史只有 `run_started`、`run_cancelled`。预算演示的上限为 10 字节，工具标识已经超限，拒绝该帧并保存 `{:budget_exceeded, :output_bytes}`。

## PostgreSQL 与独立 BEAM 证据

- 半截工具参数时仅有 seq 1 的 `run_started` 和 pending model 意图；完整响应接受后才出现 `tool_requested` 与 tool 意图，效果数仍为 0。
- gate 处取消后，保存 seq 2 的 `run_cancelled`，旧意图 superseded，无 pending 意图；旧帧和 timer 不改变已提交事实。
- 半截流时真正 kill RunServer，链接的 Provider 任务也退出；数据库保持完整旧版本，仍只有 model 意图，没有候选片段。
- 另一控制者先保存取消后，旧 owner 的工具 step 返回 stale_sequence；Mock 请求数和效果数均为 0。
- 输出超限、非法 JSON 与包含 PID 的自动错误均能保存明确失败事实。三个独立 Elixir VM 分别读取预算原因、JSON 解码原因与规范化诊断，读取后重建核对成功。

独立 VM 的预期失败原因使用字符串比较，避免在读取前由测试脚本预先创建所需 atom，从而掩盖安全解码词汇加载问题。Storage 显式加载受信任的 Budget、Stream、JSON 和 Runtime 模块；没有使用不安全解码回退。

## 实验材料

[L03](../labs/L03-streaming-control.md)、[参考解答](../labs/solutions/L03.md)、[ADR 0003](adr/0003-streaming-cancellation-and-budgets.md) 与 README 已更新。

手册的主要 Elixir 示例已组成断言脚本在实际项目运行：文本通知与重建、工具参数 gate 与效果边界、取消与 worker DOWN、迟到帧/timer、中文 5/6 字节边界，以及 PostgreSQL gate 前后的 SQL 与意图核对。脚本完成后仅删除自建 Run 数据。CLI 三条命令另行实跑。

## 本阶段边界

本周交付 Provider 通用流协议及离线 Scripted 实现，尚未接入厂商 HTTP/SSE 或计费 API。字节不是 token 或金额。模型任务可运行中取消；短时 Mock 工具仍同步执行，未声称可中断任意慢工具。

流预览最多保留 128 条通知；生产者逐帧确认不保证慢订阅者邮箱有界。工具执行前读取可拒绝确定陈旧状态，读取与效果之间仍有并发窗口，后续需要 lease、fencing 与持久操作台账。

新增策略、流计数和期限不构成持久 checkpoint。读取数据库不会恢复半条流、Provider 游标或 Mock 台账，也不会自动重发工具。取消保留已有效果与 unknown 操作事实。远程 CI 未执行。
