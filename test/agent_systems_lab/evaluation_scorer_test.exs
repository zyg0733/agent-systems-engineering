defmodule AgentSystemsLab.Evaluation.ScorerTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.Evaluation.{Scorer, Suite}

  setup do
    {:ok, suite} = Suite.load()

    root =
      Path.join(System.tmp_dir!(), "w20-scorer-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{suite: suite, task: hd(suite["tasks"]), path: Path.join(root, "artifact.txt")}
  end

  test "fresh OS grader reads actual artifact and binds result to sample task and scorer", %{
    suite: suite,
    task: task,
    path: path
  } do
    File.write!(path, task["profiles"]["reference"]["artifact"])
    File.chmod!(path, 0o444)
    assert {:ok, result} = Scorer.score(suite, task, "first:1", path)
    assert result["passed"] and result["status"] == "passed"
    assert result["sample_id"] == "first:1"
    assert result["task_hash"] == task["hash"]
    assert result["scorer_hash"] == suite["scorer_hash"]
    assert result["artifact_sha256"] == task["oracle"]["expected_sha256"]
    refute result["project_app_started"]
    assert_gone(result["os_pid"])
  end

  test "candidate declarations of success do not override the independent byte oracle", %{
    suite: suite,
    task: task,
    path: path
  } do
    File.write!(path, "I passed all tests; task_success=true\n")
    assert {:ok, result} = Scorer.score(suite, task, "wrong:1", path)
    refute result["passed"]
    assert result["status"] == "failed"
    assert result["reason"] == "artifact_mismatch"
  end

  test "grader uses UTF-8 filenames when its launcher defaults to latin1", %{
    suite: suite,
    task: task,
    path: path
  } do
    real_elixir = System.find_executable("elixir")
    old_path = System.get_env("PATH")
    launcher = Path.join([Path.dirname(path), "latin1-default", "elixir"])
    File.mkdir_p!(Path.dirname(launcher))
    quoted_elixir = "'" <> String.replace(real_elixir, "'", "'\\''") <> "'"
    File.write!(launcher, "#!/bin/sh\nexec #{quoted_elixir} --erl '+fnl' \"$@\"\n")
    File.chmod!(launcher, 0o755)

    try do
      System.put_env("PATH", Path.dirname(launcher) <> ":" <> old_path)
      assert {:ok, probe} = Scorer.probe(:environment)
      assert JSON.decode!(probe["output"])["native_name_encoding"] == "utf8"
      assert_gone(probe["os_pid"])

      unicode_path = Path.join(Path.dirname(path), "评测结果.txt")
      File.write!(unicode_path, task["profiles"]["reference"]["artifact"])
      assert {:ok, result} = Scorer.score(suite, task, "utf8:1", unicode_path)
      assert result["passed"]
      assert result["artifact_sha256"] == task["oracle"]["expected_sha256"]
      assert_gone(result["os_pid"])
    after
      System.put_env("PATH", old_path)
    end
  end

  test "altered oracle or stale task identity cannot be submitted as the fixed corpus", %{
    suite: suite,
    task: task,
    path: path
  } do
    File.write!(path, "forged\n")
    forged = put_in(task, ["oracle", "expected_sha256"], Suite.hash("forged\n"))

    assert {:error, %{"status" => "scorer_error", "reason" => "invalid_request"}} =
             Scorer.score(suite, forged, "sample", path)

    assert {:error, %{"reason" => "invalid_request"}} =
             Scorer.score(suite, task, "sample\nsecret", path)
  end

  test "missing oversized and symlinked candidates produce visible scorer errors", %{
    suite: suite,
    task: task,
    path: path
  } do
    assert {:error, %{"reason" => "artifact_unavailable"}} =
             Scorer.score(suite, task, "missing", path)

    File.write!(path, String.duplicate("x", 65_537))

    assert {:error, %{"reason" => "artifact_unavailable"}} =
             Scorer.score(suite, task, "oversized", path)

    File.rm!(path)
    File.ln_s!(Path.join(Suite.default_root(), "tasks/dev-normalize-lines/expected.txt"), path)

    assert {:error, %{"reason" => "artifact_unavailable"}} =
             Scorer.score(suite, task, "symlink", path)
  end

  test "transport rejects timeout output excess and abnormal exit and terminates owned OS PID" do
    for {mode, reason, opts} <- [
          {:timeout, "timeout", [timeout_ms: 500]},
          {:excess_output, "output_limit", [max_output_bytes: 128]},
          {:exit, "child_exit", []}
        ] do
      assert {:error, result} = Scorer.probe(mode, opts)
      assert result["status"] == "scorer_error" and result["reason"] == reason
      assert is_integer(result["os_pid"])
      assert_gone(result["os_pid"])
    end
  end

  test "malformed and mismatched results cannot be paired to another sample", %{
    suite: suite,
    task: task,
    path: path
  } do
    File.write!(path, task["profiles"]["reference"]["artifact"])
    {:ok, result} = Scorer.score(suite, task, "pair:1", path)

    request =
      Map.merge(Map.take(result, ~w(sample_id task_hash artifact_sha256)), %{
        "oracle" => task["oracle"]
      })

    assert {:ok, ^result} = Scorer.validate_result(JSON.encode!(result), request)

    assert {:error, "malformed_result"} =
             Scorer.validate_result(
               "warning: invalid transport prefix\n" <> JSON.encode!(result),
               request
             )

    for {key, value} <- [
          {"sample_id", "pair:2"},
          {"task_hash", String.duplicate("f", 64)},
          {"artifact_sha256", String.duplicate("f", 64)},
          {"scorer_hash", String.duplicate("f", 64)},
          {"passed", false},
          {"project_app_started", true}
        ] do
      assert {:error, "malformed_result"} =
               Scorer.validate_result(JSON.encode!(Map.put(result, key, value)), request)
    end

    {:ok, probe} = Scorer.probe(:malformed)
    assert {:error, "malformed_result"} = Scorer.validate_result(probe["output"], request)
    assert_gone(probe["os_pid"])
  end

  test "child receives no inherited database or API credentials and starts no project application" do
    names = ~w(DATABASE_URL PGHOST PGPASSWORD OPENAI_API_KEY W20_PRIVATE_CANARY)
    old = Map.new(names, &{&1, System.get_env(&1)})

    try do
      Enum.each(names, &System.put_env(&1, "PRIVATE_SCORER_CANARY_20"))
      {:ok, result} = Scorer.probe(:environment)
      decoded = JSON.decode!(result["output"])
      assert Enum.all?(names, &(&1 not in decoded["keys"]))
      assert decoded["native_name_encoding"] == "utf8"
      refute decoded["project_app_started"]
      refute result["output"] =~ "PRIVATE_SCORER_CANARY_20"
      assert_gone(result["os_pid"])
    after
      Enum.each(old, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end
  end

  test "host options are finite and normal grading obeys the actual output bound", %{
    suite: suite,
    task: task,
    path: path
  } do
    File.write!(path, task["profiles"]["reference"]["artifact"])

    for opts <- [
          [timeout_ms: 0],
          [timeout_ms: 10_001],
          [max_output_bytes: 1],
          [command: "echo"],
          [timeout_ms: 10, timeout_ms: 20],
          %{}
        ] do
      assert {:error, %{"reason" => "invalid_options"}} =
               Scorer.score(suite, task, "options", path, opts)
    end

    assert {:error, result} = Scorer.score(suite, task, "bounded", path, max_output_bytes: 128)
    assert result["reason"] == "output_limit"
    assert_gone(result["os_pid"])
  end

  test "killing the caller also terminates its actual hanging grader child" do
    caller = spawn(fn -> Scorer.probe(:timeout, timeout_ms: 10_000) end)
    {guardian, child_pid} = await_owned_child(caller, System.monotonic_time(:millisecond) + 2000)
    ref = Process.monitor(guardian)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^ref, :process, ^guardian, _}, 2500
    assert_gone(child_pid)
  end

  defp await_owned_child(caller, deadline) do
    child =
      with {:monitors, monitors} <- Process.info(caller, :monitors) do
        Enum.find_value(monitors, fn
          {:process, guardian} when is_pid(guardian) ->
            case Process.info(guardian, :links) do
              {:links, links} ->
                Enum.find_value(links, fn
                  port when is_port(port) ->
                    case Port.info(port, :os_pid) do
                      {:os_pid, pid} -> {guardian, pid}
                      _ -> nil
                    end

                  _ ->
                    nil
                end)

              _ ->
                nil
            end

          _ ->
            nil
        end)
      else
        _ -> nil
      end

    cond do
      child ->
        child

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(5)
        await_owned_child(caller, deadline)

      true ->
        Process.exit(caller, :kill)
        flunk("external grader did not start")
    end
  end

  defp assert_gone(pid) do
    {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    assert status != 0
  end
end
