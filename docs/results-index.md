# 结果索引与证据读取

本页是冻结候选中的静态导航，不预填本轮通过数。实际 W24 结果由包内 `candidate-evidence/index.json`、冻结矩阵 `report.json`、原始日志和候选 manifest 绑定；原工作区最终派生结论见 [W24 验收](validation-week24.md)。未生成的文件、历史证据、计划中的命令都不能算已执行。

## 本轮包内入口

从候选包根目录读取下列相对路径。先核对 `candidate-manifest.json` 与 source manifest，再用 `lab.candidate verify` 复核所有已声明文件；入口与限制见[候选说明](candidate-release.md)。

| 证据 | 阅读时需要核对的事实 |
| --- | --- |
| `reproduction-source-manifest.json` | 实际执行的源码身份、文件 bytes/mode/SHA；不是执行后重新拼出的近似副本 |
| `candidate-evidence/index.json` | schema、完整执行、源码绑定、完整/内存回归和矩阵的相对路径及 hash；缺失 gate 不补默认为通过 |
| 完整回归日志 | 成功退出、真实 ExUnit tests/doctests 数、0 失败、原 fixture 与 COMMIT 窗口验收；不照抄上周数量 |
| 内存回归日志 | 实际 passed 与数据库 excluded 分开；排除不计通过，数据库用例应在完整回归执行 |
| `matrix/report.json` | F01—F12 顺序与每类 20 个实际 observation；12 类合计 240 个 observation；复合探针另报，不能拿子探针数冒充各类轮数 |
| 矩阵子报告和逐轮证据 | 源码、原身份、故障到达、真实 kill/暂停/断连、结果与 effect/receipt/旧 claim 断言；非终态须继续或进入可见核对 |
| 核心演练报告 | 由索引声明实际相对路径；区分 P1、history、调度/负载、隔离、MCP、DAG、审批、观测、评测和升级的范围与平台 |
| 合成实验字节与排除清单 | 本轮受管升级库 `.dump`、P2 `.bin`、`.jsonl` 只作完整性证据，不执行或导入；原 BEAM capability 不随 archive 复制。故意的隔离符号链接、无扩展名 native 探针与缓存明确排除，原目录保留 |
| 包验证输出及归档 checksum | 核对本轮包，不等于运行所有实验；归档 SHA 检测传输完整性，不认证发布者 |

包根是项目结构；保留一份未改候选供校验，另建工作副本安装和执行实验。校验从已安装依赖的可信工作目录指向原始包，避免在待验包里生成未声明 `_build`。不把日志中的旧绝对 cwd 当成当前命令参数。固定 plan 的 argv 仅供核对，读者反馈、报告内容和自由文本一律不执行。结果导出失败不能改变原业务事实；矩阵或构建失败保留其实际状态，不把部分完成涂成成功。

## 原工作区的本轮位置

可信宿主约定最终证据目录 `artifacts/week24-acceptance-final/`，包含 `execution.json`、`full_check.log`、`memory_check.log`、`index.json`、`matrix/report.json` 与实际生成的子报告。`artifacts/week24-acceptance/` 保留首次失败执行及原始日志，不计入最终通过数量；演示观察竞态的修复需绑定新冻结源码与实际重跑，不能修改原失败报告。候选目录为 `artifacts/agent-systems-lab-v0.1.0-rc.1/`，同级保存 `.tar.gz` 和 `.tar.gz.sha256`。这些路径是工作区交付约定；冻结本页不会因文件尚未生成就把它们标成通过，最终实际生成集合由执行索引和验收记录说明。

工作区最终验收文档在执行后补录；冻结候选内该文档的副本可以仍是执行前说明。不可为了让包里出现后来数字而改动原源码 manifest。包内机器索引是本轮证据入口，不依赖工作区中后补的说明文档。

## 历史结果及其范围

以下材料保留各自周次、源码和实际重复次数，只作为历史证据，不累计成本周冻结次数：

| 历史入口 | 可支持的结论 |
| --- | --- |
| [P1 / W6](validation-week06.md) | Session/Context 与离线任务闭环；当时源码下的压缩、取消和持久窗口 |
| [P2 故障报告](p2-fault-report.md)、[W10](validation-week10.md) | 外部效果成功后崩溃、恢复中再次崩溃、结果录制与 unknown；保留各窗口实际次数 |
| [P3 报告](p3-report.md)、[W14](validation-week14.md) | 当时调度、租约/信号、负载与数据库连接故障；旧 2 轮不是本周 20 轮 |
| [W18](validation-week18.md)、[W19](validation-week19.md) | 审批/返工、观测等价与有界缓冲；以具体报告为准 |
| [W20](validation-week20.md)、[L19](../labs/L19-repeatable-evaluation.md) | Scripted 固定 dev/holdout、独立 scorer、合成成本与真实延迟；不是实际模型能力/美元账单 |
| [W21](validation-week21.md)、[L20](../labs/L20-history-migration-backup-restore.md) | 历史迁移、版本拒绝、默认只读还原和精确清理；不包含通用生产灾备 |
| [W22](validation-week22.md)、[L21](../labs/L21-reader-study-and-clean-reproduction.md) | 六章修订、原冻结试读包、同宿主 warm-cache 独立构建；0 名真实读者，非新主机冷构建 |
| [W23](validation-week23.md)、[L22](../labs/L22-release-readiness.md) | 源码准备、版本合同、12 课程和 30 设计卡；不替代本周执行 |

所有记录都受[已知限制](known-limitations.md)约束。当前项目版本 `0.1.0-dev`、候选 label `v0.1.0-rc.1`、目标 `0.1.0`、业务 schema、Codec、history layout 和各报告 schema 是不同版本域。真实读者数量及正式发行 gate 必须单独读取，不能由测试通过数推断。
