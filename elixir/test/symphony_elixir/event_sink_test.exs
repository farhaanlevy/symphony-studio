# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio proves bounded
# event delivery, replay, gap, and idempotency contracts without persistence.

defmodule SymphonyElixir.EventSinkTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Event
  alias SymphonyElixir.EventSink
  alias SymphonyElixir.EventSink.Memory
  alias SymphonyElixir.EventSink.Noop
  alias SymphonyElixir.Identity

  defmodule RaisingSink do
    @behaviour SymphonyElixir.EventSink

    @impl true
    def append(_server, _event), do: raise("adapter failure with private payload")

    @impl true
    def replay(_server, _run_id, _after_sequence, _limit),
      do: raise("adapter failure with private replay input")
  end

  test "the default no-op sink preserves a runner with no event history" do
    previous = Application.fetch_env(:symphony_elixir, :event_sink)

    on_exit(fn -> restore_event_sink(previous) end)
    Application.delete_env(:symphony_elixir, :event_sink)

    run_id = Identity.uuid4()
    event = event(run_id, 1)

    assert Noop == EventSink.default_target()
    assert {:ok, :appended} = EventSink.append(event)

    assert {:error, {:replay_unavailable, %{reason: :not_retained, run_id: ^run_id, requested_after: 0}}} =
             EventSink.replay(run_id, 0, 10)

    target = start_memory_sink()
    Application.put_env(:symphony_elixir, :event_sink, target)

    assert ^target = EventSink.default_target()
    assert {:ok, :appended} = EventSink.append(event)
    assert {:ok, %{events: [^event]}} = EventSink.replay(run_id, 0, 10)
  end

  test "the facade rejects malformed events, requests, and sink targets" do
    event = event(Identity.uuid4(), 1)
    forged = %{event | event_id: Identity.uuid4()}

    assert {:error, {:invalid_event, {:event, :expected_event_struct}}} =
             EventSink.append(Noop, :not_an_event)

    assert {:error, {:invalid_event, {:event_id, :does_not_match_identity}}} =
             EventSink.append(Noop, forged)

    assert {:error, {:invalid_sink, "not-an-adapter"}} =
             EventSink.append("not-an-adapter", event)

    assert {:error, {:event_sink_unavailable, String}} = EventSink.append(String, event)

    assert {:error, {:invalid_replay_request, %{field: :after_sequence, reason: :must_be_non_negative_integer}}} =
             EventSink.replay(Noop, event.run_id, -1, 1)

    assert {:error, {:invalid_replay_request, %{field: :limit, reason: :must_be_positive_integer}}} =
             EventSink.replay(Noop, event.run_id, 0, 0)

    for invalid_run_id <- [
          :not_a_uuid,
          "",
          "not-a-uuid",
          String.upcase(event.run_id),
          <<255>>,
          String.duplicate("a", 1_000_000)
        ] do
      assert {:error, {:invalid_replay_request, %{field: :run_id, reason: :must_be_canonical_uuid4}}} =
               EventSink.replay(Noop, invalid_run_id, 0, 1)
    end

    assert {:error, {:invalid_sink, "not-an-adapter"}} =
             EventSink.replay("not-an-adapter", event.run_id, 0, 1)

    assert {:error, {:event_sink_unavailable, String}} =
             EventSink.replay(String, event.run_id, 0, 1)

    assert {:error, {:event_sink_unavailable, RaisingSink}} =
             EventSink.append(RaisingSink, event)

    assert {:error, {:event_sink_unavailable, RaisingSink}} =
             EventSink.replay(RaisingSink, event.run_id, 0, 1)

    {:ok, stopped_sink} = Memory.start_link()
    :ok = GenServer.stop(stopped_sink)

    assert {:error, {:event_sink_unavailable, Memory}} =
             EventSink.append({Memory, stopped_sink}, event)

    assert {:error, {:event_sink_unavailable, Memory}} =
             EventSink.replay({Memory, stopped_sink}, event.run_id, 0, 1)
  end

  test "memory replay is ordered, cursor-based, limited, and isolated per run" do
    target = start_memory_sink(max_replay_limit: 2)
    first_run_id = Identity.uuid4()
    second_run_id = Identity.uuid4()
    first = event(first_run_id, 1)
    second = event(first_run_id, 2)
    other_run = event(second_run_id, 1)

    assert {:ok, :appended} = EventSink.append(target, first)
    assert {:ok, :duplicate} = EventSink.append(target, first)
    assert {:ok, :appended} = EventSink.append(target, second)
    assert {:ok, :appended} = EventSink.append(target, other_run)

    assert {:ok,
            %{
              events: [^first],
              earliest_sequence: 1,
              latest_sequence: 2,
              requested_after: 0
            }} = EventSink.replay(target, first_run_id, 0, 1)

    assert {:ok, %{events: [^second], earliest_sequence: 1, latest_sequence: 2}} =
             EventSink.replay(target, first_run_id, 1, 2)

    assert {:ok, %{events: [], earliest_sequence: 1, latest_sequence: 2}} =
             EventSink.replay(target, first_run_id, 2, 2)

    assert {:error,
            {:replay_gap,
             %{
               reason: :cursor_ahead,
               run_id: ^first_run_id,
               requested_after: 3,
               earliest_sequence: 1,
               latest_sequence: 2
             }}} = EventSink.replay(target, first_run_id, 3, 2)

    assert {:ok, %{events: [^other_run], earliest_sequence: 1, latest_sequence: 1}} =
             EventSink.replay(target, second_run_id, 0, 2)

    assert {:error,
            {:invalid_replay_request,
             %{
               run_id: ^first_run_id,
               requested_after: 0,
               limit: 3,
               max_replay_limit: 2
             }}} = EventSink.replay(target, first_run_id, 0, 3)
  end

  test "producer-assigned sequences reject gaps and conflicting redeliveries" do
    target = start_memory_sink()
    run_id = Identity.uuid4()
    first = event(run_id, 1)

    assert {:error, {:sequence_gap, %{run_id: ^run_id, expected_sequence: 1, received_sequence: 2}}} =
             EventSink.append(target, event(run_id, 2))

    assert {:ok, :appended} = EventSink.append(target, first)

    assert {:error, {:sequence_gap, %{run_id: ^run_id, expected_sequence: 2, received_sequence: 3}}} =
             EventSink.append(target, event(run_id, 3))

    conflicting = event(run_id, 1, payload: %{"changed" => true})

    assert {:error,
            {:event_conflict,
             %{
               reason: :sequence_reused,
               run_id: ^run_id,
               sequence: 1,
               retained_event_id: retained_id,
               received_event_id: received_id
             }}} = EventSink.append(target, conflicting)

    assert retained_id == received_id

    forged_id = %{event(run_id, 2) | event_id: first.event_id}

    assert {:error, {:invalid_event, {:event_id, :does_not_match_identity}}} =
             EventSink.append(target, forged_id)

    assert {:ok, %{events: [^first], latest_sequence: 1}} =
             EventSink.replay(target, run_id, 0, 10)
  end

  test "event and dedup retention are bounded with explicit replay gaps" do
    target =
      start_memory_sink(
        max_events_per_run: 2,
        max_dedup_entries_per_run: 3,
        max_replay_limit: 10
      )

    run_id = Identity.uuid4()
    first = event(run_id, 1)
    second = event(run_id, 2)
    third = event(run_id, 3)
    fourth = event(run_id, 4)

    for item <- [first, second, third] do
      assert {:ok, :appended} = EventSink.append(target, item)
    end

    assert {:error,
            {:replay_gap,
             %{
               reason: :history_evicted,
               run_id: ^run_id,
               requested_after: 0,
               earliest_sequence: 2,
               latest_sequence: 3
             }}} = EventSink.replay(target, run_id, 0, 10)

    assert {:ok, %{events: [^second, ^third], earliest_sequence: 2, latest_sequence: 3}} =
             EventSink.replay(target, run_id, 1, 10)

    assert {:ok, :duplicate} = EventSink.append(target, first)
    assert {:ok, :appended} = EventSink.append(target, fourth)

    assert {:error,
            {:history_evicted,
             %{
               run_id: ^run_id,
               latest_sequence: 4,
               reason: :dedup_history_evicted
             }}} = EventSink.append(target, first)
  end

  test "per-run and global byte limits evict deterministically and reject oversized events" do
    run_id = Identity.uuid4()
    first = event(run_id, 1, payload: %{"content" => String.duplicate("a", 256)})
    second = event(run_id, 2, payload: %{"content" => String.duplicate("b", 256)})
    largest = max(encoded_bytes(first), encoded_bytes(second))

    per_run_target =
      start_memory_sink(
        max_events_per_run: 4,
        max_dedup_entries_per_run: 4,
        max_bytes_per_run: largest,
        max_total_bytes: largest * 2,
        max_replay_limit: 10
      )

    assert {:ok, :appended} = EventSink.append(per_run_target, first)
    assert {:ok, :appended} = EventSink.append(per_run_target, second)

    assert {:error, {:replay_gap, %{reason: :history_evicted, earliest_sequence: 2, latest_sequence: 2}}} =
             EventSink.replay(per_run_target, run_id, 0, 10)

    oversized_target = start_memory_sink(max_bytes_per_run: encoded_bytes(first) - 1)

    assert {:error, {:event_too_large, %{bytes: bytes, max_bytes_per_run: max_bytes, max_total_bytes: total_bytes}}} =
             EventSink.append(oversized_target, first)

    assert bytes == encoded_bytes(first)
    assert max_bytes == bytes - 1
    assert total_bytes > bytes

    first_run_id = Identity.uuid4()
    second_run_id = Identity.uuid4()
    first_run_event = event(first_run_id, 1)
    second_run_event = event(second_run_id, 1)
    total_limit = max(encoded_bytes(first_run_event), encoded_bytes(second_run_event))

    global_target =
      start_memory_sink(
        max_runs: 2,
        max_events_per_run: 1,
        max_dedup_entries_per_run: 1,
        max_bytes_per_run: total_limit,
        max_total_bytes: total_limit
      )

    assert {:ok, :appended} = EventSink.append(global_target, first_run_event)
    assert {:ok, :appended} = EventSink.append(global_target, second_run_event)

    assert {:error, {:replay_gap, %{reason: :run_evicted, run_id: ^first_run_id, latest_sequence: 1}}} =
             EventSink.replay(global_target, first_run_id, 0, 1)

    assert {:ok, %{events: [^second_run_event]}} =
             EventSink.replay(global_target, second_run_id, 0, 1)
  end

  test "run and tombstone retention are bounded without mixing run domains" do
    target =
      start_memory_sink(
        max_runs: 1,
        max_events_per_run: 1,
        max_dedup_entries_per_run: 1
      )

    first_run_id = Identity.uuid4()
    second_run_id = Identity.uuid4()
    third_run_id = Identity.uuid4()
    first = event(first_run_id, 1)

    assert {:ok, :appended} = EventSink.append(target, first)
    assert {:ok, :appended} = EventSink.append(target, event(second_run_id, 1))

    assert {:error, {:replay_gap, %{reason: :run_evicted, run_id: ^first_run_id}}} =
             EventSink.replay(target, first_run_id, 0, 1)

    assert {:error, {:history_evicted, %{run_id: ^first_run_id, latest_sequence: 1}}} =
             EventSink.append(target, first)

    assert {:ok, :appended} = EventSink.append(target, event(third_run_id, 1))

    assert {:error, {:replay_unavailable, %{reason: :run_not_found, run_id: ^first_run_id, requested_after: 0}}} =
             EventSink.replay(target, first_run_id, 0, 1)

    assert {:error, {:replay_gap, %{reason: :run_evicted, run_id: ^second_run_id}}} =
             EventSink.replay(target, second_run_id, 0, 1)
  end

  test "memory startup rejects ambiguous or unbounded retention options" do
    Process.flag(:trap_exit, true)

    assert {:error, {:invalid_option, :unexpected}} = Memory.start_link(unexpected: true)
    assert {:error, {:invalid_option, :duplicate_option}} = Memory.start_link(max_runs: 1, max_runs: 2)
    assert {:error, {:invalid_option, :max_runs}} = Memory.start_link(max_runs: 0)

    assert {:error, {:invalid_option, :max_dedup_entries_per_run}} =
             Memory.start_link(max_events_per_run: 2, max_dedup_entries_per_run: 1)

    assert {:error, {:invalid_option, :expected_keyword_list}} = Memory.start_link([:not_keyword])
    assert {:error, {:invalid_option, :expected_keyword_list}} = Memory.start_link(:not_a_list)

    assert {:ok, default_pid} = Memory.start_link()
    GenServer.stop(default_pid)

    name = :"event-sink-#{System.unique_integer([:positive])}"
    assert {:ok, pid} = Memory.start_link(name: name)
    assert Process.whereis(name) == pid
    GenServer.stop(pid)
  end

  defp start_memory_sink(opts \\ []) do
    child_spec = Supervisor.child_spec({Memory, opts}, id: make_ref())
    pid = start_supervised!(child_spec)
    {Memory, pid}
  end

  defp event(run_id, sequence, overrides \\ []) do
    defaults = %{
      sequence: sequence,
      occurred_at: ~U[2026-07-16 10:00:00.000Z],
      issue_id: "issue-#{run_id}",
      issue_identifier: "SYM-#{sequence}",
      run_id: run_id,
      attempt_id: Identity.uuid4(),
      thread_id: nil,
      turn_id: nil,
      type: "runtime.event.observed",
      severity: "info",
      payload: %{"sequence" => sequence}
    }

    defaults
    |> Map.merge(Map.new(overrides))
    |> Event.new!()
  end

  defp encoded_bytes(event), do: event |> Event.to_map() |> Jason.encode!() |> byte_size()

  defp restore_event_sink({:ok, target}), do: Application.put_env(:symphony_elixir, :event_sink, target)
  defp restore_event_sink(:error), do: Application.delete_env(:symphony_elixir, :event_sink)
end
