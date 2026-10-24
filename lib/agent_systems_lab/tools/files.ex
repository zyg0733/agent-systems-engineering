defmodule AgentSystemsLab.Tools.Files do
  @moduledoc """
  Controlled text read, write and patch tools with an in-memory call ledger.

  A call ID is bound to the exact tool name and arguments. Repeated calls return
  their recorded result, including errors, without accessing the filesystem.
  The ledger is process-local and must not be treated as durable exactly-once
  execution after a restart.
  """

  alias AgentSystemsLab.Tools.{Patch, Workspace}

  defstruct [:workspace, ledger: %{}, requests: 0, reads: 0, writes: 0]

  def new(root, opts \\ []) do
    with {:ok, workspace} <- Workspace.new(root, opts) do
      {:ok, %__MODULE__{workspace: workspace}}
    end
  end

  def execute(%__MODULE__{} = state, operation_id, tool, arguments) do
    if valid_id?(operation_id) do
      next = %{state | requests: state.requests + 1}

      case Map.fetch(state.ledger, operation_id) do
        {:ok, %{tool: ^tool, arguments: previous, result: result}} when previous === arguments ->
          {result, next}

        {:ok, _} ->
          {{:error, :operation_id_conflict}, next}

        :error ->
          {result, effect} = perform(state.workspace, tool, arguments)
          entry = %{operation_id: operation_id, tool: tool, arguments: arguments, result: result}
          updated = %{next | ledger: Map.put(next.ledger, operation_id, entry)}
          {result, count_effect(updated, effect)}
      end
    else
      {{:error, :invalid_operation_id}, state}
    end
  end

  def lookup(%__MODULE__{} = state, operation_id) do
    case Map.fetch(state.ledger, operation_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> :not_found
    end
  end

  def stats(state), do: Map.take(state, [:requests, :reads, :writes])

  defp perform(workspace, "file_read", %{"path" => path} = args) when map_size(args) == 1 do
    case Workspace.read(workspace, path) do
      {:ok, content} ->
        {{:ok,
          %{
            "path" => path,
            "content" => content,
            "sha256" => Workspace.sha256(content),
            "bytes" => byte_size(content)
          }}, :read}

      error ->
        {error, nil}
    end
  end

  defp perform(
         workspace,
         "file_write",
         %{"path" => path, "content" => content, "expected_sha256" => expected} = args
       )
       when map_size(args) == 3 do
    case Workspace.write(workspace, path, content, expected) do
      {:ok, before} -> {write_result(path, before, content), :write}
      error -> {error, nil}
    end
  end

  defp perform(
         workspace,
         "file_patch",
         %{"path" => path, "expected_sha256" => expected, "edits" => edits} = args
       )
       when map_size(args) == 3 do
    result =
      with true <- expected != "absent",
           {:ok, before, _mode} <- Workspace.base(workspace, path, expected),
           {:ok, after_contents} <- Patch.apply(before, edits),
           {:ok, ^before} <- Workspace.write(workspace, path, after_contents, expected) do
        write_result(path, before, after_contents)
      else
        false -> {:error, :invalid_expected_sha256}
        {:error, _} = error -> error
      end

    {result, if(match?({:ok, _}, result), do: :write, else: nil)}
  end

  defp perform(_workspace, tool, _arguments)
       when tool in ["file_read", "file_write", "file_patch"],
       do: {{:error, :invalid_arguments}, nil}

  defp perform(_workspace, _tool, _arguments), do: {{:error, :unknown_tool}, nil}

  defp write_result(path, before, after_contents) do
    {:ok,
     %{
       "path" => path,
       "before_sha256" => if(before, do: Workspace.sha256(before), else: "absent"),
       "sha256" => Workspace.sha256(after_contents),
       "bytes" => byte_size(after_contents),
       "diff" => Patch.diff(path, before, after_contents)
     }}
  end

  defp count_effect(state, :read), do: %{state | reads: state.reads + 1}
  defp count_effect(state, :write), do: %{state | writes: state.writes + 1}
  defp count_effect(state, nil), do: state

  defp valid_id?(id) when is_binary(id) do
    byte_size(id) in 1..256 and String.valid?(id) and :binary.match(id, <<0>>) == :nomatch
  end

  defp valid_id?(_), do: false
end
