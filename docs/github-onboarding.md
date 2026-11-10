# GitHub 首次入库与交接

项目最初接入私有仓库 [zyg0733/agent-systems-engineering](https://github.com/zyg0733/agent-systems-engineering)，默认分支为 `main`，首次提交 [`a45fe75`](https://github.com/zyg0733/agent-systems-engineering/commit/a45fe750118f4f180bb36c9847edbe9f75e89e68)已推送。2026-11-11 起按开源教程草稿开放，当前取得方式见[材料获取](material-access.md)，以下保留首次入库记录。项目版本保持 `0.1.0-dev`。项目所有者已确定原创代码采用 Apache-2.0、教材采用 CC BY 4.0，具体边界见[许可范围说明](licensing.md)。本文不替代正式发行评估。

## 已核对的起点

[W26 验收记录](validation-week26.md)对应冻结源码的完整回归 1093 项、内存回归 628 项（另排除 465 项数据库测试）及 Python 执行器 36 项通过。本轮重新读取并逐文件核对了 W26 索引中的 1384 份普通证据文件、受控符号链接身份、源码 manifest、11 条命令退出码和资源清理记录；这是既有证据复核，不是重新执行 W26 全量实验。

本轮 README、CI、忽略规则和交接文档的修改属于新的工作区修订。W26 的通过数量只描述原冻结源码；本轮适用验证结果另行记录，原冻结目录、候选包、失败日志和验收记录保留。

## 首次提交的内容

| 内容 | 处理方式 |
| --- | --- |
| `lib/`、`config/`、`priv/`、`test/` | 提交实现、配置、迁移和测试 |
| `book/`、`labs/`、`docs/`、原研究计划 | 提交教材、实验、解答和范围说明 |
| `fixtures/`、`mix.exs`、`mix.lock`、`.tool-versions` | 提交小型固定输入、依赖锁和版本约束 |
| `scripts/`、`.github/`、格式与忽略配置、README | 提交安装、运行、检查和 CI 入口 |
| `LICENSE`、`LICENSE-DOCS`、`NOTICE`、`docs/licensing.md` | 提交代码与教材许可全文、项目声明和适用范围 |
| `.runtime/`、`deps/`、`_build/`、`cover/` | 忽略本地安装、数据库、缓存和构建结果 |
| `artifacts/` | 忽略原始执行材料和大型候选包；保留作者工作区原件 |
| 本地环境变量文件、凭据、编辑器缓存 | 按忽略规则排除，并检查暂存区 |

历史文档中的本地证据位置见[证据阅读说明](evidence-guide.md)。克隆源码后先按 [README](../README.md)安装和运行；不要将缺少作者本地 `artifacts/` 理解为安装失败。

## 本地检查与审阅

在项目根目录运行：

```sh
python3 scripts/repository_check.py
./scripts/mix format --check-formatted
LAB_DATABASE_ENABLED=false ./scripts/mix lab.release check
python3 -m unittest discover -s scripts/tests -p '*_test.py'
```

入库检查只报告路径和规则，不打印疑似凭据内容。它是文件范围和常见风险检查，不能证明所有秘密均已发现。Python 执行器测试会创建临时子进程和本地套接字，按测试自身规则清理；不会下载工具链或调用真实模型。

本地 Git 仓库建立后，审阅实际暂存内容：

```sh
git status --short
git diff --cached --check
git diff --cached --stat
git diff --cached
git ls-files
```

确认源码、文档与锁文件完整，忽略目录和本地凭据未进入暂存区。检查脚本扫描工作区内容和索引路径；暂存后还要核对实际 diff，避免工作区与暂存内容不同。`fixtures/.gitattributes` 为规范化练习输入保留故意的尾随空格，检查时不要自动格式化这份固定输入。根 `.gitattributes` 仅放行官方 CC 许可文本原有的结尾空行，保持许可证原文字节不变。许可文件与范围说明应随源码导出、首次提交和后续分发一起保留；教材中的原创代码示例使用 Apache-2.0，第三方材料继续遵循原许可。首次提交使用项目所有者确认的 Git 身份。

## 接入记录与后续验证

1. 已在 `zyg0733` 下创建 `agent-systems-engineering` 私有仓库；许可文件与范围说明随源码提交保留。
2. 首次提交为 `a45fe750118f4f180bb36c9847edbe9f75e89e68`，已推送至 `main`；后续修订分别记录提交与验证结果。
3. 查看 [CI 范围与日志](github-ci.md)，保留真实成功或失败、版本和平台排除。工作流文件存在和本地语法通过都不计远程执行成功。
4. Linux 核心适用测试通过后仍保留完整 Linux 隔离门槛。新 macOS 主机按[跨环境操作手册](cross-environment-validation.md)另行冷安装。
5. 用[冻结试读流程](release-assessment.md)安排 3—5 位真实独立读者，覆盖六章，至少一人完成新工作区主实验；修复与原读者复验追加记录。

远程 CI、冷主机与真人结果分别绑定实际执行的源码，不直接沿用 W26 数量。材料齐备后再重新生成同源码候选、运行发行评估并记录所有者的发行决定。GitHub 源码托管、Git tag 和正式 `0.1.0` 发布分别记录。
