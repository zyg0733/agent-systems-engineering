# 跨环境执行与环境证据操作

本手册对应 W26、[L25](../labs/L25-cross-environment-validation.md)与 [ADR 0025](adr/0025-cross-environment-validation.md)。可信宿主先执行固定计划，再采集有界文件，最后由 [ReleaseAssessment](release-assessment.md)按原政策评估。缺少真实冷主机或 Linux 环境时继续 pending；本机技术验收见 [W26](validation-week26.md)。

## 1. 选源码，分清执行范围

保留旧 W22 包、rc.1 目录和归档、W25 试读包。输出用全新绝对路径，父目录先由宿主创建。不要直接在旧包安装或运行；冻结 source 是通过 `Reproduction.verify/1` 的纯源码导出，执行器另外复制工作副本，执行前后核对其声明文件的内容与模式。

| Profile | 实际执行范围 | 可作出的结论 |
| --- | --- | --- |
| `macos-warm` | 本机 macOS，显式提供可信安装缓存，独立源码副本、编译与 PostgreSQL | 只报告实际 warm-cache 复现；不能满足冷主机 gate |
| `macos-cold` | 实际新 macOS 主机，声明未复用 runtime、依赖、数据库，重新取得固定安装输入 | 日志、来源、工具和全部固定命令均有效后，才可供冷安装 gate 评估；`--new-host` 是自报，不认证机器 |
| `linux-core` | 实际 Linux 主机，预装固定版本工具链，运行核心适用回归和主实验 | 平台排除和缺口明确记录；始终不能当作完整 Linux 隔离与矩阵通过 |

没有 `linux-full` profile。现有隔离后端是 macOS Seatbelt，Linux 明确拒绝；原完整 Linux gate 仍需无平台排除、18 项隔离事实和 F01—F12 各 20 轮。CI YAML 存在、模拟 Linux 标志、在 macOS 生成 Linux 计划或测试 fixture 都不是实际 Linux 执行。

执行前由宿主逐项核对前置：

- Python 3 与标准库；可信控制脚本、冻结源码和可选候选可先转移到目标机。未安装 BEAM 的机器先由独立 Python 执行器运行，结束后可把证据移回可信 tool host 采集，无需先安装 Mix 控制工具污染冷安装事实。
- macOS 开发工具提供 `cc`、`make`，以及 `curl/tar/unzip/shasum`；PG 源码解包还需 bzip2 支持。实际记录这些工具是否可用，不把仅安装了编辑器当作编译工具已具备。
- 固定 PostgreSQL 18.6 源码构建需要 C 编译器、GNU make、Bison 2.3 及以上、Flex、Perl 5.14 及以上和系统头文件。本项目 configure 显式关闭 ICU、Readline、zlib；具体步骤以原 [bootstrap](../scripts/bootstrap_postgres.sh) 为准，缺依赖保留配置失败日志。
- 使用普通非 root 用户，拥有本轮输出与安装目录写权限；`initdb` 拒绝 root。安装系统前置与本轮实验执行分别安排，不用 root 启动实验绕过错误。
- Linux 先提供 Elixir 1.20.4、OTP 28.4 和明确指定的 PostgreSQL 18.6 prefix，核对实际版本与来源；不假设系统 apt 默认版本正好匹配，不运行 macOS bootstrap 冒充 Linux 安装。

W26 控制工具和被测源码是两个身份。旧 rc.1 对应 `artifacts/week24-frozen-source-final` 的 502 个源文件，新试读包 `project/` 没有 W26 CLI。控制命令在可信 W26 工具工作区运行，旧源码的固定实验在独立副本运行。W26 的新测试数属于 W26；不能与 rc.1 的较小覆盖数混用。当前源码已修正部分测试临时目录的 macOS 路径假设，这不回写旧候选；旧源码在 Linux 的实际失败也须保留。

## 2. 只读计划

以下变量由宿主选择，路径须为绝对路径；`tool_root` 是可信 W26 项目，不是待验证的候选根。例子绑定原 rc.1，检查和采集时同时提供候选。要验证新 W26 源码，应先导出新的纯源码 source，并省略不匹配的旧 `--candidate`，不要把两个源码强行拼接。

