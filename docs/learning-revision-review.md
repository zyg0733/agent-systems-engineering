# 六章首批学习修订与代理评审

日期：2026-10-25（Asia/Shanghai）。本轮按项目所有者决定完成六章首批编辑，并采用多个 subagent 模拟不同背景的读者；不安排真人验证或公开试读，暂不公开。代码基准为 7ab3bac02a93f93fd9be0ca23ea011fb8006cd1c。首个修订提交 2a3ee3d 只改教材和站点；其 Actions 随后暴露既有领取竞争，追加修复与证据见本文末节。迁移、冻结清单和测试排除策略未改变。

## 修订内容

- [先修与桥接](../book/prerequisites.md)：阅读与动手两条深度、五题自测、Elixir/进程/事务/历史/领取的概念桥接。
- [术语表](../book/glossary.md)：state/status、command/event、rebuild/resume、operation/attempt/receipt、unknown/error、lease/fencing。
- [首次小练习](../labs/L01-state-machine.md#first-exercise)：先预测状态与计数，显式执行 Mock，验证错误 ID 被拒绝及重建不增加该 Mock 计数，完整 L01 后置。
- [六章路线](../book/reading-route.md)与[课程地图](course-map.md)：依赖现有材料；C07/C08 按 L10→L11→L12/L13，消除循环。
- 六章分别补学习准备、小练习、提示与下一步；核对[12 条高风险主张](technical-claims-review.md)，明确直接取消 unknown 与 Workflow 父取消的差异。
- 站点加入先修、术语和[当前状态](current-status.md)入口；正文指向导读页的链接保持站内；最近章节功能准确命名；图示使用所属小节的具体标题。
- 当前[质量计划](public-reading-quality-plan.md)已取消真人/公开试读要求，采用代理模拟与功能检查；[公开教材借鉴](learning-design-references.md)记录三项一手项目的组织方式及采用决策。

## 已取得的示例证据

本地证据根目录为维护者工作区 artifacts/learning-revision-20261025/，不随 Git 提交原始运行产物。

| 验证 | 实际范围与结果 |
| --- | --- |
| 前三章 Elixir 代码块 | 12 个按章顺序提取并执行，断言通过；章节 hash 和脚本保存在 early-chapters/ |
| 相关内存专项 | 8 个测试文件，116 项通过（1 doctest、115 tests），数据库关闭 |
| Streaming / repair / Context | 正常、取消、预算三条 stream；repair 的 2→0；P1 memory 均实际通过 |
| 第 14/16 章纯值例子 | 逐字执行 ch14 首段与 ch16 unknown→cancel，小练习断言通过；--no-start 未启动应用/DB/工具 |
| L01 首次小练习 | 从固定第0节提取两个代码块，关闭 DB/调度器执行，退出 0 |

以上不包含新主机冷安装、完整 Linux 隔离或真实模型评测；纯值例子不能替代数据库提交窗口。代理静态核对与后续 Actions 原始结果分别记录。

## 独立模拟评审

初版编辑由三个代理分工完成，随后使用未参与首轮编辑的新代理分别模拟后端新手、OTP/SQL 工程师和 Agent 应用开发者。角色是假设，结果是代理对实际材料的审查，不是三位真人的理解测试。

| 独立模拟角色 | 实际检查范围 | 发现及复验 |
| --- | --- | --- |
| 后端工程师，初接触 Elixir | 首页→开始→先修→L01→第2/5/8章；状态、错误ID、重建、权限六题 | 无 blocker/major；补 Enum.reduce 和匿名函数，修正 Session.append/3 解包说明，原代理确认关闭 |
| 熟悉 OTP/SQL 的系统工程师 | 后三章、术语、12条主张及对应实现/测试；八个新情境 | 无 blocker/major；补 renew 写前暂停对应的 lease_heartbeat_test，原代理确认关闭 |
| Agent 应用开发者 | 六章概念路线与参考解答；模型响应、ETF、效果、checkpoint、lease、取消六题 | 无 blocker/major；结果事务措辞、ETF/turn_count、解答入口、L10锁序四组细项均已修订并由原代理复查关闭 |

合计六组首轮细项均已关闭；代理没有报告真实学习耗时或理解率。另由一名代理只读复核站点实现，没有必须修复项。技术和角色审查均是静态结论，实际运行证据仍以日志为准。

## 整体验证

| 检查 | 实际结果与范围 |
| --- | --- |
| Node 站点专项 | 15 项通过；页面/片段/资源/base审计通过，生成145个阅读页 |
| Python 执行器 | 48 项通过；仓库源码与Markdown链接检查通过 |
| Elixir 格式与源码合同 | format 检查通过；lab.release check 的 source_ready=true，保留旧 release_ready=false；原13个pin未改变 |
| 便携源码 | 实际 export/verify 通过；先修、术语、路线随包提供，website工具链仍排除 |
| 桌面与窄屏 | 1280/320/390 CSS px检查；新入口和首次练习深链接有效，正文不整体横向溢出，宽表局部滚动 |
| 搜索与键盘 | “结果未知”返回正文/术语；方向键选结果、Escape关闭；修复并复测关闭后焦点回到搜索按钮 |
| 交互与图示 | 自测可用键盘展开；代码复制按钮给出成功反馈；深浅色和最近章节正常；六章中的3个Mermaid图全部渲染并带具体小节标签，无控制台错误 |

两项集成问题也已解决：课程地图不能依赖便携包不包含的 website，故六章路线移到 book 单一维护并映射原站点地址；本地搜索关闭后遗失焦点，故主题补充有界的焦点恢复。没有扩大导出、权限或网络范围。

前三章最终 Elixir 围栏逐段与实际执行脚本比较保持一致；后续仅有讲解和参考链接改动。新增先修 reduce 示例也实际 --no-start 执行通过。数据库故障窗口的正文代码没有全部逐字重跑；本轮对应实现/测试先静态核查，推送后由 Lab checks 执行适用数据库回归。两套远程 Actions 的结果绑定实际提交，见 [Actions](https://github.com/zyg0733/agent-systems-engineering/actions)，不把旧提交的成功继承为新结果。Pages 发布保持关闭。

## Actions 暴露的领取竞争

首个修订提交 `2a3ee3d` 的 [Lab checks 40173860549](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40173860549) 实际失败：数据库回归 1039/1040，通过之外的一项是 `IntentDispatchTest` 的并行领取用例，预期六个空结果而实际只有五个。内存 585 项、Python 48 项、固定夹具 10/10 和 PostgreSQL 崩溃核验虽通过，不能抵消该失败。原始 run、日志及 artifact 保存于本地证据目录 `github/lab-checks/`。

增加完整返回值诊断后，本地先连续通过 101 次，再在有界重复的第 246 次观察到同一失败：六份不同 Run/token 的 generation=1 claim、五个空结果及一个 `{:error, :intent_claimed}`。未观察到重复领取。根因是候选查询快照与锁下当前 intent 的差异；说明及相邻反例见 [T13](technical-claims-review.md#t13扫描候选不等于当前领取资格)。

修复只在扫描器锁下发现有效 lease 时继续下一候选，保留直接领取的拒绝行为与全部唯一领取断言；冻结清单、锁序、迁移和 CI 排除范围不变。新增真实 PostgreSQL 屏障测试控制旧快照窗口，并要求慢扫描找到后续 ready Run、不能改变胜出者 token。该测试用独立 schema 的时钟包装函数和 advisory lock 建立屏障，不增加生产故障注入接口。

本地旧实现运行该屏障退出 2，返回 `:intent_claimed`；修复后连续 21 次通过。原并发用例连续 1,001 次通过，领取、队列、fencing、heartbeat 五个相关测试文件合计 62 项通过。另一名代理只读认可扫描修复，并指出 schema 应在创建成功后立即注册清理；调整后单独复验通过。日志与本地修复汇总位于证据目录 `claim-race/`。完整远端回归仍以修复提交对应的 Actions 结果为准，不把本地专项次数算作新增测试用例数量。
