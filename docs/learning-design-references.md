# 公开 AI 教材的组织方式与本书借鉴

研究日期：2026-10-25。以下是官方项目页面的结构性观察，不是对其教学效果的独立排名；本轮没有运行这些项目的代码。我们借鉴学习组织方式，保留自己的内容、实验和许可边界。

## 1 Hugging Face Agents Course

官方入口集中介绍课程结构、先修与工具，并区分旁听和完成活动的路线；基础单元中穿插小测，再衔接实践。[课程入口](https://huggingface.co/learn/agents-course/en/unit0/introduction)、[基础单元](https://huggingface.co/learn/agents-course/en/unit1/introduction)

本书采用：在“开始学习”先判断阅读还是动手，提供先修自测；将第一条可运行小轨迹放在完整 L01 之前；章内预测题给分层提示。当前保持无模型密钥的离线主线，不加入账号或认证流程。

## 2 Microsoft AI Agents for Beginners

官方学习指南按学习目标列出起点和后续课，同时把每课“学什么”与“试做什么”放在一起，并用一个小应用连接课程。[Study Guide](https://github.com/microsoft/ai-agents-for-beginners/blob/main/STUDY_GUIDE.md)

本书采用：以六章现存正文作可走通的主线，标出每章先修、可检验产物和下一步；概念阅读与完整实验分别安排。我们关注持久性与故障窗口，不把该项目采用的云服务或框架变成本书依赖，也不照搬其代码。

## 3 Dive into Deep Learning

D2L 在前言说明将原理和可运行代码结合、按实践需要及时引入概念；具体章节把小结与修改代码条件的练习放在示例之后。[前言](https://d2l.ai/chapter_preface/index.html)、[Data Manipulation 示例章节](https://d2l.ai/chapter_preliminaries/ndarray.html)

本书采用：预期状态/计数紧邻代码，要求先预测再执行；错误 ID、丢响应、取消与旧 claim 都作为改变条件后的解释题。保留 Markdown/VitePress 与本地 BEAM/PostgreSQL，不引入 Jupyter 或切换整站框架。

## 4 本轮落地与后续

| 观察 | 本轮落地位置 | 验证方法 |
| --- | --- | --- |
| 入口先说明先修与路线 | [先修与桥接](../book/prerequisites.md)、[开始学习](../website/start.md) | 新手视角代理找路与自测，检查所有链接 |
| 每章目标对应小产物 | 六章开头与[阅读路线](../book/reading-route.md) | 交叉检查目标、例子、题目是否一致 |
| 先小练习再长实验 | [L01](../labs/L01-state-machine.md) | 实跑内存轨迹、错误 ID 与重建断言 |
| 提示与答案分层 | 六章首次练习 | 浏览器检查展开/收起、键盘和代码可读性 |
| 概念之间有统一解释 | [术语表](../book/glossary.md) | 核对源码含义及易混概念 |
| 旧报告不混成当前状态 | [当前状态与边界](current-status.md) | 当前导航与历史证据入口分别检查 |

这些是本书的编辑决策，不把外部项目的存在当作本书质量证明。不复制他人正文、图表或示例；若以后需要具体改编，再逐项核对来源与适用许可。
