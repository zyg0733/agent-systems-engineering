defmodule AgentSystemsLab.Evaluation.Report do
  @moduledoc """
  Pure, versioned evaluation reports. Every planned task/trial remains in the
  denominator, including execution and scoring failures. Synthetic lab units
  describe measured local work; they are not tokens or a provider invoice.
  """

  @manifest_keys ~w(schema_version protocol profile seed)
  @protocol_keys ~w(suite_hash scorer_hash pricing_hash split task_ids task_hashes repetitions execution_contract runtime_version measurement_scope)
  @sample_keys ~w(task_id task_hash trial split run_id task_success classification failure_class usage latency_us semantic_result_hash)
  @report_keys ~w(schema_version manifest samples summary by_task by_split samples_hash semantic_signature report_hash)
  @usage_keys ~w(model_attempts output_bytes tool_attempts dispatches)
  @latency_keys ~w(execution scoring total)
  @classifications ~w(success task_failure scorer_error harness_error)
  @failures ~w(success incorrect permission budget timeout unknown scorer_error harness_error)
  @max_samples 10_000
  @max_integer 1_000_000_000_000_000

  @doc "Build a report from a complete fixed task/trial plan and canonical samples."
  def build(manifest, samples) do
    with :ok <- validate_manifest(manifest),
         :ok <- validate_samples(manifest, samples) do
      sorted = Enum.sort_by(samples, &{&1["task_id"], &1["trial"]})

      report = %{
        "schema_version" => 1,
        "manifest" => manifest,
        "samples" => sorted,
        "summary" => aggregate(sorted),
        "by_task" => grouped(sorted, "task_id"),
        "by_split" => grouped(sorted, "split"),
        "samples_hash" => hash(sorted),
        "semantic_signature" => semantic_signature(manifest, sorted)
      }

      {:ok, Map.put(report, "report_hash", hash(report))}
    else
      {:error, reason} -> {:error, {:invalid_report, reason}}
    end
  rescue
    _ -> {:error, {:invalid_report, :malformed_value}}
  end

  @doc "Rebuild every derived value rather than trusting a saved summary or hash."
  def validate(report) do
    with true <- exact_keys?(report, @report_keys),
         true <- report["schema_version"] == 1,
         {:ok, rebuilt} <- build(report["manifest"], report["samples"]),
         true <- rebuilt === report do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_report, :derived_values_mismatch}}
    end
  rescue
    _ -> {:error, {:invalid_report, :malformed_value}}
  end

  @doc "SHA-256 over recursively sorted JSON keys, independent of map enumeration."
  def hash(value) do
    value
    |> canonical()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The fixed v1 local cost model; no currency conversion is performed."
  def pricing do
    %{
      "model_attempt_units" => 1_000,
      "output_byte_units" => 1,
      "tool_attempt_units" => 250,
      "currency" => nil
    }
  end

  @doc "Nearest-rank quantile over all observations, including failed samples."
  def quantile([], _percent), do: nil

  def quantile(values, percent) when is_list(values) and percent in 1..100 do
    rank = max(div(length(values) * percent + 99, 100), 1)
    values |> Enum.sort() |> Enum.at(rank - 1)
  end

  defp validate_manifest(manifest) do
    protocol = if is_map(manifest), do: manifest["protocol"], else: nil

    cond do
      not exact_keys?(manifest, @manifest_keys) ->
        {:error, :manifest_schema}

      manifest["schema_version"] !== 1 ->
        {:error, :schema_version}

      not id?(manifest["profile"]) ->
        {:error, :profile}

      not integer_in?(manifest["seed"], 0, 4_294_967_295) ->
        {:error, :seed}

      not exact_keys?(protocol, @protocol_keys) ->
        {:error, :protocol_schema}

      not Enum.all?(~w(suite_hash scorer_hash pricing_hash), &digest?(protocol[&1])) ->
        {:error, :protocol_hash}

      protocol["pricing_hash"] != hash(pricing()) ->
        {:error, :pricing_hash}

      not id?(protocol["split"]) ->
        {:error, :split}

      not task_ids?(protocol["task_ids"]) ->
        {:error, :task_ids}

      not task_hashes?(protocol["task_ids"], protocol["task_hashes"]) ->
        {:error, :task_hashes}

      not integer_in?(protocol["repetitions"], 1, 100) ->
        {:error, :repetitions}

      length(protocol["task_ids"]) * protocol["repetitions"] > @max_samples ->
        {:error, :sample_limit}

      not Enum.all?(
        ~w(execution_contract runtime_version measurement_scope),
        &text?(protocol[&1])
      ) ->
        {:error, :execution_protocol}

      true ->
        :ok
    end
  end

  defp validate_samples(manifest, samples) when is_list(samples) do
    protocol = manifest["protocol"]

    expected =
      for task <- protocol["task_ids"], trial <- 1..protocol["repetitions"], do: {task, trial}

    cond do
      length(samples) != length(expected) ->
        {:error, :incomplete_samples}

      not Enum.all?(samples, &valid_sample?(&1, protocol)) ->
        {:error, :sample_schema}

      Enum.sort(Enum.map(samples, &{&1["task_id"], &1["trial"]})) != Enum.sort(expected) ->
        {:error, :sample_identity}

      length(Enum.uniq(Enum.map(samples, & &1["run_id"]))) != length(samples) ->
        {:error, :duplicate_run}

      true ->
        :ok
    end
  end

  defp validate_samples(_, _), do: {:error, :samples_schema}

  defp valid_sample?(sample, protocol) do
    exact_keys?(sample, @sample_keys) and
      sample["task_id"] in protocol["task_ids"] and
      sample["task_hash"] == protocol["task_hashes"][sample["task_id"]] and
      integer_in?(sample["trial"], 1, protocol["repetitions"]) and
      sample["split"] == protocol["split"] and id?(sample["run_id"]) and
      is_boolean(sample["task_success"]) and sample["classification"] in @classifications and
      sample["failure_class"] in @failures and coherent_outcome?(sample) and
      valid_usage?(sample["usage"]) and valid_latency?(sample["latency_us"]) and
      digest?(sample["semantic_result_hash"])
  end

  defp coherent_outcome?(%{"task_success" => true} = sample),
    do: sample["classification"] == "success" and sample["failure_class"] == "success"

  defp coherent_outcome?(sample) do
    sample["classification"] != "success" and sample["failure_class"] != "success" and
      case sample["classification"] do
        "scorer_error" -> sample["failure_class"] == "scorer_error"
        "harness_error" -> sample["failure_class"] == "harness_error"
        "task_failure" -> sample["failure_class"] not in ~w(scorer_error harness_error)
        _ -> false
      end
  end

  defp valid_usage?(nil), do: true

  defp valid_usage?(usage),
    do: exact_keys?(usage, @usage_keys) and Enum.all?(@usage_keys, &nonnegative?(usage[&1]))

  defp valid_latency?(latency) do
    exact_keys?(latency, @latency_keys) and
      Enum.all?(@latency_keys, &nonnegative?(latency[&1])) and
      latency["total"] >= latency["execution"] + latency["scoring"]
  end

  defp aggregate(samples) do
    n = length(samples)
    successes = Enum.count(samples, & &1["task_success"])
    tasks = Enum.group_by(samples, & &1["task_id"])

    successful_tasks =
      Enum.count(tasks, fn {_id, trials} -> Enum.all?(trials, & &1["task_success"]) end)

    known = Enum.filter(samples, &is_map(&1["usage"]))
    unknown_count = n - length(known)
    complete = unknown_count == 0

    usage =
      Map.new(@usage_keys, fn key -> {key, Enum.sum(Enum.map(known, & &1["usage"][key]))} end)

    known_units =
      usage["model_attempts"] * 1_000 + usage["output_bytes"] + usage["tool_attempts"] * 250

    units = if complete, do: known_units, else: nil

    %{
      "planned_samples" => n,
      "successful_samples" => successes,
      "success_rate_pct" => percentage(successes, n),
      "task_count" => map_size(tasks),
      "successful_tasks" => successful_tasks,
      "task_success_rate_pct" => percentage(successful_tasks, map_size(tasks)),
      "classification_counts" =>
        Map.new(@classifications, fn classification ->
          {classification, Enum.count(samples, &(&1["classification"] == classification))}
        end),
      "usage" => %{
        "known_sum" => usage,
        "known_count" => length(known),
        "unknown_count" => unknown_count,
        "complete" => complete
      },
      "cost" => %{
        "unit" => "synthetic_lab_unit",
        "known_sum_units" => known_units,
        "total_units" => units,
        "known_count" => length(known),
        "unknown_count" => unknown_count,
        "complete" => complete,
        "per_planned_sample_units" => ratio(units, n),
        "per_successful_sample_units" => ratio(units, successes),
        "usd" => nil
      },
      "latency_us" =>
        Map.new(@latency_keys, fn key ->
          {key, latency(Enum.map(samples, & &1["latency_us"][key]))}
        end)
    }
  end

  defp grouped(samples, key) do
    samples
    |> Enum.group_by(& &1[key])
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {value, group} -> Map.put(aggregate(group), key, value) end)
  end

  defp latency(values) do
    %{
      "count" => length(values),
      "min" => Enum.min(values),
      "max" => Enum.max(values),
      "mean" => Enum.sum(values) / length(values),
      "p50" => quantile(values, 50),
      "p95" => quantile(values, 95)
    }
  end

  defp semantic_signature(manifest, samples) do
    semantic = Enum.map(samples, &Map.drop(&1, ["run_id", "latency_us"]))
    hash(%{"protocol" => manifest["protocol"], "samples" => semantic})
  end

  defp percentage(_numerator, 0), do: nil
  defp percentage(numerator, denominator), do: numerator * 100 / denominator
  defp ratio(nil, _), do: nil
  defp ratio(_, 0), do: nil
  defp ratio(numerator, denominator), do: numerator / denominator

  defp task_ids?(ids) when is_list(ids),
    do: length(ids) in 1..100 and ids == Enum.sort(Enum.uniq(ids)) and Enum.all?(ids, &id?/1)

  defp task_ids?(_), do: false

  defp task_hashes?(ids, hashes),
    do:
      is_map(hashes) and Enum.sort(Map.keys(hashes)) == ids and
        Enum.all?(Map.values(hashes), &digest?/1)

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp integer_in?(value, min, max), do: is_integer(value) and value >= min and value <= max
  defp nonnegative?(value), do: integer_in?(value, 0, @max_integer)
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp id?(value),
    do:
      is_binary(value) and byte_size(value) in 1..256 and
        Regex.match?(~r/\A[A-Za-z0-9_.:@-]+\z/, value)

  defp text?(value),
    do:
      is_binary(value) and byte_size(value) in 1..512 and String.valid?(value) and
        not String.contains?(value, <<0>>)

  defp canonical(map) when is_map(map) do
    [
      "{",
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [JSON.encode!(key), ":", canonical(value)] end)
      |> Enum.intersperse(","),
      "}"
    ]
  end

  defp canonical(list) when is_list(list),
    do: ["[", list |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value), do: JSON.encode!(value)
end
