defmodule AgentSystemsLab.RecordingTest do
  use ExUnit.Case, async: true

  alias AgentSystemsLab.{Context, Recording}
  alias AgentSystemsLab.Storage.Codec

  setup do
    context = %{run_id: "recorded-run", input: "Repair", permissions: %{write_allowed: false}}

    attrs = %{
      context_id: nil,
      run_id: "recorded-run",
      input_seq: 1,
      event_seq: 2,
      provider: "scripted.v1",
      input_sha256: Context.hash(context),
      response: {:final, "complete"}
    }

    %{attrs: attrs, context: context}
  end

  test "complete records have independent strict versions and deterministic hashes", c do
    assert {:ok, record} = Recording.new(c.attrs)
    assert record.version === 1
    assert record.schema_version === 1
    assert record.response_sha256 == Context.hash(c.attrs.response)
    assert :ok = Recording.validate(record)
    assert :ok = Recording.verify(record)
    assert :ok = Recording.verify(record, c.context)
    assert {:ok, encoded} = Codec.encode(record)
    assert {:ok, ^record} = Codec.decode(encoded)
  end

  test "recording preserves non-JSON argument maps and exact types", c do
    response =
      {:call,
       %{
         operation_id: "tool-1",
         tool: "mock",
         arguments: %{"binary" => [1, 2.0], atom_key: {:opaque, 1}}
       }}

    assert {:ok, record} = Recording.new(%{c.attrs | response: response})
    assert record.response === response
    assert :ok = Recording.validate(record)
  end

  test "opaque nonempty binary Run IDs retain the Kernel compatibility contract", c do
    run_id = <<255, 0, 128>>
    context = %{c.context | run_id: run_id}

    assert {:ok, record} =
             Recording.new(%{
               c.attrs
               | run_id: run_id,
                 input_sha256: Context.hash(context)
             })

    assert record.run_id === run_id
    assert :ok = Recording.verify(record, context)

    assert {:error, :invalid_recording_metadata} =
             Recording.new(%{c.attrs | provider: run_id})
  end

  test "future and type-confused envelope and response versions fail closed", c do
    assert {:ok, record} = Recording.new(c.attrs)

    for value <- [nil, false, 0, 1.0, 2, "1"] do
      assert {:error, {:unsupported_recording_version, ^value}} =
               Recording.validate(%{record | version: value})

      assert {:error, {:unsupported_model_schema_version, ^value}} =
               Recording.validate(%{record | schema_version: value})
    end
  end

  test "response tampering and input changes cannot reuse a result", c do
    assert {:ok, record} = Recording.new(c.attrs)

    assert {:error, :recorded_response_mismatch} =
             Recording.verify(%{record | response: {:final, "altered"}})

    assert {:error, :recorded_input_mismatch} =
             Recording.verify(record, put_in(c.context.permissions.write_allowed, true))

    assert {:error, :recorded_input_mismatch} =
             Recording.verify(%{record | input_sha256: String.duplicate("0", 64)}, c.context)
  end

  test "attributes and records have exact key shapes", c do
    assert {:ok, record} = Recording.new(c.attrs)

    for attrs <- [nil, [], Map.delete(c.attrs, :context_id), Map.put(c.attrs, :extra, true)] do
      assert {:error, :invalid_recording_attributes} = Recording.new(attrs)
    end

    for candidate <- [nil, Map.delete(record, :version), Map.put(record, :extra, true)] do
      assert {:error, :invalid_recording} = Recording.validate(candidate)
    end
  end

  test "invalid sequence, binding, label, hash and candidate output are rejected", c do
    for patch <- [
          %{input_seq: 1.0},
          %{input_seq: 0},
          %{event_seq: 3},
          %{event_seq: 2.0},
          %{context_id: false},
          %{context_id: "unknown"},
          %{run_id: ""},
          %{provider: ""},
          %{input_sha256: "not a hash"},
          %{input_sha256: String.duplicate("A", 64)},
          %{response: {:error, :provider_failure}},
          %{response: {:text_delta, "partial"}},
          %{response: {:call, %{operation_id: "", tool: "mock", arguments: %{}}}},
          %{response: {:call, %{operation_id: "id", tool: "mock", arguments: %{pid: self()}}}}
        ] do
      assert {:error, _reason} = Recording.new(Map.merge(c.attrs, patch))
    end

    assert {:ok, _record} = Recording.new(%{c.attrs | context_id: Ecto.UUID.generate()})
    assert {:error, :invalid_context} = Recording.verify(%{}, false)
  end
end
