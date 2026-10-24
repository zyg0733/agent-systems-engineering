defmodule AgentSystemsLab.Workflows do
  @moduledoc """
  Durable DAG orchestration over the existing Run scheduler.

  Creation and dependency advancement write facts through `Workflows.Store`.
  `load/1` is read-only. A Coordinator is an optional, replaceable polling owner;
  stopping it pauses delivery without cancelling the durable Workflow. Each node
  remains an ordinary enrolled Run with its original permissions, accounting,
  receipts, leases and reconciliation requirements.
  """

  alias AgentSystemsLab.Workflows.{ControlStore, Coordinator, Store}

  def create(id, definition, opts \\ []), do: Store.create(id, definition, opts)
  def load(id), do: Store.load(id)
  def sync(id, opts \\ []), do: Store.sync(id, opts)
  def rebuild(id), do: Store.rebuild(id)

  def cancel(id, reason \\ :user_requested, opts \\ []) do
    result = Store.cancel(id, reason, opts)
    if match?({:ok, _}, result), do: Coordinator.notify(id)
    result
  end

  def pause(id, reason \\ :user_requested, opts \\ []) do
    with {:ok, _} <- ControlStore.pause(id, reason, opts),
         {:ok, view} <- Store.load(id) do
      Coordinator.notify(id)
      {:ok, view}
    end
  end

  def resume(id, opts \\ []) do
    with {:ok, _} <- ControlStore.resume(id, opts),
         {:ok, view} <- Store.load(id) do
      Coordinator.notify(id)
      {:ok, view}
    end
  end

  def start_link(opts), do: Coordinator.start_link(opts)
  def status(server), do: Coordinator.status(server)
  def wake(server), do: Coordinator.wake(server)
  def stop(server), do: Coordinator.stop(server)
end
