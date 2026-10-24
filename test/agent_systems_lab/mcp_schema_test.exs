defmodule AgentSystemsLab.MCP.SchemaTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.MCP.Schema

  defp object(properties, required \\ []),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }

  test "closed nested JSON objects accept only declared required properties" do
    schema =
      object(
        %{
          "name" => %{"type" => "string"},
          "flags" => object(%{"ok" => %{"type" => "boolean"}}, ["ok"])
        },
        ["name"]
      )

    assert :ok = Schema.validate_schema(schema)
    assert :ok = Schema.validate(schema, %{"name" => "hello", "flags" => %{"ok" => true}})
    assert :ok = Schema.validate(schema, %{"name" => "hello"})
    assert {:error, {:invalid_mcp_arguments, :missing_property}} = Schema.validate(schema, %{})

    assert {:error, {:invalid_mcp_arguments, :unknown_property}} =
             Schema.validate(schema, %{"name" => "ok", "env" => %{}})

    assert {:error, _} = Schema.validate(schema, %{name: "hello"})
  end

  test "string lengths count Unicode codepoints and respect explicit bounds" do
    schema = %{"type" => "string", "minLength" => 2, "maxLength" => 3}
    assert :ok = Schema.validate(schema, "中文")
    assert :ok = Schema.validate(schema, "e\u0301")
    assert {:error, _} = Schema.validate(%{"type" => "string", "maxLength" => 1}, "e\u0301")
    assert {:error, _} = Schema.validate(schema, "中")
    assert {:error, _} = Schema.validate(schema, "abcd")
    assert {:error, _} = Schema.validate(schema, <<255>>)
  end

  test "integer and number bounds reject wrong types and out of range values" do
    integer = %{"type" => "integer", "minimum" => -2, "maximum" => 3}
    assert :ok = Schema.validate(integer, -2)
    assert :ok = Schema.validate(integer, 3)
    assert {:error, _} = Schema.validate(integer, 1.0)
    assert {:error, _} = Schema.validate(integer, 4)
    assert :ok = Schema.validate(%{"type" => "number", "minimum" => 0.5}, 0.5)
    assert {:error, _} = Schema.validate(%{"type" => "number", "minimum" => 0.5}, 0)
  end

  test "array items and finite lengths are both enforced" do
    schema = %{
      "type" => "array",
      "minItems" => 1,
      "maxItems" => 2,
      "items" => %{"type" => "integer"}
    }

    assert :ok = Schema.validate(schema, [1, 2])
    assert {:error, _} = Schema.validate(schema, [])
    assert {:error, _} = Schema.validate(schema, [1, 2, 3])
    assert {:error, _} = Schema.validate(schema, ["1"])
  end

  test "boolean, null and enum have exact JSON value semantics" do
    assert :ok = Schema.validate(%{"type" => "boolean"}, false)
    assert {:error, _} = Schema.validate(%{"type" => "boolean"}, 0)
    assert :ok = Schema.validate(%{"type" => "null"}, nil)
    assert {:error, _} = Schema.validate(%{"type" => "null"}, "null")
    schema = %{"type" => "string", "enum" => ["read", "write"]}
    assert :ok = Schema.validate(schema, "read")
    assert {:error, _} = Schema.validate(schema, "delete")
  end

  test "reference, pattern, combinator and unknown keyword cannot be ignored" do
    for keyword <- [
          "$ref",
          "$defs",
          "pattern",
          "oneOf",
          "anyOf",
          "allOf",
          "format",
          "default",
          "x-custom"
        ] do
      assert {:error, {:unsupported_mcp_schema, _}} =
               Schema.validate_schema(%{"type" => "string", keyword => "ignored?"})
    end
  end

  test "object grants require explicit additionalProperties false" do
    for invalid <- [
          %{"type" => "object"},
          %{"type" => "object", "additionalProperties" => true},
          %{"type" => "object", "additionalProperties" => false, "required" => ["absent"]},
          object(%{"a" => %{"type" => "string"}}, ["a", "a"]),
          object(%{bad: %{"type" => "string"}})
        ] do
      assert {:error, _} = Schema.validate_schema(invalid)
    end
  end

  test "unsupported type unions and invalid constraint shapes fail at enrollment" do
    for invalid <- [
          %{"type" => ["string", "null"]},
          %{"type" => "wat"},
          %{"type" => "number", "minimum" => nil},
          %{"type" => "number", "maximum" => "10"},
          %{"type" => "integer", "minimum" => 5, "maximum" => 2},
          %{"type" => "string", "maxLength" => 65_537},
          %{"type" => "array", "items" => %{"type" => "null"}, "maxItems" => 1025},
          %{"type" => "array"},
          %{"type" => "boolean", "enum" => []},
          %{"type" => "boolean", "enum" => [true, true]},
          %{"type" => "boolean", "enum" => [1]},
          %{"type" => "string", "minimum" => 0}
        ] do
      assert {:error, _} = Schema.validate_schema(invalid)
    end
  end

  test "recognized bounded metadata does not weaken validation" do
    schema = %{
      "type" => "string",
      "title" => "Value",
      "description" => "Host approved",
      "$schema" => "https://json-schema.org/draft/2020-12/schema"
    }

    assert :ok = Schema.validate_schema(schema)
    assert {:error, _} = Schema.validate(schema, true)

    assert {:error, _} =
             Schema.validate_schema(Map.put(schema, "$schema", "https://attacker.invalid/schema"))

    assert {:error, _} =
             Schema.validate_schema(Map.put(schema, "description", String.duplicate("x", 4097)))
  end

  test "schema and argument depth are bounded independently" do
    nested = fn depth ->
      Enum.reduce(1..depth, %{"type" => "null"}, fn _, acc ->
        %{"type" => "array", "items" => acc}
      end)
    end

    assert {:error, _} = Schema.validate_schema(nested.(20))
    assert :ok = Schema.validate_schema(nested.(3))
    assert :ok = Schema.validate(nested.(3), [[[nil]]])
  end

  test "large maps, arrays and encoded JSON are bounded before tool dispatch" do
    schema = %{"type" => "string"}
    assert {:error, _} = Schema.validate(schema, String.duplicate("x", 65_537))
    assert {:error, _} = Schema.validate(schema, String.duplicate("\n", 40_000))
    assert {:error, _} = Schema.validate_schema(object(Map.new(1..129, &{"p#{&1}", schema})))

    assert {:error, _} =
             Schema.validate(
               %{"type" => "array", "items" => %{"type" => "null"}},
               List.duplicate(nil, 5000)
             )
  end

  test "runtime terms cannot masquerade as JSON arguments" do
    schema = object(%{"a" => %{"type" => "null"}})

    for value <- [self(), make_ref(), fn -> nil end, %{a: nil}, %URI{}, [1 | 2], %{"a" => :atom}] do
      assert {:error, _} = Schema.validate(schema, value)
    end
  end
end
