defmodule AgentSystemsLab.HistoryEncodingTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.History.Encoding
  alias AgentSystemsLab.Storage.Codec

  test "both layouts decode the same inert value and preserve exact legacy bytes" do
    value = %{input: "任务", receipt: {:ok, %{"bytes" => <<0, 1, 255>>}}, fact: [true, nil, 3]}
    assert Codec.version() == 1
    assert {:ok, original} = Codec.encode(value)
    assert {:ok, original} == Encoding.encode(original, 1)
    assert {:ok, wrapped} = Encoding.wrap(original, 1, 2)
    assert wrapped != original
    assert {:ok, original} == Encoding.unwrap(wrapped, 2)

    for {format, binary} <- [{1, original}, {2, wrapped}] do
      assert {:ok, ^value} =
               Encoding.decode_event(%{data: binary, codec_version: 1, history_format: format})
    end
  end

  test "unknown layouts, codec versions and implicit downgrade are rejected" do
    assert {:ok, original} = Codec.encode(%{})
    assert {:error, {:unsupported_history_format, 99}} = Encoding.unwrap(original, 99)

    assert {:error, {:unsupported_history_format, 99}} =
             Encoding.validate_rows([%{history_format: 99}], 1)

    assert {:error, :mixed_history_formats} = Encoding.validate_rows([%{history_format: 2}], 1)
    assert {:error, {:unsupported_codec_version, 2}} = Encoding.unwrap(original, 1, 2)
    assert {:error, {:unsupported_history_migration, 2, 1}} = Encoding.wrap(original, 2, 1)
    assert {:error, :invalid_history_envelope} = Encoding.unwrap(original, 2)
    assert {:error, :invalid_payload} = Encoding.unwrap(<<0>>, 1)
  end

  test "an envelope cannot hide tampered bytes or executable terms" do
    assert {:ok, original} = Codec.encode(%{fact: "a"})

    assert {:ok, forged} =
             Codec.encode(
               {"AgentSystemsLab.History.Event", 2, original, String.duplicate("0", 64)}
             )

    assert {:error, :history_checksum_mismatch} = Encoding.unwrap(forged, 2)
    raw = :erlang.term_to_binary({"AgentSystemsLab.Storage", 1, self()})
    assert {:error, :unsupported_term} = Encoding.encode(raw, 2)
    assert {:ok, valid} = Encoding.encode(original, 2)
    assert {:error, :invalid_payload} = Encoding.unwrap(valid <> <<0>>, 2)
  end
end
