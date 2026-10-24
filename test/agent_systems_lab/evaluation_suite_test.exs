defmodule AgentSystemsLab.Evaluation.SuiteTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.Evaluation.Suite

  setup do
    root =
      Path.join(System.tmp_dir!(), "w20-suite-#{System.unique_integer([:positive, :monotonic])}")

    File.cp_r!(Suite.default_root(), root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "fixed corpus has disjoint explicit splits and a reproducible full source identity" do
    assert {:ok, suite} = Suite.load()
    assert {:ok, ^suite} = Suite.load()
    assert length(Suite.tasks(suite, "dev")) == 6
    assert length(Suite.tasks(suite, "holdout")) == 4
    assert Suite.tasks(suite, "unknown") == []
    assert length(Enum.uniq(Enum.map(suite["tasks"], & &1["id"]))) == 10
    assert map_size(suite["fixture_hashes"]) == 50
    assert suite["pricing_hash"] == Suite.digest(suite["pricing"])
    assert suite["hash"] == suite["suite_hash"]

    for hash <- [suite["hash"], suite["scorer_hash"], suite["pricing_hash"], suite["source_hash"]] do
      assert hash =~ ~r/^[a-f0-9]{64}$/
    end

    assert suite["pricing"]["currency"] == nil
  end

  test "golden bytes are excluded from execution inputs and workspace fixture DTOs" do
    {:ok, suite} = Suite.load()

    for task <- suite["tasks"] do
      assert Map.keys(task["initial_files"]) == ["input.txt"]
      assert Map.keys(task["oracle"]) |> Enum.sort() == ~w(expected_bytes expected_sha256 kind)
      refute Map.has_key?(task, "expected")
      assert task["hash"] == task["sha256"]
      assert task["profiles"]["reference"]["mode"] == "artifact"
    end

    regressed =
      Enum.filter(suite["tasks"], fn t ->
        t["profiles"]["regressed"] != t["profiles"]["reference"]
      end)

    assert Enum.map(regressed, & &1["id"]) == [
             "dev-sort-inventory",
             "dev-bounded-response",
             "holdout-deduplicate-events"
           ]
  end

  test "raw manifest bytes and every oracle or input byte affect frozen identity", %{root: root} do
    {:ok, original} = Suite.load(root: root)
    File.write!(Path.join(root, "manifest.json"), "\n", [:append])
    {:ok, whitespace} = Suite.load(root: root)
    refute whitespace["hash"] == original["hash"]
    assert whitespace["task_hashes"] == original["task_hashes"]

    for file <- ~w(expected.txt reference.txt) do
      File.write!(Path.join(root, "tasks/dev-normalize-lines/" <> file), "a changed oracle\n")
    end

    {:ok, changed} = Suite.load(root: root)
    refute changed["hash"] == whitespace["hash"]

    refute changed["task_hashes"]["dev-normalize-lines"] ==
             original["task_hashes"]["dev-normalize-lines"]

    assert changed["task_hashes"]["dev-total-ledger"] ==
             original["task_hashes"]["dev-total-ledger"]
  end

  test "strict schema rejects unknown options, versions, pricing and duplicate task IDs", %{
    root: root
  } do
    path = Path.join(root, "manifest.json")
    original = File.read!(path)
    source = JSON.decode!(original)

    invalid = [
      Map.put(source, "commands", ["arbitrary"]),
      Map.put(source, "schema_version", 2),
      put_in(source, ["pricing", "model_attempt_units"], 0),
      Map.put(source, "tasks", [
        hd(source["tasks"]) | tl(source["tasks"]) |> List.replace_at(0, hd(source["tasks"]))
      ])
    ]

    for manifest <- invalid do
      File.write!(path, JSON.encode!(manifest))
      assert {:error, _} = Suite.load(root: root)
    end

    for opts <- [
          [root: root, root: root],
          [root: root, command: "echo"],
          [root: 1],
          [root: "relative"],
          %{}
        ] do
      assert {:error, _} = Suite.load(opts)
    end
  end

  test "duplicate JSON keys and trailing documents are refused", %{root: root} do
    path = Path.join(root, "manifest.json")
    raw = File.read!(path)

    for malformed <- [
          String.replace(
            raw,
            "\"schema_version\": 1",
            "\"schema_version\": 2, \"schema_version\": 1"
          ),
          raw <> "{}"
        ] do
      File.write!(path, malformed)
      assert {:error, _} = Suite.load(root: root)
    end
  end

  test "manifest cannot select commands, alternate oracles, traversal or a different split", %{
    root: root
  } do
    path = Path.join(root, "manifest.json")
    source = JSON.decode!(File.read!(path))

    for {field, value} <- [
          {"oracle", "arbitrary_module"},
          {"input_file", "../input.txt"},
          {"split", "holdout"},
          {"artifact_path", "../../outside"},
          {"regressed_mode", "command"}
        ] do
      [first | rest] = source["tasks"]

      File.write!(
        path,
        JSON.encode!(Map.put(source, "tasks", [Map.put(first, field, value) | rest]))
      )

      assert {:error, _} = Suite.load(root: root)
    end
  end

  test "oversized input and symlinked fixtures fail closed", %{root: root} do
    path = Path.join(root, "tasks/dev-normalize-lines/input.txt")
    File.write!(path, String.duplicate("x", 16_385))
    assert {:error, _} = Suite.load(root: root)
    File.rm!(path)
    File.ln_s!(Path.join(root, "tasks/dev-total-ledger/input.txt"), path)
    assert {:error, _} = Suite.load(root: root)
  end

  test "reference and oracle disagreement is not silently accepted", %{root: root} do
    File.write!(
      Path.join(root, "tasks/dev-normalize-lines/reference.txt"),
      "self reported success\n"
    )

    assert {:error, _} = Suite.load(root: root)
  end
end
