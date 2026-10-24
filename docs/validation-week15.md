# 第 15 周验收记录

验证日期：2026-10-21，Asia/Shanghai。环境为 macOS arm64 / Darwin 25.6、Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6；沿用 mix.lock，没有新增 Hex 依赖。新增第 15 个迁移 `20261021040000_add_isolation_policy.exs`。

## 交付与后端调整

本周实现宿主授权的隔离执行器、文件/网络策略、资源限制和实际进程回收，并接入原 RunServer、Context、Recovery、操作台账与结果配对。实验编号沿用仓库顺序为 [L14](../labs/L14-isolated-execution.md)，附[参考解答](../labs/solutions/L14.md)、[ADR 0014](adr/0014-isolated-execution.md) 与[运行手册第 13 节](recovery-runbook.md#13-隔离执行与清理)。

开发宿主没有可用的 Linux 容器运行时，因此原计划首发 Linux 后端明确调整为本机可实测的 **macOS Seatbelt 教学后端**。只支持一个目标进程、禁止 fork/posix_spawn；不声称已完成 Linux、任意后代、硬内存、总磁盘、网络放行或多租户验收。自定义 Seatbelt / sandbox_init 是已弃用接口，不作为生产安全承诺。未支持能力、后端失败或非法策略一律拒绝，没有普通宿主执行回退。

| 组件 | 实现与边界 |
| --- | --- |
| `Isolation.Policy` | 固定 v1、精确字段、可信命令白名单、默认 deny network、有限预算；拒绝宽根/路径别名/命令链接/可写命令；启动前检查最多 10000 项，拒绝预存硬链接 |
| 原生 guardian | setsid、关闭继承 FD、固定环境与 stdin、硬 CPU/单文件/64 FD；exec 前安装 profile；原生 wall timer 与输出限制；只对尚未 reap 的自有目标发信号 |
| 控制通道 | 目标输出与 guardian frame 分管道；profile/编译缓存位于授权目录之外，拒绝双向重叠；固定绝对系统 dyld import，不搜索工作目录 |
| `sandbox_exec` | schema 只有 command/args；宿主显式登记后才公开，模型无法传环境/profile/授权；结果继续核对 operation_id/tool |
| 持久化 | policy sidecar 在创建事务中保存并验证 hash，不改原 v1 config；短事务复验资格，进程执行在 SQL 锁之外，回执再次 fencing |
| 恢复与预算 | 期限取 policy/Run/任务/retry/观测 lease 的最早值，慢 setup 后再扣剩余时间；prepared 未确认按非幂等 unknown 处理，禁止自动重投 |
| RunServer | 独立工具 Task 保留取消/总超时响应；Task 异常先规范化诊断再持久化，不能因异常含 PID/ref 而卡在 waiting_tool |
| 纯重建审计 | 新增 Gateway.execute/5 与 Isolation.execute/3,/4，共 23 个执行入口；真实隔离回执落库后重建仍全部零调用 |

## 最终自动验收

```sh
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

最终 **625 passed（623 tests、2 doctests），0 失败**，测试用时 71.8s；原 **10/10 fixtures** 与四个 COMMIT 前后真实进程 kill 检查全部通过。完整结果见 [week15-check-final.log](../artifacts/week15-check-final.log)。无数据库模式 **299 passed（297 tests、2 doctests），326 个数据库测试排除**，用时 8.7s，见 [week15-memory-tests-final.log](../artifacts/week15-memory-tests-final.log)。格式、无警告编译与 15 个迁移均通过；开发库也已应用[新增迁移](../artifacts/week15-migrate-dev.log)。平台测试实际在本机运行，未以排除方式通过本机验收。

| 本周测试组 | 数量 | 核对内容 |
| --- | ---: | --- |
| Policy | 19 | 严格授权/版本/argv/路径与别名、有限资源、命令不可写、硬链接预检、有限目录扫描、固定系统 import |
| Isolation | 8 | 后端与选项拒绝、执行器路径保护、过期不启动、stdout 不冒充控制、固定环境、callback 异常清理、原生 timer、恶意同名 profile |
| Gateway / RunServer | 5 | 精确 schema、未授权不创 intent、配对回执与权限 Context、运行中取消、Run 总超时 |
| Durable / PostgreSQL | 6 | 策略原子/不可变/损坏拒绝、回执复用与重建零调用、效果未确认崩溃、锁外运行与迟到 fencing、retry 剩余额度、不可持久异常规范化 |
| Fail closed | 1 | 不支持后端不运行自有 marker 程序，不调用 on_start；非 Darwin 默认后端同样拒绝 |
| IsolationDemo | 4 | 参数/目录保护、起始失败保留未完成报告、18 个真实 syscall 与实际退出 |

本周新增 43 项，W14 已有 582 项继续保留。Ubuntu CI 保留原检查流程，非 Darwin 明确排除 `:seatbelt` 的平台用例；纯策略、参数、目录保护与后端拒绝仍执行。本机以这五份新测试文件验证分组，**23 passed、20 个平台测试明确排除**，见 [week15-portable-tests.log](../artifacts/week15-portable-tests.log)。当前没有 Linux 后端，没有运行远程 CI，也不以这个本机分组验证代替 Ubuntu 实测。

## 最终冻结版真实演练

```sh
./scripts/mix lab.isolate --output artifacts/week15-isolation-final2
```

**18/18 探针通过**。使用实验拥有的外部 canary、工作区、固定 C 程序与 loopback listener；没有读取私人内容或依赖真实外网。每项输出在判据核验前写 raw execution，失败保留证据。目录存在时拒绝覆盖。

| 真实窗口 | 最终证据 |
| --- | --- |
| 受控文件 | 读写成功，内容固定 19 字节 |
| 越界读/写与 symlink | 外部 canary 确实存在，open 返回权限拒绝，哈希不变 |
| 外部/可执行文件 hardlink | 两项直接 link 调用均拒绝，没有产生可变别名 |
| 未授权网络 | 普通程序先实际连上自有 live loopback 服务；同服务上沙箱 connect 被拒绝，listener 未收到连接 |
| fork / posix_spawn / setsid | 三项直接调用均拒绝；只允许既有 session leader 目标 |
| CPU | 上限 1s，实际 CPU 1028ms，SIGXCPU 24，墙钟 1042ms，先于 5s wall 上限 |
| 单文件 | 上限 4096B，最终文件 4096B，触发资源错误/终止 |
| FD | 固定总上限 64，新开 61 个后 EMFILE；含已有三个标准描述符 |
| 输出 | 捕获 4096B，观察 13312B，终止并回收；返回值没有超限 |
| wall | 上限 100ms，实际 guardian 报告 110ms 回收；不作为系统暂停下实时上界 |
| 取消 | nonce/PID 确认实际目标已运行，再取消；55ms 返回并核验两个 OS 进程退出 |
| 调用者崩溃 | 实际启动后 kill BEAM owner，独立观察 guardian/target 退出，不以 BEAM DOWN 代替 OS 检查 |
| 未登记命令 | 起跑前拒绝，没有创建目标 |

总报告：[report.json](../artifacts/week15-isolation-final2/report.json)；原样 CLI 日志：[week15-isolation-final2-run.log](../artifacts/week15-isolation-final2-run.log)。目录中保留 base policy、每项 override 与 raw/summary、源程序/可执行文件 SHA 和身份文件。

另以自动测试在 workspace 放入同名 `(allow default)` 的恶意 dyld profile：受控文件可读，外部 canary 仍被直接 syscall 拒绝。固定绝对 import 不受 CWD 文件影响。继承环境、控制数据伪造、callback 异常及超期起跑也分别验证；这些不冒充 18 项演练中的额外探针。

## 独立审计、源码冻结与故障记录

最终报告结束后，独立 Python 只读审计 **91/91 通过**：逐项核对 raw/summary/report、源文件与 guardian 实际构建/二进制 hash、canary 未泄露与无链接别名、受限文件与私有临时目录，并观察 **34 个本次拥有的 OS 进程身份全部不存在**。审计只做 kill(pid, 0) 存活观察，没有向任意进程发送终止信号。

- [executor-manifest.json](../artifacts/week15-isolation-final2/executor-manifest.json) 绑定 guardian/probe/policy/executor 源码、实际 binary/build、报告与日志；快照设为只读。
- [independent-audit.json](../artifacts/week15-isolation-final2/independent-audit.json) 与[可复跑审计脚本](../artifacts/week15-isolation-final2/independent-audit.py)。这是事后证据核验，不声称再次注入 syscall 或重新创建网络基线。
- [实际执行的宿主示例](../artifacts/week15-docs/manual.exs) 与[日志](../artifacts/week15-docs/manual.log)，对应 L14 的 RunServer 登记/回执/最终回答示例。

此前 `week15-isolation` 已通过初版 18 项；`week15-isolation-final` 在执行期间发生宿主源码更新，独立审计正确检测到漂移并报告失败。这些目录与失败未覆盖；它们不能作为最终版本通过的证据。冻结代码后在全新 final2 重跑，最终 manifest 与审计一致。

独立审查还修复了：reap 后按旧 PID 发信号的复用窗口（handler 信号屏蔽 + 清除所有权）、callback 异常提前返回而未等原生退出、工具任务异常中的不可持久值、相对 dyld import 搜索歧义，以及新执行入口缺失于重建审计。每项由对应测试或新探针复跑确认；没有通过降低原判据消除失败。

## 仍保留的边界

只证明当前平台、当前固定探针与单目标策略。宿主自身、编译器、OS 和运行库可信；没有保护另一恶意宿主进程同时改目录，也没有任意后代或内核漏洞隔离声明。文件单项配额不限制总磁盘，CPU/FD 不限制总内存；未支持选项直接拒绝。

本地授权 COMMIT、进程启动、文件效果、receipt COMMIT 无法成为同一事务。取消和 fencing 不能撤销已有 workspace 效果，目标已退出也不代表没有发生；未确认结果继续走可见核对队列。OS 暂停/强杀 guardian、系统停滞和远端效果的 exactly-once 不在验收范围。整个 BEAM 立即退出可能留下无效私人控制文件，须按运行手册核验实际进程后清理，不能批量清空在途执行者。
