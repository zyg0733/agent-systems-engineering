# L24：版本化发行评估、冻结试读与追加式反馈闭环

对应 W25，前置 [L21](L21-reader-study-and-clean-reproduction.md)、[L22](L22-release-readiness.md)与 [L23](L23-frozen-candidate-release.md)。目标是在保留 W22 原协议、W24 rc.1 和既有发布门槛的前提下，评估同源码的发行材料，让反馈形成可追溯的 finding→fix→原读者复验记录。当前没有真实外部读者、冷主机或 Linux 实证时，结果继续待验收。

先读[发行评估操作](../docs/release-assessment.md)、[ADR 0024](../docs/adr/0024-versioned-release-assessment.md)、[已知限制](../docs/known-limitations.md)与[下一阶段计划](../docs/next-stage-plan.md)。本实验不运行真实 Provider，不改变业务状态机，也不自动发布。

## 1. 固定旧材料和本轮身份

保存旧 rc.1 候选/归档与 W22 试读包的文件 hash、模式和位置；新输出只用自己拥有的全新绝对路径。分别写下源码 manifest 原始字节 SHA、试读 protocol hash、发行 policy 身份、候选 manifest 与归档身份，解释它们各自绑定什么。

保留原政策的 3—5 名独立真人、六章、至少一次新工作区固定主实验、零未解决 blocker、冷 macOS 主机及完整 Linux 隔离/冻结验收要求。Linux CI 适用子集或本机 warm-cache 构建不能填完整通过；计划中的范围建议没有被自动采纳。项目继续 `0.1.0-dev`，候选 label 不是 Git tag。

## 2. 显式选择冻结源码

先由可信宿主选定已验证的纯源码导出 `frozen_source`，以及新 `study_output`。本轮 rc.1 对应 `artifacts/week24-frozen-source-final`；完整候选根含额外证据，不直接作为 source。W25 工具和被评估 W24 源码是两个身份，接收/账本/评估均在已安装依赖的可信 W25 工具工作区执行，新包的 `project/` 保留旧源码且没有这些新 CLI：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen prepare --source "$frozen_source" --output "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

核对新协议与 `project/reproduction-source-manifest.json` 原始字节身份一致，六章与实验资产相符。不能拿当前工作区重新导出后声称还是 rc.1；不能覆盖旧试读包。准备与报告只处理文件，不启动应用、访问 PG 或执行冻结源码；Mix 自身编译可能写工具工作区的 `_build`。

输出的父目录需预先存在且无链接，输出不得位于冻结 source 内，包括其 `artifacts/`；prepare 不代建父目录。比较 manifest 原始字节，不以重新排版 JSON 后的语义相等替代身份相等。

用私有临时副本验证：缺 manifest、源码改动、权限漂移、symlink、已有输出、嵌套/别名路径或未知版本应明确拒绝。不要为了失败演示破坏真实包；错误不能通过手改 manifest checksum 消除。

## 3. 原始反馈与受控修复

本地测试可以使用明确标注 synthetic 的合成记录，验证六章、六个 command ID、读者 ID、source/protocol 和 finding.issue_id 的约束；合成目录与正式无人反馈目录分开，不计真实人次。未完成模板必须拒绝。实际读者由可信宿主核对来源、独立性与隐私后再录入：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen add "$study_output" --feedback "$feedback_file"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

构造一个 blocker，保留原反馈，再追加 fix 与 retest：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen append "$study_output" --event "$event_file"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

按 [ReleaseStudy](../lib/agent_systems_lab/release_study.ex) 的精确事件合同填写数据。比较修复前、仅 fix、失败 retest、最近 fix 成功 retest 的报告。核对原始反馈字节一直不变，序号/previous hash/event hash/head 连续；不存在的问题、错误读者、过时 fix、重复事件或链漂移应拒绝。

同 source 的修复只涉及包外环境或另附解释；包内代码/章稿改变需要新源码、新包和新协议。列出哪些适用实验和章节要重新验证，说明旧反馈为何不能直接当作新版本通过。即使 blocker 关闭，仍应保留最初 finding 和失败复验。

在临时副本模拟追加中断与残留锁，确认只读验证/追加 fail closed。保留现场，不通过删锁、截尾、重写 head 使测试变绿。解释 hash 链在没有外部可信 head 时为何不能认证人或阻止完整自洽回滚。

## 4. 版本化发行评估

选择完整候选目录 `candidate_output`；先缺外部材料评估，再按实际取得的同源码材料增加输入：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output" --evidence "$external_evidence"
```

精确外部文件合同以 [ReleaseAssessment](../lib/agent_systems_lab/release_assessment.ex) 为准；反馈和 evidence 文字不执行，hash 不认证身份或重做历史执行。核对固定政策、候选/source/protocol 绑定与每个 gate。未取得材料是 pending；未知版本、损坏、错 source 或已声明引用却缺失的文件是错误。Linux 适用子集不能冒充完整隔离，`fresh_workspace` 不能冒充冷机器。

外部回归需与候选绑定的完整测试/doctest 覆盖数相同；两个同样小的测试集即使互相对得上也不能冒充 full。缺固定工具版本或安装输入保持 pending。Linux 隔离逐项 backend/status 与顶层一致，只接受原已知 non-goals；硬内存/总磁盘配额等原限制继续保留，新增能力缺口不能藏进任意 unsupported 字段。

分别解释 `evidence_complete`、`approval_recorded`、`publication_status` 与 `release_ready`。合法评估退出 0 不意味着发布通过；齐备的合成测试也不产生真实发行批准。保存原始输出和退出码，不覆盖旧候选 gate。

## 5. 提交与自评

提交显式选定的冻结源码与新协议、真实反馈/事件现状、追加闭环的专项测试、发行评估和旧材料前后保护记录。未取得的真人、冷主机和 Linux 证据继续明确 pending。保存完整回归与内存回归实际日志，数量按本轮统计，不抄旧周结果。实际结论另见 [W25 验收](../docs/validation-week25.md)。

核对本周不改 migration、依赖锁、权限、已用预算、原绝对 deadline、unknown、审批产物绑定及 fencing；新工具不能推进 Run、执行命令文字或接管数据库。实际验收写在执行后的独立文档，冻结材料不回填。按[参考判断](solutions/L24.md)说明技术工具完成与外部门槛待验收为何可以同时成立，事故处理见[运行手册](../docs/recovery-runbook.md#23-版本化发行评估与追加式试读闭环)。
