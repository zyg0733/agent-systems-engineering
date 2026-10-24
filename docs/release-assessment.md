# 版本化发行评估与冻结试读操作

本手册对应 W25、[L24](../labs/L24-versioned-release-assessment.md)与 [ADR 0024](adr/0024-versioned-release-assessment.md)。它追加发行评估和新试读流程，保留 [W24 候选](candidate-release.md)、W22 旧协议及原发布门槛。项目仍为 `0.1.0-dev`，`0.1.0` 未发布；没有 Git tag、自动上传或部署。

## 1. 保留基线，明确四种身份

先记录原 rc.1 候选 manifest、归档及 checksum，保留旧 W22 包的文件清单和模式。旧包作为历史材料只读保留，不在里面安装依赖、编译、覆盖反馈或改 gate。本周新输出用独立、全新、绝对路径。

| 身份 | 绑定内容 | 不能替代的事实 |
| --- | --- | --- |
| 冻结源码 | `reproduction-source-manifest.json` 原始字节 SHA 及源码文件集合 | 当前工作区内容、项目版本字符串不能代替源码身份 |
| 新试读协议 | 本轮源码、固定六章、实验资产、协议 hash | W22 旧协议或另一轮反馈不能直接继承 |
| 发行政策 | 版本化的固定 gate 与支持范围 | 后续计划的建议、CLI 参数不能降低原门槛 |
| 发行评估 | 候选、同源码试读和外部材料的只读评估结果 | 不认证真人/主机，不等于批准或实际发布 |

当前固定政策继续要求：真实独立外部读者 3—5 名、六章覆盖、至少一人新工作区固定主实验、无未解决 blocker、冷 macOS 主机复现、完整 Linux 隔离与冻结验收，以及同源码技术冻结证据。原计划中 macOS 优先范围只是未采纳的建议；本周不改变 Linux 完整门槛。

## 2. 从显式冻结源码准备新试读包

由可信宿主选定 `frozen_source` 与全新的 `study_output`。输出父目录必须已存在、是无链接的真实目录；工具不自动创建父目录，输出也不能位于冻结 source 内任何位置。source 必须是已有、可通过 `Reproduction.verify/1` 的**纯源码导出**，不能默选当前工作区或把旧 manifest 搬到新文件上。完整候选根还含 `candidate-evidence/` 等额外材料，不能直接当 source 输入。本轮 rc.1 对应的纯源码是项目内 `artifacts/week24-frozen-source-final`，新包内 `project/` 复制同一源码身份，协议绑定其原始 manifest SHA 和六章/实验资产；即使原 manifest 使用不同 JSON 排版，也保留原始字节。

W25 工具源码和被评估 rc.1 是两个身份。接收反馈、追加与发行评估在可信 W25 工具工作区运行；新包的 `project/` 保留 W24 冻结源码，不含新 CLI。根 `START-HERE.md` 说明这一区别，包内旧 W22 阅读指南属于历史版本说明，不按它覆盖旧协议。本轮操作产生新的试读包，不产生新的 rc.1 源码。

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen prepare --source "$frozen_source" --output "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

入口不启动业务应用、数据库、模型或工具，不执行冻结源码中的代码。Mix 编译发生在可信工具工作区，可能写 `_build`；不要从待验证的候选目录编译。`prepare` 生成的模板刻意不是有效真人反馈；正式无人反馈时如实显示 0 与 pending。

六章固定为 ch02/ch05/ch08/ch14/ch16/ch20。新工作区主实验覆盖 `verify/p1/history/recover/fence/upgrade` 六个固定 command ID；读者保存实际结果和来源，工具不执行反馈中的命令文字。`fresh_workspace` 自报不证明机器是新的，也不证明无缓存冷安装。

反馈必须带同一协议和源码身份，并给 finding 指定 issue ID。宿主先核对实际来源与独立性，再添加真实记录；不把作者、代理、合成测试或填好的模板当作真实读者：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen add "$study_output" --feedback "$feedback_file"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

保存的原始反馈保持输入字节，重复读者 ID 或文件覆盖会被拒绝。反馈中的描述和 evidence 文本仅作数据，不作为任意文件路径读取或 shell 命令执行。真人认证、隐私处理和对实际执行的核查由可信宿主负责，hash 不承担这些职责。

## 3. 追加修复和原读者复验

