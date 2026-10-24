# 已知限制与待验收项

适用 W24 教学候选：项目 `0.1.0-dev`、本地包标签 `v0.1.0-rc.1`、目标 `0.1.0` 未发布。限制与已通过的具体测试同时成立；不得用完整测试通过推导下面范围已经解决。实际结果见[本周验收](validation-week24.md)与[结果索引](results-index.md)，接口见[公开入口](public-interfaces.md)，操作见[运行手册](release-operations.md)。冻结本页不预填尚未执行的结果。

| 范围 | 当前事实 | 使用或验收方式 |
| --- | --- | --- |
| 外部可读性 | W22 正式包暂无真实读者记录；作者/代理审阅、自动测试与合成 fixture 不计真人 | 保留 0 人与 P5 外部 gate 未通过；按原协议收集 3–5 份独立真人反馈与至少一次新工作区主实验自报 |
| 干净环境 | 已有 W22 同一 macOS arm64 宿主、声明 warm cache、新 runtime/build/PG cluster 的复现证据 | 不称为新主机、冷网络安装、多 OS 或未知缓存来源认证；扩展环境需独立实际记录 |
| Linux 与 CI | 配置声明 Ubuntu 24.04、固定 BEAM/PG 版本；本轮没有运行远端 Linux CI | 不将配置存在写成 CI 通过；macOS 隔离后端在 Linux 明确拒绝 |
| 发布状态 | W23 source readiness 只验证文件、版本和入口；W24 固定矩阵和候选包由独立实际证据验收；本地 Git 已初始化用于首次入库准备 | `release_ready=false` 保持；候选 manifest label 不是 Git tag；目标仓库待定，远程 CI 未执行；原创代码 Apache-2.0、教材 CC BY 4.0，见[许可范围](licensing.md) |
| 冻结矩阵 | 固定 F01—F12 各 20 次，组合子探针另计；本轮状态从执行索引和原始报告读取 | 只说明受控本地 Scripted/Mock、PG 连接代理和可信合成审批；不保证任意外部服务、主机断电、介质损坏或生产 SLA |
| 候选包 | allowlist 源码与有界证据；本轮受管合成升级库的 `.dump`、P2 `.bin` 与 `.jsonl` 只作惰性字节证据 | 不含 runtime、依赖安装、build、PGDATA、既有开发库备份或凭据；复制 archive 不携带原主 BEAM capability，不能直接作可信 restore 输入；hash 不认证发行者或真人 |
| 教学完成度 | 12 个课程单元映射 L01—L22，另有 L23 综合冻结验收；30 张章节卡，六章试读正文 | 不是 30 篇长章稿或出版定稿；课程号和实验号不逐号对应；其余正文及外部审校列入后续清单 |
| 上游输入认证 | mix.lock 与本地 manifest 校验完整性；bootstrap 固定版本 URL；Action/PG image 为版本 tag | 不承诺签名认证或 immutable 供应链；严格重放保留 cache provenance 和实际工具身份 |
| 模型接入 | Scripted/Recorded 用于离线教学；Provider behaviour 有合同，当前 RunServer/Recovery 固定 Scripted | 任意真实 Provider 接入仍需源码适配及错误、流控、录制、预算与恢复验证 |
| 工具扩展 | 固定 Catalog/Gateway 和受控文件、隔离、MCP 适配器；没有通用 Tool 自注册 API | 发现工具不等于授权；新适配器需要明确 schema、结果配对和外部效果恢复合同 |
| 外部效果 | PostgreSQL 事务与文件/网络效果不能原子提交；取消不能撤销已有效果 | 非幂等且结果模糊时进入可见 unknown/manual 队列；没有一般 exactly-once 保证 |
| 文件账本 | Files 的调用去重 ledger 在内存，文件本身可跨进程存活 | 重启恢复依原 DurableTools/Recovery 和证据；内容相同不能独自证明某次调用是否成功 |
| 备份还原 | 单数据库逻辑备份；受当前主 BEAM capability/owner marker 限制；静止库 proof | 不包含工作区、外部效果、roles/tablespaces/WAL/PITR；不能任意导入旧 archive 或承诺生产灾备 |
| 迁移与降级 | 支持明确的 layout 1→2、21 个 SQL migration；版本域分别校验，未知版本拒绝 | 单 Run 迁移上限 4096 Event、各侧 payload 32 MiB；不支持自动分批或通用 down-migration |
| checkpoint | 重建仍校验原始前缀，损坏最新 checkpoint 拒绝 | 证明一致性与零执行；不宣称已经减少重建成本 |
| 隔离 | macOS Seatbelt、可信 native guardian、单目标且 fork/spawn 阻断；网络 deny | 不是 Linux container/VM；无硬内存总量或总磁盘配额；不承诺恶意租户的生产隔离 |
| MCP | 固定 2025-11-25 stdio 子集，每连接最多一个在途请求；取消为 advisory | 不支持任意新协议、HTTP/远程认证、并发多请求或所有 JSON Schema；可信宿主 server 本身另受权限管控 |
| DAG 与审批 | 静态 DAG 最多 8 节点、宽度 3；审批轮次、预算与工作区事先声明 | 不提供动态 Planner、无限返工、自动权限升级或自动发布；人工身份需宿主认证 |
| 预算与期限 | 教学字节/尝试/工具/派发计数及 absolute deadline；重试与崩溃不退款 | 不是真实 token/API 账单或全系统资源限额；暂停和维护不重置 deadline |
| 公平性 | aging、队列上限和饥饿指标在已声明负载下测量 | 不证明任意负载/数据库故障下的 SLA、严格全局公平或无限队列可用性 |
| 观测 | 有界缓冲、Null/JSONL exporter；可丢通知，producer kill 可损失有限槽位 | 需要时宿主显式重启观察器；Metrics 不替代唯一业务账本；没有 OTLP 分布式收集平台 |
| 评测 | 公开 6 dev + 4 holdout 固定 Scripted 任务，独立评分、合成成本与真实延迟 | 不是真实模型能力/美元成本 benchmark；相同语义成本可重复不保证延迟相同，回归门槛照实保存 |
| 服务化 | 单可信宿主/单 PostgreSQL 的教学项目；没有用户认证、租户隔离、HA 控制面或服务 SLA | 不作为互联网多租户服务直接上线；审批传入身份不是登录系统 |
| 输入与 hash | JSON/Codec、源码包、反馈、报告均有各自大小/字段/链接限制；hash 检测一致性 | hash 不认证人、缓存或来源；源码准备依可信私有目录无恶意并发写者 |

