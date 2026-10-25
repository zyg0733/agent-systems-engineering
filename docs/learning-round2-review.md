# 六章第二轮：完整路线、练习与解答复核

日期：2026-10-26（Asia/Shanghai）。基准提交为 `eb4fe22562576d27332339b7344276b175bba94f`。本轮继续保持私有，不安排真人或公开试读，不创建正式版本或开启 Pages。[首轮修订](learning-revision-review.md)及其失败/修复记录保留原样。

## 阅读与实验如何走过

三位 subagent 分别模拟初接触 Elixir 的后端工程师、Agent 应用开发者、熟悉 OTP/SQL 的工程师。每位都通读入口、先修、术语、六章与阅读路线，再分别深入 L01—L05、L06—L09、L10—L13 的全部手册和对应解答，形成八个新情境问题与模拟作答。共 24 个情境是静态推理，不是 24 次真人测验，也不据此计算学习成绩、耗时或满意度。

读者先记录卡点，再在指定文档范围修订；另由未参与编辑的代理独立对照当前稿、实现和测试复核。作者复验、独立静态审查、实际代码运行、浏览器检查分开记录。主线 runner 和数据库摘录由维护者统一执行，未让三个读者并发操作共享实验库。

## 本轮修正的卡点

| 触发情境 | 原问题及修订 | 依据与复验 |
| --- | --- | --- |
| 从内存练习切到数据库，或继承其他终端环境 | L01—L13 准备段显式关闭应用级 Scheduler；数据库段显式启用 Repo；说明同一终端、新 IEx 和变量边界 | [阅读路线](../book/reading-route.md#先确认执行上下文)、config、各册 DB 摘录 |
| 读者边读边手动 step | 第 5 章默认 60 秒 Run 时限含人工等待；交互例子显式给 10 分钟，保留超时结果，不把重跑当预算退款 | [第 5 章](../book/ch05-agent-loop-and-tools.md)、RunServer/Budget |
| 将取消当成统一的“先停再记状态”协议 | 教学 RunServer 实际先接受取消转换再清理模型 worker，停止请求没有等待 DOWN；与持久恢复的超时处理区分 | RunServer 实现、[L03 解答](../labs/solutions/L03.md)和第 16 章 |
| 选内存 P1 或新目录后读取证据 | L05 原来硬编码旧目录，可能验证旧产物；现在用 `p1_output` → `P1_OUTPUT` 传入同一实际目录 | 本次数据库与内存两种 P1 产物各四份 Context，独立只读核验通过 |
| 要求篡改不存在的 receipt ID | L06 区分 opaque 业务 payload、Event 外层 operation ID 和 `tool_result.v1` 内层配对身份；新增精确拒绝及原值不变断言 | Kernel、Tools.Result、Checkpoint；纯值及 DB 摘录实跑 |
| 人工结论需要绑定先前审阅的状态 | 区分自动绑定当前操作的教学便利 API 与运行手册 expected seq helper，不虚构 `Recovery.reconcile` 选项 | [运行手册](recovery-runbook.md#6-人工证据与预期序号)、L07/L08/第 16 章 |
| 直接取消 unknown 后队列为空 | L08 新增独立 Run 反例：cancelled、operation unknown、空队列、effects=1、reconcile 拒绝同时成立；解答不再称取消新增了核对证据 | Kernel/Recovery/队列和本次 L08 DB 摘录 |
| 从 P2 最终空队列寻找未查明任务 | 当前 16 窗口都构造可确认结果，最终成功是矩阵设计；仍 blocked 的保护证据从 L08 确认前快照或专门测试取得 | P2Verification、[L09 解答](../labs/solutions/L09.md)、本次 320 probe 原始报告 |
| 把所有领取和续租都画为同一锁序 | L11 与 L10 解答补充命名队列 Queue→Run→Intent；未入队与 renew/release 保持各自 Run→Intent | IntentStore/QueueStore、L10—L12 摘录及 fencing runner |
| successor 先提交后，旧调用被拒绝 | 第 20 章答案补“同 seq、同 intent，只持新 claim 不推进”窗口，再补已提交窗口，避免只凭 seq CAS 声称证明 token fencing | [第 20 章](../book/ch20-scheduling-and-recovery.md)、FencingDemo 与相邻测试 |
| IEx 中断后遗留自己的 Scheduler，或把旧阶段限制当全项目限制 | L10 用 try/after 停止自己创建的 Scheduler；L02—L05 解答收窄到所用 Storage/教学 RunServer 路径 | L10 literal 实跑；后续 Recovery/Scheduler 已有实现及独立审查 |
| L02 退出 IEx 后直接使用旧别名 | 新会话不继承变量或 alias；页内补明确的 Storage alias，并以独立新 BEAM 复验，不能用脚本额外补别名的成功掩盖正文漏项 | 第二名独立审查者发现；最终 L02 会话复验单列 |
| 把旧审计计数当当前计数 | L13 当前只读审计是 27 个入口，历史的 20 保留在原报告，不改旧记录 | P3Verification 与本次 fresh-history-audit 原始文件 |

新增的[逐段路线检查表](../book/reading-route.md#把阅读路线走成实验路线)把“预测、当前证据、换条件解释、参考解答”连接起来。演示、原文练习和要求读者自己改写/编写测试的独立挑战分别说明，不把 runner 通过冒充完成所有作业。

## 已取得的实际执行证据

维护者本地证据根目录为 `artifacts/learning-round2-20261026/`，原始日志不进入 Git，也不被站点发布。本轮使用已有固定版本运行时和依赖缓存；创建专有 PostgreSQL 集群，绑定 `127.0.0.1:55442`，启用 fsync、synchronous_commit 和 full_page_writes。路线、IEx 样例与完整测试分别使用全新数据库，未使用旧开发/测试库。

| 范围 | 实际结果 |
| --- | --- |
| L01—L13 主线 | 含 setup 共 21 条已审查命令退出 0，逐步 argv、环境、日志 hash 和耗时见 `route/summary.json` |
| P2 正式重复 | 16 窗口 × 20 轮 = 320 probe、340 次受控 kill；重复效果、丢失已确认回执、旧 token 覆盖与已接受 cursor 重请求均为 0 |
| L11 信号 | 五类窗口各 5 轮，共 25 probe 通过；没有把它写成每窗 20 轮的新冻结验收 |
| L13 数据库故障 | 五类窗口各 2 轮，共 10 probe；本地代理和新 BEAM 的受控故障通过 |
| P3 综合 | scheduling/fencing/load/database 四组件及新 BEAM 历史审计通过，信号与数据库参数为 2 轮；当前每份审计的 27 个执行入口全为 0 |
| 手册 IEx 摘录 | L02 的两次会话、L03、L04 的执行与新 BEAM 读取、L05、L06/L07/L08、L10/L11/L12 共 12 份脚本退出 0；每份独立 BEAM |
| L02 最终别名补验 | 独立新 BEAM 执行最终会话，退出 0；来源与脚本 hash 见 `backend/db_l02_session2-final-source.json`，日志与单独退出码记录见 `examples/db_l02_session2-final.log`、`examples/l02-final-result.json`；原 12 份脚本记录保留 |
| 当前 P1 产物 | 相同只读脚本分别读取本次数据库和内存输出，各核验四份 Context；未读取旧默认目录 |
| 读者纯值/内存检查 | 后端读者 12 组检查、持久读者 19 段最终摘录与 23 个纯测试、调度读者的六章相关纯值摘录与 9 个测试通过（5 个数据库用例排除）；这些重叠范围不相加为新用例数 |

IEx 脚本只取经过审查的明确片段，来源行/块 hash 与前后版本由三个读者分别保存。额外 guards、断言、工作区与跨 BEAM 证据传递均在脚本中标注；不是自动执行任意 Markdown。原批次逐条退出码、实际文件路径和日志 hash 见 `examples/summary.json`，最终 L02 补验另见上表。教材修订不改变运行时代码、迁移、冻结清单、参数上限或 CI 排除策略；后续仅针对远端 P3 失败补充测试诊断，成功断言与验收阈值保留。

完整本地回归的首个尝试设置了全局 `DATABASE_URL`，触发现有恢复测试的动态 Repo 配置缺陷：URL 覆盖临时库，测试修改了主测试库的列，最终 875/1103 通过、228 失败，随后数据库提交边界检查失败。原始 `checks/` 日志与该专有失败库保留。复验使用同一专有实例的全新默认 `agent_systems_lab_test`，移除 `DATABASE_URL`，通过 PGHOST/PGPORT 等连接；不在缺列但迁移已记账的失败库上直接重跑。README、站点入口、阅读路线及 L02—L13 的完整回归命令已明确这一环境限制；单个实验仍可指定 URL。后续只改完整回归的 shell 调用，既有 IEx 块与行号不变，最终整文 hash 另存 `final-document-hashes.json`。

无全局 URL 的下一次完整回归为 1101/1103 通过，剩余两个失败分别是 100 毫秒重试窗口与 60 秒候选文件核验超时；10/10 固定场景及 PostgreSQL 提交边界检查通过。该次 `checks-final/` 日志与数据库也保留；以两个 BEAM 调度器、新测试库和原断言/超时阈值复验，独立记录于 `checks-recheck/`，不覆盖失败。

强制严格编译、格式、48 项 Python 检查、15 项站点测试及 146 页构建/发布输出审计通过。浏览器已核对新路线表的 13 个解答入口、390/320 像素无页面级横向溢出、表格局部滚动、搜索 `P1_OUTPUT`、Escape 返回焦点及三张实际 SVG 流程图。完整回归、内存模式、源码检查及便携导出的最终本地退出码见 `checks-recheck/summary.json`；推送后的两套 [Actions](https://github.com/zyg0733/agent-systems-engineering/actions)必须对应本轮实际提交，不能继承基准的成功。交付结论与远端日志绑定提交身份，Pages 发布保持跳过。

## 远端 P3 失败与诊断补充

教材提交 `35cf7f1d1265745b0d4663df681117a2a0b32eb3` 的 [Reading site](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40218030049) 通过；[Lab checks](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40218030044) 的 Linux 数据库回归为 1040/1041、62 排除，唯一失败为 `P3VerificationTest` 的完整综合用例。内存 585 项通过、518 排除，Python 48 项通过；固定场景和 PostgreSQL 提交边界通过不能抵销该失败。

返回的 P3 报告显示 component_count=3、audit_complete=false。组件顺序表明故障发生在数据库组件尚未成功时，但 ExUnit 截断了巨大的嵌套报告，现有日志无法认证具体故障窗或根因；不能将其写成已确认的超时。测试清理还删除了组件目录，因此首次失败没有足够原始材料可进一步追溯。原 job 日志、artifact 和失败汇总保存在本轮 `github/lab-checks/`。

后续提交只增强这个测试的失败诊断：递归裁剪组件/故障窗摘要，在 GitHub Actions 中复制该次原始输出到既有 `artifacts/ci/linux-core/` 上传范围，再按原流程清理。目标必须全新，复制错误保留为诊断，不覆盖证据或掩盖原断言。成功路径不复制或打印；P3 的四组件、重复参数、零调用要求、成功断言和超时阈值均保留，工作流不变。该修改用于取得复验材料，不能据此声称已经修复尚未查明的业务故障。

本地独立复验在两个 BEAM 调度器下为完整 1103 项通过，内存 632 项通过、471 排除；48 项 Python、15 项站点测试、源码准备及 548 文件核心便携导出验证通过。完整本地回归和教材路线对应 `35cf7f1d`；后续诊断修改另做 P3 定向复验，最终远端结论以包含该诊断的实际提交为准，保留首次失败。

诊断辅助函数已做本地实际自测：原匹配断言拒绝失败值、摘要保留窗口但不展开巨大子报告、完整原始报告复制、已有目录拒绝覆盖、成功无输出或复制、字符串 false 不启用、复制失败不遮蔽原断言。P3 文件全部六例定向复验通过。另有一次重启专用集群漏带端口参数导致本地 4/6，通过实查端口并纠正为 55442 后重跑；该环境失败的日志和原始副本保留，不能当成远端数据库组件故障的复现。

## 证据边界

本轮是多个代理走读、独立静态审查与实际本地实验；远端 CI 结果以本轮实际提交的 Actions 为准。没有真人数据、真实模型能力评估、新主机冷安装或完整 Linux 隔离验收。数据库 runner 是执行路径，会调用离线 Provider 和受控工具；它们创建演示事实后，才在指定只读审计段验证零调用。Linux core 仍排除 Seatbelt，内存测试另排除 database。

手册让读者自行编写的随机轨迹、额外故障变体与完整课程 L14—L25 不因本轮主线通过就算已全部完成。尤其 L20 仍按后续前置组织；旧 W22—W26、冻结包和发行工具保留原契约，不把代理模拟填成真人反馈。本轮继续暂不公开。
