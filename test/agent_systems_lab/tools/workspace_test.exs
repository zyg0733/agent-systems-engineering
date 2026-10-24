defmodule AgentSystemsLab.Tools.WorkspaceTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Tools.Workspace

  setup do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: "/tmp"

    root =
      Path.join(base, "agent-lab-workspace-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, workspace} = Workspace.new(root)
    %{root: root, workspace: workspace}
  end

  test "only an absolute existing directory is a valid root", %{root: root} do
    assert {:ok, %{root: ^root}} = Workspace.new(root)
    assert {:error, :invalid_workspace_root} = Workspace.new("relative")
    assert {:error, :invalid_workspace_root} = Workspace.new(nil)
    assert {:error, :invalid_workspace_root} = Workspace.new(root <> "/../elsewhere")
    assert {:error, {:filesystem, :enoent}} = Workspace.new(root <> "/missing")
    File.write!(Path.join(root, "file"), "contents")
    assert {:error, :not_a_directory} = Workspace.new(Path.join(root, "file"))

    for protected <- Workspace.blocked_components() do
      assert {:error, :protected_path} = Workspace.new(Path.join(root, protected))
      assert {:error, :protected_path} = Workspace.new(Path.join([root, protected, "nested"]))
    end
  end

  test "root ancestors cannot be symbolic links", %{root: root} do
    real = Path.join(root, "real")
    File.mkdir!(real)
    File.ln_s!(real, Path.join(root, "link"))
    assert {:error, :symlink_not_allowed} = Workspace.new(Path.join(root, "link"))
    assert {:error, :symlink_not_allowed} = Workspace.new(Path.join(root, "link/sub"))
  end

  test "invalid paths and protected metadata never resolve", %{workspace: workspace} do
    for path <- [
          "",
          "/etc/passwd",
          "../escape",
          "a/../escape",
          "./file",
          "a//b",
          "a/",
          "a\\b",
          "x\0y",
          "a\nb",
          nil
        ] do
      assert {:error, :invalid_path} = Workspace.resolve(workspace, path, true)
    end

    for component <- Workspace.blocked_components() do
      assert {:error, :protected_path} =
               Workspace.resolve(workspace, "nested/#{component}/file", true)
    end

    assert {:error, :protected_path} = Workspace.resolve(workspace, ".agent-lab-tmp-spoof", true)
  end

  test "symlink files and directories cannot be read or written", %{
    root: root,
    workspace: workspace
  } do
    File.write!(Path.join(root, "real"), "secret")
    File.mkdir!(Path.join(root, "directory"))
    File.ln_s!(Path.join(root, "real"), Path.join(root, "link"))
    File.ln_s!(Path.join(root, "directory"), Path.join(root, "link-dir"))
    assert {:error, :symlink_not_allowed} = Workspace.read(workspace, "link")

    assert {:error, :symlink_not_allowed} =
             Workspace.write(workspace, "link", "changed", "absent")

    assert {:error, :symlink_not_allowed} =
             Workspace.write(workspace, "link-dir/new", "changed", "absent")

    assert File.read!(Path.join(root, "real")) == "secret"
    assert File.ls!(Path.join(root, "directory")) == []
  end

  test "protected components use Unicode case folding on every platform", %{root: root} do
    variants = [".GIT", ".RUNTIME", "DEPS", "_BUILD", ".awſ", "depſ", ".AGENT-LAB-TMP-spoof"]

    for component <- variants do
      assert {:error, :protected_path} = Workspace.path_valid(component <> "/file")
      assert {:error, :protected_path} = Workspace.path_valid("nested/" <> component <> "/file")
      assert {:error, :protected_path} = Workspace.new(Path.join(root, component))
      assert {:error, :protected_path} = Workspace.new(Path.join([root, component, "nested"]))
    end
  end

  test "metadata aliases cannot access existing files on case-insensitive filesystems", %{
    root: root,
    workspace: workspace
  } do
    File.mkdir!(Path.join(root, ".git"))
    File.write!(Path.join(root, ".git/config"), "metadata-secret\n")
    File.mkdir!(Path.join(root, "deps"))
    File.write!(Path.join(root, "deps/config"), "dependency-secret\n")

    for path <- [".GIT/config", "depſ/config"] do
      assert {:error, :protected_path} = Workspace.read(workspace, path)
      assert {:error, :protected_path} = Workspace.write(workspace, path, "changed", "absent")
    end

    assert File.read!(Path.join(root, ".git/config")) == "metadata-secret\n"
    assert File.read!(Path.join(root, "deps/config")) == "dependency-secret\n"
  end

  test "all C0 controls and DEL are rejected in relative paths and roots", %{root: root} do
    for byte <- Enum.to_list(0..31) ++ [127] do
      assert {:error, :invalid_path} = Workspace.path_valid("a" <> <<byte>> <> "b")
      assert {:error, :invalid_workspace_root} = Workspace.new(root <> "/a" <> <<byte>> <> "b")
    end
  end

  test "hard links and nonregular targets are refused", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, "real"), "secret")
    File.ln!(Path.join(root, "real"), Path.join(root, "hard"))
    assert {:error, :hardlink_not_allowed} = Workspace.read(workspace, "hard")

    assert {:error, :hardlink_not_allowed} =
             Workspace.write(workspace, "real", "changed", Workspace.sha256("secret"))

    File.mkdir!(Path.join(root, "directory"))
    assert {:error, :not_a_regular_file} = Workspace.read(workspace, "directory")
  end

  test "bounded reads reject oversized and nontext files", %{root: root, workspace: workspace} do
    File.write!(Path.join(root, "large"), :binary.copy("x", 1_000_000))
    File.write!(Path.join(root, "invalid"), <<255>>)
    File.write!(Path.join(root, "nul"), "a\0b")
    assert {:error, :file_too_large} = Workspace.read(workspace, "large")
    assert {:error, :invalid_utf8} = Workspace.read(workspace, "invalid")
    assert {:error, :nul_in_text} = Workspace.read(workspace, "nul")
  end

  test "the text limit counts bytes and accepts its exact boundary", %{
    root: root,
    workspace: workspace
  } do
    content = :binary.copy("é", 32_768)
    File.write!(Path.join(root, "boundary"), content)
    assert {:ok, ^content} = Workspace.read(workspace, "boundary")

    assert {:error, :file_too_large} =
             Workspace.write(workspace, "over", content <> "x", "absent")

    refute File.exists?(Path.join(root, "over"))
  end

  test "create and replace require an explicit matching base", %{root: root, workspace: workspace} do
    assert {:ok, nil} = Workspace.write(workspace, "answer", "42\n", "absent")
    assert {:error, :base_mismatch} = Workspace.write(workspace, "answer", "43\n", "absent")

    assert {:error, :base_mismatch} =
             Workspace.write(workspace, "answer", "43\n", Workspace.sha256("wrong"))

    assert {:ok, "42\n"} = Workspace.write(workspace, "answer", "43\n", Workspace.sha256("42\n"))
    assert File.read!(Path.join(root, "answer")) == "43\n"
    assert File.ls!(root) == ["answer"]
  end

  test "atomic replacements retain ordinary permissions and strip special bits", %{
    root: root,
    workspace: workspace
  } do
    path = Path.join(root, "private")
    File.write!(path, "before")
    File.chmod!(path, 0o600)

    assert {:ok, "before"} =
             Workspace.write(workspace, "private", "after", Workspace.sha256("before"))

    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o600
    File.chmod!(path, 0o4644)

    assert {:ok, "after"} =
             Workspace.write(workspace, "private", "final", Workspace.sha256("after"))

    assert Bitwise.band(File.stat!(path).mode, 0o7777) == 0o644
  end

  test "options and malformed hashes are rejected", %{workspace: workspace} do
    for opts <- [
          nil,
          [:bad],
          [max_file_bytes: 0],
          [max_file_bytes: 65_537],
          [unknown: true],
          [max_file_bytes: 1, max_file_bytes: 2]
        ] do
      assert {:error, :invalid_workspace_options} = Workspace.new(workspace.root, opts)
    end

    for hash <- [nil, "", String.duplicate("A", 64), String.duplicate("g", 64)] do
      assert {:error, :invalid_expected_sha256} = Workspace.write(workspace, "new", "text", hash)
    end

    {:ok, tiny} = Workspace.new(workspace.root, max_file_bytes: 2)
    assert {:error, :file_too_large} = Workspace.write(tiny, "new", "abc", "absent")
  end
end
