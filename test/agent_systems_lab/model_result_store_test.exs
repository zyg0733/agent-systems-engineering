defmodule AgentSystemsLab.ModelResultStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{
    Context,
    ContextStore,
    ModelResultStore,
    Recording,
    Repo,
    Session,
    Storage
  }

  alias AgentSystemsLab.Storage.Codec

  @moduletag :database

  setup do
    id = "model-result-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
    end)

    {:ok, initial} = Storage.create_run(id, "Repair without network")
    {:ok, session} = Session.new("session-#{id}", constraints: ["workspace only"])
    permissions = %{available_tools: ["mock"], write_allowed: false}
    {:ok, built} = Context.build(session, initial.state, permissions)
    {:ok, capture} = ContextStore.capture(initial.state, session, permissions, built)

    %{
      id: id,
      initial: initial,
      capture: capture,
      session: session,
      permissions: permissions,
      attrs: %{context_id: capture.id, provider: "scripted.v1", response: {:final, "done"}}
    }
  end

  test "accepted response, event, projection and model result share one commit", c do
    assert {:ok, snapshot} =
             Storage.dispatch(c.id, 1, {:model_response, c.attrs.response}, model_result: c.attrs)

    assert snapshot.state.status == :succeeded
    assert snapshot.intent == nil
    assert {:ok, [result]} = ModelResultStore.list(c.id)
    assert {:ok, ^result} = ModelResultStore.load(result.id)
    assert result.context_id == c.capture.id
    assert result.input_seq == 1
    assert result.event_seq == 2
    assert result.record.provider == "scripted.v1"
    assert result.record.response === c.attrs.response
    assert result.record.input_sha256 == Context.hash(c.capture.context)
    assert :ok = Recording.verify(result.record, c.capture.context)
  end

  test "tool and final outputs are ordered and retain exact argument types", c do
    response =
      {:call, %{operation_id: "first", tool: "mock", arguments: %{"key" => 1, atom: {:old, 2}}}}

    attrs = %{c.attrs | response: response}

    assert {:ok, _waiting} =
             Storage.dispatch(c.id, 1, {:model_response, response}, model_result: attrs)

    assert {:ok, running} = Storage.dispatch(c.id, 2, {:tool_result, "first", {:ok, "receipt"}})
    assert {:ok, built} = Context.build(c.session, running.state, c.permissions)
    assert {:ok, capture} = ContextStore.capture(running.state, c.session, c.permissions, built)
    final = %{c.attrs | context_id: capture.id}

    assert {:ok, _done} =
             Storage.dispatch(c.id, 3, {:model_response, final.response}, model_result: final)

    assert {:ok, [first, second]} = ModelResultStore.list(c.id)
    assert [first.event_seq, second.event_seq] == [2, 4]
    assert first.record.response === response
    assert second.record.response === {:final, "done"}
  end

  test "an exception before commit rolls back the response and result together", c do
    hook = fn :before_commit -> raise "before recorded result commit" end

    assert_raise RuntimeError, "before recorded result commit", fn ->
      Storage.dispatch(c.id, 1, {:model_response, c.attrs.response},
        model_result: c.attrs,
        hook: hook
      )
    end

    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state === c.initial.state
    assert snapshot.events === c.initial.events
    assert {:ok, [_capture]} = ContextStore.list(c.id)
  end

  test "an exception after commit retains the response and result together", c do
    hook = fn
      :before_commit -> :ok
      :after_commit -> raise "after recorded result commit"
    end

    assert_raise RuntimeError, "after recorded result commit", fn ->
      Storage.dispatch(c.id, 1, {:model_response, c.attrs.response},
        model_result: c.attrs,
        hook: hook
      )
    end

    assert {:ok, [result]} = ModelResultStore.list(c.id)
    assert result.event_seq == 2
    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state.status == :succeeded
  end

  for {stage, count, status} <- [
        {:before_commit, 0, :running},
        {:after_commit, 1, :succeeded}
      ] do
    test "caller killed at #{stage} preserves the result transaction boundary", c do
      stage = unquote(stage)
      parent = self()
      ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          hook = fn reached ->
            if reached == stage do
              send(parent, {ref, :at_boundary, self()})

              receive do
                {^ref, :release} -> :ok
              end
            end
          end

          result =
            Storage.dispatch(c.id, 1, {:model_response, c.attrs.response},
              model_result: c.attrs,
              hook: hook
            )

          send(parent, {ref, :acknowledged, result})
        end)

      assert_receive {^ref, :at_boundary, ^pid}, 5_000

      # Ordinary result-row visibility does not wait on the run's write lock.
      # Fully verifying a loaded result acquires the shared run lock, so do that
      # after killing the transaction owner and observing its rollback/commit.
      assert %{rows: [[unquote(count)]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT COUNT(*) FROM lab_model_results WHERE run_id = $1",
                 [c.id]
               )

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      refute_received {^ref, :acknowledged, _result}
      assert {:ok, records} = ModelResultStore.list(c.id)
      assert length(records) == unquote(count)
      assert {:ok, snapshot} = Storage.load(c.id)
      assert snapshot.state.status == unquote(status)
      assert length(snapshot.events) == unquote(count) + 1
    end
  end

  test "wrong input capture rejects and rolls back the entire transition", c do
    other_id = "#{c.id}-other"
    assert {:ok, other} = Storage.create_run(other_id, "other input")
    assert {:ok, built} = Context.build(c.session, other.state, c.permissions)
    assert {:ok, capture} = ContextStore.capture(other.state, c.session, c.permissions, built)

    assert {:error, :model_result_input_binding_mismatch} =
             Storage.dispatch(c.id, 1, {:model_response, c.attrs.response},
               model_result: %{c.attrs | context_id: capture.id}
             )

    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state === c.initial.state
    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "record metadata and candidates must match the accepted command", c do
    for attrs <- [
          %{c.attrs | response: {:final, "different"}},
          Map.put(c.attrs, :extra, true),
          nil,
          %{c.attrs | context_id: nil},
          %{c.attrs | provider: false}
        ] do
      assert {:error, _reason} =
               Storage.dispatch(c.id, 1, {:model_response, c.attrs.response}, model_result: attrs)
    end

    assert {:error, _reason} = Storage.dispatch(c.id, 1, {:cancel, "stop"}, model_result: c.attrs)
    assert {:ok, []} = ModelResultStore.list(c.id)
    assert {:ok, snapshot} = Storage.load(c.id)
    assert snapshot.state === c.initial.state
  end

  test "internal insertion refuses a detached write and an event not yet inserted", c do
    assert {:ok, _next, events} =
             AgentSystemsLab.Kernel.dispatch(c.initial.state, {:model_response, c.attrs.response})

    assert {:error, :model_result_requires_transition_transaction} =
             ModelResultStore.insert_for_transition(Repo, c.initial.state, events, c.attrs)

    assert {:ok, {:error, :model_result_event_not_inserted}} =
             Repo.transaction(fn ->
               ModelResultStore.insert_for_transition(Repo, c.initial.state, events, c.attrs)
             end)

    assert {:ok, []} = ModelResultStore.list(c.id)
  end

  test "altered response with a recomputed hash still fails actual event binding", c do
    result = commit(c)

    forged = %{
      result.record
      | response: {:final, "forged"},
        response_sha256: Context.hash({:final, "forged"})
    }

    update_record(result.id, forged)

    assert {:error, {:corrupt_model_result, :model_result_event_mismatch}} =
             ModelResultStore.load(result.id)
  end

  test "future response and envelope versions are rejected independently of codec", c do
    result = commit(c)

    for value <- [2, nil, false, 1.0] do
      update_record(result.id, %{result.record | schema_version: value})

      assert {:error, {:corrupt_model_result, {:unsupported_model_schema_version, ^value}}} =
               ModelResultStore.load(result.id)

      update_record(result.id, %{result.record | version: value})

      assert {:error, {:corrupt_model_result, {:unsupported_recording_version, ^value}}} =
               ModelResultStore.load(result.id)
    end
  end

  test "changed row metadata and input hashes fail verification", c do
    result = commit(c)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_model_results SET provider = 'other.v1' WHERE id::text = $1",
      [result.id]
    )

    assert {:error, {:corrupt_model_result, :model_result_metadata_mismatch}} =
             ModelResultStore.load(result.id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_model_results SET provider = 'scripted.v1' WHERE id::text = $1",
      [result.id]
    )

    update_record(result.id, %{result.record | input_sha256: String.duplicate("0", 64)})

    assert {:error, {:corrupt_model_result, :recorded_input_mismatch}} =
             ModelResultStore.load(result.id)
  end

  test "internally consistent but forged input sources fail the actual history prefix", c do
    result = commit(c)
    forged_run = %{c.initial.state | input: "rewritten input"}
    assert {:ok, built} = Context.build(c.session, forged_run, c.permissions)
    sources = %{c.capture.sources | "run" => forged_run}
    assert {:ok, sources_data} = Codec.encode(sources)
    assert {:ok, payload_data} = Codec.encode(built.context)
    assert {:ok, manifest_data} = Codec.encode(built.manifest)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_contexts SET sources_data=$2, payload_data=$3, manifest_data=$4 WHERE id::text=$1",
      [c.capture.id, sources_data, payload_data, manifest_data]
    )

    update_record(result.id, %{result.record | input_sha256: Context.hash(built.context)})
    assert {:ok, _internally_valid_capture} = ContextStore.load(c.capture.id)

    assert {:error, {:corrupt_model_result, :model_result_input_binding_mismatch}} =
             ModelResultStore.load(result.id)
  end

  test "missing records and invalid IDs are explicit and Run deletion cascades", c do
    assert {:error, :invalid_model_result_id} = ModelResultStore.load("invalid")
    assert {:error, :model_result_not_found} = ModelResultStore.load(Ecto.UUID.generate())
    assert {:error, :invalid_run_id} = ModelResultStore.list(false)
    assert {:ok, []} = ModelResultStore.list("missing")
    result = commit(c)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [c.id])
    assert {:error, :model_result_not_found} = ModelResultStore.load(result.id)
  end

  defp commit(c) do
    assert {:ok, _snapshot} =
             Storage.dispatch(c.id, 1, {:model_response, c.attrs.response}, model_result: c.attrs)

    assert {:ok, [result]} = ModelResultStore.list(c.id)
    result
  end

  defp update_record(id, record) do
    assert {:ok, data} = Codec.encode(record)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_model_results SET record_data = $2 WHERE id::text = $1",
      [id, data]
    )
  end
end
