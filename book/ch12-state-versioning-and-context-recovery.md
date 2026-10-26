# 第 12 章：状态版本化、隔离与 Context Recovery

代码升级后还能读旧历史，不是因为新代码“更聪明”，而是因为数据携带了可检查的解释条件。同样一个数字 2，可能指存储布局，也可能指业务事件语义；把它们混成一个全局版本，会让一次看似普通的读取悄悄改写事实。本章先拆开版本与来源，再讨论恢复输入时必须保留的约束。

主要实现为 [History.Compatibility](../lib/agent_systems_lab/history/compatibility.ex)、[History.Encoding](../lib/agent_systems_lab/history/encoding.ex)、[Codec](../lib/agent_systems_lab/storage/codec.ex)及 [ContextStore](../lib/agent_systems_lab/context_store.ex)。源码身份由实际检出提交与导出清单绑定，项目号 `0.1.0-dev` 本身不足以确定某份实验使用了哪些文件。

## 阅读准备与学习目标

先理解[第 4 章](ch04-transactions-wal-and-failures.md)的事务事实、[第 9 章](ch09-context-construction.md)的输入来源，以及第 11 章中工具发现与授权的区别。这里的恢复输入，是根据已保存来源重建当时交给 Provider 的值，不是再发一次模型请求。checkpoint 可以先理解为“绑定某段历史的状态切片”，下一章会展开。

读完应能列出独立版本域，为未知值给出明确拒绝，区分编码完整、语义一致与获准执行，并为 Context 恢复列出需要比较的来源。首次练习只使用纯值，不需要数据库、网络或模型账号；完整迁移实验另按 L20 的前置准备。

## 12.1 先问“什么在变”，再选版本号

版本号是解释规则的入口，不是越大越好的质量等级。如果 Event 的含义没变、只是外层存储包了一层 digest，就不该假装业务 schema 也升级了。反过来，若业务转换语义改变，即使还能解析旧 JSON，也不代表当前 Kernel 可以按旧事实正确重建。

| 版本域 | 当前支持范围 | 负责解释什么 |
| --- | --- | --- |
| Kernel / Event schema | 1 | 状态、命令与事件的语义和规范字段 |
| Codec | 1 | 受限惰性 term 的字节编码 |
| History format | 1、2 | Event 原始 payload 的存储外层 |
| sidecar schema | 1 | 操作、重试、审批等各自旁路事实 |
| SQL migration | 显式 DDL 清单 | 表、列、约束及迁移 journal 的结构 |

SQL 列存在，不表示所有行已改成新布局；行的布局为 2，也不表示 Codec 能解码版本 2。兼容检查要沿每一层逐项走，而不是看到“数据库已经 migrate”就跳过内部版本。恢复快照还要检查 Run、Event 与相关旁路记录是否互相一致。

版本域分开也帮助定位故障。读者若遇到 unsupported codec，可以先确认编码协议；遇到混合布局，则检查同一 Run 的行是否按一致格式存放。把所有错误都归为“旧版本不兼容”，会让一个具体的损坏问题失去可调查的边界。

## 12.2 第一次小练习：layout 2 能否搭配 schema 1

在仓库根目录终端进入关闭数据库和后台调度器的 IEx：

```sh
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/iex
```

先预测以下四类输入：明确的受支持组合、未知 schema、未知版本域，以及空 map。它们会得到同一个结论吗？

```elixir
alias AgentSystemsLab.History.Compatibility
versions = %{kernel_schema: 1, event_schema: 1, codec: 1,
  history_format: 2, sidecar_schema: 1}
:ok = Compatibility.validate_versions(versions)
{:error, {:incompatible_version, "kernel_schema", 2}} =
  Compatibility.validate_versions(%{versions | kernel_schema: 2})
{:error, {:unknown_version_domain, "invented"}} =
  Compatibility.validate_versions(%{invented: 1})
:ok = Compatibility.validate_versions(%{})
true = Compatibility.matrix()["unknown_version_policy"] == "reject"
```

最后一个 `:ok` 容易误读。`validate_versions/1` 检查调用方提供的键值对，并不要求调用方列齐所有域；空 map 通过只表示没有给出待拒绝的值，不能证明某个数据库完整兼容。真正库检查还核对预期表、列、DDL 清单与各列中的实际版本，再由公共 reader 验证嵌入 payload。

因此，修复“输入不全却被当成完整证明”的办法，是选择正确层级的接口与范围，而不是让模型补一个它猜测的 schema。报告应写明检查的是一组值，还是整个受管数据库及其业务事实。

