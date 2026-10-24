# W22 技术自审 B：历史、效果、调度三章与试读协议

日期：2026-10-23，Asia/Shanghai。审阅角色为协作 agent，不是外部真人试读者；本文不计入 3—5 人门槛，不是独立人员复现证明。

## 范围与方法

本次拥有并修订 [第 14 章](../book/ch14-history-checkpoints-and-replay.md)、[第 16 章](../book/ch16-durable-effects-and-reconciliation.md)、[第 20 章](../book/ch20-scheduling-and-recovery.md)。对照真实源码、L06—L13/L20、运行手册，逐一校对链接和 CLI 参数。另对 Root 持有的 `ReaderStudy` 只读审查并反馈缺陷，不直接编辑该模块。

未运行重数据库演练或全量回归。纯值 probe 通过已编译模块在独立 Elixir 中执行，不启动应用/Repo/调度器；合成反馈只存在于内存，不写入试读目录、不导入为真人记录、不执行反馈文本。路径 probe 仅创建并清理本次自有 `/private/tmp` 目录。

## 章节中修正的实际卡点

| 编号 | 原问题 | 本次修订 |
| --- | --- | --- |
| B-C01 | 初始分工将第 14/16 章主题互换 | 按原计划正名：第 14 章 Event History，第 16 章外部效果；创建对应文件并修正交叉链接 |
| B-C02 | 早期 L06 的“当前没有迁移器”容易被读作当前系统限制 | 第 14 章明确这是 W07 的时间边界；当前有 layout 1→2，Event schema/Codec 仍为 1 |
| B-C03 | checkpoint 容易被解释成启动性能优化 | 明确当前数据库路径重验完整前缀，尚无减少读取/回放成本的保证；坏最新 checkpoint 不静默退回 |
| B-C04 | 新进程重建、Recorded、Recovery.resume 容易混为一谈 | 列出各自输入和执行边界；整个 history 演示真实写一次文件，只有子进程核验阶段要求零效果 |
| B-C05 | 工具超时、unknown、有限 retry 容易互相替代 | 分开说明事实知识、资源资格和工具能力；核对耗尽不授权重发，文件内容相等不等于 receipt |
| B-C06 | 旧第 20 章没有完整拆开容量与锁序 | 补 queue capacity、有效 lease、本地 Worker、task budget 四口径；区分 Queue→Run→Intent 领取与 Run 内 renew |
| B-C07 | 还原一致容易被理解成旧 token 继续有效 | 补 exact proof 在 fence 之前、接管后只按协议更改 claim；原权限/预算/绝对 deadline 不重置 |
| B-C08 | 复测使用默认目录会与旧证据冲突 | 所有创建演示的命令使用显式新 `--output ...reader-01`，注明重跑必须改编号 |

三章当前分别 183、189、205 行。检查 69 个 Markdown 链接，本地目标均存在；所有 `lab.*` 名称有真实 Mix task。对照源码确认 `recover --repetitions 1`、`schedule --runs 6`、`load --jobs 12` 和其他所列参数合法。没有重新核验已有 Oban 上游源码执行；第 20 章仍明确引用本地固定提交研究，其上游测试未运行。

第 14 章首段 Elixir 示例从 Markdown 提取后直接运行，输出 `CH14_PURE_SNIPPET=passed`，包括完整/前缀-tail 状态精确相等、缺口拒绝及未来 schema 拒绝。第 16 章 IEx 示例对照已通过的 `recovery_test` 成功路径核验；本次没有冒充重新执行该数据库示例。

## ReaderStudy 中发现并上报的问题

以下是**发现时的实现**，修复状态以 Root 的最终源码和测试为准。它们不是当前仍存在缺陷的自动声明。

| 编号 | 发现与具体影响 | 建议及验收 |
| --- | --- | --- |
| B-R01 | `false <- duplicate? || {:error, :duplicate_reader}` 在无重复时得到 error tuple，首条合法反馈也拒绝 | 改为 `true <- not duplicate? || ...`；验证首次接受与第二次同 ID 拒绝。Root 已回报修复并 strict compile |
| B-R02 | protocol 只固定六个章节 ID，未将 suite 与冻结导出内 suite 对齐 | `load` 逐值对比已验证 project 的 suite；assets keys 精确覆盖六章、labs、guide/runbook；重新 hash 的错路径仍应被拒绝。Root 已回报加载绑定修复，纯 validator 固定映射待最终回归 |
| B-R03 | 每条反馈可达 262144 字节，五条汇总报告可超过同一个读取上限 | 报告使用独立有界上限或限制总量；写入前核验最终尺寸；最大合法反馈汇总后应能再次读取、更新。Root 已回报报告上限改为 2 MiB、单记录保持 256 KiB |
| B-R04 | 覆盖旧 report 只比较 `protocol_hash`，旧 `report_hash`/结构损坏仍被覆盖 | 覆盖前验证旧 report 完整性和必要结构；损坏报告保持原字节并报错，保留正常原子替换路径 |
| B-R05 | `fresh_directory` 先 `mkdir_p(parent)` 后检查 symlink | 先验证已有祖先并安全逐级创建，或只接受既存安全父目录；拒绝 symlink 时目标外不应留下新目录。Root 已回报改为逐级 `make_directories` |

