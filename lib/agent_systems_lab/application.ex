defmodule AgentSystemsLab.Application do
  @moduledoc """
  Supervises teaching runs and the explicitly enabled durable dispatcher.

  Run children are temporary: restarting a process is deliberately not presented
  as recovery of its in-memory history or mock effects.
  """
  use Application

  @impl true
  def start(_type, _args) do
    database? = Application.get_env(:agent_systems_lab, :database_enabled, true)
    scheduler? = Application.get_env(:agent_systems_lab, :scheduler_enabled, false)

    if scheduler? and not database?,
      do: raise(ArgumentError, "the durable scheduler requires PostgreSQL")

    storage_children =
      if database?,
        do: [AgentSystemsLab.Repo],
        else: []

    scheduler_children =
      if scheduler?,
        do: [
          {AgentSystemsLab.Scheduler,
           Application.get_env(:agent_systems_lab, :scheduler_options, [])}
        ],
        else: []

    children =
      storage_children ++
        [
          {Registry, keys: :unique, name: AgentSystemsLab.Registry},
          {Task.Supervisor, name: AgentSystemsLab.ProviderSupervisor},
          {DynamicSupervisor, strategy: :one_for_one, name: AgentSystemsLab.RunSupervisor}
        ] ++
        scheduler_children ++
        [
          {AgentSystemsLab.Observability.Buffer,
           Application.get_env(:agent_systems_lab, :observability_options, [])}
        ]

    # Runs depend on Registry ownership. If it is lost, stop the volatile runs
    # too; otherwise a fresh registry could admit duplicate live owners.
    Supervisor.start_link(children, strategy: :rest_for_one, name: AgentSystemsLab.Supervisor)
  end
end
