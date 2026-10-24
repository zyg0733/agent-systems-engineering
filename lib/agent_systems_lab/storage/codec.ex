defmodule AgentSystemsLab.Storage.Codec do
  @moduledoc """
  Version 1 of the lab's local, inert Erlang external term format.

  Values are wrapped in a versioned envelope and stored without compression.
  Decoding uses `binary_to_term/2` with `:safe`: database bytes cannot create new
  atoms or executable terms. PIDs, ports, references, functions, improper lists,
  and structs other than the kernel's State and Event are rejected on both paths.
  The maximum encoded size is 8 MiB and maximum nesting depth is 64.

  This is a BEAM-local teaching format, not a portable API. Payload atoms must
  already exist in the receiving VM; otherwise decoding explicitly fails. Prefer
  string keys and values for application payloads. A future portable codec needs
  a new version and an explicit migration, never an unsafe decode fallback.
  """

  @version 1
  @tag "AgentSystemsLab.Storage"
  @max_bytes 8 * 1024 * 1024
  @max_depth 64
  @structs [AgentSystemsLab.Kernel.State, AgentSystemsLab.Kernel.Event]

  @spec version() :: pos_integer()
  def version, do: @version

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    with :ok <- validate(value, 0) do
      binary = :erlang.term_to_binary({@tag, @version, value})

      if byte_size(binary) <= @max_bytes,
        do: {:ok, binary},
        else: {:error, :payload_too_large}
    end
  end

  @spec decode(binary(), integer()) :: {:ok, term()} | {:error, term()}
  def decode(binary, version \\ @version)

  def decode(_binary, version) when version !== @version,
    do: {:error, {:unsupported_codec_version, version}}

  def decode(<<131, 80, _rest::binary>>, @version), do: {:error, :compressed_payload}

  def decode(binary, @version) when is_binary(binary) and byte_size(binary) <= @max_bytes do
    try do
      case :erlang.binary_to_term(binary, [:safe, :used]) do
        {{@tag, @version, value}, used} when used == byte_size(binary) ->
          with :ok <- validate(value, 0), do: {:ok, value}

        _ ->
          {:error, :invalid_payload}
      end
    rescue
      ArgumentError -> {:error, :invalid_payload}
    end
  end

  def decode(binary, @version) when is_binary(binary), do: {:error, :payload_too_large}
  def decode(_binary, @version), do: {:error, :invalid_payload}

  defp validate(_value, depth) when depth > @max_depth, do: {:error, :payload_too_deep}

  defp validate(value, _depth)
       when is_binary(value) or is_integer(value) or is_float(value) or is_atom(value),
       do: :ok

  defp validate([], _depth), do: :ok

  defp validate([head | tail], depth) do
    with :ok <- validate(head, depth + 1), do: validate_list(tail, depth)
  end

  defp validate(value, depth) when is_tuple(value),
    do: validate_many(Tuple.to_list(value), depth + 1)

  defp validate(%{__struct__: module} = value, depth) when module in @structs,
    do: validate_map(Map.from_struct(value), depth)

  defp validate(%{__struct__: _module}, _depth), do: {:error, :unsupported_struct}
  defp validate(value, depth) when is_map(value), do: validate_map(value, depth)
  defp validate(_value, _depth), do: {:error, :unsupported_term}

  defp validate_list([], _depth), do: :ok

  defp validate_list([head | tail], depth) do
    with :ok <- validate(head, depth + 1), do: validate_list(tail, depth)
  end

  defp validate_list(_tail, _depth), do: {:error, :improper_list}

  defp validate_map(value, depth) do
    Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
      case validate_many([key, item], depth + 1) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_many(values, depth) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validate(value, depth) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
