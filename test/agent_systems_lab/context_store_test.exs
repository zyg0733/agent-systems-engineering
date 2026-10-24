defmodule AgentSystemsLab.ContextStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Context, ContextStore, Repo, Session, SessionStore, Storage}
  alias AgentSystemsLab.Storage.Codec

  @moduletag :database

  setup do
    suffix = "#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"
    run_id = "context-store-#{suffix}"
    session_id = "context-session-#{suffix}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [run_id])
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_sessions WHERE id = $1", [session_id])
    end)

    {:ok, snapshot} = Storage.create_run(run_id, "Repair the fixture")

    {:ok, session} =
      Session.new(session_id,
        facts: %{"task" => "repair shipping", "expected" => 4},
        acceptance: ["4/4 cases"],
        constraints: ["workspace only"]
      )

    {:ok, session} = Session.append(session, "user", "Preserve the working cases")
    permissions = %{available_tools: [], executor: "mock", write_allowed: false}
    {:ok, built} = Context.build(session, snapshot.state, permissions)

    %{
      run: snapshot.state,
      run_id: run_id,
      session_id: session_id,
      session: session,
      permissions: permissions,
      built: built
    }
  end

  test "capture commits complete input sources, payload, and independently verifiable manifest",
       c do
    assert {:ok, capture} = ContextStore.capture(c.run, c.session, c.permissions, c.built)
    assert {:ok, ^capture} = ContextStore.load(capture.id)
    assert capture.run_id == c.run_id
    assert capture.run_seq == c.run.seq
    assert capture.session_id == nil
    assert capture.session_version == c.session.version
    assert capture.context == c.built.context
    assert capture.manifest == c.built.manifest
    assert capture.sources["session"] == Session.to_map(c.session)
    assert capture.sources["run"] == c.run
    assert capture.sources["permissions"] == c.permissions
    assert {:ok, [^capture]} = ContextStore.list(c.run_id)
    assert {:error, :session_not_found} = SessionStore.load(c.session_id)
  end

  test "explicit Sessions are locked and checked against the exact canonical version", c do
    assert {:ok, _session} = SessionStore.create(c.session)

    assert {:ok, capture} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built,
               session_id: c.session_id
             )

    assert capture.session_id == c.session_id

    assert {:ok, _newer} =
             SessionStore.append(c.session_id, c.session.version, "note", "newer message")

    assert {:error, {:stale_session_version, 1, 2}} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built,
               session_id: c.session_id
             )

    # The old committed capture remains independently reconstructable after append.
    assert {:ok, ^capture} = ContextStore.load(capture.id)
    assert {:ok, [^capture]} = ContextStore.list(c.run_id)
  end

  test "same-version but altered Session sources are refused", c do
    assert {:ok, _session} = SessionStore.create(c.session)
    forged = %{c.session | constraints: []}
    assert {:ok, built} = Context.build(forged, c.run, c.permissions)

    assert {:error, :session_snapshot_mismatch} =
             ContextStore.capture(c.run, forged, c.permissions, built, session_id: c.session_id)

    assert {:ok, []} = ContextStore.list(c.run_id)
  end

  test "persisted Session binding cannot be silently removed from capture metadata", c do
    assert {:ok, _session} = SessionStore.create(c.session)

    assert {:ok, capture} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built,
               session_id: c.session_id
             )

    assert capture.sources["persisted_session_id"] == c.session_id

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_contexts SET session_id = NULL WHERE id::text = $1",
      [capture.id]
    )

    assert {:error, {:corrupt_context, :metadata_mismatch}} = ContextStore.load(capture.id)
  end

  test "stale or altered Run projections cannot be published as model input", c do
    assert {:ok, current} =
             Storage.dispatch(c.run_id, c.run.seq, {:model_response, {:final, "done"}})

    assert {:error, {:stale_sequence, 1, 2}} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built)

    forged = %{current.state | input: "rewritten"}
    assert {:ok, built} = Context.build(c.session, forged, c.permissions)

    assert {:error, :run_snapshot_mismatch} =
             ContextStore.capture(forged, c.session, c.permissions, built)

    assert {:ok, []} = ContextStore.list(c.run_id)
  end

  test "forged payloads and manifests are refused before insert", c do
    forged_payload = %{
      c.built
      | context: Map.put(c.built.context, :permissions, %{available_tools: ["write_file"]})
    }

    forged_manifest = %{c.built | manifest: Map.put(c.built.manifest, :payload_sha256, "forged")}

    for built <- [forged_payload, forged_manifest, %{}, nil] do
      assert {:error, :context_mismatch} =
               ContextStore.capture(c.run, c.session, c.permissions, built)
    end

    assert {:ok, []} = ContextStore.list(c.run_id)
  end

  test "saved payload corruption is detected without executing tools or Provider", c do
    assert {:ok, capture} = ContextStore.capture(c.run, c.session, c.permissions, c.built)
    assert {:ok, forged} = Codec.encode(%{capture.context | input: "forged"})
    set_field(capture.id, "payload_data", forged)
    assert {:error, {:corrupt_context, :context_mismatch}} = ContextStore.load(capture.id)
    assert {:error, {:corrupt_context, :context_mismatch}} = ContextStore.list(c.run_id)
  end

  test "saved manifest, source, and metadata corruption fail reconstruction", c do
    assert {:ok, capture} = ContextStore.capture(c.run, c.session, c.permissions, c.built)
    assert {:ok, forged} = Codec.encode(%{capture.manifest | preserved: %{permissions: false}})
    set_field(capture.id, "manifest_data", forged)
    assert {:error, {:corrupt_context, :context_mismatch}} = ContextStore.load(capture.id)
    assert {:ok, original} = Codec.encode(capture.manifest)
    set_field(capture.id, "manifest_data", original)

    assert {:ok, forged} =
             Codec.encode(%{
               capture.sources
               | "permissions" => %{available_tools: ["write_file"]}
             })

    set_field(capture.id, "sources_data", forged)
    assert {:error, {:corrupt_context, :context_mismatch}} = ContextStore.load(capture.id)
    assert {:ok, original} = Codec.encode(capture.sources)
    set_field(capture.id, "sources_data", original)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE lab_contexts SET run_seq = run_seq + 1 WHERE id::text = $1",
      [capture.id]
    )

    assert {:error, {:corrupt_context, :metadata_mismatch}} = ContextStore.load(capture.id)
  end

  test "compressed capture preserves canonical Session and all protected facts", c do
    session =
      Enum.reduce(1..12, c.session, fn _index, session ->
        {:ok, next} = Session.append(session, "note", String.duplicate("old narrative ", 100))
        next
      end)

    opts = [max_context_bytes: 2_500, keep_recent_messages: 1, max_summary_bytes: 700]
    assert {:ok, built} = Context.build(session, c.run, c.permissions, opts)
    assert built.manifest.messages.omitted != []
    assert {:ok, _session} = SessionStore.create(session)

    assert {:ok, capture} =
             ContextStore.capture(c.run, session, c.permissions, built,
               session_id: c.session_id,
               context_options: opts
             )

    assert {:ok, ^capture} = ContextStore.load(capture.id)
    assert capture.context.task.facts == session.facts
    assert capture.context.task.constraints == session.constraints
    assert capture.context.permissions == c.permissions
    assert capture.context.operations == c.run.operations
    assert {:ok, ^session} = SessionStore.load(c.session_id)
  end

  test "exceptions before commit roll back input capture and after commit preserve it", c do
    before_hook = fn
      :before_commit -> raise "before context commit"
      :after_commit -> :ok
    end

    assert_raise RuntimeError, "before context commit", fn ->
      ContextStore.capture(c.run, c.session, c.permissions, c.built, hook: before_hook)
    end

    assert {:ok, []} = ContextStore.list(c.run_id)

    after_hook = fn
      :before_commit -> :ok
      :after_commit -> raise "after context commit"
    end

    assert_raise RuntimeError, "after context commit", fn ->
      ContextStore.capture(c.run, c.session, c.permissions, c.built, hook: after_hook)
    end

    assert {:ok, [capture]} = ContextStore.list(c.run_id)
    assert capture.context == c.built.context
  end

  for {stage, count} <- [before_commit: 0, after_commit: 1] do
    test "killing capture caller at #{stage} preserves the actual commit boundary", c do
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

          result = ContextStore.capture(c.run, c.session, c.permissions, c.built, hook: hook)
          send(parent, {ref, :acknowledged, result})
        end)

      assert_receive {^ref, :at_boundary, ^pid}, 5_000
      assert {:ok, visible} = ContextStore.list(c.run_id)
      assert length(visible) == unquote(count)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
      refute_received {^ref, :acknowledged, _result}
      assert {:ok, ^visible} = ContextStore.list(c.run_id)
    end
  end

  test "nested write transactions and malformed options are rejected", c do
    assert {:ok, {:error, :nested_transaction_not_supported}} =
             Repo.transaction(fn ->
               ContextStore.capture(c.run, c.session, c.permissions, c.built)
             end)

    for opts <- [
          [unknown: true],
          [session_id: false],
          [hook: :invalid],
          [session_id: nil, session_id: nil],
          nil
        ] do
      assert {:error, _reason} =
               ContextStore.capture(c.run, c.session, c.permissions, c.built, opts)
    end

    assert {:error, :session_not_found} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built,
               session_id: c.session_id
             )

    assert {:error, :invalid_context_id} = ContextStore.load("invalid uuid")
    assert {:error, :context_not_found} = ContextStore.load(Ecto.UUID.generate())
    assert {:ok, []} = ContextStore.list(c.run_id)
  end

  test "deleting a Run cascades its captures without deleting its independent Session", c do
    assert {:ok, _session} = SessionStore.create(c.session)

    assert {:ok, capture} =
             ContextStore.capture(c.run, c.session, c.permissions, c.built,
               session_id: c.session_id
             )

    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_runs WHERE id = $1", [c.run_id])
    assert {:error, :context_not_found} = ContextStore.load(capture.id)
    assert {:ok, session} = SessionStore.load(c.session_id)
    assert session == c.session
  end

  defp set_field(id, field, value)
       when field in ["payload_data", "manifest_data", "sources_data"] do
    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_contexts SET #{field} = $2 WHERE id::text = $1", [
      id,
      value
    ])
  end
end
