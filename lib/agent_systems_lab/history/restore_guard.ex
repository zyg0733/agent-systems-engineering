defmodule AgentSystemsLab.History.RestoreGuard do
  @moduledoc """
  Explicit trusted-host activation of an owned, staged restored database.

  Activation requires an exact copy of a verified complete source proof. It
  revokes every pending intent's copied lease and advances its fencing generation
  in one transaction, without consuming a dispatch, changing a run sequence,
  resetting a deadline, or reconciling an unknown tool result. Only then may the
  backup backend lift the database's operational write gate. This is not a tool
  exposed to model-authored input.
  """
  alias AgentSystemsLab.Backup
  alias AgentSystemsLab.History.ReadonlyProof

  def activate(handle, scope, source_proof) do
    with :ok <- valid_source(source_proof),
         {:ok, metadata} <- Backup.metadata(handle),
         :ok <- staged_target(metadata, source_proof) do
      Backup.activate_restore(handle, fn conn ->
        with {:ok, _} <- Postgrex.query(conn, "BEGIN", []) do
          result = fence(conn, scope, source_proof)

          case result do
            {:ok, value} ->
              case Postgrex.query(conn, "COMMIT", []) do
                {:ok, _} -> {:ok, value}
                _ -> rollback(conn, :restore_activation_commit_failed)
              end

            {:error, reason} ->
              rollback(conn, reason)
          end
        else
          _ -> {:error, :restore_activation_transaction_failed}
        end
      end)
    end
  rescue
    _ -> {:error, :restore_activation_failed}
  catch
    _, _ -> {:error, :restore_activation_failed}
  end

  defp fence(conn, scope, source_proof) do
    # Match scheduler admission's Queue -> Run -> Intent order. These are staged,
    # quiescent databases; an active target can never enter this function.
    with {:ok, _} <-
           Postgrex.query(conn, "SELECT name FROM lab_queues ORDER BY name FOR UPDATE", []),
         {:ok, _} <- Postgrex.query(conn, "SELECT id FROM lab_runs ORDER BY id FOR UPDATE", []),
         {:ok, _} <-
           Postgrex.query(conn, "SELECT id FROM lab_intents ORDER BY run_id,seq FOR UPDATE", []),
         {:ok, copied} <- ReadonlyProof.capture_connection(conn, scope),
         :ok <- ReadonlyProof.compare(source_proof, copied),
         {:ok, generations} <-
           Postgrex.query(
             conn,
             "SELECT run_id, seq, claim_generation FROM lab_intents WHERE status='pending' ORDER BY run_id,seq",
             []
           ),
         true <-
           Enum.all?(generations.rows, fn [_, _, generation] ->
             is_integer(generation) and generation >= 0 and generation < 2_147_483_646
           end) || {:error, :fencing_generation_exhausted},
         {:ok, changed} <-
           Postgrex.query(
             conn,
             "UPDATE lab_intents SET claim_token=NULL, claim_owner=NULL, claim_expires_at=NULL, claim_generation=claim_generation+1, updated_at=timezone('UTC',clock_timestamp()) WHERE status='pending'",
             []
           ),
         {:ok, fenced} <- ReadonlyProof.capture_connection(conn, scope),
         true <-
           copied["protected_hash"] === fenced["protected_hash"] ||
             {:error, :activation_changed_protected_facts},
         true <-
           copied["raw_semantic_hash"] === fenced["raw_semantic_hash"] ||
             {:error, :activation_changed_run_state} do
      {:ok,
       %{
         "schema_version" => 1,
         "activated" => true,
         "revoked_pending_intents" => changed.num_rows,
         "generations" =>
           Enum.map(generations.rows, fn [run, seq, generation] ->
             %{"run_id" => run, "seq" => seq, "before" => generation, "after" => generation + 1}
           end),
         "source_database_hash" => source_proof["database_hash"],
         "restored_database_hash" => fenced["database_hash"],
         "protected_hash" => fenced["protected_hash"],
         "raw_semantic_hash" => fenced["raw_semantic_hash"],
         "lease_policy" => "revoke_then_explicit_resume"
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :restore_activation_failed}
    end
  end

  defp valid_source(proof) do
    case ReadonlyProof.validate(proof, :source) do
      :ok -> :ok
      _ -> {:error, :verified_source_proof_required}
    end
  end

  defp staged_target(%{origin: :restored, readonly: true, source_database: source}, proof) do
    if source === proof["database_name"],
      do: :ok,
      else: {:error, :restore_source_database_mismatch}
  end

  defp staged_target(_, _), do: {:error, :restore_target_not_staged}

  defp rollback(conn, reason) do
    Postgrex.query(conn, "ROLLBACK", [])
    {:error, reason}
  end
end
