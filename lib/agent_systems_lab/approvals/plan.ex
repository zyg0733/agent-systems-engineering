defmodule AgentSystemsLab.Approvals.Plan do
  @moduledoc """
  A host-authored finite review and rework plan over existing static workflows.

  All one to three rounds and their authority are fixed before admission. Every
  round reserves its complete five-dimensional child allocation, including rounds
  never selected; unused resources are not transferred or refunded. One parent
  timeout is measured from original case creation, never restarted by a decision.
  The durable approval store supplies that absolute deadline to child workflows.

  Rework selects the next predeclared round and cannot create a graph, a Session,
  a permission grant or a new budget. Workspaces are independent across nodes and
  rounds, and each artifact root must already be an exact node workspace grant.
  Approver IDs are a trusted host allowlist; they are not an authentication system.
  """

  alias AgentSystemsLab.Context
  alias AgentSystemsLab.Approvals.Artifact
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Workflows.Definition

  @fields [:schema_version, :rounds, :budgets, :timeout_ms, :approvers]
  @round_fields [:id, :definition, :artifacts]
  @budget_fields [
    :max_turns,
    :max_model_attempts,
    :max_output_bytes,
    :max_tool_calls,
    :max_dispatches
  ]
  @defaults %{
    max_turns: 96,
    max_model_attempts: 192,
    max_output_bytes: 1_572_864,
    max_tool_calls: 384,
    max_dispatches: 768
  }
  @caps %{
    max_turns: 384,
    max_model_attempts: 768,
    max_output_bytes: 25_165_824,
    max_tool_calls: 768,
    max_dispatches: 12_288
  }
  @identifier ~r/\A[A-Za-z0-9_-]{1,64}\z/
  @approver ~r/\A[A-Za-z0-9_@.:-]{1,128}\z/

  defstruct schema_version: 1,
            rounds: [],
            budgets: @defaults,
            timeout_ms: 60_000,
            approvers: ["lab-human"]

  def max_rounds, do: 3
  def max_artifact_bytes, do: 1_048_576

  def new(rounds, opts \\ []) do
    with :ok <- options_valid(opts),
         {:ok, normalized} <- normalize_rounds(rounds),
         {:ok, budgets} <- budget_envelope(Keyword.get(opts, :budgets, %{})),
         {:ok, approvers} <- normalize_approvers(Keyword.get(opts, :approvers, ["lab-human"])),
         plan = %__MODULE__{
           rounds: normalized,
           budgets: budgets,
           timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
           approvers: approvers
         },
         :ok <- validate_canonical(plan) do
      {:ok, plan}
    end
  end

  def validate(%__MODULE__{} = plan) do
    with :ok <- exact_keys(Map.from_struct(plan), @fields, :invalid_approval_plan),
         :ok <- validate_canonical(plan),
         {:ok, normalized} <- normalize_rounds(plan.rounds),
         true <- normalized === plan.rounds || {:error, :noncanonical_approval_rounds} do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_approval_plan}
  def to_map(%__MODULE__{} = plan), do: Map.from_struct(plan)
  def hash(%__MODULE__{} = plan), do: Context.hash(to_map(plan))

  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @fields, :invalid_approval_plan),
         plan = struct!(__MODULE__, map),
         :ok <- validate(plan) do
      {:ok, plan}
    end
  end

  def from_map(_), do: {:error, :invalid_approval_plan}

  @doc "Returns the selected round with only its known host-authored structs hydrated."
  def round(%__MODULE__{} = plan, selector) do
    selected =
      cond do
        is_integer(selector) and selector >= 0 -> Enum.at(plan.rounds, selector)
        is_binary(selector) -> Enum.find(plan.rounds, &(&1.id == selector))
        true -> nil
      end

    case selected do
      nil -> {:error, :approval_round_not_found}
      value -> hydrate_round(value)
    end
  end

  def round(_, _), do: {:error, :invalid_approval_plan}

  @doc "Stable identity for one declared round, independent of controller or delivery attempt."
  def workflow_id(case_id, round_id) when is_binary(case_id) and is_binary(round_id),
    do: "approval:" <> Context.hash({"approval-round.v1", case_id, round_id})

  @doc "All fixed child reservations across all rounds, including unused rework rounds."
  def allocations(%__MODULE__{rounds: rounds}) do
    Enum.reduce(rounds, Map.new(@budget_fields, &{&1, 0}), fn round, acc ->
      definition = struct!(Definition, round.definition)
      allocated = Definition.allocations(definition)
      Map.new(@budget_fields, &{&1, acc[&1] + allocated[&1]})
    end)
  end

  defp normalize_rounds(rounds) when is_list(rounds) and length(rounds) in 1..3 do
    Enum.reduce_while(rounds, {:ok, []}, fn round, {:ok, acc} ->
      case normalize_round(round) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} ->
        values = Enum.reverse(values)
        ids = Enum.map(values, & &1.id)

        if length(ids) == length(Enum.uniq(ids)),
          do: {:ok, values},
          else: {:error, :duplicate_approval_round}

      error ->
        error
    end
  end

  defp normalize_rounds(_), do: {:error, :invalid_approval_rounds}

  defp normalize_round(round) when is_map(round) and not is_struct(round) do
    with :ok <- exact_keys(round, @round_fields, :invalid_approval_round),
         true <- identifier?(round.id) || {:error, :invalid_approval_round_id},
         {:ok, definition} <- normalize_definition(round.definition),
         {:ok, artifacts} <- normalize_artifacts(round.artifacts),
         :ok <- artifact_authority(definition, artifacts),
         true <-
           Enum.sum(Enum.map(artifacts, & &1.max_total_bytes)) <= max_artifact_bytes() ||
             {:error, :approval_artifact_bundle_overallocated} do
      {:ok, %{id: round.id, definition: Definition.to_map(definition), artifacts: artifacts}}
    end
  end

  defp normalize_round(_), do: {:error, :invalid_approval_round}

  defp normalize_definition(%Definition{} = definition) do
    with :ok <- Definition.validate(definition), do: {:ok, definition}
  end

  defp normalize_definition(map), do: Definition.from_map(map)

  defp normalize_artifacts(artifacts) when is_list(artifacts) and length(artifacts) in 1..8 do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, acc} ->
      result =
        case artifact do
          %Artifact{} = value -> with :ok <- Artifact.validate(value), do: {:ok, value}
          map -> Artifact.from_map(map)
        end

      case result do
        {:ok, value} -> {:cont, {:ok, [Artifact.to_map(value) | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} ->
        roots = Enum.map(values, &fold(&1.root))

        if length(roots) == length(Enum.uniq(roots)),
          do: {:ok, Enum.sort_by(values, & &1.root)},
          else: {:error, :duplicate_round_artifact_root}

      error ->
        error
    end
  end

  defp normalize_artifacts(_), do: {:error, :invalid_round_artifacts}

  defp hydrate_round(value) do
    with {:ok, definition} <- Definition.from_map(value.definition),
         {:ok, artifacts} <-
           Enum.reduce_while(value.artifacts, {:ok, []}, fn map, {:ok, acc} ->
             case Artifact.from_map(map) do
               {:ok, artifact} -> {:cont, {:ok, [artifact | acc]}}
               error -> {:halt, error}
             end
           end) do
      {:ok, %{id: value.id, definition: definition, artifacts: Enum.reverse(artifacts)}}
    end
  end

  defp validate_canonical(plan) do
    with true <- plan.schema_version === 1 || {:error, :unsupported_approval_plan_version},
         true <-
           (is_integer(plan.timeout_ms) and plan.timeout_ms in 1..86_400_000) ||
             {:error, :invalid_approval_timeout},
         {:ok, budgets} <- budget_envelope(plan.budgets),
         true <- budgets === plan.budgets || {:error, :noncanonical_approval_budgets},
         {:ok, approvers} <- normalize_approvers(plan.approvers),
         true <- approvers === plan.approvers || {:error, :noncanonical_approval_approvers},
         {:ok, rounds} <- normalize_rounds(plan.rounds),
         true <- rounds === plan.rounds || {:error, :noncanonical_approval_rounds},
         :ok <- workspace_separation(rounds),
         allocated = allocations(plan),
         true <-
           Enum.all?(@budget_fields, &(allocated[&1] <= budgets[&1])) ||
             {:error, :approval_budget_overallocated},
         {:ok, _} <- Codec.encode(to_map(plan)) do
      :ok
    end
  end

  defp artifact_authority(definition, artifacts) do
    roots = definition.nodes |> Enum.flat_map(&workspace_roots/1) |> Enum.uniq()

    if Enum.all?(artifacts, &(&1.root in roots)),
      do: :ok,
      else: {:error, :artifact_workspace_not_granted}
  end

  defp workspace_separation(rounds) do
    roots =
      Enum.flat_map(rounds, fn round ->
        Enum.flat_map(round.definition.nodes, fn node ->
          node
          |> workspace_roots()
          |> Enum.uniq()
          |> Enum.map(&{{round.id, node.id}, fold(&1)})
        end)
      end)

    if Enum.any?(roots, fn {owner, root} ->
         Enum.any?(roots, fn {other_owner, other} ->
           owner != other_owner and (ancestor?(root, other) or ancestor?(other, root))
         end)
       end),
       do: {:error, :overlapping_approval_workspaces},
       else: :ok
  end

  defp workspace_roots(node) do
    [
      Map.get(node.options, :workspace),
      get_in(node.options, [:isolation_policy, :workspace]),
      get_in(node.options, [:mcp_policy, :isolation_policy, :workspace])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp budget_envelope(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
      do: budget_envelope(Map.new(opts)),
      else: {:error, :invalid_approval_budgets}
  end

  defp budget_envelope(opts) when is_map(opts) and not is_struct(opts) do
    value = Map.merge(@defaults, opts)

    if Map.keys(opts) -- @budget_fields == [] and
         Enum.all?(@budget_fields, fn field ->
           is_integer(value[field]) and value[field] >= 0 and value[field] <= @caps[field]
         end),
       do: {:ok, value},
       else: {:error, :invalid_approval_budgets}
  end

  defp budget_envelope(_), do: {:error, :invalid_approval_budgets}

  defp normalize_approvers(approvers) when is_list(approvers) and length(approvers) in 1..16 do
    if Enum.all?(approvers, &(is_binary(&1) and Regex.match?(@approver, &1))) and
         length(approvers) == length(Enum.uniq(approvers)),
       do: {:ok, Enum.sort(approvers)},
       else: {:error, :invalid_approval_approvers}
  end

  defp normalize_approvers(_), do: {:error, :invalid_approval_approvers}

  defp options_valid(opts) do
    if is_list(opts) and Keyword.keyword?(opts) and
         Keyword.keys(opts) -- [:budgets, :timeout_ms, :approvers] == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
       do: :ok,
       else: {:error, :invalid_approval_plan_options}
  end

  defp exact_keys(map, keys, reason) do
    if Enum.sort(Map.keys(map)) === Enum.sort(keys), do: :ok, else: {:error, reason}
  end

  defp identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)

  defp fold(path),
    do: path |> String.normalize(:nfc) |> :string.casefold() |> String.normalize(:nfc)

  defp ancestor?("/", _), do: true
  defp ancestor?(root, path), do: root == path or String.starts_with?(path, root <> "/")
end
