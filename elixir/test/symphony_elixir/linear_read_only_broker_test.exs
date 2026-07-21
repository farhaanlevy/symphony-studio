# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Linear.ReadOnlyBrokerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Linear.ReadOnlyBroker

  @receipt String.duplicate("a", 64)

  test "uses one bounded packet-four Unix session and completes with no credential" do
    path = private_socket_path()
    {:ok, listener} = listen(path)
    parent = self()

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request_payload} = :gen_tcp.recv(socket, 0, 1_000)
        request = Jason.decode!(request_payload)
        send(parent, {:request, request})

        :ok =
          :gen_tcp.send(
            socket,
            Jason.encode!(%{
              "body" => %{"data" => %{"viewer" => %{"id" => "private-id"}}},
              "ok" => true,
              "receipt" => @receipt,
              "seq" => 1,
              "v" => 1
            })
          )

        {:ok, finish_payload} = :gen_tcp.recv(socket, 0, 1_000)
        finish = Jason.decode!(finish_payload)
        send(parent, {:finish, finish})

        :ok =
          :gen_tcp.send(
            socket,
            Jason.encode!(%{"ok" => true, "receipt" => @receipt, "seq" => 2, "v" => 1})
          )

        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    assert {:ok, :complete} =
             ReadOnlyBroker.with_graphql_for_test(path, fn graphql ->
               assert {:ok, %{"data" => %{"viewer" => %{"id" => "private-id"}}}} =
                        graphql.("connectivity", %{})

               :complete
             end)

    assert_receive {:request,
                    %{
                      "op" => "connectivity",
                      "seq" => 1,
                      "v" => 1,
                      "variables" => %{}
                    }}

    assert_receive {:finish, %{"op" => "finish", "seq" => 2, "v" => 1, "variables" => %{}}}
    Task.await(server)
  end

  test "rejects the public entry unless the fixed sandbox socket selector is present" do
    previous = System.get_env("SYMPHONY_LINEAR_BROKER_SOCKET")

    on_exit(fn ->
      if previous,
        do: System.put_env("SYMPHONY_LINEAR_BROKER_SOCKET", previous),
        else: System.delete_env("SYMPHONY_LINEAR_BROKER_SOCKET")
    end)

    System.put_env("SYMPHONY_LINEAR_BROKER_SOCKET", "/tmp/untrusted.sock")
    assert {:error, :request_failed} = ReadOnlyBroker.with_graphql(fn _graphql -> :unreachable end)
  end

  defp private_socket_path do
    # The immutable fixture deliberately uses a deeply nested TMPDIR. Keep the
    # AF_UNIX pathname beneath the kernel limit while retaining a unique,
    # cleanup-owned filesystem socket.
    Path.join("/tmp", "slb-#{System.unique_integer([:positive, :monotonic])}.sock")
  end

  defp listen(path) do
    File.rm(path)
    :gen_tcp.listen(0, [:binary, active: false, packet: 4, ifaddr: {:local, String.to_charlist(path)}])
  end
end