纯值复现 B-R02：使用真实 suite/asset metadata，把六章路径和 labs 全改为 `README.md`，并重算 protocol hash。发现时 `validate_protocol` 返回 `:ok`。这个 probe 证明 validator 的形状校验不足；对完整 `load` 还应增加冻结源 suite 对齐测试，不能仅凭纯函数结果声称已绕过全部加载步骤。

纯值复现 B-R03：每条合成记录 25 个合法 minor finding，每个 description/suggestion 为 4096 字节。五条记录均通过 `validate_feedback`，单条 JSON 为 **207750 字节**，`assess` 输出 JSON 为 **1037293 字节**。这超过发现时报告覆盖读取共用的 262144 上限；没有将这些记录保存为真实反馈。

路径复现 B-R05：在自有临时目录内设 `link → target`，请求 `link/new/nest/packet`。返回 `{:error, :unsafe_reading_directory}`，但 `target/new/nest` 已存在。probe 最后清理整个自有目录，未影响其他文件。

## Reproduction 的路径别名自审

**B-X01：拒绝的递归导出仍可能修改源树。** `fresh_output` 使用字符串前缀排除已选的 `source/lib` 等目录。在当前 macOS 不区分大小写的卷上，`source/LIB` 与 `source/lib` 是同一个目录实体，但字符串前缀不同。

自有临时夹具中放置三个必需文件及 `lib/probe.ex`，调用 `Reproduction.export(source <> "/LIB/nested", source: source)`。发现时返回 `{:error, :reproduction_source_changed}`，但 `source/lib/nested` 已被创建并包含副本。最终源清单比较确实拒绝了导出成功，却不能撤销此前对原源码树的修改；因此不能把最终 mismatch 当成足够的递归路径防护。

建议在创建输出前，把目标已有祖先与所有被选源码目录按 `File.stat` 的 device/inode 比较，拒绝同一目录实体的子路径；同时保留现有无 symlink 规则。大小写敏感卷上可以显式跳过别名分支，当前卷应有确定测试并断言失败前后源内容未改变。只按宿主 OS 名称做 `downcase` 不能完整处理卷配置和 Unicode 别名。问题已上报 Root，最终修复/回归由模块持有者记录。

除 B-X01 外，静态核对导出源白名单、排除 `.runtime/deps/_build/artifacts`、权限保留、固定 command ID 与隔离环境字段，没有发现另一项已证实的文件导出缺陷。目录枚举和同权限并发修改仍在可信宿主、私有目录、无并发 writer 的声明内；校验和不认证 warm cache 的来源。

## 审查边界与保留判断

- `protocol_hash`、source manifest 和 report hash 是完整性绑定，不是签名；同一宿主能重写全部事实并重算 hash 时，不构成身份认证。上述 B-R02/B-R04 要求内部绑定一致，不增加外部信任锚声明。
- 反馈需要 host 提供外部真人自报，`reader_type`/独立性声明不能鉴别人。自动运行和 agent 自审不能据此成为真人；本周真实反馈仍须单独计数。
- 现有 `lstat`/目录遍历和 hardlink 拒绝可防静态 symlink 输入，不抵御同一权限恶意并发交换文件；使用私有目录、没有并发 writer 的可信宿主边界应明确。
- 并发提交不同 reader ID 可能共同通过“五条以内”的先读判断；若模块承诺并发写入，需要序列化或跨进程锁。若仅承诺单宿主串行操作，应在文档中写明，不能把有限列表当成并发数据库约束。
- 汇总中的 blocker 只有新增记录，尚无明确修订后复核/关闭状态。外部试读若产生 blocker，应保留原反馈，再用新版本冻结 packet 重新复核；不能删原记录或把 severity 改小制造通过。
- 技术复现门槛与真人门槛分开计算，只有一侧通过不能把最终 P5 gate 写成完成；证据摘要也不是实际命令执行的自动证明。

最终交付应同时保留章节修订、自审问题及对应回归，准确写出外部真人数量、同机隔离技术复现范围、全量测试结果和仍未达成的外部门槛。
