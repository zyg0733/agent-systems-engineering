defmodule AgentSystemsLab.KernelToolPairingTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Kernel
  alias AgentSystemsLab.Tools.Result

  defp pending(tool \\ "file_read") do
    {:ok, run} = Kernel.new("pairing")
    {:ok, run, started} = Kernel.dispatch(run, {:start, "repair"})
    call = %{operation_id: "call-1", tool: tool, arguments: %{"path" => "x"}}
    {:ok, run, requested} = Kernel.dispatch(run, {:model_response, {:call, call}})
    {run, started ++ requested, call}
  end

  test "paired result is retained with its ID and tool through replay" do
    {run, history, _call} = pending()
    result = Result.wrap({:ok, %{"content" => "source"}}, "call-1", "file_read")
    assert {:ok, next, events} = Kernel.dispatch(run, {:tool_result, "call-1", result})
    assert next.operations["call-1"].result.operation_id == "call-1"
    assert next.operations["call-1"].result.tool == "file_read"
    assert Kernel.rebuild("pairing", history ++ events) == {:ok, next}
  end

  test "tagged envelopes reject missing output, wrong ID, wrong tool and extra fields" do
    {run, history, _call} = pending()
    good = %{type: "tool_result.v1", operation_id: "call-1", tool: "file_read", output: "ok"}

    for payload <- [
          Map.delete(good, :output),
          %{good | operation_id: "other"},
          %{good | tool: "file_write"},
          Map.put(good, :extra, 1)
        ] do
      assert {:error, {:invalid_tool_result_envelope, "call-1", "file_read"}} =
               Kernel.dispatch(run, {:tool_result, "call-1", {:ok, payload}})
    end

    {:ok, _next, [event]} = Kernel.dispatch(run, {:tool_result, "call-1", {:ok, good}})

    forged = %{
      event
      | data: %{operation_id: "call-1", result: {:ok, %{good | tool: "file_write"}}}
    }

    assert {:error, {:invalid_tool_result_envelope, _, _}} =
             Kernel.rebuild("pairing", history ++ [forged])
  end

  test "old v1 unknown-tool histories remain replayable when names later become file tools" do
    for tool <- ~w(file_read file_write file_patch) do
      {run, history, _call} = pending(tool)
      result = {:error, {:unsupported_tool, tool}}
      assert {:ok, running, recorded} = Kernel.dispatch(run, {:tool_result, "call-1", result})
      assert running.operations["call-1"].result == {:unsupported_tool, tool}

      assert {:ok, completed, finished} =
               Kernel.dispatch(running, {:model_response, {:final, "old run"}})

      assert Kernel.rebuild("pairing", history ++ recorded ++ finished) == {:ok, completed}
    end
  end

  test "duplicate IDs and changed arguments never create a second operation" do
    {run, _history, call} = pending()
    result = Result.wrap({:ok, "source"}, "call-1", "file_read")
    {:ok, next, _events} = Kernel.dispatch(run, {:tool_result, "call-1", result})

    for retry <- [call, %{call | arguments: %{"path" => "changed"}}, %{call | tool: "file_write"}] do
      assert {:error, {:duplicate_operation_id, "call-1"}} =
               Kernel.dispatch(next, {:model_response, {:call, retry}})
    end

    assert map_size(next.operations) == 1
  end

  test "wrong outer IDs, duplicate and out-of-order results are rejected" do
    {run, _history, _call} = pending()
    result = Result.wrap({:ok, "source"}, "call-1", "file_read")

    assert {:error, {:unexpected_operation_id, "call-1", "other"}} =
             Kernel.dispatch(run, {:tool_result, "other", result})

    {:ok, next, _events} = Kernel.dispatch(run, {:tool_result, "call-1", result})

    assert {:error, {:invalid_transition, :running, :tool_result}} =
             Kernel.dispatch(next, {:tool_result, "call-1", result})

    {:ok, cancelled, _events} = Kernel.dispatch(run, {:cancel, "stop"})

    assert {:error, {:terminal_run, :cancelled}} =
             Kernel.dispatch(cancelled, {:tool_result, "call-1", result})
  end

  test "unknown file result and reconciliation enforce the same correlation" do
    {run, history, _call} = pending()
    unknown = Result.wrap({:unknown, "receipt uncertain"}, "call-1", "file_read")
    {:ok, blocked, first} = Kernel.dispatch(run, {:tool_result, "call-1", unknown})
    wrong = Result.wrap({:ok, "source"}, "call-2", "file_read")

    assert {:error, {:invalid_tool_result_envelope, _, _}} =
             Kernel.dispatch(blocked, {:reconcile, "call-1", wrong})

    result = Result.wrap({:error, "confirmed absent"}, "call-1", "file_read")
    assert {:ok, running, second} = Kernel.dispatch(blocked, {:reconcile, "call-1", result})
    assert Kernel.rebuild("pairing", history ++ first ++ second) == {:ok, running}
  end

  test "legacy mock payloads are preserved but explicit envelopes must pair" do
    {run, _history, _call} = pending("mock_write")
    arbitrary = %{arbitrary: [:old, "receipt"], operation_id: "a legacy payload field"}
    assert {:ok, next, _} = Kernel.dispatch(run, {:tool_result, "call-1", {:ok, arbitrary}})
    assert next.operations["call-1"].result == arbitrary
    result = Result.wrap({:ok, "wrong"}, "other", "mock_write")

    assert {:error, {:invalid_tool_result_envelope, _, _}} =
             Kernel.dispatch(run, {:tool_result, "call-1", result})
  end
end
