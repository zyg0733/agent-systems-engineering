# 阅读准备与先修桥接

本书面向写过程序、希望理解 Agent 执行与恢复机制的读者。熟悉后端任务、进程或数据库会更容易进入后半部分；不要求真实模型密钥，也不把已有 Elixir/OTP 经验作为开始阅读的条件。全书使用固定 Scripted/Recorded Provider、Mock 与受控工具解释现有机制，并明确区分设计推演；不能据此推断真实模型的任务能力。

## 先选择阅读深度

| 你的目标 | 开始前需要什么 | 当前入口 |
| --- | --- | --- |
| 理解设计与反例 | 能读条件分支、函数输入输出和简单状态图；愿意区分“请求做什么”与“已经发生什么” | 先读[第 1 章导读](ch01-from-llm-apps-to-agent-systems-engineering.md)，用下方自测找到补读点，再进第 2 章 |
| 跑通纯内存练习 | 会在终端进入目录、运行命令；有仓库访问权和 Elixir/OTP 环境；能读元组、map 和模式匹配 | [L01 首次小练习](../labs/L01-state-machine.md#first-exercise) |
| 完成持久化与故障实验 | 在上一行基础上，能使用自己的可丢弃 PostgreSQL，理解事务、进程退出和并发 | 先补下方事务与领取桥接，再按[课程地图](../docs/course-map.md)逐项完成 |

只阅读概念可以暂不安装工具。运行实验前先查看[开始学习](../README.md#快速开始)的安装与平台说明：当前仓库仍私有；完整隔离实验依赖 macOS Seatbelt，Linux 核心回归并不包含该后端。

## 五道自测

先写一句自己的解释，再展开核对。它们用于找到需要补的知识，不是入学考试。

1. 函数返回 `{:error, reason}`，与函数让数据库写入一半再报错，有什么区别？
2. `s1 = %{s0 | status: :running}` 后，`s0.status` 会自动改变吗？
3. 客户端超时，没有收到提交成功的回复，能否断定事务没有提交？
4. 两个 Worker 都看见“任务待处理”，能否各自开始执行？
5. 旧 Worker 租约过期后，它的进程和远端请求会自动消失吗？

<details>
<summary>核对解释与补读入口</summary>

1. 返回值本身不证明有没有副作用。纯 Kernel 只计算返回值；数据库边界还需事务来保证原子性。见下方“纯转换与事务”。
2. 不会。Elixir 数据不可变，更新表达式生成新值。见下方“读懂示例语法”。
3. 不能。COMMIT 可能已经完成而 ACK 丢失，需查询权威记录。见“纯转换与事务”。
4. 不行。读取待处理状态与领取资格不是同一件事，需要原子 claim，并在提交处校验当前资格。见“并发领取”。
5. 不会。有效租约给出有时限的资格，fencing 才能在参与校验的边界拒绝旧资格。见[术语表](glossary.md#租约与执行资格)。

</details>

## 读懂示例语法

本书的 `sh` 代码块在**项目根目录的终端**执行；`elixir` 代码块若标为 IEx，则先用 `./scripts/iex` 进入交互会话。`# =>` 表示预期值，不是要复制的终端提示符。不要把 `iex>` 或 `$` 当作命令的一部分。

| 写法 | 在示例中的意思 |
| --- | --- |
| `:running` | atom，用于有限的状态或标签；与字符串 `"running"` 不同 |
| `{:ok, value}` / `{:error, reason}` | 带标签的元组，调用方按返回形状分支 |
| `%{operation_id: "op-1", tool: "mock_write"}` | map；这里使用 atom 键，不能随意改成字符串键 |
| `{:ok, s0} = LabKernel.new("run-1")` | 模式匹配；返回形状不同会抛出匹配错误，从而暴露预期不成立 |
| `%{s0 | status: :running}` | 基于旧 map/struct 生成新值；不会就地修改 `s0` |
| `e1 ++ e2` | 拼接两个事件列表；列表顺序是重建输入的一部分 |
| `alias AgentSystemsLab.Kernel, as: LabKernel` | 使用短名；避免与 Elixir 自带的 `Kernel` 混淆 |

变量可以重新绑定，但先前的值不会被就地修改。实验中把状态依次命名为 `s0`、`s1`、`s2`，是为了保留转换前后的对照。IEx 中 `true = expression` 是一个简单断言：只有表达式为 `true` 才匹配成功。完整测试使用 ExUnit 的 `assert`。

### 读懂累计器与匿名函数

第 8 章用 `Enum.reduce/3` 依次追加消息。先在 IEx 看一个不依赖项目模块的例子：

```elixir
sum = Enum.reduce([1, 2, 3], 0, fn item, current ->
  next = current + item
  next
end)
6 = sum
```

三个参数分别是输入集合、初始累计值、每轮调用的匿名函数。`fn ... -> ... end` 定义函数；第一轮 `item=1`、`current=0`，返回的 `next=1` 成为下一轮的 `current`，再依次得到 3 和 6。换成 Session 时，累计器是整个会话值，通过 `{:ok, next} = Session.append(current, role, content)` 取出新会话，再以 `next` 作为本轮结果返回；这是 `Session.append/3`，并非直接返回会话。原 `s0` 不会被修改，不能只执行多次函数却丢掉其返回值。

## 纯转换与事务

**纯转换**回答：“给定状态和命令，应接受什么事实，下一状态是什么？”`Kernel.dispatch/2` 不执行工具，也不自动保存数据库。命令被拒绝时，返回错误，没有一份新的成功转换可提交。[第 2 章](ch02-agent-state-machine.md)从这里开始。

**进程**是运行代码和保存内存状态的容器。GenServer 可以串行处理自己的消息；Task 可以在另一个进程执行工作。monitor 通知某个进程退出，但不会告诉你它退出前的数据库事务或远端效果是否成功。监督树可以重新启动进程，不能凭空还原丢失的内存事实。[第 5 章](ch05-agent-loop-and-tools.md)把执行驱动放到纯转换之外。

**事务**把一组数据库写入作为一个提交单位。本项目把 Run 投影、Event 与下一调度意图放在同一事务里。COMMIT 前回滚，不应只留下其中一项；COMMIT 后回复丢失，数据库仍可能已有全部新事实。Ecto Repo 是本项目访问数据库的入口，不能把一次 Repo 调用等同于外部工具与数据库的跨系统原子提交。准备实验时先读 [L02](../labs/L02-transactions.md)与[事务 ADR](../docs/adr/0002-transactional-storage.md)，再进行故障注入。

## 从会话到模型输入

Session 保留对话与任务事实；Context 是从某个 Session 版本构造的模型输入。压缩输入不应改写完整会话。权限、回执等硬事实与可裁剪叙述用途不同；本项目还会记录 manifest，让实际输入可追溯。本地序列化字节预算不等于某个模型 API 的 token 计费。[第 8 章](ch08-session-context.md)和[术语表](glossary.md#会话与历史)给出具体边界。

## 从历史到外部效果

Event history 能重建已接受的状态；Checkpoint 提供一个受校验的状态切片。两者都不能替代“执行下一步所需的资格、权限和外部事实”。读[第 14 章](ch14-history-checkpoints-and-replay.md)时先问“重建要不要调用工具”；再读[第 16 章](ch16-durable-effects-and-reconciliation.md)，问“工具已发生效果而回执丢失怎么办”。`unknown` 是结果还不能确定，不能直接改叫失败然后重试。

## 并发领取

调度器扫描已提交的 intent；Worker 先通过数据库原子 claim 获得当前执行资格，再执行一个步骤。锁保证领取过程中的并发条件；lease、token 与 generation 供后续续期和提交校验。`SKIP LOCKED` 允许扫描者先处理没有被其他事务锁住的候选项，不保证全局严格先来先服务，也不证明外部效果只发生一次。

进入[第 20 章](ch20-scheduling-and-recovery.md)前，至少能解释上一段，并读 [L10 的调度协议](../labs/L10-background-scheduling.md#2-先读调度协议)。若要动手验证，先完成 L01—L09，再按 **L10 → L11 → L12 → L13**：L11 只依赖已完成的 L10，无需先完成同属 C07 的 L12/L13。完整课程入口见[课程地图](../docs/course-map.md)。

读完准备页后，按[阅读路线](reading-route.md)继续。遇到近义词混用时，先查[术语表](glossary.md)，再回到具体 API 与测试核对。
