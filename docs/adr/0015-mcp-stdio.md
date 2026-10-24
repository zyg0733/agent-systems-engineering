# ADR 0015：固定版本的 MCP stdio 与非幂等恢复边界

- 状态：接受，用于第 16 周教学实现；真实验收以 validation-week16 为准。
- 日期：2026-10-21。
- 依据：[受控工具与调用配对](0004-controlled-tools-and-call-pairing.md)、[隔离执行器](0014-isolated-execution.md)、[MCP 实验](../../labs/L15-mcp-stdio.md)。

## 问题

前序工具接口在进程内执行。引入外部 MCP server 后，需要初始化与能力检查、独立传输生命周期、工具发现、请求 ID 配对和超时取消。远端描述或 annotations 不能扩大现有权限，也不能把可能已完成的非幂等动作变成安全重试。stdio 的 EOF 与本地进程退出同样不能证明业务效果未发生。

目前已经发布的 MCP 2026-07-28 改变了协议生命周期。直接套用最新文档而保留旧 initialize 握手，会把两个不兼容时代混在一起；本周需要一个明确可检查的版本边界。

## 决定

实现并固定 MCP `2025-11-25` 的 stateful stdio 子集。客户端按 initialize → initialized → tools/list → tools/call 运行，检查回传版本和 tools capability。2026-07-28 不是本实现支持的另一个常量；不支持版本立即结束连接，不自动降级、升级或回退普通宿主执行。

JSON-RPC 2.0 为 UTF-8，一行一个消息，stdout 不容许普通日志。客户端分别处理请求、通知、响应和 JSON-RPC error；每条连接只有一个有界在途请求，响应必须匹配原 ID。stderr 独立收集且有界，不根据日志存在判定调用失败。消息、分页、工具数量、请求和连接生命周期均设有限上界；重复 cursor、重复名称、错误 ID、非法消息和超限输入不能无限增长等待或缓冲。

MCP.Policy 来自可信宿主配置，固定 server 名、command、args、隔离策略以及批准工具的确切 input schema 和描述。局部工具名 `mcp.<server>.<remote>` 保留来源；当前 server/remote 名称使用有界 ASCII 字母、数字、下划线和连字符。发现只验证预先批准工具，不产生授权。远端多出来的工具、description、instructions、readOnlyHint/idempotentHint 不改变宿主权限、模型描述、重试或恢复策略。

Schema 校验采用有限的 closed-object 子集：object、array、string、integer、number、boolean、null、enum，有限长度和数值约束；显式 additionalProperties=false，拒绝未知关键字、refs、regex、组合器和其他 dialect。schema 与参数独立施加深度、节点和编码大小上限。不声明完整 JSON Schema 2020-12 或任意第三方 SDK 兼容性。

stdio server 在 W15 隔离边界内启动：固定绝对命令、不经 shell、不继承宿主秘密环境和额外 FD，只开放私有 workspace，网络默认拒绝且不可放宽，单目标进程禁止 fork。可信原生监督器将 server stdout/stderr 与控制帧分离，等待实际目标与监督器结束。后端、CPU/单文件/输出/wall-clock 约束和未实现的硬内存/总磁盘/Linux 能力延续 W15；MCP 不引入额外权限。

tools/call 超时或宿主取消时，给原 request ID 发送 advisory cancelled 通知；initialize 不发送此通知。已发送调用无法得到可确认结果时返回 unknown，并使该连接不再接收新工具调用。迟到响应不能配到其他调用。正常关闭先结束输入，再给受限退出机会，必要时回收本次拥有的进程；取消不代表回滚。

合法 JSON-RPC error 与 result.isError=true 分别映射为确认的协议错误和工具错误，保留有界 code/message/content 与请求身份。传输丢失、超时或非法响应在调用发送之后不能映射成“未执行”。工具结果继续绑定原 Runtime operation ID；连接/request ID 仅补充传输层配对。

创建 Run 时将 MCP policy 作为版本化 inert sidecar 持久化并绑定哈希，恢复时重验。MCP 工具按非幂等动作处理；不采信远端 idempotentHint 作为重放许可。prepared 后崩溃或发送后结果模糊的调用进入既有 unknown/reconcile 人工核对路径。已完成回执在重复投递时复用，不再启动 server；结果提交继续经过现有预算、lease/fencing 和调用 ID 校验。外部效果执行时不持有数据库行锁。

## 验证

使用仓库控制的微型 C fixture 和私有工作目录，不依赖真实外部服务或未固定的软件包。验证握手、发现分页、未批准工具、schema 漂移、版本与 capability 拒绝、日志和分片、ID 配对、确认的协议/工具错误、超时取消、迟到响应、进程清理与断连。再用实际 effects-before-reply 故障证明 unknown 可见、恢复不盲目重放、已完成回执重复投递不产生新效果。固定 fixture 是教学探针，不是通用服务器或完整 JSON parser；最终结论受本地已测子集限制。

新增测试与全量既有测试共同运行，正式实验输出保留原始结果、真实进程身份、清理状态与故障证据，默认拒绝覆盖旧目录。数量和成功结论必须来自实际运行，不能将计划中的案例当成已完成验收。

## 后果与后续边界

工具网关获得明确的协议适配层，同时保留现有权限与恢复不变量。代价是当前每次公共调用需要有限握手/发现开销，工具 schema 与协议范围较窄，第三方 MCP server 需要单独适配与互操作测试。后续扩展 HTTP/OAuth、其他功能或 2026 协议必须明确新契约及迁移测试，不依赖静默兼容猜测。

## 一手依据

- [2025-11-25 transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)：stdio framing、stdout/stderr 与 subprocess 所有权。
- [2025-11-25 lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)：initialize/initialized、版本协商与关闭。
- [2025-11-25 tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)：工具发现、分页、调用、工具错误与不可信 annotations。
- [2025-11-25 cancellation](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/cancellation)：取消请求及 advisory 语义，initialize 取消例外。
- [2026-07-28 transports](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)：每请求 `_meta`、协议消息方向与旧版本兼容边界。
- [官方 TypeScript SDK 迁移指南](https://ts.sdk.modelcontextprotocol.io/v2/migration/support-2026-07-28)：手工连接 StdioServerTransport 仍为 2025 era；新 stdio era 需要独立 serveStdio 入口。
