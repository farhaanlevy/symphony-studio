# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CancellationSafetyRegressionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{CleanupGuardian, TransportError}
  alias SymphonyElixir.EventSink.Memory

  @hook_failure_run_id "11111111-1111-4111-8111-111111111111"
  @hook_failure_attempt_id "22222222-2222-4222-8222-222222222222"
  @runtime_children [
    SymphonyElixir.CleanupBarrier,
    SymphonyElixir.CleanupSupervisor,
    SymphonyElixir.ConnectionSupervisor,
    SymphonyElixir.WorkspaceHookSupervisor,
    SymphonyElixir.TaskSupervisor,
    SymphonyElixir.Orchestrator
  ]

  defmodule RetainedStartupRollbackAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      test_pid =
        Application.fetch_env!(
          :symphony_elixir,
          :retained_startup_rollback_test_pid
        )

      status = :atomics.new(1, [])
      :ok = :atomics.put(status, 1, 0)

      authority =
        spawn(fn ->
          send(test_pid, {:startup_cleanup_authority_ready, self()})
          cleanup_authority_loop(status)
        end)

      cleanup_handle = %CleanupGuardian.Handle{pid: authority, status: status}

      if Application.get_env(
           :symphony_elixir,
           :retained_startup_rollback_test_mode,
           :immediate
         ) == :held do
        send(test_pid, {:startup_adapter_waiting, self()})

        receive do
          :return_start_failure -> :ok
        end
      end

      {:error,
       {:process_identity_unavailable, :injected_identity_failure,
        {:startup_rollback_unverified,
         %{
           group_empty: false,
           manager_alive: true,
           namespace_root: :not_captured,
           stop_request: :stop_timeout
         }, cleanup_handle}}}
    end

    defp cleanup_authority_loop(status) do
      receive do
        :release_cleanup -> :atomics.put(status, 1, 1)
        _message -> cleanup_authority_loop(status)
      end
    end
  end

  defmodule ImmediateCleanupAdapter do
    @moduledoc false
    def stop(_adapter, _timeout_ms), do: :ok
  end

  defmodule ControlledCleanupAdapter do
    @moduledoc false

    def stop(%{allow_stop: allow_stop, test_pid: test_pid}, _timeout_ms) do
      allowed? = Agent.get(allow_stop, & &1)
      send(test_pid, {:controlled_cleanup_attempt, self(), allowed?})

      if allowed?, do: :ok, else: {:error, :cleanup_held}
    end
  end

  defmodule VerifiedBeforeRegistrationAdapter do
    @moduledoc false

    alias SymphonyElixir.Codex.CleanupGuardian

    def start(_argv, _opts) do
      handle =
        CleanupGuardian.start_handle(
          self(),
          SymphonyElixir.CancellationSafetyRegressionTest.ImmediateCleanupAdapter,
          :fixture,
          0
        )

      monitor_ref = Process.monitor(handle.pid)
      :ok = CleanupGuardian.request_cleanup(handle)

      receive do
        {:DOWN, ^monitor_ref, :process, _guardian, :normal} -> :ok
      end

      rollback = {:startup_rollback_unverified, %{manager_alive: false}, handle}
      {:error, {:process_identity_unavailable, :injected_identity_failure, rollback}}
    end
  end

  defmodule LostBeforeRegistrationAdapter do
    @moduledoc false

    alias SymphonyElixir.Codex.CleanupGuardian

    def start(_argv, _opts) do
      status = :atomics.new(1, [])
      :ok = :atomics.put(status, 1, 0)
      guardian = spawn(fn -> :ok end)
      monitor_ref = Process.monitor(guardian)

      receive do
        {:DOWN, ^monitor_ref, :process, ^guardian, :normal} -> :ok
      end

      handle = %CleanupGuardian.Handle{pid: guardian, status: status}

      rollback = {:startup_rollback_unverified, %{manager_alive: true}, handle}
      {:error, {:process_identity_unavailable, :injected_identity_failure, rollback}}
    end
  end

  test "an absent runtime uses one acknowledged fallback guardian" do
    runtime =
      unregister_runtime_names!([
        SymphonyElixir.RuntimeSupervisor,
        SymphonyElixir.CleanupSupervisor
      ])

    try do
      handle =
        CleanupGuardian.start_handle(
          self(),
          ImmediateCleanupAdapter,
          :fixture,
          0
        )

      assert Process.alive?(handle.pid)
      refute CleanupGuardian.verified?(handle)

      guardian_ref = Process.monitor(handle.pid)
      assert :ok = CleanupGuardian.cleanup_verified(handle)
      assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
      assert guardian == handle.pid
      assert CleanupGuardian.verified?(handle)
    after
      restore_runtime_names!(runtime)
    end
  end

  test "cleanup-once reports unavailable and non-responsive authorities" do
    dead_guardian = spawn(fn -> :ok end)
    dead_ref = Process.monitor(dead_guardian)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_guardian, :normal}, 1_000

    assert {:error, :cleanup_guardian_unavailable} =
             CleanupGuardian.request_cleanup_once(dead_guardian, 100)

    non_responsive_guardian = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> if Process.alive?(non_responsive_guardian), do: Process.exit(non_responsive_guardian, :kill) end)

    assert {:error, :cleanup_in_progress} =
             CleanupGuardian.request_cleanup_once(non_responsive_guardian, 0)
  end

  test "duplicate cleanup requests never create a second physical stop caller" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    handle =
      CleanupGuardian.start_handle(
        self(),
        ControlledCleanupAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0
      )

    guardian_ref = Process.monitor(handle.pid)

    on_exit(fn ->
      if Process.alive?(handle.pid), do: CleanupGuardian.cleanup_verified(handle)
    end)

    assert {:error, :cleanup_held} = CleanupGuardian.request_cleanup_once(handle.pid, 1_000)
    assert_receive {:controlled_cleanup_attempt, _first_caller, false}, 1_000

    assert {:error, :cleanup_in_progress} =
             CleanupGuardian.request_cleanup_once(handle.pid, 1_000)

    assert :ok = CleanupGuardian.request_cleanup(handle)
    assert :ok = CleanupGuardian.cleanup_verified(handle)
    assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
    assert guardian == handle.pid
    assert CleanupGuardian.verified?(handle)
    refute_receive {:controlled_cleanup_attempt, _second_caller, _allowed?}, 100
  end

  test "invalid and faulting guardian starters hold cleanup authority fail closed" do
    test_pid = self()

    starters = [
      invalid: fn _guardian_fun ->
        send(test_pid, {:guardian_starter_invoked, :invalid})
        :invalid
      end,
      raised: fn _guardian_fun ->
        send(test_pid, {:guardian_starter_invoked, :raised})
        raise "injected guardian start failure"
      end,
      thrown: fn _guardian_fun ->
        send(test_pid, {:guardian_starter_invoked, :thrown})
        throw(:injected_guardian_start_failure)
      end
    ]

    Enum.each(starters, fn {kind, starter} ->
      caller =
        spawn(fn ->
          result =
            CleanupGuardian.start_handle_with_starter_for_test(
              self(),
              ImmediateCleanupAdapter,
              :fixture,
              0,
              starter
            )

          send(test_pid, {:guardian_starter_returned, kind, result})
        end)

      assert_receive {:guardian_starter_invoked, ^kind}, 1_000
      refute_receive {:guardian_starter_returned, ^kind, _result}, 100
      assert Process.alive?(caller)
      Process.exit(caller, :kill)
    end)
  end

  test "an ambiguous guardian acknowledgement remains adoptable after a persistent hold cycle" do
    test_pid = self()

    owner =
      spawn(fn ->
        handle =
          CleanupGuardian.start_handle_with_starter_for_test(
            self(),
            ImmediateCleanupAdapter,
            :fixture,
            0,
            fn guardian_fun ->
              send(test_pid, {:delayed_guardian_fun, guardian_fun})
              {:error, :ambiguous_guardian_start}
            end
          )

        send(test_pid, {:delayed_guardian_adopted, handle})

        receive do
          :release_delayed_guardian_owner -> :ok
        end
      end)

    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)

    assert_receive {:delayed_guardian_fun, guardian_fun}, 1_000
    Process.sleep(6_100)
    guardian = spawn(guardian_fun)

    assert_receive {:delayed_guardian_adopted, %CleanupGuardian.Handle{} = handle}, 1_000
    assert handle.pid == guardian

    guardian_ref = Process.monitor(guardian)
    assert :ok = CleanupGuardian.request_cleanup(handle)
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    assert CleanupGuardian.verified?(handle)

    send(owner, :release_delayed_guardian_owner)
  end

  test "a claimed guardian that never acknowledges readiness is killed before authority returns" do
    test_pid = self()

    assert_raise RuntimeError, "runtime cleanup guardian unavailable", fn ->
      CleanupGuardian.start_handle_with_starter_for_test(
        self(),
        ImmediateCleanupAdapter,
        :fixture,
        0,
        fn _guardian_fun ->
          guardian = spawn(fn -> Process.sleep(:infinity) end)
          send(test_pid, {:unready_claimed_guardian, guardian})
          {:ok, guardian}
        end
      )
    end

    assert_receive {:unready_claimed_guardian, guardian}, 1_000
    refute Process.alive?(guardian)
  end

  test "an unavailable runtime barrier re-requests cleanup while retaining sole authority" do
    runtime =
      unregister_runtime_names!([
        SymphonyElixir.CleanupBarrier,
        SymphonyElixir.CleanupSupervisor
      ])

    {:ok, allow_stop} = Agent.start_link(fn -> false end)
    test_pid = self()

    caller =
      spawn(fn ->
        result =
          try do
            CleanupGuardian.start_handle_with_starter_for_test(
              self(),
              ControlledCleanupAdapter,
              %{allow_stop: allow_stop, test_pid: test_pid},
              0,
              fn guardian_fun ->
                guardian = spawn(guardian_fun)
                send(test_pid, {:unbarriered_guardian, guardian})
                {:ok, guardian}
              end
            )
          rescue
            error -> error
          end

        send(test_pid, {:unbarriered_guardian_result, result})
      end)

    try do
      assert_receive {:unbarriered_guardian, guardian}, 1_000
      on_exit(fn -> if Process.alive?(guardian), do: Process.exit(guardian, :kill) end)
      assert_receive {:controlled_cleanup_attempt, _worker, false}, 1_000

      Process.sleep(5_200)
      assert Process.alive?(caller)
      refute_receive {:unbarriered_guardian_result, _result}, 0

      Agent.update(allow_stop, fn _held -> true end)
      send(guardian, :retry_cleanup)

      assert_receive {:controlled_cleanup_attempt, _worker, true}, 1_000

      assert_receive {:unbarriered_guardian_result, %RuntimeError{message: "runtime cleanup barrier unavailable"}},
                     1_000
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      restore_runtime_names!(runtime)
    end
  end

  test "lost unbarriered authority holds forever instead of returning inline cleanup" do
    runtime =
      unregister_runtime_names!([
        SymphonyElixir.CleanupBarrier,
        SymphonyElixir.CleanupSupervisor
      ])

    {:ok, allow_stop} = Agent.start_link(fn -> false end)
    test_pid = self()

    caller =
      spawn(fn ->
        result =
          CleanupGuardian.start_handle_with_starter_for_test(
            self(),
            ControlledCleanupAdapter,
            %{allow_stop: allow_stop, test_pid: test_pid},
            0,
            fn guardian_fun ->
              guardian = spawn(guardian_fun)
              send(test_pid, {:lost_unbarriered_guardian, guardian})
              {:ok, guardian}
            end
          )

        send(test_pid, {:lost_unbarriered_result, result})
      end)

    try do
      assert_receive {:lost_unbarriered_guardian, guardian}, 1_000
      assert_receive {:controlled_cleanup_attempt, _worker, false}, 1_000

      guardian_ref = Process.monitor(guardian)
      Process.exit(guardian, :kill)
      assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :killed}, 1_000

      send(caller, :unrelated_message)
      refute_receive {:lost_unbarriered_result, _result}, 100
      assert Process.alive?(caller)
    after
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      restore_runtime_names!(runtime)
    end
  end

  test "verified cleanup before callback registration cannot wedge the controller" do
    root = unique_root("verified-before-registration")
    issue = issue("issue-verified-before-registration", "MT-VERIFIED-BEFORE-REGISTRATION")

    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    assert {:ok, controller} =
             AgentRunner.start_supervised(issue, self(), process_adapter: VerifiedBeforeRegistrationAdapter)

    controller_ref = Process.monitor(controller)

    assert_receive {:codex_worker_update, _, %{event: :process_cleanup_failed}}, 5_000
    assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 5_000
    assert File.dir?(Path.join(root, issue.identifier))
  end

  test "a dead but unverified cleanup handle remains fail-closed" do
    root = unique_root("lost-before-registration")
    issue = issue("issue-lost-before-registration", "MT-LOST-BEFORE-REGISTRATION")

    on_exit(fn -> File.rm_rf(root) end)
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

    assert {:ok, controller} =
             AgentRunner.start_supervised(issue, self(), process_adapter: LostBeforeRegistrationAdapter)

    on_exit(fn -> if Process.alive?(controller), do: Process.exit(controller, :kill) end)

    assert_receive {:codex_worker_update, _, %{event: :process_cleanup_failed}}, 5_000
    Process.sleep(100)
    assert Process.alive?(controller)
    assert File.dir?(Path.join(root, issue.identifier))
  end

  test "an already-dead cooperative controller preserves the workspace and claim" do
    root = unique_root("dead-controller")
    workspace = Path.join(root, "MT-DEAD-CONTROLLER")
    issue = issue("issue-dead-controller", "MT-DEAD-CONTROLLER")

    try do
      File.mkdir_p!(workspace)
      File.write!(Path.join(workspace, "sentinel"), "preserve")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: root)

      assert {:ok, controller} =
               Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
                 Process.sleep(:infinity)
               end)

      controller_ref = Process.monitor(controller)
      Process.exit(controller, :kill)
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, :killed}, 1_000

      state = running_state(issue, controller, controller_ref, workspace)

      updated_state =
        Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(updated_state.running, issue.id)
      assert Map.has_key?(updated_state.blocked, issue.id)
      assert updated_state.blocked[issue.id].preserve_on_terminal?
      assert MapSet.member?(updated_state.claimed, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
    after
      File.rm_rf(root)
    end
  end

  test "after_run containment validation failure propagates and preserves the workspace" do
    root = unique_root("after-run-containment")
    workspace_root = Path.join(root, "workspaces")
    hook_marker = Path.join(root, "after-run.log")
    fake = install_fake_codex!(root, :interrupt_ok)
    issue = issue("issue-after-run-containment", "MT-AFTER-RUN-CONTAINMENT")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake.binary} app-server",
        codex_read_timeout_ms: 1_000,
        hook_timeout_ms: 2_000,
        hook_after_run: "printf '%s\\n' ran > '#{hook_marker}'"
      )

      {controller, workspace} = start_agent!(issue)
      controller_ref = Process.monitor(controller)
      displaced_workspace = workspace <> "-displaced"

      File.write!(Path.join(workspace, "sentinel"), "preserve")
      File.rename!(workspace, displaced_workspace)
      File.ln_s!(displaced_workspace, workspace)

      state = running_state(issue, controller, controller_ref, workspace)

      updated_state =
        Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(workspace)
      assert File.read!(Path.join(displaced_workspace, "sentinel")) == "preserve"
      refute File.exists?(hook_marker)
      refute Map.has_key?(updated_state.running, issue.id)
      assert Map.has_key?(updated_state.blocked, issue.id)
      assert updated_state.blocked[issue.id].preserve_on_terminal?
      assert MapSet.member?(updated_state.claimed, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
    after
      File.rm_rf(root)
    end
  end

  test "AgentRunner enables managed tools only through the explicit option" do
    root = unique_root("explicit-managed")
    workspace_root = Path.join(root, "workspaces")
    fake = install_fake_codex!(root, :interrupt_ok)
    issue = issue("issue-explicit-managed", "MT-EXPLICIT-MANAGED")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake.binary} app-server",
        codex_read_timeout_ms: 1_000,
        hook_timeout_ms: 2_000
      )

      {controller, workspace} = start_agent!(issue, managed: true)

      assert {:ok, %{workspace_path: ^workspace}} =
               AgentRunner.cancel(controller, AgentRunner.cancellation_timeout_ms())

      await_process_down(controller)

      description = fake.request_log |> read_requests!() |> dynamic_tool_description()

      assert description =~ "current Linear issue"
      refute description =~ "raw GraphQL query or mutation"
    after
      File.rm_rf(root)
    end
  end

  test "interrupt failure and unresolved turn uncertainty block cleanup" do
    root = unique_root("interrupt-failure")
    workspace_root = Path.join(root, "workspaces")
    fake = install_fake_codex!(root, :interrupt_error)
    issue = issue("issue-interrupt-failure", "MT-INTERRUPT-FAILURE")

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{fake.binary} app-server",
        codex_read_timeout_ms: 1_000,
        hook_timeout_ms: 2_000
      )

      {controller, workspace} = start_agent!(issue)
      File.write!(Path.join(workspace, "sentinel"), "preserve")
      controller_ref = Process.monitor(controller)
      state = running_state(issue, controller, controller_ref, workspace)

      updated_state =
        Orchestrator.reconcile_issue_states_for_test([%{issue | state: "Closed"}], state)

      assert Enum.any?(read_requests!(fake.request_log), &(&1["method"] == "turn/interrupt"))
      assert File.read!(Path.join(workspace, "sentinel")) == "preserve"
      refute Map.has_key?(updated_state.running, issue.id)
      assert Map.has_key?(updated_state.blocked, issue.id)
      assert updated_state.blocked[issue.id].preserve_on_terminal?
      assert MapSet.member?(updated_state.claimed, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
    after
      File.rm_rf(root)
    end
  end

  test "cancellation cannot discard a collected uncertain turn-start result" do
    uncertainty =
      TransportError.new(:uncertain_external_outcome, %{
        operation: %{
          classification: :side_effecting,
          method: "turn/start",
          send_state: :sent
        },
        reconciliation_required: true
      })

    assert {:error, ^uncertainty} =
             AgentRunner.cancellation_finish_result_for_test({:error, uncertainty}, :ok)
  end

  test "unverified App Server startup rollback blocks retry while cleanup authority is retained" do
    root = unique_root("startup-rollback")
    workspace_root = Path.join(root, "workspaces")
    issue = issue("issue-startup-rollback", "MT-STARTUP-ROLLBACK")

    previous_test_pid =
      Application.get_env(:symphony_elixir, :retained_startup_rollback_test_pid)

    Application.put_env(
      :symphony_elixir,
      :retained_startup_rollback_test_pid,
      self()
    )

    on_exit(fn ->
      restore_application_env(
        :retained_startup_rollback_test_pid,
        previous_test_pid
      )

      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_timeout_ms: 2_000
    )

    {:ok, sink} = start_supervised({Memory, max_events_per_run: 16})
    recipient = self()

    assert {:ok, controller} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               AgentRunner.run(issue, recipient,
                 correlation: %{
                   run_id: @hook_failure_run_id,
                   attempt_id: @hook_failure_attempt_id
                 },
                 process_adapter: RetainedStartupRollbackAdapter
               )
             end)

    on_exit(fn -> terminate_task_if_alive(controller) end)
    controller_ref = Process.monitor(controller)

    assert_receive {:startup_cleanup_authority_ready, authority}, 5_000
    authority_ref = Process.monitor(authority)
    on_exit(fn -> if Process.alive?(authority), do: send(authority, :release_cleanup) end)

    issue_id = issue.id
    expected_workspace = Path.join(workspace_root, issue.identifier)

    initial_state =
      hook_failure_running_state(
        issue,
        controller,
        controller_ref,
        {Memory, sink}
      )

    assert_receive {:worker_runtime_info, ^issue_id,
                    %{
                      workspace_path: ^expected_workspace,
                      workspace_root: ^workspace_root,
                      run_id: @hook_failure_run_id,
                      attempt_id: @hook_failure_attempt_id
                    }} = runtime_message,
                   5_000

    assert {:noreply, runtime_state} =
             Orchestrator.handle_info(runtime_message, initial_state)

    assert_receive {:codex_worker_update, ^issue_id,
                    %{
                      event: :process_cleanup_failed,
                      reason: %TransportError{
                        kind: :process_cleanup_failed,
                        details: %{
                          cleanup_verified: false,
                          reason: :startup_rollback_unverified
                        }
                      },
                      run_id: @hook_failure_run_id,
                      attempt_id: @hook_failure_attempt_id
                    }} = cleanup_message,
                   5_000

    assert {:noreply, cleanup_state} =
             Orchestrator.handle_info(cleanup_message, runtime_state)

    assert Process.alive?(controller)
    assert Process.alive?(authority)
    assert File.dir?(expected_workspace)
    refute Map.has_key?(cleanup_state.retry_attempts, issue_id)

    send(authority, :release_cleanup)
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, :normal}, 1_000

    assert_receive {:DOWN, ^controller_ref, :process, ^controller, down_reason},
                   5_000

    assert {:noreply, blocked_state} =
             Orchestrator.handle_info(
               {:DOWN, controller_ref, :process, controller, down_reason},
               cleanup_state
             )

    blocked_entry = Map.fetch!(blocked_state.blocked, issue_id)
    assert File.dir?(expected_workspace)
    assert blocked_entry.workspace_path == expected_workspace
    assert blocked_entry.workspace_root == workspace_root
    assert blocked_entry.last_codex_event == :process_cleanup_failed
    assert blocked_entry.preserve_on_terminal?
    assert MapSet.member?(blocked_state.claimed, issue_id)
    refute Map.has_key?(blocked_state.running, issue_id)
    refute Map.has_key?(blocked_state.retry_attempts, issue_id)
  end

  test "startup cleanup authority blocks an Orchestrator crash restart until recovery" do
    root = unique_root("startup-rollback-runtime")
    workspace_root = Path.join(root, "workspaces")
    issue = issue("issue-startup-rollback-runtime", "MT-STARTUP-ROLLBACK-RUNTIME")
    previous_test_pid = Application.get_env(:symphony_elixir, :retained_startup_rollback_test_pid)

    Application.put_env(:symphony_elixir, :retained_startup_rollback_test_pid, self())

    on_exit(fn ->
      restore_application_env(
        :retained_startup_rollback_test_pid,
        previous_test_pid
      )

      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, controller} =
             AgentRunner.start_supervised(issue, self(), process_adapter: RetainedStartupRollbackAdapter)

    controller_ref = Process.monitor(controller)
    assert_receive {:startup_cleanup_authority_ready, authority}, 5_000
    authority_ref = Process.monitor(authority)

    on_exit(fn ->
      if Process.alive?(authority), do: send(authority, :release_cleanup)
      if Process.alive?(controller), do: Process.exit(controller, :kill)
    end)

    assert_receive {:codex_worker_update, _, %{event: :process_cleanup_failed}}, 5_000
    assert Process.alive?(controller)

    runtime = runtime_snapshot()
    old_orchestrator = Map.fetch!(runtime.children, SymphonyElixir.Orchestrator)
    Process.exit(old_orchestrator, :kill)

    assert_runtime_unchanged(runtime, 750)
    assert Process.alive?(controller)
    assert Process.alive?(authority)

    send(authority, :release_cleanup)
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, :normal}, 1_000
    assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 2_000

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_runtime_replacement(name, old_pid, 2_000))
    end)
  end

  test "cancellation during an unresolved App Server start cannot report retired containment" do
    root = unique_root("startup-rollback-cancel")
    workspace_root = Path.join(root, "workspaces")
    issue = issue("issue-startup-rollback-cancel", "MT-STARTUP-ROLLBACK-CANCEL")

    previous_test_pid =
      Application.get_env(:symphony_elixir, :retained_startup_rollback_test_pid)

    previous_test_mode =
      Application.get_env(
        :symphony_elixir,
        :retained_startup_rollback_test_mode
      )

    Application.put_env(
      :symphony_elixir,
      :retained_startup_rollback_test_pid,
      self()
    )

    Application.put_env(
      :symphony_elixir,
      :retained_startup_rollback_test_mode,
      :held
    )

    on_exit(fn ->
      restore_application_env(
        :retained_startup_rollback_test_pid,
        previous_test_pid
      )

      restore_application_env(
        :retained_startup_rollback_test_mode,
        previous_test_mode
      )

      File.rm_rf(root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_timeout_ms: 2_000
    )

    assert {:ok, controller} =
             AgentRunner.start_supervised(issue, self(), process_adapter: RetainedStartupRollbackAdapter)

    on_exit(fn -> terminate_task_if_alive(controller) end)
    controller_ref = Process.monitor(controller)

    assert_receive {:startup_cleanup_authority_ready, authority}, 5_000
    authority_ref = Process.monitor(authority)
    on_exit(fn -> if Process.alive?(authority), do: send(authority, :release_cleanup) end)

    assert_receive {:startup_adapter_waiting, connection}, 1_000
    connection_ref = Process.monitor(connection)
    on_exit(fn -> if Process.alive?(connection), do: send(connection, :return_start_failure) end)

    assert {:error, :app_server_connection_discovery_incomplete} =
             AgentRunner.cancel(
               controller,
               AgentRunner.cancellation_timeout_ms()
             )

    assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason},
                   5_000

    assert Process.alive?(connection)
    assert Process.alive?(authority)
    assert File.dir?(Path.join(workspace_root, issue.identifier))

    send(connection, :return_start_failure)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 2_000

    send(authority, :release_cleanup)
    assert_receive {:DOWN, ^authority_ref, :process, ^authority, :normal}, 1_000
  end

  test "blocked terminal cleanup uses its stored workspace after a root reload" do
    root = unique_root("blocked-root-reload")
    original_root = Path.join(root, "root-a")
    reloaded_root = Path.join(root, "root-b")
    issue = issue("issue-blocked-root-reload", "MT-BLOCKED-ROOT-RELOAD")
    bound_workspace = Path.join(original_root, issue.identifier)
    reloaded_workspace = Path.join(reloaded_root, issue.identifier)
    reloaded_sentinel = Path.join(reloaded_workspace, "sentinel")

    try do
      File.mkdir_p!(bound_workspace)
      File.mkdir_p!(reloaded_workspace)
      File.write!(Path.join(bound_workspace, "sentinel"), "remove")
      File.write!(reloaded_sentinel, "preserve")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: reloaded_root)

      updated_state =
        Orchestrator.reconcile_blocked_issue_states_for_test(
          [%{issue | state: "Closed"}],
          blocked_state(issue, bound_workspace)
        )

      refute File.exists?(bound_workspace)
      assert File.read!(reloaded_sentinel) == "preserve"
      refute Map.has_key?(updated_state.blocked, issue.id)
      refute MapSet.member?(updated_state.claimed, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
    after
      File.rm_rf(root)
    end
  end

  test "blocked terminal cleanup failure retains the stored workspace and claim" do
    root = unique_root("blocked-cleanup-failure")
    captured_root = Path.join(root, "captured-root")
    moved_root = Path.join(root, "captured-root-moved")
    reloaded_root = Path.join(root, "reloaded-root")
    issue = issue("issue-blocked-cleanup-failure", "MT-BLOCKED-CLEANUP-FAILURE")
    bound_workspace = Path.join(captured_root, issue.identifier)
    reloaded_workspace = Path.join(reloaded_root, issue.identifier)
    bound_sentinel = Path.join(bound_workspace, "sentinel")
    reloaded_sentinel = Path.join(reloaded_workspace, "sentinel")

    try do
      File.mkdir_p!(bound_workspace)
      File.mkdir_p!(reloaded_workspace)
      File.write!(bound_sentinel, "preserve-bound")
      File.write!(reloaded_sentinel, "preserve-reloaded")

      File.rename!(captured_root, moved_root)
      File.ln_s!(moved_root, captured_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: reloaded_root)

      initial_state = blocked_state(issue, bound_workspace)

      updated_state =
        Orchestrator.reconcile_blocked_issue_states_for_test(
          [%{issue | state: "Closed"}],
          initial_state
        )

      assert File.read!(bound_sentinel) == "preserve-bound"
      assert File.read!(reloaded_sentinel) == "preserve-reloaded"
      assert Map.has_key?(updated_state.blocked, issue.id)

      assert updated_state.blocked[issue.id].blocked_at ==
               initial_state.blocked[issue.id].blocked_at

      assert MapSet.member?(updated_state.claimed, issue.id)
      refute Map.has_key?(updated_state.retry_attempts, issue.id)
    after
      File.rm_rf(root)
    end
  end

  test "real after_create cleanup failure publishes its binding and stays sticky through DOWN and terminal input" do
    assert_real_hook_cleanup_block!(:after_create)
  end

  test "real before_run cleanup failure preserves its binding and stays sticky through DOWN and terminal input" do
    assert_real_hook_cleanup_block!(:before_run)
  end

  defp assert_real_hook_cleanup_block!(hook_phase) do
    root = unique_root("#{hook_phase}-cleanup")
    workspace_root = Path.join(root, "workspaces")
    ready_path = Path.join(root, "#{hook_phase}-ready")
    issue = issue("issue-#{hook_phase}-cleanup", "MT-#{hook_phase |> Atom.to_string() |> String.upcase()}")
    expected_workspace = Path.join(workspace_root, issue.identifier)
    hook_command = "printf ready > '#{ready_path}'; while :; do sleep 1; done"

    on_exit(fn -> File.rm_rf(root) end)

    hook_override_key = String.to_existing_atom("hook_#{hook_phase}")

    workflow_overrides =
      [
        workspace_root: workspace_root,
        hook_timeout_ms: 1_000
      ]
      |> Keyword.put(hook_override_key, hook_command)

    write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)
    {:ok, sink} = start_supervised({Memory, max_events_per_run: 16})
    recipient = self()

    assert {:ok, controller} =
             Task.Supervisor.start_child(SymphonyElixir.TaskSupervisor, fn ->
               AgentRunner.run(issue, recipient,
                 correlation: %{
                   run_id: @hook_failure_run_id,
                   attempt_id: @hook_failure_attempt_id
                 }
               )
             end)

    on_exit(fn -> terminate_task_if_alive(controller) end)
    controller_ref = Process.monitor(controller)

    assert wait_for_path(ready_path, 3_000)

    task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)
    worker = await_linked_child(controller, [task_supervisor], 1_000)
    hook_runner = await_linked_child(worker, [controller], 1_000)
    hook_runner_ref = Process.monitor(hook_runner)

    assert true == :erlang.suspend_process(hook_runner)
    assert {:status, :suspended} = Process.info(hook_runner, :status)

    on_exit(fn -> resume_process_if_alive(hook_runner) end)

    initial_state =
      hook_failure_running_state(
        issue,
        controller,
        controller_ref,
        {Memory, sink}
      )

    issue_id = issue.id

    assert_receive {:worker_runtime_info, ^issue_id,
                    %{
                      workspace_path: ^expected_workspace,
                      workspace_root: ^workspace_root,
                      run_id: @hook_failure_run_id,
                      attempt_id: @hook_failure_attempt_id
                    }} = runtime_message,
                   15_000

    assert {:noreply, runtime_state} = Orchestrator.handle_info(runtime_message, initial_state)

    assert_receive {:codex_worker_update, ^issue_id,
                    %{
                      event: :process_cleanup_failed,
                      reason: %{kind: :workspace_cleanup_failed},
                      run_id: @hook_failure_run_id,
                      attempt_id: @hook_failure_attempt_id
                    }} = cleanup_message,
                   15_000

    assert {:noreply, cleanup_state} = Orchestrator.handle_info(cleanup_message, runtime_state)

    assert_receive {:DOWN, ^controller_ref, :process, ^controller, down_reason}, 3_000

    assert {:noreply, blocked_state} =
             Orchestrator.handle_info(
               {:DOWN, controller_ref, :process, controller, down_reason},
               cleanup_state
             )

    blocked_entry = Map.fetch!(blocked_state.blocked, issue_id)
    assert blocked_entry.workspace_path == expected_workspace
    assert blocked_entry.workspace_root == workspace_root
    assert blocked_entry.last_codex_event == :process_cleanup_failed
    assert blocked_entry.preserve_on_terminal?
    assert File.dir?(expected_workspace)
    assert MapSet.member?(blocked_state.claimed, issue_id)
    refute Map.has_key?(blocked_state.running, issue_id)
    refute Map.has_key?(blocked_state.retry_attempts, issue_id)

    terminal_issue = %{issue | state: "Closed"}

    repeated_state =
      Orchestrator.reconcile_blocked_issue_states_for_test(
        [terminal_issue, terminal_issue],
        blocked_state
      )

    repeated_entry = Map.fetch!(repeated_state.blocked, issue_id)
    assert repeated_entry.blocked_at == blocked_entry.blocked_at
    assert repeated_entry.workspace_path == expected_workspace
    assert repeated_entry.workspace_root == workspace_root
    assert repeated_entry.last_codex_event == :process_cleanup_failed
    assert repeated_entry.preserve_on_terminal?
    assert File.dir?(expected_workspace)
    assert MapSet.member?(repeated_state.claimed, issue_id)
    refute Map.has_key?(repeated_state.retry_attempts, issue_id)

    resume_process_if_alive(hook_runner)
    assert_receive {:DOWN, ^hook_runner_ref, :process, ^hook_runner, _reason}, 5_000
  end

  defp start_agent!(issue, opts \\ []) do
    recipient = self()
    issue_id = issue.id

    assert {:ok, controller} = AgentRunner.start_supervised(issue, recipient, opts)

    on_exit(fn -> terminate_task_if_alive(controller) end)

    assert_receive {:worker_runtime_info, ^issue_id, %{workspace_path: workspace}}, 5_000

    assert_receive {:codex_worker_update, ^issue_id, %{event: :session_started, thread_id: "thread-cancel", turn_id: "turn-cancel"}},
                   5_000

    {controller, workspace}
  end

  defp running_state(issue, controller, controller_ref, workspace) do
    %Orchestrator.State{
      running: %{
        issue.id => %{
          cancel_mode: :cooperative,
          pid: controller,
          ref: controller_ref,
          identifier: issue.identifier,
          issue: issue,
          workspace_path: workspace,
          workspace_root: Path.dirname(workspace),
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp hook_failure_running_state(issue, controller, controller_ref, event_sink) do
    %Orchestrator.State{
      running: %{
        issue.id => %{
          cancel_mode: :cooperative,
          pid: controller,
          ref: controller_ref,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: nil,
          workspace_root: nil,
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
          run_id: @hook_failure_run_id,
          attempt_id: @hook_failure_attempt_id,
          event_sequence: 0,
          last_event_id: nil,
          last_event_type: nil,
          started_at: DateTime.utc_now()
        }
      },
      claimed: MapSet.new([issue.id]),
      event_sink: event_sink,
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp blocked_state(issue, workspace) do
    blocked_at = DateTime.utc_now()

    %Orchestrator.State{
      running: %{},
      blocked: %{
        issue.id => %{
          issue_id: issue.id,
          identifier: issue.identifier,
          issue: issue,
          worker_host: nil,
          workspace_path: workspace,
          workspace_root: Path.dirname(workspace),
          session_id: "blocked-session",
          error: "cleanup pending",
          blocked_at: blocked_at,
          preserve_on_terminal?: false
        }
      },
      claimed: MapSet.new([issue.id]),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Cancellation safety regression",
      description: "Prove cleanup remains fail closed",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp install_fake_codex!(root, interrupt_mode) do
    File.mkdir_p!(root)
    binary = Path.join(root, "fake-codex")
    request_log = Path.join(root, "requests.log")

    interrupt_body =
      case interrupt_mode do
        :interrupt_ok ->
          """
          printf '%s\\n' '{"id":4,"result":{}}'
          printf '%s\\n' '{"method":"turn/cancelled","params":{"threadId":"thread-cancel","turn":{"id":"turn-cancel"}}}'
          while :; do sleep 1; done
          """

        :interrupt_error ->
          """
          printf '%s\\n' '{"id":4,"error":{"code":-32001,"message":"interrupt rejected"}}'
          while :; do sleep 1; done
          """
      end

    File.write!(
      binary,
      """
      #!/bin/sh
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
            #{interrupt_body}
            ;;
        esac
      done
      """
    )

    File.chmod!(binary, 0o755)
    %{binary: binary, request_log: request_log}
  end

  defp read_requests!(request_log) do
    request_log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp dynamic_tool_description(requests) do
    thread_start = Enum.find(requests, &(&1["method"] == "thread/start"))
    get_in(thread_start, ["params", "dynamicTools", Access.at(0), "description"])
  end

  defp await_process_down(pid) do
    monitor_ref = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> flunk("agent controller did not exit")
    end
  end

  defp await_linked_child(parent, excluded, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_linked_child(parent, MapSet.new(excluded), deadline_ms)
  end

  defp do_await_linked_child(parent, excluded, deadline_ms) do
    candidates =
      case Process.info(parent, :links) do
        {:links, links} ->
          Enum.filter(links, fn pid ->
            is_pid(pid) and Process.alive?(pid) and not MapSet.member?(excluded, pid)
          end)

        nil ->
          []
      end

    case Enum.find(candidates, &workspace_hook_process?/1) || List.first(candidates) do
      pid when is_pid(pid) ->
        pid

      nil ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(10)
          do_await_linked_child(parent, excluded, deadline_ms)
        else
          flunk("linked hook process was not discovered before the deadline")
        end
    end
  end

  defp workspace_hook_process?(pid) do
    case Process.info(pid, :current_function) do
      {:current_function, {SymphonyElixir.WorkspaceHookRunner, _function, _arity}} -> true
      _other -> false
    end
  end

  defp wait_for_path(path, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_path(path, deadline_ms)
  end

  defp do_wait_for_path(path, deadline_ms) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(10)
        do_wait_for_path(path, deadline_ms)
    end
  end

  defp resume_process_if_alive(pid) when is_pid(pid) do
    case Process.info(pid, :status) do
      {:status, :suspended} ->
        :erlang.resume_process(pid)
        :ok

      _not_suspended_or_dead ->
        :ok
    end
  end

  defp terminate_task_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
        :ok -> :ok
        {:error, :not_found} -> Process.exit(pid, :kill)
      end
    end

    :ok
  end

  defp runtime_snapshot do
    %{
      parent: Process.whereis(SymphonyElixir.RuntimeSupervisor),
      children: Map.new(@runtime_children, &{&1, Process.whereis(&1)})
    }
  end

  defp assert_runtime_unchanged(runtime, duration_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + duration_ms
    do_assert_runtime_unchanged(runtime, deadline_ms)
  end

  defp do_assert_runtime_unchanged(runtime, deadline_ms) do
    assert Process.whereis(SymphonyElixir.RuntimeSupervisor) == runtime.parent

    Enum.each(runtime.children, fn {name, old_pid} ->
      case Process.whereis(name) do
        pid when is_nil(pid) or pid == old_pid -> :ok
        _replacement -> flunk("#{inspect(name)} restarted before startup cleanup recovery")
      end
    end)

    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(10)
      do_assert_runtime_unchanged(runtime, deadline_ms)
    else
      :ok
    end
  end

  defp await_runtime_replacement(name, old_pid, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_runtime_replacement(name, old_pid, deadline_ms)
  end

  defp do_await_runtime_replacement(name, old_pid, deadline_ms) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pending ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(10)
          do_await_runtime_replacement(name, old_pid, deadline_ms)
        else
          flunk("#{inspect(name)} did not restart after startup cleanup recovery")
        end
    end
  end

  defp restore_application_env(key, nil),
    do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:symphony_elixir, key, value)

  defp unregister_runtime_names!(names) do
    registrations =
      Enum.map(names, fn name ->
        pid = Process.whereis(name)
        assert is_pid(pid)
        assert Process.unregister(name)
        {name, pid}
      end)

    on_exit(fn -> restore_runtime_names!(registrations) end)
    registrations
  end

  defp restore_runtime_names!(registrations) do
    Enum.each(registrations, fn {name, pid} ->
      if Process.alive?(pid) and is_nil(Process.whereis(name)) do
        Process.register(pid, name)
      end
    end)

    :ok
  end

  defp unique_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-elixir-cancellation-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end
end
