# Ubuntu 24.04：从固定工具链到首次内存练习

这条路线面向 Ubuntu 24.04 的 **Linux core**：先运行不需要 PostgreSQL 的演示与 L01，再按需要准备自己的实验数据库。当前源码仍为私有，需先取得仓库权限或维护者提供的明确版本源码；网页可读不代表已经取得实验文件。不要把无法访问源码误诊为 Elixir 安装失败。

项目的 Linux CI 使用 Ubuntu 24.04、Elixir **1.20.4**、Erlang/OTP **28.4** 和 PostgreSQL **18.6**。下文的安装命令依据官方说明和现有 CI 整理；本次文档修订没有在新的 Ubuntu 主机执行这些安装，不把命令写出或已有 CI 通过称为你的新主机已验收。[CI 范围与证据](github-ci.md)保留实际执行身份。

## 1. 取得独立练习副本

先用有系统安装权限的 Ubuntu 账户准备 Git 与下载工具；`sudo` 仅用于系统包。后面的运行时脚本、Mix、实验和 PostgreSQL 都由普通非 root 用户执行：

```sh
sudo apt-get update
sudo apt-get install --no-install-recommends -y git curl ca-certificates unzip
```

有仓库权限时，在自己的工作目录克隆；已有维护者提供的源码副本则进入该副本根目录，不重复克隆：

```sh
git clone https://github.com/zyg0733/agent-systems-engineering.git
cd agent-systems-engineering
git rev-parse HEAD
cat .tool-versions
cat /etc/os-release
uname -m
```

记录实际 commit、Ubuntu 版本与架构；拿到无 Git 历史的包时记录其 manifest 和校验摘要。后续项目命令都在这个根目录执行，安装目录和数据库归该副本所有。不要复用其他课程或共享服务的数据库目录。

## 2. 安装并核对固定 BEAM

