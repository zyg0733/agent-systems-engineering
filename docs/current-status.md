# 当前内容、运行环境与边界

更新：2026-10-27（Asia/Shanghai）。这里是当前阅读入口；[W24 已知限制](known-limitations.md)和各周验收保留各自历史时点，不作为新修订已经执行的证明。

## 现在可以读什么

全书七篇、30 章正文草稿已齐，并有 25 份实验手册、12 个课程单元和 30 张设计卡。新读者从[第 1 章导读](../book/ch01-from-llm-apps-to-agent-systems-engineering.md)与[先修桥接](../book/prerequisites.md)进入[完整路线](../book/reading-route.md)，随时查[术语表](../book/glossary.md)。草稿齐备不等于商业出版、生产部署或真实模型能力已经验证；逐章实际范围见[全书复核](book-completion-review.md)。

本轮按项目所有者决定使用 subagent 模拟读者与交叉技术审查，不做真人试读或公开试读评审。六章首批准备见[首轮报告](learning-revision-review.md)，完整阅读/实验路线、练习及解答复核见[第二轮报告](learning-round2-review.md)，新导读与 P3 有界复验见[后续记录](learning-followup-review.md)。模拟、静态核查、代码实跑和浏览器检查分别记录。没有真人满意度或学习完成率，也不要求取得这些数据才能继续编辑。

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

当前仍为 0.1.0-dev，正式 0.1.0 未发布。六章第二轮修订基线提交为 [e335e4e](https://github.com/zyg0733/agent-systems-engineering/commit/e335e4e6f0b10406b3c5f1a02c34b7242a326809)：[Reading site](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40220350159)和 [Lab checks](https://github.com/zyg0733/agent-systems-engineering/actions/runs/40220350130)通过；首次 P3 失败证据及首因未知的结论保留。该基线不替代本批全书验证；本批以对应提交的 [Actions](https://github.com/zyg0733/agent-systems-engineering/actions)和后续记录为准。

旧候选和 v1 发行工具保持原字段，release_ready=false 和历史真人 0 不伪造成通过。本轮以[教材质量计划](public-reading-quality-plan.md)推进代理评审，不把旧真人 gate 设为教材继续写作的条件。完整平台与正式版本发布另行处理，本轮不创建 tag 或开放网站。
