# GitHub 首次推送与 CI 验证

工作流为 [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)，由 `push` 和 `pull_request` 触发，不需要模型 API key 或仓库 Secrets。课程使用固定脚本与本地 fixture；安装 Action、BEAM、系统构建前置、PostgreSQL 和锁定依赖仍需联网。取得依赖后，Mix 检查设置 `HEX_OFFLINE=1`，避免在测试阶段重新解析远端包；这不是宿主网络隔离承诺。

## 检查范围

| Job | 执行内容 | 明确排除与限制 |
| --- | --- | --- |
| Python environment runner | `repository_check.py --json` 源码入库检查；Python 标准库执行器专项，当前为 36 项 | 两项分别保留结果，源码检查失败仍运行执行器专项；不启动真实 BEAM/PostgreSQL，不能代替跨主机执行 |
| Linux core (Seatbelt excluded) | Ubuntu 24.04；OTP 28.4、Elixir 1.20.4、PostgreSQL 18.6；source readiness、`mix check`、内存 `mix test` | `test/test_helper.exs` 在 Linux 排除 `seatbelt`；内存模式另排除 `database`；排除数以实际 ExUnit 日志为准 |

数据库服务使用全新 runner 的 `postgres:18.6` 容器。备份/恢复源码固定调用 `.runtime/postgres/18.6/bin/pg_dump` 与 `pg_restore`，因此 CI 另外复用已有 `bootstrap_postgres.sh` 从官方校验和验证过的源码编译原生工具，避免误用 Ubuntu 默认客户端或仅安装容器服务却缺少本地工具。源码安装步骤只准备项目内工具，不启动第二个数据库。Scheduler 保持关闭。

工作流全局设置 `PYTHONDONTWRITEBYTECODE=1`，避免 Python 解释器缓存随后进入递归导出的源码；源码入库检查作为持续门禁，非零退出码会使 job 失败。

工作流仅申请 `contents: read`，checkout 不持久保存凭据。沿用 `actions/checkout@v4`、`erlef/setup-beam@v1`，日志上传使用 `actions/upload-artifact@v4`；Action 版本标签、服务镜像标签和随下载取得的校验和不构成不可变供应链或发布者认证。相关配置可参见 [setup-beam 官方输入](https://github.com/erlef/setup-beam/blob/v1/action.yml)、[checkout 官方输入](https://github.com/actions/checkout/blob/v4/action.yml)和 [upload-artifact 官方输入](https://github.com/actions/upload-artifact/blob/v4/action.yml)。

## 首次推送后如何判断

1. 在 GitHub Actions 找到本次提交的 `Lab checks`。确认两个 job 的实际状态；失败和 skipped 都不能登记为通过。
2. 下载本轮 `python-runner-<run_id>-<attempt>` 与 `linux-core-<run_id>-<attempt>`。正常完成、失败时均尝试上传，保留 14 天；runner 被强制终止、服务初始化失败或上传失败时仍可能没有完整 artifact，应保留 GitHub 自身日志。
3. Python 包先查看 `source-check.json`、`source-check.log` 和 `source-check.exit` 的源码检查结果，再查看专项实际用例总数和 `tests.exit`；两个检查的失败都保留。Linux 包查看 `environment.log` 的实际 checkout commit、主机信息、安装与依赖日志、`source-readiness.log`、`full.log`、`memory.log`、对应 `.exit` 和 `step-outcomes.json`。内存回归在数据库回归失败后仍可运行，两个结果分别记录，整体失败状态不被覆盖。
4. 使用原始 ExUnit 汇总记录通过数、失败数和排除数，保留失败现场。PostgreSQL 编译日志、服务日志及实际镜像 ID 一并保留；不得用本机 W26 通过数填入 Linux 实测记录。
5. 在 artifact 到期前把所需证据保存到正式验收位置，并绑定提交/源码。源码改变后重新冻结、执行适用验证；原 W26 冻结源码、旧候选和原始失败记录保持原身份。

这份工作流的绿色结果只证明实际执行的 Linux 核心适用检查。它没有运行 W26 的完整 frozen-source 环境执行器，不直接生成 `EnvironmentValidation` 或发行准入 bundle；需要该证据时，按[跨环境手册](cross-environment-validation.md)在真实 Linux 环境执行 `linux-core` profile 并采集。它也不提供完整 Linux 隔离后端、18 项隔离探针和 12×20 矩阵，不解除原 `linux_full` 发行 gate；冷 macOS 与真人试读继续独立验收。

当前文档描述待首次推送执行的配置，没有声称已取得 GitHub/Linux 运行结果。CI 文件属于 `fixtures/release/manifest.json` 的固定源码清单，修改时只更新当前工作区相应条目的 SHA256、字节数和模式，运行 source readiness；历史冻结包不回写。
