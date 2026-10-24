defmodule AgentSystemsLab.Tools.FilesTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Tools.{Files, Workspace}

  setup do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"
    root = Path.join(base, "agent-lab-files-#{System.unique_integer([:positive, :monotonic])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, files} = Files.new(root)
    %{root: root, files: files}
  end

  test "read returns bounded content and a SHA-256 version", %{root: root, files: files} do
    File.write!(Path.join(root, "answer"), "42\n")
    {{:ok, output}, next} = Files.execute(files, "read-1", "file_read", %{"path" => "answer"})

    assert output == %{
             "path" => "answer",
             "content" => "42\n",
             "sha256" => Workspace.sha256("42\n"),
             "bytes" => 3
           }

    assert Files.stats(next) == %{requests: 1, reads: 1, writes: 0}
  end

  test "read retries return the original result even if the file changes", %{
    root: root,
    files: files
  } do
    path = Path.join(root, "answer")
    File.write!(path, "before")
    args = %{"path" => "answer"}
    {result, next} = Files.execute(files, "read-1", "file_read", args)
    File.write!(path, "after")
    assert {^result, final} = Files.execute(next, "read-1", "file_read", args)
    assert Files.stats(final) == %{requests: 2, reads: 1, writes: 0}

    assert {:ok, %{operation_id: "read-1", tool: "file_read", arguments: ^args, result: ^result}} =
             Files.lookup(final, "read-1")
  end

  test "create, read, patch and write have correctly paired results", %{root: root, files: files} do
    write = %{"path" => "answer", "content" => "return 41\n", "expected_sha256" => "absent"}
    {{:ok, created}, state} = Files.execute(files, "create", "file_write", write)
    assert created["before_sha256"] == "absent"
    assert created["diff"] =~ "--- /dev/null\n+++ b/answer"

    patch = %{
      "path" => "answer",
      "expected_sha256" => created["sha256"],
      "edits" => [%{"old" => "41", "new" => "42"}]
    }

    {{:ok, patched}, state} = Files.execute(state, "patch", "file_patch", patch)
    assert patched["before_sha256"] == created["sha256"]
    assert patched["sha256"] == Workspace.sha256("return 42\n")
    assert patched["diff"] =~ "-return 41\n+return 42\n"
    assert File.read!(Path.join(root, "answer")) == "return 42\n"
    assert Files.stats(state) == %{requests: 2, reads: 0, writes: 2}
  end

  test "a write retry is deduplicated and call IDs bind both tool and arguments", %{
    root: root,
    files: files
  } do
    args = %{"path" => "answer", "content" => "one", "expected_sha256" => "absent"}
    {result, state} = Files.execute(files, "op", "file_write", args)
    assert {^result, state} = Files.execute(state, "op", "file_write", args)

    assert {{:error, :operation_id_conflict}, state} =
             Files.execute(state, "op", "file_write", %{args | "content" => "two"})

    assert {{:error, :operation_id_conflict}, state} =
             Files.execute(state, "op", "file_read", %{"path" => "answer"})

    assert Files.stats(state) == %{requests: 4, reads: 0, writes: 1}
    assert File.read!(Path.join(root, "answer")) == "one"
  end

  test "failed calls also retain their ID binding without later effects", %{
    root: root,
    files: files
  } do
    args = %{"path" => "missing"}
    {result, state} = Files.execute(files, "read", "file_read", args)
    assert result == {:error, {:filesystem, :enoent}}
    File.write!(Path.join(root, "missing"), "now present")
    assert {^result, state} = Files.execute(state, "read", "file_read", args)
    assert Files.stats(state) == %{requests: 2, reads: 0, writes: 0}
  end

  test "patch validates every edit before writing and rejects stale bases", %{
    root: root,
    files: files
  } do
    File.write!(Path.join(root, "answer"), "one\n")

    patch = %{
      "path" => "answer",
      "expected_sha256" => Workspace.sha256("one\n"),
      "edits" => [%{"old" => "one", "new" => "two"}, %{"old" => "absent", "new" => "three"}]
    }

    assert {{:error, :patch_not_found}, state} =
             Files.execute(files, "patch", "file_patch", patch)

    assert File.read!(Path.join(root, "answer")) == "one\n"

    stale = %{
      patch
      | "expected_sha256" => Workspace.sha256("stale"),
        "edits" => [%{"old" => "one", "new" => "two"}]
    }

    assert {{:error, :base_mismatch}, state} = Files.execute(state, "stale", "file_patch", stale)
    assert Files.stats(state) == %{requests: 2, reads: 0, writes: 0}
    assert File.ls!(root) == ["answer"]
  end

  test "malformed tool arguments fail safely", %{files: files} do
    for {tool, args} <- [
          {"file_read", %{path: "answer"}},
          {"file_read", %{"path" => "answer", "extra" => true}},
          {"file_write", %{}},
          {"file_patch", %{"path" => "x", "expected_sha256" => "absent", "edits" => []}},
          {"file_write", %{"path" => "x", "content" => nil, "expected_sha256" => "absent"}}
        ] do
      assert {{:error, _}, _} = Files.execute(files, "valid-id", tool, args)
    end

    assert {{:error, :unknown_tool}, _} = Files.execute(files, "valid-id", "shell", %{})

    for id <- ["", "x\0y", <<255>>, String.duplicate("x", 257), nil] do
      assert {{:error, :invalid_operation_id}, ^files} =
               Files.execute(files, id, "file_read", %{})
    end

    assert :not_found = Files.lookup(files, "never")
  end

  test "deleting or replacing the workspace root cannot redirect reads", %{
    root: root,
    files: files
  } do
    target = Path.join(root, "actual")
    File.mkdir!(target)
    File.write!(Path.join(target, "answer"), "secret")
    subroot = Path.join(root, "subroot")
    File.mkdir!(subroot)
    {:ok, controlled} = Files.new(subroot)
    File.rmdir!(subroot)
    File.ln_s!(target, subroot)

    assert {{:error, :symlink_not_allowed}, _} =
             Files.execute(controlled, "read", "file_read", %{"path" => "answer"})

    assert Files.stats(files) == %{requests: 0, reads: 0, writes: 0}
  end

  test "failed writes leave neither changed targets nor temporary files", %{
    root: root,
    files: files
  } do
    File.write!(Path.join(root, "target"), "before")

    for {id, path, content, expected} <- [
          {"stale", "target", "after", Workspace.sha256("stale")},
          {"invalid", "target", <<255>>, Workspace.sha256("before")},
          {"huge", "target", String.duplicate("x", 65_537), Workspace.sha256("before")},
          {"missing-parent", "absent/target", "after", "absent"},
          {"protected", ".git/config", "after", "absent"}
        ] do
      assert {{:error, _}, _} =
               Files.execute(files, id, "file_write", %{
                 "path" => path,
                 "content" => content,
                 "expected_sha256" => expected
               })

      assert File.read!(Path.join(root, "target")) == "before"
      assert File.ls!(root) == ["target"]
    end
  end
end
