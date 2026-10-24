defmodule AgentSystemsLab.Tools.CatalogTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.Tools.{Catalog, Gateway}

  @hash String.duplicate("a", 64)

  test "advertises enabled tools with closed object schemas and serializable descriptors" do
    assert Enum.map(Catalog.schemas(), & &1["name"]) == ["mock_write"]
    schemas = Catalog.schemas(true)
    assert Enum.map(schemas, & &1["name"]) == ~w(mock_write file_read file_write file_patch)
    assert is_binary(JSON.encode!(schemas))

    for descriptor <- tl(schemas) do
      schema = descriptor["input_schema"]
      assert schema["type"] == "object"
      assert schema["additionalProperties"] == false
      assert Enum.sort(schema["required"]) == Enum.sort(Map.keys(schema["properties"]))
    end

    patch = List.last(schemas)["input_schema"]["properties"]["edits"]
    assert patch["minItems"] == 1
    assert patch["maxItems"] == 32
    assert patch["items"]["additionalProperties"] == false
  end

  test "read rejects missing, atom, extra, nontext and excessive path arguments" do
    assert :ok = Catalog.validate("file_read", %{"path" => "src/main.ex"})

    for args <- [
          %{},
          %{path: "main.ex"},
          %{"path" => "x", "extra" => true},
          %{"path" => ""},
          %{"path" => nil},
          %{"path" => <<255>>},
          %{"path" => "a" <> <<0>>},
          %{"path" => String.duplicate("x", 1025)},
          []
        ] do
      assert {:error, {:invalid_tool_arguments, _}} = Catalog.validate("file_read", args)
    end
  end

  test "write requires explicit SHA precondition and bounded UTF-8 content" do
    valid = %{"path" => "result.txt", "content" => "你好", "expected_sha256" => "absent"}
    assert :ok = Catalog.validate("file_write", valid)
    assert :ok = Catalog.validate("file_write", %{valid | "expected_sha256" => @hash})

    for change <- [
          %{"expected_sha256" => ""},
          %{"expected_sha256" => String.upcase(@hash)},
          %{"expected_sha256" => nil},
          %{"content" => <<255>>},
          %{"content" => "a" <> <<0>>},
          %{"content" => String.duplicate("你", 21_846)}
        ] do
      assert {:error, {:invalid_tool_arguments, _}} =
               Catalog.validate("file_write", Map.merge(valid, change))
    end

    assert {:error, _} = Catalog.validate("file_write", Map.delete(valid, "expected_sha256"))
  end

  test "patch rejects empty, excessive, malformed and open edit objects" do
    valid = %{
      "path" => "main.ex",
      "expected_sha256" => @hash,
      "edits" => [%{"old" => "broken", "new" => ""}]
    }

    assert :ok = Catalog.validate("file_patch", valid)

    for values <- [
          [],
          nil,
          List.duplicate(%{"old" => "a", "new" => "b"}, 33),
          [%{"old" => "", "new" => "x"}],
          [%{"old" => "a"}],
          [%{old: "a", new: "b"}],
          [%{"old" => "a", "new" => "b", "extra" => 1}]
        ] do
      assert {:error, _} = Catalog.validate("file_patch", %{valid | "edits" => values})
    end

    assert {:error, _} = Catalog.validate("file_patch", %{valid | "expected_sha256" => "absent"})
  end

  test "mock keeps arbitrary map compatibility and unknown names remain controlled" do
    assert :ok = Catalog.validate("mock_write", %{arbitrary: {self(), :value}})
    assert {:error, _} = Catalog.validate("mock_write", [])
    assert {:error, {:unsupported_tool, "other"}} = Catalog.validate("other", %{})
    assert :ok = Gateway.validate_call(%{operation_id: "id", tool: "other", arguments: %{}}, nil)

    assert {:error, {:tool_disabled, "file_read"}} =
             Gateway.validate_call(
               %{operation_id: "id", tool: "file_read", arguments: %{"path" => "x"}},
               nil
             )

    assert {:error, {:invalid_tool_call, _}} = Gateway.validate_call(%{operation_id: "id"}, nil)
  end

  test "file call IDs and relative paths are validated before intent creation" do
    files = %AgentSystemsLab.Tools.Files{}
    call = %{operation_id: "call-1", tool: "file_read", arguments: %{"path" => "source.ex"}}
    assert :ok = Gateway.validate_call(call, files)

    for id <- [String.duplicate("x", 257), <<255>>, "nul" <> <<0>>] do
      assert {:error, :invalid_operation_id} =
               Gateway.validate_call(%{call | operation_id: id}, files)
    end

    for path <- [
          "/etc/passwd",
          "../outside",
          "src/../outside",
          "a//b",
          ".git/config",
          "deps/x",
          "a\\b",
          "source\nforged-header",
          ".agent-lab-tmp-fake"
        ] do
      assert {:error, {:invalid_tool_arguments, :path}} =
               Gateway.validate_call(%{call | arguments: %{"path" => path}}, files)
    end

    assert :ok =
             Gateway.validate_call(
               %{call | operation_id: String.duplicate("x", 257), tool: "mock_write"},
               nil
             )
  end
end
