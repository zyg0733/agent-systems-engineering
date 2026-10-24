# L21：六章试读与干净环境独立复现

对应 W22，前置 L01—L20。原计划本周聚焦试读、实验修订和复现，不增加 Agent 运行时功能。用户已选择先完成试读包与技术验收；3–5 名真实外部读者尚待收集。自动测试、作者技术核验、代理审阅和新 BEAM 不计入真人数。

实验目标是回答：读者拿到的是哪份源码与六章，是否依赖作者旧构建或旧数据库，失败能否定位到具体步骤，以及技术通过为何不等于外部试读通过。先读[六章指南](../book/reader-study/README.md)、[修订记录](../docs/reader-study-revisions.md)、[ADR 0021](../docs/adr/0021-reader-study-and-clean-reproduction.md)及[运行手册第 20 节](../docs/recovery-runbook.md#20-六章试读与干净环境复现)。

## 1. 创建冻结试读包

在原工程执行，无需启动应用或连接 PostgreSQL：

```sh
./scripts/mix lab.reading prepare --output artifacts/L21-reading-unique
./scripts/mix lab.reading report artifacts/L21-reading-unique
```

输出目录必须全新，包含 `project/` 源码与文档、`protocol.json`、无效的空白 `feedback-template.json`、`feedback/`、`START-HERE.md` 和初始 `report.json`。检查初始外部读者数为 0、technical pending、P5 gate false。模板不计作反馈；已有目录不会覆盖。

协议绑定六章与现行实验号：ch02→L01、ch05→L03/L04、ch08→L05、ch14→L06/L20、ch16→L07/L08、ch20→L11/L13。原计划编号与实际连续交付编号不同，不根据章节号推算实验号。完整导出 manifest 保存每个源码文件的 SHA-256、大小和 mode；assets 再绑定章稿、实验、指南和手册。协议修改后重算 hash 不能绕过冻结套件绑定。

## 2. 导出独立源码目录

在原工程准备一个自己拥有的短路径父目录，例如 `/private/tmp/asl-w22-example`；不要使用已有项目或含符号链接的目标。macOS 的 Unix socket 路径长度有限，示例使用短路径减少初始化故障。

```sh
mkdir -p /private/tmp/asl-w22-example
./scripts/mix lab.reproduce export --output /private/tmp/asl-w22-example/project
./scripts/mix lab.reproduce verify --output /private/tmp/asl-w22-example/project
./scripts/mix lab.reproduce plan --output /private/tmp/asl-w22-example/project --port 55439
```

这三个命令只准备和检查数据，不运行 plan 中的命令，不安装运行时，不起停数据库。选择空闲端口；若被占用换端口，不能停掉占用者。导出排除 `.git/.runtime/deps/_build/artifacts/cover`，只复制固定源码与文档入口；未知构建历史不能混进导出身份。符号/硬链接、大小写别名造成的源树内目标、旧目录、超限或源漂移均应拒绝，而且拒绝不能在源目录中产生副本。

## 3. 明确声明缓存来源

若使用同一可信宿主已经下载的固定安装缓存：

```sh
./scripts/mix lab.reproduce cache --output /private/tmp/asl-w22-example/project
```

它只复制固定 OTP/Elixir archive、PostgreSQL source+SHA 文件、Hex/Rebar3 构建工具 archive 与六个锁定依赖包和 registry cache，不复制已安装 runtime、deps、BEAM build、PGDATA 或业务行。检查 `.runtime/cache-provenance.json` 的实际文件 hash、模式、总量及 scope。缓存manifest描述执行前输入。Hex使用后可能重写registry的cache.ets，应保留初始registry快照与使用后hash；其他安装archive、包与工具保持原hash。SHA 是完整性校验，不认证缓存来源；这不是新主机、冷网络下载或未知发行包认证。

在导出目录安装缓存，并从已校验 PostgreSQL 源码构建全新 prefix。以下只针对项目已验证的 macOS arm64 缓存；其他平台须另行提供对应运行时并记录差异。

```sh
cd /private/tmp/asl-w22-example/project
mkdir -p .runtime/otp/28.4 .runtime/elixir/1.20.4-otp-28 .runtime/sources
tar xzf .runtime/downloads/otp-aarch64-apple-darwin.tar.gz -C .runtime/otp/28.4
unzip -q .runtime/downloads/elixir-1.20.4-otp-28.zip -d .runtime/elixir/1.20.4-otp-28
(cd .runtime/downloads && shasum -a 256 -c postgresql-18.6.tar.bz2.sha256)
tar xjf .runtime/downloads/postgresql-18.6.tar.bz2 -C .runtime/sources
```

接着在 `.runtime/sources/postgresql-18.6` 中执行 `./configure --prefix=绝对导出路径/.runtime/postgres/18.6 --without-icu --without-readline --without-zlib`，再 `make -j4` 和 `make install`。保存三步的退出码和日志；不能把原工程 postgres 可执行文件拷来却声称重新编译。安装/源码来自明确可信宿主缓存，实验不运行读者反馈中的命令文本。

## 4. 隔离环境后再执行

先按 plan 的 `environment` 建立子进程环境：unset `DATABASE_URL`、`MIX_BUILD_PATH/MIX_EXS/ERL_LIBS` 等继承项；显式设置 `PGHOST=127.0.0.1`、新 `PGPORT`、`PGUSER=postgres`、空密码、unset PGOPTIONS/PGSERVICE/PGSERVICEFILE/PGHOSTADDR/PGDATABASE、`PGPASSFILE=/dev/null`，`MIX_ENV=test`、`HEX_OFFLINE=1`、`LAB_DATABASE_ENABLED=true`、`LAB_SCHEDULER_ENABLED=false`。Mix/Hex、deps 和 build 路径必须指向本次导出。JSON null 表示 unset，不能把字符串 `"null"` 传给环境变量。

确认 `.runtime/pgdata`、`deps`、`_build` 尚不存在，先记录空目录证据。然后在该导出目录执行 plan 固定步骤：

```sh
./scripts/postgres start
./scripts/mix deps.get --only test
./scripts/mix check
LAB_DATABASE_ENABLED=false ./scripts/mix test
./scripts/mix lab.verify
./scripts/mix lab.p1 --output artifacts/reproduction-p1
./scripts/mix lab.history --output artifacts/reproduction-history
./scripts/mix lab.recover --output artifacts/reproduction-recovery --repetitions 1
./scripts/mix lab.fence --output artifacts/reproduction-fence --repetitions 1
./scripts/mix lab.upgrade --output artifacts/reproduction-upgrade
```

这些是固定可信源码的宿主验收命令。每步记录 cwd、环境差异（不得输出凭据）、启动/结束、退出码、日志 hash 与报告。记录新 PGDATA 的 cluster identity，`SHOW data_directory/port/fsync/synchronous_commit/full_page_writes`，以及迁移前空库与之后 21 个迁移。不从原工程复制数据库或工作区来“帮助成功”。

`lab.upgrade` 生成并精确清理自己的四个 DB；它的备份仍只含数据库，原授权工作区保留。P1/history/recover/fence 另有各自真正断言；不能用全量测试通过代替逐实验检查。不要为某个失败重新设置预算、deadline、权限或绕过 unknown/approval；先定位并保留失败日志。

## 5. 核对同一性并只清理自己拥有的进程

完成后再次 verify 源 manifest，确保运行未改源码/模式；新增 runtime/deps/build/artifacts 不算源码漂移。记录源码、缓存、实际日志和报告的 hash，以及编译与迁移从零运行的证据。

只有确认当前目录和 PGDATA 是本轮新创建的独立集群，才在**该导出目录**执行 `./scripts/postgres stop`。保存成功停止和监听端口释放证据；不要在原工作区运行 stop，也不要根据端口前缀或 PID 猜测清理对象。留存正式日志、manifest 和产物，不把清理成功扩展为删除工作区或生产灾备承诺。

本实验的“干净环境”指同宿主、源代码导出、声明的安装缓存、新 runtime prefix/依赖编译与新 PostgreSQL 集群；不声称已经验证另一台机器、另一 OS、冷网络安装或真实模型。

## 6. 收集真实反馈和分开判定 gate

按照[指南](../book/reader-study/README.md)填写并交给可信宿主。不要运行示例代码生成三份合成反馈来充人数。单份 JSON 最多 256 KiB，最多 5 人；汇总报告独立允许 2 MiB。记录只能包含固定字段、完整六章、有效 UTC 时间与实际复现结果；未知字段、过时协议、代理/作者/空模板或整体 passed 却缺少命令都拒绝。

```sh
./scripts/mix lab.reading add artifacts/L21-reading-unique --feedback /absolute/real-feedback.json
./scripts/mix lab.reading report artifacts/L21-reading-unique
```

技术证据通过 `report --technical FILE` 另外提供。技术 flags 绑定已实际执行的日志 manifest digest；它们是宿主提交的声明，不是让外部 bool 产生执行证明。技术通过不能替代 3–5 人阅读、至少一次外部 fresh-workspace 主实验自报、零未解决 blocker。当前没有真人记录时，正确结论是 technical passed、external pending、P5 gate false。

## 7. 交付

提交六章修订与卡点汇总、原始/重试日志、真实干净复现证据、试读协议与初始 0 人状态、对应测试和运行手册。比较原权限、预算、absolute deadline、工具回执、unknown、审批 subject 与 fencing；本周工具不得修改运行时模块、既有 SQL migration 或依赖版本。实际验收数量见[第 22 周记录](../docs/validation-week22.md)，参考判断见[解答](solutions/L21.md)。
