# 固定版本实验源码包

实验包用于取得与某个 Git commit 对应的教学源码，不要求接收者具有私有仓库读取权限。**本批只在维护者本地和私有 Actions artifact 中准备、验证，尚未提供公共下载地址。** 只有维护者另行公开包和校验文件后，才能把它描述为公开取得的实验材料。阅读与反馈入口见[材料获取](material-access.md)。

## 包里有什么

包名为 `agent-systems-engineering-<完整 commit>.zip`，解包后的同名目录就是项目根目录。包含代码、测试、固定 fixture、教材与实验、运行脚本、精确的 `mix.lock`、工具链版本，以及 `LICENSE`、`LICENSE-DOCS`、`NOTICE` 和[许可范围](licensing.md)。Git 跟踪的普通文件权限保留，可执行脚本仍可直接运行。

包内另外有两份生成文件：

- `EXPERIMENT-PACKAGE.json`：完整源码 commit/tree、`0.1.0-dev` 等实际项目版本、工具链、每个源码文件的路径、字节数、SHA256 和权限，以及整个文件清单的摘要。
- `PACKAGE-README.txt`：与该包身份绑定的起步说明、预期内存演示输出和平台边界。

包外同时交付 `SHA256SUMS` 和 `package-summary.json`。这三份交付物中的 ZIP 是固定版本源码；这是教学草稿包，不是正式软件版本或 Git tag。构建器不会把未提交修改和未跟踪文件混入包里。

范围沿项目 core 源码白名单：根许可证、README、Mix/工具链配置及研究计划；`.github/`、`book/`、`config/`、`docs/`、`fixtures/`、`labs/`、`lib/`、`priv/`、`scripts/`、`test/`。发现未审查的新顶层跟踪路径会失败，需先明确是否属于实验包。

**不包含** `website/` 的 Node 构建工具链、Git 历史、第三方依赖或安装包、运行时缓存、数据库、凭据及作者历史 `artifacts/`。README 的建站段落适用于完整 Git 克隆；实验包读者使用包内教材和运行脚本。网站许可清单对应浏览器产物，与本源码包的依赖安装分别处理。首次安装 BEAM、Hex 与锁定依赖仍需要联网；离线教学 Provider 不等于首次安装无需网络。

## 维护者生成与验证

使用 Python 3 标准库和 Git，在完整仓库根目录执行。先完成源文件提交，再选择要交付的 commit；输出目录必须是新目录，避免覆盖旧证据：

```sh
package_commit=$(git rev-parse HEAD)
python3 scripts/build_experiment_package.py build \
  --repo . --commit "$package_commit" --output artifacts/experiment-package
python3 scripts/build_experiment_package.py verify \
  --archive "artifacts/experiment-package/agent-systems-engineering-$package_commit.zip" \
  --checksum-file artifacts/experiment-package/SHA256SUMS \
  --repo . --extract artifacts/experiment-package-extracted
```

`build` 直接读取指定提交的 Git blob，不读取相应工作区文件；同一提交在同一打包合同下重复生成的 ZIP 字节相同。ZIP 使用无压缩存储、固定时间与元数据，避免文件时间、工作区路径或压缩库版本影响摘要。清单不会写入维护者姓名、本机路径或当前时间。

`verify --repo .` 不仅比较包内清单，还将所有源码字节、权限和文件集合与所声称的 Git commit 对照。`--extract` 在检查全部条目通过后，才写入新建目录；不会执行导出的 Python、Elixir、shell 或启动数据库。不传 `--extract` 时只验包。输出 JSON 中 `git_source_compared` 和 `external_checksum_compared` 分别说明实际完成了哪项核对。

构建器拒绝源码符号链接、submodule、非白名单路径和受查凭据格式。验包器还拒绝路径穿越、重复项、异常权限、额外或缺失源码、清单/说明篡改、非规范 ZIP 和未登记的附加字节。使用自己控制的新目录，避免与其他进程并发写入；这些检查不等于穷尽凭据扫描或程序安全认证。

私有 CI 在每次 `main` 推送和 Pull Request 时，使用当前运行的完整提交生成同一包，并执行 Git 对照、外部 SHA256 和解包验证。构建器禁用 Git replace objects，避免本机替换引用让旧 commit 名称指向不同源码。只有这些检查通过的 artifact 才进入后续发布准备；下载私有 Actions artifact 仍需权限，不能把它当作公共下载地址。

在 `Reading site` 工作流中，实验包 artifact 命名为 `experiment-source-<完整 commit>-<run_id>-<run_attempt>`，保留 **14 天**。其中只有 ZIP、`SHA256SUMS` 与 `package-summary.json`；解包临时树不作为下载材料上传。它是需要仓库权限的暂存交付物，正式开放时须将同一已验包材料转交到获准的公开位置，不依赖过期 artifact 作为永久下载。过期后可用原固定 commit 与该提交中的打包器重新生成，并核对原始 SHA256；不要用后来变化的 `main` 替换旧包身份。

## 接收者核对和首次运行

从可信材料提供者取得 ZIP、`SHA256SUMS` 和 `package-summary.json`，先确认版本与校验来源。SHA256 能发现传输或文件变化；如果攻击者同时替换 ZIP 与校验清单，摘要本身不能认证作者。

在这三个文件所在目录校验。macOS 使用：

```sh
shasum -a 256 -c SHA256SUMS
```

Linux 使用：

```sh
sha256sum -c SHA256SUMS
```

有可信的本项目检查器时，可在完整仓库外独立验包并安全解开。以下变量填写实际收到的 ZIP 文件路径；这里没有公共下载 URL：

```sh
package_archive=/absolute/path/to/agent-systems-engineering-COMMIT.zip
package_checksums=/absolute/path/to/SHA256SUMS
python3 scripts/build_experiment_package.py verify \
  --archive "$package_archive" --checksum-file "$package_checksums" \
  --extract artifacts/received-experiment-package
```

这里的检查器路径指向**已经信任的检查器副本**，不是要求在校验来源之前执行未知压缩包内的程序。没有 Git 仓库时仍能逐文件检查，但 `git_source_compared=false`；清单里的 commit 声明不是签名。先通过可信的外部摘要确认原包后，也可使用系统 ZIP 解包工具解开到自己的新目录。

进入解包后的项目根目录，先读 `PACKAGE-README.txt`、`.tool-versions` 和 README。macOS 按声明的平台路线安装运行时；Linux 按 [Ubuntu core 入门](linux-core-start.md)安装固定版本，不运行 macOS 专用安装脚本。第一次内存演示使用 Scripted/Recorded Provider 与 Mock，不需要模型密钥或 PostgreSQL。其预期末两行为：

```text
status=succeeded turns=2 requests=1 effects=1
rebuild_matches=true (in-memory history; no durable storage)
```

随后完成 [L01 首次小练习](../labs/L01-state-machine.md#first-exercise)。持久化实验使用自己的 PostgreSQL；Linux core 排除 Seatbelt，完整隔离按已声明的 macOS 路线学习。记录自己实际运行的退出码和输出，不把包内历史验收记录作为本次执行证明。

## 与既有冻结复现工具的关系

本工具为新的 Git 固定版本交付合同，不改写 `lab.reproduce`、W22—W26 冻结 manifest、旧 ReleaseAssessment 或原有历史文件。包内源码可以继续学习那些工具，但 `EXPERIMENT-PACKAGE.json` 不冒充它们的 manifest，也不把 `release_ready=false` 自动改成正式发行通过。完整范围见[当前状态](current-status.md)。
