# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.HookCancellationContainmentTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.CleanupGuardian

  @runtime_children [
    SymphonyElixir.CleanupBarrier,
    SymphonyElixir.CleanupSupervisor,
    SymphonyElixir.ConnectionSupervisor,
    SymphonyElixir.TaskSupervisor,
    SymphonyElixir.WorkspaceHookSupervisor,
    SymphonyElixir.Orchestrator
  ]

  defmodule RecoveringHookRunner do
    @moduledoc false

    def run(_command, _workspace, hook_name, _timeout_ms, opts) do
      owner = self()
      observer = Keyword.get(opts, :observer)
      result_ref = make_ref()

      test_pid =
        Application.fetch_env!(
          :symphony_elixir,
          :recovering_hook_runner_test_pid
        )

      runner_fun = fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(owner)
        notify(observer, {:workspace_hook_runner_started, self()})
        send(test_pid, {:recovering_hook_runner_ready, self()})

        await_owner_exit(owner, owner_ref)

        error =
          {:error, {:workspace_hook_cleanup_failed, hook_name, :injected_stop}}

        notify(
          observer,
          {:workspace_hook_runner_cleanup_failed, self(), error}
        )

        send(test_pid, {:recovering_hook_cleanup_failed, self()})
        send(owner, {result_ref, error})
        await_recovery(observer, hook_name, test_pid)
      end

      with {:ok, runner} <-
             Task.Supervisor.start_child(
               SymphonyElixir.WorkspaceHookSupervisor,
               runner_fun,
               shutdown: :infinity
             ) do
        Process.link(runner)
        monitor_ref = Process.monitor(runner)

        receive do
          {^result_ref, result} ->
            Process.unlink(runner)
            Process.demonitor(monitor_ref, [:flush])
            result

          {:DOWN, ^monitor_ref, :process, ^runner, _reason} ->
            {:error, {:workspace_hook_runner_failed, hook_name}}
        end
      end
    end

    defp await_owner_exit(owner, owner_ref) do
      receive do
        {:EXIT, ^owner, _reason} -> :ok
        {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
        _message -> await_owner_exit(owner, owner_ref)
      end
    end

    defp await_recovery(observer, hook_name, test_pid) do
      receive do
        :recover_cleanup ->
          recovered =
            {:error, {:workspace_hook_cleanup_recovered, hook_name}}

          notify(
            observer,
            {:workspace_hook_runner_stopped, self(), recovered}
          )

          send(test_pid, {:recovering_hook_cleanup_recovered, self()})
          :ok

        _message ->
          await_recovery(observer, hook_name, test_pid)
      end
    end

    defp notify(observer, message) when is_function(observer, 1),
      do: observer.(message)

    defp notify(_observer, _message), do: :ok
  end

  test "hook startup cleanup accepts verified late registration and rejects lost authority" do
    verified_status = :atomics.new(1, [])
    :ok = :atomics.put(verified_status, 1, 1)
    verified_pid = spawn(fn -> :ok end)
    verified_ref = Process.monitor(verified_pid)
    assert_receive {:DOWN, ^verified_ref, :process, ^verified_pid, :normal}, 1_000

    verified = %CleanupGuardian.Handle{pid: verified_pid, status: verified_status}
    test_pid = self()
    observer = fn event -> send(test_pid, {:hook_cleanup_observer, event}) end

    assert :ok =
             SymphonyElixir.WorkspaceHookRunner.await_startup_cleanup_for_test(
               verified,
               observer,
               "before_run"
             )

    assert_receive {
                     :hook_cleanup_observer,
                     {:workspace_hook_runner_stopped, _runner, {:error, {:workspace_hook_cleanup_recovered, "before_run"}}}
                   },
                   1_000

    live_status = :atomics.new(1, [])
    :ok = :atomics.put(live_status, 1, 0)

    live_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    live = %CleanupGuardian.Handle{pid: live_pid, status: live_status}

    live_waiter =
      spawn(fn ->
        SymphonyElixir.WorkspaceHookRunner.await_startup_cleanup_for_test(
          live,
          observer,
          "after_create"
        )
      end)

    send(live_waiter, :unrelated_message)
    send(live_waiter, {:cleanup_guardian_verified, live_pid})

    assert_receive {
                     :hook_cleanup_observer,
                     {:workspace_hook_runner_stopped, ^live_waiter, {:error, {:workspace_hook_cleanup_recovered, "after_create"}}}
                   },
                   1_000

    send(live_pid, :stop)

    active_status = :atomics.new(1, [])
    :ok = :atomics.put(active_status, 1, 0)
    lost_pid = spawn(fn -> :ok end)
    lost_ref = Process.monitor(lost_pid)
    assert_receive {:DOWN, ^lost_ref, :process, ^lost_pid, :normal}, 1_000
    lost = %CleanupGuardian.Handle{pid: lost_pid, status: active_status}

    holder =
      spawn(fn ->
        SymphonyElixir.WorkspaceHookRunner.await_startup_cleanup_for_test(
          lost,
          observer,
          "before_run"
        )
      end)

    Process.sleep(100)
    assert Process.alive?(holder)
    send(holder, :unrelated_message)
    Process.sleep(10)
    assert Process.alive?(holder)
    Process.exit(holder, :kill)
  end

  test "hook runner uses its safe PATH fallback and rejects invalid startup inputs" do
    test_root = unique_root("hook-runner-inputs")
    workspace = Path.join(test_root, "workspace")
    missing_workspace = Path.join(test_root, "missing")
    previous_path = System.get_env("PATH")

    File.mkdir_p!(workspace)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      File.rm_rf(test_root)
    end)

    System.delete_env("PATH")

    assert :ok =
             SymphonyElixir.WorkspaceHookRunner.run(
               "test \"$PATH\" = /usr/local/bin:/usr/bin:/bin",
               workspace,
               "path_fallback",
               2_000
             )

    assert {:error, {:workspace_hook_invalid_output_limit, "invalid_limit"}} =
             SymphonyElixir.WorkspaceHookRunner.run(
               "exit 0",
               workspace,
               "invalid_limit",
               1_000,
               output_limit_bytes: 0
             )

    assert {:error, {:workspace_hook_start_failed, "missing_workspace"}} =
             SymphonyElixir.WorkspaceHookRunner.run(
               "exit 0",
               missing_workspace,
               "missing_workspace",
               1_000
             )
  end

  test "hook runner fails closed when the runtime cleanup barrier is unavailable" do
    barrier_name = SymphonyElixir.CleanupBarrier
    barrier = Process.whereis(barrier_name)
    assert is_pid(barrier)
    assert true = Process.unregister(barrier_name)

    on_exit(fn -> restore_registered_process(barrier_name, barrier) end)
    previous_trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:workspace_hook_runner_failed, "barrier_unavailable"}} =
               SymphonyElixir.WorkspaceHookRunner.run(
                 "exit 0",
                 System.tmp_dir!(),
                 "barrier_unavailable",
                 1_000
               )
    after
      Process.flag(:trap_exit, previous_trap_exit)
      restore_registered_process(barrier_name, barrier)
    end
  end

  test "hook runner maps task-supervisor errors and exits to a closed failure" do
    supervisor_name = SymphonyElixir.WorkspaceHookSupervisor
    runtime_supervisor = Process.whereis(supervisor_name)
    assert is_pid(runtime_supervisor)
    assert true = Process.unregister(supervisor_name)

    on_exit(fn -> restore_registered_process(supervisor_name, runtime_supervisor) end)

    assert {:ok, limited_supervisor} =
             Task.Supervisor.start_link(name: supervisor_name, max_children: 0)

    assert {:error, {:workspace_hook_supervisor_unavailable, "capacity"}} =
             SymphonyElixir.WorkspaceHookRunner.run(
               "exit 0",
               System.tmp_dir!(),
               "capacity",
               1_000
             )

    :ok = Supervisor.stop(limited_supervisor)

    rogue_supervisor =
      spawn(fn ->
        receive do
          _message -> exit(:injected_supervisor_exit)
        end
      end)

    assert true = Process.register(rogue_supervisor, supervisor_name)

    assert {:error, {:workspace_hook_supervisor_unavailable, "supervisor_exit"}} =
             SymphonyElixir.WorkspaceHookRunner.run(
               "exit 0",
               System.tmp_dir!(),
               "supervisor_exit",
               1_000
             )

    restore_registered_process(supervisor_name, runtime_supervisor)
  end

  test "cancellation during after_create waits for hook containment before after_run" do
    assert_cancelled_hook_containment!(:after_create)
  end

  test "cancellation during before_run waits for hook containment before after_run" do
    assert_cancelled_hook_containment!(:before_run)
  end

  test "an orchestrator crash cannot replace runtime children around a worker-owned hook" do
    test_root = unique_root("runtime-worker-hook")
    workspace_root = Path.join(test_root, "workspaces")
    local_pid_path = Path.join(test_root, "hook.local-pid")
    namespace_path = Path.join(test_root, "hook.namespace")
    ready_path = Path.join(test_root, "hook.ready")
    issue = issue("issue-runtime-worker-hook", "MT-RUNTIME-WORKER-HOOK")
    expected_workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(test_root)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_run: resistant_hook(local_pid_path, namespace_path, ready_path),
      hook_timeout_ms: 1_000
    )

    recipient = self()
    assert {:ok, controller} = AgentRunner.start_supervised(issue, recipient)

    on_exit(fn ->
      terminate_controller_if_alive(controller)
      File.rm_rf(test_root)
    end)

    assert_receive {:worker_runtime_info, issue_id,
                    %{
                      workspace_path: ^expected_workspace,
                      workspace_root: ^workspace_root
                    }},
                   5_000

    assert issue_id == issue.id
    assert wait_for_path(ready_path, 3_000)

    worker = await_linked_worker(controller, 1_000)
    hook_runner = await_hook_runner(worker, 1_000)
    assert_barrier_member!(controller)
    assert_barrier_member!(hook_runner)
    hook_runner_ref = Process.monitor(hook_runner)
    identity = await_target_identity(local_pid_path, namespace_path, 1_000)
    runtime = runtime_snapshot!()

    assert process_identity_alive?(identity)
    assert process_ignores_term?(identity)
    assert true == :erlang.suspend_process(hook_runner)
    assert {:status, :suspended} = Process.info(hook_runner, :status)

    on_exit(fn ->
      resume_process_if_alive(hook_runner)
      force_retire_identity(identity)
    end)

    Process.exit(runtime.children[SymphonyElixir.Orchestrator], :kill)

    assert process_identity_alive?(identity)
    assert_runtime_barrier!(runtime, 100)

    resume_process_if_alive(hook_runner)

    await_hook_containment_before_replacement!(identity, hook_runner, runtime, 5_000)
    assert_receive {:DOWN, ^hook_runner_ref, :process, ^hook_runner, _reason}, 1_000

    refute process_identity_alive?(identity)
    assert Process.whereis(SymphonyElixir.RuntimeSupervisor) == runtime.parent

    Enum.each(runtime.children, fn {name, old_pid} ->
      replacement = await_registered_replacement(name, old_pid, 5_000)
      assert is_pid(replacement)
    end)
  end

  test "runtime restart proceeds only after a failed hook cleanup later recovers" do
    test_root = unique_root("runtime-hook-cleanup-recovery")
    workspace_root = Path.join(test_root, "workspaces")
    issue = issue("issue-runtime-hook-recovery", "MT-RUNTIME-HOOK-RECOVERY")

    previous_test_pid =
      Application.get_env(:symphony_elixir, :recovering_hook_runner_test_pid)

    Application.put_env(
      :symphony_elixir,
      :recovering_hook_runner_test_pid,
      self()
    )

    on_exit(fn ->
      restore_application_env(
        :recovering_hook_runner_test_pid,
        previous_test_pid
      )

      File.rm_rf(test_root)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      hook_before_run: "injected",
      hook_timeout_ms: 100
    )

    recipient = self()

    assert {:ok, controller} =
             AgentRunner.start_supervised(issue, recipient, workspace_hook_runner: RecoveringHookRunner)

    on_exit(fn -> terminate_controller_if_alive(controller) end)
    controller_ref = Process.monitor(controller)

    assert_receive {:worker_runtime_info, issue_id,
                    %{
                      workspace_root: ^workspace_root
                    }},
                   5_000

    assert issue_id == issue.id
    assert_receive {:recovering_hook_runner_ready, runner}, 1_000
    runner_ref = Process.monitor(runner)
    runtime = runtime_snapshot!()

    Process.exit(runtime.children[SymphonyElixir.Orchestrator], :kill)

    assert_receive {:recovering_hook_cleanup_failed, ^runner}, 5_000
    assert Process.alive?(runner)
    assert Process.alive?(controller)
    assert_runtime_barrier!(runtime, 5_300)
    refute_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 0

    send(runner, :recover_cleanup)

    assert_receive {:recovering_hook_cleanup_recovered, ^runner}, 1_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}, 1_000
    assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 5_000

    Enum.each(runtime.children, fn {name, old_pid} ->
      replacement = await_registered_replacement(name, old_pid, 5_000)
      assert is_pid(replacement)
    end)
  end

  defp assert_cancelled_hook_containment!(hook_phase) do
    test_root = unique_root("cancel-#{hook_phase}")
    workspace_root = Path.join(test_root, "workspaces")
    local_pid_path = Path.join(test_root, "hook.local-pid")
    namespace_path = Path.join(test_root, "hook.namespace")
    ready_path = Path.join(test_root, "hook.ready")
    host_identity_path = Path.join(test_root, "hook.host-identity")
    after_run_result_path = Path.join(test_root, "after-run.result")
    issue = issue("issue-cancel-#{hook_phase}", "MT-CANCEL-#{hook_phase}")
    expected_workspace = Path.join(workspace_root, issue.identifier)

    File.mkdir_p!(test_root)

    hook_key = String.to_existing_atom("hook_#{hook_phase}")

    workflow_overrides =
      [
        workspace_root: workspace_root,
        hook_after_run: retirement_probe(host_identity_path, after_run_result_path),
        hook_timeout_ms: 1_000
      ]
      |> Keyword.put(hook_key, resistant_hook(local_pid_path, namespace_path, ready_path))

    write_workflow_file!(Workflow.workflow_file_path(), workflow_overrides)

    recipient = self()
    assert {:ok, controller} = AgentRunner.start_supervised(issue, recipient)

    on_exit(fn ->
      terminate_controller_if_alive(controller)
      File.rm_rf(test_root)
    end)

    assert_receive {:worker_runtime_info, issue_id,
                    %{
                      workspace_path: ^expected_workspace,
                      workspace_root: ^workspace_root
                    }},
                   5_000

    assert issue_id == issue.id
    assert wait_for_path(ready_path, 3_000)

    worker = await_linked_worker(controller, 1_000)
    hook_runner = await_hook_runner(worker, 1_000)
    hook_runner_ref = Process.monitor(hook_runner)
    worker_ref = Process.monitor(worker)
    identity = await_target_identity(local_pid_path, namespace_path, 1_000)
    File.write!(host_identity_path, "#{identity.pid} #{identity.start_time}\n")

    assert process_identity_alive?(identity)
    assert process_ignores_term?(identity)
    assert true == :erlang.suspend_process(hook_runner)
    assert {:status, :suspended} = Process.info(hook_runner, :status)

    on_exit(fn ->
      resume_process_if_alive(hook_runner)
      force_retire_identity(identity)
    end)

    cancel_ref = make_ref()
    test_process = self()

    canceller =
      spawn(fn ->
        result = AgentRunner.cancel(controller, 15_000)
        send(test_process, {cancel_ref, result})
      end)

    on_exit(fn ->
      if Process.alive?(canceller), do: Process.exit(canceller, :kill)
    end)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 7_000
    refute_receive {^cancel_ref, _result}, 0
    refute File.exists?(after_run_result_path)
    assert process_identity_alive?(identity)

    resume_process_if_alive(hook_runner)

    assert_receive {^cancel_ref,
                    {:ok,
                     %{
                       workspace_path: ^expected_workspace,
                       workspace_root: ^workspace_root
                     }}},
                   10_000

    assert_receive {:DOWN, ^hook_runner_ref, :process, ^hook_runner, _reason}, 1_000
    await_process_down(controller, 3_000)

    refute process_identity_alive?(identity)
    assert File.read!(after_run_result_path) == "descendant_retired\n"
  end

  defp resistant_hook(local_pid_path, namespace_path, ready_path) do
    "trap '' TERM; " <>
      "printf '%s\\n' \"$$\" > '#{local_pid_path}'; " <>
      "readlink /proc/self/ns/pid > '#{namespace_path}'; " <>
      "printf ready > '#{ready_path}'; " <>
      "while :; do sleep 1; done"
  end

  defp retirement_probe(identity_path, result_path) do
    "read pid original_start < '#{identity_path}'; " <>
      "state=$(awk '{print $3}' /proc/$pid/stat 2>/dev/null || true); " <>
      "current_start=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null || true); " <>
      ~s|if [ -n "$state" ] && [ "$state" != Z ] && [ "$current_start" = "$original_start" ]; | <>
      "then printf '%s\\n' descendant_alive; else printf '%s\\n' descendant_retired; fi > '#{result_path}'"
  end

  defp await_linked_worker(controller, timeout_ms) do
    excluded = MapSet.new([Process.whereis(SymphonyElixir.TaskSupervisor)])
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_linked_worker(controller, excluded, deadline_ms)
  end

  defp do_await_linked_worker(controller, excluded, deadline_ms) do
    candidates =
      case Process.info(controller, :links) do
        {:links, links} ->
          Enum.filter(links, fn pid ->
            is_pid(pid) and Process.alive?(pid) and not MapSet.member?(excluded, pid)
          end)

        nil ->
          []
      end

    case candidates do
      [worker] ->
        worker

      other ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(10)
          do_await_linked_worker(controller, excluded, deadline_ms)
        else
          flunk("expected one linked worker, got: #{inspect(other)}")
        end
    end
  end

  defp await_hook_runner(worker, timeout_ms) do
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_hook_runner(worker, deadline_ms)
  end

  defp do_await_hook_runner(worker, deadline_ms) do
    runners =
      SymphonyElixir.WorkspaceHookSupervisor
      |> Task.Supervisor.children()
      |> Enum.filter(fn runner ->
        case Process.info(runner, :links) do
          {:links, links} -> worker in links
          nil -> false
        end
      end)

    case runners do
      [runner] ->
        runner

      other ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(10)
          do_await_hook_runner(worker, deadline_ms)
        else
          flunk("expected one worker-owned hook runner, got: #{inspect(other)}")
        end
    end
  end

  defp await_target_identity(local_pid_path, namespace_path, timeout_ms) do
    local_pid = local_pid_path |> File.read!() |> String.trim() |> String.to_integer()
    namespace = namespace_path |> File.read!() |> String.trim()
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_target_identity(local_pid, namespace, deadline_ms)
  end

  defp do_await_target_identity(local_pid, namespace, deadline_ms) do
    identity =
      "/proc/[0-9]*/status"
      |> Path.wildcard()
      |> Enum.find_value(&target_identity(&1, local_pid, namespace))

    cond do
      is_map(identity) ->
        identity

      monotonic_ms() < deadline_ms ->
        Process.sleep(10)
        do_await_target_identity(local_pid, namespace, deadline_ms)

      true ->
        flunk("hook target identity was not discoverable before the deadline")
    end
  end

  defp target_identity(status_path, local_pid, namespace) do
    host_pid = status_path |> Path.dirname() |> Path.basename() |> String.to_integer()

    with {:ok, ^namespace} <- File.read_link("/proc/#{host_pid}/ns/pid"),
         {:ok, status} <- File.read(status_path),
         true <- namespace_pid(status) == local_pid,
         {:ok, start_time} <- process_start_time(host_pid) do
      %{pid: host_pid, start_time: start_time}
    else
      _not_target -> nil
    end
  end

  defp namespace_pid(status) do
    status
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "NSpid:"))
    |> case do
      nil -> nil
      line -> line |> String.replace_prefix("NSpid:", "") |> String.split() |> List.last() |> String.to_integer()
    end
  end

  defp process_start_time(pid) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         start_time when is_binary(start_time) <- stat |> String.split() |> Enum.at(21),
         {start_time, ""} <- Integer.parse(start_time) do
      {:ok, start_time}
    else
      _error -> {:error, :process_identity_unavailable}
    end
  end

  defp process_identity_alive?(%{pid: pid, start_time: expected_start_time}) do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         fields <- String.split(stat),
         state when state != "Z" <- Enum.at(fields, 2),
         start_time when is_binary(start_time) <- Enum.at(fields, 21),
         {start_time, ""} <- Integer.parse(start_time) do
      start_time == expected_start_time
    else
      _error -> false
    end
  end

  defp process_ignores_term?(%{pid: pid} = identity) do
    with true <- process_identity_alive?(identity),
         {:ok, status} <- File.read("/proc/#{pid}/status"),
         line when is_binary(line) <- Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "SigIgn:")),
         mask <- line |> String.replace_prefix("SigIgn:", "") |> String.trim() |> String.to_integer(16) do
      Bitwise.band(mask, 16_384) == 16_384
    else
      _error -> false
    end
  end

  defp runtime_snapshot! do
    parent = Process.whereis(SymphonyElixir.RuntimeSupervisor)
    assert is_pid(parent)

    children =
      Map.new(@runtime_children, fn name ->
        pid = Process.whereis(name)
        assert is_pid(pid)
        {name, pid}
      end)

    %{parent: parent, children: children}
  end

  defp assert_barrier_member!(member, attempts \\ 100)

  defp assert_barrier_member!(_member, 0),
    do: flunk("runtime member was not registered in the cleanup barrier")

  defp assert_barrier_member!(member, attempts) do
    if Map.has_key?(:sys.get_state(SymphonyElixir.CleanupBarrier), member) do
      :ok
    else
      Process.sleep(10)
      assert_barrier_member!(member, attempts - 1)
    end
  end

  defp assert_runtime_barrier!(runtime, duration_ms) do
    deadline_ms = monotonic_ms() + duration_ms
    do_assert_runtime_barrier!(runtime, deadline_ms)
  end

  defp do_assert_runtime_barrier!(runtime, deadline_ms) do
    assert_runtime_not_replaced!(runtime)

    if monotonic_ms() < deadline_ms do
      Process.sleep(10)
      do_assert_runtime_barrier!(runtime, deadline_ms)
    else
      :ok
    end
  end

  defp await_hook_containment_before_replacement!(identity, runner, runtime, timeout_ms) do
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_hook_containment_before_replacement!(identity, runner, runtime, deadline_ms)
  end

  defp do_await_hook_containment_before_replacement!(identity, runner, runtime, deadline_ms) do
    if process_identity_alive?(identity) or Process.alive?(runner) do
      assert_runtime_not_replaced!(runtime)

      if monotonic_ms() < deadline_ms do
        Process.sleep(10)
        do_await_hook_containment_before_replacement!(identity, runner, runtime, deadline_ms)
      else
        flunk("runtime hook containment did not retire before the deadline")
      end
    else
      :ok
    end
  end

  defp assert_runtime_not_replaced!(runtime) do
    assert Process.whereis(SymphonyElixir.RuntimeSupervisor) == runtime.parent

    Enum.each(runtime.children, fn {name, old_pid} ->
      case Process.whereis(name) do
        pid when is_nil(pid) or pid == old_pid -> :ok
        _replacement -> flunk("#{inspect(name)} was replaced before hook containment retired")
      end
    end)
  end

  defp await_registered_replacement(name, old_pid, timeout_ms) do
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_registered_replacement(name, old_pid, deadline_ms)
  end

  defp do_await_registered_replacement(name, old_pid, deadline_ms) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _timed_out ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(10)
          do_await_registered_replacement(name, old_pid, deadline_ms)
        else
          flunk("#{inspect(name)} was not replaced before the deadline")
        end
    end
  end

  defp await_process_down(pid, timeout_ms) do
    monitor_ref = Process.monitor(pid)

    receive do
      {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
    after
      timeout_ms -> flunk("process did not retire before the deadline")
    end
  end

  defp wait_for_path(path, timeout_ms) do
    deadline_ms = monotonic_ms() + timeout_ms
    do_wait_for_path(path, deadline_ms)
  end

  defp do_wait_for_path(path, deadline_ms) do
    cond do
      File.exists?(path) ->
        true

      monotonic_ms() >= deadline_ms ->
        false

      true ->
        Process.sleep(10)
        do_wait_for_path(path, deadline_ms)
    end
  end

  defp resume_process_if_alive(pid) do
    case Process.info(pid, :status) do
      {:status, :suspended} ->
        :erlang.resume_process(pid)
        :ok

      _not_suspended_or_dead ->
        :ok
    end
  end

  defp terminate_controller_if_alive(controller) do
    if Process.alive?(controller) do
      try do
        case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, controller) do
          :ok -> :ok
          {:error, :not_found} -> Process.exit(controller, :kill)
        end
      catch
        :exit, _reason -> Process.exit(controller, :kill)
      end
    end

    :ok
  end

  defp force_retire_identity(identity) do
    if process_identity_alive?(identity) do
      _result = System.cmd("/bin/kill", ["-KILL", Integer.to_string(identity.pid)], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp restore_application_env(key, nil),
    do: Application.delete_env(:symphony_elixir, key)

  defp restore_application_env(key, value),
    do: Application.put_env(:symphony_elixir, key, value)

  defp restore_registered_process(name, process) do
    case Process.whereis(name) do
      ^process ->
        :ok

      current when is_pid(current) ->
        Process.unregister(name)
        restore_registered_process(name, process)

      nil ->
        if Process.alive?(process), do: Process.register(process, name)
        :ok
    end
  end

  defp issue(id, identifier) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Hook cancellation containment",
      description: "Prove local hooks retire before lifecycle progress",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: []
    }
  end

  defp unique_root(suffix) do
    Path.join(
      System.tmp_dir!(),
      "symphony-hook-containment-#{suffix}-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
