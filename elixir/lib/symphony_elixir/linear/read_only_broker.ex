# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Linear.ReadOnlyBroker do
  @moduledoc false

  @protocol_version 1
  @socket_path "/run/symphony-readiness/linear-broker.sock"
  @request_limit_bytes 64 * 1_024
  @response_limit_bytes 2 * 1_024 * 1_024 + 64 * 1_024
  @timeout_ms 30_000
  @operations ~w(connectivity validation_project states labels validation_fixtures mutation_schema)

  @type graphql_fun :: (String.t(), map() -> {:ok, map()} | {:error, :request_failed})

  @spec with_graphql((graphql_fun() -> term())) :: {:ok, term()} | {:error, :request_failed}
  def with_graphql(fun) when is_function(fun, 1) do
    case System.get_env("SYMPHONY_LINEAR_BROKER_SOCKET") do
      @socket_path -> with_graphql_at(@socket_path, fun)
      _missing_or_untrusted -> {:error, :request_failed}
    end
  end

  def with_graphql(_invalid), do: {:error, :request_failed}

  @doc false
  @spec with_graphql_for_test(String.t(), (graphql_fun() -> term())) ::
          {:ok, term()} | {:error, :request_failed}
  def with_graphql_for_test(path, fun) when is_binary(path) and is_function(fun, 1),
    do: with_graphql_at(path, fun)

  defp with_graphql_at(path, fun) do
    with {:ok, socket} <- connect(path) do
      try do
        state = %{seq: 0, socket: socket}
        {:ok, agent} = Agent.start_link(fn -> state end)

        try do
          graphql = fn operation, variables -> request(agent, operation, variables) end
          result = fun.(graphql)

          case finish(agent) do
            :ok -> {:ok, result}
            {:error, :request_failed} = error -> error
          end
        after
          if Process.alive?(agent), do: Agent.stop(agent, :normal, @timeout_ms)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp connect(path) when is_binary(path) do
    :gen_tcp.connect(
      {:local, String.to_charlist(path)},
      0,
      [:binary, active: false, packet: 4, packet_size: @response_limit_bytes],
      @timeout_ms
    )
    |> sanitize_socket_result()
  end

  defp request(agent, operation, variables)
       when operation in @operations and is_map(variables) do
    Agent.get_and_update(
      agent,
      fn %{seq: seq} = state ->
        next = seq + 1
        result = exchange(state.socket, next, operation, variables, false)
        {result, %{state | seq: next}}
      end,
      @timeout_ms
    )
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp request(_agent, _operation, _variables), do: {:error, :request_failed}

  defp finish(agent) do
    Agent.get_and_update(
      agent,
      fn %{seq: seq} = state ->
        next = seq + 1
        result = exchange(state.socket, next, "finish", %{}, true)
        {result, %{state | seq: next}}
      end,
      @timeout_ms
    )
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp exchange(socket, seq, operation, variables, finish?) do
    request = %{
      "op" => operation,
      "seq" => seq,
      "v" => @protocol_version,
      "variables" => variables
    }

    with {:ok, payload} <- Jason.encode(request),
         true <- byte_size(payload) <= @request_limit_bytes,
         :ok <- :gen_tcp.send(socket, payload),
         {:ok, response} <- :gen_tcp.recv(socket, 0, @timeout_ms),
         true <- byte_size(response) <= @response_limit_bytes,
         {:ok, decoded} <- Jason.decode(response),
         {:ok, body} <- validate_response(decoded, seq, finish?) do
      if finish?, do: :ok, else: {:ok, body}
    else
      _blocked -> {:error, :request_failed}
    end
  end

  defp validate_response(
         %{
           "body" => body,
           "ok" => true,
           "receipt" => receipt,
           "seq" => seq,
           "v" => @protocol_version
         } = response,
         seq,
         false
       )
       when map_size(response) == 5 and is_map(body) and is_binary(receipt) and
              byte_size(receipt) == 64,
       do: {:ok, body}

  defp validate_response(
         %{"ok" => true, "seq" => seq, "v" => @protocol_version, "receipt" => receipt} = response,
         seq,
         true
       )
       when map_size(response) == 4 and is_binary(receipt) and byte_size(receipt) == 64,
       do: {:ok, %{}}

  defp validate_response(_invalid, _seq, _finish?), do: {:error, :request_failed}

  defp sanitize_socket_result({:ok, socket}), do: {:ok, socket}
  defp sanitize_socket_result(_error), do: {:error, :request_failed}
end
