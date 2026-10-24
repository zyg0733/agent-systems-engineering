defmodule AgentSystemsLab.Tools.PatchTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Tools.Patch

  test "edits use exact sequential matching" do
    assert {:ok, "return 42\n"} = Patch.apply("return 41\n", [%{"old" => "41", "new" => "42"}])

    assert {:ok, "three"} =
             Patch.apply("one", [
               %{"old" => "one", "new" => "two"},
               %{"old" => "two", "new" => "three"}
             ])
  end

  test "missing or ambiguous matches reject the entire in-memory batch" do
    assert {:error, :patch_not_found} =
             Patch.apply("one", [
               %{"old" => "one", "new" => "two"},
               %{"old" => "missing", "new" => "three"}
             ])

    assert {:error, :patch_ambiguous} =
             Patch.apply("same same", [%{"old" => "same", "new" => "other"}])

    assert {:error, :patch_ambiguous} = Patch.apply("aaa", [%{"old" => "aa", "new" => "b"}])
  end

  test "schema bounds and invalid UTF-8 or NUL text are rejected" do
    for edits <- [
          nil,
          [],
          List.duplicate(%{"old" => "a", "new" => "b"}, 33),
          [%{"old" => "", "new" => "b"}],
          [%{"old" => "a", "new" => "b", "extra" => true}],
          [%{old: "a", new: "b"}],
          [%{"old" => "a", "new" => <<255>>}],
          [%{"old" => "a", "new" => "b\0"}]
        ] do
      assert {:error, :invalid_edits} = Patch.apply("a", edits)
    end
  end

  test "expanded output is bounded before any file write" do
    assert {:error, :file_too_large} =
             Patch.apply("ab", [%{"old" => "a", "new" => String.duplicate("x", 65_536)}])
  end

  test "diff is a standard complete-file unified hunk" do
    assert Patch.diff("lib/example.ex", "one\ntwo\n", "one\nthree\n") ==
             "--- a/lib/example.ex\n+++ b/lib/example.ex\n@@ -1,2 +1,2 @@\n-one\n-two\n+one\n+three\n"

    assert Patch.diff("same", "same", "same") == ""
  end

  test "diff represents creation, empty output, and absent trailing newlines" do
    assert Patch.diff("new", nil, "new\n") == "--- /dev/null\n+++ b/new\n@@ -0,0 +1,1 @@\n+new\n"
    assert Patch.diff("empty", "old\n", "") == "--- a/empty\n+++ b/empty\n@@ -1,1 +0,0 @@\n-old\n"

    assert Patch.diff("text", "a", "b") ==
             "--- a/text\n+++ b/text\n@@ -1,1 +1,1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"
  end

  test "empty creation has a Git-compatible extended header, including quoted paths" do
    assert Patch.diff("empty file", nil, "") ==
             "diff --git \"a/empty file\" \"b/empty file\"\nnew file mode 100644\nindex 0000000..e69de29\n"
  end
end
