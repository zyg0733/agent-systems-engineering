# L25：冷主机、Linux 适用测试与环境证据

对应 W26，前置 [L21](L21-reader-study-and-clean-reproduction.md)、[L23](L23-frozen-candidate-release.md)和 [L24](L24-versioned-release-assessment.md)。目标是把跨环境验证变成受控执行和可核对的证据，而非把安装计划、排除测试或自报 JSON 算作平台通过。先读[操作手册](../docs/cross-environment-validation.md)、[ADR 0025](../docs/adr/0025-cross-environment-validation.md)及[已知限制](../docs/known-limitations.md)。

## 1. 固定身份与实际环境

保留原 rc.1/归档、W22 与 W25 试读包的文件集合、bytes/mode 和 hash。选择已通过 Reproduction 校验的纯源码导出；可信 W26 控制工具、被测 source、候选、试读协议、环境执行、采集 bundle 分别记录身份。不能给旧 `project/` 加新 CLI 后继续声称仍是原源码。

按手册设置绝对的 `tool_root/frozen_source/candidate_output/execution_output/bundle_output`。原 rc.1 对应 W24 的 502 个源文件；当前 W26 的新源码单独导出，不能绑定旧候选。列明实际主机/平台、工具版本、缓存、输入来源与新数据库计划；没有真实机器就列 pending。

## 2. 计划与本机执行

先只读检查：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment plan --source "$frozen_source" --candidate "$candidate_output" --profile macos-warm
python3 "$tool_root/scripts/environment_validate.py" plan --source "$frozen_source" --candidate "$candidate_output" --profile macos-warm --output "$execution_output" --operator-id operator-local --host-id host-local --cache-from "$tool_root" --port 55591
```

核对固定 argv，无安装、数据库或业务启动。确认输出全新、端口空闲、缓存来源可信后，将第二条的 `plan` 改为 `run`，保存所有步骤退出码和原始日志。不要并行运行重故障演练。执行前后校验 source 声明文件，不能把 build 或结果变化误记成源文件通过。

证明使用新源码副本、依赖编译、新 PGDATA 与实验库，记录三项 durability 和 SQL/PID/端口身份。异常后仍只清理本轮确切资源，确认停止和端口释放；原共享 55432 与旧开发库保持。用临时合成输入验证输出存在、端口被占用、未知 profile、平台错配或身份不符的拒绝，不破坏真实包演示失败。

## 3. 真冷安装与 Linux 适用流程

在实际新 macOS 主机，选择 `macos-cold`、`--new-host`，不传 warm cache；重新取得固定安装输入并保留来源与摘要。新目录、新 runtime prefix 或新 PGDATA 不能单独证明新主机。自报、版本 URL 和 SHA 各自能证明什么，不能证明什么，应逐项解释。

在真实 Linux 环境选择 `linux-core`，预装固定版本工具链，执行同源码适用回归和固定主实验。保存通过数、`:seatbelt` 等排除数、隔离明确拒绝/未执行范围。当前源码修正了测试的临时目录平台假设，但旧 rc.1 未改，旧源码的实际失败不能隐藏。

完整 Linux gate 继续要求无平台排除、全部隔离探针与 12×20 矩阵，没有 `linux-full` profile。不能将 macOS 日志改 platform，也不能把核心通过或 CI 配置存在当作完整 Linux 隔离通过。未取得真实新主机/Linux 时，本实验提交可执行流程与本机事实，对应外部门槛继续 pending。

## 4. 采集与交叉核验

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment collect --source "$frozen_source" --candidate "$candidate_output" --execution "$execution_output" --output "$bundle_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.environment verify --source "$frozen_source" --candidate "$candidate_output" --bundle "$bundle_output"
```

核对 collector 只处理文件，不执行记录中的 argv、启动业务或访问 PG。源码/candidate/日志/result 引用必须互相绑定；在临时副本构造错 schema、错源码、hash 漂移、缺文件、路径逃逸、链接、过大日志和重复输出，要求明确拒绝。合成正向环境只用于测试，不能放进真实外部证据目录。

符合发行 v1 合同的同源码 bundle 再交给 `lab.release.assess --candidate ... --evidence ...`；可加同源码 `--study`。比较采集成功、记录的执行结果、平台完整性和各个发行 gate，解释合法 pending 为何可退出 0。材料缺失与材料损坏分别处理，不填默认 true。

## 5. 提交与验收

提交冻结工具源码、执行与来源记录、原始日志、采集/verify/assessment 输出、失败现场、精确 cleanup 和旧产物/开发库前后保护。运行全部现有完整测试和内存回归，按实际数量登记，不抄历史结果。新测试应覆盖有界、错绑定、失败/中断与纯文件边界；不为通过 Linux 而放宽旧隔离断言。

业务权限、已用预算、原绝对 deadline、operation ID、unknown/reconcile、审批产物 hash、lease/heartbeat/fencing 保持。真实读者 0、冷主机/Linux 未取得时继续待验收，正式发行保持关闭。参考[判断](solutions/L25.md)、[运行手册第 24 节](../docs/recovery-runbook.md#24-跨环境执行证据与独占资源清理)与 [W26 实测](../docs/validation-week26.md)；执行后补录只写工作区的派生验收文档，不回填冻结副本。
