# L15：MCP stdio、权限与恢复边界

对应第 16 周；前置 L01—L14，建议用时 12—16 小时。先读 [MCP ADR](../docs/adr/0015-mcp-stdio.md)、[运行手册第 14 节](../docs/recovery-runbook.md#14-mcp-stdio-连接与核对) 与 [验收记录](../docs/validation-week16.md)。本仓库沿用连续实验编号，因此第 16 周对应 L15。

本实验把 MCP 接入已有的工具权限、调用 ID、结果回执与 unknown/reconcile 流程。目标是能用真实 stdio 进程说明“发现工具”“批准工具”“收到协议响应”和“确定业务效果”各自提供什么证据。

## 1. 固定协议与实现范围

本周固定 MCP `2025-11-25` 的 stateful stdio 子集：`initialize`、`notifications/initialized`、分页 `tools/list`、`tools/call`、ping、受限通知处理与调用取消。JSON-RPC 2.0 消息为 UTF-8，每行一个对象；stdout 只承载协议，stderr 独立收集。连接初始化之前不能直接调用工具，版本或能力不匹配时结束连接。

当前最新的 `2026-07-28` 是另一套有 breaking changes 的协议：移除了 initialize/initialized，将版本与客户端能力放入每个请求的 `_meta`，并引入 `server/discover`。本实验不会把旧握手自动解释为新版本，也不声称实现新协议。相关原文见 [2025 生命周期](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)、[2026 传输规则](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports) 与 [官方 SDK 迁移指南](https://ts.sdk.modelcontextprotocol.io/v2/migration/support-2026-07-28)。

没有实现 Streamable HTTP、OAuth、resources、prompts、sampling、roots、elicitation、task 扩展或完整 SDK 兼容性。Schema validator 只接受本文列出的有限子集，不是完整 JSON Schema 2020-12 实现。

## 2. 准备与运行

在项目根目录执行。正式实验包含持久化故障窗口，需要现有 PostgreSQL；内存调用示例不依赖数据库：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
./scripts/mix lab.mcp
./scripts/mix lab.mcp --output artifacts/week16-mcp-repeat
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

默认输出 `artifacts/week16-mcp`，目录已存在时拒绝覆盖。每次复验选择新目录，并保留失败证据。平台或隔离后端不可用时返回明确错误，不退回普通宿主进程。

实验服务器是仓库控制的 `priv/mcp/fixture_server.c`。`MCPFixture.ensure_executable/0` 用本机 clang 编译它，`MCPFixture.tools/0` 定义可信宿主批准的 5 个小工具，工厂 `MCPFixture.policy/3` 将二者装入版本化策略。这是离线固定探针，不是生产 MCP server 或通用 JSON 库；它不会下载包、启动 shell 或连接外部服务。`write_note` 的固定解析器只支持本实验使用的简单字符串，不能从探针成功推导任意第三方服务器兼容性。

## 3. 第一次真实 stdio 调用

在 `./scripts/iex -S mix` 中执行以下示例。目录必须是本次自己创建的私有工作目录；不要使用 home、整个仓库或含私人数据的目录：

```elixir
alias AgentSystemsLab.{MCP, MCPFixture}

root = Path.expand("artifacts/w16-example-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
{:ok, policy} = MCPFixture.policy(root, "normal", tools: ["echo"])

{:ok, receipt} = MCP.execute(policy, "mcp.fixture.echo", %{"text" => "stdio receipt"})
false = receipt["isError"]
%{"echo" => "stdio receipt"} = receipt["structuredContent"]
[%{"type" => "text", "text" => "stdio receipt"}] = receipt["content"]
true = receipt["transport"]["target_exited"]
true = receipt["transport"]["guardian_exited"]

# 服务器发现了其他工具；宿主只批准 echo。
{:error, :mcp_tool_not_allowed} =
  MCP.execute(policy, "mcp.fixture.write_note", %{"path" => "note.txt", "content" => "no"})

File.rm_rf!(root)
```

公共入口完成启动、握手、发现、调用和关闭；结果保留协议请求身份及本次传输的清理记录。逐项字段和正式运行结果见验收记录。只有工具结果成功而没有目标、监督器实际退出证据，不能判连接生命周期通过。

如需观察长连接生命周期，可以使用 `MCP.Connection`，先 `start_link/2`、再 `discover/1`、`call_tool/4`，最后 `close/1`；每条连接最多一个在途请求。不要从模型输入构造这些宿主对象，正常 Runtime 应通过现有工具网关调用。

## 4. 发现不等于授权

`MCP.Policy.new/1` 的可信配置固定 server 名、绝对命令、argv、隔离策略、批准工具、描述和精确 input schema。局部工具名为 `mcp.<server_name>.<remote_name>`，当前名字仅接受有界 ASCII 字母、数字、下划线和连字符，避免跨服务器名称歧义。

工具发现必须完成有界分页，再检查批准工具是否全部存在且 schema 完全一致。重复名称、重复 cursor、缺失、schema 漂移或超出页数/工具数量上限时停止。服务器额外提供的工具不会获得权限。远端描述、instructions、`readOnlyHint` 或 `idempotentHint` 不能修改广告给模型的宿主描述，也不能获得重试、网络或文件权限。

本地 schema 支持 object、array、string、integer、number、boolean、null 与 enum；object 必须显式 `additionalProperties: false`。支持有限 properties、required、items、长度及数值上下界；可选 title/description 和固定 2020-12 `$schema` 仅作元数据。`$ref`、regex、combinator、未知关键字或其他 dialect 在配置时拒绝。schema 与参数分别有深度、节点和编码大小上限，字符串长度按 Unicode codepoint 计算。发现的 schema 必须与已通过此校验的宿主 schema 精确一致，不接受“差不多”。

MCP 没有提供额外 OS 权限。本周复用 W15 Seatbelt 的单目标进程、默认拒绝网络、固定文件工作区和资源限制。模型不能提交 server command、env、profile、workspace 或新策略；stdio 也不继承 Repo socket 或宿主秘密环境。Linux、硬内存和总磁盘配额仍未实现。

## 5. 超时、取消与错误分类

| 触发点 | 应保留的证据与处理 |
| --- | --- |
| 本地权限/schema 拒绝 | 在发送 tools/call 前拒绝，不能伪造远端错误回执 |
| initialize 版本/能力不符、发现漂移 | 结束连接，不执行 tools/call；initialize 不发送 cancelled 通知 |
| 合法 JSON-RPC error | 保留 code/message 与请求 ID，映射为已确认的协议错误 |
| 合法工具 result 且 isError=true | 保留 content，映射为已确认的工具错误，不等同于传输断连 |
| tools/call 超时或宿主取消 | 给原 request ID 发送 advisory `notifications/cancelled`；结果进入 unknown，连接不再承接新工具调用 |
| malformed/oversized/wrong-ID/EOF | 对已经发送的调用保留未知结果；不能生成“未执行”结论 |
| 迟到响应 | 不提交给新的调用 ID，不撤销已判 unknown 的结果 |
| 关闭/调用者崩溃 | 关闭输入，给服务器退出机会，必要时回收；核对本次目标与监督器退出 |

超时不能证明效果未发生，取消通知也不是事务回滚或服务器确认。使用固定 `after_effect_drop` 模式：服务器向自己的 workspace 文件追加一次，随后在回复之前退出。观察文件效果存在且没有可确认工具响应，这是本周最重要的故障窗口。

## 6. 保持已有恢复不变量

宿主在创建 Run 时持久化 MCP policy 的 inert sidecar 及其哈希，恢复时校验版本、策略与哈希。模型无法覆盖此配置。工具 operation ID 与 JSON-RPC request ID 有不同用途：前者跨 Runtime 重试稳定，后者只在单条连接中配对；两者都要在回执中可追溯。

MCP 工具按非幂等处理，远端 `idempotentHint` 不会变成宿主重放许可。调度意图准备后崩溃、调用发送后断连或效果完成后丢响应，都应遵循已有 unknown/reconcile 路径，进入可见人工核对队列，不自动重放。完成回执的重复投递只复用原结果，不能再启动服务器或执行工具。结果写回仍经过原 lease/fencing、预算与调用 ID 校验；连接清理不能代替这些约束。

故障注入应先有实际握手/请求已发送的证据，再触发 kill 或断连。检查外部效果次数、原 operation 状态、核对队列、回执身份和新进程恢复行为；仅看到 Task DOWN、异常或 timeout 不足以证明命中预期窗口。

## 7. 交付与评分

至少覆盖：正常发现/调用；分页；宿主未批准工具；schema 漂移；版本与 tools 能力不符；stderr/分片；请求 ID 配对；协议错误/工具错误；超时取消与迟到响应；进程清理；effects-before-reply 丢失；持久化重复投递与新进程恢复。所有旧测试也必须通过。

读取 `artifacts/week16-mcp` 的真实 summary、逐项调用结果、固定 fixture 身份与故障记录，核对实际已完成数量和失败项。所有计数、文件名及运行平台以 [验收记录](../docs/validation-week16.md) 为准。保留未支持能力，不能把 mock 返回值或文件存在当成协议互操作与 OS 生命周期的完整证据。完成 [参考解答](solutions/L15.md) 中的问题，并对照 [ADR](../docs/adr/0015-mcp-stdio.md) 与 [运行手册](../docs/recovery-runbook.md)。
