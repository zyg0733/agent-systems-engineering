# ADR 0010：从持久意图领取单步工作并有限并发执行

- 状态：已接受
- 日期：2026-10-21，Asia/Shanghai
- 对应阶段：第 11 周、P3、L10

## 背景

P2 已验证同一业务身份下的恢复、工具台账、未知结果核对、有限重试与 claim fencing。执行仍由显式调用者推进，未来 due 需要操作员或实验观察者再次调用。后台执行不能引入一份与 Event/Run 分离的事实来源，也不能因为多 Worker 而丢失已建立的预算、回执或未知结果约束。

本周把持久意图接到周期发现、原子领取和有限 Worker 上。用户明确要求租约续期与到期重试，因此一并实现进程级续期与失联接管；操作系统 SIGSTOP/SIGCONT、生产网络分区、外部 fencing 与全局背压仍在后续验证范围。

## 决策

### 持久意图是发现源

保留现有 Run/Event/下一 Intent 的原子提交。Scheduler 默认关闭；显式启动后周期扫描，可以接收 wake 提示。提示既不是唯一来源，也不替代 claim，因此丢失提示只增加发现延迟，重复提示不授权重复业务。

默认只领取已登记 Recovery、仍处于可执行状态的当前意图；排除终态、blocked/reconcile、尚有有效 lease 的工作及原 due 未到的 retry。`run_ids` 可限定教学、测试或操作范围。旧 volatile RunServer 的内存任务不会被猜测配置后自动接管。

### Run 先锁，领取后执行

`IntentStore.claim_next/2` 先锁 Run，使用 `FOR UPDATE SKIP LOCKED` 允许其他消费者处理未锁住的 Run，然后锁其当前意图，并重验 seq、执行资格与租约。锁顺序与 Storage/Retry/现有 IntentStore 保持一致。每份新 claim 有独立 token 与递增 generation，只有 COMMIT 后返回。

Worker 调用 `Recovery.execute_claim/2` 执行一个已经领取的步骤，不通过 Run ID 再领取。已确认结果仍按原协议复用，所有写入继续验证当前 token/generation。一次步骤结束后重新参加领取，不让单个 Run 在一个槽位中无限循环。

### 有限并发与独立续期

每个 Scheduler 只启动配置数量的在途工作。续期与执行并行，使用 PostgreSQL 时间延长同一 token 的 expiry，保持 generation 不变；不得复活已经到期的 token。续期者与执行者的生命周期绑定，失联或停机后不永久续期僵尸工作。

未经过受控清理的 Worker kill 可能留下有效 claim，接管等待实际 lease 到期。正常停止先终止并等待 executor 退出，再尝试释放自身仍有效的资格；无论哪种路径，operation/attempt 台账都保留。结果不明时按工具能力继续，不将进程退出或 lease 超时解释成目标未执行。停止调度器不撤销外部效果，旧 token 的迟到提交与错误释放仍必须被拒绝。

### Due 投影与优先级

在 Intent 增加 `available_at` 发现提示；Retry 状态变化时同一事务更新提示。原 Retry journal 的绝对 due 仍是权威资格，领取在 Run 锁下读取并校验。旧 NULL 行、提前 hint 或延后 hint 不能改变实际执行资格；不把 opaque ETF 中的状态另造为第二份可独立修改的事实。

Run 创建时固定优先级 0—9，默认 0。先考虑高优先级，同级按意图 ID 排序；不抢占已在执行的步骤，不保证并发完成顺序，也不宣称跨优先级无饥饿。

### 错误和 unknown 保持可见

本次无可执行工作返回 `{:ok, nil}`。数据库失败、不兼容版本、hash 或历史损坏保留错误，不能伪装成空队列。发现损坏候选时记录拒绝原因并继续寻找其他合格 Run；若没有健康候选则返回被拒候选的错误集合。健康工作可以继续，坏记录仍不能获得执行资格。

blocked/reconcile 不自动业务执行；后台多 Worker 不扩大工具权限，不授予人工证据，也不代替显式核对。安全查询、manual 证据、已确认本地 receipt 复用继续沿用 P2 协议。

后台接管可能晚于原 Run deadline。到期后先区分已有工具事实：没有准备历史则失败，已确认结果只补齐工具 Event，模糊投递则观察归档并进入 blocked 核对队列。该归档路径不预留执行次数、不调用目标、不查询工具，也不扩大后续执行期限，避免“超时失败”掩盖尚需核对的效果。

## 后果

数据库保存已经提交、尚待执行或等待到期的事实，进程重启只丢失发现延迟和本地执行槽位。有限 Worker 与 `SKIP LOCKED` 提供可测的并发基础，原 claim fencing、预算和工具能力契约仍约束所有执行路径。

多个 Scheduler 的容量相加；本实现没有全数据库并发配额、每租户公平性、抢占、生产吞吐保证或任意外部 exactly-once。周期扫描存在发现延迟，高优先级持续输入可能使低优先级任务饥饿。第 12—14 周继续验证暂停旧 Worker、目标 fencing、背压、公平性与数据库断连。

当前扫描逐候选校验完整历史，在本次事务结束前持有已访问 Run 的锁；大批未来 retry 或损坏候选会增加扫描工作量和其他操作的锁等待。`SKIP LOCKED` 允许消费者跳过繁忙 Run，不提供固定扫描耗时或大型队列性能保证。

## 验证

验证包括同一意图竞争、多 Run 同时执行、跳过锁定 Run、长步骤租约续期、Worker 失联后自然到期再领取、重复 wake/扫描、receipt 复用、unknown 排除、原 due 前不新增尝试及到期自动恢复。全部前序测试继续作为门槛。

具体命令、测试结果与演示产物见 [第 11 周验收记录](../validation-week11.md)；操作步骤与讨论题见 [L10](../../labs/L10-background-scheduling.md) 和 [恢复运行手册](../recovery-runbook.md)。
