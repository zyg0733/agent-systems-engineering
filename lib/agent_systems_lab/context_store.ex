defmodule AgentSystemsLab.ContextStore do
  @moduledoc """
  Immutable model-input captures, committed before a provider is invoked.

  Every capture retains the complete inputs as well as the built payload and its
  manifest. Loading reconstructs the context deterministically and checks all
  three, so a forged payload, manifest, or metadata is rejected. These rows are
  audit records; reading them performs no provider or tool work and does not
  resume an interrupted run.
  """
  import Ecto.Query

  alias AgentSystemsLab.{Context, Repo, Session, SessionStore, Storage}
  alias AgentSystemsLab.Kernel.State
  alias AgentSystemsLab.Storage.Codec
  alias AgentSystemsLab.Storage.Context, as: StoredContext

  @spec capture(State.t(), Session.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def capture(run, session, permissions, built, opts \\ []) do
    with :ok <- transaction_boundary(),
         :ok <- validate_options(opts),
         :ok <- Session.validate(session),
         :ok <- validate_run(run),
         context_options = Keyword.get(opts, :context_options, []),
         :ok <- Context.verify(built, session, run, permissions, context_options),
         sources = %{
           "session" => Session.to_map(session),
           "run" => run,
           "permissions" => permissions,
           "context_options" => context_options,
           "persisted_session_id" => Keyword.get(opts, :session_id)
         },
         {:ok, sources_data} <- Codec.encode(sources),
         {:ok, payload_data} <- Codec.encode(built.context),
         {:ok, manifest_data} <- Codec.encode(built.manifest) do
      attrs = %{
        run_id: run.run_id,
        run_seq: run.seq,
        session_id: Keyword.get(opts, :session_id),
        session_version: session.version,
        codec_version: Codec.version(),
        sources_data: sources_data,
        payload_data: payload_data,
        manifest_data: manifest_data
      }

      result =
        Repo.transaction(fn ->
          with {:ok, current} <- Storage.load(run.run_id),
               :ok <- current_run(current.state, run),
               :ok <- current_session(attrs.session_id, session),
               {:ok, row} <- Repo.insert(StoredContext.changeset(%StoredContext{}, attrs)) do
            invoke_hook(opts, :before_commit)
            captured(row, sources, built)
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, _captured} -> invoke_hook(opts, :after_commit)
        _ -> :ok
      end

      result
    end
  end

  @spec load(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def load(id) do
    with {:ok, id} <- valid_uuid(id) do
      case Repo.get(StoredContext, id) do
        nil -> {:error, :context_not_found}
        row -> decode_row(row)
      end
    end
  end

  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(run_id) when is_binary(run_id) do
    Repo.all(
      from(context in StoredContext,
        where: context.run_id == ^run_id,
        order_by: [context.run_seq, context.inserted_at, context.id]
      )
    )
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case decode_row(row) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def list(_run_id), do: {:error, :invalid_run_id}

  defp decode_row(row) do
    # Safe ETF may only refer to the trusted, already loaded runtime vocabulary.
    # Storage.load also initializes the kernel/provider/tool vocabulary. Here the
    # input snapshot can outlive its live RunServer, so preload it explicitly.
    Enum.each(
      [
        AgentSystemsLab.Kernel,
        State,
        AgentSystemsLab.Kernel.Event,
        AgentSystemsLab.RunServer,
        AgentSystemsLab.Budget,
        AgentSystemsLab.Stream,
        AgentSystemsLab.Providers.Scripted,
        AgentSystemsLab.Tools.Catalog,
        AgentSystemsLab.Tools.Gateway,
        AgentSystemsLab.Tools.Result,
        AgentSystemsLab.Tools.Files,
        AgentSystemsLab.Tools.Workspace,
        AgentSystemsLab.Tools.Patch,
        AgentSystemsLab.Tools.Mock,
        JSON,
        Session,
        Context
      ],
      &Code.ensure_loaded!/1
    )

    with {:ok, sources} <- Codec.decode(row.sources_data, row.codec_version),
         {:ok, context} <- Codec.decode(row.payload_data, row.codec_version),
         {:ok, manifest} <- Codec.decode(row.manifest_data, row.codec_version),
         {:ok, session, run, permissions, options} <- decode_sources(sources),
         true <-
           row.run_id === run.run_id and row.run_seq === run.seq and
             row.session_version === session.version,
         true <- row.session_id === sources["persisted_session_id"],
         :ok <-
           Context.verify(
             %{context: context, manifest: manifest},
             session,
             run,
             permissions,
             options
           ) do
      {:ok, captured(row, sources, %{context: context, manifest: manifest})}
    else
      false -> {:error, {:corrupt_context, :metadata_mismatch}}
      {:error, reason} -> {:error, {:corrupt_context, reason}}
    end
  end

  defp decode_sources(
         %{
           "session" => session,
           "run" => run,
           "permissions" => permissions,
           "context_options" => options,
           "persisted_session_id" => binding
         } = sources
       )
       when map_size(sources) == 5 do
    with {:ok, session} <- Session.from_map(session),
         :ok <- validate_run(run),
         true <- is_nil(binding) or binding === session.id do
      {:ok, session, run, permissions, options}
    else
      false -> {:error, :invalid_context_session_binding}
      error -> error
    end
  end

  defp decode_sources(_sources), do: {:error, :invalid_context_sources}

  defp captured(row, sources, built) do
    %{
      id: row.id,
      run_id: row.run_id,
      run_seq: row.run_seq,
      session_id: row.session_id,
      session_version: row.session_version,
      context: built.context,
      manifest: built.manifest,
      sources: sources
    }
  end

  defp current_run(run, expected) when run === expected, do: :ok

  defp current_run(run, expected) when run.seq != expected.seq,
    do: {:error, {:stale_sequence, expected.seq, run.seq}}

  defp current_run(_run, _expected), do: {:error, :run_snapshot_mismatch}

  defp current_session(nil, _session), do: :ok

  defp current_session(id, session) do
    with {:ok, current} <- SessionStore.lock(id, :share) do
      cond do
        current.version != session.version ->
          {:error, {:stale_session_version, session.version, current.version}}

        current !== session ->
          {:error, :session_snapshot_mismatch}

        true ->
          :ok
      end
    end
  end

  defp validate_run(%State{run_id: id, seq: seq})
       when is_binary(id) and is_integer(seq) and seq > 0,
       do: :ok

  defp validate_run(_run), do: {:error, :invalid_context_run}

  defp valid_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_context_id}
    end
  end

  defp transaction_boundary do
    if Repo.in_transaction?(), do: {:error, :nested_transaction_not_supported}, else: :ok
  end

  defp validate_options(opts) when is_list(opts) do
    allowed = [:session_id, :context_options, :hook]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(Keyword.get(opts, :session_id)) or is_binary(Keyword.get(opts, :session_id))) and
         (is_nil(Keyword.get(opts, :hook)) or is_function(Keyword.get(opts, :hook), 1)),
       do: :ok,
       else: {:error, {:invalid_context_store_options, opts}}
  end

  defp validate_options(opts), do: {:error, {:invalid_context_store_options, opts}}

  defp invoke_hook(opts, stage) do
    case Keyword.get(opts, :hook) do
      nil -> :ok
      hook -> hook.(stage)
    end
  end
end
