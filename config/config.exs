import Config

config :agent_systems_lab, ecto_repos: [AgentSystemsLab.Repo]

config :agent_systems_lab,
       :database_enabled,
       System.get_env("LAB_DATABASE_ENABLED", "true") == "true"

config :agent_systems_lab,
       :scheduler_enabled,
       System.get_env("LAB_SCHEDULER_ENABLED", "false") == "true"

config :agent_systems_lab, :scheduler_options,
  name: AgentSystemsLab.Scheduler,
  max_workers: 2,
  poll_interval_ms: 100,
  lease_ms: 5_000,
  renew_interval_ms: 1_000

repo_options = [
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("PGPORT", "55432")),
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD"),
  database: "agent_systems_lab_#{config_env()}",
  pool_size: 10,
  log: false,
  parameters: [synchronous_commit: "on"],
  priv: "priv/repo"
]

repo_options =
  case System.get_env("DATABASE_URL") do
    nil -> repo_options
    url -> Keyword.put(repo_options, :url, url)
  end

config :agent_systems_lab, AgentSystemsLab.Repo, repo_options
