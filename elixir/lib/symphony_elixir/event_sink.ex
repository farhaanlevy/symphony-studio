# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio adds an
# optional structured-event boundary while preserving a no-persistence runner.

defmodule SymphonyElixir.EventSink do
  @moduledoc """
  Injected boundary for normalized runtime events.

  The default adapter deliberately retains nothing, so the core Symphony
  runner does not depend on Studio persistence. A sink target is either an
  adapter module or an `{adapter, server}` pair. Adapters own delivery and
  retention; callers own event sequence assignment.
  """

  alias SymphonyElixir.{Event, Identity}
  alias SymphonyElixir.EventSink.Noop

  @type target :: module() | {module(), term()}
  @type append_status :: :appended | :duplicate
  @type append_error ::
          {:invalid_event, term()}
          | {:invalid_sink, term()}
          | {:event_sink_unavailable, module()}
          | {:event_conflict, map()}
          | {:history_evicted, map()}
          | {:sequence_gap, map()}
          | {:event_too_large, map()}

  @type replay_page :: %{
          events: [Event.t()],
          earliest_sequence: pos_integer(),
          latest_sequence: pos_integer(),
          requested_after: non_neg_integer()
        }

  @type replay_error ::
          {:invalid_replay_request, term()}
          | {:invalid_sink, term()}
          | {:event_sink_unavailable, module()}
          | {:replay_unavailable, map()}
          | {:replay_gap, map()}

  @callback append(term(), Event.t()) ::
              {:ok, append_status()} | {:error, append_error()}

  @callback replay(
              term(),
              String.t(),
              non_neg_integer(),
              pos_integer()
            ) :: {:ok, replay_page()} | {:error, replay_error()}

  @doc "Returns the configured event sink, defaulting to the retaining-nothing adapter."
  @spec default_target() :: target()
  def default_target do
    Application.get_env(:symphony_elixir, :event_sink, Noop)
  end

  @doc "Appends a validated event to the configured sink."
  @spec append(Event.t()) :: {:ok, append_status()} | {:error, append_error()}
  def append(event), do: append(default_target(), event)

  @doc "Appends a validated event to an injected sink."
  @spec append(target(), Event.t()) :: {:ok, append_status()} | {:error, append_error()}
  def append(target, event) do
    with :ok <- validate_event(event),
         {:ok, {adapter, server}} <- normalize_target(target),
         :ok <- ensure_adapter(adapter, :append, 2) do
      safe_adapter_call(adapter, fn -> adapter.append(server, event) end)
    end
  end

  @doc "Replays events after a per-run sequence cursor from the configured sink."
  @spec replay(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, replay_page()} | {:error, replay_error()}
  def replay(run_id, after_sequence, limit) do
    replay(default_target(), run_id, after_sequence, limit)
  end

  @doc "Replays events after a per-run sequence cursor from an injected sink."
  @spec replay(target(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, replay_page()} | {:error, replay_error()}
  def replay(target, run_id, after_sequence, limit) do
    with :ok <- validate_replay_request(run_id, after_sequence, limit),
         {:ok, {adapter, server}} <- normalize_target(target),
         :ok <- ensure_adapter(adapter, :replay, 4) do
      safe_adapter_call(adapter, fn -> adapter.replay(server, run_id, after_sequence, limit) end)
    end
  end

  defp validate_event(%Event{} = event) do
    case Event.validate(event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_event, reason}}
    end
  end

  defp validate_event(_event), do: {:error, {:invalid_event, {:event, :expected_event_struct}}}

  defp validate_replay_request(run_id, after_sequence, limit) do
    with :ok <- validate_replay_run_id(run_id),
         :ok <- validate_replay_cursor(after_sequence) do
      validate_replay_limit(limit)
    end
  end

  defp validate_replay_run_id(run_id) do
    if canonical_uuid4?(run_id),
      do: :ok,
      else: invalid_replay_field(:run_id, :must_be_canonical_uuid4)
  end

  defp validate_replay_cursor(after_sequence)
       when is_integer(after_sequence) and after_sequence >= 0,
       do: :ok

  defp validate_replay_cursor(_after_sequence),
    do: invalid_replay_field(:after_sequence, :must_be_non_negative_integer)

  defp validate_replay_limit(limit) when is_integer(limit) and limit > 0, do: :ok
  defp validate_replay_limit(_limit), do: invalid_replay_field(:limit, :must_be_positive_integer)

  defp invalid_replay_field(field, reason),
    do: {:error, {:invalid_replay_request, %{field: field, reason: reason}}}

  defp canonical_uuid4?(value) when is_binary(value) do
    byte_size(value) == 36 and String.valid?(value) and value == String.downcase(value) and
      Identity.valid_uuid4?(value)
  end

  defp canonical_uuid4?(_value), do: false

  defp normalize_target({adapter, server}) when is_atom(adapter), do: {:ok, {adapter, server}}
  defp normalize_target(adapter) when is_atom(adapter), do: {:ok, {adapter, adapter}}
  defp normalize_target(target), do: {:error, {:invalid_sink, target}}

  defp ensure_adapter(adapter, function, arity) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, function, arity) do
      :ok
    else
      {:error, {:event_sink_unavailable, adapter}}
    end
  end

  defp safe_adapter_call(adapter, callback) do
    callback.()
  rescue
    _error -> {:error, {:event_sink_unavailable, adapter}}
  catch
    _kind, _reason -> {:error, {:event_sink_unavailable, adapter}}
  end
end
