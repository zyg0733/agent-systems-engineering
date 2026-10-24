defmodule AgentSystemsLab.BudgetTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Budget

  test "defaults bound requests and the run, while unrelated runtime options are accepted" do
    assert {:ok, budget} = Budget.new(run_id: "budget", storage: :memory)
    assert budget.max_output_bytes == 65_536
    assert budget.max_stream_events == 4_096
    assert budget.max_tool_calls == 16
    assert budget.model_timeout_ms == 5_000
    assert budget.run_timeout_ms == 60_000
  end

  test "every explicit policy is a strict integer with its own lower bound" do
    for name <- [
          :max_output_bytes,
          :max_stream_events,
          :max_tool_calls,
          :model_timeout_ms,
          :run_timeout_ms
        ],
        value <- [nil, false, -1, 1.5, "4", :infinity] do
      assert {:error, {:invalid_budget, ^name, ^value}} = Budget.new([{name, value}])
    end

    assert {:ok, _} = Budget.new(max_output_bytes: 0, max_tool_calls: 0)

    for name <- [:max_stream_events, :model_timeout_ms, :run_timeout_ms] do
      assert {:error, {:invalid_budget, ^name, 0}} = Budget.new([{name, 0}])
    end

    assert {:error, {:invalid_budget, :max_output_bytes, 2}} =
             Budget.new(max_output_bytes: 2, max_output_bytes: 3)

    assert {:error, {:invalid_options, _}} = Budget.new(%{})
    assert {:error, {:invalid_options, _}} = Budget.new([:bad])
  end

  test "UTF-8 counts bytes and the exact limit is allowed across requests" do
    assert {:ok, budget} = Budget.new(max_output_bytes: 4)
    assert {:ok, budget} = Budget.consume(budget, {:text_delta, "中"})
    assert budget.output_bytes == 3
    assert budget.events == 1
    budget = Budget.reset_request(budget)
    assert budget.events == 0
    assert budget.output_bytes == 3
    assert {:ok, budget} = Budget.consume(budget, {:arguments_delta, "x"})
    assert budget.output_bytes == 4

    assert {:error, {:budget_exceeded, :output_bytes}} =
             Budget.consume(budget, {:text_delta, "y"})

    assert budget.output_bytes == 4
  end

  test "zero-byte frames count toward a per-request event limit" do
    assert {:ok, budget} = Budget.new(max_output_bytes: 0, max_stream_events: 2)
    assert {:ok, budget} = Budget.consume(budget, {:text_delta, ""})
    assert {:ok, budget} = Budget.consume(budget, :done)
    assert {:error, {:budget_exceeded, :stream_events}} = Budget.consume(budget, :done)
    assert {:ok, _} = Budget.consume(Budget.reset_request(budget), :done)
  end

  test "legacy complete responses use a bounded payload without changing argument keys" do
    args = %{report: "saved", nested: %{value: 1}}
    call = {:call, %{operation_id: "budget-op", tool: "mock_write", arguments: args}}
    bytes = byte_size("budget-opmock_write") + byte_size(:erlang.term_to_binary(args))
    assert {:ok, budget} = Budget.new(max_output_bytes: bytes + 2)
    assert {:ok, budget} = Budget.consume(budget, {:complete, call})
    assert budget.output_bytes == bytes
    assert {:ok, budget} = Budget.consume(budget, {:complete, {:final, "ok"}})
    assert budget.output_bytes == bytes + 2

    assert {:error, {:budget_exceeded, :output_bytes}} =
             Budget.consume(budget, {:complete, {:final, "!"}})
  end

  test "tool proposals count all prior operations, including failed or unresolved effects" do
    assert {:ok, budget} = Budget.new(max_tool_calls: 1)
    call = {:call, %{operation_id: "next", tool: "mock_write", arguments: %{}}}
    assert :ok = Budget.allow_response(budget, %{operations: %{}}, call)

    assert {:error, {:budget_exceeded, :tool_calls}} =
             Budget.allow_response(budget, %{operations: %{"old" => %{status: :error}}}, call)

    assert :ok = Budget.allow_response(budget, %{operations: %{"old" => %{}}}, {:final, "ok"})
  end

  test "tool metadata cannot bypass the byte limit" do
    assert {:ok, budget} = Budget.new(max_output_bytes: 2)

    assert {:error, {:budget_exceeded, :output_bytes}} =
             Budget.consume(budget, {:tool_start, %{operation_id: "id", tool: "t"}})

    assert budget.output_bytes == 0
  end
end
