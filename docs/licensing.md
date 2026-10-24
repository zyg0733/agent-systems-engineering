# 代码与教材的许可范围

项目采用按内容划分的两种许可证。代码使用 [Apache-2.0](../LICENSE)，教材使用 [CC-BY-4.0](../LICENSE-DOCS)；项目声明见 [NOTICE](../NOTICE)。这不是让使用者为同一份内容任意二选一。各贡献者保留其贡献的版权，已有的作者署名继续保留。

## 适用范围

| 内容 | 许可证 |
| --- | --- |
| 原创软件实现：`lib/`、`priv/` 中的程序和迁移 | Apache-2.0 |
| 原创脚本、测试、配置和固定实验输入：`scripts/`、`test/`、`config/`、`.github/`、`fixtures/` 及根目录的 Mix、运行时和工具配置 | Apache-2.0 |
| 原创教材正文、实验讲解、参考解答文字、课程卡片、ADR、运行手册、README、根研究计划与原创图表；包括 `book/`、`labs/`、`docs/` 中的此类内容 | CC-BY-4.0 |

教材中的原创代码示例、命令与可直接复用的配置示例采用 Apache-2.0；周围的讲解文字和图表采用 CC-BY-4.0。Markdown 代码围栏只是排版形式：用于展示图表、普通文字或第三方摘录的围栏，仍按其内容和来源确定许可。

第三方材料保留原有许可和署名，优先遵守文件内或来源处的单独声明。依赖库、引用的文章、外部图表及上游代码片段不因位于本仓库而被重新许可；本项目的许可只覆盖我们有权许可的内容。Oban 源码研究的版本与来源见[研究清单](research/oban-v2.24.2-manifest.json)和[对照说明](research/oban-scheduling-recovery.md)。

## 复用与署名

复用代码时，遵守 Apache-2.0 的许可证副本、声明保留、修改标注和适用 NOTICE 等条款。完整许可文字以根目录 `LICENSE` 为准。

复用教材时，保留已有作者署名，注明项目或作品名称、来源、CC BY 4.0 许可链接以及所作修改。没有单独作者署名时，可使用项目署名 **Agent Systems Lab contributors**。例如：

> 来源：Agent Systems Lab contributors，《Agent Systems Engineering / Agent Systems Lab》，CC BY 4.0（https://creativecommons.org/licenses/by/4.0/）。修改：说明本次翻译、删节或改编；附所用项目版本与来源地址。

两种许可证均允许商业使用，具体权利和条件以各自完整原文为准。此说明不增加额外限制，也不覆盖第三方权利或商标授权。

## 分发与冻结源码

源码分发同时携带 `LICENSE`、`LICENSE-DOCS`、`NOTICE` 和本页，避免接收者只拿到代码却丢失适用条款。Mix 包的许可元数据列出两种 SPDX 标识；文件范围按上表区分，不表示任一文件同时提供两种替代许可。

当前源码导出清单、Python 环境验证器和入库检查共同覆盖这些材料。新的普通工作区导出要求三份根声明齐全；已经验证的历史冻结源码沿其原固定合同校验和重新导出。W22、W24、W25、W26 的旧包、源码 manifest 和实际验收原件保留原样；不通过修改旧文件来宣称历史归档已经包含本轮新增的许可材料。

许可证文本取自 [Apache 官方原文](https://www.apache.org/licenses/LICENSE-2.0.txt)与 [Creative Commons 官方原文](https://creativecommons.org/licenses/by/4.0/legalcode.txt)，许可标识分别为 `Apache-2.0` 和 `CC-BY-4.0`。
