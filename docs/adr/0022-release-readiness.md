# ADR 0022：源码准备检查与分开的正式发布 gate

状态：W23 实现。项目仍为 `0.1.0-dev`，`0.1.0` 是目标版本；W24 最终矩阵、变更冻结、tag 与发布决定不在本周自动完成。用户已经确认真人记录缺失时先交付试读包与技术验收，W22 外部 gate 继续待验收。

## 背景

已有 21 周运行时、22 周技术交付与连续 L01—L21 实验，接口、版本、恢复步骤和课程入口分布在多处。若只写“可发布”布尔值，会混淆源码一致、实际回归、操作系统能力、真人可读性与发布行为。未知版本、错误连接或误用执行入口还会危及原权限和恢复合同。

## 决定

整理[公开接口](../public-interfaces.md)、[安装运行操作](../release-operations.md)和[已知限制](../known-limitations.md)，区分可信宿主 CLI/教学 API、Provider/工具合同与内部事务实现。Provider behaviour 不等于当前可任意装配模型；固定工具目录不等于自注册插件。当前版本不升级成稳定 SDK。

使用固定 inert [manifest](../../fixtures/release/manifest.json) 绑定版本、选定源码 hash、21 个迁移、30 张章卡与 12 次课程入口。`ReleaseReadiness.check/0,1` 对当前可信源码做有界只读验证；严格拒绝缺失/未知字段、漂移、无效入口、链接与边界输入，不自动重写 pin 或运行补救。`plan/0,1` 检查后仅输出固定测试 argv 与待验收项，不接受反馈或报告里的任意命令。

`lab.release check|plan` 只编译，不启动应用、Repo、Scheduler、Provider 或工具。报告显示 `source_ready=true` 时仍保留 `release_ready=false`、外部真人未评估、W24 矩阵待执行和 tag 未创建。源码 pin 不是本机实际运行时探测，hash 不是来源认证；编译可能写 `_build`。实际测试和故障演练另外保留日志、源码身份和结果。

30 张章卡提供完整教学结构，不冒充 30 篇长章正文；12 次课程按前置知识映射现有连续实验编号。W22 冻结试读包保持原协议，不被本周新文档覆盖。正式外部 gate 仍需独立真人记录，代理、作者与测试 fixture 均不得充数。

## 不变式与验收

业务 Runtime、权限、五维预算、已扣额度、absolute deadline、操作与结果配对、unknown/manual 队列、审批 hash/generation、lease/fencing 与恢复语义保持。无新增业务 migration、依赖或运行时执行能力，不通过新建 Run/ID、直接改表或版本回退重置事实。

新增测试验证源码准备的正常结果、元数据与 pin 漂移拒绝、章节/课程覆盖和零业务执行；完整 check 与内存模式继续通过。W23 技术验收不替代 W24 最终矩阵、跨环境验证、外部可读性或发布批准。配套 [L22](../../labs/L22-release-readiness.md)、[解答](../../labs/solutions/L22.md)与[本周记录](../validation-week23.md)。
