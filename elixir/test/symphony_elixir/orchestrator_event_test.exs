# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio verifies the
# Orchestrator event boundary, stale-attempt isolation, and payload redaction.

defmodule SymphonyElixir.OrchestratorEventTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Event, EventSink, EventSink.Memory, Orchestrator}
  alias SymphonyElixir.Linear.Issue

  @run_id "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @attempt_id "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @stale_attempt_id "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  test "orchestrator init honors the application-configured sink boundary" do
    {:ok, sink} = start_supervised({Memory, max_events_per_run: 8})
    previous_sink = Application.get_env(:symphony_elixir, :event_sink)
    target = {Memory, sink}

    Application.put_env(:symphony_elixir, :event_sink, target)

    on_exit(fn ->
      if is_nil(previous_sink) do
        Application.delete_env(:symphony_elixir, :event_sink)
      else
        Application.put_env(:symphony_elixir, :event_sink, previous_sink)
      end
    end)

    name = Module.concat(__MODULE__, :ConfiguredSinkOrchestrator)
    pid = start_supervised!({Orchestrator, name: name})

    assert :sys.get_state(pid).event_sink == target
  end

  test "appends normalized events before projection and isolates stale attempts" do
    {:ok, sink} = start_supervised({Memory, max_events_per_run: 8})
    issue_id = "issue-event-stream"
    canary = "PRIVATE-PROVIDER-PAYLOAD-CANARY"
    state = event_state(sink, issue_id)

    first = %{
      event: :notification,
      timestamp: ~U[2026-07-16 10:00:00Z],
      run_id: @run_id,
      attempt_id: @attempt_id,
      method_category: :turn,
      payload: %{"raw" => canary}
    }

    assert {:noreply, state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, first}, state)

    assert state.running[issue_id].last_codex_event == :notification
    assert state.running[issue_id].event_sequence == 1

    assert {:ok, %{events: [first_event], latest_sequence: 1}} =
             EventSink.replay({Memory, sink}, @run_id, 0, 8)

    assert %Event{
             sequence: 1,
             run_id: @run_id,
             attempt_id: @attempt_id,
             issue_id: ^issue_id,
             issue_identifier: "SYM-EVENT",
             type: "codex.notification",
             payload: %{"method_category" => "turn"},
             redacted: true
           } = first_event

    refute inspect(Event.to_map(first_event)) =~ canary

    event_canary = "PRIVATE-SECRET-EVENT-CANARY"

    rejection_log =
      ExUnit.CaptureLog.capture_log(fn ->
        for malformed <- [
              first
              |> Map.merge(%{
                run_id: "not-a-run-id",
                event: event_canary,
                operation: :not_a_map
              }),
              %{first | attempt_id: "not-an-attempt-id"},
              %{first | run_id: nil},
              %{first | attempt_id: nil}
            ] do
          assert {:noreply, unchanged} =
                   Orchestrator.handle_info({:codex_worker_update, issue_id, malformed}, state)

          assert unchanged.running[issue_id].event_sequence == 1
          assert unchanged.running[issue_id].run_id == @run_id
          assert unchanged.running[issue_id].attempt_id == @attempt_id
        end
      end)

    assert rejection_log =~
             "Rejected structured codex event issue_id=#{issue_id} issue_identifier=SYM-EVENT"

    assert rejection_log =~ "run_id=#{@run_id} attempt_id=#{@attempt_id}"
    assert rejection_log =~ "operation_id=n/a event_type=unvalidated"
    refute rejection_log =~ canary
    refute rejection_log =~ event_canary

    missing_context_canary = "PRIVATE-MISSING-CONTEXT-CANARY"

    {{:noreply, unchanged}, missing_context_log} =
      ExUnit.CaptureLog.with_log(fn ->
        Orchestrator.handle_info(
          {:codex_worker_update, missing_context_canary,
           %{
             first
             | run_id: missing_context_canary,
               attempt_id: missing_context_canary,
               event: missing_context_canary
           }},
          state
        )
      end)

    assert unchanged == state
    assert missing_context_log =~ "issue_id=n/a issue_identifier=n/a"
    assert missing_context_log =~ "run_id=n/a attempt_id=n/a operation_id=n/a event_type=unvalidated"
    refute missing_context_log =~ missing_context_canary

    assert {:ok, %{events: [^first_event], latest_sequence: 1}} =
             EventSink.replay({Memory, sink}, @run_id, 0, 8)

    forged_timestamp = %{first.timestamp | year: nil}

    for malformed <- [
          %{first | event: <<255>>},
          %{first | event: {:invalid, :event}},
          %{first | timestamp: forged_timestamp}
        ] do
      assert {:noreply, unchanged} =
               Orchestrator.handle_info({:codex_worker_update, issue_id, malformed}, state)

      assert unchanged.running[issue_id].event_sequence == 1
      assert unchanged.running[issue_id].last_codex_event == :notification
    end

    assert {:ok, %{events: [^first_event], latest_sequence: 1}} =
             EventSink.replay({Memory, sink}, @run_id, 0, 8)

    stale = %{
      event: :turn_completed,
      timestamp: ~U[2026-07-16 10:00:01Z],
      run_id: @run_id,
      attempt_id: @stale_attempt_id,
      terminal: :turn_completed
    }

    assert {:noreply, state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, stale}, state)

    assert state.running[issue_id].event_sequence == 2
    assert state.running[issue_id].attempt_id == @attempt_id
    assert state.running[issue_id].last_codex_event == :notification

    assert {:ok, %{events: [^first_event, stale_event], latest_sequence: 2}} =
             EventSink.replay({Memory, sink}, @run_id, 0, 8)

    assert stale_event.sequence == 2
    assert stale_event.attempt_id == @stale_attempt_id
    assert stale_event.type == "codex.turn.completed"

    conflicting = %{stale | run_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"}

    assert {:noreply, unchanged} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, conflicting}, state)

    assert unchanged.running[issue_id].event_sequence == 2

    assert {:ok, %{events: [^first_event, ^stale_event], latest_sequence: 2}} =
             EventSink.replay({Memory, sink}, @run_id, 0, 8)
  end

  test "runtime metadata requires exact canonical correlation for identified attempts" do
    {:ok, sink} = start_supervised({Memory, max_events_per_run: 8})
    issue_id = "issue-runtime-correlation"
    state = event_state(sink, issue_id)

    valid = %{
      run_id: @run_id,
      attempt_id: @attempt_id,
      worker_host: nil,
      workspace_path: "/tmp/valid-runtime"
    }

    assert {:noreply, correlated} =
             Orchestrator.handle_info({:worker_runtime_info, issue_id, valid}, state)

    assert correlated.running[issue_id].workspace_path == "/tmp/valid-runtime"

    rejected = [
      Map.delete(valid, :run_id),
      %{valid | run_id: "not-a-run-id"},
      %{valid | attempt_id: "not-an-attempt-id"},
      %{valid | run_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"},
      %{valid | attempt_id: @stale_attempt_id}
    ]

    for runtime_info <- rejected do
      assert {:noreply, unchanged} =
               Orchestrator.handle_info(
                 {:worker_runtime_info, issue_id, runtime_info},
                 correlated
               )

      assert unchanged.running[issue_id].workspace_path == "/tmp/valid-runtime"
    end
  end

  test "process-local sink history loss cannot block safety projection" do
    sink_name = Module.concat(__MODULE__, :RestartedMemorySink)
    {:ok, sink_pid} = Memory.start_link(name: sink_name, max_events_per_run: 8)

    on_exit(fn ->
      case Process.whereis(sink_name) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end
    end)

    issue_id = "issue-sink-restart"
    state = event_state(sink_name, issue_id)

    first = %{
      event: :notification,
      timestamp: ~U[2026-07-16 10:00:00Z],
      run_id: @run_id,
      attempt_id: @attempt_id,
      method_category: :turn
    }

    assert {:noreply, state} =
             Orchestrator.handle_info({:codex_worker_update, issue_id, first}, state)

    assert state.running[issue_id].event_sequence == 1
    assert state.running[issue_id].last_codex_event == :notification

    :ok = GenServer.stop(sink_pid)
    {:ok, _restarted_sink} = Memory.start_link(name: sink_name, max_events_per_run: 8)

    blocker = %{
      first
      | event: :turn_input_required,
        timestamp: ~U[2026-07-16 10:00:01Z],
        method_category: :turn
    }

    {{:noreply, continued}, sink_log} =
      ExUnit.CaptureLog.with_log(fn ->
        Orchestrator.handle_info({:codex_worker_update, issue_id, blocker}, state)
      end)

    assert sink_log =~
             "Structured event sink unavailable issue_id=#{issue_id} issue_identifier=SYM-EVENT"

    assert sink_log =~ "run_id=#{@run_id} attempt_id=#{@attempt_id}"
    assert sink_log =~ "operation_id=n/a event_type=codex.turn.input.required"
    assert sink_log =~ "failure_kind=sequence_gap"
    refute sink_log =~ "run_not_found"

    assert continued.running[issue_id].event_sequence == 2
    assert continued.running[issue_id].last_codex_event == :turn_input_required

    assert {:error, {:replay_unavailable, %{reason: :run_not_found, run_id: @run_id, requested_after: 0}}} =
             EventSink.replay({Memory, sink_name}, @run_id, 0, 8)
  end

  defp event_state(sink, issue_id) do
    issue = %Issue{
      id: issue_id,
      identifier: "SYM-EVENT",
      title: "Verify event stream",
      state: "In Progress",
      url: "https://example.org/issues/SYM-EVENT"
    }

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: nil,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      codex_last_reported_input_tokens: 0,
      codex_last_reported_output_tokens: 0,
      codex_last_reported_total_tokens: 0,
      turn_count: 0,
      retry_attempt: 0,
      run_id: @run_id,
      attempt_id: @attempt_id,
      event_sequence: 0,
      last_event_id: nil,
      last_event_type: nil,
      started_at: ~U[2026-07-16 10:00:00Z]
    }

    %Orchestrator.State{
      running: %{issue_id => running_entry},
      claimed: MapSet.new([issue_id]),
      event_sink: {Memory, sink},
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0}
    }
  end
end
