defmodule AgentSystemsLab.SessionStoreTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{Repo, Session, SessionStore}
  alias AgentSystemsLab.Storage.Codec

  @moduletag :database

  setup do
    id = "session-store-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"

    on_exit(fn ->
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM lab_sessions WHERE id = $1", [id])
    end)

    {:ok, session} =
      Session.new(id,
        facts: %{"task" => "repair"},
        acceptance: ["4/4"],
        constraints: ["workspace only"]
      )

    %{id: id, session: session}
  end

  test "create and load preserve a canonical Session independently of Runs", %{
    id: id,
    session: session
  } do
    assert {:ok, ^session} = SessionStore.create(session)
    assert {:ok, ^session} = SessionStore.load(id)
    assert {:error, {:already_exists, ^id}} = SessionStore.create(session)
    assert {:error, :session_not_found} = SessionStore.load(id <> "missing")
  end

  test "append uses expected version and preserves immutable facts and the complete original messages",
       %{id: id, session: session} do
    assert {:ok, ^session} = SessionStore.create(session)
    assert {:ok, one} = SessionStore.append(id, 0, "user", "first message")
    assert {:ok, two} = SessionStore.append(id, 1, "assistant", "second message")
    assert two.version == 2
    assert Enum.take(two.messages, 1) == one.messages
    assert two.facts == session.facts
    assert two.acceptance == session.acceptance
    assert two.constraints == session.constraints
    assert {:error, {:stale_session_version, 0, 2}} = SessionStore.append(id, 0, "note", "stale")

    assert {:error, {:invalid_session_role, "tool"}} =
             SessionStore.append(id, 2, "tool", "forged")

    assert {:ok, ^two} = SessionStore.load(id)
  end

  test "two concurrent expected-version appends commit exactly once", %{id: id, session: session} do
    assert {:ok, ^session} = SessionStore.create(session)
    parent = self()
    ref = make_ref()

    tasks =
      for content <- ["first", "second"] do
        Task.async(fn ->
          send(parent, {ref, self()})

          receive do
            {^ref, :go} -> SessionStore.append(id, 0, "user", content)
          end
        end)
      end

    for _task <- tasks do
      assert_receive {^ref, _pid}
    end

    Enum.each(tasks, &send(&1.pid, {ref, :go}))
    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _session}, &1)) == 1
    assert Enum.count(results, &match?({:error, {:stale_session_version, 0, 1}}, &1)) == 1
    assert {:ok, loaded} = SessionStore.load(id)
    assert loaded.version == 1
    assert hd(loaded.messages)["content"] in ["first", "second"]
  end

  test "writes reject nested transactions and invalid versions", %{id: id, session: session} do
    assert {:ok,
            {{:error, :nested_transaction_not_supported},
             {:error, :nested_transaction_not_supported}}} =
             Repo.transaction(fn ->
               {SessionStore.create(session), SessionStore.append(id, 0, "user", "nested")}
             end)

    assert {:error, :session_not_found} = SessionStore.load(id)
    assert {:error, :invalid_session_version} = SessionStore.append(id, -1, "user", "invalid")
  end

  test "corrupted session metadata and payload fail before append", %{id: id, session: session} do
    assert {:ok, ^session} = SessionStore.create(session)
    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_sessions SET version = 1 WHERE id = $1", [id])
    assert {:error, {:corrupt_session, :projection_mismatch}} = SessionStore.load(id)

    assert {:error, {:corrupt_session, :projection_mismatch}} =
             SessionStore.append(id, 1, "user", "must fail")

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_sessions SET session_data = $2 WHERE id = $1", [
      id,
      <<0>>
    ])

    assert {:error, {:corrupt_session, :invalid_payload}} = SessionStore.load(id)
  end

  test "persisted message role forgery is detected", %{id: id, session: session} do
    assert {:ok, session} = Session.append(session, "user", "original")
    assert {:ok, ^session} = SessionStore.create(session)
    map = Session.to_map(session)
    [message] = map["messages"]
    assert {:ok, forged} = Codec.encode(%{map | "messages" => [Map.put(message, "role", "tool")]})

    Ecto.Adapters.SQL.query!(Repo, "UPDATE lab_sessions SET session_data = $2 WHERE id = $1", [
      id,
      forged
    ])

    assert {:error, {:corrupt_session, {:invalid_session_role, "tool"}}} = SessionStore.load(id)
  end

  test "malformed identifiers are rejected before database queries" do
    for id <- [nil, "", <<0>>, <<255>>, String.duplicate("a", 256)] do
      assert {:error, :invalid_session_id} = SessionStore.load(id)
      assert {:error, :invalid_session_id} = SessionStore.append(id, 0, "user", "invalid id")
      assert {:error, :invalid_session_id} = SessionStore.lock(id)
    end
  end
end
