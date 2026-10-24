# 第 16 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境为 macOS arm64、Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6；沿用 mix.lock，没有新增 Hex 依赖。第 16 个迁移 `20261022000000_add_mcp_policy.exs` 为既有恢复记录增加两个可空字段，开发与测试库均已迁移，旧行不变。

## 交付与协议决定

完成 MCP stdio、工具发现/调用、连接生命周期、超时取消、错误映射与原 Runtime 集成。配套 [L15 实验](../labs/L15-mcp-stdio.md)、[参考解答](../labs/solutions/L15.md)、[ADR 0015](adr/0015-mcp-stdio.md) 与[运行手册第 14 节](recovery-runbook.md#14-mcp-stdio-连接与核对)。

固定 **MCP 2025-11-25 stdio 子集**。原计划研究的 2026-07-28 已取消 initialize/initialized 并改变能力传递；本次不混用两个时代、不仅替换版本常量、不静默协商未实现版本。[官方变更说明](https://modelcontextprotocol.io/specification/2026-07-28/changelog)直接支持这个版本区别。旧版传输、生命周期、工具和取消的一手依据列于 ADR，当前实现没有宣称完整规范或任意 SDK 兼容。

| 组件 | 行为与边界 |
| --- | --- |
| `MCP.Policy` / `Schema` | 宿主固定命令/参数、W15 隔离与批准工具；精确 input schema、宿主描述；有限 closed object/array/string/number/integer/boolean/null/enum；复杂度有界，不支持关键字直接拒绝 |
| native stdio guardian | 单目标 Seatbelt、stdin/stdout/stderr 独立管道与可信 framing；继承 FD/环境收窄；CPU/文件/FD/总输出/wall 限制，owner 丢失后回收；没有宿主执行 fallback |
| `MCP.Connection` | initialize/initialized、版本/tools capability、分页与 cursor/工具上限；一个在途请求；下层也校验宿主授权；独立 request ID 配对，不授权 sampling/roots/elicitation |
| 取消与关闭 | call 超时发送相同 ID 的 cancelled；initialize 不发取消；连接 tainted、迟到回复忽略、不重投；先刷新输入再 EOF，必要时回收并观察真实退出 |
| 错误 | `mcp_rpc_error` 保留 code/message 与请求身份；isError=true → `mcp_tool_error` 保留内容；已发送调用的断连、错误 ID、畸形/超帧与取消 → unknown |
| Gateway / RunServer | 未授权/非法参数在 intent 前拒绝，MCP 与旧工具一样配对；MCP 异步可取消，非预期 Task 退出保守 blocked，不能向 Mock 核对 MCP |
| 恢复 / 持久化 | 独立不可变 policy sidecar/hash，不改 config v1；prepared → 锁内资格/期限复验 → 事务外执行 → fencing 回执；保留 Run/任务/retry/观测 lease 最早期限 |
| 重建 | confirmed receipt 重复投递不再启动服务器；MCP 一律非幂等未知核对，不信 idempotentHint；27 个执行入口重建零调用，安全 Codec 可在新 BEAM 读取连接层错误 |

## 自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终 **694 passed（692 tests、2 doctests），0 失败**，测试用时 82.0s；原 **10/10 fixtures** 与四个 COMMIT 前后真实进程 kill 检查全部通过。完整结果：[week16-check-complete.log](../artifacts/week16-check-complete.log)。无数据库模式 **359 passed（357 tests、2 doctests），335 个数据库测试排除**，用时 10.9s，见 [week16-memory-tests.log](../artifacts/week16-memory-tests.log)。check 包含格式、无警告编译与 16 个迁移。本机 Seatbelt 用例实际执行；Linux 的平台测试依旧明确排除，不能冒充 Linux 后端通过。

| 本周测试组 | 数量 | 主要判据 |
| --- | ---: | --- |
| MCP Schema | 12 | closed schema、Unicode codepoint 长度、数值/枚举/array、未知关键字与 JSON/复杂度边界 |
| MCP Policy | 12 | 精确配置与 v1 Codec、命令权限、host 名称/描述、发现额外工具不授权、重复/missing/drift 拒绝 |
| MCP Transport | 28 | 真实 stdio、分片/stderr/ping/反向请求拒绝、分页/循环/重复、协议错误、超时/取消/迟到、清理/崩溃、权限/参数、邮箱消息保留 |
| MCP Gateway / RunServer | 5 | 宿主权限与 paired receipt、未批准不创 intent、不起服务器；取消仍响应、Task 异常保留 unknown |
| Durable MCP | 8 | 不可变 sidecar 与旧 Run、回执复用/零执行重建、发送后崩溃、效果后断连、SQL 锁外运行/迟到 fencing、deadline、独立 BEAM 读取真实错误回执 |
| MCPDemo | 4 | 严格选项、旧证据/全局消费者保护、起始失败保留报告、20 个完整窗口与恢复判据 |

本周新增 69 项，W15 已有 625 项保持。开发过程中先前完整 693 项已通过；最终补充了安全词汇预加载和真实 pre-call error 的新 BEAM 回归，再对冻结版本执行最终 check。开发回归日志：[75 项工具/恢复回归](../artifacts/week16-integration.log)、[新 BEAM 错误回执回归](../artifacts/week16-mcp-fresh-codec-test.log)、[实验测试](../artifacts/week16-demo-tests.log)。这些有各自范围，不加总冒充独立新增测试数。

## 正式实验

```sh
./scripts/mix lab.mcp --output artifacts/week16-mcp-final
```

完整模式 **20/20 通过**：18 个 stdio/权限/生命周期窗口、两个真实 PostgreSQL 恢复窗口。`all_passed` 表示符合判据，实际业务保留 **1 succeeded、1 expected_blocked/manual**。不会为了全成功自动确认模糊动作。

| 实验组 | 真实观察 |
| --- | --- |
| 正常/分片/stderr/分页 | init→initialized→list→call；echo 与原 request ID 相等；分片仍重组；stderr 不进入 JSON parser；分页实际两次 tools/list |
| 非法授权与参数 | tools/call 前拒绝，服务器也未启动；远端描述与 idempotentHint 不改变 host policy |
| 版本/schema 漂移 | 实际服务器响应不符，拒绝后没有 tools/call |
| RPC/tool error | 真实配对响应，分别保存 `mcp_rpc_error` 与 `mcp_tool_error`，不冒充 unknown 或未执行 |
| 超时/错误 ID/畸形/断连 | 各仅发送一次调用，返回 unknown；超时 trace 中的 cancelled.requestId 与原调用一致 |
| 文件越界 | 服务端尝试追加自己的 workspace 外 canary，内核拒绝，原内容保持不变 |
| 显式取消 | 实际 wait 调用发出后发送取消，回报 unknown，目标与 guardian 退出 |
| 调用方崩溃 | 确认实际 server 已收到 call，再 kill BEAM caller；连接、目标与 guardian 独立退出 |
| 迟到回报 | 服务端忽略取消后实际迟到应答，连接仍 tainted，不接收新调用，没有重投 |
| 持久回执复用 | 同 claim 重复执行复用原回执，实际 tools/call 仍 1；完成 Run 后27个入口全部零调用 |
| 效果后断连 | append 真正发生后服务器退出不回结果；文件为 ONE_EFFECT，工具调用 1；manual queue unknown 可见，自动 reconcile 拒绝且不再执行 |

正式报告：[report.json](../artifacts/week16-mcp-final/report.json)；日志：[week16-mcp-final-run.log](../artifacts/week16-mcp-final-run.log)。每项保留 policy、raw execution、summary 与实验自有 `.mcp-trace.jsonl`；两个持久 Run 的 ID 与 namespace 在 manifest/report 中保留，不删除正式证据。

stdio-only 模式需要显式 `--memory`，期望 18 项，mode=stdio_only、recovery_verified=false。它可以关闭数据库运行，不能代替上述完整恢复验收。默认输出目录拒绝覆盖；失败仍留下失败位置和已完成记录。

## 独立复核与版本留证

原 `artifacts/week16-mcp` 的 20 项和独立核验已通过，之后发现安全 Codec 的词汇预加载应包含 Connection/Stdio，因而新增了真实错误回执的新进程测试。原目录不覆盖，不把旧快照冒充最终代码；补强后使用全新 `week16-mcp-final` 留证。

最终独立审计 **218/218 通过**。独立 BEAM 对两个正式 Run 做全量/checkpoint 重建，核对当前状态、录制、操作台账与 7 张持久表的原始行哈希：逐项不变，两个 Run 各 **27 个执行入口全部零调用**，人工队列继续可见。独立 Python 对逐项 raw/summary/report、16 次 tools/call 的唯一 ID 与取消配对、单次文件效果及源码/native build/binary manifest 做只读检查；**18 个目标 + 18 个 guardian，共 36 个自有 OS 身份全部不存在**，217 个源码/native 文件与起跑基线一致。见 [independent-audit.json](../artifacts/week16-mcp-final/independent-audit.json)、[独立重建](../artifacts/week16-mcp-final/independent-rebuild.json)及[源码/native manifest](../artifacts/week16-mcp-final/source-native-manifest.json)。

审计只验证当前证据与当前持久事实，不声称再次执行 syscall 或重新制造服务器崩溃；原始故障由实际实验 trace 证明。旧 canonical 独立审计检查 34 个身份，遗漏的两项 durable guardian 已在最终审计从持久回执提取补齐；旧证据保留其原覆盖范围。最终独立重建脚本首次因遍历 DateTime 的 Access 用法失败，原日志保留，修正产物脚本后重跑通过，产品源码没有因此变化。源码变化会使冻结检查失败，必须用新目录重跑。审查中也补齐了：直接 Connection 的白名单/schema 校验、调用者邮箱不被吞、RPC 错误配对身份、取消通知在 EOF 前刷新、独立 caller 死亡回收，以及工具错误 outer tuple 与既有语义一致。

## 当前限制

只证明当前 Seatbelt、固定 C fixture 与实现子集。fixture 仅用于固定教学输入，不是生产 JSON parser 或通用 MCP server；没有第三方服务互操作、远程 HTTP/OAuth、2026 协议、完整 Schema、任意子进程、Linux、硬内存/总磁盘或生产安全认证。

服务器启动也可能有副作用；“没有 tools/call”不等于任意服务器都没有产生任何效果。授权 COMMIT、OS exec、效果与 receipt COMMIT 不是一个原子事务；取消/进程退出不回滚已发生的文件变化。已确认错误也不证明 effect:none。未知 MCP 调用不自动重放，不宣称远端 exactly-once。OS 暂停/强杀 native guardian 的边界、整个 BEAM 强杀后的私人控制文件与身份核验继续遵守 W15 运行手册。
