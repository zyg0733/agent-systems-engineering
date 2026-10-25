# 阅读站维护与 GitHub Pages

阅读站把教材、实验手册和参考文档组织成可连续阅读的静态网站。站点源码位于 [`website/`](../website/)，复用现有 `book/`、`labs/`、`docs/` 和根 README；教材原稿仍在原位置维护。本站使用 VitePress **1.6.4**、Mermaid **12.2.0** 和 Node.js **24**，依赖版本与完整依赖树由 [`package.json`](../website/package.json)及 [`package-lock.json`](../website/package-lock.json)固定。

当前准备的是本地阅读站和默认关闭部署的工作流，**尚未启用 GitHub Pages，也没有公开阅读地址**。仓库保持私有。此前 Pages API 查询返回 404，账户查询的 `plan` 为 `null`，没有取得足以确认套餐的资料；不能据此认定该账户具备从私有仓库发布 Pages 的资格。

## 本地阅读与验证

从具有仓库访问权限的完整 Git 克隆开始，确认 `node --version` 为 24.x。在项目根目录运行：

```sh
cd website
npm ci
npm run dev
```

按终端显示的本机地址阅读。开发服务只绑定 `127.0.0.1`。首次安装依赖需要访问 npm；阅读和构建不需要模型密钥、Elixir、BEAM 或 PostgreSQL。

提交前运行站点专项检查与生产构建：

```sh
npm run check
npm run build
npm run preview
```

`check` 运行 Node 专项测试。`build` 先准备内容，再构建 VitePress，最后运行 `check-output.mjs`，检查生成 HTML 的站内链接、资源和锚点。生产产物位于 `website/.vitepress/dist/`；`preview` 同样只绑定 `127.0.0.1`。应在浏览器核对桌面与窄屏导航、课程与章节入口、搜索结果、代码块、Mermaid 图和前后页。

`preview` 使用项目自己的只读静态服务，显式监听 IPv4 回环地址，并检查真实监听结果；没有使用 VitePress 1.6.4 会忽略 `--host` 的预览实现。它只提供生成目录内的文件，不跟随指向目录外的符号链接。使用其他端口可运行 `npm run preview -- --port 4174`。

默认 base 为 `/agent-systems-engineering/`，适用于项目站点路径。自定义托管路径时，在构建和本地服务中使用相同的 `SITE_BASE`；例如在域名根路径预览：

```sh
SITE_BASE=/ npm run build
SITE_BASE=/ npm run preview
```

发布工作流通过仓库变量 `READING_SITE_BASE` 设置同一环境变量；未设置时沿用默认值。路径改变后必须重新构建并验证，不能只移动旧 HTML。

## 原稿、生成内容与实验源码

新增或修订章节时，直接编辑 `book/`；实验讲解与参考解答编辑 `labs/`；操作和设计文档编辑 `docs/`。可随实验包阅读的六章路线维护在 `book/reading-route.md`，准备器将它呈现为站点的 `/reading.html`，并加入最近章节组件；不要维护另一份路线副本。阅读站自己的首页与开始/教学页在 `website/`，导航、主题、内容准备和检查代码也在该目录。`npm run prepare:content` 会把当前原稿准备到忽略的 `website/.content/`；不要编辑或提交 `.content/`、`node_modules/`、缓存和构建产物。原稿变化后重新运行 `dev` 或 `build` 以刷新准备内容。

阅读站呈现静态讲解与代码，不能在网页上执行 PostgreSQL、BEAM、故障注入或隔离实验。实际实验仍需按 [README](../README.md)和[课程地图](course-map.md)在本地配置环境。站点中的源码链接指向私有 GitHub 仓库，访问者仍需相应仓库权限；教材公开不会自动赋予源码访问权。

全文搜索在浏览器本地执行，支持中文分词。历史验收周报和 `labs/solutions/` 中的教师参考不进入搜索索引，仍可从相应目录或正文链接访问；这只是减少历史噪声和提前看到答案，不构成权限隔离。继续阅读只保存当前浏览器最近打开的正文章节，可从首页清除，不上传阅读记录。

