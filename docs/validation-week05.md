# 第 5 周验收记录

验证日期：2026-10-20，Asia/Shanghai。环境沿用 Elixir 1.20.4、Erlang/OTP 28.4、PostgreSQL 18.6，macOS arm64。未新增 Hex 依赖；应用显式启动 OTP 自带的 `:crypto`，用于 SHA256 与临时文件随机名称。

## 本周交付

Catalog 向 Provider 公开工具名称和输入 schema；Gateway 在接受完整工具提议前、执行效果前分别校验。文件工具仅由显式 `workspace` 配置启用，参数使用字符串键，拒绝未知字段、非法调用 ID、路径、内容和 hash 格式。原 Mock 与未知工具的受控错误行为保持兼容。

`operation_id` 继续同时标识当前阶段的 Provider 调用与逻辑操作；每个 Run 只有一个待处理调用。新文件结果使用 `tool_result.v1` 封装核对 ID、工具名与形状，并进入下一轮 Provider context。当前 Runtime 对文件结果强制要求封装；纯 Kernel 只对显式新封装增加规则，旧版同名未知工具的原始结果仍可重建。没有修改 State/Event 字段或既有存储版本。

新增 `file_read`、`file_write`、`file_patch`。文件为无 NUL 的 UTF-8 普通文本，最大 64 KiB；不接受符号链接、多个硬链接或缺失父目录。写入与补丁要求匹配原 SHA256；`"absent"` 仅用于创建。补丁最多 32 项唯一匹配替换，全部在内存预检后一次落盘。单目录临时文件、同步和重命名避免正常调用出现半写目标，失败清理自建临时文件。

Files 的内存台账将调用 ID 绑定到工具名与完整参数；重复传输返回原结果，改参报冲突。成功和失败都保留 ID 绑定。统计区分请求、成功读取和写入，不改变旧 Mock 的计数口径。

## 完整检查

```sh
./scripts/mix check
```

结果：**198 passed，包含 196 个测试与 2 个 doctest，0 失败**。原第 4 周的 137 项全部保留通过，新增 61 项。格式检查、无警告编译、测试库迁移、10/10 原有场景，以及创建/转换各两个提交边界的真实进程 kill 验证全部通过。

| 新增测试组 | 数量 | 主要验证 |
| --- | ---: | --- |
| Workspace / Files / Patch | 29 | 路径与链接、别名、控制字符、有限读取、hash、全补丁预检、原子写、去重、diff |
| Catalog | 6 | 可见能力、严格字段、文本/hash/调用 ID、非法路径前置拒绝 |
| Kernel 配对 | 7 | ID/工具错配、重复/乱序/终态、核对、坏事件、旧历史兼容 |
| RunServer 文件工具 | 11 | Streaming、取消、schema 拒绝、下轮 context、外部命令和执行层复检 |
| PostgreSQL 工具集成 | 6 | 配对提交、新 VM、取消、陈旧 owner、hash 冲突、重建无效果 |
| 离线修复 | 2 | 完整前后验收、diff 实际应用、证据重建、拒绝覆盖旧输出 |

```sh
LAB_DATABASE_ENABLED=false ./scripts/mix test
```

结果：**162 passed，36 个数据库测试明确排除**。内存模式包含真实文件工具与固定修复验收，不需要数据库或模型密钥；它不替代持久化检查。

## 已完成的离线修复

实际运行：

```sh
./scripts/mix lab.repair
```

修复对象为固定的配送费样例：原来 `subtotal > 100` 才免运费，需求为金额达到 100 即免运费。Scripted Provider 依次提议读取源码、替换为 `subtotal >= 100`、新建修复说明、给出最终回答。

