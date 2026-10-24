defmodule AgentSystemsLab.ModelResultStore do
  @moduledoc """
  Complete model results bound to captured inputs and committed kernel events.

  Insertion is only used inside the locked `Storage.dispatch/4` transaction.
  The result, run projection, event and scheduling intent therefore share one
  commit. Partial streams, failures, cancellations and rejected candidate outputs
  are never reusable results. Captured inputs may legitimately have no result.

  Reads check the input capture, its exact event-history prefix, the committed
  output event, metadata and hashes. They only reconstruct data; no provider or
  tool is invoked. Recordings are audit data and explicit offline inputs, not an
  automatic resume mechanism or an external-effect deduplication guarantee.
  """

  import Ecto.Query

  alias AgentSystemsLab.{Context, ContextStore, Recording, Repo, Storage}
  alias AgentSystemsLab.Kernel, as: RunKernel
  alias AgentSystemsLab.Kernel.State
  alias AgentSystemsLab.Storage.{Codec, ModelResult}
  alias AgentSystemsLab.Storage.Event, as: StoredEvent
  alias AgentSystemsLab.History.Encoding

  @doc false
  def insert_for_transition(repo, %State{} = current, events, attrs) do
    with :ok <- transaction_boundary(repo),
         :ok <- validate_attributes(attrs),
         {:ok, capture} <- ContextStore.load(attrs.context_id),
         :ok <- capture_binding(capture, current),
         :ok <- accepted_events(current, attrs.response, events),
         :ok <- inserted_event_binding(repo, current, events),
         {:ok, record} <-
           Recording.new(%{
             context_id: capture.id,
             run_id: current.run_id,
             input_seq: current.seq,
             event_seq: current.seq + 1,
             provider: attrs.provider,
             input_sha256: Context.hash(capture.context),
             response: attrs.response
           }),
         {:ok, data} <- Codec.encode(record),
         {:ok, row} <-
           repo.insert(
             ModelResult.changeset(%ModelResult{}, %{
               context_id: record.context_id,
               run_id: record.run_id,
               input_seq: record.input_seq,
               event_seq: record.event_seq,
               provider: record.provider,
               schema_version: record.schema_version,
               codec_version: Codec.version(),
               record_data: data
             })
           ) do
      {:ok, captured(row, record)}
    end
  end

  def insert_for_transition(_repo, _current, _events, _attrs),
    do: {:error, :invalid_model_result_transition}

  @doc "Loads one verified result, including its complete inert record."
  def load(id) do
    with {:ok, id} <- valid_uuid(id) do
      case Repo.get(ModelResult, id) do
        nil -> {:error, :model_result_not_found}
        row -> decode_row(row)
      end
    end
  end

  @doc "Lists verified results in committed model-event order."
  def list(run_id) when is_binary(run_id) and byte_size(run_id) > 0 do
    Repo.all(
      from(result in ModelResult,
        where: result.run_id == ^run_id,
        order_by: [result.event_seq, result.id]
      )
    )
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, records} ->
      case decode_row(row) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  def list(_run_id), do: {:error, :invalid_run_id}

  defp decode_row(row) do
    Storage.preload_vocabulary()

    with {:ok, record} <- Codec.decode(row.record_data, row.codec_version),
         :ok <- Recording.validate(record),
         :ok <- metadata_binding(row, record),
         {:ok, capture} <- ContextStore.load(record.context_id),
         :ok <- Recording.verify(record, capture.context),
         {:ok, snapshot} <- Storage.load(record.run_id),
         {:ok, prefix} <-
           RunKernel.rebuild(record.run_id, Enum.take(snapshot.events, record.input_seq),
             max_turns: snapshot.state.max_turns
           ),
         :ok <- capture_binding(capture, prefix),
         :ok <-
           accepted_events(prefix, record.response, [Enum.at(snapshot.events, record.input_seq)]) do
      {:ok, captured(row, record)}
    else
      {:error, reason} -> {:error, {:corrupt_model_result, reason}}
    end
  end

  defp accepted_events(current, response, events) do
    case RunKernel.dispatch(current, {:model_response, response}) do
      {:ok, _next, expected} when expected === events -> :ok
      _other -> {:error, :model_result_event_mismatch}
    end
  end

  defp inserted_event_binding(repo, current, [expected]) do
    row =
      repo.one(
        from(event in StoredEvent,
          where: event.run_id == ^current.run_id and event.seq == ^expected.seq
        )
      )

    case row do
      %StoredEvent{} ->
        with {:ok, data} <- Encoding.decode_event(row) do
          if row.run_id === expected.run_id and row.seq === expected.seq and
               row.schema_version === expected.schema_version and
               row.type === Atom.to_string(expected.type) and data === expected.data,
             do: :ok,
             else: {:error, :model_result_event_mismatch}
        end

      nil ->
        {:error, :model_result_event_not_inserted}
    end
  end

  defp capture_binding(capture, current) do
    if capture.run_id === current.run_id and capture.run_seq === current.seq and
         capture.sources["run"] === current,
       do: :ok,
       else: {:error, :model_result_input_binding_mismatch}
  end

  defp metadata_binding(row, record) do
    if row.context_id === record.context_id and row.run_id === record.run_id and
         row.input_seq === record.input_seq and row.event_seq === record.event_seq and
         row.provider === record.provider and row.schema_version === record.schema_version,
       do: :ok,
       else: {:error, :model_result_metadata_mismatch}
  end

  defp captured(row, record),
    do: %{
      id: row.id,
      record: record,
      context_id: row.context_id,
      run_id: row.run_id,
      input_seq: row.input_seq,
      event_seq: row.event_seq
    }

  defp transaction_boundary(repo) do
    if repo.in_transaction?(),
      do: :ok,
      else: {:error, :model_result_requires_transition_transaction}
  end

  defp validate_attributes(attrs) when is_map(attrs) do
    if not is_struct(attrs) and Enum.sort(Map.keys(attrs)) === [:context_id, :provider, :response] and
         is_binary(attrs.context_id),
       do: :ok,
       else: {:error, :invalid_model_result_attributes}
  end

  defp validate_attributes(_attrs), do: {:error, :invalid_model_result_attributes}

  defp valid_uuid(id) do
    case Ecto.UUID.cast(id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_model_result_id}
    end
  end
end
