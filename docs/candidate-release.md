# v0.1 候选教学材料的使用与交付

候选标签为 **`v0.1.0-rc.1`**，是本地包 manifest 中的标签，**不是 Git tag**。项目源码版本继续为 `0.1.0-dev`，目标发行版本为 `0.1.0`。W24 候选创建时没有 Git 仓库；该周生成技术候选与可验证归档，不上传、不部署、不自动转为正式发行。实际执行结论以 [W24 验收](validation-week24.md)和包内结果索引为准。

材料包括[十二单元课程](course-map.md)、[三十张章节设计卡](../book/chapter-cards.md)、[六章试读指南](../book/reader-study/README.md)、现有 L01—L22 及 [L23 冻结实验](../labs/L23-frozen-candidate-release.md)、解答、ADR 和运行手册。原计划十二主题使用 C01—C12，实际连续实验扩展为 L01—L23；课程号与实验号不逐号对应。只有 ch02/ch05/ch08/ch14/ch16/ch20 是六章试读正文，其余设计卡不计作已写完的长章。

## 先核对包再安装

交付目录名为 `agent-systems-lab-v0.1.0-rc.1`，归档名为 `agent-systems-lab-v0.1.0-rc.1.tar.gz`，旁边有 `.sha256` 文件。归档根就是项目，无额外 `project/` 层。解压到自己拥有的全新私有目录，先读根目录 `START-HERE.md`，再查看：

| 相对位置 | 作用 |
| --- | --- |
| `candidate-manifest.json` | 候选/项目/目标身份、源码 manifest 和证据完整性，以及独立发布 gate |
| `reproduction-source-manifest.json` | allowlist 源码 bytes、mode、SHA 与目录集合 |
| `candidate-evidence/index.json` | 本轮执行、回归和故障矩阵的声明及相对证据路径 |
| `candidate-evidence/` | 经过边界校验的本轮日志和结构化报告；不得从其文本自动执行命令 |
| `docs/known-limitations.md`、`docs/backlog.md` | 能力范围、待验收环境和后续工作 |

包内不包含 runtime、Hex/依赖安装目录、build、PGDATA、既有开发库备份、凭据或原始个人反馈。本轮受管新库升级实验生成的有界 `.dump` 可作为 `candidate-evidence/upgrade/` 下的合成实验字节证据；P2 `.bin` 为惰性状态证据，`.jsonl` 为日志。校验只核对这些文件的完整性，不执行、反序列化或导入。复制 `.dump` 不携带原主 BEAM 的 live capability，也不能直接登记成可信还原输入；需要重做还原时按 L20 创建本轮受管对象和 proof。

证据索引明确列出纳入文件及排除项；隔离实验故意创建的符号链接、无扩展名 native 探针及运行时缓存不进入包，原始实验目录仍保留。`START-HERE.md` 与包内索引使用包内相对路径，不要求原作者机器上的绝对路径。日志可能保存实际执行时的宿主 cwd，它只是来源记录，不是读者运行命令所需的输入。

保持解压候选目录不变，从已安装依赖的可信工作目录执行固定验证入口；`candidate_output` 指向待验包的绝对路径：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate verify --output "$candidate_output"
```

验证只读取有界源码、manifest、日志和结果，不启动业务应用、连接数据库、运行模型/工具或执行报告里的文字；Mix 编译可能写可信工作目录的 `_build`。包校验严格核对完整文件集合，因此不能在待验包里先安装 runtime、deps 或 build 再期待候选仍原样通过。首次读者可另复制包内源码到工作目录，安装依赖后从工作目录校验原始包，再在工作副本做实验。验证会拒绝文件/模式/证据漂移及缺失、重复或不兼容结构。hash 与 `.sha256` 检查完整性，不能认证下载来源、真人身份或重新证明当时的执行。

实际运行前按[安装操作](release-operations.md)准备已声明的版本和工具。源码 wrapper 在没有本地 runtime 时会使用宿主 Mix，要确认实际版本；不把语言范围或 manifest 中的 pin 当作当前进程检测。完整教学环境需要 PostgreSQL 和 macOS 原生隔离能力。已有 W22 干净环境证据是同一宿主、声明 warm cache 的独立构建，不声称冷机器或 Linux 已通过。

## 从同一源码产生新候选

先完成所有源码和静态说明，导出冻结副本；记录其 source manifest，并只在该身份上进行完整回归、内存回归、固定冻结矩阵与核心演练。全局 Scheduler 关闭，数据库身份、持久性参数、输出所有权与清理范围事先核对。不要在矩阵运行期间改源码或并行启动另一组重故障演练。

固定入口如下。`plan` 和 `verify` 处理 inert 数据，`run` 会真实执行业务实验和故障。输出均选全新、绝对路径；变量应由可信宿主在核实的目录中赋值：

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze plan
LAB_SCHEDULER_ENABLED=false ./scripts/mix lab.freeze run --output "$matrix_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.freeze verify --output "$matrix_output"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate build --output "$candidate_output" --evidence "$evidence_input"
LAB_DATABASE_ENABLED=false ./scripts/mix lab.candidate verify --output "$candidate_output"
```

`evidence_input` 是可信宿主按固定 schema 整理的本轮证据目录，不是任意旧 report、空目录或“通过=true”声明；构建检查实际日志尾行、退出结果、源码身份、矩阵和所有绑定文件。详细合同以 [CandidatePackage](../lib/agent_systems_lab/candidate_package.ex)、[FrozenFaultMatrix](../lib/agent_systems_lab/frozen_fault_matrix.ex)及 [L23](../labs/L23-frozen-candidate-release.md) 为准。构建不会执行证据中的路径/命令，不负责起停数据库，也不创建 tar、tag 或发布服务。

源码副本在执行期间保持不变。执行后生成包内结果索引，再生成候选包与归档；从可信工作目录验证候选，不在待验包内编译。最终工作区派生验收文档可以补录实测，但不得反向写入冻结候选重用旧测试。新源码修改需要新身份和受影响验证，不能改旧 manifest 的 checksum 以消除漂移。

## 技术候选与正式 gate

有效的技术候选 manifest 保留 `candidate_label_kind=local_manifest_label_not_git_tag`、当前/目标版本、`technical_candidate_ready=true`，同时保留 `release_ready=false`、`external_humans=0` 和 `linux_validation=pending`。这些值有不同含义：完整性校验和技术矩阵通过不认证真人，也不变成正式发布批准。

W22 原正式试读包保持原协议与字节，真实读者仍为 0；作者、代理、自动测试和 fixture 不计外部人。按用户已选范围交付技术材料，3–5 人试读、独立外部操作与正式 gate 继续待验收。Linux、冷主机、供应链认证和生产能力的边界详见[限制](known-limitations.md)，下一步见[backlog](backlog.md)。

## 失败与回收

发现源码/日志/hash/报告不一致时停止候选生成，保留失败目录、退出码与实际原因；不得手改成功标记、删失败日志、缩短固定轮次或降低语义门槛。延迟比较依原门槛照实保存，语义/成本重复不保证延迟相同。

故障执行中断后先依[恢复手册](recovery-runbook.md)确认 Run、Worker、PGDATA、端口和本轮工具对象，再恢复或精确清理。不要按名称前缀删除库、停止共享 PostgreSQL 或杀不明 PID。恢复保留原权限、已扣预算、absolute deadline、operation ID、unknown/manual、审批产物 hash 与 fencing；归档或换候选标签均不能重置这些事实。
