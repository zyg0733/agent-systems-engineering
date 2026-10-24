# ADR 0014：隔离执行器与宿主能力边界

- 状态：接受，用于第 15 周教学实验；后端能力以实际探测和验收记录为准。
- 日期：2026-10-21。
- 依据：[原研究计划 W15](../../Agent%20Systems%20Engineering%20研究与落地计划.md)、[受控工具 ADR](0004-controlled-tools-and-call-pairing.md)、[恢复运行手册第 13 节](../recovery-runbook.md#13-隔离执行与清理)。

## 问题

第 5 周的文件工具校验路径、哈希和修改范围，但执行任意程序后，程序可以直接调用 open、connect、fork，绕过 Elixir 工具入口的参数校验。工作目录、Git worktree 与路径前缀都不提供操作系统隔离。第 13—14 周停止 BEAM executor 也不能自动证明其启动的宿主进程已经退出。

执行器必须分别约束可执行文件与参数、可读写文件、网络、资源与生命周期。拒绝策略或后端初始化失败必须阻止命令启动；不能退回普通 System.cmd。取消和调用者崩溃要停止并等待执行器自己拥有的进程，不按未验证的任意 PID 清理宿主。

## 决定

隔离策略来自可信宿主配置；模型只能提交已登记命令的参数，不能扩大命令白名单、工作目录、网络或资源上限。策略按版本校验，工作目录必须为已存在的真实目录，拒绝符号链接根目录；命令为明确的可执行绝对路径。网络仅提供 deny；没有 allow-all 或不受控宿主网络后备路径。

当前开发环境是 Darwin arm64，原计划的“一种 Linux 容器后端”调整为本机可验证的 macOS Seatbelt 后端。受控原生监督器使用 sandbox_init 安装自定义默认拒绝 profile，设定硬资源限制并管理目标生命周期。该决定不声称 Linux 容器、namespace、cgroup 或其他操作系统已通过验证；缺少支持后端时返回明确错误。sandbox-exec 和 sandbox_init 的本机系统手册将接口标记为 deprecated，因此此后端用于当前教学宿主，不作为长期跨平台或多租户边界的承诺。

文件规则只放行工作目录、登记的可执行文件和必要系统动态运行库。profile 以固定绝对路径 `/System/Library/Sandbox/Profiles/dyld-support.sb` 完成动态装载，不按 CWD 搜索，不引入有更大宿主访问面的 system.sb；真实测试在 workspace 放置同名恶意 profile，越界 syscall 仍被拒绝。运行时临时目录位于工作目录内，不因 TMPDIR 或宿主环境变量扩大权限。调用直接系统调用的可信 C 探针检查越界读取、越界写入与符号链接目标；仅看到工具参数拒绝不能算操作系统隔离通过。探针只使用实验自己创建的 canary，不读取个人文件，不输出 canary 内容。

硬链接会把同一个 inode 暴露到另一条获准路径，因此仅处理符号链接还不够。策略在有界的 workspace 预检中拒绝多链接普通文件，命令文件同样要求没有链接别名；profile 拒绝创建 file-link。直接探针还需验证已登记可执行文件不能硬链接进可写 workspace。宿主必须在启动期间保持 workspace 根与命令的独占控制；这种路径预检没有声称能对抗另一个恶意宿主进程同时替换目录项。

默认只允许一个目标程序，Seatbelt 拒绝 process-fork，并以实际 fork 与 posix_spawn 探针分别验证。这个进程数量约束不依赖 RLIMIT_NPROC：该限制按用户计数，无法等同于单个沙箱的配额。目标先成为独立 session/group 的 leader，setsid 探针也必须被拒绝；拒绝创建子进程同时阻止通过 fork 后 setsid 脱离原进程组。当前不提供允许任意子进程的模式；监督器和目标仍是实际创建且需要清理的宿主进程树。不能从进程组 kill 推导已覆盖任意脱离会话的恶意后代。

CPU 与单文件大小使用继承的硬资源限制；wall-clock 与输出上限由受控监督路径回收。硬限制不能被非特权目标调高。原始流量超过输出上限时要终止并回收，不能只截断日志后让程序继续产生输出。CPU 秒数、单文件大小不等于完整内存、总磁盘或容器配额；未实现的能力必须在报告中明确列出。

本机 sandbox(7) 手册指出，限制通常在资源获取时执行，已经打开的文件描述符可能继续使用。监督器应关闭非契约描述符、最小化传入环境，并把 stdin/stdout/stderr 限定为受控通道；不将数据库连接、宿主目录句柄或其他能力交给目标。

## 验证与证据

运行 [L14](../../labs/L14-isolated-execution.md) 的独立探针：受控读写成功；自己的外部 canary 在存在时得到 EPERM/EACCES；真实 loopback 服务基线连接成功，沙箱连接被内核拒绝；fork、posix_spawn 与再次 setsid 被拒绝；CPU、单文件、wall-clock、输出超限触发终止或明确资源错误；取消与调用者崩溃后目标和监督器退出。每项保存策略、真实退出原因、有界输出与清理记录。没有命中窗口、初始化失败、只发生 ENOENT/连接拒绝或回调异常，均不得伪报为隔离成功。

验收记录应报告实际系统、编译器、后端、限制值和未支持能力，保留失败记录且禁止覆盖旧输出目录。普通工具幂等、unknown/reconcile、lease 与 fencing 的测试继续运行。杀死本地进程不能撤销此前已完成的文件修改，也不能证明任何外部效果没有发生；实际工具接入仍保留原 operation 身份和提交协议。

## 后果

本周提供可检查的本机执行边界，而不把应用层路径校验冒充内核隔离。代价是命令能力与平台支持都很窄，需要原生构建及后端探测。后续 Linux 后端必须独立实现相同契约并运行相同直接系统调用探针，补上 namespace/cgroup、镜像/挂载与网络证据后才能声明支持；不能只在文档中替换平台名称。

## 一手依据与复核

本次直接阅读宿主的 `sandbox-exec(1)`、`sandbox_init(3)`、`sandbox(7)`、`setrlimit(2)` 系统手册，并检查系统自带的 `/System/Library/Sandbox/Profiles/dyld-support.sb`。手册明确了接口弃用、子进程继承、资源获取时检查、预先打开的 FD 以及硬资源限制的语义。可使用 `man sandbox`、`man sandbox_init`、`man setrlimit` 在同一宿主复核；实际 profile 与探针输出仍是运行验收所必需的证据。

Apple 的 [App Sandbox 官方指南](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html) 说明基于 entitlements 的应用权限与子进程继承，并推荐 XPC 做权限分离。本期自定义 Seatbelt 执行器没有声称采用或完成这套 App Sandbox 应用分发流程，不能混用两套配置作为验证证据。
