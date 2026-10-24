defmodule AgentSystemsLab.Observability do
  @moduledoc """
  Lossy observability beside durable execution. Emission always returns `:ok`.

  No database, file, network, exporter callback or synchronous process call occurs
  on the emission path. A missing, stopped, full or failing observer cannot alter
  an execution result. Query/rebuild of durable evidence is a separate host action.
  Default export is Null; JSONL export requires explicit host configuration.
  """
  alias AgentSystemsLab.Observability.{Buffer, Context}

  def emit(name, refs \\ %{}, measurements \\ %{}, opts \\ []) do
    try do
      handle = Keyword.get(opts, :buffer, Buffer.default_handle())
      Buffer.admit(handle, name, refs, measurements, opts)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  def stats(server \\ Buffer), do: Buffer.stats(server)
  def recent(server \\ Buffer), do: Buffer.recent(server)
  def metrics(server \\ Buffer), do: Buffer.metrics(server)
  def configure(opts), do: Buffer.configure(Buffer, opts)
  def configuration, do: Buffer.configuration()

  @doc "Host-only restart/discard of observation state; execution children are left alone."
  def restart do
    opts = Application.get_env(:agent_systems_lab, :observability_options, [])

    case Supervisor.terminate_child(AgentSystemsLab.Supervisor, Buffer) do
      result when result in [:ok, {:error, :not_found}] ->
        case Supervisor.start_child(AgentSystemsLab.Supervisor, {Buffer, opts}) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end

      error ->
        error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  @doc "Host-only bounded wait; never called by an execution boundary."
  def flush(server \\ Buffer, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_flush(server, deadline)
  end

  def span_start(name, refs, opts \\ []) do
    refs = Map.put_new(refs, :span_id, Context.span_id(name, refs))
    emit(name, refs, %{}, opts)
    %{name: name, refs: refs, opts: opts, monotonic_ms: System.monotonic_time(:millisecond)}
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  def span_stop(token, outcome, measurements \\ %{}) do
    try do
      name =
        Map.get(
          %{
            model_started: :model_stopped,
            tool_started: :tool_stopped,
            recovery_started: :recovery_stopped
          },
          token.name
        )

      duration = max(System.monotonic_time(:millisecond) - token.monotonic_ms, 0)

      emit(
        name,
        token.refs,
        Map.put(measurements, :duration_ms, duration),
        Keyword.put(token.opts, :outcome, outcome)
      )
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp await_flush(server, deadline) do
    state = stats(server)

    cond do
      state.buffer_entries == 0 and not state.inflight ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(5)
        await_flush(server, deadline)
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
