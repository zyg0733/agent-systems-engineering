defmodule AgentSystemsLab.MCP.Schema do
  @moduledoc """
  A deliberately bounded JSON Schema 2020-12 subset for host-approved MCP tools.

  Unsupported keywords are rejected when authority is installed, rather than
  silently ignored at invocation. Objects are closed; schemas cannot resolve
  references, run regular expressions, or expand combinators. Limits apply to
  schemas and argument values independently of the transport frame limit.
  """

  @schema_limits {12, 1024, 65_536}
  @value_limits {16, 4096, 65_536}
  @metadata ~w(title description $schema)
  @dialects [
    "https://json-schema.org/draft/2020-12/schema",
    "https://json-schema.org/draft/2020-12/schema#"
  ]
  @keywords %{
    "object" => ~w(properties required additionalProperties),
    "array" => ~w(items minItems maxItems),
    "string" => ~w(minLength maxLength),
    "integer" => ~w(minimum maximum),
    "number" => ~w(minimum maximum),
    "boolean" => [],
    "null" => []
  }

  @doc "Accepts only the documented finite subset, within schema complexity limits."
  def validate_schema(schema) do
    with :ok <- bounded_json(schema, @schema_limits), :ok <- schema_node(schema) do
      :ok
    else
      {:error, reason} -> {:error, {:unsupported_mcp_schema, reason}}
    end
  end

  @doc "Validates a JSON value after checking the schema itself."
  def validate(schema, value) do
    with :ok <- validate_schema(schema),
         :ok <- bounded_json(value, @value_limits),
         :ok <- value_node(schema, value) do
      :ok
    else
      {:error, {:unsupported_mcp_schema, _}} = error -> error
      {:error, reason} -> {:error, {:invalid_mcp_arguments, reason}}
    end
  end

  defp schema_node(schema) when is_map(schema) and not is_struct(schema) do
    type = schema["type"]

    with {:ok, keywords} <- Map.fetch(@keywords, type),
         true <- Map.keys(schema) -- (["type", "enum"] ++ @metadata ++ keywords) == [],
         :ok <- metadata(schema),
         :ok <- type_schema(type, schema),
         :ok <- enum_schema(schema) do
      :ok
    else
      _ -> {:error, :unsupported_or_invalid_keyword}
    end
  end

  defp schema_node(_), do: {:error, :schema_must_be_object}

  defp metadata(schema) do
    valid =
      Enum.all?(~w(title description), fn key ->
        not Map.has_key?(schema, key) or bounded_text?(schema[key], 0, 4096)
      end) and
        (not Map.has_key?(schema, "$schema") or schema["$schema"] in @dialects)

    if valid, do: :ok, else: {:error, :invalid_metadata}
  end

  defp type_schema("object", schema) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    with true <- schema["additionalProperties"] === false,
         true <- is_map(properties) and not is_struct(properties) and map_size(properties) <= 128,
         true <- Enum.all?(Map.keys(properties), &bounded_text?(&1, 0, 128)),
         true <- bounded_list?(required, 128),
         true <- Enum.all?(required, &is_binary/1),
         true <- length(required) == length(Enum.uniq(required)),
         true <- required -- Map.keys(properties) == [] do
      each(Map.values(properties), &schema_node/1)
    else
      _ -> {:error, :invalid_closed_object}
    end
  end

  defp type_schema("array", schema) do
    with true <- Map.has_key?(schema, "items"),
         :ok <- integer_bounds(schema, "minItems", "maxItems", 1024),
         :ok <- schema_node(schema["items"]) do
      :ok
    else
      _ -> {:error, :invalid_array}
    end
  end

  defp type_schema("string", schema),
    do: integer_bounds(schema, "minLength", "maxLength", 65_536)

  defp type_schema(type, schema) when type in ["integer", "number"] do
    minimum = Map.get(schema, "minimum")
    maximum = Map.get(schema, "maximum")

    if (not Map.has_key?(schema, "minimum") or is_number(minimum)) and
         (not Map.has_key?(schema, "maximum") or is_number(maximum)) and
         (is_nil(minimum) or is_nil(maximum) or minimum <= maximum),
       do: :ok,
       else: {:error, :invalid_number_bounds}
  end

  defp type_schema(_, _), do: :ok

  defp integer_bounds(schema, min_key, max_key, cap) do
    minimum = Map.get(schema, min_key, 0)
    maximum = Map.get(schema, max_key, cap)

    if is_integer(minimum) and is_integer(maximum) and minimum >= 0 and maximum <= cap and
         minimum <= maximum,
       do: :ok,
       else: {:error, :invalid_length_bounds}
  end

  defp enum_schema(schema) do
    if Map.has_key?(schema, "enum") do
      values = schema["enum"]
      without_enum = Map.delete(schema, "enum")

      if bounded_list?(values, 64) and values != [] and
           length(values) == length(Enum.uniq(values)) do
        each(values, &value_node(without_enum, &1))
      else
        {:error, :invalid_enum}
      end
    else
      :ok
    end
  end

  defp value_node(schema, value) do
    with :ok <- type_value(schema["type"], schema, value),
         true <- not Map.has_key?(schema, "enum") or Enum.any?(schema["enum"], &(&1 === value)) do
      :ok
    else
      false -> {:error, :enum_mismatch}
      {:error, _} = error -> error
    end
  end

  defp type_value("object", schema, value) when is_map(value) and not is_struct(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])

    cond do
      not Enum.all?(Map.keys(value), &is_binary/1) -> {:error, :non_string_object_key}
      Map.keys(value) -- Map.keys(properties) != [] -> {:error, :unknown_property}
      required -- Map.keys(value) != [] -> {:error, :missing_property}
      true -> each(Map.to_list(value), fn {key, item} -> value_node(properties[key], item) end)
    end
  end

  defp type_value("array", schema, value) when is_list(value) do
    if length(value) >= Map.get(schema, "minItems", 0) and
         length(value) <= Map.get(schema, "maxItems", 1024),
       do: each(value, &value_node(schema["items"], &1)),
       else: {:error, :array_length}
  end

  defp type_value("string", schema, value) when is_binary(value) do
    length = length(String.codepoints(value))

    if length >= Map.get(schema, "minLength", 0) and
         length <= Map.get(schema, "maxLength", 65_536),
       do: :ok,
       else: {:error, :string_length}
  end

  defp type_value("integer", schema, value) when is_integer(value),
    do: number_value(schema, value)

  defp type_value("number", schema, value) when is_number(value), do: number_value(schema, value)
  defp type_value("boolean", _schema, value) when is_boolean(value), do: :ok
  defp type_value("null", _schema, nil), do: :ok
  defp type_value(_, _, _), do: {:error, :type_mismatch}

  defp number_value(schema, value) do
    if (not Map.has_key?(schema, "minimum") or value >= schema["minimum"]) and
         (not Map.has_key?(schema, "maximum") or value <= schema["maximum"]),
       do: :ok,
       else: {:error, :number_bounds}
  end

  defp bounded_json(value, {depth, nodes, bytes}) do
    with {:ok, _remaining} <- json_node(value, depth, nodes),
         encoded = JSON.encode!(value),
         true <- byte_size(encoded) <= bytes do
      :ok
    else
      _ -> {:error, :json_complexity_limit}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp json_node(_, depth, remaining) when depth < 0 or remaining <= 0,
    do: {:error, :json_complexity_limit}

  defp json_node(value, depth, remaining) when is_map(value) and not is_struct(value) do
    if map_size(value) < remaining and
         Enum.all?(Map.keys(value), &bounded_text?(&1, 0, 65_536)) do
      json_children(Map.values(value), depth, remaining - 1 - map_size(value))
    else
      {:error, :invalid_json_object}
    end
  end

  defp json_node(value, depth, remaining) when is_list(value),
    do: json_children(value, depth, remaining - 1)

  defp json_node(value, _, remaining) when is_binary(value) do
    if bounded_text?(value, 0, 65_536),
      do: {:ok, remaining - 1},
      else: {:error, :invalid_json_text}
  end

  defp json_node(value, _, remaining) when is_number(value) or is_boolean(value) or is_nil(value),
    do: {:ok, remaining - 1}

  defp json_node(_, _, _), do: {:error, :invalid_json_value}

  defp json_children(values, depth, remaining) do
    Enum.reduce_while(values, {:ok, remaining}, fn value, {:ok, remaining} ->
      case json_node(value, depth - 1, remaining) do
        {:ok, remaining} -> {:cont, {:ok, remaining}}
        error -> {:halt, error}
      end
    end)
  end

  defp each(values, validator) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp bounded_text?(value, minimum, maximum),
    do:
      is_binary(value) and byte_size(value) >= minimum and byte_size(value) <= maximum and
        String.valid?(value)

  defp bounded_list?(values, maximum) when is_list(values), do: length(values) <= maximum
  defp bounded_list?(_, _), do: false
end
