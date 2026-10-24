# ADR 0017：绑定产物字节的人工审批、持久化暂停与有限返工

- 状态：接受，用于第 18 周教学实现；真实验收以 validation-week18 为准。
- 日期：2026-10-21。
- 依据：[研究计划](../../Agent%20Systems%20Engineering%20研究与落地计划.md)、[静态 DAG](0016-static-dag-workflows.md)、[lease 与 fencing](0011-leases-heartbeats-fencing.md)、[L17](../../labs/L17-human-approvals.md)。

## 问题

模型完成任务或 Reviewer 返回结构化意见，并不代表真人批准当前文件。人工审阅和消费产物之间可能发生输出修改、源基线漂移、重复请求、竞争决定、暂停或崩溃。只保存 `approved=true`，或在恢复时重新读取路径并沿用旧批准，会丢失“谁对哪些字节作出哪项决定”的边界。新增人工控制不能绕过 Run 的权限、预算、结果配对、unknown 核对与 fencing。

## 决定

采用独立持久化 Case 管理一至三轮可信宿主预声明的 Workflow。Plan 固定轮次、图、脚本、Session、工作区、隔离/MCP 策略、五维总预算、唯一总 timeout 和 approver allowlist。返工只选择下一轮，不能由模型动态改图、增加能力或补充预算。不同节点与轮次的文件授权根不可相同或互为祖先。

所有轮的 child allocation 在 Case 创建前按 turn、model attempt、output bytes、tool call、dispatch 五维求和，必须分别小于等于固定 Case cap。未执行轮仍占预留，不退款、不转移。Case deadline 按 PostgreSQL 时钟在首次创建时固定，暂停、等待人工、返工和恢复不重置；每轮 Workflow 和子 Run 的期限裁剪到这个绝对上限。

Artifact 是宿主声明的有界只读选择：相对输出文件、protected baseline 和可选初始输出版本。输出根必须恰好匹配本轮已声明的节点文件授权。initial 只在本轮准入核对，protected baseline 在准入与每次捕获都核对；两类文件不能混淆或重叠。每文件至多 65,536 字节，每 Artifact 至多 16 个输出，单轮全部 max_total_bytes 静态和至多 1 MiB。拒绝保护元数据、符号链接、硬链接、非规范路径及缺失输出。

捕获保存完整文本字节、SHA-256、大小、路径和版本元数据，使用确定的快照哈希。protected baseline 在读取输出前后核验，文件身份和大小也前后检查。宿主需保持私有工作区；这仍是有界文件采样，并非跨文件原子快照或对抗恶意宿主并发 rename 的 inode 隔离。

待审 subject 绑定 Case ID、Plan 哈希、轮次、generation、成功 Workflow ID/seq/完整来源 proof，以及所有 Artifact 快照哈希。人工请求携带可信宿主 actor、理由、request_id、expected_seq 与 subject_hash，决定动作为 approve、reject 或 rework。数据库 CAS 拒绝过期 seq 或 subject，请求 ID 绑定完整请求以处理响应丢失和重复投递。

输出或来源改变时撤销当前批准，增加 generation 并保留历史。即使输出改回旧字节，撤销的授权也不复活。protected source 改变产生显式 baseline conflict，不自动刷新其版本；操作者可拒绝或选择适用的下一预声明轮。历史加载与只读重建验证记录，不读取当前产物内容来重新审批，也不意味着授权当前文件。

release 是唯一取出当前已批准产物的边界：每次调用及重复投递均重新核对当前内容、基线、generation、来源和原 deadline，成功后返回已经审阅的不可变字节及批准证据。它不应用补丁、不发布、不部署。后续消费者必须使用返回字节，并对目标 baseline 执行自身的受控原子 CAS，不能重新按路径读取任意新内容并沿用批准。

人工 pause 通过 Case 所属的持久化 Workflow gate 生效。事务内保存 gate 并撤销原 claim token；旧 Worker 的续租、effect、frame 和结果接受继续被门禁与 fencing 拒绝。恢复重新领取原 Run 的新代次，保留原权限、已扣预算和工具回执。停止 Coordinator 仅停止进程，不能代替持久化 pause。外部工具可能已产生效果，模糊结果继续走原 unknown/reconcile，不把暂停、人工批准或返工作为成功回执。

Case、控制 gate、相关事件、请求去重和下一轮 Workflow 准入在同一 PostgreSQL 事务中提交。外部执行仍通过原 Scheduler、claim 和工具台账；Case Coordinator 只做有界观察与推进，拥有当前运行轮的 Workflow Coordinator。approved Case 可以继续观察输出失效，关闭的 Case 进入停止收敛。只读 audit 在独立 BEAM 验证相同 Case/控制/Workflow/子 Run，且执行与 capture 入口调用为零。

actor allowlist 表示可信宿主已鉴别的操作者标识。本实验没有登录、凭据、签名或组织 RBAC；模型或任意调用方自行填写允许的 actor 不能被解释成真实人工授权。静态 Reviewer 的 `approved` 字段也没有人工能力。

## 验证

纯测试覆盖路径与链接拒绝、initial/protected baseline 生命周期、缺失与空文件区分、有界字节、不可变快照、哈希和版本防篡改、全轮预算、轮次上限、跨轮权限隔离、approved workspace 绑定及 approver allowlist。真实 PostgreSQL/OTP 测试与正式演练覆盖人工 CAS、请求去重、输出改变和改回后失效、baseline conflict、暂停旧 claim、原期限到期、未知效果、有限返工、竞争推进、提交前后崩溃以及新进程恢复。具体计数只填写实际验收结果。

## 后果与边界

审批指向确切不可变字节，恢复能够解释每次人工作用，旧 Worker 和旧批准不能仅凭进程存活或文件路径继续获得能力。代价是预留保守、每轮独立工作区、完整快照和事件占用额外数据库空间，以及严格上限带来的可见拒绝。

动态 Planner、模型自主增权、自动无限返工、真实登录身份、补丁应用、发布部署及跨系统原子消费均留待独立设计。原隔离器的操作系统、内存和总磁盘配额边界不会因人工审批而改变。
