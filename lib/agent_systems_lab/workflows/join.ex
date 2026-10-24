defmodule AgentSystemsLab.Workflows.Join do
  @moduledoc """
  Deterministic, lossless dependency bundles made from successful child receipts.

  Results are keyed by source node rather than merged into one shared value. The
  original task, source Run, journal sequence, complete operation receipts and
  hashes stay visible. Tagged JSON preserves inert Erlang atoms, tuples, binary
  data and map key types without creating executable values or host Run options.
  A bundle that exceeds one MiB fails closed instead of truncating its evidence.
  """

  alias AgentSystemsLab.{Context, Kernel, Session}
  alias AgentSystemsLab.Kernel.State
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Tools.Result
  alias AgentSystemsLab.Workflows.Definition

  @completion_keys [:run_id, :seq, :status, :output, :operations]
  @max_bytes 1_048_576

  def max_bytes, do: @max_bytes

  @doc "Derives a successful result only from a structurally valid terminal state."
  def completion(%{state: %State{} = state}), do: completion(state)

  def completion(%State{status: :succeeded} = state) do
    case Kernel.dispatch(state, {:start, "workflow-completion-validation"}) do
      {:error, {:terminal_run, :succeeded}} ->
        completion(Map.take(state, @completion_keys))

      _ ->
        {:error, :invalid_workflow_completion}
    end
  end

  def completion(map) when is_map(map) and not is_struct(map) do
    with true <-
           Enum.sort(Map.keys(map)) === Enum.sort(@completion_keys) ||
             {:error, :invalid_workflow_completion},
         :ok <- Session.validate_id(map.run_id),
         true <-
           (is_integer(map.seq) and map.seq > 0 and map.status === :succeeded and
              is_binary(map.output) and String.valid?(map.output)) ||
             {:error, :invalid_workflow_completion},
         :ok <- operations(map.operations),
         {:ok, _} <- Codec.encode(map) do
      {:ok, map}
    end
  end

  def completion(_), do: {:error, :invalid_workflow_completion}

  @doc "Builds a canonical complete-workflow result manifest in node ID order."
  def build(%Definition{} = definition, completions) do
    with :ok <- Definition.validate(definition),
         {:ok, results} <- sources(Enum.map(definition.nodes, & &1.id), completions),
         manifest = manifest("workflow_results.v1", results),
         :ok <- bounded(manifest) do
      {:ok, manifest}
    end
  end

  @doc "Builds a downstream Run input; empty dependencies preserve its task verbatim."
  def build(input, deps, completions) when is_binary(input) and is_list(deps) do
    with true <- String.valid?(input) || {:error, :invalid_workflow_node_input},
         {:ok, results} <- sources(deps, completions),
         bundle = dependency_manifest(input, results),
         :ok <- bounded(bundle) do
      if deps == [], do: {:ok, input}, else: {:ok, canonical_json(bundle)}
    end
  end

  def build(_input, _deps, _completions), do: {:error, :invalid_workflow_join}

  @doc "Returns only the named node's successful direct dependencies, without authority."
  def dependencies(%Definition{} = definition, node_id, completions) do
    with :ok <- Definition.validate(definition),
         node when not is_nil(node) <- Enum.find(definition.nodes, &(&1.id == node_id)),
         {:ok, results} <- sources(node.deps, completions),
         manifest = dependency_manifest(node.input, results),
         :ok <- bounded(manifest) do
      {:ok, manifest}
    else
      nil -> {:error, :workflow_node_not_found}
      error -> error
    end
  end

  def dependencies(_, _, _), do: {:error, :invalid_workflow_join}

  defp sources(deps, completions) when is_list(deps) and is_map(completions) do
    if length(deps) <= 8 and Enum.all?(deps, &is_binary/1) and
         length(deps) == length(Enum.uniq(deps)) do
      deps
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn id, {:ok, acc} ->
        with {:ok, value} <- Map.fetch(completions, id),
             {:ok, source} <- completion(value) do
          result = %{
            "node_id" => id,
            "run_id" => source.run_id,
            "seq" => source.seq,
            "status" => "succeeded",
            "output" => source.output,
            "operations" => json_value(source.operations),
            "result_sha256" => Context.hash(source)
          }

          {:cont, {:ok, acc ++ [result]}}
        else
          :error -> {:halt, {:error, {:dependency_not_succeeded, id}}}
          {:error, _} -> {:halt, {:error, {:invalid_dependency_completion, id}}}
        end
      end)
    else
      {:error, :invalid_workflow_join}
    end
  end

  defp sources(_, _), do: {:error, :invalid_workflow_join}

  defp dependency_manifest(input, results) do
    body = %{
      "schema_version" => 1,
      "kind" => "workflow_dependencies.v1",
      "task_input" => input,
      "dependencies" => results
    }

    Map.put(body, "sha256", Context.hash(body))
  end

  defp manifest(kind, results) do
    body = %{"schema_version" => 1, "kind" => kind, "results" => results}
    Map.put(body, "sha256", Context.hash(body))
  end

  defp operations(operations) when is_map(operations) and not is_struct(operations) do
    if Enum.all?(operations, fn
         {id,
          %{operation_id: id, tool: tool, arguments: arguments, status: status, result: result} =
              operation}
         when is_binary(id) and byte_size(id) > 0 and is_binary(tool) and byte_size(tool) > 0 and
                is_map(arguments) and status in [:ok, :error] and map_size(operation) == 5 ->
           Result.validate({status, result}, id, tool) === :ok

         _ ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_workflow_completion_operations}
  end

  defp operations(_), do: {:error, :invalid_workflow_completion_operations}

  defp bounded(value) do
    if byte_size(canonical_json(value)) <= @max_bytes,
      do: :ok,
      else: {:error, :workflow_join_too_large}
  end

  # Keys retain their types: atom :value and binary "value" cannot overwrite each
  # other. Binary payloads remain exact even when they are not valid UTF-8 text.
  defp json_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$binary" => Base.encode64(value)}
  end

  defp json_value(value) when value in [nil, true, false], do: value
  defp json_value(value) when is_number(value), do: value
  defp json_value(value) when is_atom(value), do: %{"$atom" => Atom.to_string(value)}
  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_tuple(value),
    do: %{"$tuple" => value |> Tuple.to_list() |> Enum.map(&json_value/1)}

  defp json_value(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _} -> :erlang.term_to_binary(key, [:deterministic]) end)
      |> Enum.map(fn {key, item} -> %{"key" => json_value(key), "value" => json_value(item)} end)

    %{"$map" => entries}
  end

  defp canonical_json(value), do: value |> encode_json() |> IO.iodata_to_binary()

  defp encode_json(map) when is_map(map) do
    entries =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", encode_json(value)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp encode_json(list) when is_list(list),
    do: ["[", list |> Enum.map(&encode_json/1) |> Enum.intersperse(","), "]"]

  defp encode_json(value), do: JSON.encode!(value)
end
