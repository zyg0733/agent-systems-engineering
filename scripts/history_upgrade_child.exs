config = Config.Reader.read!("config/config.exs", env: :dev, target: :host)
Application.put_all_env(config)
[action, output] = System.argv()
# Only the fixed, trusted offline schema-upgrade action gets a maintenance
# session. The database default read-only gate and other sessions stay closed.
if action == "upgrade_legacy_restore" do
  options = Application.fetch_env!(:agent_systems_lab, AgentSystemsLab.Repo)
  parameters = Keyword.put(options[:parameters] || [], :default_transaction_read_only, "off")
  Application.put_env(:agent_systems_lab, AgentSystemsLab.Repo, Keyword.put(options, :parameters, parameters))
end
Application.put_env(:agent_systems_lab, :scheduler_enabled, false)
{:ok, _} = Application.ensure_all_started(:agent_systems_lab)
result = try do
  AgentSystemsLab.HistoryUpgradeDemo.child_action(action, output)
rescue
  error ->
    File.write!(Path.join(output, action <> "-error.log"), Exception.format(:error, error, __STACKTRACE__))
    reraise error, __STACKTRACE__
end
IO.puts("UPGRADE_RESULT=" <> JSON.encode!(result))
