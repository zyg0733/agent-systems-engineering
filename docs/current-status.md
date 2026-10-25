# 当前内容、运行环境与边界

更新：2026-10-26（Asia/Shanghai）。这里是当前阅读入口；[W24 已知限制](known-limitations.md)和各周验收保留各自历史时点，不作为新修订已经执行的证明。

## 现在可以读什么

已有第 2、5、8、14、16、20 章正文，以及 25 份实验手册、12 个课程单元和 30 张章节设计卡。其余 24 章还不是完整正文。先看[先修与桥接](../book/prerequisites.md)，再按[六章路线](../book/reading-route.md)推进；术语随时查[统一术语表](../book/glossary.md)。

本轮按项目所有者决定使用 subagent 模拟读者与交叉技术审查，不做真人试读或公开试读评审。六章首批准备见[首轮报告](learning-revision-review.md)，完整阅读/实验路线、练习及解答复核见[第二轮报告](learning-round2-review.md)。模拟、静态核查、代码实跑和浏览器检查分别记录。没有真人满意度或学习完成率，也不要求取得这些数据才能继续编辑。

## 阅读站与源码如何取得

源码托管在[私有 GitHub 仓库](https://github.com/zyg0733/agent-systems-engineering)，克隆、编辑链接和 Actions artifact 下载需要仓库权限。Pages 未开启，没有公开阅读地址。静态网页展示教材，不能在浏览器运行 BEAM、PostgreSQL 或隔离实验。

完整 Git 克隆可按[阅读站维护说明](reading-site.md)用 Node.js 24 构建/预览；实验导出包不包含站点 Node 工具链。源码获取与平台准备另见[项目 README](../README.md)。

## 运行哪些实验

| 路线 | 已知范围 | 不能据此声称 |
| --- | --- | --- |
| 只阅读 | 正文、桥接、术语、练习推理，无需模型账号 | 已执行实验或学会了全部系统设计 |
| 内存小练习 | 纯 Kernel/Mock，不需要数据库或模型密钥 | 持久恢复、真实模型能力或远程效果保证 |
| macOS 完整教学环境 | 已有 arm64 warm-cache 验收；固定 BEAM/PG 与 Seatbelt 教学后端 | 新主机冷安装、x86_64 已实证或生产级隔离 |
| Linux core | 真实 Ubuntu Actions 执行数据库/内存适用回归，排除 Seatbelt | Linux 已具备完整隔离后端 |

运行时使用 Scripted/Recorded Provider 和受控工具；尚未接入真实厂商模型。项目面向单可信宿主、单 PostgreSQL，不提供任意分布式/远端 exactly-once。unknown 要保留原操作身份并依目标能力核对；直接取消 Run 不会撤销效果，且终态后不能用原 Run reconcile 续跑，详见[第 16 章](../book/ch16-durable-effects-and-reconciliation.md)。

## 验证与版本

当前仍为 0.1.0-dev，正式 0.1.0 未发布。最近已核验的首轮修订基线提交为 [eb4fe22](https://github.com/zyg0733/agent-systems-engineering/commit/eb4fe22562576d27332339b7344276b175bba94f)：[Reading site](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40176517885)和 [Lab checks](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40176517882)通过。它不替代第二轮修订的验证；本轮结果以第二轮报告及对应提交的 [Actions](https://github.com/zyg0733/agent-systems-engineering/actions)为准。

旧候选和 v1 发行工具保持原字段，release_ready=false 和历史真人 0 不伪造成通过。本轮以[教材质量计划](public-reading-quality-plan.md)推进代理评审，不把旧真人 gate 设为教材继续写作的条件。完整平台与正式版本发布另行处理，本轮不创建 tag 或开放网站。
