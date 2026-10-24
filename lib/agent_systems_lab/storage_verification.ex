defmodule AgentSystemsLab.StorageVerification do
  @moduledoc """
  Exercises real PostgreSQL commit boundaries by killing the calling process.

  The hook is a barrier, not a simulated exception. A separate connection reads
  the database while the writer is paused; the writer is then killed before it
  can acknowledge the request. No SQL Sandbox transaction surrounds these probes.
  Each probe deletes only the run it created, including its cascading children.
  """

  alias AgentSystemsLab.{Kernel, Repo, Storage}

  @timeout 10_000

  @doc "Runs create and dispatch probes on both sides of COMMIT."
  def run do
    with {:ok, create_before} <- crash_probe(:before_commit, :create),
         {:ok, dispatch_before} <- crash_probe(:before_commit, :dispatch),
         {:ok, create_after} <- crash_probe(:after_commit, :create),
         {:ok, dispatch_after} <- crash_probe(:after_commit, :dispatch) do
      {:ok,
       %{
         before_commit: %{
           visible: false,
           acknowledged: false,
           create: create_before,
           dispatch: dispatch_before
         },
         after_commit: %{
           visible: true,
           acknowledged: false,
           create: create_after,
           dispatch: dispatch_after
         },
         recovered: %{seq: dispatch_after.recovered_seq, pending_kind: "tool"}
       }}
    end
  end

  @doc """
  Runs one crash probe, returning the observations made by a separate DB client.

  Supported phases are `:before_commit` and `:after_commit`; operations are
  `:create` and `:dispatch`. A successful probe also checks recovery by replay and
  by attempting the same logical write with its original expected sequence.
  """
  def crash_probe(phase, operation)
      when phase in [:before_commit, :after_commit] and operation in [:create, :dispatch] do
    run_id = unique_run_id(phase, operation)

    try do
      verify_probe(run_id, phase, operation)
    rescue
      exception -> {:error, {:verification_exception, Exception.message(exception)}}
    after
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [run_id])
    end
  end

  defp verify_probe(run_id, phase, :create) do
    writer = fn hook ->
      Storage.create_run(run_id, "Observe the create boundary", max_turns: 7, hook: hook)
    end

    expected = if phase == :before_commit, do: counts(0, 0, 0, 0), else: counts(1, 1, 1, 1)

    with {:ok, observation} <- interrupt_at(writer, phase, run_id),
         :ok <- equal(observation.at_barrier, expected, :create_visibility_at_barrier),
         :ok <- equal(observation.after_kill, expected, :create_visibility_after_kill),
         :ok <- equal(observation.acknowledged, false, :create_acknowledged),
         :ok <- check_created_snapshot(run_id, phase),
         {:ok, recovered} <- recover_create(run_id, phase),
         :ok <- verify_replay(recovered) do
      {:ok,
       Map.merge(observation, %{
         phase: phase,
         operation: :create,
         visible: phase == :after_commit,
         recovered_seq: recovered.state.seq,
         recovered_kind: recovered.intent.kind
       })}
    end
  end

  defp verify_probe(run_id, phase, :dispatch) do
    command =
      {:model_response,
       {:call, %{operation_id: "observed-op", tool: "read_file", arguments: %{path: "note.txt"}}}}

    with {:ok, _initial} <- Storage.create_run(run_id, "Observe the transition boundary"),
         {:ok, observation} <-
           interrupt_at(
             fn hook -> Storage.dispatch(run_id, 1, command, hook: hook) end,
             phase,
             run_id
           ),
         expected = if(phase == :before_commit, do: counts(1, 1, 1, 1), else: counts(1, 2, 2, 1)),
         :ok <- equal(observation.at_barrier, expected, :dispatch_visibility_at_barrier),
         :ok <- equal(observation.after_kill, expected, :dispatch_visibility_after_kill),
         :ok <- equal(observation.acknowledged, false, :dispatch_acknowledged),
         {:ok, persisted} <- Storage.load(run_id),
         :ok <- check_dispatch_snapshot(persisted, phase),
         {:ok, recovered} <- recover_dispatch(run_id, phase, command),
         :ok <- verify_replay(recovered) do
      {:ok,
       Map.merge(observation, %{
         phase: phase,
         operation: :dispatch,
         visible: phase == :after_commit,
         persisted_seq: persisted.state.seq,
         recovered_seq: recovered.state.seq,
         recovered_kind: recovered.intent.kind
       })}
    end
  end

  defp interrupt_at(writer, phase, run_id) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn current_phase ->
          if current_phase == phase do
            send(parent, {ref, :barrier, current_phase, self()})

            receive do
              {^ref, :release} -> :ok
            end
          end
        end

        send(parent, {ref, :ack, writer.(hook)})
      end)

    try do
      receive do
        {^ref, :barrier, ^phase, ^pid} ->
          at_barrier = row_counts(run_id)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, ^pid, :killed} ->
              acknowledged =
                receive do
                  {^ref, :ack, _result} -> true
                after
                  0 -> false
                end

              {:ok,
               %{
                 at_barrier: at_barrier,
                 after_kill: row_counts(run_id),
                 acknowledged: acknowledged,
                 exit_reason: :killed
               }}
          after
            @timeout -> {:error, {:writer_did_not_exit, phase}}
          end

        {^ref, :ack, result} ->
          {:error, {:writer_returned_before_barrier, phase, result}}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, {:writer_exited_before_barrier, phase, reason}}
      after
        @timeout -> {:error, {:barrier_timeout, phase}}
      end
    after
      if Process.alive?(pid), do: Process.exit(pid, :kill)
      Process.demonitor(monitor, [:flush])
    end
  end

  defp check_created_snapshot(run_id, :before_commit),
    do: equal(Storage.load(run_id), {:error, :not_found}, :uncommitted_create)

  defp check_created_snapshot(run_id, :after_commit) do
    with {:ok, snapshot} <- Storage.load(run_id),
         :ok <- equal(snapshot.state.seq, 1, :committed_create_sequence),
         :ok <- equal(snapshot.state.max_turns, 7, :committed_create_options),
         :ok <- equal(snapshot.intent.kind, "model", :committed_create_intent) do
      verify_replay(snapshot)
    end
  end

  defp recover_create(run_id, :before_commit),
    do: Storage.create_run(run_id, "Observe the create boundary", max_turns: 7)

  defp recover_create(run_id, :after_commit) do
    with :ok <-
           equal(
             Storage.create_run(run_id, "retry"),
             {:error, {:already_exists, run_id}},
             :committed_create_retry
           ) do
      Storage.load(run_id)
    end
  end

  defp check_dispatch_snapshot(snapshot, phase) do
    {seq, status, kind} =
      if phase == :before_commit, do: {1, :running, "model"}, else: {2, :waiting_tool, "tool"}

    with :ok <- equal(snapshot.state.seq, seq, :dispatch_sequence),
         :ok <- equal(snapshot.state.status, status, :dispatch_status),
         :ok <- equal(snapshot.intent.kind, kind, :dispatch_intent) do
      verify_replay(snapshot)
    end
  end

  defp recover_dispatch(run_id, :before_commit, command),
    do: Storage.dispatch(run_id, 1, command)

  defp recover_dispatch(run_id, :after_commit, command) do
    with :ok <-
           equal(
             Storage.dispatch(run_id, 1, command),
             {:error, {:stale_sequence, 1, 2}},
             :committed_dispatch_retry
           ) do
      Storage.load(run_id)
    end
  end

  defp verify_replay(snapshot) do
    equal(
      Kernel.rebuild(snapshot.state.run_id, snapshot.events, max_turns: snapshot.state.max_turns),
      {:ok, snapshot.state},
      :recovered_replay
    )
  end

  defp row_counts(run_id) do
    %{rows: [[runs, events, intents, pending]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT
          (SELECT count(*) FROM lab_runs WHERE id = $1),
          (SELECT count(*) FROM lab_events WHERE run_id = $1),
          (SELECT count(*) FROM lab_intents WHERE run_id = $1),
          (SELECT count(*) FROM lab_intents WHERE run_id = $1 AND status = 'pending')
        """,
        [run_id]
      )

    counts(runs, events, intents, pending)
  end

  defp counts(runs, events, intents, pending),
    do: %{runs: runs, events: events, intents: intents, pending: pending}

  defp equal(actual, expected, _context) when actual == expected, do: :ok
  defp equal(actual, expected, context), do: {:error, {context, expected, actual}}

  defp unique_run_id(phase, operation),
    do:
      "l02-#{phase}-#{operation}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
end
