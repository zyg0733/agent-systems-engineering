defmodule AgentSystemsLab.Tools.MockTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Tools.Mock

  setup do
    server = start_supervised!(Mock)
    %{server: server}
  end

  test "100 concurrent retries create exactly one effect", %{server: server} do
    arguments = %{path: "answer.txt", content: "42"}

    results =
      1..100
      |> Task.async_stream(fn _ -> Mock.execute(server, "write-answer", arguments) end,
        max_concurrency: 100,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    receipt = %{operation_id: "write-answer", arguments: arguments, effect_index: 1}
    assert Enum.all?(results, &(&1 == {:ok, receipt}))
    assert Mock.stats(server) == %{requests: 100, effects: 1}
  end

  test "a conflicting ID fails without overwriting the original receipt", %{server: server} do
    assert {:ok, original} = Mock.execute(server, "op-1", %{value: 1})
    assert {:error, :operation_id_conflict} = Mock.execute(server, "op-1", %{value: 2})
    assert {:ok, ^original} = Mock.lookup(server, "op-1")
    assert Mock.stats(server) == %{requests: 2, effects: 1}
  end

  test "argument equality is strict", %{server: server} do
    assert {:ok, _} = Mock.execute(server, "op-1", %{value: 1})
    assert {:error, :operation_id_conflict} = Mock.execute(server, "op-1", %{value: 1.0})
  end

  test "a lost reply commits an effect that lookup and retry can reconcile", %{server: server} do
    arguments = %{value: "hello"}
    assert {:unknown, :receipt_lost} = Mock.execute(server, "op-1", arguments, response: :lost)
    assert Mock.stats(server) == %{requests: 1, effects: 1}

    assert {:ok, receipt} = Mock.lookup(server, "op-1")
    assert receipt == %{operation_id: "op-1", arguments: arguments, effect_index: 1}
    assert {:ok, ^receipt} = Mock.execute(server, "op-1", arguments)
    assert Mock.stats(server) == %{requests: 2, effects: 1}
  end

  test "failure before an effect leaves no receipt and can be retried", %{server: server} do
    assert {:error, :failed_before_effect} =
             Mock.execute(server, "op-1", %{}, response: :fail_before_effect)

    assert :not_found = Mock.lookup(server, "op-1")
    assert Mock.stats(server) == %{requests: 1, effects: 0}
    assert {:ok, %{effect_index: 1}} = Mock.execute(server, "op-1", %{})
    assert Mock.stats(server) == %{requests: 2, effects: 1}
  end

  test "repeated lost responses do not produce more effects", %{server: server} do
    for _ <- 1..3 do
      assert {:unknown, :receipt_lost} = Mock.execute(server, "op-1", %{}, response: :lost)
    end

    assert {:ok, %{effect_index: 1}} = Mock.lookup(server, "op-1")
    assert Mock.stats(server) == %{requests: 3, effects: 1}
  end

  test "a committed operation can be read back even with a before-effect fault", %{server: server} do
    assert {:ok, receipt} = Mock.execute(server, "op-1", %{})

    assert {:ok, ^receipt} =
             Mock.execute(server, "op-1", %{}, response: :fail_before_effect)

    assert Mock.stats(server) == %{requests: 2, effects: 1}
  end

  test "each instance owns an independent ledger and reset only clears its target", %{
    server: server
  } do
    other = start_supervised!({Mock, []}, id: :other_mock)
    assert {:ok, _} = Mock.execute(server, "op-1", %{value: "first"})
    assert :not_found = Mock.lookup(other, "op-1")
    assert {:ok, _} = Mock.execute(other, "op-1", %{value: "second"})
    assert :ok = Mock.reset(server)
    assert Mock.stats(server) == %{requests: 0, effects: 0}
    assert :not_found = Mock.lookup(server, "op-1")
    assert {:ok, %{arguments: %{value: "second"}}} = Mock.lookup(other, "op-1")
    assert Mock.stats(other) == %{requests: 1, effects: 1}
  end

  test "a caller may give an instance an explicit registered name" do
    named = start_supervised!({Mock, [name: __MODULE__]}, id: :named_mock)
    assert Process.whereis(__MODULE__) == named
    assert {:ok, %{operation_id: "op-1"}} = Mock.execute(__MODULE__, "op-1", %{})
    assert Mock.stats(__MODULE__) == %{requests: 1, effects: 1}
  end

  test "invalid input returns errors and leaves the server usable", %{server: server} do
    assert {:error, :invalid_operation_id} = Mock.execute(server, "", %{})
    assert {:error, :invalid_operation_id} = Mock.execute(server, :dynamic_name, %{})
    assert {:error, :invalid_arguments} = Mock.execute(server, "op-1", [])
    assert {:error, :invalid_options} = Mock.execute(server, "op-1", %{}, nil)
    assert {:error, :invalid_options} = Mock.execute(server, "op-1", %{}, [:lost])
    assert {:error, :invalid_options} = Mock.execute(server, "op-1", %{}, response: :ok, x: 1)

    assert {:error, :invalid_response_mode} =
             Mock.execute(server, "op-1", %{}, response: :unexpected)

    assert {:error, :invalid_operation_id} = Mock.lookup(server, nil)
    assert Mock.stats(server) == %{requests: 0, effects: 0}
    assert Process.alive?(server)
    assert {:ok, %{effect_index: 1}} = Mock.execute(server, "op-1", %{})
  end
end