Ubuntu 默认仓库中的 Elixir/OTP 不一定是本项目固定版本。按 [Elixir 官方 Ubuntu 安装说明](https://elixir-lang.org/install/#install-scripts)，下载官方脚本，先阅读本地脚本，再显式指定版本：

```sh
mkdir -p .runtime/downloads
curl --fail --location --retry 2 https://elixir-lang.org/install.sh \
  --output .runtime/downloads/elixir-install.sh
cat .runtime/downloads/elixir-install.sh
sh .runtime/downloads/elixir-install.sh elixir@1.20.4 otp@28.4
lab_installs_dir="$HOME/.elixir-install/installs"
export PATH="$lab_installs_dir/elixir/1.20.4-otp-28/bin:$lab_installs_dir/otp/28.4/bin:$PATH"
elixir --version
cat "$lab_installs_dir/otp/28.4/releases/28/OTP_VERSION"
```

应核对 Elixir 为 `1.20.4`、OTP 补丁版本文件为 `28.4`；`Erlang/OTP 28` 的大版本显示本身不足以确认补丁号。官方脚本将运行时装入用户的 `.elixir-install/`；本页 `export PATH` 只影响当前终端，新终端须重设。脚本与下载地址随上游维护，下载失败应保留错误并核对官方来源，不能静默换成另一个版本继续声称相同环境。

项目的 `scripts/bootstrap_runtime.sh` 是 macOS 专用适配，Linux 不运行它。`./scripts/mix` 在没有项目内 macOS 运行时时使用 PATH 中的 Mix，并将项目自己的 Hex/Mix 缓存放进 `.runtime/`。已有可信版本管理器也可以安装同一版本组合，但仍须先核对实际 PATH 与版本，不能只看 `.tool-versions` 文件。

## 3. 先运行无数据库演示

首次取得 Hex 和锁定依赖需要网络。在源码根目录执行：

```sh
MIX_ENV=dev ./scripts/mix local.hex --force
MIX_ENV=dev ./scripts/mix deps.get --check-locked
MIX_ENV=dev LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.demo
```

正常演示的末两行应为：

```text
status=succeeded turns=2 requests=1 effects=1
rebuild_matches=true (in-memory history; no durable storage)
```

这一步使用固定 Provider 和内存 Mock，不需要模型密钥或 PostgreSQL；初次依赖下载与离线实验执行分开记录。接着做 [L01 首次小练习](../labs/L01-state-machine.md#first-exercise)，再使用其[测试文件骨架](../labs/L01-state-machine.md#先准备一个能独立运行的测试文件)运行自己的单文件测试。骨架、演示通过与完整 L01 独立任务分别验收。

需要查看适用内存回归时，再运行：

```sh
MIX_ENV=test LAB_DATABASE_ENABLED=false LAB_SCHEDULER_ENABLED=false ./scripts/mix test
```

Linux 会排除 `seatbelt`，此模式还排除 `database`；记录本次的通过、失败和排除数，不把排除用例计作通过，也不照抄历史 CI 数量。

## 4. 再准备自己的 PostgreSQL

进入 L02 及后续持久化实验前，使用这份新练习副本的专属实例。项目的 [PostgreSQL 构建脚本](../scripts/bootstrap_postgres.sh)在 Linux CI 也用于取得固定原生工具：从 PostgreSQL 官方下载 `18.6` 源码及 SHA256，校验后安装至 `.runtime/postgres/18.6/`。它使用 C 编译器、GNU make、Bison、Flex、Perl、bzip2 和下载工具；需要系统头文件。构建流程与选项可对照 [PostgreSQL 18 源码安装说明](https://www.postgresql.org/docs/18/install-make.html)。

先确认当前副本的 `.runtime/pgdata` 没有被别的实验使用，端口 `55432` 未被占用。下面操作只适用于你自己的新实例；如果已有实例或端口冲突，先检查归属，不按进程名字猜测并停止服务：

```sh
sudo apt-get install --no-install-recommends -y build-essential bison flex perl bzip2
unset DATABASE_URL PGDATABASE PGSERVICE PGSERVICEFILE PGHOSTADDR PGOPTIONS PGPASSWORD
export PGHOST=127.0.0.1
export PGPORT=55432
export PGUSER=postgres
export LAB_DATABASE_ENABLED=true
export LAB_SCHEDULER_ENABLED=false
sh scripts/bootstrap_postgres.sh
./scripts/postgres start
.runtime/postgres/18.6/bin/postgres --version
.runtime/postgres/18.6/bin/pg_dump --version
.runtime/postgres/18.6/bin/pg_restore --version
.runtime/postgres/18.6/bin/psql -d postgres -Atc \
  "SELECT current_setting('data_directory'), current_setting('port'), current_setting('server_version');"
MIX_ENV=dev ./scripts/mix setup
env -u DATABASE_URL MIX_ENV=test LAB_DATABASE_ENABLED=true LAB_SCHEDULER_ENABLED=false ./scripts/mix check
```

确认 SQL 显示当前副本的 PGDATA、所选端口和 `18.6`。项目实例只监听回环地址，使用教学用 trust 认证，不是生产服务配置。首次启动会建立本副本的数据库目录；`PGPORT` 改变不会迁移已经运行的实例，也不能据此跳过连接身份核对。需要其他端口时，在首次启动前选择未占用端口，并在同一终端修改 `PGPORT`。

完整 `check` 使用默认 `agent_systems_lab_test` 库名；开发库为 `agent_systems_lab_dev`。全局 `DATABASE_URL` 可覆盖恢复测试的动态 Repo 目标，因而完整回归必须清除它，改用 `PGHOST/PGPORT/PGUSER/PGPASSWORD` 选择专属实例。不要连接生产或共享数据；恢复测试会创建、修改并删除自己管理的临时数据库。单次 `env -u` 不会修改父终端，本页先执行的 `unset` 和显式环境仍应在新终端重新确认。

各实验完成后，只有确认集群仍属于这份副本、没有其他任务使用时，才在该副本执行 `./scripts/postgres stop`。不要用这个脚本停止另一个副本或未知归属的服务。

## 5. 按 Linux 能力选择实验

| 路线 | Linux 读者可以做什么 | 需要分别记录什么 |
| --- | --- | --- |
| L01 与纯值章节小练习 | 内存状态机、预测、断言、事件重建 | 无需 PG；不代表持久恢复已验 |
| L02—L13 | 在自有 PG 上学习事务、历史、恢复、领取与故障对照；按手册依赖推进 | 命令、原始报告及平台；L10→L11→L12→L13 顺序不变 |
| L14、L15 的真实 OS/stdio 探针 | 阅读机制、策略与反例；现有执行后端依赖 macOS Seatbelt | Linux 不运行成套 Seatbelt/MCP 隔离验收，不改标签绕过限制 |
| L16—L20 的 core 机制 | 读过前置概念后，按对应手册选择 DAG、审批、观测、固定评测与迁移的适用任务 | core 测试通过不补算 L14/L15 的 OS 实操；手册完整验收与选定任务分开 |
| L21—L25 与正式候选 | 按其固定源码、profile 和环境合同另外准备 | 不把 `linux-core` 报告写成 `linux-full` 或正式发行通过 |

主线入口见[阅读路线](../book/reading-route.md)与[课程地图](course-map.md)。第 21、22 章的复制、HA 和多租户是设计推演，不需要为了完成本页在 Linux 上部署不存在的生产功能。

## 6. 遇到错误时先查哪一层

| 现象 | 先检查 | 不要据此做的事 |
| --- | --- | --- |
| clone 返回 404 / 无权限 | 仓库访问权，或维护者提供的版本包是否完整 | 不把权限失败当运行时问题 |
| `mix` / `elixir` 找不到，或版本不符 | 当前终端 PATH、官方安装输出与 OTP 补丁版本文件 | 不以发行版默认包替换固定版本后沿用旧结论 |
| macOS bootstrap 提示不支持平台 | 使用第 2 节 Ubuntu 路线 | 不删除平台检查强行执行 |
| Hex/依赖下载失败 | 网络、证书与原始错误；锁文件是否来自本次源码 | 未取得依赖前不设离线模式，不修改锁文件求通过 |
| 缺 `pg_dump` / `pg_restore` | 项目内 `.runtime/postgres/18.6/bin` 是否构建成功 | 仅有数据库容器或其他版本客户端不足以完成迁移实验 |
| 连接拒绝、端口冲突或库身份不符 | 自有实例状态、PGDATA、PGPORT、PG* 与 URL 是否已清除 | 不停止未知服务，不对错误目标继续迁移或测试 |
| `initdb` 拒绝 root | 返回普通用户，检查本副本目录写权限 | 不用 root 运行实验或修改共享数据权限 |
| `unsupported_backend` / Seatbelt 排除 | 当前任务是否要求 macOS 后端 | 不把跳过、拒绝或纯 capability 声明写成隔离通过 |

保留源码身份、命令、退出码和错误输出后，再查[命令参考](command-reference.md)、[恢复运行手册](recovery-runbook.md)与[跨环境执行说明](cross-environment-validation.md)。这条入门路线支持读者开始适用学习，不取代完整 Linux 隔离、冷安装或正式版本验收。
