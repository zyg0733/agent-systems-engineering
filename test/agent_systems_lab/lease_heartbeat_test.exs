defmodule AgentSystemsLab.LeaseHeartbeatTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{IntentStore, Recovery, RecoveryStore, Repo, Scheduler}
  @moduletag :database

  setup do
    id = "heartbeat-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
    on_exit(fn -> Repo.query!("DELETE FROM lab_runs WHERE id=$1", [id]) end)
    assert {:ok, _} = Recovery.create_run(id, "heartbeat proof", script: [{:final, "done"}])
    %{id: id}
  end

  test "a lease that expires between verification and the renewal write cannot be revived", c do
    assert {:ok, old} = IntentStore.claim(c.id, "original", lease_ms: 180)

    assert {:error, :claim_expired} =
             IntentStore.renew(old,
               lease_ms: 5_000,
               hook: fn
                 :before_renew_write -> wait_expiry(old)
                 _ -> :ok
               end
             )

    assert {:ok, after_expiry} = Recovery.load(c.id)
    assert after_expiry.intent.claim_expires_at == old.expires_at
    assert after_expiry.intent.claim_generation == old.generation
    assert {:ok, current} = IntentStore.claim(c.id, "replacement")
    assert current.generation == old.generation + 1
    assert {:error, :stale_claim} = IntentStore.renew(old)
    assert :ok = IntentStore.release(current)
  end

  test "replayed and obsolete ticks cannot multiply the independent heartbeat loop", c do
    scheduler = start_scheduler(c.id, lease_ms: 2_000, renew_interval_ms: 400)
    assert_receive {:heartbeat_gate, executor}, 2_000
    [%{worker: worker}] = Scheduler.status(scheduler).active
    original = :sys.get_state(worker)
    send(worker, {:renew, original.renew_token})
    assert eventually(fn -> Scheduler.status(scheduler).counters.renewed == 1 end)

    for _ <- 1..100 do
      send(worker, {:renew, original.renew_token})
      send(worker, {:renew, make_ref()})
      send(worker, :renew)
    end

    after_replay = :sys.get_state(worker)
    assert after_replay.renewals == 1
    assert after_replay.renew_token != original.renew_token

    [%{heartbeat: heartbeat, heartbeat_age_ms: age, claim: renewed}] =
      Scheduler.status(scheduler).active

    assert heartbeat.sequence == 1
    assert heartbeat.duration_ms >= 0
    assert age >= 0
    assert heartbeat.lease_expires_at == renewed.expires_at
    assert eventually(fn -> Scheduler.status(scheduler).counters.renewed >= 2 end)
    assert Scheduler.status(scheduler).counters.renewed <= 3
    send(executor, :continue)

    assert eventually(fn ->
             match?({:ok, %{state: %{status: :succeeded}}}, Recovery.load(c.id))
           end)
  end

  test "a resumed heartbeat loses to a live same-sequence successor and stops its executor", c do
    scheduler = start_scheduler(c.id, lease_ms: 220, renew_interval_ms: 40)
    assert_receive {:heartbeat_gate, executor}, 2_000
    [%{worker: worker, claim: old}] = Scheduler.status(scheduler).active
    assert :ok = :sys.suspend(worker)
    on_exit(fn -> if Process.alive?(worker), do: :sys.resume(worker) end)

    # Suspension stops the Worker mailbox, but a renewal already dispatched to
    # its database helper can still commit a later expiry. Observe that outcome
    # before waiting for the persisted lease, retaining the old token/generation.
    if renewal = :sys.get_state(worker).renewal do
      renewal_monitor = Process.monitor(renewal.pid)
      assert_receive {:DOWN, ^renewal_monitor, :process, _, _}, 2_000
    end

    assert {:ok, paused} = Recovery.load(c.id)
    assert paused.intent.claim_token == old.token
    assert paused.intent.claim_generation == old.generation
    wait_expiry(%{old | expires_at: paused.intent.claim_expires_at})
    assert {:ok, replacement} = IntentStore.claim(c.id, "replacement", lease_ms: 5_000)
    assert replacement.seq == old.seq
    assert {:ok, protected} = Recovery.load(c.id)
    monitor = Process.monitor(executor)
    assert :ok = :sys.resume(worker)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 2_000
    assert eventually(fn -> Scheduler.status(scheduler).active == [] end)

    assert Enum.any?(
             Scheduler.status(scheduler).errors,
             &String.contains?(&1.reason, "lease_lost")
           )

    assert :ok = Scheduler.stop(scheduler)
    assert {:ok, unchanged} = Recovery.load(c.id)
    assert unchanged === protected
    assert :ok = IntentStore.release(replacement)
  end

  defp start_scheduler(id, extra) do
    parent = self()

    hook = fn
      :after_input ->
        send(parent, {:heartbeat_gate, self()})
        receive do: (:continue -> :ok)

      _ ->
        :ok
    end

    assert {:ok, pid} =
             Scheduler.start_link(
               [
                 run_ids: [id],
                 max_workers: 1,
                 poll_interval_ms: 20,
                 recovery_options: [hook: hook]
               ] ++ extra
             )

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: Scheduler.stop(pid) end)
    pid
  end

  defp wait_expiry(claim) do
    remaining = DateTime.to_unix(claim.expires_at, :millisecond) - RecoveryStore.now_ms() + 5

    if remaining > 0 do
      Process.sleep(remaining)
      wait_expiry(claim)
    end
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 2_000)

  defp eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        eventually(fun, deadline)

      true ->
        false
    end
  end
end
