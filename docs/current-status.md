# 当前内容、运行环境与边界

更新：2026-11-11（Asia/Shanghai）。这里是当前阅读入口；[W24 已知限制](known-limitations.md)和各周验收保留各自历史时点，不作为新修订已经执行的证明。

## 现在可以读什么

全书七篇、30 章正文草稿已齐，并有 25 份实验手册、12 个课程单元和 30 张设计卡。新读者从[第 1 章导读](../book/ch01-from-llm-apps-to-agent-systems-engineering.md)与[先修桥接](../book/prerequisites.md)进入[完整路线](../book/reading-route.md)，随时查[术语表](../book/glossary.md)。草稿齐备不等于商业出版、生产部署或真实模型能力已经验证；逐章实际范围见[全书复核](book-completion-review.md)。

本轮按项目所有者决定使用 subagent 模拟读者与交叉技术审查，不做真人试读或公开试读评审。六章首批准备见[首轮报告](learning-revision-review.md)，完整阅读/实验路线、练习及解答复核见[第二轮报告](learning-round2-review.md)，新导读与 P3 有界复验见[后续记录](learning-followup-review.md)。模拟、静态核查、代码实跑和浏览器检查分别记录。没有真人满意度或学习完成率，也不要求取得这些数据才能继续编辑。

2026-10-28 的[公开准备修订](readiness-improvements-review.md)同步配套命令和 L19 口径，补齐测试外壳、三个设计案例、终章综合任务、检索排序与 Linux 起步路线；具体执行和未执行范围见该记录。内容准备与实际公开继续分别处理。

## 阅读站与源码如何取得

教材与源码托管在[公开 GitHub 仓库](https://github.com/zyg0733/agent-systems-engineering)，可以直接浏览和 `git clone`；在线阅读入口是 [GitHub Pages](https://zyg0733.github.io/agent-systems-engineering/)。静态网页展示教材，不能在浏览器运行 BEAM、PostgreSQL 或隔离实验。

[材料获取与反馈](material-access.md)提供克隆命令及各类材料的说明。[固定版本实验包](experiment-package.md)是克隆之外的补充方式，由精确提交生成并通过 Actions 保存；下载 artifact 需要登录 GitHub，且有保留期限。网站页脚进入[勘误报告工具](errata.md)，支持本地复制、下载和公开 Issue 草稿；提交 Issue 需要登录。Ubuntu 用户可从 [Linux core 入门](linux-core-start.md)开始适用实验，完整隔离后端仍限已声明的 macOS 路线。

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

教程以公开草稿持续修订；配套软件仍为 `0.1.0-dev`，正式 `0.1.0` 未发布。公开前收尾基线 [a9b3ed6](https://github.com/zyg0733/agent-systems-engineering/commit/a9b3ed644c54102ea7eed9e80b814b23badb786f)已取得 [Reading site](https://github.com/zyg0733/agent-systems-engineering/actions/runs/41085204234)和 [Lab checks](https://github.com/zyg0733/agent-systems-engineering/actions/runs/41085204439)通过记录，覆盖许可、固定源码包及适用回归。此后变更的验证与部署状态以各提交的 [Actions](https://github.com/zyg0733/agent-systems-engineering/actions)为准；既有首次 P3 失败证据及首因未知的结论保留。

旧候选和 v1 发行工具保持原字段，`release_ready=false` 和历史真人 0 不伪造成通过。教材按[质量计划](public-reading-quality-plan.md)继续代理评审，不把旧真人 gate 设为开源教程草稿的发布条件。公开仓库与阅读站不创建正式软件版本 tag，也不代表完整平台和生产使用已经验收。
