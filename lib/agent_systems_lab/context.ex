defmodule AgentSystemsLab.Context do
  @moduledoc """
  Deterministic, byte-bounded provider input with a separate audit manifest.

  Task facts, constraints, the run's complete operation ledger and host permissions
  are protected values. Only session narrative can be omitted. Compaction uses an
  extractive UTF-8 prefix, never a model or a new source of permissions. Its summary
  is explicitly untrusted and retains the identities of its source messages.

  The limit measures deterministic Erlang external-term bytes of the provider
  payload. It is not a token, API billing or manifest-size limit. A protected
  payload that cannot fit fails closed rather than weakening a constraint.
  """

  alias AgentSystemsLab.Kernel.State
  alias AgentSystemsLab.{Kernel, Session}
  alias AgentSystemsLab.Storage.Codec

  @defaults %{max_context_bytes: 262_144, keep_recent_messages: 4, max_summary_bytes: 2_048}
  @option_keys Map.keys(@defaults)
  @protected_keys [
    :run_id,
    :input,
    :turn_count,
    :operations,
    :available_tools,
    :task,
    :session,
    :permissions
  ]
  @algorithm "extractive_prefix.v1"

  @doc "Validates the three context policy options without building provider input."
  def validate_options(opts) do
    case options(opts) do
      {:ok, _policy} -> :ok
      error -> error
    end
  end

  @doc "Returns the complete, strictly validated context policy."
  def options(opts \\ [])

  def options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         Enum.all?(Keyword.keys(opts), &(&1 in @option_keys)) do
      policy = Map.merge(@defaults, Map.new(opts))

      if integer_in?(policy.max_context_bytes, 1, 8_388_608) and
           integer_in?(policy.keep_recent_messages, 0, 1_000) and
           integer_in?(policy.max_summary_bytes, 0, 65_536),
         do: {:ok, policy},
         else: {:error, :invalid_context_options}
    else
      {:error, :invalid_context_options}
    end
  end

  def options(_opts), do: {:error, :invalid_context_options}

  @doc "Builds provider input and an independently stored provenance manifest."
  def build(session, run, permissions, opts \\ []) do
    with {:ok, policy} <- options(opts),
         :ok <- Session.validate(session),
         :ok <- validate_run(run),
         :ok <- validate_permissions(permissions) do
      protected = protected_payload(session, run, permissions)
      minimum = Map.merge(protected, %{messages: [], summary: nil})
      required = encoded_bytes(minimum)

      if required > policy.max_context_bytes do
        {:error, {:protected_context_too_large, required, policy.max_context_bytes}}
      else
        {payload, summary_status} = compact(minimum, session.messages, policy)

        {:ok,
         %{context: payload, manifest: manifest(payload, summary_status, session, run, policy)}}
      end
    end
  end

  @doc "Rebuilds from authoritative sources and rejects any input or manifest alteration."
  def verify(built, session, run, permissions, opts \\ []) do
    case build(session, run, permissions, opts) do
      {:ok, ^built} -> :ok
      {:ok, _expected} -> {:error, :context_mismatch}
      error -> error
    end
  end

  @doc "SHA-256 of deterministic local ETF bytes, used for reproducible audit records."
  def hash(value),
    do: value |> encoded() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  @doc "The exact byte metric used by the context policy."
  def encoded_bytes(value), do: value |> encoded() |> byte_size()

  defp protected_payload(session, run, permissions) do
    %{
      run_id: run.run_id,
      input: run.input,
      turn_count: run.turn_count,
      operations: run.operations,
      available_tools: permissions.available_tools,
      task: %{
        facts: session.facts,
        acceptance: session.acceptance,
        constraints: session.constraints
      },
      session: %{id: session.id, version: session.version},
      permissions: permissions
    }
  end

  defp compact(minimum, messages, policy) do
    full = %{minimum | messages: messages}

    if encoded_bytes(full) <= policy.max_context_bytes do
      {full, "not_needed"}
    else
      count = min(length(messages), policy.keep_recent_messages)
      compact_recent(minimum, messages, policy, count)
    end
  end

  defp compact_recent(minimum, messages, policy, count) do
    {omitted, included} = Enum.split(messages, length(messages) - count)
    base = %{minimum | messages: included}

    if encoded_bytes(base) <= policy.max_context_bytes do
      case fit_summary(base, omitted, policy) do
        nil -> {base, "omitted_budget"}
        summary -> {%{base | summary: summary}, "included"}
      end
    else
      # The empty narrative was already checked before reaching this function.
      compact_recent(minimum, messages, policy, count - 1)
    end
  end

  defp fit_summary(_base, [], _policy), do: nil
  defp fit_summary(_base, _omitted, %{max_summary_bytes: 0}), do: nil

  defp fit_summary(base, omitted, policy) do
    text =
      Enum.map_join(omitted, "\n", fn message ->
        "[#{message["seq"]}:#{message["id"]} #{message["role"]}] #{message["content"]}"
      end)

    metadata = %{
      type: "derived_summary.v1",
      trust: "untrusted_session_narrative",
      algorithm: @algorithm,
      source_ids: Enum.map(omitted, & &1["id"]),
      source_sha256: hash(omitted),
      excerpt: ""
    }

    fits? = fn summary ->
      encoded_bytes(summary) <= policy.max_summary_bytes and
        encoded_bytes(%{base | summary: summary}) <= policy.max_context_bytes
    end

    if fits?.(metadata) do
      bytes = largest_prefix(metadata, text, fits?, 0, byte_size(text))
      if bytes > 0, do: %{metadata | excerpt: utf8_prefix(text, bytes)}, else: nil
    end
  end

  defp largest_prefix(_metadata, _text, _fits?, low, high) when low >= high, do: low

  defp largest_prefix(metadata, text, fits?, low, high) do
    middle = div(low + high + 1, 2)

    if fits?.(%{metadata | excerpt: utf8_prefix(text, middle)}),
      do: largest_prefix(metadata, text, fits?, middle, high),
      else: largest_prefix(metadata, text, fits?, low, middle - 1)
  end

  defp utf8_prefix(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    if String.valid?(prefix), do: prefix, else: utf8_prefix(text, bytes - 1)
  end

  defp manifest(payload, summary_status, session, run, policy) do
    included_ids = Enum.map(payload.messages, & &1["id"])
    included = MapSet.new(included_ids)
    omitted = Enum.reject(session.messages, &MapSet.member?(included, &1["id"]))
    omitted_ids = Enum.map(omitted, & &1["id"])

    %{
      version: 1,
      format: "context_manifest.v1",
      payload_sha256: hash(payload),
      protected_sha256: hash(Map.take(payload, @protected_keys)),
      source_session_sha256: hash(Session.to_map(session)),
      run_state_sha256: hash(run),
      policy_sha256: hash(policy),
      byte_size: encoded_bytes(payload),
      max_context_bytes: policy.max_context_bytes,
      policy: policy,
      messages: %{
        included: included_ids,
        omitted: omitted_ids,
        sources:
          Enum.map(session.messages, fn message ->
            %{
              id: message["id"],
              seq: message["seq"],
              sha256: hash(message),
              disposition:
                if(MapSet.member?(included, message["id"]), do: "included", else: "omitted")
            }
          end)
      },
      summary: %{
        algorithm: @algorithm,
        status: summary_status,
        source_ids: if(summary_status == "not_needed", do: [], else: omitted_ids),
        source_sha256: hash(omitted),
        excerpt_bytes: if(payload.summary, do: byte_size(payload.summary.excerpt), else: 0)
      },
      preserved: %{
        input: true,
        task_facts: true,
        acceptance: true,
        constraints: true,
        tool_receipts: true,
        permissions: true,
        task_sha256: hash(payload.task),
        operations_sha256: hash(payload.operations),
        permissions_sha256:
          hash(%{permissions: payload.permissions, available_tools: payload.available_tools})
      }
    }
  end

  defp validate_run(%State{} = run) do
    with {:ok, _binary} <- Codec.encode(run) do
      # A discarded pure transition reuses every Kernel projection, operation
      # and result-pairing rule without inventing a second state validator.
      # Terminal runs are valid sources too; Kernel validates before reporting
      # their terminal status. No returned state or event is stored or executed.
      case Kernel.dispatch(run, {:cancel, :context_validation}) do
        {:ok, _discarded_state, _discarded_events} -> :ok
        {:error, {:terminal_run, status}} when status == run.status -> :ok
        {:error, _reason} -> {:error, :invalid_context_run}
      end
    else
      {:error, reason} -> {:error, {:invalid_context_run, reason}}
    end
  end

  defp validate_run(_run), do: {:error, :invalid_context_run}

  defp validate_permissions(%{available_tools: tools} = permissions) when is_list(tools) do
    if is_struct(permissions) do
      {:error, :invalid_context_permissions}
    else
      case Codec.encode(permissions) do
        {:ok, _binary} -> :ok
        {:error, reason} -> {:error, {:invalid_context_permissions, reason}}
      end
    end
  end

  defp validate_permissions(_permissions), do: {:error, :invalid_context_permissions}

  defp integer_in?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp encoded(value), do: :erlang.term_to_binary(value, [:deterministic])
end