| 证据 | 实际结果 |
| --- | --- |
| 修复前验收 | 3/4 通过，金额 100 的断言失败，exit code 2 |
| 修复后验收 | 4/4 通过，exit code 0 |
| 已接受模型响应 | 4 |
| 文件调用 | 3：1 次成功读取、2 次写入 |
| Mock 请求 / 效果 | 0 / 0 |
| 业务事件 | 8，连续 seq 1—8 |
| 事件重建 | 与实际终态完全相同 |

交付目录为 [artifacts/week05-repair](../artifacts/week05-repair/)，其中包括：

- [repair.diff](../artifacts/week05-repair/repair.diff)：源码补丁与新增修复说明的 unified diff。
- [before-test.log](../artifacts/week05-repair/before-test.log) 与 [after-test.log](../artifacts/week05-repair/after-test.log)：独立 BEAM 的实际验收输出。
- [report.json](../artifacts/week05-repair/report.json)：调用 ID、轮数、统计、前后 hash 与验收退出码。
- `events.bin`：可用安全 Codec 读取的业务事件；`workspace/`：修改后的样例文件。

端到端测试把生成的 diff 用真实 `git apply` 应用到另一份原始 fixture，核对源码与新增说明完全一致。另覆盖无末尾换行与空文件创建的 Git-compatible diff。默认输出目录已存在，再次运行会明确拒绝覆盖；重新实验需传 `--output` 指向新目录。

验收程序是宿主固定驱动，只在源码与测试精确匹配已知原始/修复版本后运行固定测试。没有把模型选定的命令、测试或任意生成代码交给宿主执行。该结果证明离线工具流程闭合，不是对真实模型修复能力的评估。

## 审阅发现与补强

实际在当前 macOS 文件系统复现了大小写与 Unicode 字符别名：`.GIT` 可以访问 `.git`，`.awſ`、`depſ` 可以访问 `.aws`、`deps`。只按字面量判断保护目录会失效。最终对根和相对路径组件、内部临时文件前缀统一执行 Unicode casefold 后比较，并拒绝 C0 与 DEL 控制字符。新测试覆盖纯词法规则及现存元数据别名的读写拒绝；完整验收在修复后重新通过。

审阅还避免了一项历史兼容问题：不能仅因为 Runtime 新增了 `file_read` 名称，就改变旧版同名未知工具的结果解释。测试保留三种文件工具名的旧无封装历史重放，同时要求当前 Runtime 的新文件结果严格配对。

## 持久化与手册验证

数据库测试证明：合法文件提议先保存 tool 意图，随后配对结果与下一意图事务提交；非法 schema 没有操作或效果。取消已规划写入后目标仍不存在；另一控制者先取消时，旧 owner 的执行请求被拒绝。文件在提议后变化时返回配对的 `:base_mismatch`，不覆盖新内容。

两个独立 BEAM 分别读取完整修复结果和文件失败结果；历史读取不调用文件适配器。测试在完成后改写源文件，再重建和读取数据库，外部改动保持不变。Storage 预加载新增受信任模块词汇，继续使用原 safe ETF 校验，无不安全回退。

[L04 手册](../labs/L04-controlled-tools.md)、[参考解答](../labs/solutions/L04.md)、[ADR 0004](adr/0004-controlled-tools-and-call-pairing.md) 与 README 已补齐。IEx 等价脚本实际验证了内存和 PostgreSQL 的三工具流程、结果回传、去重、seq 1—8 与无效果重建；手册 CLI 另用专用目录实跑并核对拒绝覆盖。仅清理了这些验证自建的数据和目录，正式交付证据保留。

## 当前边界

工具面向没有恶意并发写者的私人目录；路径与 hash 检查不能消除检查后替换的 TOCTOU 窗口，也不是操作系统沙箱。文件工具同步执行，不承诺慢文件系统调用中的即时取消。

文件效果发生在数据库事务外；文件替换成功、结果提交前崩溃仍会留下不确定窗口。内存台账不能跨重启去重，pending 意图不能据此自动重发。本周没有实现持久 Attempt、lease、fencing、通用 shell 或自动续跑。远程 CI 未执行。
