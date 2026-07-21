# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Fake do
  @moduledoc """
  Deterministic in-memory fake for broker contract and recovery tests.

  It is never the public service default and its provider is always `fake`, so
  no fake response can be mistaken for a Linear publication receipt.
  """

  use Agent

  @behaviour SymphonyElixir.Studio.LinearWriteBroker

  alias SymphonyElixir.Studio.Intent.Canonical
  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Result}

  @type scripted_response :: {:ok, Result.t()} | {:error, term()}

  @doc "Starts an isolated fake broker."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    scripts = Keyword.get(opts, :responses, %{})

    Agent.start_link(fn ->
      %{
        calls: [],
        operations: %{},
        responses: normalize_scripts(scripts)
      }
    end)
  end

  @doc "Returns recorded calls in execution order."
  @spec calls(Agent.agent()) :: [map()]
  def calls(server), do: Agent.get(server, &Enum.reverse(&1.calls))

  @doc "Installs ordered responses for one phase and exact idempotency key."
  @spec set_responses(Agent.agent(), :reconcile | :execute, String.t(), [scripted_response()]) ::
          :ok
  def set_responses(server, phase, idempotency_key, responses)
      when phase in [:reconcile, :execute] and is_binary(idempotency_key) and is_list(responses) do
    Agent.update(server, fn state ->
      put_in(state, [:responses, {phase, idempotency_key}], responses)
    end)
  end

  @impl true
  def reconcile(server, %Command{} = command) do
    Agent.get_and_update(server, &perform(:reconcile, command, &1))
  end

  @impl true
  def execute(server, %Command{} = command) do
    Agent.get_and_update(server, &perform(:execute, command, &1))
  end

  defp perform(phase, command, state) do
    call = %{
      phase: phase,
      kind: command.kind,
      idempotency_key: command.idempotency_key,
      subject_id: command.subject_id
    }

    state = %{state | calls: [call | state.calls]}
    key = {phase, command.idempotency_key}

    case Map.get(state.responses, key, []) do
      [response | rest] ->
        next = put_in(state, [:responses, key], rest)
        {response, maybe_remember(response, command, next)}

      [] ->
        default_response(phase, command, state)
    end
  end

  defp default_response(:reconcile, command, state) do
    result = Map.get(state.operations, command.idempotency_key, Result.absent("fake"))
    {{:ok, result}, state}
  end

  defp default_response(:execute, command, state) do
    result = deterministic_result(command)
    {{:ok, result}, put_in(state, [:operations, command.idempotency_key], result)}
  end

  defp deterministic_result(%Command{kind: :issue} = command) do
    %Result{
      status: :confirmed,
      provider: "fake",
      external_id: Canonical.id("fake_issue_", command.idempotency_key, 20),
      issue_identifier: fake_identifier(command.idempotency_key),
      details: %{"outcome" => "created"}
    }
  end

  defp deterministic_result(%Command{kind: :relation} = command) do
    %Result{
      status: :confirmed,
      provider: "fake",
      external_id: Canonical.id("fake_relation_", command.idempotency_key, 20),
      issue_identifier: nil,
      details: %{"outcome" => "created"}
    }
  end

  defp deterministic_result(%Command{kind: :transition} = command) do
    %Result{
      status: :confirmed,
      provider: "fake",
      external_id: command.payload["issue_id"],
      issue_identifier: command.payload["issue_identifier"],
      details: %{"outcome" => "transitioned", "state" => "Todo"}
    }
  end

  defp fake_identifier(key) do
    number =
      key
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, 4)
      |> :binary.decode_unsigned()
      |> rem(900_000)
      |> Kernel.+(100_000)

    "FAKE-#{number}"
  end

  defp maybe_remember({:ok, %Result{status: :confirmed} = result}, command, state) do
    put_in(state, [:operations, command.idempotency_key], result)
  end

  defp maybe_remember(_response, _command, state), do: state

  defp normalize_scripts(scripts) when is_map(scripts) do
    Map.new(scripts, fn
      {{phase, key}, responses}
      when phase in [:reconcile, :execute] and is_binary(key) and is_list(responses) ->
        {{phase, key}, responses}

      {invalid, _responses} ->
        {invalid, []}
    end)
  end

  defp normalize_scripts(_scripts), do: %{}
end