## 12.3 包装字节与解释业务是两次判断

当前 layout 1 保存原 Codec 字节；layout 2 给原字节加固定 tag、布局号和 digest。升级不重新生成 Event，不改工具参数，也不重新请求模型。先做一个纯值往返：

```elixir
alias AgentSystemsLab.Storage.Codec
alias AgentSystemsLab.History.Encoding
payload = %{"operation_id" => "v12-1", "value" => 7}
{:ok, original} = Codec.encode(payload)
{:ok, envelope} = Encoding.wrap(original, 1, 2)
true = original != envelope
{:ok, ^original} = Encoding.unwrap(envelope, 2, 1)
{:ok, ^payload} = Codec.decode(original, 1)
{:error, {:unsupported_history_format, 3}} = Encoding.validate_format(3)
{:error, {:unsupported_codec_version, 2}} = Encoding.unwrap(envelope, 2, 2)
```

预期外层字节不同，解包后原字节完全相同，payload 的值也相同。这个练习没有构造一条完整 Event，更没有验证它应当被某个 Run 接受。存储 reader 仍需检查行投影、Run ID、序号、事件类型、schema 与实际重建结果，不能拿“可以 decode”代替全部业务检查。

```mermaid
flowchart LR
    Row[行格式与元数据] --> Envelope[按明确布局解包]
    Envelope --> Codec[按明确 Codec 解码]
    Codec --> Event[Event 规范与连续序号]
    Event --> State[按原配置重建状态]
    State --> Audit[与持久投影及旁路事实核对]
```

遇到未知格式时应在对应入口拒绝，不向下猜测最相近布局。digest 一致说明本次字节配对关系成立，不说明是谁批准这些字节；若攻击者能同时替换 payload 和 digest，单靠 hash 不能认证来源。完整恢复还依赖可信宿主、受管数据来源和执行授权。

## 12.4 Codec 为何坚持惰性与有界

数据恢复是一条会处理历史字节的入口。当前 Codec 只接受限定 term，拒绝 PID、port、reference、函数、非支持 struct、非正规列表、超深或过大的 payload；解码使用安全模式并要求完整消费字节。它不是通用对象反序列化器，更不会从数据库加载模块来“修好旧对象”。

这个格式是 BEAM 本地教学协议。既有 atom 必须在接收 VM 中存在，未知 atom 不能在读历史时凭文本创造；应用 payload 更宜使用字符串键值。把安全解码改成无限制解码，也许能让一份旧记录暂时读出来，却扩大了数据进入执行环境的能力，不属于兼容修复。

当前 Codec 上限与迁移上限也各有对象：单份编码限制不等于整个 Run 的历史规模，HistoryMigration 的 Event 数与总字节上限则控制一次迁移工作。超限应明确报错并另行设计分段方案，不能截断后报告“迁移完成”。

## 12.5 Context Recovery 要恢复来源，而非相似文字

Context 是某个时刻从 Run、Session、宿主权限和选项构造的 Provider 输入。Session 版本回答“引用哪一次会话事实”，Run seq 回答“引用哪一段任务历史”；manifest 记录来源及输入构造结果。它们是相关的身份，不是同一个数字。

当前 ContextStore.capture 会在事务中核对保存时的 Run 与可选规范 Session，再保存来源、payload 和 manifest；Provider 只接收 payload，manifest 留给宿主审计。后来 Session 又追加一条消息，并不会使旧 capture 失效，因为旧 capture 正是在记录旧时刻。新的 capture 若仍绑定过期会话版本，则必须重新检查并拒绝陈旧输入。

再考虑两个 Session：它们都刚好处于 version=5，但任务、消息和权限来源不同。只比较数字 5 就复用 capture，会将另一个会话的输入带进当前 Run。版本必须与对象身份、内容和相应 Run 状态一起核对；它是对象内部的变化位置，不是跨所有对象通用的内容地址。这个反例也解释了为什么来源清单不能只存一列版本数字。

恢复者不能把最终 Run 投影代替当时的推理前快照，也不能按“文字看着差不多”换掉输入来源。Context 的确定性重建与 payload hash 可发现漂移；它们不证明摘要语义完美，更不允许恢复时增加工作区、工具、网络或预算。对于录制 Provider，精确输入与当时接受的响应还需一起配对。

一个常见反例是复制旧 Session 后，给新宿主补一条“允许访问所有目录”的说明，再把构造成功称为恢复成功。这里改变的是授权来源，而不是修正序列化。模型、摘要或历史叙述都不能签发新权限；新的授权决策需要单独、显式且可审计的宿主流程。

