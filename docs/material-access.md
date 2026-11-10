# 材料获取、源码与反馈

本书以开源教程草稿提供 30 章正文、25 份实验手册和教师参考。可以直接[在线阅读](https://zyg0733.github.io/agent-systems-engineering/)，也可以克隆[公开仓库](https://github.com/zyg0733/agent-systems-engineering)在本地阅读、修改和运行实验。浏览与克隆无需登录 GitHub 或申请邀请。

## 取得教材与完整源码

```sh
git clone https://github.com/zyg0733/agent-systems-engineering.git
cd agent-systems-engineering
```

从[项目 README](../README.md)进入运行环境准备；只阅读可直接从[完整阅读路线](../book/reading-route.md)开始。后续修订以所检出的 commit 为准，可用 `git rev-parse HEAD` 记录版本。实验在自己的副本和专用资源中执行，输出使用新目录。

| 你想做什么 | 所需材料 | 现在怎么继续 |
| --- | --- | --- |
| 阅读概念、看图、预测和比较参考推理 | 在线阅读站或克隆后的 Markdown；不需要模型账号或本地运行时 | 从[第 1 章](../book/ch01-from-llm-apps-to-agent-systems-engineering.md)与[阅读路线](../book/reading-route.md)开始 |
| 运行实验、修改实现或执行测试 | 克隆后的源码及 fixture、固定工具链、自己的实验资源 | 按 README 安装；Linux 用[core 入门路线](linux-core-start.md) |
| 打开正文的源码、测试或配置引用 | 公开 GitHub 文件页或本地克隆 | 在当前版本中查找相同路径；无需仓库邀请 |
| 构建自己的阅读站 | 完整 Git 克隆及 Node.js 24 | 按[阅读站维护说明](reading-site.md)操作 |
| 复核作者历史原始结果 | 具体源码身份和经过检查的证据集合 | 按[证据说明](evidence-guide.md)约定范围；旧作者工作区的 `artifacts/` 不随克隆取得 |

网页展示讲解和代码，运行实验仍需本地 BEAM、PostgreSQL 或对应隔离后端。当前书稿持续修订，配套软件版本仍为 `0.1.0-dev`；平台和实验边界见[当前状态](current-status.md)。

## 固定版本与补充下载

复现某次结果时，按报告记录的完整 commit 检出对应版本；源码准备检查、每次 Actions 和历史冻结候选分别绑定各自身份，不能以未来 `main` 的结果替换旧验证。

[固定版本实验包](experiment-package.md)是克隆之外的补充方式。对应提交的 `Reading site` Actions 会保存源码 ZIP、清单与校验文件，和静态网站产物分别存放。下载 artifact 需要登录 GitHub，保留期为 **14 天**；它不是永久下载地址。已克隆仓库的读者也可用包工具从指定 commit 自行生成同一版本的包。

实验包只包含教材和实验 core 源码，不包含 `website/` 的 Node 站点工具链、已安装依赖、运行时缓存、数据库或作者历史证据。需要本地构建阅读站时使用完整 Git 克隆。GitHub 的普通源码 ZIP 与此处带 `EXPERIMENT-PACKAGE.json` 的实验包也有区别，不应混用清单或校验值。

## 反馈与勘误

在 [Issues](https://github.com/zyg0733/agent-systems-engineering/issues) 中报告错误或提出建议，修订原稿可以提交 Pull Request。提交这些内容需要登录 GitHub，无需私有仓库邀请。

也可以使用[勘误报告工具](errata.md)填写页面、版本和问题，检查后复制、下载或打开预填 Issue 草稿。工具不会自动发送内容；仍需在 GitHub 确认提交。当前未另设邮箱或表单。

反馈请包含材料位置、版本、问题和可检查的依据：

```text
页面 / 小节：
源码 commit 或材料版本：
我理解的说法 / 期望结果：
实际文字 / 命令与返回：
最小复现或对应源码位置：
影响范围：只影响解释 / 阻塞练习 / 可能改变执行目标
```

Issue 和 Pull Request 的内容会公开。先删除凭据与无关私人内容，再提供最小必要输出。遇到命令结果不同，保留原始失败和自己的新目录；不要改写历史报告、覆盖旧输出或放宽断言来获得通过。