```sh
tool_root="$PWD"
frozen_source="$tool_root/artifacts/week24-frozen-source-final"
candidate_output="$tool_root/artifacts/agent-systems-lab-v0.1.0-rc.1"
execution_output="$tool_root/artifacts/environment-warm-unique"
bundle_output="$tool_root/artifacts/environment-bundle-unique"

LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment plan --source "$frozen_source" --candidate "$candidate_output" --profile macos-warm
python3 "$tool_root/scripts/environment_validate.py" plan --source "$frozen_source" --candidate "$candidate_output" --profile macos-warm --output "$execution_output" --operator-id operator-local --host-id host-local --cache-from "$tool_root" --port 55591
```

两个 plan 只返回数据，不安装、不启动业务或 PostgreSQL、不执行命令。Mix 本身可能编译可信工具工作区。执行器 plan 与纯文件计划应核对同一 profile、源码和固定命令集合；不从计划 JSON 接收可替换的任意 shell。

## 3. 固定命令执行与来源记录

确认真实平台符合所选 profile、固定工具链和构建前置已具备，独立端口未占用，输出不存在，再执行：

```sh
python3 "$tool_root/scripts/environment_validate.py" run --source "$frozen_source" --candidate "$candidate_output" --profile macos-warm --output "$execution_output" --operator-id operator-local --host-id host-local --cache-from "$tool_root" --port 55591 --timeout 1800
```

`run` 会启动独立进程、执行固定 bootstrap/依赖/回归/主实验、初始化和停止本轮自有 PostgreSQL，不是只读命令。命令集合以脚本和 `lab.environment plan` 为准：完整与内存回归、verify、p1、history、recover、fence、upgrade，macOS 另记录安装和依赖取得。固定 argv 以数组传递，不把反馈或证据文字解释为 shell。每步保留原始 stdout/stderr、退出码与结果引用；失败/超时不改写为成功。

Warm 模式显式引用缓存宿主的已安装 OTP/Elixir/PostgreSQL prefix，并复制可写 Mix/Hex/下载缓存；bootstrap 固定命令实际执行但会复用这些安装。不会复制旧 deps、build、PGDATA，依赖在新工作副本编译；不把这次执行写成重新构建所有 runtime。

真实冷主机上使用 `macos-cold`、省略 `--cache-from` 并加 `--new-host`。先确认没有旧 runtime/依赖/数据库可复用；不要先在该机 warm-cache 安装控制工具，再把它称为冷主机。Python 执行器可在未安装 BEAM 的主机准备执行；文件采集可以在执行完后转交可信工具宿主处理。宿主核实身份后，在真实冷 macOS 上设置该机的绝对路径及实际 `operator_id/host_id`，例如：

```sh
python3 "$tool_root/scripts/environment_validate.py" run --source "$frozen_source" --candidate "$candidate_output" --profile macos-cold --output "$cold_output" --operator-id "$operator_id" --host-id "$host_id" --new-host --port 55591 --timeout 3600
```

真实 Linux 主机提供已安装的 Elixir 1.20.4、OTP 28.4、PostgreSQL 18.6，设置可信 PG 安装根 `postgres_prefix`、全新 `linux_output` 及该机身份，执行：

```sh
python3 "$tool_root/scripts/environment_validate.py" run --source "$frozen_source" --candidate "$candidate_output" --profile linux-core --output "$linux_output" --operator-id "$operator_id" --host-id "$host_id" --postgres-prefix "$postgres_prefix" --port 55591 --timeout 1800
```

Linux 不传 macOS 缓存；执行器只复制该 PG 工具安装，不复制数据库。缺工具或平台不符应明确失败，不能回退成另一个平台的成功记录。两个例子也可先将 `run` 换成 `plan` 核对；生成计划不计真实执行。安装前置包括 Python 3、下载/解压程序，以及冷构建 PostgreSQL 所需 C 编译器和 make；所需主机资源与网络由宿主准备。

