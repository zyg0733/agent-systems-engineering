# ADR 0007：持久执行恢复、意图领取与工具核对

- 状态：已接受
- 日期：2026-10-20
- 范围：第 8 周、L07
- 延续：[ADR 0002](0002-transactional-storage.md)、[ADR 0004](0004-controlled-tools-and-call-pairing.md)、[ADR 0006](0006-history-checkpoints-and-recorded-results.md)

## 背景

已有 Run/Event/意图事务、Context 输入留档、完整模型结果录制与严格历史重建。它们可以还原已接受事实，但不能独立决定 pending 工作是否可以再次执行。原 RunServer 的 Provider cursor、预算与工具台账仍在内存；进程退出后重新创建默认值会丢失约束，盲目重发工具还可能重复产生外部效果。

本阶段需要独立、显式的安全续跑入口。它必须处理多 worker 竞争、owner 失联与迟到结果，并区分逻辑业务操作、具体投递尝试和外部回执。对于无法核实的非幂等效果，恢复应保留歧义并阻塞。

## 决策

1. 新增独立 Recovery 驱动与持久 Recovery 配置。创建任务时保存不可变脚本、Session、工具 workspace/权限、Context 策略与预算策略；保存 Provider cursor、累计资源进度、request attempt 与绝对 deadline。恢复读取并验证这些事实，不从 Event 数推算默认配置，也不重置预算。缺少配置的旧 Run 明确拒绝续跑。原 RunServer 保持原来的临时执行模式，不隐式升级旧历史。
2. Recovery.load 不领取意图、不执行 Provider 或工具。History/checkpoint 继续只读零效果。Recovery.step 显式处理当前一步；Recovery.resume 是执行到暂停的入口，可以调用模型或工具。重建与执行恢复采用不同入口，不能把 resume 误认为只读重建，也不能让 load 看见 waiting_tool 后自动调度工具。
3. pending 意图增加短事务领取、续租和释放协议。claim 绑定当前 Run/seq、owner、到期时间与单调代次 token；数据库互斥决定当前有效 owner。接管产生新 token，旧 token 不再拥有推进资格。结果提交重新核对当前意图、expected seq、owner/token 与有效期限。取消或其他事实推进会 supersede 旧意图，迟到提交不得覆盖新状态。
4. claim 只负责 Runtime 推进资格，不声称能够停止已经发出的外部请求。Provider 不持长期 Run 行锁等待；有界本地 Mock/Files 在短事务临界区重新验证 claim 后执行，效果与最终 Runtime 结果分开提交。文件系统不能随这个数据库事务回滚。此临界区不适合直接扩展为等待任意远程服务；一般外部效果仍需稳定 operation 身份、幂等契约或权威核对，数据库 fencing 不能单独阻止旧 worker 在外部系统产生效果。
5. 持久工具 ledger 分开保存 operation、delivery attempt 与 receipt。operation 绑定 Run、工具、稳定调用 ID 与精确参数；attempt 表示一次投递或核对，具有独立身份。重试继续使用原 operation 身份并新增 attempt，同一 operation 更换参数明确冲突，不生成替代 ID 绕过去重。
6. 新持久 Mock 外部账本原子保存业务效果与回执，为同一 operation/参数返回原回执并保持效果计数。它独立于执行进程生命周期，支持新进程按稳定身份查询。此保证仅适用于本地演示外部系统的明确契约，不外推到任意远程 API。
7. 在投递前持久保存必要 operation/attempt；无法确认外部结果时保留 unknown。恢复先查询已有回执与外部事实，查到匹配结果后才提交 observation/reconciliation。缺失本地结果不代表外部没有执行；缓存未命中不构成权威否定。再次投递仅在工具幂等或核对契约明确允许时进行。
8. 文件效果不能参加 PostgreSQL 事务，且没有通用的外部 operation 回执。已经准备但缺少可靠结果的文件操作按歧义处理，阻塞并要求明确人工核对，不自动再次执行，也不从当前内容相同猜成功。人工核对是绑定原 operation 和 expected seq 的新事实，保留原 attempt 与未知观察。取消不撤销已发生文件效果。
9. 模型请求使用先留档的 Context 与持久请求身份。调用前扣除一次 model attempt 机会；每个 frame 在 ACK 前持久扣除累计输出字节与本请求帧数，已扣字节跨崩溃保留。完整结果仍须通过 schema、预算、Kernel 和录制绑定校验；接受结果、相关 Event/意图、录制与 cursor 推进保持事务一致。COMMIT 前退出不留下半个接受状态，COMMIT 后 ACK 丢失通过重新读取确认，不再次消费相同脚本位置。未完成流不是已接受录制；不能将本地确定性脚本的能力描述为真实网络连接续接。
10. 持久数据继续精确检查版本、投影、来源绑定与 safe Codec。不可持久化的 PID、reference、函数及任意未授权 struct 不进入配置或 ledger；故障 hook 是执行时注入，不作为恢复配置保存。不增加 unsafe ETF fallback，也不 silently 迁移未来版本。
11. 故障验证使用真实进程 kill 与独立连接/BEAM，覆盖领取、请求/投递 attempt、效果、结果 COMMIT 和 ACK 边界，同时验证并发领取、lease 接管、旧 token、取消迟到、参数冲突、持久预算与 unknown 文件阻塞。历史重建的模型/工具零调用证明继续保留。

## 提交与效果边界

```text
已提交 Run/Event + Recovery 配置
             │
             ▼
       短事务领取意图 ── owner / lease / token
             │
             ▼
       持久 request / operation / delivery attempt
             │ COMMIT
             ▼
       Provider / 有界本地工具短临界区
             │
       ┌─────┴─────┐
       │ 已知回执   │ 结果未知
       ▼           ▼
   核对 claim     查询已有回执 / 外部事实
       │           ├─ 可证明结果 ── 核对 claim
       │           └─ 无法证明 ── unknown / 阻塞 / 人工核对
       ▼
 一个事务：Run + Event + 旧/新 intent + 相关结果/恢复进度
             │ COMMIT
             ▼
      ACK；丢失 ACK 后重新读取事实
```

外部效果和最后一个结果事务之间仍有窗口。持久 Mock 的去重和查询使这一窗口可恢复；一般文件操作没有相同契约，因此以阻塞保护事实完整性。operation 身份解决业务去重，claim token 解决当前推进资格，两者不能互相代替。

## 代价与范围

执行配置、attempt 与 receipt 增加存储和验证成本。lease 会带来时间与接管规则；它不能保证旧 worker 立即停止。绝对 deadline 跨进程持续约束 Run，主机时钟和数据库可用性仍是本地实验的运行前提。

本阶段没有常驻 dispatcher、公平调度、优先级、多队列或完整 worker 管理，不把最小领取协议描述为完整调度系统。仍使用离线 Scripted Provider，没有真实模型/SSE 重连、厂商请求幂等或费用核对。安全续跑只适用于显式保存 Recovery 配置的 Run，以及已声明能力契约的工具。

一般外部系统与 PostgreSQL 不共享事务；本决策不承诺外部 exactly-once、自动撤销文件效果或未知结果自动完成。hash 继续用于完整性和绑定检查，不是签名。

实验步骤见 [L07](../../labs/L07-recovery.md)，实际验收见 [第 8 周记录](../validation-week08.md)。
