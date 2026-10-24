defmodule AgentSystemsLab.Repair do
  @moduledoc """
  A fixed offline repair exercise, including before/after acceptance evidence.

  The model-facing tools only read/write/patch bounded files. This trusted driver
  runs one fixed acceptance script in a separate BEAM, after verifying that both
  the source and test bytes match the shipped baseline or its one allowed fix.
  It never executes arbitrary model-generated source or a model-selected command.
  The private output directory must not already exist; failures retain evidence.
  """

  alias AgentSystemsLab.{Kernel, RunServer}
  alias AgentSystemsLab.Storage.Codec

  @source_path "lib/shipping.ex"
  @test_path "test/shipping_test.exs"
  @old "subtotal > 100"
  @new "subtotal >= 100"
  @notes "The free-delivery threshold is inclusive: subtotal 100 now pays no delivery fee.\n"

  def fixture_dir, do: Application.app_dir(:agent_systems_lab, "priv/repair_fixture")
  def fixture_source, do: File.read!(Path.join(fixture_dir(), @source_path))

  @doc "Four deterministic decisions: read, patch, write a note, then finish."
  def script(source) when is_binary(source) do
    [
      {:call,
       %{operation_id: "read-shipping", tool: "file_read", arguments: %{"path" => @source_path}}},
      {:call,
       %{
         operation_id: "patch-shipping",
         tool: "file_patch",
         arguments: %{
           "path" => @source_path,
           "expected_sha256" => sha256(source),
           "edits" => [%{"old" => @old, "new" => @new}]
         }
       }},
      {:call,
       %{
         operation_id: "write-repair-notes",
         tool: "file_write",
         arguments: %{
           "path" => "repair-notes.md",
           "content" => @notes,
           "expected_sha256" => "absent"
         }
       }},
      {:final,
       "The inclusive delivery threshold is repaired; the fixed driver must verify acceptance."}
    ]
  end

  def run(opts \\ []) do
    output = Path.expand(Keyword.get(opts, :output, "artifacts/week05-repair"))

    with :ok <- create_output(output),
         {:ok, workspace} <- copy_fixture(output),
         {:ok, before} <- acceptance(workspace, :before),
         true <- before.exit_code == 2,
         {:ok, snapshot} <- drive(workspace, opts),
         {:ok, after_result} <- acceptance(workspace, :after),
         true <- after_result.exit_code == 0,
         {:ok, report} <- save_evidence(output, snapshot, before, after_result) do
      {:ok, report}
    else
      false -> {:error, {:acceptance_invariant_failed, output}}
      {:error, _reason} = error -> error
    end
  end

  defp create_output(output) do
    with :ok <- File.mkdir_p(Path.dirname(output)) do
      case File.mkdir(output) do
        :ok -> :ok
        {:error, :eexist} -> {:error, {:output_exists, output}}
        {:error, reason} -> {:error, {:create_output, reason}}
      end
    end
  end

  defp copy_fixture(output) do
    workspace = Path.join(output, "workspace")

    case File.cp_r(fixture_dir(), workspace) do
      {:ok, _files} -> {:ok, workspace}
      {:error, reason, file} -> {:error, {:copy_fixture, reason, file}}
    end
  end

  defp acceptance(workspace, phase) do
    baseline = fixture_source()
    expected = if phase == :before, do: baseline, else: String.replace(baseline, @old, @new)
    test = File.read!(Path.join(fixture_dir(), @test_path))

    with {:ok, ^expected} <- File.read(Path.join(workspace, @source_path)),
         {:ok, ^test} <- File.read(Path.join(workspace, @test_path)) do
      {log, code} =
        System.cmd(System.find_executable("elixir"), ["-r", @source_path, @test_path],
          cd: workspace,
          stderr_to_stdout: true,
          env: [{"ERL_FLAGS", "+S 2:2"}]
        )

      {:ok, %{exit_code: code, log: log}}
    else
      _other -> {:error, :untrusted_acceptance_input}
    end
  end

  defp drive(workspace, opts) do
    responses = script(fixture_source())
    responses = if opts[:streaming], do: Enum.map(responses, &stream_entry/1), else: responses

    run_options = Keyword.get(opts, :run_options, [])
    allowed = [:run_id, :session, :session_id, :context_options, :storage]

    if not Keyword.keyword?(run_options) or Keyword.keys(run_options) -- allowed != [],
      do: raise(ArgumentError, "unsupported repair run options")

    run_options =
      Keyword.merge(
        [
          run_id: "repair-#{System.unique_integer([:positive])}",
          input:
            "Delivery is free at a subtotal of 100 or more. Repair the boundary and record a note.",
          workspace: workspace,
          script: responses,
          max_turns: 4
        ],
        run_options
      )

    with {:ok, server} <-
           AgentSystemsLab.start_run(run_options) do
      try do
        with {:ok, snapshot} <- RunServer.run_until_pause(server),
             :ok <- verify_run(snapshot) do
          {:ok, snapshot}
        end
      after
        GenServer.stop(server)
      end
    end
  end

  defp stream_entry({:call, call}) do
    arguments = JSON.encode!(call.arguments)
    middle = div(byte_size(arguments), 2)
    <<first::binary-size(^middle), second::binary>> = arguments

    {:stream,
     [
       {:tool_start, Map.take(call, [:operation_id, :tool])},
       {:arguments_delta, first},
       {:arguments_delta, second},
       :done
     ]}
  end

  defp stream_entry({:final, text}),
    do: {:stream, [{:text_delta, text}, :done]}

  defp verify_run(snapshot) do
    {:ok, rebuilt} = Kernel.rebuild(snapshot.state.run_id, snapshot.events, max_turns: 4)
    read = snapshot.state.operations["read-shipping"]
    patch_context = Enum.at(snapshot.provider.requests, 1)

    if snapshot.state.status == :succeeded and rebuilt == snapshot.state and
         snapshot.file_stats == %{requests: 3, reads: 1, writes: 2} and
         patch_context.operations["read-shipping"] == read and read.status == :ok,
       do: :ok,
       else: {:error, :repair_run_invariant_failed}
  end

  defp save_evidence(output, snapshot, before, after_result) do
    operations = snapshot.state.operations

    diff =
      operations["patch-shipping"].result.output["diff"] <>
        operations["write-repair-notes"].result.output["diff"]

    {:ok, encoded} = Codec.encode(snapshot.events)

    report = %{
      "status" => Atom.to_string(snapshot.state.status),
      "run_id" => snapshot.state.run_id,
      "before_exit_code" => before.exit_code,
      "after_exit_code" => after_result.exit_code,
      "turns" => snapshot.state.turn_count,
      "event_count" => length(snapshot.events),
      "file_stats" =>
        Map.new(snapshot.file_stats, fn {key, value} -> {Atom.to_string(key), value} end),
      "call_ids" => ["read-shipping", "patch-shipping", "write-repair-notes"],
      "source_before_sha256" => sha256(fixture_source()),
      "source_after_sha256" => sha256(String.replace(fixture_source(), @old, @new)),
      "rebuild_matches" => true,
      "acceptance_driver" => "fixed fixture, exact source/test bytes checked before execution"
    }

    with :ok <- File.write(Path.join(output, "before-test.log"), before.log),
         :ok <- File.write(Path.join(output, "after-test.log"), after_result.log),
         :ok <- File.write(Path.join(output, "repair.diff"), diff),
         :ok <- File.write(Path.join(output, "events.bin"), encoded),
         :ok <- File.write(Path.join(output, "report.json"), JSON.encode!(report) <> "\n") do
      {:ok,
       %{
         output_dir: output,
         diff_path: Path.join(output, "repair.diff"),
         report: report,
         snapshot: snapshot
       }}
    end
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
