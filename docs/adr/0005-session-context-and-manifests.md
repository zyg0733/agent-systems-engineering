# ADR 0005：规范 Session、有限 Context 与可重建 manifest

- 状态：已接受
- 日期：2026-10-20
- 范围：第 6 周、L05、P1
- 延续：[ADR 0002](0002-transactional-storage.md)、[ADR 0003](0003-streaming-cancellation-and-budgets.md)、[ADR 0004](0004-controlled-tools-and-call-pairing.md)

## 背景

Runtime 已能流式推进受控文件修复，但只有当前 Run input 与 operations，没有独立的规范会话或有限上下文构造。若直接裁剪模型看到的数组而不保留来源，任务条件可能消失，调用结果可能失配，摘要也可能被误当作授权。P1 需要证明压缩后的请求仍精确保留任务事实、工具回执与权限，并能追溯每次实际模型输入。

## 决策

1. Session 是纯值，包含 id、version、facts、acceptance、constraints 和完整 messages。facts 为字符串键 JSON Map，要求与约束为字符串列表；消息为字符串键 Map，含稳定 ID、连续 seq、role 和 content。新增只通过 append API；追加保持 task 字段原值，不提供覆盖历史的更新 API。角色限于 user、assistant、note，不接收工具结果或 system 角色。
2. 工具事实继续由纯 Kernel 验证的 Run.operations 提供，保留完整参数、status 和结果封装。Provider 输出和工具回执不自动追加为 Session 消息。宿主显式选择要追加的内容，模型文本或摘要不能提升为宿主权限。
3. Context.build 使用规范 Session、当前 Run 和宿主提供的 inert permissions 生成 `%{context: payload, manifest: manifest}`。payload 保持旧 run_id/input/turn_count/operations/available_tools 字段，新增 task、session 身份、permissions、messages 和 summary。available_tools 来自宿主 Catalog，不能从 Session 叙述获得。
4. input、task 全部字段、Run 身份/轮数/完整 operations、Session 身份版本、permissions 与 available_tools 为保护内容。仅 session narrative 可裁剪，工具结果不截断、不转换 outcome、不拆开调用与结果。保护内容本身无法容纳时返回 `{:protected_context_too_large, required, maximum}`，不调用 Provider。
5. 预算度量为 payload 的确定性 ETF 实际字节，manifest 不计入、不传给 Provider。默认最大 262144 字节，近期消息上限 4，摘要上限 2048 字节。所有策略选项严格检查范围、类型、重复与未知键。该度量是本地实验输入大小，不是 token 或货币计费。
6. 完整 payload 放得下时，原样保留消息，summary 为 nil。超限后保留近期完整后缀，必要时继续去掉其中最旧消息；近期内容优先于摘要。省略前缀使用 `extractive_prefix.v1` 拼接带来源的原文后取 UTF-8 安全前缀，不调用模型或推断事实。摘要显式标为 `derived_summary.v1` 与 `untrusted_session_narrative`，绑定 omitted source IDs/hash；封装也受摘要字节预算。放不下时 summary=nil，manifest 记录 omitted_budget。
7. manifest 是确定性版本 1 审计值，包含 payload/protected/source Session/Run/effective policy hash、实际字节与预算、全部消息 ID/seq/hash 的 included 或 omitted 分区、摘要算法与来源、task/operations/permissions 保留证明。每条源消息只归属一个分区，摘要来源只能来自 omitted。无随机 ID、时间或外部请求。
8. Context.verify 从权威源重新构造并全量比较 payload 和 manifest，发现内容、来源或策略变化。Run 在构造前通过 inert Codec 检查，并复用纯 Kernel 状态规则校验整个投影和操作配对；合法终态也可作为审计源。纯校验丢弃返回状态和事件，不写入历史、不执行效果。hash 不是带密钥签名，不提供对所有权威源同时被重写的真实性保证。
9. SessionStore 持久保存完整规范值；append 在行锁下对 expected version 做 CAS，一次提交新版本与内容。ContextStore 追加不可变输入 capture，每行一次提交完整源输入、payload 和 manifest，并保存 Run/Session 投影元数据。读取先安全解码，再核对投影与确定性重建；不会产生模型或工具效果。
10. PostgreSQL RunServer 在构造 Context 后、Provider 启动前 capture。事务核对当前 Run 全值和序号，以及可选关联规范 Session 的当前版本/内容；COMMIT 成功 ACK 后才消耗 Provider 项。失败不调用 Provider。capture 为独立输入记录，不增加业务 Event 序号，不创建新的调度意图，不与随后模型结果提交合并。
11. RunServer 可接收 `session` 快照或 PostgreSQL 的 `session_id`，二者互斥。未提供时建立空 Session，兼容旧调用。宿主 append_message 在流进行中拒绝 busy，在终态拒绝编辑；关联 Session 使用持久 CAS。snapshot 包含当前 session、最近一次 built context 和可选 context_id；最近输入不随后续 Run 状态自动改写。

## 数据与事务边界

```text
SessionStore：完整 Session + version ────── 显式宿主 append / CAS
                         │
Run 当前已接受状态 ────────┼── Context.build ── 校验/裁剪/提取摘要
宿主权限与 schema ────────┘                       │
                                                 ▼
                         capture 事务：核对源 + 完整来源/payload/manifest
                                                 │ COMMIT / ACK
                                                 ▼
                                  Provider.stream（payload only）
                                                 │ 完整响应
                                                 ▼
                                 原有 Run/Event/意图提交事务
```

旧 capture 保留当时 Session，因此后来追加不影响历史读取；新 capture 不能用陈旧关联 Session 或 Run。一个 capture 只能证明输入被保存，不能证明请求发送、模型返回、结果落库或外部工具效果发生。capture 后崩溃可能留下尚未使用的输入记录；不据此自动重发请求或工具。同序号允许多个 capture，不以唯一行或 hash 冒充完整请求幂等协议。

保留完整 sources 意味着压缩只限制模型输入，不减少规范数据或数据库总存储量。工具回执与 schema 占用保护预算，可能使较小预算直接失败；这是保留证明的成本，后续若要外置大工具结果，需要独立的可寻址内容与读取协议，不能偷偷截断。

## P1 与验证

P1 使用完整 40 条 Session 消息，生成四份含提取摘要的压缩输入，验证任务字段、逐次增长的完整工具回执、宿主权限均与来源相等。流式 Scripted Provider 完成固定配送费修复，生成 diff 与 3/4→4/4 验收证据；另一个未完整参数的流被取消，零文件写入。默认 PostgreSQL 路径核对四条持久 capture 和规范 Session 未被摘要改写，并运行已有 Run 创建/转换各两个 COMMIT kill 探针。

Context 测试覆盖精确 ETF 边界、中文 UTF-8、保护内容超限、摘要缺失原因、来源全分区、确定性、叙述注入、failed/unknown 回执、完整 Kernel 投影/配对校验，以及 payload/manifest/源数据/policy 篡改。Session 与存储测试覆盖角色和事实形状、追加版本竞争、capture 提交前后 kill、损坏读取、独立 VM 安全解码。Runtime 测试证明 capture 在 Provider 前提交、失败不消耗脚本、busy 期间不改源版本，旧工具与 Streaming 仍兼容。

本阶段没有真实厂商模型或 LLM 摘要，也没有跨重启恢复 Provider cursor、Streaming、预算计数和文件工具台账。输入留档不等于执行恢复、模型输出录制或安全自动续跑。实验步骤见 [L05](../../labs/L05-session-context.md)，实际验收见 [第 6 周记录](../validation-week06.md)。
