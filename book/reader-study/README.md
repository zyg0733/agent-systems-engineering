# 六章试读指南：先证明自己读到的是哪一版

本轮对应 W22。当前原始反馈为 **0 名外部真人读者**；自动测试、作者与代理技术审阅不计入 3–5 人目标。用户已确认先完成试读包和技术验收；外部试读准入保持待验收，不能据技术通过写成 P5 全部完成。

## 阅读路线与现行实验号

| 次序 | 章节 | 已实现实验 | 读后应能解释 |
| --- | --- | --- | --- |
| 1 | [第 2 章](../ch02-agent-state-machine.md) | [L01](../../labs/L01-state-machine.md) | 命令可能拒绝，已接受事件能纯重建状态 |
| 2 | [第 5 章](../ch05-agent-loop-and-tools.md) | [L03](../../labs/L03-streaming-control.md)、[L04](../../labs/L04-controlled-tools.md) | 完整模型提议、工具权限/ID 配对、取消与预算 |
| 3 | [第 8 章](../ch08-session-context.md) | [L05](../../labs/L05-session-context.md) | Session 原文与有限 Context；压缩不能覆盖硬约束 |
| 4 | [第 14 章](../ch14-history-checkpoints-and-replay.md) | [L06](../../labs/L06-history-checkpoints.md)、[L20](../../labs/L20-history-migration-backup-restore.md) | rebuild 只解释事实，resume 才执行；历史版本不混猜 |
| 5 | [第 16 章](../ch16-durable-effects-and-reconciliation.md) | [L07](../../labs/L07-recovery.md)、[L08](../../labs/L08-retries-and-reconciliation.md) | 外部效果不在本地事务内；unknown 不能盲重发 |
| 6 | [第 20 章](../ch20-scheduling-and-recovery.md) | [L11](../../labs/L11-leases-heartbeats-fencing.md)、[L13](../../labs/L13-database-outages-p3.md) | lease 过期不代表旧 Worker 消失，提交仍须 fencing |

原研究计划的 L03/L04 等主题编号与实际 21 个连续实验已经顺延；本表的链接是本轮执行入口。其余章节尚未形成同等试读稿，不作为隐含前置。建议分两到三次完成，每章记录阅读、准备、执行、诊断所花的时间；耗时由读者实际填写，不使用作者估算冒充测量。

## 获取同一冻结版本

作者运行 `./scripts/mix lab.reading prepare --output artifacts/reading-packet-unique`。包中 `project/` 是可编译源码、六章和实验的自含副本，不包含 `.runtime`、`deps`、`_build`、旧数据库或既有实验产物。`protocol.json` 绑定六章、实验与运行手册的文件 SHA-256，以及完整源码 manifest。收到后先核对这个身份，再开始阅读。Hash 是完整性证据，不是读者身份认证。

在原工程用 `./scripts/mix lab.reproduce verify --output ABSOLUTE_PROJECT_PATH` 核对导出源码。新环境安装参照 [L21](../../labs/L21-reader-study-and-clean-reproduction.md)。如果需要做练习修改源码，请在另外的副本中操作，保留原冻结包不动；笔记、日志与新输出放 `artifacts/` 或包外，不修改协议来迁就记录。

## 分步执行，不继承上一节的环境开关

内存命令使用命令前缀，不在终端长期 `export LAB_DATABASE_ENABLED=false`：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.verify
LAB_DATABASE_ENABLED=false ./scripts/mix lab.demo --lost-response
LAB_DATABASE_ENABLED=false ./scripts/mix lab.p1 --memory --output artifacts/reader-p1-memory
```

随后在**独立实验实例**上设置明确 PGPORT，再执行数据库命令。若终端曾设置 `DATABASE_URL`，先移除它，避免覆盖 PGPORT。不要停止已经运行的共享 PostgreSQL，也不要把现有 dev/test 库当作“干净环境”。所有 `--output` 必须全新；再次执行换后缀。

```sh
./scripts/mix setup
./scripts/mix check
./scripts/mix lab.p1 --output artifacts/reader-p1
./scripts/mix lab.history --output artifacts/reader-history
./scripts/mix lab.recover --output artifacts/reader-recovery --repetitions 1
./scripts/mix lab.fence --output artifacts/reader-fence --repetitions 1
./scripts/mix lab.upgrade --output artifacts/reader-upgrade
```

这些命令对应反馈中的 `verify/p1/history/recover/fence/upgrade` 六个固定 command ID。先读每个命令的实验判据，分别记录退出码、报告路径和结论。不能只写“运行了 mix check”；也不能用修复前预期失败的 fixture 误判整个修复流程失败。

## 反馈怎样进入验收

复制包内 `feedback-template.json` 到包外。使用匿名 `R01`–`R99`，不填写姓名、邮箱、密钥、完整私有输入或 claim token。模板的 `completed` 与独立性初始均为 false，时间为空，所以它不能被当作已完成的真人记录。

实际阅读六章后，填写 UTC 起止时间、六个 chapter ID、具体卡点和 `blocker/major/minor` 等级。卡点应包含所在节、实际命令、期望和实际结果，以及建议；不要写“看不懂”而省略位置。若没有执行复现，保留 `not_attempted/none/[]`；若卡住，填 `blocked` 和实际失败条目，不能把缺日志的步骤填成 passed。

外部独立读者由可信宿主收集，宿主在包外运行：

```sh
./scripts/mix lab.reading add ABSOLUTE_STUDY_PATH --feedback ABSOLUTE_FEEDBACK_JSON
./scripts/mix lab.reading report ABSOLUTE_STUDY_PATH
```

反馈文本与 evidence 字段仅作为数据展示，不会作为 shell 命令、路径读取或模型指令执行。重复匿名 ID、模板、代理记录、未知字段、过时 protocol、缺章或“整体 passed 但缺少步骤”的记录明确拒绝。最多接受 5 份外部记录。

技术复现与真人试读各自有 gate。技术日志、隔离环境和所有实验通过后，技术可报告 passed；外部 gate 至少需要 3 份完整独立真人自报、至少一份全新工作区主实验自报通过，且没有未解决 blocker。模板、自动运行、不同 BEAM、代理数量都不能补足人数。自报不等于认证或独立审计；最终判断仍需宿主核对实际记录。

当前可先查看[修订记录](../../docs/reader-study-revisions.md)和[第 22 周验收](../../docs/validation-week22.md)。修订记录中的自动发现应保持对应标签，不能事后改称读者访谈。
