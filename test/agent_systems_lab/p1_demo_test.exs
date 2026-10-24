defmodule AgentSystemsLab.P1DemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{Context, P1Demo, Session}
  alias AgentSystemsLab.Storage.Codec

  setup do
    root = Path.join(File.cwd!(), "artifacts/p1-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "P1 repairs with four compressed inputs and exports verifiable source manifests", %{
    root: root
  } do
    assert {:ok, result} = P1Demo.run(output: Path.join(root, "evidence"), storage: :memory)
    assert result.report["compressed_contexts"] == 4
    assert result.report["summary_contexts"] == 4
    assert result.report["canonical_messages"] == 40
    assert result.report["before_exit_code"] == 2
    assert result.report["after_exit_code"] == 0
    assert result.report["cancel_status"] == "cancelled"
    assert result.report["cancel_file_writes"] == 0
    assert result.report["postgres_commit_probes"] == "not_run_in_memory_mode"
    assert Enum.all?(result.report["payload_bytes"], &(&1 <= 16_384))

    for index <- 1..4 do
      path =
        Path.join(
          result.output_dir,
          "contexts/#{String.pad_leading(to_string(index), 2, "0")}.bin"
        )

      assert {:ok, bundle} = Codec.decode(File.read!(path))
      assert {:ok, session} = Session.from_map(bundle.session)
      assert session === result.session

      assert :ok =
               Context.verify(
                 Map.take(bundle, [:context, :manifest]),
                 session,
                 bundle.run,
                 bundle.permissions,
                 bundle.context_options
               )

      refute Map.has_key?(bundle.context, :manifest)
    end

    # Every original message remains intact; compaction is a provider projection.
    assert {:ok, source} = Codec.decode(File.read!(Path.join(result.output_dir, "session.bin")))
    assert Session.from_map(source) == {:ok, result.session}
  end

  test "existing P1 output is preserved without starting work", %{root: root} do
    File.write!(Path.join(root, "keep"), "keep")
    assert {:error, {:output_exists, ^root}} = P1Demo.run(output: root, storage: :memory)
    assert File.ls!(root) == ["keep"]
  end
end
