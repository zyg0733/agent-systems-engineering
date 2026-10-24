defmodule AgentSystemsLab.StreamTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Stream

  test "text stays provisional until done and assembles split UTF-8 bytes" do
    empty = Stream.new()
    <<first, rest::binary>> = "你好"
    assert {:ok, partial} = Stream.push(empty, {:text_delta, <<first>>})
    assert {:error, :incomplete_stream} = Stream.finish(partial)
    assert {:ok, partial} = Stream.push(partial, {:text_delta, rest})
    assert {:done, {:final, "你好"}, complete} = Stream.push(partial, :done)
    assert {:ok, {:final, "你好"}} = Stream.finish(complete)
    assert {:error, :incomplete_stream} = Stream.finish(empty)
  end

  test "an explicit done can complete an empty final answer" do
    assert {:done, {:final, ""}, complete} = Stream.push(Stream.new(), :done)
    assert {:ok, {:final, ""}} = Stream.finish(complete)
  end

  test "invalid final UTF-8 fails at done while individual byte fragments remain provisional" do
    for bytes <- [<<255>>, <<0xE4, 0xBD>>] do
      assert {:ok, partial} = Stream.push(Stream.new(), {:text_delta, bytes})
      assert {:error, :incomplete_stream} = Stream.finish(partial)
      assert {:error, :invalid_text_utf8} = Stream.push(partial, :done)
    end

    # The compatibility frame retains the original complete-response contract.
    response = {:final, <<255>>}
    assert {:done, ^response, _complete} = Stream.push(Stream.new(), {:complete, response})
  end

  test "only complete JSON object arguments produce a tool call" do
    {:ok, start} = Stream.push(Stream.new(), tool_start())
    {:ok, partial} = Stream.push(start, {:arguments_delta, ~s({"value":"he)})
    assert {:error, :incomplete_stream} = Stream.finish(partial)
    {:ok, full} = Stream.push(partial, {:arguments_delta, ~s(llo","nested":[true,null,3]})})

    assert {:done,
            {:call,
             %{
               operation_id: "op-1",
               tool: "mock_write",
               arguments: %{"value" => "hello", "nested" => [true, nil, 3]}
             }}, complete} = Stream.push(full, :done)

    assert {:ok, {:call, _}} = Stream.finish(complete)
    assert start.arguments == []
  end

  test "JSON can be split inside a UTF-8 value or an escaped sequence" do
    {:ok, start} = Stream.push(Stream.new(), tool_start())
    json = ~s({"value":"你好\\nworld"})
    <<head::binary-size(12), tail::binary>> = json
    {:ok, partial} = Stream.push(start, {:arguments_delta, head})
    {:ok, full} = Stream.push(partial, {:arguments_delta, tail})

    assert {:done, {:call, %{arguments: %{"value" => "你好\nworld"}}}, _} =
             Stream.push(full, :done)
  end

  test "legacy complete responses preserve arbitrary map keys and values exactly" do
    arguments = %{"string" => %{9 => [:ok]}, atom_key: %{tuple: {:value, 3}}}
    response = {:call, %{operation_id: "op-legacy", tool: "mock_write", arguments: arguments}}

    assert {:done, ^response, complete} = Stream.push(Stream.new(), {:complete, response})
    assert {:ok, ^response} = Stream.finish(complete)
    assert {:done, {:final, "old"}, _} = Stream.push(Stream.new(), {:complete, {:final, "old"}})
  end

  test "incomplete and invalid JSON never become a tool call" do
    for json <- ["", "{", ~s({"value":), ~s({"value":1} trailing), <<255>>] do
      {:ok, start} = Stream.push(Stream.new(), tool_start())
      {:ok, partial} = Stream.push(start, {:arguments_delta, json})
      assert {:error, {:invalid_arguments_json, _}} = Stream.push(partial, :done)
    end
  end

  test "valid JSON scalars and arrays are rejected as arguments" do
    for json <- ["[]", "null", "42", "true", ~s("value")] do
      {:ok, start} = Stream.push(Stream.new(), tool_start())
      {:ok, partial} = Stream.push(start, {:arguments_delta, json})
      assert {:error, :arguments_must_be_object} = Stream.push(partial, :done)
    end
  end

  test "mixed text and tools, multiple tools, and arguments before a tool are rejected" do
    {:ok, text} = Stream.push(Stream.new(), {:text_delta, "thinking"})
    {:ok, tool} = Stream.push(Stream.new(), tool_start())
    assert {:error, :mixed_response} = Stream.push(text, tool_start())
    assert {:error, :mixed_response} = Stream.push(tool, {:text_delta, "answer"})
    assert {:error, :multiple_tool_calls} = Stream.push(tool, tool_start())
    assert {:error, :arguments_before_tool} = Stream.push(Stream.new(), {:arguments_delta, "{}"})
    assert {:error, :arguments_before_tool} = Stream.push(text, {:arguments_delta, "{}"})
    assert {:error, :complete_after_partial} = Stream.push(text, {:complete, {:final, "done"}})
  end

  test "every frame after completion is rejected, including a second done" do
    {:done, _, complete} = Stream.push(Stream.new(), :done)

    for event <- [
          :done,
          {:text_delta, "late"},
          tool_start(),
          {:arguments_delta, "{}"},
          {:complete, {:final, "late"}}
        ] do
      assert {:error, :stream_already_complete} = Stream.push(complete, event)
    end
  end

  test "tool identifiers, complete responses and event shapes follow the provider contract" do
    for start <- [
          %{},
          %{operation_id: "", tool: "mock_write"},
          %{operation_id: "op-1", tool: ""},
          %{operation_id: 1, tool: "mock_write"},
          %{operation_id: "op-1", tool: "mock_write", extra: true}
        ] do
      assert {:error, {:invalid_tool_start, ^start}} =
               Stream.push(Stream.new(), {:tool_start, start})
    end

    for response <- [{:final, 42}, {:call, %{}}, :invalid] do
      assert {:error, {:invalid_complete_response, ^response}} =
               Stream.push(Stream.new(), {:complete, response})
    end

    for event <- [:unknown, {:text_delta, 42}, {:arguments_delta, nil}] do
      assert {:error, {:invalid_stream_event, ^event}} = Stream.push(Stream.new(), event)
    end
  end

  defp tool_start, do: {:tool_start, %{operation_id: "op-1", tool: "mock_write"}}
end
