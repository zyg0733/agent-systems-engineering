defmodule AgentSystemsLab.Tools.Patch do
  @moduledoc "Exact, uniquely matched text edits and a portable unified diff."

  alias AgentSystemsLab.Tools.Workspace

  @doc "Applies all edits in memory; any missing or ambiguous old text rejects the batch."
  def apply(contents, edits) do
    with :ok <- Workspace.text_valid(contents),
         :ok <- edits_valid(edits) do
      Enum.reduce_while(edits, {:ok, contents}, fn %{"old" => old, "new" => new},
                                                   {:ok, current} ->
        case unique_match(current, old) do
          {:ok, {offset, length}} ->
            prefix = binary_part(current, 0, offset)
            suffix = binary_part(current, offset + length, byte_size(current) - offset - length)
            next = prefix <> new <> suffix

            case Workspace.text_valid(next) do
              :ok -> {:cont, {:ok, next}}
              error -> {:halt, error}
            end

          {:error, _} = error ->
            {:halt, error}
        end
      end)
    end
  end

  def edits_valid(edits) when is_list(edits) and length(edits) in 1..32 do
    if Enum.all?(edits, &edit_valid?/1), do: :ok, else: {:error, :invalid_edits}
  end

  def edits_valid(_), do: {:error, :invalid_edits}

  @doc "Builds a unified diff; empty creation uses Git's extended new-file header."
  def diff(path, nil, "") do
    "diff --git #{quote_path("a/" <> path)} #{quote_path("b/" <> path)}\n" <>
      "new file mode 100644\nindex 0000000..e69de29\n"
  end

  def diff(path, before, after_contents) do
    if before === after_contents do
      ""
    else
      old_lines = lines(before || "")
      new_lines = lines(after_contents)
      old_header = if is_nil(before), do: "/dev/null", else: "a/#{path}"
      old_start = if old_lines == [], do: 0, else: 1
      new_start = if new_lines == [], do: 0, else: 1

      "--- #{old_header}\n+++ b/#{path}\n" <>
        "@@ -#{old_start},#{length(old_lines)} +#{new_start},#{length(new_lines)} @@\n" <>
        Enum.map_join(old_lines, &diff_line("-", &1)) <>
        Enum.map_join(new_lines, &diff_line("+", &1))
    end
  end

  defp edit_valid?(%{"old" => old, "new" => new} = edit) when map_size(edit) == 2 do
    is_binary(old) and old != "" and Workspace.text_valid(old) == :ok and
      Workspace.text_valid(new) == :ok
  end

  defp edit_valid?(_), do: false

  defp unique_match(contents, old) do
    case :binary.match(contents, old) do
      :nomatch ->
        {:error, :patch_not_found}

      {offset, _length} = found ->
        tail_offset = offset + 1
        tail_length = byte_size(contents) - tail_offset

        case :binary.match(contents, old, scope: {tail_offset, tail_length}) do
          :nomatch -> {:ok, found}
          _ -> {:error, :patch_ambiguous}
        end
    end
  end

  defp lines(""), do: []

  defp lines(contents) do
    parts = :binary.split(contents, "\n", [:global])
    last = List.last(parts)
    complete = Enum.drop(parts, -1) |> Enum.map(&{&1, true})
    if last == "", do: complete, else: complete ++ [{last, false}]
  end

  defp diff_line(prefix, {line, true}), do: prefix <> line <> "\n"
  defp diff_line(prefix, {line, false}), do: prefix <> line <> "\n\\ No newline at end of file\n"

  defp quote_path(path) do
    "\"" <> (path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\""
  end
end