阅读站展示的 W22、W24、W25、W26 等验收页是绑定各自冻结源码的历史材料，不能作为当前工作区已经验收的证明。当前范围见[当前状态](current-status.md)，执行记录见 [GitHub CI](github-ci.md)。本轮按所有者决定使用代理模拟评审，不安排真人验证或公开试读，见[质量计划](public-reading-quality-plan.md)；旧[发行评估](release-assessment.md)保留其历史工具语义。

阅读站工具链与实验源码导出的范围分别维护。`lab.reproduce`、Mix 实验包和冻结复现包不包含 `website/` 的 Node 工具链；这些实验包继续沿其固定源码合同使用。构建阅读站须取得完整 Git 克隆，不能把实验导出包当作完整站点源码，也不能把静态站点产物当作完整实验发行包。

## 自动构建与私有预览

独立工作流为 [`.github/workflows/reading-site.yml`](../.github/workflows/reading-site.yml)，不修改现有实验 [CI 工作流](../.github/workflows/ci.yml)。相关内容推送到 `main`、提出 pull request，或手动运行 `workflow_dispatch` 时，执行 `npm ci`、专项检查、构建和产物检查。

构建成功后上传 `reading-site-preview-<run_id>-<run_attempt>`，保留 14 天。该 artifact 从私有仓库的 Actions 登录下载，用于审阅生成文件；它不是在线预览地址。构建 job 仅有 `contents: read`，不启用 Pages，不申请 Pages 写权限。

独立的 `deploy` job 只在以下条件同时满足时运行：仓库变量 `PUBLISH_READING_SITE` 的字符串值为 `true`，当前 ref 是 `refs/heads/main`，且事件不是 pull request。默认不设置该变量时，部署被跳过，构建仍可正常通过；这不表示网站已经上线。只有部署 job 获得 `pages: write` 和 `id-token: write`，并使用 `github-pages` environment。

部署从同一次运行下载已经验证的预览 artifact，读取已有 Pages 设置，再使用官方 Pages artifact 与部署 Action 发布；不会在部署 job 重新构建另一份内容。`configure-pages` 显式设置 `enablement: false`，不会替维护者开启站点。

## 启用公开阅读前

项目负责人先确认教材可公开、公开范围及对应许可，并确认账户套餐支持从当前私有仓库发布 Pages。[GitHub 官方说明](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)列明：GitHub Pro、Team 和 Enterprise 可在私有仓库使用 Pages；当前账户套餐仍待核实。私有仓库与网站可见性应分别确认，不能把“源码私有”理解为“教材网站也私有”。

获得公开授权并确认托管条件后，由负责人在仓库 Settings → Pages 将构建来源设为 **GitHub Actions**（API 中为 `build_type: workflow`），核对 `github-pages` environment 仅允许预期分支部署。如果使用自定义域名或路径，同时调整 `READING_SITE_BASE` 并重新构建；随后才设置 `PUBLISH_READING_SITE=true`，在 `main` 手动运行本工作流。GitHub 的具体配置要求见[官方自定义工作流说明](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)。

负责人应检查独立部署 job 成功、实际返回的 Pages 地址和浏览器访问结果，再补入 README 的公开入口。关闭发布开关只会阻止后续部署；已有网站如需撤下，应另行在 Pages 设置停用，不能把一次 skipped 部署当成已撤下。

本轮不自动开启 Pages、不设置发布变量、不改变仓库可见性，也不把套餐升级作为默认动作。若最终选择其他托管方式或另设公开教材仓库，先确定目的地与公开范围，再调整部署合同。

## 许可证与依赖维护

`website/` 中的原创构建脚本、测试、主题代码和配置采用 Apache-2.0；原创导读文字、教材正文和图表采用 CC BY 4.0。教材内原创代码示例继续采用 Apache-2.0，第三方内容沿其原许可；具体边界见[许可范围说明](licensing.md)。站点携带两份许可证及 NOTICE，公开前检查许可与署名入口。

依赖升级时同步更新精确版本与 lockfile，重新执行专项检查、构建和浏览器核验。工作流的官方 Action 固定到完整提交 SHA，旁注标明核验时的稳定 release；更新时应从各官方仓库的已发布版本核对 SHA，再审阅输入与权限变化。站点构建通过与实验 CI、冻结候选验证、正式发行分别验收。