来源记录包含操作者、主机匿名 ID、实际 UTC、平台、缓存复用、五项输入 `source/otp/elixir/postgres/mix_lock` 的来源与摘要以及实际工具版本。下载、复制缓存、预装工具链分别记录；观察到什么就写什么。输入摘要绑定内容，不认证发布者；现有固定版本 URL、Action/镜像 tag 也不等于不可变供应链。若缺少签名或可信来源认证，应保留该限制，不自行填“已认证”。

## 4. 独立数据库与中断

执行器只在新输出内建立 `owned-postgres`，使用新 PGDATA 和未占用的回环端口，禁用 Unix socket 并清除 `DATABASE_URL` 等继承路由，所有客户端显式走回环地址。先核对空实验库及 `fsync/synchronous_commit/full_page_writes=on`，保存 SQL 查询到的 PGDATA、端口和 system identifier。全局 Scheduler 关闭，避免另一个执行者影响故障实验。

结束、异常或可处理的中断时，必须核对本轮目录、postmaster PID、PGDATA 和端口后才停止自有集群，并记录端口释放与自有命令进程组退出。清理只覆盖这些固定可信实验命令的受管进程组，不扩展为任意恶意后代逃逸后的进程树保证。不要使用原工作区 `scripts/postgres stop`，不要停止共享 55432、删除旧 dev/test 或按名字前缀清理。强制杀死宿主、断电等可能留下资源；归属不明时保留现场，按输出中的身份人工核对，不盲目重跑或清理。

## 5. 有界采集、核验与发行评估

执行完成后从可信 W26 工具工作区采集，不向执行目录或旧候选回写：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment collect --source "$frozen_source" --candidate "$candidate_output" --execution "$execution_output" --output "$bundle_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment verify --source "$frozen_source" --candidate "$candidate_output" --bundle "$bundle_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release.assess --candidate "$candidate_output" --study "$study_output" --evidence "$bundle_output"
```

最后一条的 `study_output` 另由 [W25 手册](release-assessment.md)选定，必须与候选同源码；没有试读输入时省略 `--study`。只有符合原 v1 发行证据合同的 bundle 才作为 `--evidence` 输入；普通工作流执行记录与发行准入报告分别查看，不凭采集退出 0 判断 gate。

Bundle 保存 `environment-validation.json` 文件清单、原始 `execution.json`、绑定的 `source-manifest.json` 及受界日志/结果；`report.json` 是派生输出，verify 不信任其缓存值。有同源码 candidate 时另外生成既有 v1 `environment.json` 和 `environment-evidence.json`，保持原 `ReleaseAssessment` 合同。没有 candidate 的当前源码验证只按工作流报告查看，不把它当成旧候选发行证据。

采集器与 verify 只处理惰性文件，不执行 argv、不启动应用、不连数据库、不安装、不起停资源；报告从验证后的原始材料重算。它再次核对显式 source/candidate，拒绝错绑定、未知 schema/字段、相对路径逃逸、符号/硬链接、特殊文件、hash/大小漂移、超限与已有输出。存在但损坏的材料是 error，不当作“尚未取得”。不要编辑源 manifest、日志、退出码或结果 hash 消除错误。

v1 采集 JSON 上限为 4 MiB，单份日志/结果上限 32 MiB，证据总量上限 256 MiB；命令 ID、顺序与 argv 来自固定表。输出仅保存声明的必要普通文件，不拷贝整个工作副本、安装缓存或 PGDATA。没有取得的输入或命令结果不能凭模板补齐。

缺命令、失败、缓存复用、核心范围、测试排除或清理未完成，应体现在完整性与 gate 中，不能变成 full 通过。Linux 核心通过加排除数可以说明适用覆盖；不能删除排除数或填造隔离/矩阵。实际 W26 交付仍没有真实新主机/Linux/读者时，相关项保持 pending，`evidence_complete=false`、`approval_recorded=false`、`release_ready=false`，发布状态未发布。

同一环境报告只能绑定实际执行的源码；修改代码、章稿或安装脚本后重新冻结并重跑适用验证。来源证据没有显式继承规则就不继承。业务事故继续按[恢复手册第 24 节](recovery-runbook.md#24-跨环境执行证据与独占资源清理)，不因环境采集失败重置 Run 权限、预算、deadline、unknown、审批或 fencing。
