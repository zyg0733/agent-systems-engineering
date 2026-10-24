# 第 6 周与 P1 验收记录

验证日期：2026-10-20，Asia/Shanghai。环境沿用 macOS arm64、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6。没有新增 Hex 依赖。

## 实现结果

Session 保存完整原始消息与固定的 facts、acceptance、constraints，追加生成稳定消息 ID 与连续版本。任务字段不会被追加或摘要改写。角色仅允许 user、assistant、note；工具事实来自 Run.operations，宿主权限来自实际 Catalog、workspace 与预算配置，不能由叙述授予。

Context 将完整 Session、当前合法 Run 投影和宿主权限构造成 Provider payload。任务输入、事实、验收、约束、全部操作及完整回执、Session 身份和权限精确保留；只裁剪可丢弃叙述。超限后保留近期消息后缀，并生成带来源的确定性 UTF-8 提取摘要。摘要标为不可信派生数据，不调用 LLM、不推断新的事实。放不下摘要会明确记为 omitted_budget；保护内容本身超限则在调用模型前失败。

manifest 与 payload 分开，记录完整来源与保留/省略分区、摘要算法、源消息 hash、保护部分与实际输入 hash、有效策略和 ETF 字节数。Context.verify 根据权威源重新构造并全量比较。输入构造复用完整 Kernel 状态规则，拒绝损坏投影或错配回执。

新迁移增加 lab_sessions 与 lab_contexts，保持原 Run/Event、State/Event 字段及 Codec v1。SessionStore 使用行锁与版本 CAS；ContextStore 在启动 Provider 前原子保存完整来源、payload 与 manifest，并核对当前 Run 和关联 Session。读取只做安全解码与纯重建，不访问工具或重新调用模型。

## 完整自动化验收

```sh
./scripts/mix check
```

结果：**265 passed，包含 263 个测试与 2 个 doctest，0 失败**。原第 5 周的 198 项保留通过，新增 67 项。格式、无警告编译、测试库迁移、10/10 原有场景，以及四个 Run/Event/意图提交边界 kill 探针全部通过。

| 新增组别 | 数量 | 主要证据 |
| --- | ---: | --- |
| Session | 8 | 原文不变、稳定身份、严格角色/事实/大小与损坏结构拒绝 |
| Context | 19 | 真压缩、精确字节边界、UTF-8、完整回执、叙述注入、来源分区、篡改与保护超限 |
| SessionStore | 7 | 真实存储、版本竞争、不可变任务字段、损坏读取与非法标识符 |
| ContextStore | 14 | 源版本 CAS、完整捕获、篡改/绑定拒绝、提交前后异常与真实 caller kill |
| RunServer Context | 12 | 消息追加、流中 busy、权限、超限不调用 Provider、非法选项、旧长 Run ID 兼容 |
| 持久运行器集成 | 5 | capture 先于 Provider、Session 陈旧拒绝、失败提交、完整回执与新 VM 读取 |
| P1 演示 | 2 | 四轮压缩流式修复、可验证证据导出、取消零写入、拒绝覆盖旧输出 |

另行运行：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

结果：**203 passed，62 个数据库测试明确排除**。该模式包括 Session、Context 与 P1 内存演示；不能替代完整数据库验收。

## P1 实际演示

开发数据库已执行新迁移，实际运行：

```sh
./scripts/mix lab.p1
```

输出保存在 [artifacts/week06-p1](../artifacts/week06-p1/)。P1 的固定修复使用 40 条完整叙述，依次进行流式源码读取、精确补丁、修复说明写入与最终回答；另外在半截工具参数的 gate 处取消独立 Run。PostgreSQL 路径还运行真实提交边界 kill 探针。

