defmodule AgentSystemsLab.Backup.Manager do
  @moduledoc false
  use GenServer

  def ensure_started do
    case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      _ -> {:error, :backup_registry_unavailable}
    end
  end

  def put(kind, value) do
    with :ok <- ensure_started() do
      capability = :crypto.strong_rand_bytes(32)
      :ok = GenServer.call(__MODULE__, {:put, kind, capability, value})
      {:ok, capability}
    end
  end

  def get(kind, capability) when is_binary(capability) do
    with :ok <- ensure_started(),
         do: GenServer.call(__MODULE__, {:get, kind, capability})
  end

  def get(_, _), do: {:error, :invalid_backup_capability}

  def update(kind, capability, changes) do
    with :ok <- ensure_started(),
         do: GenServer.call(__MODULE__, {:update, kind, capability, changes})
  end

  def delete(kind, capability) do
    with :ok <- ensure_started(),
         do: GenServer.call(__MODULE__, {:delete, kind, capability})
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put, kind, key, value}, _from, state),
    do: {:reply, :ok, Map.put(state, {kind, key}, value)}

  def handle_call({:get, kind, key}, _from, state),
    do: {:reply, Map.fetch(state, {kind, key}) |> found(), state}

  def handle_call({:update, kind, key, changes}, _from, state) do
    case Map.fetch(state, {kind, key}) do
      {:ok, value} -> {:reply, :ok, Map.put(state, {kind, key}, Map.merge(value, changes))}
      :error -> {:reply, {:error, :invalid_backup_capability}, state}
    end
  end

  def handle_call({:delete, kind, key}, _from, state),
    do: {:reply, :ok, Map.delete(state, {kind, key})}

  defp found({:ok, value}), do: {:ok, value}
  defp found(:error), do: {:error, :invalid_backup_capability}
end
