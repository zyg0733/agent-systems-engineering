defmodule AgentSystemsLab.DurableRetryToolsTest do
  use ExUnit.Case, async: false

  alias AgentSystemsLab.{DurableTools, IntentStore, Repo, Storage}
  alias AgentSystemsLab.Tools.Result

  @moduletag :database

  setup do
    id = "retry-tools-#{System.unique_integer([:positive])}-#{System.system_time(:microsecond)}"
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    root = Path.join(base, id)
    File.mkdir_p!(root)

    on_exit(fn ->
      Repo.query!("DELETE FROM lab_runs WHERE id LIKE $1", ["#{id}%"])
      File.rm_rf!(root)
    end)

    %{id: id, root: root}
  end

  test "only safe confirmed transient failures are retried, preserving earlier receipts", c do
    {claim, operation} = waiting(c.id)

    for attempt <- 1..2 do
      assert {:ok, {:error, receipt}} =
               DurableTools.execute(claim, operation,
                 retry_failed: true,
                 transient_failures: 2,
                 attempt: attempt
               )

      assert receipt.output == %{kind: "transient", reason: "unavailable", effect: "none"}
      assert DurableTools.stats(c.id).effects == 0
    end

    assert {:ok, {:ok, receipt} = confirmed} =
             DurableTools.execute(claim, operation,
               retry_failed: true,
               transient_failures: 2,
               attempt: 3
             )

    assert receipt.output.effect_index == 1

    assert {:ok, ^confirmed} =
             DurableTools.execute(claim, operation,
               retry_failed: true,
               transient_failures: 99,
               attempt: 4
             )

    assert DurableTools.stats(c.id) == %{effects: 1, attempts: 4, operations: 1}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert Enum.map(record.attempts, &elem(&1.result, 0)) == [:error, :error, :ok, :ok]
    assert Enum.all?(record.attempts, &(&1.outcome == "completed"))
  end

  test "default delivery reuses transient errors and retry never grants unqueryable effects", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, first} = DurableTools.execute(claim, operation, transient_failures: 1)
    assert {:ok, ^first} = DurableTools.execute(claim, operation, attempt: 2)

    assert {:ok, ^first} =
             DurableTools.execute(claim, operation,
               retry_failed: true,
               mock_mode: :unqueryable,
               attempt: 3
             )

    assert DurableTools.stats(c.id).effects == 0
  end

  test "an arbitrary error and operator evidence are never retry permissions", c do
    {claim, operation} = waiting(c.id)

    assert {:ok, first} =
             DurableTools.execute(claim, operation, mock_response: :fail_before_effect)

    assert {:ok, ^first} = DurableTools.execute(claim, operation, retry_failed: true, attempt: 2)
    assert DurableTools.stats(c.id).effects == 0

    {claim2, operation2} = waiting(c.id <> "-manual")
    stop_at(claim2, operation2, :after_prepare)

    invented =
      Result.wrap(
        {:error, %{kind: "transient", reason: "unavailable", effect: "none"}},
        operation2.operation_id,
        operation2.tool
      )

    assert {:ok, ^invented} =
             DurableTools.confirm(
               claim2,
               operation2,
               invented,
               "An operator supplied this result."
             )

    assert {:ok, ^invented} =
             DurableTools.execute(claim2, operation2, retry_failed: true, attempt: 2)

    assert DurableTools.stats(c.id <> "-manual").effects == 0
  end

  test "timeout after external effect records unknown, then lookup confirms exactly one effect",
       c do
    {claim, operation} = waiting(c.id)
    stop_at(claim, operation, :after_effect)
    assert DurableTools.stats(c.id).effects == 1

    assert {:ok, {:unknown, receipt}} =
             DurableTools.observe_timeout(claim, operation, :tool_timeout)

    assert receipt.output == %{kind: "timeout", reason: :tool_timeout, effect: "unknown"}
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert Enum.map(record.attempts, & &1.kind) == ["execution", "observation"]
    assert {:ok, {:ok, confirmed}} = DurableTools.reconcile(claim, operation)
    assert confirmed.output.effect_index == 1
    assert DurableTools.stats(c.id).effects == 1
  end

  test "timeout after receipt commit reuses a complete result without ambiguity", c do
    {claim, operation} = waiting(c.id)
    stop_at(claim, operation, :after_receipt)
    assert {:ok, [before]} = DurableTools.list(c.id)
    assert {:ok, observed} = DurableTools.observe_timeout(claim, operation, :tool_timeout)
    assert observed === before.result
    assert {:ok, [after_record]} = DurableTools.list(c.id)
    assert List.last(after_record.attempts).kind == "observation"
    assert List.last(after_record.attempts).outcome == "completed"
    assert DurableTools.stats(c.id).effects == 1
  end

  test "timeout before preparation conservatively creates unknown without invoking a file tool",
       c do
    operation = %{
      operation_id: "write",
      tool: "file_write",
      arguments: %{"path" => "out.txt", "content" => "one\n", "expected_sha256" => "absent"}
    }

    {claim, operation} = waiting(c.id, operation)

    assert {:ok, {:unknown, _}} =
             DurableTools.observe_timeout(claim, operation, :tool_timeout, workspace: c.root)

    assert {:ok, {:unknown, _}} =
             DurableTools.execute(claim, operation, retry_failed: true, workspace: c.root)

    refute File.exists?(Path.join(c.root, "out.txt"))
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "unknown"
    assert hd(record.attempts).kind == "observation"
  end

  test "retry preparation commits before effect and a second crash keeps prior attempts", c do
    {claim, operation} = waiting(c.id)
    assert {:ok, {:error, _}} = DurableTools.execute(claim, operation, transient_failures: 1)
    stop_at(claim, operation, :after_prepare, retry_failed: true, attempt: 2)
    assert {:ok, [record]} = DurableTools.list(c.id)
    assert record.status == "prepared"
    assert record.result == nil
    assert hd(record.attempts).outcome == "completed"
    assert List.last(record.attempts).outcome == "prepared"

    assert {:ok, {:unknown, _}} = DurableTools.observe_timeout(claim, operation, :tool_timeout)
    assert DurableTools.stats(c.id).effects == 0
  end

  test "invalid retry options and executable timeout reasons fail before preparation", c do
    {claim, operation} = waiting(c.id)

    for opts <- [[attempt: 0], [attempt: 1.0], [transient_failures: -1], [retry_failed: :yes]] do
      assert {:error, :invalid_durable_tool_options} =
               DurableTools.execute(claim, operation, opts)
    end

    assert {:error, :unsupported_term} =
             DurableTools.observe_timeout(claim, operation, fn -> :unsafe end)

    assert DurableTools.stats(c.id) == %{effects: 0, attempts: 0, operations: 0}
  end

  defp waiting(
         id,
         call \\ %{operation_id: "charge", tool: "mock_write", arguments: %{"amount" => 1}}
       ) do
    {:ok, initial} = Storage.create_run(id, "safe retries")
    {:ok, waiting} = Storage.dispatch(id, initial.state.seq, {:model_response, {:call, call}})
    {:ok, claim} = IntentStore.claim(id, "tool-worker")
    {claim, Map.fetch!(waiting.state.operations, call.operation_id)}
  end

  defp stop_at(claim, operation, target, opts \\ []) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        hook = fn stage ->
          if stage == target do
            send(parent, {:at_gate, self()})
            receive do: (:continue -> :ok)
          end
        end

        DurableTools.execute(claim, operation, Keyword.put(opts, :hook, hook))
      end)

    assert_receive {:at_gate, ^pid}, 5_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
  end
end
