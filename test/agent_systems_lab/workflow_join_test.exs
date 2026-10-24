defmodule AgentSystemsLab.Workflows.JoinTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Context, Kernel}
  alias AgentSystemsLab.Tools.Result
  alias AgentSystemsLab.Workflows.{Definition, Join}

  defp completion(id, output \\ "result", operations \\ %{}) do
    %{run_id: "child:" <> id, seq: 5, status: :succeeded, output: output, operations: operations}
  end

  defp definition do
    {:ok, definition} =
      Definition.new([
        %{id: "a", input: "task a"},
        %{id: "b", input: "task b"},
        %{id: "join", deps: ["b", "a"], input: "original task", role: :reviewer}
      ])

    definition
  end

  test "joins concurrent outputs by source in lexical order without last writer wins" do
    values = %{"a" => completion("a", "first"), "b" => completion("b", "second")}
    assert {:ok, input} = Join.build("original task", ["b", "a"], values)

    assert {:ok, ^input} =
             Join.build("original task", ["a", "b"], Map.new(Enum.reverse(Map.to_list(values))))

    decoded = JSON.decode!(input)
    assert decoded["task_input"] == "original task"
    assert Enum.map(decoded["dependencies"], & &1["node_id"]) == ["a", "b"]
    assert Enum.map(decoded["dependencies"], & &1["output"]) == ["first", "second"]
    assert Enum.map(decoded["dependencies"], & &1["run_id"]) == ["child:a", "child:b"]
    assert Enum.all?(decoded["dependencies"], &(&1["seq"] == 5))
    assert decoded["sha256"] == Context.hash(Map.delete(decoded, "sha256"))

    for result <- decoded["dependencies"] do
      assert result["result_sha256"] == Context.hash(values[result["node_id"]])
    end
  end

  test "a root input stays verbatim and a direct dependency excludes unrelated results" do
    values = %{"a" => completion("a"), "b" => completion("b")}
    assert Join.build("unchanged root", [], values) == {:ok, "unchanged root"}
    assert {:ok, bundle} = Join.dependencies(definition(), "a", values)
    assert bundle["dependencies"] == []
    assert {:ok, bundle} = Join.dependencies(definition(), "join", values)
    assert Enum.map(bundle["dependencies"], & &1["node_id"]) == ["a", "b"]
    assert {:error, :workflow_node_not_found} = Join.dependencies(definition(), "absent", values)
  end

  test "complete manifests preserve every terminal source in deterministic node order" do
    values = Map.new(["join", "b", "a"], &{&1, completion(&1)})
    assert {:ok, manifest} = Join.build(definition(), values)
    assert Enum.map(manifest["results"], & &1["node_id"]) == ["a", "b", "join"]
    assert manifest["sha256"] == Context.hash(Map.delete(manifest, "sha256"))
  end

  test "missing, failed, blocked, cancelled or unpaired sources never satisfy a join" do
    assert {:error, {:dependency_not_succeeded, "b"}} =
             Join.build("task", ["b"], %{})

    for status <- [:failed, :blocked, :cancelled, :running] do
      values = %{"a" => %{completion("a") | status: status}}
      assert {:error, {:invalid_dependency_completion, "a"}} = Join.build("task", ["a"], values)
    end

    bad = %{completion("a") | operations: %{"op" => %{status: :unknown}}}

    assert {:error, {:invalid_dependency_completion, "a"}} =
             Join.build("task", ["a"], %{"a" => bad})

    assert {:error, :invalid_workflow_join} = Join.build("task", ["a", "a"], %{})
  end

  test "snapshots derive receipts through kernel state validation without effects" do
    assert {:ok, state} = Kernel.new("snapshot")
    assert {:ok, state, _} = Kernel.dispatch(state, {:start, "task"})
    assert {:ok, state, _} = Kernel.dispatch(state, {:model_response, {:final, "done"}})
    assert {:ok, result} = Join.completion(%{state: state})

    assert result == %{
             run_id: "snapshot",
             seq: 2,
             status: :succeeded,
             output: "done",
             operations: %{}
           }

    assert {:error, :invalid_workflow_completion} = Join.completion(%{state | seq: -1})
  end

  test "full paired tool receipts survive tagged JSON including atom/string key collisions" do
    result = %{
      type: "tool_result.v1",
      operation_id: "call-1",
      tool: "write_file",
      output: %{"value" => %{permissions: %{shell: true}}, value: {:ok, <<255, 0>>}}
    }

    operations = %{
      "call-1" => %{
        operation_id: "call-1",
        tool: "write_file",
        arguments: %{path: "file.txt", contents: "data"},
        status: :ok,
        result: result
      }
    }

    source = completion("a", "tool receipt", operations)
    assert {:ok, input} = Join.build("review", ["a"], %{"a" => source})
    decoded = JSON.decode!(input)
    [joined] = decoded["dependencies"]
    assert joined["result_sha256"] == Context.hash(source)
    encoded_operations = JSON.encode!(joined["operations"])
    assert String.contains?(encoded_operations, "call-1")
    assert String.contains?(encoded_operations, "tool_result.v1")
    assert String.contains?(encoded_operations, "$tuple")
    assert String.contains?(encoded_operations, "$binary")
    assert String.contains?(encoded_operations, "$atom")
    refute Map.has_key?(decoded, "permissions")
    refute Map.has_key?(decoded, "options")

    mismatched = put_in(source, [:operations, "call-1", :result, :operation_id], "other-call")
    assert {:error, :invalid_workflow_completion_operations} = Join.completion(mismatched)
    assert :ok = Result.validate({:ok, result}, "call-1", "write_file")
  end

  test "changing any source output, receipt or sequence changes the source and aggregate hash" do
    a = completion("a")
    assert {:ok, first} = Join.build("task", ["a"], %{"a" => a})

    for modified <- [%{a | output: "changed"}, %{a | seq: 6}, %{a | run_id: "other"}] do
      assert {:ok, changed} = Join.build("task", ["a"], %{"a" => modified})
      refute changed == first
      refute JSON.decode!(changed)["sha256"] == JSON.decode!(first)["sha256"]
    end
  end

  test "invalid completion shape and executable values fail closed before encoding JSON" do
    for invalid <- [
          Map.put(completion("a"), :permissions, %{shell: true}),
          %{completion("a") | seq: 0},
          %{completion("a") | output: <<255>>},
          %{completion("a") | run_id: ""},
          %{completion("a") | operations: self()}
        ] do
      assert {:error, _} = Join.completion(invalid)
    end

    operation = %{
      operation_id: "call",
      tool: "mock_write",
      arguments: %{},
      status: :ok,
      result: fn -> :executable end
    }

    assert {:error, :unsupported_term} =
             Join.completion(completion("a", "result", %{"call" => operation}))
  end

  test "oversize joins fail visibly without trimming task text or source results" do
    oversized = completion("a", String.duplicate("x", Join.max_bytes()))

    assert {:error, :workflow_join_too_large} =
             Join.build("keep this task", ["a"], %{"a" => oversized})

    assert oversized.output == String.duplicate("x", Join.max_bytes())
  end
end
