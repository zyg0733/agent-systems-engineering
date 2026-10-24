defmodule AgentSystemsLab.Approvals do
  @moduledoc """
  Host-operated approval and finite rework over ordinary durable Workflows.

  Decisions are not model tools. The host authenticates its operator before
  passing a configured actor ID. Release revalidates the current subject and
  returns immutable bytes; it does not publish or apply a patch.
  """
  alias AgentSystemsLab.Approvals.{Cases, Coordinator}

  def create(id, plan, opts \\ []), do: Cases.create(id, plan, opts)
  def load(id), do: Cases.load(id)
  def rebuild(id), do: Cases.rebuild(id)
  def sync(id, opts \\ []), do: Cases.sync(id, opts)

  def pause(id, request, opts \\ []), do: notify(Cases.pause(id, request, opts), id)
  def resume(id, request, opts \\ []), do: notify(Cases.resume(id, request, opts), id)
  def cancel(id, request, opts \\ []), do: notify(Cases.cancel(id, request, opts), id)
  def decide(id, request, opts \\ []), do: notify(Cases.decide(id, request, opts), id)
  def release(id, request, opts \\ []), do: notify(Cases.release(id, request, opts), id)

  def start_link(opts), do: Coordinator.start_link(opts)
  def status(server), do: Coordinator.status(server)
  def wake(server), do: Coordinator.wake(server)
  def stop(server), do: Coordinator.stop(server)

  defp notify(result, id) do
    if match?({:ok, _}, result), do: Coordinator.notify(id)
    result
  end
end
