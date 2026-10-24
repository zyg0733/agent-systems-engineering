defmodule AgentSystemsLab.DatabaseProxyTest do
  use ExUnit.Case, async: true
  alias AgentSystemsLab.Faults.DatabaseProxy

  test "fragments protocol frames, drops only a completed COMMIT acknowledgement and heals" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, backend_port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()

    backend =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, <<8::32, 196_608::32>>} = :gen_tcp.recv(socket, 8, 2_000)
        send(parent, :startup_seen)
        {:ok, <<?Q, 11::32, "COMMIT", 0>>} = :gen_tcp.recv(socket, 12, 2_000)
        send(parent, :commit_reached_backend)
        :ok = :gen_tcp.send(socket, <<?C, 11::32, "COM">>)
        receive do: (:complete -> :ok)
        :ok = :gen_tcp.send(socket, <<"MIT", 0, ?Z, 5::32, ?I>>)
        send(parent, :commit_complete_sent)
        receive do: (:stop -> :gen_tcp.close(socket))
      end)

    on_exit(fn -> Process.exit(backend, :kill) end)
    {:ok, proxy} = DatabaseProxy.start_link("127.0.0.1", backend_port)
    port = DatabaseProxy.port(proxy)
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    :ok = :gen_tcp.send(client, <<8::32>>)
    :ok = :gen_tcp.send(client, <<196_608::32>>)
    assert_receive :startup_seen
    :ok = DatabaseProxy.trap_commit_ack(proxy)
    :ok = :gen_tcp.send(client, <<?Q, 11::32, "COM">>)
    :ok = :gen_tcp.send(client, <<"MIT", 0>>)
    assert_receive :commit_reached_backend
    assert {:error, :timeout} = :gen_tcp.recv(client, 0, 20)
    assert DatabaseProxy.status(proxy).ack_dropped == 0
    send(backend, :complete)
    assert_receive :commit_complete_sent
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)

    assert %{ack_dropped: 1, dropped: 1, mode: :blocked, connections: 0} =
             DatabaseProxy.status(proxy)

    {:ok, rejected} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
    assert {:error, :closed} = :gen_tcp.recv(rejected, 0, 1_000)
    assert DatabaseProxy.status(proxy).rejected == 1
    assert :ok = DatabaseProxy.heal(proxy)
    assert DatabaseProxy.status(proxy).mode == :healthy
    assert :ok = DatabaseProxy.stop(proxy)
    send(backend, :stop)

    assert {:error, :econnrefused} =
             :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)
  end

  test "disconnect closes existing clients without touching the backend listener" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, backend_port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, proxy} = DatabaseProxy.start_link("127.0.0.1", backend_port)

    {:ok, client} =
      :gen_tcp.connect(~c"127.0.0.1", DatabaseProxy.port(proxy), [:binary, active: false], 1_000)

    {:ok, backend} = :gen_tcp.accept(listener, 1_000)
    :ok = DatabaseProxy.disconnect(proxy)
    assert {:error, :closed} = :gen_tcp.recv(client, 0, 1_000)
    assert {:error, :closed} = :gen_tcp.recv(backend, 0, 1_000)
    assert {:ok, _} = :inet.sockname(listener)
    assert :ok = DatabaseProxy.stop(proxy)
  end
end
