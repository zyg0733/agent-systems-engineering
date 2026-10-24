defmodule AgentSystemsLab.Evaluation.Scorer do
  @moduledoc """
  Fixed byte oracle in a fresh OS BEAM. This is process separation for a trusted
  teaching grader, not a sandbox for executing candidate code. The child starts
  no project application, receives no inherited credentials and never executes
  the candidate artifact. Only hashes and bounded metadata cross the protocol.
  """
  @source __ENV__.file
  @external_resource @source
  @source_hash :crypto.hash(:sha256, File.read!(@source)) |> Base.encode16(case: :lower)
  @result_keys ~w(schema_version status passed sample_id task_hash artifact_sha256 scorer_hash reason os_pid project_app_started)
  @max_artifact 65_536

  def source_hash, do: @source_hash

  def score(suite, task, sample_id, artifact_path, opts \\ []) do
    with :ok <- validate_options(opts),
         :ok <- validate_identity(suite, task, sample_id),
         {:ok, artifact_hash} <- artifact_hash(artifact_path) do
      request = %{
        "schema_version" => 1,
        "sample_id" => sample_id,
        "task_hash" => task["hash"],
        "artifact_path" => artifact_path,
        "artifact_sha256" => artifact_hash,
        "scorer_hash" => @source_hash,
        "oracle" => task["oracle"]
      }

      case launch(request, :score, opts) do
        {:ok, bytes, pid} ->
          case validate_result(bytes, request) do
            {:ok, result} -> {:ok, Map.put(result, "os_pid", pid)}
            {:error, reason} -> failure(reason, request, pid)
          end

        {:error, reason, pid} ->
          failure(reason, request, pid)
      end
    else
      {:error, reason} ->
        failure(
          reason,
          %{
            "sample_id" => safe_sample(sample_id),
            "task_hash" => safe_hash(task),
            "scorer_hash" => @source_hash
          },
          nil
        )
    end
  rescue
    _ ->
      failure(
        "invalid_request",
        %{
          "sample_id" => safe_sample(sample_id),
          "task_hash" => safe_hash(task),
          "scorer_hash" => @source_hash
        },
        nil
      )
  end

  @doc "Fixed host diagnostics for the scorer transport; no command or source text is accepted."
  def probe(mode, opts \\ [])
      when mode in [:timeout, :malformed, :excess_output, :exit, :environment] do
    with :ok <- validate_options(opts) do
      case launch(%{}, mode, opts) do
        {:ok, bytes, pid} -> {:ok, %{"output" => bytes, "os_pid" => pid}}
        {:error, reason, pid} -> failure(reason, %{}, pid)
      end
    else
      {:error, reason} -> failure(reason, %{}, nil)
    end
  end

  @doc false
  def main do
    Application.ensure_all_started(:crypto)

    result =
      with line when is_binary(line) <- IO.read(:stdio, :line),
           true <- byte_size(line) <= 8192,
           {:ok, request} <- JSON.decode(line),
           :ok <- validate_child_request(request),
           {:ok, hash} <- artifact_hash(request["artifact_path"]),
           true <- hash == request["artifact_sha256"] do
        oracle = request["oracle"]
        {:ok, info} = File.stat(request["artifact_path"])
        passed = hash == oracle["expected_sha256"] and info.size == oracle["expected_bytes"]

        %{
          "schema_version" => 1,
          "status" => if(passed, do: "passed", else: "failed"),
          "passed" => passed,
          "sample_id" => request["sample_id"],
          "task_hash" => request["task_hash"],
          "artifact_sha256" => hash,
          "scorer_hash" => @source_hash,
          "reason" => if(passed, do: "exact_match", else: "artifact_mismatch"),
          "os_pid" => :os.getpid() |> List.to_string() |> String.to_integer(),
          "project_app_started" =>
            Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_systems_lab))
        }
      else
        _ -> %{"status" => "scorer_error", "reason" => "invalid_child_request"}
      end

    IO.write(JSON.encode!(result) <> "\n")
  rescue
    _ -> IO.write("{\"status\":\"scorer_error\",\"reason\":\"child_exception\"}\n")
  end

  @doc false
  def probe_main(:timeout), do: receive(do: (:never -> :ok))
  def probe_main(:malformed), do: IO.write("not a JSON result\n")

  def probe_main(:excess_output),
    do: Enum.each(1..128, fn _ -> IO.write(String.duplicate("x", 1024)) end)

  def probe_main(:exit), do: System.halt(7)

  def probe_main(:environment) do
    IO.write(
      JSON.encode!(%{
        "keys" => System.get_env() |> Map.keys() |> Enum.sort(),
        "project_app_started" =>
          Enum.any?(Application.started_applications(), &(elem(&1, 0) == :agent_systems_lab))
      })
    )
  end

  def validate_result(bytes, request) when is_binary(bytes) and is_map(request) do
    with {:ok, result} <- JSON.decode(bytes),
         true <- is_map(result),
         true <- Enum.sort(Map.keys(result)) == Enum.sort(@result_keys),
         true <- result["schema_version"] == 1 and result["scorer_hash"] == @source_hash,
         true <-
           result["sample_id"] == request["sample_id"] and
             result["task_hash"] == request["task_hash"],
         true <- result["artifact_sha256"] == request["artifact_sha256"],
         true <- result["project_app_started"] == false,
         true <- is_integer(result["os_pid"]) and result["os_pid"] > 0,
         true <- result["passed"] in [true, false],
         true <- result["status"] == if(result["passed"], do: "passed", else: "failed"),
         true <-
           result["reason"] == if(result["passed"], do: "exact_match", else: "artifact_mismatch"),
         expected = request["oracle"],
         true <- result["passed"] == (request["artifact_sha256"] == expected["expected_sha256"]) do
      {:ok, result}
    else
      _ -> {:error, "malformed_result"}
    end
  rescue
    _ -> {:error, "malformed_result"}
  end

  def validate_result(_, _), do: {:error, "malformed_result"}

  defp validate_identity(%{"tasks" => tasks, "scorer_hash" => @source_hash}, task, sample)
       when is_list(tasks) and is_map(task) do
    if valid_sample?(sample) and Enum.any?(tasks, &(&1 == task)) and valid_oracle?(task["oracle"]),
      do: :ok,
      else: {:error, "invalid_request"}
  end

  defp validate_identity(_, _, _), do: {:error, "invalid_request"}

  defp validate_child_request(request) when is_map(request) do
    if Enum.sort(Map.keys(request)) ==
         Enum.sort(
           ~w(schema_version sample_id task_hash artifact_path artifact_sha256 scorer_hash oracle)
         ) and
         request["schema_version"] == 1 and request["scorer_hash"] == @source_hash and
         valid_sample?(request["sample_id"]) and
         valid_hash?(request["task_hash"]) and valid_hash?(request["artifact_sha256"]) and
         valid_oracle?(request["oracle"]), do: :ok, else: {:error, "invalid_request"}
  end

  defp validate_child_request(_), do: {:error, "invalid_request"}

  defp valid_oracle?(
         %{"kind" => "exact_bytes_v1", "expected_sha256" => hash, "expected_bytes" => count} =
           oracle
       ),
       do:
         map_size(oracle) == 3 and valid_hash?(hash) and is_integer(count) and count >= 0 and
           count <= @max_artifact

  defp valid_oracle?(_), do: false

  defp valid_sample?(value),
    do:
      is_binary(value) and byte_size(value) in 1..192 and
        Regex.match?(~r/^[A-Za-z0-9_.:@-]+$/, value)

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value)

  defp artifact_hash(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute and byte_size(path) <= 2048,
         {:ok, %{type: :regular, size: size}} when size <= @max_artifact <- File.lstat(path),
         {:ok, bytes} <- read_artifact(path),
         true <- byte_size(bytes) <= @max_artifact do
      {:ok, :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}
    else
      _ -> {:error, "artifact_unavailable"}
    end
  end

  defp artifact_hash(_), do: {:error, "artifact_unavailable"}

  defp read_artifact(path) do
    File.open(path, [:read, :binary], fn file ->
      case IO.binread(file, @max_artifact + 1) do
        bytes when is_binary(bytes) -> bytes
        :eof -> <<>>
        _ -> raise ArgumentError, "unreadable artifact"
      end
    end)
  end

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and length(Enum.uniq(Keyword.keys(opts))) == length(opts) and
         Enum.all?(opts, fn {key, _} -> key in [:timeout_ms, :max_output_bytes] end) and
         Keyword.get(opts, :timeout_ms, 3000) in 1..10_000 and
         Keyword.get(opts, :max_output_bytes, 8192) in 128..65_536,
       do: :ok,
       else: {:error, "invalid_options"}
  end

  defp launch(request, mode, opts) do
    owner = self()

    {guardian, ref} =
      spawn_monitor(fn ->
        owner_ref = Process.monitor(owner)
        result = launch_owned(request, mode, opts, owner_ref)
        send(owner, {:scorer_result, self(), result})
      end)

    receive do
      {:scorer_result, ^guardian, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^guardian, _} ->
        {:error, "launch_failed", nil}
    end
  end

  # The independent guardian owns the Port before the caller can be killed.
  # try/after alone cannot clean a child when its own process receives :kill.
  defp launch_owned(request, mode, opts, owner_ref) do
    executable = System.find_executable("elixir")
    ebin = __MODULE__ |> :code.which() |> List.to_string() |> Path.dirname()

    expression =
      if mode == :score,
        do: "AgentSystemsLab.Evaluation.Scorer.main()",
        else: "AgentSystemsLab.Evaluation.Scorer.probe_main(:#{mode})"

    env =
      Enum.map(System.get_env(), fn {key, _} -> {String.to_charlist(key), false} end) ++
        [{~c"PATH", String.to_charlist(System.get_env("PATH", ""))}]

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, ["--erl", "+S 1:1 +A 1 +SDcpu 1 +SDio 1", "-pa", ebin, "-e", expression]},
        {:env, env}
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      true = Port.command(port, JSON.encode!(request) <> "\n")
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 3000)

      case collect(port, deadline, Keyword.get(opts, :max_output_bytes, 8192), <<>>, owner_ref) do
        {:ok, bytes} -> {:ok, bytes, pid}
        {:error, reason} -> {:error, reason, pid}
      end
    rescue
      _ -> {:error, "launch_failed", pid}
    after
      if Port.info(port), do: terminate(port, pid)
    end
  rescue
    _ -> {:error, "launch_failed", nil}
  end

  defp collect(port, deadline, limit, bytes, owner_ref) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        {:error, "owner_exit"}

      {^port, {:data, next}} ->
        if byte_size(bytes) + byte_size(next) <= limit,
          do: collect(port, deadline, limit, bytes <> next, owner_ref),
          else: {:error, "output_limit"}

      {^port, {:exit_status, 0}} ->
        {:ok, bytes}

      {^port, {:exit_status, _}} ->
        {:error, "child_exit"}
    after
      remaining -> {:error, "timeout"}
    end
  end

  defp terminate(port, pid) do
    System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    if Port.info(port), do: Port.close(port)
    await_exit(pid, System.monotonic_time(:millisecond) + 1500)
    drain(port)
    :ok
  rescue
    _ -> :ok
  end

  defp await_exit(pid, deadline) do
    {_, status} = System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    if status == 0 and System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        10 -> :ok
      end

      await_exit(pid, deadline)
    else
      :ok
    end
  end

  defp drain(port) do
    receive do
      {^port, _} -> drain(port)
    after
      0 -> :ok
    end
  end

  defp safe_sample(value), do: if(valid_sample?(value), do: value, else: nil)
  defp safe_hash(%{"hash" => hash}), do: if(valid_hash?(hash), do: hash, else: nil)
  defp safe_hash(_), do: nil

  defp failure(reason, request, pid),
    do:
      {:error,
       %{
         "status" => "scorer_error",
         "reason" => reason,
         "sample_id" => request["sample_id"],
         "task_hash" => request["task_hash"],
         "artifact_sha256" => request["artifact_sha256"],
         "scorer_hash" => @source_hash,
         "os_pid" => pid
       }}
end
