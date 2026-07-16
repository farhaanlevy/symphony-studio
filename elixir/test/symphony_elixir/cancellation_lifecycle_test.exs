# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CancellationLifecycleTest do
  use SymphonyElixir.TestSupport

  test "terminal turn events clear the interrupt target before later reconciliation" do
    turn_id = "turn-stale-interrupt"

    assert AgentRunner.turn_runtime_id_for_test(nil, %{
             event: :session_started,
             turn_id: turn_id
           }) == turn_id

    for event <- [:turn_completed, :turn_failed, :turn_cancelled] do
      assert AgentRunner.turn_runtime_id_for_test(turn_id, %{event: event}) == nil
    end

    assert AgentRunner.turn_runtime_id_for_test(turn_id, %{event: :item_completed}) == turn_id
  end

  test "terminal reconciliation interrupts the active turn before hooks and bound cleanup" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-lifecycle-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    lifecycle_log = Path.join(test_root, "lifecycle.log")
    request_log = Path.join(test_root, "requests.log")
    codex_pid_file = Path.join(test_root, "codex.pid")

    try do
      File.mkdir_p!(test_root)

      File.write!(
        codex_binary,
        """
        #!/bin/sh
        trap '' TERM
        awk '{print $1 " " $22}' /proc/$$/stat > '#{codex_pid_file}'
        printf '%s\\n' 'app_server_started' >> '#{lifecycle_log}'
        count=0

        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\\n' "$line" >> '#{request_log}'

          case "$count" in
            1)
              printf '%s\\n' '{"id":1,"result":{}}'
              ;;
            2)
              ;;
            3)
              printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-cancel"}}}'
              ;;
            4)
              printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-cancel"}}}'
              ;;
            5)
              printf '%s\\n' 'interrupt_received' >> '#{lifecycle_log}'
              printf '%s\\n' '{"id":4,"result":{}}'
              printf '%s\\n' '{"method":"turn/cancelled","params":{"threadId":"thread-cancel","turn":{"id":"turn-cancel"}}}'
              while :; do sleep 1; done
              ;;
          esac
        done
        """
      )

      File.chmod!(codex_binary, 0o755)

      dead_process_hook =
        "read pid original_start < '#{codex_pid_file}'; " <>
          "state=$(awk '{print $3}' /proc/$pid/stat 2>/dev/null || true); " <>
          "current_start=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null || true); " <>
          ~s|if [ -n "$state" ] && [ "$state" != Z ] && | <>
          ~s|[ "$current_start" = "$original_start" ]; | <>
          "then printf 'process_alive_%s\\n' \"$state\"; else printf '%s\\n'"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_read_timeout_ms: 1_000,
        hook_timeout_ms: 2_000,
        hook_after_run: dead_process_hook <> " after_run_dead; fi >> '#{lifecycle_log}'",
        hook_before_remove: dead_process_hook <> " before_remove_dead; fi >> '#{lifecycle_log}'"
      )

      issue = %Issue{
        id: "issue-cancel-lifecycle",
        identifier: "MT-CANCEL",
        title: "Cancel safely",
        description: "Prove active turn cancellation ordering",
        state: "In Progress",
        url: "https://example.org/issues/MT-CANCEL",
        labels: []
      }

      issue_id = issue.id

      recipient = self()

      assert {:ok, agent_pid} = AgentRunner.start_supervised(issue, recipient)

      assert_receive {:worker_runtime_info, ^issue_id, %{workspace_path: workspace_path}},
                     5_000

      assert_receive {:codex_worker_update, ^issue_id, %{event: :session_started, thread_id: "thread-cancel", turn_id: "turn-cancel"}},
                     5_000

      agent_ref = Process.monitor(agent_pid)

      state = %Orchestrator.State{
        running: %{
          issue.id => %{
            cancel_mode: :cooperative,
            pid: agent_pid,
            ref: agent_ref,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: nil,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue.id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      terminal_issue = %{issue | state: "Closed"}
      updated_state = Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)

      refute Process.alive?(agent_pid)
      refute File.exists?(workspace_path)
      refute Map.has_key?(updated_state.running, issue.id)
      refute Map.has_key?(updated_state.blocked, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
      refute MapSet.member?(updated_state.claimed, issue.id)

      assert File.read!(lifecycle_log) |> String.split("\n", trim: true) == [
               "app_server_started",
               "interrupt_received",
               "after_run_dead",
               "before_remove_dead"
             ]

      requests =
        request_log
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      assert Enum.any?(requests, fn request -> request["method"] == "turn/interrupt" end)

      thread_start = Enum.find(requests, &(&1["method"] == "thread/start"))
      turn_start = Enum.find(requests, &(&1["method"] == "turn/start"))

      dynamic_tool_description =
        get_in(thread_start, ["params", "dynamicTools", Access.at(0), "description"])

      assert dynamic_tool_description =~ "raw GraphQL query or mutation"
      refute dynamic_tool_description =~ "current Linear issue"

      assert get_in(turn_start, ["params", "sandboxPolicy"])
             |> Map.take(["type", "writableRoots", "networkAccess"]) == %{
               "type" => "workspaceWrite",
               "writableRoots" => [workspace_path],
               "networkAccess" => false
             }
    after
      File.rm_rf(test_root)
    end
  end

  test "duplicate terminal cleanup failure retains its controller and preserves the safety block" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-failure-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "MT-CANCEL-FAIL")
    issue_id = "issue-cancel-failure"

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "sentinel"), "preserve")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

      assert {:ok, controller} =
               Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                 receive do
                   {:cancel_agent_attempt, caller, token} ->
                     send(
                       caller,
                       {:agent_attempt_cancelled, token, {:error, :app_server_process_cleanup_failed}}
                     )

                     Process.sleep(:infinity)
                 end
               end)

      on_exit(fn ->
        if Process.alive?(controller), do: Process.exit(controller, :kill)
      end)

      controller_ref = Process.monitor(controller)

      issue = %Issue{
        id: issue_id,
        identifier: "MT-CANCEL-FAIL",
        title: "Preserve on cleanup failure",
        state: "In Progress"
      }

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            cancel_mode: :cooperative,
            pid: controller,
            ref: controller_ref,
            identifier: issue.identifier,
            issue: issue,
            workspace_path: workspace,
            workspace_root: test_root,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      terminal_issue = %{issue | state: "Closed"}

      blocked_state =
        Orchestrator.reconcile_issue_states_for_test(
          [terminal_issue, terminal_issue],
          state
        )

      assert Process.alive?(controller)
      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(blocked_state.running, issue_id)
      assert Map.has_key?(blocked_state.blocked, issue_id)
      assert MapSet.member?(blocked_state.claimed, issue_id)
      refute Map.has_key?(blocked_state.retry_attempts, issue_id)

      repeated_state =
        Orchestrator.reconcile_blocked_issue_states_for_test([terminal_issue], blocked_state)

      assert Map.has_key?(repeated_state.blocked, issue_id)
      assert repeated_state.blocked[issue_id].blocked_at == blocked_state.blocked[issue_id].blocked_at
      assert MapSet.member?(repeated_state.claimed, issue_id)
      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(repeated_state.retry_attempts, issue_id)

      assert :ok =
               Task.Supervisor.terminate_child(
                 SymphonyElixir.TaskSupervisor,
                 controller
               )

      refute Process.alive?(controller)
    after
      File.rm_rf(test_root)
    end
  end

  test "retained cleanup authority cannot block terminal reconciliation globally" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-retained-cleanup-authority-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "MT-RETAINED-CLEANUP")
    issue_id = "issue-retained-cleanup-authority"
    parent = self()

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "sentinel"), "preserve")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: test_root)

      assert {:ok, controller} =
               Task.Supervisor.start_child(
                 SymphonyElixir.TaskSupervisor,
                 fn ->
                   Process.flag(:trap_exit, true)
                   send(parent, {:retained_controller_ready, self()})

                   receive do
                     {:cancel_agent_attempt, caller, token} ->
                       send(
                         caller,
                         {:agent_attempt_cancelled, token, {:error, :app_server_process_cleanup_failed}}
                       )

                       receive do
                         :release_retained_controller -> :ok
                       end
                   end
                 end,
                 shutdown: :infinity
               )

      on_exit(fn ->
        if Process.alive?(controller), do: Process.exit(controller, :kill)
      end)

      controller_ref = Process.monitor(controller)
      assert_receive {:retained_controller_ready, ^controller}, 1_000

      issue = %Issue{
        id: issue_id,
        identifier: "MT-RETAINED-CLEANUP",
        title: "Retain cleanup authority",
        state: "In Progress"
      }

      terminal_issue = %{issue | state: "Closed"}

      reconciliation =
        Task.async(fn ->
          state = %Orchestrator.State{
            running: %{
              issue_id => %{
                cancel_mode: :cooperative,
                pid: controller,
                ref: Process.monitor(controller),
                identifier: issue.identifier,
                issue: issue,
                workspace_path: workspace,
                workspace_root: test_root,
                started_at: DateTime.utc_now()
              }
            },
            claimed: MapSet.new([issue_id]),
            codex_totals: %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: 0
            },
            retry_attempts: %{}
          }

          Orchestrator.reconcile_issue_states_for_test([terminal_issue], state)
        end)

      blocked_state = Task.await(reconciliation, 1_000)

      assert Process.alive?(controller)
      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(blocked_state.running, issue_id)
      assert blocked_state.blocked[issue_id].preserve_on_terminal?
      assert MapSet.member?(blocked_state.claimed, issue_id)
      refute Map.has_key?(blocked_state.retry_attempts, issue_id)

      send(controller, :release_retained_controller)
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 1_000
    after
      File.rm_rf(test_root)
    end
  end

  test "timed-out cancellation retains capacity until the unconfirmed controller exits" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-cancel-timeout-capacity-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(test_root, "MT-CANCEL-TIMEOUT")
    issue_id = "issue-cancel-timeout-capacity"
    parent = self()

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "sentinel"), "preserve")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{"In Progress" => 1}
      )

      assert {:ok, controller} =
               Task.Supervisor.start_child(
                 SymphonyElixir.TaskSupervisor,
                 fn ->
                   Process.flag(:trap_exit, true)

                   loop = fn loop ->
                     receive do
                       {:cancel_agent_attempt, _caller, _token} ->
                         send(parent, {:timed_out_cancel_received, self()})
                         loop.(loop)

                       :release_timed_out_controller ->
                         :ok
                     end
                   end

                   loop.(loop)
                 end,
                 shutdown: :infinity
               )

      on_exit(fn ->
        if Process.alive?(controller), do: Process.exit(controller, :kill)
      end)

      controller_ref = Process.monitor(controller)

      issue = %Issue{
        id: issue_id,
        identifier: "MT-CANCEL-TIMEOUT",
        title: "Retain timed-out capacity",
        state: "In Progress"
      }

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            cancel_mode: :cooperative,
            cancel_timeout_ms: 25,
            pid: controller,
            ref: Process.monitor(controller),
            identifier: issue.identifier,
            issue: issue,
            worker_host: "worker-a",
            workspace_path: workspace,
            workspace_root: test_root,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        max_concurrent_agents: 2,
        codex_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: 0
        },
        retry_attempts: %{}
      }

      blocked_state =
        Orchestrator.reconcile_issue_states_for_test(
          [%{issue | state: "Closed"}],
          state
        )

      assert_receive {:timed_out_cancel_received, ^controller}, 1_000
      assert Process.alive?(controller)
      assert blocked_state.blocked[issue_id].retained_controller_pid == controller
      assert blocked_state.blocked[issue_id].retained_controller_issue_state == "In Progress"
      assert blocked_state.blocked[issue_id].preserve_on_terminal?
      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(blocked_state.running, issue_id)
      refute Map.has_key?(blocked_state.retry_attempts, issue_id)

      next_issue = %Issue{
        id: "issue-after-cancel-timeout",
        identifier: "MT-AFTER-TIMEOUT",
        title: "Wait for retained capacity",
        state: "In Progress"
      }

      refreshed_state =
        Orchestrator.reconcile_blocked_issue_states_for_test(
          [%{issue | state: "Closed"}],
          blocked_state
        )

      assert refreshed_state.blocked[issue_id].issue.state == "Closed"

      assert refreshed_state.blocked[issue_id].retained_controller_issue_state ==
               "In Progress"

      refute Orchestrator.should_dispatch_issue_for_test(next_issue, refreshed_state)

      other_state_issue = %{next_issue | id: "issue-other-state", state: "Todo"}
      assert Orchestrator.should_dispatch_issue_for_test(other_state_issue, refreshed_state)

      global_saturated_state = %{refreshed_state | max_concurrent_agents: 1}
      refute Orchestrator.should_dispatch_issue_for_test(other_state_issue, global_saturated_state)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: test_root,
        worker_ssh_hosts: ["worker-a"],
        worker_max_concurrent_agents_per_host: 1,
        max_concurrent_agents: 2,
        max_concurrent_agents_by_state: %{"In Progress" => 2}
      )

      refute Orchestrator.should_dispatch_issue_for_test(other_state_issue, refreshed_state)

      send(controller, :release_timed_out_controller)
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :normal}, 1_000
      assert Orchestrator.should_dispatch_issue_for_test(next_issue, refreshed_state)
      assert Orchestrator.should_dispatch_issue_for_test(other_state_issue, refreshed_state)
    after
      File.rm_rf(test_root)
    end
  end

  test "terminal cleanup removes only the workspace bound before a root reload" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-bound-reload-#{System.unique_integer([:positive])}"
      )

    original_root = Path.join(test_root, "root-a")
    reloaded_root = Path.join(test_root, "root-b")
    identifier = "MT-BOUND"
    bound_workspace = Path.join(original_root, identifier)
    reloaded_workspace = Path.join(reloaded_root, identifier)
    reloaded_sentinel = Path.join(reloaded_workspace, "sentinel")
    issue_id = "issue-bound-reload"

    try do
      File.mkdir_p!(bound_workspace)
      File.mkdir_p!(reloaded_workspace)
      File.write!(Path.join(bound_workspace, "original"), "remove")
      File.write!(reloaded_sentinel, "preserve")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: reloaded_root)

      assert {:ok, worker} =
               Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                 Process.sleep(:infinity)
               end)

      issue = %Issue{
        id: issue_id,
        identifier: identifier,
        title: "Keep cleanup bound to root A",
        state: "In Progress"
      }

      state = %Orchestrator.State{
        running: %{
          issue_id => %{
            pid: worker,
            ref: Process.monitor(worker),
            identifier: identifier,
            issue: issue,
            workspace_path: bound_workspace,
            workspace_root: original_root,
            started_at: DateTime.utc_now()
          }
        },
        claimed: MapSet.new([issue_id]),
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        retry_attempts: %{}
      }

      updated_state =
        Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

      refute Process.alive?(worker)
      refute File.exists?(bound_workspace)
      assert File.read!(reloaded_sentinel) == "preserve"
      refute Map.has_key?(updated_state.running, issue_id)
      refute Map.has_key?(updated_state.blocked, issue_id)
      refute MapSet.member?(updated_state.claimed, issue_id)
    after
      File.rm_rf(test_root)
    end
  end
end