一个 issue 先有原始 finding，再追加 `fix`，最后由原读者针对最近 fix 追加 `retest`。fix 包含修复说明与证据 hash，只表示提出修复；成功的当前复验才能关闭问题。失败 retest、他人确认或对旧 fix 的成功不能关闭当前 blocker。

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen append "$study_output" --event "$event_file"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.reading.frozen report "$study_output"
```

事件输入的精确字段与模板以 [ReleaseStudy](../lib/agent_systems_lab/release_study.ex) 为准。`events/` 按序号追加，前一 hash 和事件 hash 组成链，`head.json` 绑定末尾与数量；报告只读验证并重算，不保存一个可手改成功值的报告。

输入 JSON 必须精确匹配以下字段，不自行构造外层序号/hash envelope：

| 输入 | 字段及约束 |
| --- | --- |
| 共同绑定 | `schema_version=1`、`protocol_hash`、`source_manifest_sha256`；从本包协议读取，不能改绑另一版 |
| fix | 共同绑定加 `type=fix`、`issue_id`、全账本唯一 `fix_id`、`created_at_utc`、`description`、`evidence_sha256` |
| retest | 共同绑定加 `type=retest`、`issue_id`、当前 `fix_id`、原 `reader_id`、`reader_type=external_human`、`independent_of_authors=true`、`completed=true`、`started_at_utc`、`finished_at_utc`、布尔 `passed`、`description`、`evidence_sha256` |

时间采用实际 UTC ISO8601；fix 不早于此前反馈/复验，retest 不早于当前 fix，结束不早于开始。一次 fix 接受一次 retest；失败后需要新 fix，再由原读者复验，不能覆盖旧结果。ID、说明和 hash 仍是宿主提供的自报资料，不能用模板中的 true 代替实际确认。

**同一源码只闭环不改变包内文件的修复**，例如纠正读者本机环境或另附操作解释。若修改章稿、代码或安装文件，重新冻结源码并准备新包、新协议；在旧包保留原反馈与失败，不能换 hash 后把旧通过挪过去。新源码的适用实验与受影响章节要取得新证据。

追加由独占 `.append.lock` 串行化。遇到锁未释放、序号/链/head 损坏、部分写入或未知记录时，停止写入，保留目录和错误；不自动删锁、截尾、改 hash 或覆盖 head。文件链用于发现相对于已有可信锚点的漂移，不是外部签名或不可修改日志；可信宿主应另存协议、反馈与 head 的已审核身份。

## 4. 只读评估候选

从可信工作区执行，对 `candidate_output` 指定已验证的完整候选目录。可先不提供试读和外部证据；有效的缺项会形成 pending 结果，不用占位 JSON 假装完成：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output" --evidence "$external_evidence"
```

`external_evidence` 是固定 schema 的有界外部材料目录，具体合同见 [ReleaseAssessment](../lib/agent_systems_lab/release_assessment.ex)。评估将固定政策、候选/source、试读 protocol/ledger 与实际环境文件共同绑定，不能用任意旧报告或几个 `passed=true` 字段充当平台覆盖。Linux 排除项、冷安装输入与缓存来源、主机身份和执行范围按实际记录；Linux 适用子集通过仍不满足完整 Linux gate。

| 外部材料 | 固定 v1 合同 |
| --- | --- |
| `environment-evidence.json` | kind `agent-systems-lab.release-environment-index.v1`；绑定 source/candidate manifest SHA；`archive` 可空或为 `{path,sha256,bytes}`，`environments` 最多两份相同引用结构 |
| 环境报告 | kind `agent-systems-lab.release-environment.v1`；`id`、`type=cold_install_macos` 或 `linux`、`scope=full` 或 `core`、同源码/候选 SHA、`provenance`、`excluded_tags`、`commands`、`cleanup` |
| 来源声明 | 操作者、主机、平台、实际 UTC 时间、`self_reported=true`、新主机与 runtime/依赖/数据库缓存复用布尔值、输入来源/hash、工具版本；门槛固定 Elixir 1.20.4/OTP 28.4/PostgreSQL 18.6 与 `source/otp/elixir/postgres/mix_lock` 输入，source 输入 hash 必须对应本次绑定；来源只是声明，非认证 |
| 固定命令记录 | `id,argv,exit_status,log,result`；argv 严格来自 `ReleaseAssessment.policy/0` 的固定表，文件引用限定证据根内 `{path,sha256,bytes}`；数据不执行 |
| 环境完成条件 | full/core 与排除如实报告；回归尾行须与候选绑定的完整测试/doctest 覆盖数相同，内存通过加排除与完整模式相配，不能用较小测试集冒充 full；固定主实验、只清理自有 PG/进程并确认端口释放；Linux 另需 12×20 矩阵和 18 项完整隔离事实，逐项 backend/status 与顶层相符，Seatbelt 不能伪装 Linux 后端 |

没有记录保持 pending；缺固定命令/安装输入、工具版本不符、`scope=core`、有排除或清理未完也保持 pending。存在但 hash/schema/源码绑定损坏应报错，不能把损坏当作未提供。隔离报告的未支持能力只能使用原有限制白名单（如硬内存、总磁盘配额）；额外能力缺口会被拒绝，也不把原未承诺能力偷偷升成新要求。W25 没有外部材料时不创建填假的环境报告；将来按固定命令表预先准备实际执行环境，再记录日志。

评估不会启动应用、连接 PG、执行报告内容、起停主机资源或保存覆盖旧报告。宿主保存成功命令的 JSON、退出码与原始 stdout/stderr；首次编译日志可能先于 JSON，不把混合 stdout 整体解码为 JSON。结构合法的 pending 可以退出成功；应逐项读取 gate，而非把退出 0 当成正式发行通过。

同源码缺少试读或外部证据保持待验收；未知政策/schema、损坏目录、篡改、错源码/协议和少必需文件明确报错。`evidence_complete`、`approval_recorded`、`publication_status` 与 `release_ready` 分开记录。W25 不提供发行批准或发布操作：即便合成测试覆盖材料齐备路径，也不代表真实批准、Git tag、上传或正式发行。

## 5. 实际交接与失败处理

真实读者、冷主机或 Linux 完整验证尚未取得时，保留 0/pending，不用本机新目录或 fixture 补齐。交付本轮冻结源码、协议、空的真实反馈/事件集合、评估报告、实际回归及旧材料前后保护记录；合成测试与真实目录分开。实际数量、结果和未完成项在 [W25 独立验收](validation-week25.md)中记录。

若需要修复工具，保留失败输入和原始日志，修改受版本管理源码后生成新身份并重跑适用验证；不要回写 rc.1 或 W22 的成功值。发行材料处理不触发业务续跑；原权限、已用预算、absolute deadline、operation ID、unknown/manual、审批产物 hash 与 fencing 保持。业务事故继续按[恢复手册](recovery-runbook.md)，未来取得外部材料后重新只读评估，由所有者另外作发行决定。
