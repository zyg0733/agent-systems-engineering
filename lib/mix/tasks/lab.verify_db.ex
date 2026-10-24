defmodule Mix.Tasks.Lab.VerifyDb do
  @shortdoc "Verifies PostgreSQL atomicity with real pre/post-commit process crashes"
  use Mix.Task

  @impl true
  def run(args) do
    if args != [], do: Mix.raise("Usage: mix lab.verify_db")

    if not Application.get_env(:agent_systems_lab, :database_enabled, true),
      do: Mix.raise("lab.verify_db requires PostgreSQL; LAB_DATABASE_ENABLED must be true")

    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Mix.Task.run("app.start")

    case AgentSystemsLab.StorageVerification.run() do
      {:ok, report} ->
        Mix.shell().info("PostgreSQL crash verification passed")
        Mix.shell().info(inspect(report, pretty: true, limit: :infinity))

      {:error, reason} ->
        Mix.raise("Database verification failed: #{inspect(reason)}")
    end
  end
end
