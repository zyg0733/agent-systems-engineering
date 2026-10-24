defmodule AgentSystemsLab.Checkpoint do
  @moduledoc """
  Versioned, inert kernel checkpoint with deterministic SHA256 digests.

  `verify/2` audits the complete original prefix, including every event schema.
  `validate/1` checks only internal consistency and cannot authenticate a state
  against a journal. Hashes are integrity checks, not signatures.
  """
  alias AgentSystemsLab.Kernel, as: RunKernel
  alias AgentSystemsLab.History
  alias AgentSystemsLab.Kernel.State
  alias AgentSystemsLab.Storage.Codec

  @keys Enum.sort([
          :schema_version,
          :run_id,
          :last_seq,
          :max_turns,
          :state,
          :history_sha256,
          :state_sha256
        ])

  def new(run_id, events, opts \\ []) do
    with {:ok, state} <- History.rebuild(run_id, events, opts),
         {:ok, history_sha256} <- digest(events),
         {:ok, state_sha256} <- digest(state) do
      {:ok,
       %{
         schema_version: 1,
         run_id: run_id,
         last_seq: state.seq,
         max_turns: state.max_turns,
         state: state,
         history_sha256: history_sha256,
         state_sha256: state_sha256
       }}
    end
  end

  def verify(checkpoint, prefix) do
    with :ok <- validate(checkpoint),
         {:ok, rebuilt} <- new(checkpoint.run_id, prefix, max_turns: checkpoint.max_turns),
         true <- rebuilt === checkpoint do
      :ok
    else
      false -> {:error, :checkpoint_history_mismatch}
      error -> error
    end
  end

  def validate(checkpoint) when is_map(checkpoint) do
    cond do
      Enum.sort(Map.keys(checkpoint)) != @keys ->
        {:error, :invalid_checkpoint}

      checkpoint.schema_version !== 1 ->
        {:error, {:unsupported_checkpoint_schema_version, checkpoint.schema_version}}

      not is_binary(checkpoint.run_id) or byte_size(checkpoint.run_id) == 0 ->
        {:error, :invalid_checkpoint}

      not is_integer(checkpoint.last_seq) or checkpoint.last_seq < 0 ->
        {:error, :invalid_checkpoint}

      not is_integer(checkpoint.max_turns) or checkpoint.max_turns < 1 ->
        {:error, :invalid_checkpoint}

      not valid_hash?(checkpoint.history_sha256) ->
        {:error, :invalid_checkpoint_digest}

      not valid_hash?(checkpoint.state_sha256) ->
        {:error, :invalid_checkpoint_digest}

      true ->
        validate_state(checkpoint)
    end
  end

  def validate(_checkpoint), do: {:error, :invalid_checkpoint}

  @doc "Hashes validated inert terms using deterministic external term encoding."
  def digest(term) do
    with {:ok, _encoded} <- Codec.encode(term) do
      {:ok,
       :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))
       |> Base.encode16(case: :lower)}
    end
  end

  defp validate_state(%{state: %State{} = state} = checkpoint) do
    with true <-
           state.run_id === checkpoint.run_id and state.seq === checkpoint.last_seq and
             state.max_turns === checkpoint.max_turns,
         :ok <- valid_kernel_state(state),
         {:ok, hash} <- digest(state),
         true <- hash === checkpoint.state_sha256 do
      :ok
    else
      false -> {:error, :checkpoint_state_mismatch}
      error -> error
    end
  end

  defp validate_state(_checkpoint), do: {:error, :invalid_checkpoint_state}

  defp valid_kernel_state(state) do
    case RunKernel.dispatch(state, :checkpoint_validation) do
      {:error, {:invalid_command, :checkpoint_validation}} -> :ok
      {:error, {:terminal_run, _status}} -> :ok
      _ -> {:error, :invalid_checkpoint_state}
    end
  end

  defp valid_hash?(hash),
    do: is_binary(hash) and byte_size(hash) == 64 and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
end
