defmodule AgentSystemsLab.MixProject do
  use Mix.Project

  def project do
    [
      app: :agent_systems_lab,
      version: "0.1.0-dev",
      description: "Offline Elixir/OTP teaching lab for Agent Systems Engineering",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      package: [
        licenses: ["Apache-2.0", "CC-BY-4.0"],
        links: %{
          "Apache-2.0" => "https://www.apache.org/licenses/LICENSE-2.0.txt",
          "CC BY 4.0" => "https://creativecommons.org/licenses/by/4.0/"
        },
        files: [
          ".gitattributes",
          ".formatter.exs",
          ".github",
          ".gitignore",
          ".tool-versions",
          "README.md",
          "LICENSE",
          "LICENSE-DOCS",
          "NOTICE",
          "mix.exs",
          "mix.lock",
          "Agent Systems Engineering 研究与落地计划.md",
          "book",
          "config",
          "docs",
          "fixtures",
          "labs",
          "lib",
          "priv",
          "scripts",
          "test"
        ]
      ],
      deps: [{:ecto_sql, "~> 3.14.0"}, {:postgrex, "~> 0.22.0"}],
      ecto_repos: [AgentSystemsLab.Repo],
      aliases: [
        setup: ["ecto.create", "ecto.migrate"],
        check: [
          "format --check-formatted",
          "compile --warnings-as-errors",
          "ecto.create --quiet",
          "ecto.migrate --quiet",
          "test",
          "lab.verify",
          "lab.verify_db"
        ]
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AgentSystemsLab.Application, []}]
  end

  def cli, do: [preferred_envs: [check: :test, "lab.verify_db": :test]]
end
