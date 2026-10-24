defmodule AgentSystemsLab.HistoryCompatibilityTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.History.{Compatibility, ReadonlyProof, RestoreGuard}

  test "version domains are independent and unknown history never falls back" do
    assert :ok =
             Compatibility.validate_versions(%{
               kernel_schema: 1,
               event_schema: 1,
               codec: 1,
               history_format: 2,
               sidecar_schema: 1
             })

    for {domain, version} <- [
          {:kernel_schema, 2},
          {:event_schema, 2},
          {:codec, 2},
          {:history_format, 3},
          {:sidecar_schema, 2},
          {:history_format, nil},
          {:history_format, "1"}
        ] do
      assert {:error, {:incompatible_version, name, ^version}} =
               Compatibility.validate_versions(%{domain => version})

      assert name === Atom.to_string(domain)
    end

    assert {:error, {:unknown_version_domain, "guessed"}} =
             Compatibility.validate_versions(%{guessed: 1})

    assert {:error, :invalid_version_manifest} = Compatibility.validate_versions([])
  end

  test "a partial or ordinary projection cannot authorize activation" do
    assert {:error, :invalid_restore_proof} = ReadonlyProof.compare(%{}, %{})
    tagged = %{"proof_kind" => "verified_source", "scope_complete" => true}
    assert {:error, :invalid_restore_proof} = ReadonlyProof.compare(tagged, tagged)
    assert {:error, :invalid_restore_proof} = ReadonlyProof.compare_semantics(tagged, tagged)

    assert {:error, :invalid_restore_proof} =
             ReadonlyProof.compare_semantics(%{"proof_kind" => "verified_source"}, %{
               "proof_kind" => "verified_source"
             })

    assert {:error, :invalid_restore_proof} = ReadonlyProof.compare_semantics(%{}, %{})

    assert {:error, :verified_source_proof_required} =
             RestoreGuard.activate(%{}, %{runs: [], workflows: [], cases: []}, %{})

    assert {:error, :invalid_restore_scope} = ReadonlyProof.capture(%{runs: []})

    assert {:error, :invalid_restore_scope} =
             ReadonlyProof.capture(%{runs: ["duplicate", "duplicate"], workflows: [], cases: []})
  end
end
