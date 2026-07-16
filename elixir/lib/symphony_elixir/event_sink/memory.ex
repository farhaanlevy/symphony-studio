# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio adds a bounded,
# process-local replay adapter for event contract tests and optional consumers.

defmodule SymphonyElixir.EventSink.Memory do
  @moduledoc """
  Bounded, process-local event sink with per-run replay.

  Producers assign sequences. The adapter rejects gaps and conflicts, accepts
  exact duplicates idempotently, and keeps run domains independent. Per-run
  event and deduplication retention is deterministic FIFO; global run eviction
  removes the run whose most recent successful new-event append is oldest.
  Replay and duplicate access do not refresh that order. The adapter is
  explicitly non-durable: a process restart loses all events and deduplication
  history.
  """

  use GenServer

  @behaviour SymphonyElixir.EventSink

  alias SymphonyElixir.Event

  @default_max_runs 128
  @default_max_events_per_run 512
  @default_max_bytes_per_run 2 * 1_024 * 1_024
  @default_max_total_bytes 64 * 1_024 * 1_024
  @default_max_dedup_entries_per_run 1_024
  @default_max_replay_limit 512

  defmodule State do
    @moduledoc false

    defstruct runs: %{},
              run_order: :queue.new(),
              evicted_runs: %{},
              evicted_order: :queue.new(),
              total_bytes: 0,
              max_runs: nil,
              max_events_per_run: nil,
              max_bytes_per_run: nil,
              max_total_bytes: nil,
              max_dedup_entries_per_run: nil,
              max_replay_limit: nil
  end

  @doc "Starts an optional, process-local event sink."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    server_options = if Keyword.keyword?(opts), do: Keyword.take(opts, [:name]), else: []
    GenServer.start_link(__MODULE__, opts, server_options)
  end

  @impl true
  def append(server, %Event{} = event), do: GenServer.call(server, {:append, event})

  @impl true
  def replay(server, run_id, after_sequence, limit) do
    GenServer.call(server, {:replay, run_id, after_sequence, limit})
  end

  @impl true
  def init(opts) do
    case build_state(opts) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:append, event}, _from, %State{} = state) do
    case prepare_record(event, state) do
      {:ok, record, dedup_record} ->
        case append_record(state, record, dedup_record) do
          {:ok, status, next_state} -> {:reply, {:ok, status}, next_state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:replay, run_id, after_sequence, limit}, _from, %State{} = state) do
    reply = replay_events(state, run_id, after_sequence, limit)
    {:reply, reply, state}
  end

  defp build_state(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      build_keyword_state(opts)
    else
      {:error, {:invalid_option, :expected_keyword_list}}
    end
  end

  defp build_state(_opts), do: {:error, {:invalid_option, :expected_keyword_list}}

  defp build_keyword_state(opts) do
    allowed = [
      :name,
      :max_runs,
      :max_events_per_run,
      :max_bytes_per_run,
      :max_total_bytes,
      :max_dedup_entries_per_run,
      :max_replay_limit
    ]

    with :ok <- reject_unknown_options(opts, allowed),
         {:ok, max_runs} <- positive_option(opts, :max_runs, @default_max_runs),
         {:ok, max_events} <-
           positive_option(opts, :max_events_per_run, @default_max_events_per_run),
         {:ok, max_run_bytes} <-
           positive_option(opts, :max_bytes_per_run, @default_max_bytes_per_run),
         {:ok, max_total_bytes} <-
           positive_option(opts, :max_total_bytes, @default_max_total_bytes),
         {:ok, max_dedup} <-
           positive_option(
             opts,
             :max_dedup_entries_per_run,
             @default_max_dedup_entries_per_run
           ),
         {:ok, max_replay} <-
           positive_option(opts, :max_replay_limit, @default_max_replay_limit),
         :ok <- validate_dedup_bound(max_dedup, max_events) do
      {:ok,
       %State{
         max_runs: max_runs,
         max_events_per_run: max_events,
         max_bytes_per_run: max_run_bytes,
         max_total_bytes: max_total_bytes,
         max_dedup_entries_per_run: max_dedup,
         max_replay_limit: max_replay
       }}
    end
  end

  defp reject_unknown_options(opts, allowed) do
    keys = Keyword.keys(opts)
    unknown = Enum.reject(keys, &(&1 in allowed))

    case {unknown, length(keys) == MapSet.size(MapSet.new(keys))} do
      {[], true} -> :ok
      {[option | _rest], _unique} -> {:error, {:invalid_option, option}}
      {[], false} -> {:error, {:invalid_option, :duplicate_option}}
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, {:invalid_option, key}}
    end
  end

  defp validate_dedup_bound(max_dedup, max_events) when max_dedup >= max_events, do: :ok

  defp validate_dedup_bound(_max_dedup, _max_events) do
    {:error, {:invalid_option, :max_dedup_entries_per_run}}
  end

  defp prepare_record(%Event{} = event, %State{} = state) do
    event_map = Event.to_map(event)

    encoded = Jason.encode!(event_map)

    case byte_size(encoded) do
      size when size <= state.max_bytes_per_run and size <= state.max_total_bytes ->
        record = %{
          event: event,
          event_id: event.event_id,
          sequence: event.sequence,
          bytes: size
        }

        dedup_record = %{
          event_id: event.event_id,
          sequence: event.sequence,
          fingerprint: fingerprint(event_map)
        }

        {:ok, record, dedup_record}

      size when is_integer(size) ->
        {:error,
         {:event_too_large,
          %{
            bytes: size,
            max_bytes_per_run: state.max_bytes_per_run,
            max_total_bytes: state.max_total_bytes
          }}}
    end
  end

  defp fingerprint(event_map) do
    event_map
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp append_record(%State{} = state, record, dedup_record) do
    run_id = record.event.run_id

    case {Map.fetch(state.runs, run_id), Map.fetch(state.evicted_runs, run_id)} do
      {{:ok, run}, _tombstone} ->
        append_by_sequence(state, run_id, run, record, dedup_record)

      {:error, {:ok, tombstone}} ->
        {:error, history_evicted(run_id, tombstone.latest_sequence, :run_evicted)}

      {:error, :error} ->
        append_to_new_run(state, run_id, record, dedup_record)
    end
  end

  defp append_to_new_run(state, run_id, %{sequence: 1} = record, dedup_record) do
    run = empty_run() |> retain_record(record, dedup_record, state)
    {:ok, :appended, put_run(state, run_id, run)}
  end

  defp append_to_new_run(_state, run_id, record, _dedup_record) do
    {:error, sequence_gap(run_id, 1, record.sequence)}
  end

  defp append_by_sequence(state, run_id, run, record, dedup_record) do
    case Map.fetch(run.dedup_by_sequence, record.sequence) do
      {:ok, retained} ->
        compare_duplicate(state, run_id, retained, record, dedup_record)

      :error when record.sequence == run.latest_sequence + 1 ->
        next_run = retain_record(run, record, dedup_record, state)
        {:ok, :appended, put_run(state, run_id, next_run)}

      :error when record.sequence <= run.latest_sequence ->
        {:error, history_evicted(run_id, run.latest_sequence, :dedup_history_evicted)}

      :error ->
        {:error, sequence_gap(run_id, run.latest_sequence + 1, record.sequence)}
    end
  end

  defp compare_duplicate(state, run_id, retained, record, dedup_record) do
    if retained.event_id == record.event_id and
         retained.fingerprint == dedup_record.fingerprint do
      {:ok, :duplicate, state}
    else
      {:error,
       {:event_conflict,
        %{
          reason: :sequence_reused,
          run_id: run_id,
          sequence: record.sequence,
          retained_event_id: retained.event_id,
          received_event_id: record.event_id
        }}}
    end
  end

  defp empty_run do
    %{
      latest_sequence: 0,
      events: :queue.new(),
      event_count: 0,
      event_bytes: 0,
      dedup_order: :queue.new(),
      dedup_by_sequence: %{}
    }
  end

  defp retain_record(run, record, dedup_record, state) do
    run
    |> Map.put(:latest_sequence, record.sequence)
    |> Map.update!(:events, &:queue.in(record, &1))
    |> Map.update!(:event_count, &(&1 + 1))
    |> Map.update!(:event_bytes, &(&1 + record.bytes))
    |> Map.update!(:dedup_order, &:queue.in(dedup_record, &1))
    |> Map.update!(:dedup_by_sequence, &Map.put(&1, record.sequence, dedup_record))
    |> trim_events(state)
    |> trim_dedup(state.max_dedup_entries_per_run)
  end

  defp trim_events(run, state) do
    run_byte_limit = min(state.max_bytes_per_run, state.max_total_bytes)

    if run.event_count > state.max_events_per_run or
         run.event_bytes > run_byte_limit do
      {{:value, removed}, events} = :queue.out(run.events)

      run
      |> Map.put(:events, events)
      |> Map.update!(:event_count, &(&1 - 1))
      |> Map.update!(:event_bytes, &(&1 - removed.bytes))
      |> trim_events(state)
    else
      run
    end
  end

  defp trim_dedup(run, max_entries) do
    if :queue.len(run.dedup_order) > max_entries do
      {{:value, removed}, dedup_order} = :queue.out(run.dedup_order)

      run
      |> Map.put(:dedup_order, dedup_order)
      |> Map.update!(:dedup_by_sequence, &Map.delete(&1, removed.sequence))
      |> trim_dedup(max_entries)
    else
      run
    end
  end

  defp put_run(%State{} = state, run_id, run) do
    previous_bytes =
      case Map.get(state.runs, run_id) do
        nil -> 0
        previous -> previous.event_bytes
      end

    state
    |> Map.update!(:runs, &Map.put(&1, run_id, run))
    |> Map.update!(:total_bytes, &(&1 - previous_bytes + run.event_bytes))
    |> touch_run(run_id)
    |> enforce_global_bounds()
  end

  defp touch_run(%State{} = state, run_id) do
    order = state.run_order |> :queue.to_list() |> Enum.reject(&(&1 == run_id))
    %{state | run_order: :queue.from_list(order ++ [run_id])}
  end

  defp enforce_global_bounds(%State{} = state) do
    if map_size(state.runs) > state.max_runs or state.total_bytes > state.max_total_bytes do
      {{:value, run_id}, run_order} = :queue.out(state.run_order)
      run = Map.fetch!(state.runs, run_id)

      state
      |> Map.put(:run_order, run_order)
      |> Map.update!(:runs, &Map.delete(&1, run_id))
      |> Map.update!(:total_bytes, &(&1 - run.event_bytes))
      |> retain_tombstone(run_id, run.latest_sequence)
      |> enforce_global_bounds()
    else
      state
    end
  end

  defp retain_tombstone(%State{} = state, run_id, latest_sequence) do
    without_existing =
      state.evicted_order
      |> :queue.to_list()
      |> Enum.reject(&(&1 == run_id))

    state
    |> Map.update!(:evicted_runs, &Map.put(&1, run_id, %{latest_sequence: latest_sequence}))
    |> Map.put(:evicted_order, :queue.from_list(without_existing ++ [run_id]))
    |> trim_tombstones()
  end

  defp trim_tombstones(%State{} = state) do
    if map_size(state.evicted_runs) > state.max_runs do
      {{:value, run_id}, order} = :queue.out(state.evicted_order)

      state
      |> Map.update!(:evicted_runs, &Map.delete(&1, run_id))
      |> Map.put(:evicted_order, order)
      |> trim_tombstones()
    else
      state
    end
  end

  defp replay_events(%State{} = state, run_id, after_sequence, limit)
       when limit > state.max_replay_limit do
    {:error,
     {:invalid_replay_request,
      %{
        run_id: run_id,
        requested_after: after_sequence,
        limit: limit,
        max_replay_limit: state.max_replay_limit
      }}}
  end

  defp replay_events(%State{} = state, run_id, after_sequence, limit) do
    case Map.fetch(state.runs, run_id) do
      {:ok, run} -> replay_run(run_id, run, after_sequence, limit)
      :error -> unavailable_replay(state, run_id, after_sequence)
    end
  end

  defp replay_run(run_id, run, after_sequence, limit) do
    records = :queue.to_list(run.events)
    earliest_sequence = records |> hd() |> Map.fetch!(:sequence)

    cond do
      after_sequence > run.latest_sequence ->
        {:error,
         {:replay_gap,
          %{
            reason: :cursor_ahead,
            run_id: run_id,
            requested_after: after_sequence,
            earliest_sequence: earliest_sequence,
            latest_sequence: run.latest_sequence
          }}}

      after_sequence + 1 < earliest_sequence ->
        {:error,
         {:replay_gap,
          %{
            reason: :history_evicted,
            run_id: run_id,
            requested_after: after_sequence,
            earliest_sequence: earliest_sequence,
            latest_sequence: run.latest_sequence
          }}}

      true ->
        events =
          records
          |> Enum.filter(&(&1.sequence > after_sequence))
          |> Enum.take(limit)
          |> Enum.map(& &1.event)

        {:ok,
         %{
           events: events,
           earliest_sequence: earliest_sequence,
           latest_sequence: run.latest_sequence,
           requested_after: after_sequence
         }}
    end
  end

  defp unavailable_replay(state, run_id, after_sequence) do
    case Map.fetch(state.evicted_runs, run_id) do
      {:ok, tombstone} ->
        {:error,
         {:replay_gap,
          %{
            reason: :run_evicted,
            run_id: run_id,
            requested_after: after_sequence,
            earliest_sequence: nil,
            latest_sequence: tombstone.latest_sequence
          }}}

      :error ->
        {:error,
         {:replay_unavailable,
          %{
            reason: :run_not_found,
            run_id: run_id,
            requested_after: after_sequence
          }}}
    end
  end

  defp sequence_gap(run_id, expected, received) do
    {:sequence_gap, %{run_id: run_id, expected_sequence: expected, received_sequence: received}}
  end

  defp history_evicted(run_id, latest_sequence, reason) do
    {:history_evicted, %{run_id: run_id, latest_sequence: latest_sequence, reason: reason}}
  end
end
