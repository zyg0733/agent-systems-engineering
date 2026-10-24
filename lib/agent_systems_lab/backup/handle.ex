defmodule AgentSystemsLab.Backup.Handle do
  @moduledoc "Opaque capability for one newly created, laboratory-owned database."
  @enforce_keys [:capability]
  defstruct [:capability]

  defimpl Inspect do
    def inspect(_, _), do: "#Backup.Handle<private>"
  end
end

defmodule AgentSystemsLab.Backup.Bundle do
  @moduledoc "Opaque capability for a trusted archive created during this BEAM lifetime."
  @enforce_keys [:capability]
  defstruct [:capability]

  defimpl Inspect do
    def inspect(_, _), do: "#Backup.Bundle<trusted-host>"
  end
end
