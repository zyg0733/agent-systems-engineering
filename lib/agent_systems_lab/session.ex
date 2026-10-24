defmodule AgentSystemsLab.Session do
  @moduledoc """
  An append-only conversation with immutable task facts and permission constraints.

  User-authored messages cannot claim the `system` or `tool` roles. Tool receipts
  are derived from the run journal by Context, never accepted as Session messages.
  The canonical Session is retained in full; context compression produces a
  separate projection and does not rewrite it.
  """

  @enforce_keys [:id]
  defstruct id: nil, version: 0, facts: %{}, acceptance: [], constraints: [], messages: []

  @type t :: %__MODULE__{
          id: String.t(),
          version: non_neg_integer(),
          facts: map(),
          acceptance: [String.t()],
          constraints: [String.t()],
          messages: [map()]
        }

  @max_messages 1_000
  @max_content_bytes 65_536
  @max_session_bytes 1_048_576
  @roles ["user", "assistant", "note"]
  @fields [:id, :version, :facts, :acceptance, :constraints, :messages]
  @map_fields Enum.map(@fields, &Atom.to_string/1)

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(id, opts \\ []) do
    with :ok <- validate_options(opts) do
      session = %__MODULE__{
        id: id,
        facts: Keyword.get(opts, :facts, %{}),
        acceptance: Keyword.get(opts, :acceptance, []),
        constraints: Keyword.get(opts, :constraints, [])
      }

      with :ok <- validate(session), do: {:ok, session}
    end
  end

  @spec append(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def append(session, role, content) do
    with :ok <- validate(session),
         :ok <- validate_role(role),
         :ok <- validate_content(content) do
      seq = session.version + 1

      message = %{
        "id" => message_id(session.id, seq),
        "seq" => seq,
        "role" => role,
        "content" => content
      }

      next = %{session | version: seq, messages: session.messages ++ [message]}
      with :ok <- validate(next), do: {:ok, next}
    end
  end

  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = session) do
    with true <- Enum.sort(Map.keys(Map.from_struct(session))) == Enum.sort(@fields),
         :ok <- validate_id(session.id),
         true <- is_integer(session.version) and session.version >= 0,
         true <- is_map(session.facts) and not is_struct(session.facts),
         :ok <- validate_json(session.facts, 0),
         :ok <- validate_strings(session.acceptance),
         :ok <- validate_strings(session.constraints),
         :ok <- validate_messages(session),
         true <- byte_size(:erlang.term_to_binary(to_map(session))) <= @max_session_bytes do
      :ok
    else
      false -> {:error, :invalid_session}
      {:error, _reason} = error -> error
    end
  end

  def validate(_session), do: {:error, :invalid_session}

  @doc "Returns a plain, string-keyed map suitable for the inert persistence codec."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    Map.new(@fields, fn field -> {Atom.to_string(field), Map.fetch!(session, field)} end)
  end

  @spec from_map(term()) :: {:ok, t()} | {:error, term()}
  def from_map(map) when is_map(map) and not is_struct(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(@map_fields) do
      session = struct!(__MODULE__, Map.new(@fields, &{&1, Map.fetch!(map, Atom.to_string(&1))}))
      with :ok <- validate(session), do: {:ok, session}
    else
      {:error, :invalid_session}
    end
  end

  def from_map(_map), do: {:error, :invalid_session}

  defp validate_options(opts) when is_list(opts) do
    allowed = [:facts, :acceptance, :constraints]

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, {:invalid_session_options, opts}}
  end

  defp validate_options(opts), do: {:error, {:invalid_session_options, opts}}

  @doc false
  def validate_id(id) when is_binary(id) and byte_size(id) in 1..255 do
    if String.valid?(id) and not String.contains?(id, <<0>>),
      do: :ok,
      else: {:error, :invalid_session_id}
  end

  def validate_id(_id), do: {:error, :invalid_session_id}

  defp validate_role(role) when role in @roles, do: :ok
  defp validate_role(role), do: {:error, {:invalid_session_role, role}}

  defp validate_content(content)
       when is_binary(content) and byte_size(content) <= @max_content_bytes do
    if String.valid?(content), do: :ok, else: {:error, :invalid_session_content}
  end

  defp validate_content(_content), do: {:error, :invalid_session_content}

  defp validate_strings(values) when is_list(values) and length(values) <= 128 do
    collect(values, &validate_content/1)
  end

  defp validate_strings(_values), do: {:error, :invalid_session_requirements}

  defp validate_messages(%{id: id, version: version, messages: messages})
       when is_list(messages) and length(messages) <= @max_messages and
              length(messages) == version do
    messages
    |> Enum.with_index(1)
    |> collect(fn
      {%{"id" => message_id, "seq" => seq, "role" => role, "content" => content} = message, index}
      when map_size(message) == 4 and seq == index ->
        with true <- message_id == message_id(id, index),
             :ok <- validate_role(role),
             :ok <- validate_content(content) do
          :ok
        else
          false -> {:error, :invalid_session_message}
          error -> error
        end

      _ ->
        {:error, :invalid_session_message}
    end)
  end

  defp validate_messages(_session), do: {:error, :invalid_session_messages}

  defp message_id(id, seq), do: "#{id}:m#{seq}"

  defp validate_json(_value, depth) when depth > 16, do: {:error, :session_facts_too_deep}
  defp validate_json(value, _depth) when is_number(value) or value in [nil, true, false], do: :ok
  defp validate_json(value, _depth) when is_binary(value), do: validate_content(value)

  defp validate_json(value, depth) when is_list(value) and length(value) <= 4_096,
    do: collect(value, &validate_json(&1, depth + 1))

  defp validate_json(value, depth)
       when is_map(value) and not is_struct(value) and map_size(value) <= 4_096 do
    collect(Map.to_list(value), fn
      {key, item} when is_binary(key) ->
        with :ok <- validate_content(key), do: validate_json(item, depth + 1)

      _ ->
        {:error, :invalid_session_facts}
    end)
  end

  defp validate_json(_value, _depth), do: {:error, :invalid_session_facts}

  defp collect(values, function) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case function.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
