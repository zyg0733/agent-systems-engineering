defmodule AgentSystemsLab.Approvals.PlanTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Context
  alias AgentSystemsLab.Approvals.{Artifact, Plan}
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Workflows.Definition

  setup do
    temporary = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(temporary, "lab-review-plan-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  defp round_spec(root, id, opts \\ []) do
    workspace = Keyword.get(opts, :workspace, Path.join(root, id))
    File.mkdir_p!(workspace)

    {:ok, definition} =
      Definition.new([
        %{
          id: "implement",
          input: "predeclared #{id}",
          role: :implementer,
          options: %{workspace: workspace, script: [{:final, "fixed #{id}"}]}
        }
      ])

    {:ok, artifact} =
      Artifact.new(workspace, ["patch.diff"], initial: %{"patch.diff" => "absent"})

    %{id: id, definition: definition, artifacts: [artifact]}
  end

  test "one to three ordered host rounds persist inertly and hydrate known authority", c do
    rounds = Enum.map(1..3, &round_spec(c.root, "r#{&1}"))
    assert {:ok, plan} = Plan.new(rounds, approvers: ["zoe", "alice"])
    assert Enum.map(plan.rounds, & &1.id) == ["r1", "r2", "r3"]
    assert plan.approvers == ["alice", "zoe"]
    assert plan.timeout_ms == 60_000
    assert Plan.max_rounds() == 3
    assert {:ok, selected} = Plan.round(plan, 1)
    assert selected == Enum.at(rounds, 1)
    assert {:ok, ^selected} = Plan.round(plan, "r2")
    assert is_struct(selected.definition, Definition)
    assert Enum.all?(selected.artifacts, &is_struct(&1, Artifact))
    refute is_struct(hd(plan.rounds).definition)
    assert Plan.hash(plan) == Context.hash(Plan.to_map(plan))
    assert {:ok, bytes} = Codec.encode(Plan.to_map(plan))
    assert {:ok, decoded} = Codec.decode(bytes)
    assert {:ok, ^plan} = Plan.from_map(decoded)
    assert :ok = Plan.validate(plan)
  end

  test "all unused future rounds reserve full allocations without refund or transfer", c do
    rounds = Enum.map(1..3, &round_spec(c.root, "r#{&1}"))
    assert {:ok, plan} = Plan.new(rounds)

    assert Plan.allocations(plan) == %{
             max_turns: 12,
             max_model_attempts: 24,
             max_output_bytes: 196_608,
             max_tool_calls: 48,
             max_dispatches: 96
           }

    for {key, allocation} <- Plan.allocations(plan) do
      assert {:error, :approval_budget_overallocated} =
               Plan.new(rounds, budgets: %{key => allocation - 1})

      assert {:ok, bounded} = Plan.new(rounds, budgets: %{key => allocation})
      assert Plan.allocations(bounded)[key] == allocation
    end

    assert {:ok, selected} = Plan.round(plan, 2)
    assert hd(selected.definition.nodes).options.max_turns == 4
    assert hd(selected.definition.nodes).options.task_budget.max_dispatches == 32
  end

  test "whole case timeout is independent of per-round timeout and cannot be reset in a plan",
       c do
    rounds = [round_spec(c.root, "initial"), round_spec(c.root, "rework")]
    assert {:ok, plan} = Plan.new(rounds, timeout_ms: 1000)
    assert plan.timeout_ms == 1000
    assert Enum.all?(plan.rounds, &(&1.definition.timeout_ms == 60_000))
    assert {:error, :invalid_approval_plan_options} = Plan.new(rounds, deadline_at_ms: 10)
    assert {:error, :invalid_approval_plan_options} = Plan.new(rounds, reset_timeout: true)
    assert {:error, :invalid_approval_timeout} = Plan.new(rounds, timeout_ms: 0)
  end

  test "round count, identity, exact schema and selected index are finite", c do
    first = round_spec(c.root, "r1")
    assert {:error, :invalid_approval_rounds} = Plan.new([])
    assert {:error, :invalid_approval_rounds} = Plan.new(List.duplicate(first, 4))
    assert {:error, :duplicate_approval_round} = Plan.new([first, first])
    assert {:error, :invalid_approval_round_id} = Plan.new([%{first | id: "../dynamic"}])

    assert {:error, :invalid_approval_round} =
             Plan.new([Map.put(first, :model_can_add_nodes, true)])

    assert {:ok, plan} = Plan.new([first])

    for selector <- [-1, 1, "new-round", nil] do
      assert {:error, :approval_round_not_found} = Plan.round(plan, selector)
    end
  end

  test "approver identity is a bounded explicit host allowlist", c do
    rounds = [round_spec(c.root, "r1")]
    assert {:ok, plan} = Plan.new(rounds)
    assert plan.approvers == ["lab-human"]

    for approvers <- [
          [],
          ["alice", "alice"],
          ["bad user"],
          [:alice],
          Enum.map(1..17, &"human#{&1}")
        ] do
      assert {:error, :invalid_approval_approvers} = Plan.new(rounds, approvers: approvers)
    end

    assert {:ok, named} = Plan.new(rounds, approvers: ["alice@example.com", "host:operator"])
    assert named.approvers == ["alice@example.com", "host:operator"]
  end

  test "cross-round mutable workspaces cannot alias, overlap or transfer authority", c do
    first = round_spec(c.root, "r1")
    same = round_spec(c.root, "r2", workspace: hd(first.definition.nodes).options.workspace)
    assert {:error, :overlapping_approval_workspaces} = Plan.new([first, same])

    nested =
      round_spec(c.root, "r2",
        workspace: Path.join(hd(first.definition.nodes).options.workspace, "child")
      )

    assert {:error, :overlapping_approval_workspaces} = Plan.new([first, nested])
    distinct = round_spec(c.root, "r2")
    assert {:ok, plan} = Plan.new([first, distinct])
    assert {:ok, second} = Plan.round(plan, 1)

    refute hd(first.definition.nodes).options.workspace ==
             hd(second.definition.nodes).options.workspace

    assert hd(second.definition.nodes).input == "predeclared r2"
  end

  test "artifact roots must be exact existing node grants rather than nearby paths", c do
    first = round_spec(c.root, "r1")
    outside = Path.join(c.root, "outside")
    nested = Path.join(hd(first.definition.nodes).options.workspace, "nested")
    File.mkdir_p!(outside)
    File.mkdir_p!(nested)
    {:ok, outside_artifact} = Artifact.new(outside, ["patch.diff"])
    {:ok, nested_artifact} = Artifact.new(nested, ["patch.diff"])

    for artifact <- [outside_artifact, nested_artifact] do
      assert {:error, :artifact_workspace_not_granted} =
               Plan.new([%{first | artifacts: [artifact]}])
    end

    assert {:error, :duplicate_round_artifact_root} =
             Plan.new([%{first | artifacts: first.artifacts ++ first.artifacts}])

    assert {:error, :invalid_round_artifacts} = Plan.new([%{first | artifacts: []}])
  end

  test "persisted schema catches changed allocations, approvers and extra authority",
       c do
    assert {:ok, plan} = Plan.new([round_spec(c.root, "r1"), round_spec(c.root, "r2")])
    map = Plan.to_map(plan)

    assert {:error, :unsupported_approval_plan_version} =
             Plan.from_map(%{map | schema_version: 2})

    assert {:error, :invalid_approval_plan} =
             Plan.from_map(Map.put(map, :permissions, %{shell: true}))

    assert {:error, :invalid_approval_plan} = Plan.from_map(Map.delete(map, :approvers))

    assert {:error, :noncanonical_approval_approvers} =
             Plan.from_map(%{map | approvers: ["zoe", "alice"]})

    assert {:error, :noncanonical_approval_budgets} =
             Plan.from_map(%{map | budgets: %{max_turns: 96}})

    assert {:ok, reversed} = Plan.from_map(%{map | rounds: Enum.reverse(map.rounds)})
    refute Plan.hash(reversed) == Plan.hash(plan)
    [first, second] = map.rounds
    artifact = hd(first.artifacts)
    tampered = %{first | artifacts: [%{artifact | files: ["z.txt", "a.txt"]}]}

    assert {:error, :noncanonical_artifact_files} =
             Plan.from_map(%{map | rounds: [tampered, second]})
  end

  test "multi-root review bundles reserve at most one MiB before any round executes", c do
    roots = Enum.map(["first", "second"], &Path.join(c.root, &1))
    Enum.each(roots, &File.mkdir_p!/1)

    {:ok, definition} =
      roots
      |> Enum.with_index()
      |> Enum.map(fn {workspace, index} ->
        %{id: "worker#{index}", input: "fixed", options: %{workspace: workspace}}
      end)
      |> Definition.new()

    artifacts =
      Enum.map(roots, fn root ->
        {:ok, artifact} = Artifact.new(root, ["result.txt"])
        artifact
      end)

    round = %{id: "r1", definition: definition, artifacts: artifacts}
    assert {:error, :approval_artifact_bundle_overallocated} = Plan.new([round])
    allocated = Enum.map(artifacts, &%{&1 | max_total_bytes: 524_288})
    assert {:ok, plan} = Plan.new([%{round | artifacts: allocated}])
    assert Plan.max_artifact_bytes() == 1_048_576

    assert Enum.sum(Enum.map(hd(plan.rounds).artifacts, & &1.max_total_bytes)) ==
             Plan.max_artifact_bytes()
  end

  test "stable round workflow IDs exclude controller and delivery attempts", c do
    id = Plan.workflow_id("case", "r1")
    assert id == Plan.workflow_id("case", "r1")
    refute id == Plan.workflow_id("case", "r2")
    refute id == Plan.workflow_id("other", "r1")
    refute Plan.workflow_id("a:b", "c") == Plan.workflow_id("a", "b:c")
    assert byte_size(id) == 73
    assert {:ok, _} = Plan.new([round_spec(c.root, "r1")], budgets: [max_turns: 4])
  end
end