本页不削弱已有语义：未知结果不能自动当失败，旧 claim 不因 Worker 复活而恢复资格，审批不能跨产物 hash，已用预算与原绝对期限不能因维护或重跑重置。超出能力时保留错误与证据，再设计显式扩展和验证。

## W25 工具准备的新增边界

W25 的 [ReleaseStudy 与 ReleaseAssessment](release-assessment.md)增加显式冻结源码试读、追加式反馈和固定政策评估；以上 W24 能力限制、原包与发布门槛不变。本地工具及合成测试完成不等于外部准入完成：真实读者仍为 0，冷主机与完整 Linux 证据尚未取得，正式发布保持关闭。实际执行结果另见 [W25 验收](validation-week25.md)。

| 范围 | 当前边界 | 处理方式 |
| --- | --- | --- |
| 冻结试读 | 新包绑定显式纯源码导出；可信 W25 工具与被评估 rc.1 是两个源码身份 | 旧源码不含新 CLI；从可信工具接收、追加和评估，不改旧 project 来补工具 |
| 反馈闭环 | 同一 source 的 fix/retest 适用于包外环境或另附解释；只有原读者对最近 fix 的成功复验关闭问题 | 修改包内代码/章稿须新冻结、新协议和适用复验；原反馈/失败保留，不自动跨 source 继承 |
| 账本可信性 | 原始字节、序号、hash 链与本地 head 检测漂移及部分写入；没有签名、自然人认证或外部不可变存储 | 完整自洽重写、改 head 后回滚不能仅靠本地链识别；宿主另外保存已核对的 report/head 身份 |
| 并发及中断 | 独占追加锁串行化写入；残留锁、孤立反馈/事件、半写、缺尾和 head/链不一致会 fail closed | 保留目录与错误，不自动删锁、截尾或改 hash；没有自动账本修复/事务回滚承诺 |
| 外部评估 | 按原固定政策核验有界宿主自报材料，缺项 pending；完整 Linux 仍需隔离和 12×20 矩阵 | 结构合法不认证来源、真人、冷机器或历史执行；`evidence_complete` 不产生批准或实际发布 |

## W26 跨环境工具的新增边界

[跨环境流程](cross-environment-validation.md)提供固定计划执行器和纯文件 `lab.environment` 采集/验证，原候选、原政策及上述运行时限制不变。实际机器与结果见 [W26 验收](validation-week26.md)。

| 范围 | 当前边界 | 处理方式 |
| --- | --- | --- |
| 冷主机 | `macos-cold` 的新主机与缓存声明是宿主自报；本机已有工具/缓存只能记 warm-cache | 没有真实新主机和下载/构建记录继续 pending；新目录、新 prefix、新 PGDATA 不能补事实 |
| Linux | `linux-core` 可执行核心适用流程；现有 Seatbelt 后端不提供 Linux 隔离，无 `linux-full` profile | 保存实际通过/排除/失败，完整 Linux 仍需无平台排除、隔离探针与冻结矩阵；不将排除计通过 |
| 源码版本 | 当前测试修正了部分 macOS 临时路径假设；旧 rc.1 不改 | 新源码 Linux 兼容性不能挪作旧候选通过；旧源码的实际失败照实保留 |
| 执行与采集 | Python runner 会执行固定命令、建自有 PG 并清理；采集/verify 只处理有界惰性文件 | 不执行证据中的任意 argv；执行与采集成功不等于环境完整或发行通过 |
| 资源清理 | 只按本轮 PGDATA/PID/端口绑定停止独占集群；强制宿主死亡可能留下现场 | 不停止共享 55432、不按前缀清库；身份不明先采证并人工核对 |
| 来源可信性 | 记录安装输入、缓存、工具版本与 SHA；没有新增签名/远程主机认证 | hash 绑定字节，不证明供应者、独立机器或真人；未取得来源认证继续列为限制 |
