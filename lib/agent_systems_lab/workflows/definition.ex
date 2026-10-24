defmodule AgentSystemsLab.Workflows.Definition do
  @moduledoc """
  A bounded, host-authored static DAG and immutable child budget allocations.

  Persisted definitions contain only inert values. Dependencies supply data, never
  Run options, authority or a replacement Session. Every child keeps its original
  budget after retry or recovery; unused allocations are not transferred.
  """

  alias AgentSystemsLab.{Budget, Context, Recovery, RetryPolicy, Session}
  alias AgentSystemsLab.Isolation.Policy, as: IsolationPolicy
  alias AgentSystemsLab.MCP.Policy, as: MCPPolicy
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.Workspace

  @fields [:schema_version, :nodes, :order, :max_parallel, :budgets, :timeout_ms]
  @node_fields [:id, :deps, :input, :options, :role]
  @budget_fields [
    :max_turns,
    :max_model_attempts,
    :max_output_bytes,
    :max_tool_calls,
    :max_dispatches
  ]
  @defaults %{
    max_turns: 32,
    max_model_attempts: 64,
    max_output_bytes: 524_288,
    max_tool_calls: 128,
    max_dispatches: 256
  }
  @caps %{
    max_turns: 128,
    max_model_attempts: 256,
    max_output_bytes: 8_388_608,
    max_tool_calls: 256,
    max_dispatches: 4096
  }
  @option_fields [
    :script,
    :session,
    :workspace,
    :context_options,
    :max_turns,
    :max_model_attempts,
    :mock_mode,
    :mock_response,
    :retry_policy,
    :model_attempt_scripts,
    :mock_transient_failures,
    :task_budget,
    :isolation_policy,
    :mcp_policy,
    :max_output_bytes,
    :max_stream_events,
    :model_timeout_ms,
    :run_timeout_ms,
    :max_tool_calls
  ]
  @run_budget_fields [
    :max_output_bytes,
    :max_stream_events,
    :model_timeout_ms,
    :run_timeout_ms,
    :max_tool_calls
  ]
  @identifier ~r/\A[A-Za-z0-9_-]{1,64}\z/

  defstruct schema_version: 1,
            nodes: [],
            order: [],
            max_parallel: 3,
            budgets: @defaults,
            timeout_ms: 60_000

  def new(nodes, opts \\ []) do
    with :ok <- keyword(opts, [:max_parallel, :budgets, :timeout_ms]),
         {:ok, normalized} <- normalize_nodes(nodes),
         {:ok, order} <- topological(normalized),
         {:ok, budgets} <- budget_envelope(Keyword.get(opts, :budgets, %{})),
         definition = %__MODULE__{
           nodes: Enum.sort_by(normalized, & &1.id),
           order: order,
           max_parallel: Keyword.get(opts, :max_parallel, 3),
           budgets: budgets,
           timeout_ms: Keyword.get(opts, :timeout_ms, 60_000)
         },
         :ok <- validate_canonical(definition) do
      {:ok, definition}
    end
  end

  def validate(%__MODULE__{} = definition) do
    with :ok <- exact_keys(Map.from_struct(definition), @fields),
         :ok <- validate_canonical(definition),
         {:ok, rebuilt} <-
           new(definition.nodes,
             max_parallel: definition.max_parallel,
             budgets: definition.budgets,
             timeout_ms: definition.timeout_ms
           ),
         true <- rebuilt === definition || {:error, :noncanonical_workflow_definition} do
      :ok
    end
  end

  def validate(_), do: {:error, :invalid_workflow_definition}

  def to_map(%__MODULE__{} = definition), do: Map.from_struct(definition)

  def hash(%__MODULE__{} = definition), do: Context.hash(to_map(definition))

  def from_map(map) when is_map(map) and not is_struct(map) do
    with :ok <- exact_keys(map, @fields),
         definition = struct!(__MODULE__, map),
         :ok <- validate(definition) do
      {:ok, definition}
    end
  end

  def from_map(_), do: {:error, :invalid_workflow_definition}

  @doc "Returns eligible unfinished node IDs in deterministic topological order."
  def ready(%__MODULE__{} = definition, statuses) when is_map(statuses) do
    by_id = Map.new(definition.nodes, &{&1.id, &1})

    Enum.filter(definition.order, fn id ->
      status(Map.get(statuses, id)) in [nil, :pending, :waiting] and
        Enum.all?(by_id[id].deps, &(status(Map.get(statuses, &1)) == :succeeded))
    end)
  end

  def ready(_, _), do: []

  @doc "A deterministic child ID with no dependency on an execution attempt."
  def run_id(workflow_id, node_id) when is_binary(workflow_id) and is_binary(node_id),
    do: "workflow:" <> Context.hash({"workflow-child.v1", workflow_id, node_id})

  @doc "Rehydrates trusted Run options without copying any dependency result into authority."
  def run_options(%{options: options}) when is_map(options) do
    Enum.reduce_while(options, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case hydrate(key, value) do
        {:ok, hydrated} -> {:cont, {:ok, [{key, hydrated} | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  def run_options(_), do: {:error, :invalid_workflow_node}

  def recovery_options(node), do: run_options(node)

  @doc "The fixed aggregate reservation; actual spending stays in child durable counters."
  def allocations(%__MODULE__{nodes: nodes}) do
    Enum.reduce(nodes, Map.new(@budget_fields, &{&1, 0}), fn node, sum ->
      Enum.reduce(@budget_fields, sum, fn key, acc ->
        value =
          if key == :max_dispatches,
            do: node.options.task_budget.max_dispatches,
            else: Map.fetch!(node.options, key)

        Map.update!(acc, key, &(&1 + value))
      end)
    end)
  end

  defp normalize_nodes(nodes) when is_list(nodes) and length(nodes) in 1..8 do
    Enum.reduce_while(nodes, {:ok, []}, fn node, {:ok, acc} ->
      case normalize_node(node) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_nodes(_), do: {:error, :invalid_workflow_nodes}

  defp normalize_node(node) when is_map(node) and not is_struct(node) do
    with true <- Map.keys(node) -- @node_fields == [] || {:error, :invalid_workflow_node},
         true <- identifier?(node[:id]) || {:error, :invalid_workflow_node_id},
         true <- text?(node[:input]) || {:error, :invalid_workflow_node_input},
         deps = Map.get(node, :deps, []),
         true <-
           (is_list(deps) and length(deps) <= 8 and Enum.all?(deps, &identifier?/1) and
              length(deps) == length(Enum.uniq(deps))) || {:error, :invalid_workflow_dependencies},
         role = Map.get(node, :role, :worker),
         true <- role in [:worker, :implementer, :reviewer] || {:error, :invalid_workflow_role},
         {:ok, options} <- normalize_options(Map.get(node, :options, %{})) do
      {:ok,
       %{id: node.id, deps: Enum.sort(deps), input: node.input, options: options, role: role}}
    end
  end

  defp normalize_node(_), do: {:error, :invalid_workflow_node}

  defp normalize_options(opts) when is_list(opts) do
    with :ok <- keyword(opts, @option_fields), do: normalize_options(Map.new(opts))
  end

  defp normalize_options(opts) when is_map(opts) and not is_struct(opts) do
    with true <- Map.keys(opts) -- @option_fields == [] || {:error, :invalid_workflow_run_options},
         {:ok, opts} <- normalize_special(opts),
         {:ok, budget} <- Budget.new(Map.to_list(opts)),
         {:ok, task_budget} <- task_budget(Map.get(opts, :task_budget, %{})),
         opts =
           opts
           |> Map.merge(Map.take(budget, @run_budget_fields))
           |> Map.put_new(:max_turns, 4)
           |> Map.put_new(:max_model_attempts, 8)
           |> Map.put(:task_budget, task_budget),
         true <-
           (integer?(opts.max_turns, 1, @caps.max_turns) and
              integer?(opts.max_model_attempts, 1, @caps.max_model_attempts)) ||
             {:error, :invalid_workflow_run_limits},
         :ok <- validate_recovery_options(opts),
         {:ok, _} <- Codec.encode(opts) do
      {:ok, opts}
    end
  end

  defp normalize_options(_), do: {:error, :invalid_workflow_run_options}

  defp normalize_special(opts) do
    Enum.reduce_while(opts, {:ok, opts}, fn {key, value}, {:ok, acc} ->
      case normalize_value(key, value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_value(:session, %Session{} = session) do
    with :ok <- Session.validate(session), do: {:ok, Session.to_map(session)}
  end

  defp normalize_value(:session, value) do
    with {:ok, _} <- Session.from_map(value), do: {:ok, value}
  end

  defp normalize_value(:isolation_policy, %IsolationPolicy{} = policy) do
    with :ok <- IsolationPolicy.validate(policy), do: {:ok, IsolationPolicy.to_map(policy)}
  end

  defp normalize_value(:isolation_policy, nil), do: {:ok, nil}

  defp normalize_value(:isolation_policy, map) do
    with {:ok, _} <- IsolationPolicy.from_map(map), do: {:ok, map}
  end

  defp normalize_value(:mcp_policy, %MCPPolicy{} = policy) do
    with :ok <- MCPPolicy.validate(policy), do: {:ok, MCPPolicy.to_map(policy)}
  end

  defp normalize_value(:mcp_policy, nil), do: {:ok, nil}

  defp normalize_value(:mcp_policy, map) do
    with {:ok, _} <- MCPPolicy.from_map(map), do: {:ok, map}
  end

  defp normalize_value(:retry_policy, value), do: RetryPolicy.new(value)

  defp normalize_value(:workspace, nil), do: {:ok, nil}

  defp normalize_value(:workspace, root) do
    with {:ok, workspace} <- Workspace.new(root), do: {:ok, workspace.root}
  end

  defp normalize_value(_key, value), do: {:ok, value}

  defp hydrate(:session, map), do: Session.from_map(map)
  defp hydrate(key, nil) when key in [:isolation_policy, :mcp_policy], do: {:ok, nil}
  defp hydrate(:isolation_policy, map), do: IsolationPolicy.from_map(map)
  defp hydrate(:mcp_policy, map), do: MCPPolicy.from_map(map)
  defp hydrate(:task_budget, map), do: {:ok, Map.to_list(map)}
  defp hydrate(_key, value), do: {:ok, value}

  defp validate_recovery_options(opts) do
    session = Map.get(opts, :session) || Session.to_map(%Session{id: "workflow-validation"})

    config = %{
      schema_version: 1,
      provider: "scripted.v1",
      script: Map.get(opts, :script, []),
      session: session,
      workspace: Map.get(opts, :workspace),
      context_options: Map.get(opts, :context_options, []),
      budget: Map.take(opts, @run_budget_fields),
      max_turns: opts.max_turns,
      max_model_attempts: opts.max_model_attempts,
      mock_mode: Map.get(opts, :mock_mode, :idempotent),
      mock_response: Map.get(opts, :mock_response, :ok)
    }

    with :ok <- Recovery.validate_config(config),
         :ok <- retry_options(opts, config) do
      :ok
    end
  end

  defp retry_options(opts, config) do
    retry = Map.get(opts, :retry_policy)

    if is_nil(retry) do
      if Map.has_key?(opts, :model_attempt_scripts) or
           Map.has_key?(opts, :mock_transient_failures),
         do: {:error, :retry_policy_required},
         else: :ok
    else
      value = %{
        schema_version: 1,
        policy: retry,
        model_attempt_scripts: Map.get(opts, :model_attempt_scripts, %{}),
        mock_transient_failures: Map.get(opts, :mock_transient_failures, 0)
      }

      with :ok <- Recovery.validate_retry_config(value),
           true <-
             Enum.all?(Map.keys(value.model_attempt_scripts), &(&1 < length(config.script))) ||
               {:error, :invalid_model_attempt_scripts} do
        :ok
      end
    end
  end

  defp task_budget(opts) when is_list(opts) do
    with :ok <- keyword(opts, [:max_dispatches, :execution_timeout_ms]),
         do: task_budget(Map.new(opts))
  end

  defp task_budget(opts) when is_map(opts) and not is_struct(opts) do
    value = Map.merge(%{max_dispatches: 32, execution_timeout_ms: 5000}, opts)

    if Map.keys(opts) -- [:max_dispatches, :execution_timeout_ms] == [] and
         integer?(value.max_dispatches, 1, @caps.max_dispatches) and
         integer?(value.execution_timeout_ms, 1, 86_400_000),
       do: {:ok, value},
       else: {:error, :invalid_task_budget}
  end

  defp task_budget(_), do: {:error, :invalid_task_budget}

  defp budget_envelope(opts) when is_list(opts) do
    with :ok <- keyword(opts, @budget_fields), do: budget_envelope(Map.new(opts))
  end

  defp budget_envelope(opts) when is_map(opts) and not is_struct(opts) do
    value = Map.merge(@defaults, opts)

    if Map.keys(opts) -- @budget_fields == [] and
         Enum.all?(@budget_fields, &integer?(value[&1], 0, @caps[&1])),
       do: {:ok, value},
       else: {:error, :invalid_workflow_budgets}
  end

  defp budget_envelope(_), do: {:error, :invalid_workflow_budgets}

  defp validate_canonical(definition) do
    with true <- definition.schema_version === 1 || {:error, :unsupported_workflow_version},
         true <-
           integer?(definition.max_parallel, 1, 3) || {:error, :invalid_workflow_parallelism},
         true <-
           integer?(definition.timeout_ms, 1, 86_400_000) || {:error, :invalid_workflow_timeout},
         {:ok, nodes} <- normalize_nodes(definition.nodes),
         true <-
           Enum.sort_by(nodes, & &1.id) === definition.nodes ||
             {:error, :noncanonical_workflow_nodes},
         {:ok, budgets} <- budget_envelope(definition.budgets),
         true <- budgets === definition.budgets || {:error, :noncanonical_workflow_budgets},
         {:ok, order} <- topological(nodes),
         true <- definition.order === order || {:error, :invalid_workflow_order},
         true <- width(nodes, order) <= 3 || {:error, :workflow_width_exceeded},
         :ok <- workspace_separation(nodes),
         allocated = allocations(definition),
         true <-
           Enum.all?(@budget_fields, &(allocated[&1] <= budgets[&1])) ||
             {:error, :workflow_budget_overallocated},
         {:ok, _} <- Codec.encode(to_map(definition)) do
      :ok
    end
  end

  defp topological(nodes) do
    ids = Enum.map(nodes, & &1.id)

    cond do
      length(ids) != length(Enum.uniq(ids)) -> {:error, :duplicate_workflow_node}
      Enum.any?(nodes, &(&1.id in &1.deps)) -> {:error, :self_workflow_dependency}
      Enum.any?(nodes, &(&1.deps -- ids != [])) -> {:error, :missing_workflow_dependency}
      true -> topo(nodes, [])
    end
  end

  defp topo([], order), do: {:ok, order}

  defp topo(nodes, order) do
    case nodes |> Enum.filter(&(&1.deps -- order == [])) |> Enum.sort_by(& &1.id) do
      [] -> {:error, :cyclic_workflow}
      [node | _] -> topo(Enum.reject(nodes, &(&1.id == node.id)), order ++ [node.id])
    end
  end

  # Eight nodes make exhaustive antichain enumeration cheap (at most 256 sets).
  # Looking only at Kahn frontiers would miss graphs with a wider interleaving.
  defp width(nodes, order) do
    by_id = Map.new(nodes, &{&1.id, &1})

    ancestors =
      Enum.reduce(order, %{}, fn id, acc ->
        all = Enum.flat_map(by_id[id].deps, &[&1 | Map.fetch!(acc, &1)]) |> Enum.uniq()
        Map.put(acc, id, all)
      end)

    order
    |> Enum.reduce([[]], fn id, subsets -> subsets ++ Enum.map(subsets, &[id | &1]) end)
    |> Enum.filter(fn set ->
      Enum.all?(set, fn id -> Enum.all?(set -- [id], &(&1 not in ancestors[id])) end)
    end)
    |> Enum.map(&length/1)
    |> Enum.max()
  end

  defp workspace_separation(nodes) do
    roots =
      Enum.flat_map(nodes, fn node ->
        ordinary = Map.get(node.options, :workspace)
        isolated = get_in(node.options, [:isolation_policy, :workspace])
        mcp = get_in(node.options, [:mcp_policy, :isolation_policy, :workspace])

        [ordinary, isolated, mcp]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.map(&{node.id, folded_path(&1)})
      end)

    if Enum.any?(roots, fn {id, root} ->
         Enum.any?(roots, fn {other_id, other} ->
           id != other_id and (ancestor?(root, other) or ancestor?(other, root))
         end)
       end),
       do: {:error, :overlapping_workflow_workspaces},
       else: :ok
  end

  defp folded_path(path),
    do:
      path
      |> Path.expand()
      |> String.normalize(:nfc)
      |> :string.casefold()
      |> String.normalize(:nfc)

  defp ancestor?("/", _path), do: true
  defp ancestor?(root, path), do: root == path or String.starts_with?(path, root <> "/")

  defp status(%{status: status}), do: status
  defp status(status), do: status

  defp keyword(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
         length(opts) == length(Enum.uniq_by(opts, &elem(&1, 0))),
       do: :ok,
       else: {:error, :invalid_workflow_options}
  end

  defp keyword(_, _), do: {:error, :invalid_workflow_options}

  defp exact_keys(map, fields) do
    if Enum.sort(Map.keys(map)) === Enum.sort(fields),
      do: :ok,
      else: {:error, :invalid_workflow_definition}
  end

  defp identifier?(value), do: is_binary(value) and Regex.match?(@identifier, value)
  defp integer?(value, low, high), do: is_integer(value) and value >= low and value <= high
  defp text?(value), do: is_binary(value) and byte_size(value) <= 65_536 and String.valid?(value)
end
