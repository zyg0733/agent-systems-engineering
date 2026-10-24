defmodule AgentSystemsLab.Workflows.DefinitionTest do
  use ExUnit.Case, async: true
  import Kernel, except: [node: 1]

  alias AgentSystemsLab.{Context, Session}
  alias AgentSystemsLab.Isolation.Policy, as: IsolationPolicy
  alias AgentSystemsLab.MCP.Policy, as: MCPPolicy
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Workflows.Definition

  defp node(id, deps \\ [], options \\ %{}),
    do: %{id: id, deps: deps, input: "task " <> id, options: options}

  test "normalizes a diamond into a stable bounded static definition" do
    nodes = [node("z", ["b", "a"]), node("b", ["root"]), node("root"), node("a", ["root"])]
    assert {:ok, definition} = Definition.new(nodes, max_parallel: 2)
    assert definition.order == ["root", "a", "b", "z"]
    assert Enum.map(definition.nodes, & &1.id) == ["a", "b", "root", "z"]
    assert Enum.find(definition.nodes, &(&1.id == "z")).deps == ["a", "b"]
    assert :ok = Definition.validate(definition)
    assert definition.max_parallel == 2
    assert definition.schema_version == 1
    assert {:ok, ^definition} = Definition.new(Enum.reverse(nodes), max_parallel: 2)
    assert Definition.hash(definition) == Context.hash(Definition.to_map(definition))
  end

  test "every child receives an immutable complete resource allocation" do
    assert {:ok, definition} = Definition.new([node("a"), node("b")])

    assert Definition.allocations(definition) == %{
             max_turns: 8,
             max_model_attempts: 16,
             max_output_bytes: 131_072,
             max_tool_calls: 32,
             max_dispatches: 64
           }

    for child <- definition.nodes do
      assert child.options.max_turns == 4
      assert child.options.max_model_attempts == 8
      assert child.options.max_output_bytes == 65_536
      assert child.options.max_tool_calls == 16
      assert child.options.task_budget == %{max_dispatches: 32, execution_timeout_ms: 5000}
      assert {:ok, opts} = Definition.recovery_options(child)
      assert Map.new(opts[:task_budget]) == %{execution_timeout_ms: 5000, max_dispatches: 32}
    end
  end

  test "aggregate envelopes reject over-allocation in each independent budget dimension" do
    for {key, cap} <- [
          max_turns: 7,
          max_model_attempts: 15,
          max_output_bytes: 131_071,
          max_tool_calls: 31,
          max_dispatches: 63
        ] do
      assert {:error, :workflow_budget_overallocated} =
               Definition.new([node("a"), node("b")], budgets: %{key => cap})
    end

    assert {:ok, definition} =
             Definition.new([node("a", [], max_turns: 2), node("b", [], max_turns: 2)],
               budgets: [max_turns: 4]
             )

    assert Definition.allocations(definition).max_turns == 4
  end

  test "a zero output or tool allocation stays zero instead of taking a default" do
    assert {:ok, definition} =
             Definition.new([node("a", [], max_output_bytes: 0, max_tool_calls: 0)],
               budgets: [max_output_bytes: 0, max_tool_calls: 0]
             )

    assert hd(definition.nodes).options.max_output_bytes == 0
    assert hd(definition.nodes).options.max_tool_calls == 0
  end

  test "graph rejects duplicate, missing, self, cyclic, and repeated dependencies" do
    assert {:error, :duplicate_workflow_node} = Definition.new([node("a"), node("a")])
    assert {:error, :missing_workflow_dependency} = Definition.new([node("a", ["absent"])])
    assert {:error, :self_workflow_dependency} = Definition.new([node("a", ["a"])])
    assert {:error, :cyclic_workflow} = Definition.new([node("a", ["b"]), node("b", ["a"])])
    assert {:error, :invalid_workflow_dependencies} = Definition.new([node("a", ["b", "b"])])
  end

  test "static width is capped at three even with a smaller delivery pool" do
    assert {:ok, _} = Definition.new([node("a"), node("b"), node("c")], max_parallel: 1)

    assert {:error, :workflow_width_exceeded} =
             Definition.new([node("a"), node("b"), node("c"), node("d")], max_parallel: 1)

    # Four incomparable vertices occur across levels, not in one lexical frontier.
    assert {:error, :workflow_width_exceeded} =
             Definition.new([
               node("a"),
               node("b"),
               node("c", ["a"]),
               node("d", ["a"]),
               node("e", ["b"]),
               node("f", ["b"])
             ])
  end

  test "node count, identifiers, text, role, options and numeric controls are finite" do
    for nodes <- [[], nil, Enum.map(1..9, &node("n#{&1}"))] do
      assert {:error, :invalid_workflow_nodes} = Definition.new(nodes)
    end

    for id <- ["", "with space", "../escape", "中文", String.duplicate("a", 65), :a] do
      assert {:error, :invalid_workflow_node_id} = Definition.new([%{id: id, input: "task"}])
    end

    for input <- [nil, <<255>>, String.duplicate("x", 65_537)] do
      assert {:error, :invalid_workflow_node_input} = Definition.new([%{id: "a", input: input}])
    end

    assert {:error, :invalid_workflow_role} =
             Definition.new([Map.put(node("a"), :role, :administrator)])

    for parallel <- [0, 4, 1.0, nil] do
      assert {:error, :invalid_workflow_parallelism} =
               Definition.new([node("a")], max_parallel: parallel)
    end

    for timeout <- [0, 86_400_001, nil] do
      assert {:error, :invalid_workflow_timeout} =
               Definition.new([node("a")], timeout_ms: timeout)
    end
  end

  test "unknown fields and duplicate keyword values fail closed" do
    assert {:error, :invalid_workflow_node} =
             Definition.new([Map.put(node("a"), :permissions, %{shell: true})])

    for opts <- [[max_parallel: 1, max_parallel: 2], [dynamic_dag: true], %{}] do
      assert {:error, :invalid_workflow_options} = Definition.new([node("a")], opts)
    end

    assert {:error, :invalid_workflow_options} =
             Definition.new([node("a", [], max_turns: 1, max_turns: 2)])
  end

  test "child options cannot supply execution hooks, queue scope or authority overrides" do
    for options <- [
          %{hook: fn _ -> :ok end},
          %{queue: "outside"},
          %{priority: 100},
          %{permissions: %{shell: true}},
          %{provider: "host"}
        ] do
      assert {:error, :invalid_workflow_run_options} = Definition.new([node("a", [], options)])
    end

    for unsafe <- [self(), make_ref(), fn -> :effect end] do
      assert {:error, :unsupported_term} =
               Definition.new([node("a", [], %{script: [{:error, unsafe}]})])
    end
  end

  test "session is persisted inertly and rehydrated with its immutable constraints" do
    assert {:ok, session} =
             Session.new("host-session", facts: %{"task" => "preserve"}, constraints: ["offline"])

    assert {:ok, definition} = Definition.new([node("a", [], session: session)])
    child = hd(definition.nodes)
    refute is_struct(child.options.session)
    assert {:ok, opts} = Definition.recovery_options(child)
    assert opts[:session] == session
    assert {:ok, bytes} = Codec.encode(Definition.to_map(definition))
    assert {:ok, plain} = Codec.decode(bytes)
    assert {:ok, ^definition} = Definition.from_map(plain)
  end

  test "strict persisted schema rejects tampering instead of renormalizing it" do
    assert {:ok, definition} = Definition.new([node("a"), node("b", ["a"])])
    saved = Definition.to_map(definition)

    for invalid <- [
          Map.put(saved, :schema_version, 2),
          Map.put(saved, :order, ["b", "a"]),
          Map.put(saved, :nodes, Enum.reverse(saved.nodes)),
          Map.put(saved, :grant, true),
          Map.delete(saved, :timeout_ms)
        ] do
      assert {:error, _} = Definition.from_map(invalid)
    end

    [first, second] = saved.nodes

    tampered = %{
      saved
      | nodes: [%{first | options: Map.delete(first.options, :max_turns)}, second]
    }

    assert {:error, :noncanonical_workflow_nodes} = Definition.from_map(tampered)
  end

  test "only successful direct parents release a child and blocked siblings do not interfere" do
    assert {:ok, definition} =
             Definition.new([
               node("root"),
               node("a", ["root"]),
               node("b", ["root"]),
               node("z", ["a", "b"])
             ])

    assert Definition.ready(definition, %{}) == ["root"]
    assert Definition.ready(definition, %{"root" => :succeeded}) == ["a", "b"]

    assert Definition.ready(definition, %{
             "root" => :succeeded,
             "a" => :blocked,
             "b" => %{status: :waiting}
           }) == ["b"]

    for status <- [:failed, :cancelled, :skipped, :blocked, :running] do
      assert Definition.ready(definition, %{
               "root" => :succeeded,
               "a" => status,
               "b" => :succeeded
             }) == []
    end

    assert Definition.ready(definition, %{
             "root" => :succeeded,
             "a" => :succeeded,
             "b" => :succeeded
           }) == ["z"]
  end

  test "child IDs distinguish workflow/node pairs without path or attempt material" do
    id = Definition.run_id("workflow", "node")
    assert byte_size(id) == 73
    assert id == Definition.run_id("workflow", "node")
    refute id == Definition.run_id("workflow", "other")
    refute Definition.run_id("a:b", "c") == Definition.run_id("a", "b:c")
  end

  test "retry scripts use original child allocations and require a valid finite policy" do
    assert {:ok, definition} =
             Definition.new([
               node("a", [],
                 script: [{:error, :transient}],
                 retry_policy: [max_attempts: 2],
                 model_attempt_scripts: %{0 => [{:final, "recovered"}]}
               )
             ])

    assert hd(definition.nodes).options.retry_policy.max_attempts == 2
    assert Definition.allocations(definition).max_turns == 4

    assert {:error, :retry_policy_required} =
             Definition.new([node("a", [], model_attempt_scripts: %{})])

    assert {:error, :invalid_model_attempt_scripts} =
             Definition.new([
               node("a", [],
                 script: [],
                 retry_policy: [],
                 model_attempt_scripts: %{0 => [{:final, "bad"}]}
               )
             ])
  end

  test "children with overlapping file authority cannot share a mutable workspace" do
    temporary = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    base = Path.join(temporary, "lab-dag-#{System.unique_integer([:positive])}")
    first = Path.join(base, "implementer")
    nested = Path.join(first, "nested")
    second = Path.join(base, "reviewer")
    File.mkdir_p!(nested)
    File.mkdir_p!(second)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:error, :overlapping_workflow_workspaces} =
             Definition.new([node("a", [], workspace: first), node("b", [], workspace: first)])

    assert {:error, :overlapping_workflow_workspaces} =
             Definition.new([node("a", [], workspace: first), node("b", [], workspace: nested)])

    reviewer = node("review", ["implement"], workspace: second) |> Map.put(:role, :reviewer)
    implementer = node("implement", [], workspace: first) |> Map.put(:role, :implementer)
    assert {:ok, definition} = Definition.new([implementer, reviewer])
    assert Enum.find(definition.nodes, &(&1.id == "review")).options.workspace == second
  end

  test "isolation and MCP policy maps retain authority and rehydrate only their known types" do
    temporary = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    base = Path.join(temporary, "lab-dag-policy-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    command = Path.join(base, "host-probe")
    File.mkdir_p!(workspace)
    File.write!(command, "trusted policy fixture")
    File.chmod!(command, 0o700)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:ok, isolation} = IsolationPolicy.new(workspace: workspace, commands: [command])

    assert {:ok, mcp} =
             MCPPolicy.new(
               server_name: "approved",
               command: command,
               args: [],
               isolation_policy: isolation,
               tools: [
                 %{
                   name: "echo",
                   description: "host text",
                   input_schema: %{
                     "type" => "object",
                     "properties" => %{},
                     "additionalProperties" => false
                   }
                 }
               ]
             )

    assert {:ok, definition} =
             Definition.new([
               node("implementer", [], isolation_policy: isolation, mcp_policy: mcp),
               Map.put(node("reviewer", ["implementer"]), :role, :reviewer)
             ])

    implementer = Enum.find(definition.nodes, &(&1.id == "implementer"))
    reviewer = Enum.find(definition.nodes, &(&1.id == "reviewer"))
    refute is_struct(implementer.options.isolation_policy)
    refute is_struct(implementer.options.mcp_policy)
    assert {:ok, restored} = Definition.recovery_options(implementer)
    assert restored[:isolation_policy] == isolation
    assert restored[:mcp_policy] == mcp
    assert {:ok, reviewer_options} = Definition.recovery_options(reviewer)
    refute Keyword.has_key?(reviewer_options, :workspace)
    refute Keyword.has_key?(reviewer_options, :isolation_policy)
    refute Keyword.has_key?(reviewer_options, :mcp_policy)

    assert {:ok, encoded} = Codec.encode(Definition.to_map(definition))
    assert {:ok, plain} = Codec.decode(encoded)
    assert {:ok, ^definition} = Definition.from_map(plain)
  end

  test "the filesystem root overlaps descendants and Unicode path aliases fail closed" do
    temporary = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    base = Path.join(temporary, "lab-dag-alias-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    assert {:error, :overlapping_workflow_workspaces} =
             Definition.new([
               node("root", [], workspace: "/"),
               node("nested", [], workspace: base)
             ])

    ascii = Path.join(base, "source")
    unicode = Path.join(base, "ſource")
    File.mkdir_p!(ascii)
    File.mkdir_p!(unicode)

    assert {:error, :overlapping_workflow_workspaces} =
             Definition.new([
               node("ascii", [], workspace: ascii),
               node("unicode", [], workspace: unicode)
             ])

    # Similar prefixes are different directory components and remain independent.
    next = Path.join(base, "source-extra")
    File.mkdir_p!(next)

    assert {:ok, _} =
             Definition.new([
               node("first", [], workspace: ascii),
               node("next", [], workspace: next)
             ])
  end
end
