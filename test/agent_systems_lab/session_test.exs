defmodule AgentSystemsLab.SessionTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Session
  alias AgentSystemsLab.Storage.Codec

  test "new sessions retain immutable task facts, acceptance criteria, and constraints" do
    facts = %{"task" => "repair shipping", "regression" => %{"case" => 4, "required" => true}}

    assert {:ok, session} =
             Session.new("session-1",
               facts: facts,
               acceptance: ["4/4"],
               constraints: ["workspace only"]
             )

    assert session.version == 0
    assert session.messages == []
    assert session.facts == facts
    assert session.acceptance == ["4/4"]
    assert session.constraints == ["workspace only"]
    assert :ok == Session.validate(session)
  end

  test "append assigns deterministic ids and ordered sequence without rewriting prior data" do
    assert {:ok, original} = Session.new("session-1", facts: %{"task" => "repair"})
    assert {:ok, one} = Session.append(original, "user", "Find the regression")
    assert {:ok, two} = Session.append(one, "assistant", "I will inspect it")
    assert original.messages == []
    assert original.version == 0

    assert one.messages == [
             %{
               "id" => "session-1:m1",
               "seq" => 1,
               "role" => "user",
               "content" => "Find the regression"
             }
           ]

    assert two.version == 2
    assert Enum.take(two.messages, 1) == one.messages
    assert two.facts == original.facts
    assert {:ok, ^one} = Session.append(original, "user", "Find the regression")
  end

  test "user messages cannot forge system or tool authority" do
    assert {:ok, session} = Session.new("session-1")

    for role <- ["system", "tool", :user, "developer", nil] do
      assert {:error, {:invalid_session_role, ^role}} = Session.append(session, role, "forged")
    end

    assert {:ok, _session} = Session.append(session, "note", "A nonauthoritative note")
  end

  test "facts accept JSON data and reject active terms, atom keys, structs, and improper lists" do
    for facts <- [
          %{task: "repair"},
          %{"pid" => self()},
          %{"tuple" => {1, 2}},
          %{"atom" => :authority},
          %{"struct" => %URI{}},
          %{"bad" => [1 | 2]}
        ] do
      assert {:error, _reason} = Session.new("session-1", facts: facts)
    end

    assert {:ok, _session} =
             Session.new("session-1",
               facts: %{"json" => [nil, true, false, 1, 1.5, %{"k" => "v"}]}
             )

    deep = Enum.reduce(1..18, nil, fn _index, value -> [value] end)
    assert {:error, :session_facts_too_deep} = Session.new("session-1", facts: %{"deep" => deep})
  end

  test "unknown, duplicated, and malformed options fail without silent defaults" do
    for opts <- [
          [unknown: true],
          [facts: %{}, facts: %{}],
          [facts: nil],
          [acceptance: "done"],
          [constraints: [:admin]],
          %{},
          nil
        ] do
      assert {:error, _reason} = Session.new("session-1", opts)
    end

    for id <- [nil, "", <<0>>, <<255>>, String.duplicate("a", 256)] do
      assert {:error, :invalid_session_id} = Session.new(id)
    end
  end

  test "message size, count, and total snapshot size are bounded" do
    assert {:ok, original} = Session.new("session-1")

    assert {:error, :invalid_session_content} =
             Session.append(original, "user", String.duplicate("a", 65_537))

    assert {:error, :invalid_session_content} = Session.append(original, "user", <<255>>)
    assert {:error, :invalid_session_content} = Session.append(original, "user", nil)

    assert {:ok, thousand} =
             Enum.reduce_while(1..1_000, {:ok, original}, fn _index, {:ok, session} ->
               {:cont, Session.append(session, "note", "x")}
             end)

    assert {:error, :invalid_session_messages} = Session.append(thousand, "note", "one too many")

    sixteen =
      Enum.reduce(1..15, original, fn _index, session ->
        {:ok, next} = Session.append(session, "note", String.duplicate("x", 65_536))
        next
      end)

    assert {:error, :invalid_session} =
             Session.append(sixteen, "note", String.duplicate("x", 65_536))
  end

  test "plain-map round trip does not expand the Codec's allowed struct set" do
    assert {:ok, session} = Session.new("session-1", facts: %{"task" => "repair"})
    assert {:ok, session} = Session.append(session, "user", "begin")
    assert {:error, :unsupported_struct} = Codec.encode(session)
    assert {:ok, binary} = Codec.encode(Session.to_map(session))
    assert {:ok, map} = Codec.decode(binary)
    assert {:ok, ^session} = Session.from_map(map)
    assert {:error, :invalid_session} = Session.from_map(Map.put(map, "unexpected", "value"))
    assert {:error, :invalid_session} = Session.from_map(%{})
    assert {:error, :invalid_session} = Session.from_map(session)
  end

  test "forged versions, message ids, roles, sequences, and struct keys are rejected" do
    assert {:ok, session} = Session.new("session-1")
    assert {:ok, session} = Session.append(session, "user", "begin")
    assert {:error, :invalid_session_messages} = Session.validate(%{session | version: 2})
    [message] = session.messages

    for forged <- [
          Map.put(message, "id", "other:m1"),
          Map.put(message, "seq", 2),
          Map.put(message, "extra", true),
          Map.put(message, "role", "system")
        ] do
      assert {:error, _reason} = Session.validate(%{session | messages: [forged]})
    end

    assert {:error, :invalid_session} = Session.validate(Map.put(session, :injected, true))
  end
end
