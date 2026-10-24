defmodule AgentSystemsLab.Repo do
  @moduledoc "PostgreSQL repository; crash tests use real commits, not SQL Sandbox."
  use Ecto.Repo, otp_app: :agent_systems_lab, adapter: Ecto.Adapters.Postgres
end
