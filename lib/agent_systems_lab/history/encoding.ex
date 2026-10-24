defmodule AgentSystemsLab.History.Encoding do
  @moduledoc """
  Explicit adapters for persisted history layouts. Kernel event schema and the
  inert payload codec remain version 1. Format 2 adds a checked envelope around
  the exact original codec bytes; there is no guessing or legacy fallback.
  """
  alias AgentSystemsLab.Storage.Codec

  @tag "AgentSystemsLab.History.Event"
  @formats [1, 2]

  def supported_formats, do: @formats
  def validate_format(format) when format in @formats, do: :ok
  def validate_format(format), do: {:error, {:unsupported_history_format, format}}

  def validate_rows(rows, format) do
    with :ok <- validate_format(format),
         :ok <- validate_row_formats(rows) do
      if Enum.all?(rows, &(&1.history_format === format)),
        do: :ok,
        else: {:error, :mixed_history_formats}
    end
  end

  defp validate_row_formats(rows) do
    Enum.reduce_while(rows, :ok, fn row, :ok ->
      case validate_format(row.history_format) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def encode(original, 1) when is_binary(original) do
    with {:ok, _} <- Codec.decode(original), do: {:ok, original}
  end

  def encode(original, 2) when is_binary(original) do
    with {:ok, _} <- Codec.decode(original),
         do: Codec.encode({@tag, 2, original, hash(original)})
  end

  def encode(_original, format) do
    with :ok <- validate_format(format), do: {:error, :invalid_history_payload}
  end

  def wrap(original, 1, 2), do: encode(original, 2)

  def wrap(_original, source, target),
    do: {:error, {:unsupported_history_migration, source, target}}

  def unwrap(binary, format, codec_version \\ 1)

  def unwrap(binary, 1, codec_version) do
    with {:ok, _} <- Codec.decode(binary, codec_version), do: {:ok, binary}
  end

  def unwrap(binary, 2, codec_version) do
    with {:ok, envelope} <- Codec.decode(binary, codec_version) do
      case envelope do
        {@tag, 2, original, digest} when is_binary(original) and is_binary(digest) ->
          with true <- digest === hash(original) || {:error, :history_checksum_mismatch},
               {:ok, _} <- Codec.decode(original, codec_version),
               do: {:ok, original}

        _ ->
          {:error, :invalid_history_envelope}
      end
    end
  end

  def unwrap(_binary, format, _codec_version), do: validate_format(format)

  def decode_event(%{data: binary, history_format: format, codec_version: codec_version}) do
    with {:ok, original} <- unwrap(binary, format, codec_version),
         do: Codec.decode(original, codec_version)
  end

  def hash(binary) when is_binary(binary),
    do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  @doc false
  def rows_hash(rows, format) do
    rows
    |> Enum.map(fn row ->
      {row.run_id, row.seq, row.type, row.schema_version, row.codec_version, format, row.data}
    end)
    |> :erlang.term_to_binary([:deterministic])
    |> hash()
  end

  @doc false
  def semantic_hash(state, events),
    do: hash(:erlang.term_to_binary({state, events}, [:deterministic]))
end