## 12.6 隔离版本域，也隔离证明范围

本章的“隔离”首先是职责与来源的分离：可裁剪叙述不覆盖硬约束，存储布局不改业务 schema，只读解释不变成执行资格。它不表示这些 map 或版本号提供了操作系统隔离；实际文件、进程与网络边界在后面的隔离章节另有机制。

迁移时要保存一份事实清单：Run 状态与 seq、原事件、输入 capture、完整响应录制、操作与回执、预算、due/deadline、工作区以及审批 subject。原始布局字节可以按受支持规则改变，业务语义与受保护事实则应保持。只比较最终 status 会漏掉“预算清零但状态一样”这样的错误。

当前 HistoryMigration.plan 先只读核对，migrate 再在 expected seq 与无活跃 claim 的条件下提交布局变换及 journal；已经是当前布局时验证后返回 already_current。布局升级不查明 unknown，不把已取消 Run 重新打开，也不使复制的旧租约成为新目标的许可。

完整练习使用 [L20](../labs/L20-history-migration-backup-restore.md) 的受管新目标，先按其前置准备；第一次读本章无需先完成整套备份还原。观察时保留实际迁移前后 proof、原字节/语义 hash 和拒绝样本，再查[运行手册](../docs/recovery-runbook.md#19-历史迁移版本兼容与备份还原)。

## 12.7 失败与修复的最小工作流

若恢复失败，先记录失败域、精确版本、源码身份和数据来源，确认当前读者是否在支持矩阵内。接着比较 metadata 与原始字节，再看连续 Event、checkpoint、Context 和旁路事实。每一步缩小解释范围，不提前进入 resume 或修改原库。

修复可能是选回支持该布局的固定 reader，可能是从可信备份恢复损坏字节，也可能需要一个新版本迁移器。它不应是修改数据库里的版本号、重算所有 hash 或忽略坏行，让当前代码刚好读通。应在新的自有副本验证修复，保留原始失败材料与前后差异。

完成记录至少说明支持与拒绝了哪些输入、哪些事实保持、是否发生业务执行。一次纯 Encoding 往返只证明这段字节协议，不应写成全库恢复或跨平台兼容。没有实际运行的环境继续标为待验证。

## 12.8 练习与教师参考

每题按版本域说明、反例和核验入口三项各 0—2 分自检，至少 5/6。当前判据不允许把省略字段、更新版本号或重算 hash 当成完整恢复证明。

1. layout 2、Event schema 1、Codec 1 能否同时成立？SQL migrations 已应用能否证明行布局已变？
2. 为什么 `validate_versions(%{}) == :ok` 不能证明数据库兼容？应补哪些层次的检查？
3. 旧 Context capture 与 Session 新版本可以同时有效吗？什么时候应拒绝一次新的 capture？
4. 恢复时把旧 workspace 换成一个更大的新根、保持 payload hash 不变，能否称作等价恢复？给出风险与修复方向。

<details>
<summary>教师参考：分别证明格式、事实与权限</summary>

1. 可以，三者解释不同层。SQL DDL 只是结构条件，旧行可仍为 layout 1；需读取 Run/Event 的实际格式并核对迁移 journal，不能从数字或执行命令名称猜测。
2. 该函数只验证传入键值，没有必填域完整性证明。库检查还需表、列、显式迁移、各行版本与公共 reader 的嵌入 payload、状态和旁路事实核验；只填一个合法字段不足以代表全部数据。
3. 旧 capture 保存旧时刻来源，新 Session 继续发展并不改写它。新 capture 若使用陈旧关联版本、与当前 Run 不符或重建输入不一致，应拒绝；不能用终态替代推理开始前状态。
4. 不可以，文件授权来源已经改变，文字和 payload 自洽不能代替授权。保留原环境和证据，或另行设计显式迁移与重新授权；扩大根目录不能作为读取不兼容数据的临时补丁。

</details>

## 术语与继续阅读

schema 描述结构及语义，codec 描述受限值的字节协议，layout 描述外层存储表示，migration 是受条件约束的转换，capture 是保存某时刻的输入证据。完整近义词见[术语表](glossary.md)。本章结论直接对照本地实现与[兼容测试](../test/agent_systems_lab/history_compatibility_test.exs)、[编码测试](../test/agent_systems_lab/history_encoding_test.exs)。下一章[Checkpoint 与持久化快照](ch13-checkpoints-and-persistent-snapshots.md)把这种分层核验应用到历史切片。
