# W22 作者技术核验：第 2、5、8 章

日期：2026-10-23。本记录由协作编码 agent 对项目源码、测试和章节命令执行核验后整理，属于作者侧技术核验，不是独立自然人试读，不计入原计划的 3 至 5 人试读门槛。当前三章为此前缺失的试读初稿；卡点为已观察到的文档衔接问题及易误读的责任边界，没有虚构读者引语、完成时间或满意度。

核验范围为 [第 2 章](../book/ch02-agent-state-machine.md)、[第 5 章](../book/ch05-agent-loop-and-tools.md)、[第 8 章](../book/ch08-session-context.md)。未修改 runtime、旧实验记录或现有权限、预算和恢复协议，未运行全量回归或数据库故障演练；这些验收由 W22 总记录另行汇总。

## 发现与修订

| 编号 | 源码或既有文档显示的问题 | 本次修订 | 读者应能核验的事实 |
| --- | --- | --- | --- |
| A01 | 研究计划将 Session 对应 L04，而实际 L04 为工具、L05 为 Session | 三章开头列出现行编号和顺延原因 | 能直接打开目标实验，不按旧表猜文件名 |
| A02 | Kernel 的轮数拒绝与 RunServer 的显式 fail 是两个动作 | ch02 §2.6、ch05 §5.8 分开说明 | Kernel 拒绝后状态不变；RunServer 不再请求 Provider 并记录失败 |
| A03 | `storage: :postgres` 只持久化部分事实，RunServer.Budget 明确是进程内控制 | ch05 §5.8、ch08 §8.9 指向持久 Recovery/TaskBudgetStore | 重启旧教学循环不能冒充预算与执行安全恢复 |
| A04 | 手写 Kernel 工具结果没有实际执行 Mock/文件 | ch02、ch08 手工示例前明确限定，ch05 使用实际 Mock 台账 | 把“已接受回执”和“外部效果证据”分开 |
| A05 | 最近一次 Context 使用请求前 Run，而 snapshot.state 可已是终态 | ch08 §8.7 明确固定来源时点 | 不用最终 State 核验推理前输入 |
| A06 | 旧默认产物目录已可能存在，演练主动拒绝覆盖 | ch05/ch08 使用 `mktemp` 父目录和全新输出子目录 | 重复命令不要求删除旧证据 |
| A07 | `lab.stream` CLI 没有 `--output`，其它演练有 | ch05 §5.5 使用真实参数，并解释日志另存 | 正常/取消/超限三个命令均可运行 |
| A08 | ETF 输入字节、JSON 文件长度、token 和费用不能混用 | ch05/ch08 明确 `Context.encoded_bytes` 与预算度量 | 不通过 JSON 文件大小推导模型成本 |
| A09 | v2 历史存储封装与 Kernel schema/Codec 版本独立 | ch02 §2.5 明确历史 envelope v2 的范围 | 不把升级成功误读为任意 schema 向后兼容 |
| A10 | 命令跨越 IEx 与 shell，新读者容易粘贴到错误入口 | ch05/ch08 显式给出 `System.halt()` 和 shell 变量生命周期 | 能在同一终端继续执行后续步骤 |

上述修订来自真实 API/文档对照和命令执行；外部读者是否仍会卡住，需要通过独立试读收集，不能由此推断。

## 执行证据

三章全部 `elixir` 代码块按章依序提取后，在全新 BEAM 的 `LAB_DATABASE_ENABLED=false` 模式原样执行，三章均输出 `examples=passed`。脚本保存为 `artifacts/week22-chapters-a-smoke/examples.exs`。固定 Kernel ID 仅用于纯内存值，不写已有数据库。

章节引用的八个测试文件一次执行：Kernel、Kernel pairing、RunServer、RunServer files、RunServer stream、Session、Context、RunServer context，共 **116 passed（1 doctest、115 tests）**，无数据库用例；此计数不是 W22 全量结果。

| 命令 | 实际结果 | 产物 |
| --- | --- | --- |
| `lab.stream` | succeeded，2 轮，1 request/1 effect，重建相同 | 命令输出 |
| `lab.stream --cancel` | cancelled，0 轮，0 request/0 effect，重建相同 | 命令输出 |
| `lab.stream --budget` | failed，output_bytes 超限，0 request/0 effect，重建相同 | 命令输出 |
| `lab.repair --output` 新目录 | 验收退出码 2→0，4 轮、8 事件，3 requests/1 read/2 writes | `artifacts/week22-chapters-a-smoke/repair/` |
| `lab.p1 --memory --output` 新目录 | 4 Context 均压缩并带摘要，事实/完整回执/权限保留，取消 0 写入 | `artifacts/week22-chapters-a-smoke/p1-memory/` |

本轮执行同时发现当时新增的 `reader_study.ex` 存在 `false <- Enum.any?(...) || error` 的不可达匹配编译告警，已报告负责该模块的主 agent 处理。没有越权修改其文件；最终 warnings-as-errors 与全量回归结果以 W22 总验收为准。

## 仍需自然人试读的问题

请独立读者在未由作者逐步带领的情况下记录：在哪条命令停住、错误输出、查了哪段说明、是否自行解决、所用平台/版本和实际产物位置。重点观察三次 `step` 的边界、unknown 核对、IEx/shell 切换、请求前 Context 来源和新输出目录约束。

自然人反馈必须与本记录分开保存，并经本人确认后才用于试读统计。自动化验证不能证明教材解释已经被理解，也不能取代全新环境的独立复现。
