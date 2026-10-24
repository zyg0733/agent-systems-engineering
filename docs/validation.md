# 第 1—2 周验收记录

这是 L01 基线的历史验收快照；当前持久化版本见 [第 3 周验收记录](validation-week03.md)。

验证日期：2026-10-20，Asia/Shanghai。环境：macOS arm64，Elixir 1.20.4，Erlang/OTP 28.4。运行时位于项目 `.runtime/`，源代码无第三方依赖。

## 已运行的检查

```sh
./scripts/mix check
./scripts/mix lab.demo
./scripts/mix lab.demo --lost-response
```

`check` 包含格式检查、编译警告视为错误、ExUnit 与 fixture 验收。最终结果为 **53 passed：51 个测试与 2 个 doctest**。10 条 fixture 全部通过，并分别检查最终状态、业务效果数以及事件重建一致性。

测试覆盖合法轨迹、非法状态转换、终态保护、重复操作编号、损坏事件、事件序号与 schema、预算、unknown 核对、并发 100 次同编号工具提交、取消、脚本耗尽、进程生命周期与监督依赖。

普通演示记录 4 个事件，最终为 `succeeded`，模型响应 2 轮、工具请求 1 次、效果 1 次。丢回执演示记录 5 个事件，先进入 `blocked`，再经查询和 `tool_reconciled` 到达 `succeeded`；工具请求与效果仍各为 1。两种演示的纯事件重建结果均与运行状态一致。

L01 手册中 6 段 Elixir 示例已按文档顺序抽取并执行，通过正常轨迹、状态重建、Provider 游标和 Mock 核对示例。

## 范围

以上是本地运行结果。已提供 Linux GitHub Actions 配置，但本次没有推送仓库或执行远程 CI。

所有业务状态和台账仍在内存中。验收证明受控脚本的机制行为，不证明断电恢复、任意监督进程强杀后的可用性，也不代表真实模型的任务成功率。Registry 子树故障测试采用有序停止，边界见 [架构说明](architecture.md)。
