defmodule AgentSystemsLab.RetryDemoTest do
  use ExUnit.Case, async: false
  alias AgentSystemsLab.{ReconciliationQueue, Repo, RetryDemo}
  alias AgentSystemsLab.Storage.Codec
  @moduletag :database

  test "finite backoff survives a kill and new VM while manual unknown stays visible" do
    output =
      Path.join(File.cwd!(), "artifacts/retry-demo-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(output) end)
    assert {:ok, result} = RetryDemo.run(output: output)
    report = result.report
    keys = ~w(model_retry exhausted_retry idempotent_tool manual_unknown queryable_timeout)
    ids = Enum.map(keys, &report[&1]["run_id"])
    on_exit(fn -> Enum.each(ids, &Repo.query!("DELETE FROM lab_runs WHERE id=$1", [&1])) end)
    assert report["all_passed"]
    assert report["model_retry"]["model_attempts"] == 3
    assert report["model_retry"]["accepted_results"] == 1
    assert report["model_retry"]["fresh_vm_due_preserved"]
    assert report["exhausted_retry"]["attempts"] == 3
    assert report["exhausted_retry"]["delays_ms"] == [25, 50]
    assert report["idempotent_tool"]["effect_samples"] == [0, 0, 1]
    assert report["manual_unknown"]["automatic_redeliveries"] == 0
    assert {:ok, entry} = ReconciliationQueue.get(report["manual_unknown"]["run_id"])
    assert entry.safe_mode == :manual
    assert report["queryable_timeout"]["original_receipt_queried"]
    assert {:ok, journals} = Codec.decode(File.read!(Path.join(output, "journals.bin")))
    assert length(journals) == 5
    assert File.read!(Path.join(output, "fresh-vm.log")) =~ "RETRY_AUDIT="
    assert {:error, {:output_exists, ^output}} = RetryDemo.run(output: output)
  end
end
