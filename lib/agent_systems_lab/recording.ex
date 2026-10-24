defmodule AgentSystemsLab.Recording do
  @moduledoc """
  A versioned, inert record of one complete, accepted model result.

  Input and response hashes use the same deterministic local ETF representation
  as `AgentSystemsLab.Context`. They detect inconsistent data; they do not
  authenticate database authors or make model execution exactly once. Recordings
  retain complete response terms, including non-JSON tool argument keys.

  The envelope and response schema versions are independent from the storage
  codec version. A record alone proves neither that its input was captured nor
  that its response committed. `ModelResultStore` establishes those bindings.
  """

  alias AgentSystemsLab.{Context, Provider}
  alias AgentSystemsLab.Storage.Codec

  @attribute_keys [
    :context_id,
    :run_id,
    :input_seq,
    :event_seq,
    :provider,
    :input_sha256,
    :response
  ]
  @record_keys @attribute_keys ++ [:version, :schema_version, :response_sha256]

  @doc "Constructs a record without changing the complete model response."
  def new(attrs) do
    if exact_keys?(attrs, @attribute_keys) do
      record =
        Map.merge(attrs, %{
          version: 1,
          schema_version: 1,
          response_sha256: Context.hash(attrs.response)
        })

      with :ok <- validate(record), do: {:ok, record}
    else
      {:error, :invalid_recording_attributes}
    end
  end

  @doc "Checks every envelope field, the response contract and its exact hash."
  def validate(record) do
    cond do
      not exact_keys?(record, @record_keys) ->
        {:error, :invalid_recording}

      record.version !== 1 ->
        {:error, {:unsupported_recording_version, record.version}}

      record.schema_version !== 1 ->
        {:error, {:unsupported_model_schema_version, record.schema_version}}

      not valid_context_id?(record.context_id) or not nonempty_binary?(record.run_id) or
          not nonempty_text?(record.provider) ->
        {:error, :invalid_recording_metadata}

      not is_integer(record.input_seq) or record.input_seq < 1 or
        not is_integer(record.event_seq) or record.event_seq !== record.input_seq + 1 ->
        {:error, :invalid_recording_sequence}

      not hash?(record.input_sha256) or not hash?(record.response_sha256) ->
        {:error, :invalid_recording_hash}

      not Provider.valid_response?(record.response) ->
        {:error, :invalid_recorded_response}

      record.response_sha256 !== Context.hash(record.response) ->
        {:error, :recorded_response_mismatch}

      true ->
        case Codec.encode(record) do
          {:ok, _binary} -> :ok
          {:error, reason} -> {:error, {:invalid_recording_payload, reason}}
        end
    end
  end

  @doc "Validates a record, optionally matching the exact provider input."
  def verify(record), do: validate(record)

  def verify(record, context) when is_map(context) do
    with :ok <- validate(record) do
      if record.input_sha256 === Context.hash(context),
        do: :ok,
        else: {:error, :recorded_input_mismatch}
    end
  end

  def verify(_record, _context), do: {:error, :invalid_context}

  defp exact_keys?(map, keys) when is_map(map),
    do: not is_struct(map) and Enum.sort(Map.keys(map)) === Enum.sort(keys)

  defp exact_keys?(_map, _keys), do: false
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0
  defp nonempty_text?(value), do: nonempty_binary?(value) and String.valid?(value)
  defp hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_context_id?(nil), do: true
  defp valid_context_id?(id), do: Ecto.UUID.cast(id) === {:ok, id}
end