| 观察项 | 实际结果 |
| --- | --- |
| Session 原文 / 版本 | 40 条 / version 40，数据库中的原文完全不变 |
| 修复模型输入 | 4 次，全部发生压缩，全部包含提取摘要 |
| payload 上限 | 16,384 个确定性 ETF 字节 |
| 四次实际 payload 字节 | 14,135 / 14,754 / 15,948 / 16,384 |
| 任务事实、验收、约束 | 每次与原始 Session 精确相等 |
| 工具操作与完整回执 | 每次与当时 Run 投影精确相等 |
| 宿主权限 | 原样保留，shell=false、network=false，workspace 与工具目录不变 |
| 修复前 / 后验收 | 3/4，exit 2 → 4/4，exit 0 |
| 修复工具调用 | 1 次读取、2 次写入；4 轮模型决策、8 条业务事件 |
| 独立取消路径 | cancelled，0 个操作、0 次文件写入，Provider 任务退出 |
| Run 事务探针 | 创建与转换各两个 COMMIT 边界，实际 kill 均符合预期 |

主要证据：

- [P1 总报告](../artifacts/week06-p1/report.json)：Session/Run 标识、每轮大小、保留结果、取消与完整数据库探针结果。
- [第一轮 manifest](../artifacts/week06-p1/contexts/01-manifest.json) 与 [第四轮 manifest](../artifacts/week06-p1/contexts/04-manifest.json)：消息来源、保护值 hash、裁剪与摘要来源。
- `contexts/01.bin` 至 `04.bin`：四次修复 payload、manifest、完整源 Session、当时 Run、权限及有效策略，可重新验证。
- `session.bin`：完整规范会话快照。
- [repair.diff](../artifacts/week06-p1/repair/repair.diff)、[修复前日志](../artifacts/week06-p1/repair/before-test.log)、[修复后日志](../artifacts/week06-p1/repair/after-test.log)：沿用固定可信 fixture 的源码修复及验收证据。

四个修复 capture 与实际传给 Scripted Provider 的请求逐值一致。取消 Run 另有自己的持久输入 capture；总报告的四次 payload 统计对应修复路径。演示保留 Session、Run 与捕获记录供后续查询，不自动删除正式证据。

## 保护与失败边界

测试既比较 hash，也比较原始字段，避免仅信任 manifest 中的布尔声明。ok/error/unknown 的工具参数、状态与结果均不能因压缩改变；Session 中声称启用 shell、扩大工作区或伪造回执，不会改变实际权限和操作台账。任务硬事实必须由应用明确放在固定任务字段或 Run input 中，不依赖从自由叙述自动抽取。

protected_context_too_large 会提交明确 run_failed，Provider 游标和请求数不推进，也没有无效输入 capture。陈旧的 Session/Run 在 capture 阶段被拒绝，不静默刷新或启动模型。活动模型期间与终态的消息追加被拒绝。

ContextStore 自身的真实进程 kill 测试证明：COMMIT 前终止不留下半个输入；COMMIT 后、API 返回前终止，完整来源、payload 和 manifest 仍可读取。这个输入事务与后续模型结果、工具效果不是同一个事务。

审阅补强了 source 与 metadata 的绑定：显式关联 Session 不能通过把行的 session_id 改成 nil 而悄悄变成匿名来源。读取会核对来源中的关联标识。manifest 提供内容自一致性验证，不是签名；同时拥有数据库写权限并重写全部来源与摘要的人不在真实性保证内。

## 新进程与实验手册

独立 Elixir VM 已实际读取含完整文件回执的持久 capture，重新构造并核对；原文件在完成后被修改，读取历史不会覆盖它或重新执行工具。

[L05 手册](../labs/L05-session-context.md)、[参考解答](../labs/solutions/L05.md)、[ADR 0005](adr/0005-session-context-and-manifests.md) 与 README 已更新。纯压缩、篡改/超限、运行器消息与 Streaming、PostgreSQL capture/Session CAS 四组交互示例均按等价脚本实际执行。另在关闭数据库的全新 VM 中只读验证了正式 P1 四份 bundle；未执行 workspace 源码、模型文本或工具。手册包含这段只读验证代码。

## 当前边界

摘要是确定性原文提取，不是 LLM 总结或语义无损压缩；压缩只限制 Provider 输入，不减少规范 Session 或输入审计记录的存储量。ETF 字节不是网络 JSON 大小、token 或费用，独立 manifest 不计入 payload 上限。

capture 已提交只能证明输入已保存，不能证明请求发出、模型返回或结果落库。输入快照不恢复 Provider 游标、流连接、运行时预算或工具台账；不提供自动续跑或未知效果自动重试。仍使用离线 Scripted Provider，远程 CI 未执行。
