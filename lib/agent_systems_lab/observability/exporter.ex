defmodule AgentSystemsLab.Observability.Exporter do
  @moduledoc "Trusted host extension executed only inside the isolated, timed export worker."
  @callback export([map()], keyword()) :: :ok | {:error, term()}
end

defmodule AgentSystemsLab.Observability.Exporters.Null do
  @moduledoc "Drops export batches; local bounded diagnostics remain available."
  @behaviour AgentSystemsLab.Observability.Exporter
  @impl true
  def export(_events, _opts), do: :ok
end

defmodule AgentSystemsLab.Observability.Exporters.JSONL do
  @moduledoc "Appends content-free events to a host-selected existing parent directory."
  @behaviour AgentSystemsLab.Observability.Exporter
  @impl true
  def export(events, opts) do
    with path when is_binary(path) <- Keyword.get(opts, :path),
         true <- Path.type(path) == :absolute do
      File.write(path, Enum.map(events, &[JSON.encode!(&1), "\n"]), [:append])
    else
      _ -> {:error, :invalid_export_path}
    end
  end
end
