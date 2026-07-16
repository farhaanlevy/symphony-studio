# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio adds a
# fail-closed injected port for future durable tracker-outbox ownership.

defmodule SymphonyElixir.Tracker.Outbox do
  @moduledoc """
  Non-durable submission port for managed tracker mutations.

  R0 validates the command and delegates it to an explicitly injected sink
  exactly once. It deliberately has no default sink, persistence, retry loop,
  or reconciliation authority; those belong to the durable Studio releases.
  The host must supply `source: :studio` out of band, so an envelope field is
  never treated as proof of model-independent provenance.
  """

  alias SymphonyElixir.Tracker.ManagedMutation

  @type receipt :: term()
  @type error ::
          ManagedMutation.error()
          | :invalid_managed_tracker_outbox_options
          | :managed_tracker_source_required
          | :managed_tracker_outbox_unavailable
          | :managed_tracker_outbox_rejected
          | :managed_tracker_outbox_failed
          | :managed_tracker_outbox_invalid_response

  @callback enqueue(ManagedMutation.t()) :: {:ok, receipt()} | {:error, term()}

  @doc "Validates and submits one managed mutation to an explicitly injected sink."
  @spec submit(ManagedMutation.t() | map() | keyword(), keyword()) ::
          {:ok, receipt()} | {:error, error()}
  def submit(mutation, opts \\ []) do
    with {:ok, managed_mutation} <- ManagedMutation.new(mutation),
         {:ok, sink} <- validate_options(opts) do
      enqueue_once(sink, managed_mutation)
    end
  end

  defp validate_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         true <- Keyword.keys(opts) |> Enum.uniq() |> length() == length(opts),
         true <- Enum.all?(Keyword.keys(opts), &(&1 in [:sink, :source])),
         :ok <- validate_source(Keyword.get(opts, :source)),
         {:ok, sink} <- validate_sink(Keyword.get(opts, :sink)) do
      {:ok, sink}
    else
      false -> {:error, :invalid_managed_tracker_outbox_options}
      {:error, _reason} = error -> error
    end
  end

  defp validate_options(_opts), do: {:error, :invalid_managed_tracker_outbox_options}

  defp validate_source(:studio), do: :ok
  defp validate_source(:model), do: {:error, :model_lifecycle_mutation_denied}
  defp validate_source(nil), do: {:error, :managed_tracker_source_required}
  defp validate_source(_source), do: {:error, :invalid_managed_tracker_outbox_options}

  defp validate_sink(sink) when is_atom(sink) and not is_nil(sink) do
    if Code.ensure_loaded?(sink) and function_exported?(sink, :enqueue, 1),
      do: {:ok, sink},
      else: {:error, :managed_tracker_outbox_unavailable}
  end

  defp validate_sink(_sink), do: {:error, :managed_tracker_outbox_unavailable}

  defp enqueue_once(sink, mutation) do
    case sink.enqueue(mutation) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, _reason} -> {:error, :managed_tracker_outbox_rejected}
      _invalid -> {:error, :managed_tracker_outbox_invalid_response}
    end
  rescue
    _error -> {:error, :managed_tracker_outbox_failed}
  catch
    _kind, _reason -> {:error, :managed_tracker_outbox_failed}
  end
end
