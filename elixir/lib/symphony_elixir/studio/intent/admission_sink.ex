# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.AdmissionSink do
  @moduledoc """
  Composite event-sink adapter that links real Symphony admission events.

  Configure an orchestrator with this target and an existing downstream sink;
  the downstream remains authoritative for runtime event persistence. Only a
  validated `worker.attempt.started` event with an exact published issue ID can
  move an intent out of `waiting_for_admission`.
  """

  @behaviour SymphonyElixir.EventSink

  alias SymphonyElixir.{Event, EventSink}
  alias SymphonyElixir.EventSink.Noop
  alias SymphonyElixir.Studio.Intent.Store
  alias SymphonyElixir.Studio.IntentService

  @doc "Builds an injectable orchestrator event-sink target."
  @spec target(Store.t(), EventSink.target()) :: EventSink.target()
  def target(%Store{} = store, downstream \\ Noop) do
    {__MODULE__, %{downstream: downstream, store: store}}
  end

  @impl true
  def append(%{downstream: downstream, store: %Store{} = store}, %Event{} = event) do
    case EventSink.append(downstream, event) do
      {:ok, status} = accepted when status in [:appended, :accepted, :duplicate] ->
        link_admission(accepted, event, store)

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def replay(%{downstream: downstream}, run_id, after_sequence, limit) do
    EventSink.replay(downstream, run_id, after_sequence, limit)
  end

  defp link_admission(accepted, event, store) do
    case IntentService.observe_admission_event(event, store: store) do
      {:ok, _linked_count} -> accepted
      {:error, reason} -> {:error, {:intent_admission_link_failed, reason}}
    end
  end
end
