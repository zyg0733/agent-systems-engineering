# This file is data. Load it with Code.eval_file/1; do not build executable
# scenario expressions from task input. Mix.Tasks.Lab.Verify owns the scenario
# implementations and checks the expected final status.
[
  %{
    id: "direct-success",
    input: "不用工具，给出完成说明。",
    scenario: :direct_success,
    expected_status: :succeeded
  },
  %{
    id: "one-tool-success",
    input: "向模拟服务写入一条草稿，再报告成功。",
    scenario: :tool_success,
    expected_status: :succeeded
  },
  %{
    id: "two-tools-success",
    input: "用两个不同的操作编号依次写入两条模拟记录。",
    scenario: :two_tools,
    expected_status: :succeeded
  },
  %{
    id: "cancel-before-start",
    input: "任务还未开始就收到取消请求。",
    scenario: :cancel_before_start,
    expected_status: :cancelled
  },
  %{
    id: "cancel-while-waiting",
    input: "工具已请求，但在结果到达前取消任务。",
    scenario: :cancel_waiting_tool,
    expected_status: :cancelled
  },
  %{
    id: "explicit-failure",
    input: "执行中发现无法继续的错误，显式结束任务。",
    scenario: :explicit_failure,
    expected_status: :failed
  },
  %{
    id: "tool-fails-before-effect",
    input: "模拟工具在产生业务效果之前失败。",
    scenario: :tool_failure,
    expected_status: :failed
  },
  %{
    id: "lost-response-reconciled",
    input: "模拟工具已产生效果但回执丢失，查询台账后核对结果。",
    scenario: :unknown_then_reconcile,
    expected_status: :succeeded
  },
  %{
    id: "invalid-command-rejected",
    input: "未开始的任务收到模型最终回答，应拒绝且保持原状态。",
    scenario: :invalid_transition,
    expected_status: :queued
  },
  %{
    id: "turn-budget-exhausted",
    input: "脚本持续请求工具，超过模型轮数预算后结束。",
    scenario: :turn_limit,
    expected_status: :failed
  }
]
