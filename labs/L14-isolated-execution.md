# L14：隔离执行、权限与进程清理

对应第 15 周；前置 L01—L13，建议用时 12—16 小时。原计划将 Sandbox 编号为 L09，本仓库沿用已经交付的连续编号。先读 [隔离执行 ADR](../docs/adr/0014-isolated-execution.md)、[运行手册第 13 节](../docs/recovery-runbook.md#13-隔离执行与清理) 与 [验收记录](../docs/validation-week15.md)。

实验结束时，应能区分参数拒绝、操作系统权限拒绝、程序退出和资源回收。执行失败、超时或调用者崩溃之后，既要检查业务结果，也要核对本次实际创建的宿主进程已经结束。

## 1. 学习目标与范围

- 从可信宿主配置构造版本化的工作目录、命令白名单、网络和资源策略。
- 用直接 open/connect/fork 的程序证明越权操作无法绕过工具网关。
- 验证 CPU、单文件大小、输出与 wall-clock 限制，并观察真实清理结果。
- 区分 BEAM 进程停止、宿主目标退出、原生监督器退出和外部效果核对。
- 在后端不可用、策略非法或初始化失败时停止，不退回普通宿主执行。

当前验收环境为 Darwin arm64，使用 macOS Seatbelt 自定义 profile。原计划首发 Linux 容器后端在本周明确调整为本机等价隔离实验；Linux、容器 namespace/cgroup、总内存/磁盘、多租户边界均未因此通过验证。sandbox-exec 在本机系统手册中已标记 deprecated，不能把本教学后端当成长期可移植接口。

## 2. 准备与运行

在项目根目录执行。该隔离实验本身不要求数据库；完整回归仍需要现有 PostgreSQL：

运行下段完整回归前，先按[完整回归的环境准备](../docs/command-reference.md#完整回归的环境准备)确认自己的可丢弃 PostgreSQL 实例；自定义实例先设置 `PGHOST/PGPORT/PGUSER/PGPASSWORD`，再清除 `DATABASE_URL`。完整回归使用默认测试库名 `agent_systems_lab_test`；另开终端时重新做同样准备。

```sh
unset DATABASE_URL MIX_ENV
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.isolate
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.isolate --output artifacts/week15-isolation-repeat
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

默认输出目录为 `artifacts/week15-isolation`。输出目录已经存在时拒绝执行，以保留原有证据；重复运行选择新目录。后端未支持、初始化失败或任一探针不满足判据时必须返回非成功结果。具体参数、真实计数和原始证据以验收记录为准。

探针源代码为 `priv/isolation/probe.c`。它是实验室控制的固定 C 程序，用直接系统调用触发权限与资源限制，不执行模型生成的 shell，不读取用户私人路径，不打印文件内容或环境变量。编译后放入本次私有 fixture，所有 canary、工作文件和 loopback 监听器都属于本次实验。

## 3. 策略与授权来源

`Isolation.Policy.new/1` 使用可信工作目录和明确可执行文件构造策略。`network: :deny` 是当前唯一网络模式。资源包含 `wall_time_ms`、`cpu_seconds`、`max_output_bytes`、`max_file_bytes` 与 `max_processes: 1`；范围由策略校验决定。参数属于已登记命令的输入，不能借助命令参数修改策略。

不要将工作目录设置为用户 home、仓库外的私人目录或整个临时目录。临时文件放在受控工作目录内；运行库只开放必需系统路径。符号链接不能扩大可读写范围，非法根目录应在启动前拒绝。初始化失败时不得调用 System.cmd 执行原命令作为兼容方案。

以下在 `LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/iex -S mix` 中创建独立的内存实验。只允许固定 echo；模型 schema 只能提交 command/args，不含 workspace、network、env 或 limits：

```elixir
alias AgentSystemsLab.{RunServer, Isolation.Policy}
root = Path.expand("artifacts/w15-host-example-#{System.unique_integer([:positive])}")
File.mkdir_p!(root)
{:ok, policy} = Policy.new(workspace: root, commands: ["/bin/echo"])
call = %{operation_id: "exec-1", tool: "sandbox_exec",
         arguments: %{"command" => "/bin/echo", "args" => ["isolated receipt"]}}
{:ok, server} = RunServer.start_link(run_id: "w15-example-#{System.unique_integer([:positive])}",
  input: "run the registered command", isolation_policy: policy,
  script: [{:call, call}, {:final, "done"}])
{:ok, waiting} = RunServer.step(server)
:waiting_tool = waiting.state.status
{:ok, executed} = RunServer.step(server)
"isolated receipt\n" = executed.state.operations["exec-1"].result.output.output
{:ok, done} = RunServer.step(server)
:succeeded = done.state.status
GenServer.stop(server)
File.rm_rf!(root)
```

持久入口是 `Recovery.create_run/3` 的同名 `isolation_policy:` 选项；host 策略在创建事务中写入独立 sidecar 并绑定哈希，恢复调用不能替换策略。未登记时不广告 sandbox_exec，模型主动提出该工具也会在 intent 创建前拒绝。Context permissions 与 manifest 保留固定策略，工具回执继续绑定原 operation ID。对应契约见 `isolation_tool_gateway_test.exs` 与 `durable_isolation_test.exs`。

## 4. 直接系统调用探针

| 探针 | 正向基线 | 通过判据 |
| --- | --- | --- |
| 受控文件 | 在登记 workspace 新建并读回固定内容 | 命令成功，文件内容与大小符合固定 fixture |
| 越界读取 | 父进程确认自己的外部 canary 存在 | 沙箱 open 返回 EPERM/EACCES；不能用 ENOENT 当成权限阻断 |
| 越界写入 | 父进程保存外部 canary 哈希 | 沙箱写入被拒，原文件哈希保持不变 |
| 符号链接 | workspace 内链接指向自己外部 canary | 真实目标读取被拒；字符串前缀检查不是证据 |
| 硬链接 | 分别尝试将外部 canary 与已登记可执行文件链接进 workspace | file-link 被拒，没有可变权限别名；预先存在的多链接普通文件也在策略校验时拒绝 |
| 网络 | 父进程拥有 live loopback 服务，普通探针确实连接成功 | 同一服务上沙箱 connect 被权限拒绝；ECONNREFUSED 或服务未启动不算通过 |
| 子进程与会话 | 原生目标分别调用 fork、posix_spawn、setsid | 内核拒绝创建新进程；目标已是 session/group leader，无法再次 setsid 脱组 |
| 单文件大小 | 在 workspace 写入固定字节流 | 触发 EFBIG/资源终止且文件大小不超过限制 |
| 文件描述符 | 连续打开受允许的 /dev/null | 在原生监督器固定 64 个描述符的硬上限处得到 EMFILE |
| CPU | 持续计算 | 硬 CPU 限制触发实际终止，不能只靠 wall-clock 抢先结束 |
| 输出 | 持续写 stdout | 达到输出限制后停止，返回输出保持有界，目标退出 |
| wall-clock | 目标打印身份后进入睡眠 | 时限触发回收，目标与监督器实际退出 |
| 取消与调用者崩溃 | 先确认实际目标已经启动 | 停止本次拥有的进程树并等待退出；无额外未知 PID 清理 |

默认拒绝 fork 是有意的能力边界。允许 fork 后，目标可能通过 setsid 脱离原进程组；只 kill 原进程组不能自动证明清理了所有恶意后代。当前不提供这种模式。`max_processes: 1` 限制目标程序；受控监督器与 BEAM 控制器仍存在，应分别计数。

## 5. 证据与评分

基础策略保存在 `policy.json`，资源案例在 summary 中记录本次覆盖上限；每项保存命令模式、退出原因、耗时、有界输出、实际 OS 身份和清理记录。`fixture.json` 冻结探针源文件与可执行文件的 SHA-256，`*-execution.json` 保存断言前的真实调用结果，`independent-audit.json` 记录正式验收后对原始结果、哈希和 OS 身份的独立只读核对。canary 的内容不写入报告。保留未支持能力、失败项和原始错误，不把“捕获异常”直接视为成功。检查 `report.json` 的期望数、已完成数和 `all_passed`，再返回逐项记录核对；只有报告文件存在不能证明全部执行过。

系统限制在资源获取时生效，因此预先继承的文件描述符也是权限。检查监督器关闭非契约 FD、环境最小化，以及没有将 Repo socket 或宿主目录句柄交给目标。CPU 和单文件限制不能替代总内存、总磁盘或全系统进程配额，报告中的未支持能力必须保留。

## 6. 与恢复协议的关系

本地清理解决执行生命周期，不替代 lease、fencing、operation 幂等和 unknown/reconcile。超时前可能已经修改 workspace；取消并不撤销该修改。将真实工具结果接入现有 Runtime 时，继续使用稳定调用 ID、结果配对、fenced 提交和未知结果核对，不能因“沙箱已经停止”就盲目重新执行非幂等动作。

完成交付包括源码、对应测试、原始报告、[ADR](../docs/adr/0014-isolated-execution.md)、[运行手册](../docs/recovery-runbook.md)、[验收记录](../docs/validation-week15.md) 和 [参考解答](solutions/L14.md)。运行所有既有测试，确认新隔离层没有改变前序预算、恢复与核对语义。
