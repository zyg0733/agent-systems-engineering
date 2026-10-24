defmodule AgentSystemsLab do
  @moduledoc """
  Starts isolated, manually stepped runs under the application's supervisor.

  The labs need no model credentials or external tools. Memory mode makes no
  database writes. Pass `storage: :postgres` to persist accepted run transitions;
  mock effects, provider cursors and streaming control counters remain in memory.
  Use RunServer.start_stream/1 for nonblocking model requests, and its cancel/2
  control to stop further work while retaining confirmed facts.

  File tools are enabled only with an explicit private `workspace` directory.
  Their real filesystem effects outlive the volatile adapter ledger and cannot
  be rolled back by cancelling a run or rolling back its database transaction.
  """

  alias AgentSystemsLab.RunServer

  @spec start_run(keyword()) :: DynamicSupervisor.on_start_child()
  def start_run(opts) do
    DynamicSupervisor.start_child(AgentSystemsLab.RunSupervisor, {RunServer, opts})
  end
end
