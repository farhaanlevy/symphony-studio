# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.RuntimeSupervisorTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{CleanupBarrier, CleanupGuardian, Connection, TransportError}

  @runtime_children [
    SymphonyElixir.CleanupBarrier,
    SymphonyElixir.CleanupSupervisor,
    SymphonyElixir.ConnectionSupervisor,
    SymphonyElixir.WorkspaceHookSupervisor,
    SymphonyElixir.TaskSupervisor,
    SymphonyElixir.Orchestrator
  ]

  defmodule HeldCleanupAdapter do
    @moduledoc false

    def stop(%{allow_stop: allow_stop, test_pid: test_pid}, _timeout_ms) do
      allowed? = Agent.get(allow_stop, & &1)
      send(test_pid, {:runtime_guardian_cleanup_attempt, self(), allowed?})
      if allowed?, do: :ok, else: {:error, :cleanup_held}
    end
  end

  defmodule DirectConnectionAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      child = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: child}}
    end

    def stop(%{pid: child}, _timeout_ms) do
      Process.unlink(child)
      Process.exit(child, :kill)
      :ok
    end
  end

  defmodule HeldGuardianStartAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      %{allow_stop: allow_stop, test_pid: test_pid} =
        Application.fetch_env!(:symphony_elixir, :held_guardian_start_control)

      child = spawn_link(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:guardian_start_adapter_ready, self(), child})

      receive do
        :release_guardian_start -> :ok
      end

      {:ok, %{allow_stop: allow_stop, pid: child, test_pid: test_pid}}
    end

    def stop(adapter, _timeout_ms) do
      allowed? = Agent.get(adapter.allow_stop, & &1)
      send(adapter.test_pid, {:guardian_start_cleanup_attempt, self(), allowed?})

      if allowed? do
        if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)
        :ok
      else
        {:error, :cleanup_held}
      end
    end
  end

  defmodule BarrierRegistrationRaceAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      %{counter: counter, test_pid: test_pid} =
        Application.fetch_env!(:symphony_elixir, :barrier_registration_race_control)

      child = spawn_link(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:barrier_registration_start_ready, self(), child})

      receive do
        :release_barrier_registration_start -> :ok
      end

      {:ok, %{child: child, counter: counter, test_pid: test_pid}}
    end

    def stop(adapter, _timeout_ms) do
      {active, max_seen} =
        Agent.get_and_update(adapter.counter, fn state ->
          active = state.active + 1
          max_seen = max(state.max_seen, active)

          {{active, max_seen},
           %{
             state
             | active: active,
               callers: MapSet.put(state.callers, self()),
               max_seen: max_seen
           }}
        end)

      send(
        adapter.test_pid,
        {:barrier_registration_stop_entered, self(), active, max_seen}
      )

      try do
        receive do
          {:release_barrier_registration_stop, result} ->
            if result == :ok and Process.alive?(adapter.child) do
              Process.unlink(adapter.child)
              Process.exit(adapter.child, :kill)
            end

            result
        end
      after
        Agent.update(adapter.counter, fn state ->
          %{
            state
            | active: state.active - 1,
              callers: MapSet.delete(state.callers, self())
          }
        end)
      end
    end
  end

  defmodule SupervisorCrashAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      %{counter: counter, test_pid: test_pid} =
        Application.fetch_env!(:symphony_elixir, :supervisor_crash_adapter_control)

      child = spawn_link(fn -> Process.sleep(:infinity) end)

      adapter = %{
        counter: counter,
        os_pid: System.unique_integer([:positive]),
        pid: child,
        test_pid: test_pid
      }

      Kernel.send(test_pid, {:supervisor_crash_adapter_started, adapter})
      {:ok, adapter}
    end

    def send(_adapter, _data), do: :ok
    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      {active, max_seen} =
        Agent.get_and_update(adapter.counter, fn state ->
          active = state.active + 1
          max_seen = max(state.max_seen, active)

          {{active, max_seen},
           %{
             state
             | active: active,
               callers: MapSet.put(state.callers, self()),
               max_seen: max_seen
           }}
        end)

      Kernel.send(
        adapter.test_pid,
        {:supervisor_crash_stop_entered, self(), active, max_seen}
      )

      try do
        receive do
          {:release_supervisor_crash_stop, result} ->
            if result == :ok and Process.alive?(adapter.pid) do
              Process.unlink(adapter.pid)
              Process.exit(adapter.pid, :kill)
            end

            result
        end
      after
        Agent.update(adapter.counter, fn state ->
          %{
            state
            | active: state.active - 1,
              callers: MapSet.delete(state.callers, self())
          }
        end)
      end
    end
  end

  test "runtime and member-barrier entry points report existing or unavailable owners" do
    runtime = Process.whereis(SymphonyElixir.RuntimeSupervisor)
    barrier = Process.whereis(SymphonyElixir.CleanupBarrier)

    assert is_pid(runtime)
    assert is_pid(barrier)

    assert {:error, {:already_started, ^runtime}} =
             SymphonyElixir.RuntimeSupervisor.start_link()

    assert Process.unregister(SymphonyElixir.CleanupBarrier)

    try do
      assert {:error, :barrier_unavailable} = CleanupBarrier.register_member(self())
    after
      if is_nil(Process.whereis(SymphonyElixir.CleanupBarrier)) and Process.alive?(barrier) do
        Process.register(barrier, SymphonyElixir.CleanupBarrier)
      end
    end

    assert Process.whereis(SymphonyElixir.CleanupBarrier) == barrier
  end

  test "cleanup barrier callbacks cover duplicate, dead, verified, and unknown entries" do
    live_cleanup = spawn(fn -> Process.sleep(:infinity) end)
    active_status = :atomics.new(1, [])
    verified_status = :atomics.new(1, [])
    :ok = :atomics.put(active_status, 1, 0)
    :ok = :atomics.put(verified_status, 1, 1)

    verified_handle = %CleanupGuardian.Handle{pid: live_cleanup, status: verified_status}
    active_handle = %CleanupGuardian.Handle{pid: live_cleanup, status: active_status}

    assert {:reply, :ok, %{}} =
             CleanupBarrier.handle_call({:register, verified_handle}, {self(), make_ref()}, %{})

    assert {:reply, :ok, cleanup_state} =
             CleanupBarrier.handle_call({:register, active_handle}, {self(), make_ref()}, %{})

    assert %{^live_cleanup => %{kind: :cleanup, ref: cleanup_ref}} = cleanup_state

    assert {:reply, :ok, ^cleanup_state} =
             CleanupBarrier.handle_call(
               {:register, active_handle},
               {self(), make_ref()},
               cleanup_state
             )

    unknown_ref = make_ref()

    assert {:noreply, ^cleanup_state} =
             CleanupBarrier.handle_info(
               {:DOWN, unknown_ref, :process, self(), :normal},
               cleanup_state
             )

    :ok = :atomics.put(active_status, 1, 1)
    assert {:noreply, %{}} = CleanupBarrier.handle_info(:poll_cleanup_barrier, cleanup_state)
    Process.demonitor(cleanup_ref, [:flush])
    Process.exit(live_cleanup, :kill)

    live_member = spawn(fn -> Process.sleep(:infinity) end)

    assert {:reply, :ok, member_state} =
             CleanupBarrier.handle_call(
               {:register_member, live_member},
               {self(), make_ref()},
               %{}
             )

    assert %{^live_member => %{kind: :member, ref: member_ref}} = member_state

    assert {:reply, :ok, ^member_state} =
             CleanupBarrier.handle_call(
               {:register_member, live_member},
               {self(), make_ref()},
               member_state
             )

    Process.demonitor(member_ref, [:flush])
    Process.exit(live_member, :kill)

    dead_member = spawn(fn -> :ok end)
    dead_ref = Process.monitor(dead_member)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_member, :normal}, 1_000

    assert {:reply, :ok, %{}} =
             CleanupBarrier.handle_call(
               {:register_member, dead_member},
               {self(), make_ref()},
               %{}
             )

    stale_ref = Process.monitor(dead_member)
    stale_state = %{dead_member => %{kind: :member, ref: stale_ref}}
    assert {:noreply, %{}} = CleanupBarrier.handle_info(:poll_cleanup_barrier, stale_state)
    Process.demonitor(stale_ref, [:flush])
  end

  test "cleanup barrier termination ignores unrelated DOWN messages while awaiting a member" do
    member = spawn(fn -> Process.sleep(:infinity) end)
    member_ref = Process.monitor(member)
    state = %{member => %{kind: :member, ref: member_ref}}

    send(self(), {:DOWN, make_ref(), :process, self(), :normal})

    spawn(fn ->
      Process.sleep(25)
      Process.exit(member, :kill)
    end)

    assert :ok = CleanupBarrier.terminate(:shutdown, state)
    Process.demonitor(member_ref, [:flush])
  end

  test "guardian creation fails closed inside Connection when CleanupSupervisor is lost" do
    {:ok, allow_stop} = Agent.start(fn -> false end)
    previous_control = Application.get_env(:symphony_elixir, :held_guardian_start_control)

    Application.put_env(:symphony_elixir, :held_guardian_start_control, %{
      allow_stop: allow_stop,
      test_pid: self()
    })

    on_exit(fn ->
      if Process.alive?(allow_stop), do: Agent.update(allow_stop, fn _blocked -> true end)

      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :held_guardian_start_control)
      else
        Application.put_env(:symphony_elixir, :held_guardian_start_control, previous_control)
      end
    end)

    connection_task =
      Task.async(fn ->
        Connection.start(["/bin/true"],
          kill_timeout_ms: 0,
          process_adapter: HeldGuardianStartAdapter
        )
      end)

    assert_receive {:guardian_start_adapter_ready, connection_process, child}, 1_000
    runtime = runtime_snapshot()
    old_cleanup_supervisor = Map.fetch!(runtime.children, SymphonyElixir.CleanupSupervisor)
    cleanup_supervisor_ref = Process.monitor(old_cleanup_supervisor)

    Process.exit(old_cleanup_supervisor, :kill)
    assert_receive {:DOWN, ^cleanup_supervisor_ref, :process, ^old_cleanup_supervisor, :killed}, 3_000
    send(connection_process, :release_guardian_start)

    assert_receive {:guardian_start_cleanup_attempt, _worker, false}, 3_000
    assert_runtime_unchanged(runtime, 750)
    assert Process.alive?(child)

    Agent.update(allow_stop, fn _blocked -> true end)

    assert {:error,
            %TransportError{
              kind: :process_start_failed,
              details: %{
                cleanup_verified: true,
                reason: :cleanup_runtime_unavailable
              }
            }} = Task.await(connection_task, 3_000)

    refute Process.alive?(child)

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "barrier loss during guardian registration keeps one cleanup caller" do
    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    previous_control =
      Application.get_env(:symphony_elixir, :barrier_registration_race_control)

    Application.put_env(:symphony_elixir, :barrier_registration_race_control, %{
      counter: counter,
      test_pid: self()
    })

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_barrier_registration_stop, :ok}))
      end

      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :barrier_registration_race_control)
      else
        Application.put_env(
          :symphony_elixir,
          :barrier_registration_race_control,
          previous_control
        )
      end
    end)

    connection_task =
      Task.async(fn ->
        Connection.start(["/bin/true"],
          kill_timeout_ms: 0,
          process_adapter: BarrierRegistrationRaceAdapter
        )
      end)

    assert_receive {:barrier_registration_start_ready, connection_process, child}, 1_000

    runtime = runtime_snapshot()
    old_cleanup_barrier = Map.fetch!(runtime.children, SymphonyElixir.CleanupBarrier)
    cleanup_barrier_ref = Process.monitor(old_cleanup_barrier)
    Process.exit(old_cleanup_barrier, :kill)
    assert_receive {:DOWN, ^cleanup_barrier_ref, :process, ^old_cleanup_barrier, :killed}, 1_000

    send(connection_process, :release_barrier_registration_start)

    assert_receive {:barrier_registration_stop_entered, cleanup_caller, 1, 1}, 1_000
    refute_receive {:barrier_registration_stop_entered, _second_caller, _active, _max_seen}, 750

    assert %{active: 1, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
    assert_runtime_unchanged(runtime, 250)
    assert Process.alive?(child)

    child_ref = Process.monitor(child)
    send(cleanup_caller, {:release_barrier_registration_stop, :ok})
    connection_result = Task.await(connection_task, 3_000)

    assert match?({:ok, _connection}, connection_result) or
             match?({:error, _reason}, connection_result)

    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 1_000
    assert %{active: 0, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "ambiguous guardian start adopts its ready child without inline overlap" do
    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    child = spawn(fn -> Process.sleep(:infinity) end)
    test_pid = self()

    adapter = %{child: child, counter: counter, test_pid: test_pid}

    ambiguous_starter = fn guardian_fun ->
      guardian = spawn(guardian_fun)
      send(guardian, {:EXIT, self(), :ambiguous_supervisor_start})
      {:error, :ambiguous_supervisor_start}
    end

    owner_task =
      Task.async(fn ->
        try do
          handle =
            CleanupGuardian.start_handle_with_starter_for_test(
              self(),
              BarrierRegistrationRaceAdapter,
              adapter,
              0,
              ambiguous_starter
            )

          send(test_pid, {:ambiguous_guardian_adopted, handle})

          receive do
            :release_ambiguous_guardian_owner -> :ok
          end
        rescue
          _error -> BarrierRegistrationRaceAdapter.stop(adapter, 0)
        end
      end)

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_barrier_registration_stop, :ok}))
      end

      if Process.alive?(owner_task.pid), do: Process.exit(owner_task.pid, :kill)
      if Process.alive?(child), do: Process.exit(child, :kill)
    end)

    assert_receive {:ambiguous_guardian_adopted, %CleanupGuardian.Handle{} = handle}, 1_000
    guardian_ref = Process.monitor(handle.pid)
    child_ref = Process.monitor(child)

    assert_receive {:barrier_registration_stop_entered, cleanup_caller, 1, 1}, 1_000
    refute_receive {:barrier_registration_stop_entered, _second_caller, _active, _max_seen}, 750

    assert %{active: 1, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))

    send(cleanup_caller, {:release_barrier_registration_stop, :ok})

    assert_receive {:DOWN, ^child_ref, :process, ^child, _reason}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
    assert guardian == handle.pid
    assert CleanupGuardian.verified?(handle)

    send(owner_task.pid, :release_ambiguous_guardian_owner)
    assert :ok = Task.await(owner_task, 1_000)
    assert %{active: 0, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
  end

  test "ambiguous guardian start without acknowledgement holds before inline cleanup" do
    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    child = spawn(fn -> Process.sleep(:infinity) end)
    test_pid = self()
    adapter = %{child: child, counter: counter, test_pid: test_pid}
    runtime = runtime_snapshot()

    owner_task =
      Task.async(fn ->
        try do
          CleanupGuardian.start_handle_with_starter_for_test(
            self(),
            BarrierRegistrationRaceAdapter,
            adapter,
            0,
            fn _guardian_fun -> {:error, :ambiguous_without_child} end
          )
        rescue
          _error -> BarrierRegistrationRaceAdapter.stop(adapter, 0)
        end
      end)

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_barrier_registration_stop, :ok}))
      end

      if Process.alive?(owner_task.pid), do: Process.exit(owner_task.pid, :kill)
      if Process.alive?(child), do: Process.exit(child, :kill)
    end)

    Process.sleep(1_300)

    assert Task.yield(owner_task, 0) == nil
    refute_receive {:barrier_registration_stop_entered, _caller, _active, _max_seen}, 100
    assert %{active: 0, max_seen: 0} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
    assert_runtime_unchanged(runtime, 100)

    assert nil == Task.shutdown(owner_task, :brutal_kill)
    assert Process.alive?(child)
  end

  test "lost runtime barriers await acknowledged cleanup before returning inline authority" do
    runtime = runtime_snapshot()

    unavailable_registrations = [
      {SymphonyElixir.CleanupBarrier, Map.fetch!(runtime.children, SymphonyElixir.CleanupBarrier)},
      {SymphonyElixir.CleanupSupervisor, Map.fetch!(runtime.children, SymphonyElixir.CleanupSupervisor)}
    ]

    Enum.each(unavailable_registrations, fn {name, _pid} ->
      assert Process.unregister(name)
    end)

    restore_registrations = fn ->
      Enum.each(unavailable_registrations, fn {name, pid} ->
        if Process.alive?(pid) and is_nil(Process.whereis(name)) do
          Process.register(pid, name)
        end
      end)
    end

    on_exit(restore_registrations)

    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    child = spawn(fn -> Process.sleep(:infinity) end)
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_barrier_registration_stop, :ok}))
      end

      if Process.alive?(child), do: Process.exit(child, :kill)
    end)

    # Connection startup and ProcessAdapter startup rollback both catch errors
    # from this shared start_handle boundary before considering inline cleanup.
    cleanup_task =
      Task.async(fn ->
        assert_raise RuntimeError, "runtime cleanup barrier unavailable", fn ->
          CleanupGuardian.start_handle_with_starter_for_test(
            self(),
            BarrierRegistrationRaceAdapter,
            %{child: child, counter: counter, test_pid: test_pid},
            0,
            fn guardian_fun -> {:ok, spawn(guardian_fun)} end
          )
        end
      end)

    assert_receive {:barrier_registration_stop_entered, cleanup_caller, 1, 1}, 1_000
    assert Task.yield(cleanup_task, 0) == nil
    refute_receive {:barrier_registration_stop_entered, _second_caller, _active, _max_seen}, 500

    assert %{active: 1, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))

    send(cleanup_caller, {:release_barrier_registration_stop, :ok})

    assert %RuntimeError{message: "runtime cleanup barrier unavailable"} =
             Task.await(cleanup_task, 3_000)

    refute Process.alive?(child)
    assert %{active: 0, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))

    restore_registrations.()

    Enum.each(unavailable_registrations, fn {name, pid} ->
      assert Process.whereis(name) == pid
    end)
  end

  test "Task and hook supervisor crashes wait for every trapped runtime member" do
    Enum.each(
      [SymphonyElixir.TaskSupervisor, SymphonyElixir.WorkspaceHookSupervisor],
      &assert_nested_supervisor_member_barrier/1
    )
  end

  test "ConnectionSupervisor crash keeps one stop caller and waits for its Connection" do
    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    previous_control =
      Application.get_env(:symphony_elixir, :supervisor_crash_adapter_control)

    Application.put_env(:symphony_elixir, :supervisor_crash_adapter_control, %{
      counter: counter,
      test_pid: self()
    })

    assert {:ok, connection} =
             Connection.start(["/bin/true"],
               kill_timeout_ms: 0,
               process_adapter: SupervisorCrashAdapter
             )

    assert_receive {:supervisor_crash_adapter_started, adapter}, 1_000
    assert Map.has_key?(:sys.get_state(SymphonyElixir.CleanupBarrier), connection)
    connection_ref = Process.monitor(connection)
    child_ref = Process.monitor(adapter.pid)

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_supervisor_crash_stop, :ok}))
      end

      if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)

      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :supervisor_crash_adapter_control)
      else
        Application.put_env(
          :symphony_elixir,
          :supervisor_crash_adapter_control,
          previous_control
        )
      end
    end)

    runtime = runtime_snapshot()

    old_connection_supervisor =
      Map.fetch!(runtime.children, SymphonyElixir.ConnectionSupervisor)

    Process.exit(old_connection_supervisor, :kill)

    assert_receive {:supervisor_crash_stop_entered, cleanup_caller, 1, 1}, 1_000
    refute_receive {:supervisor_crash_stop_entered, _second_caller, _active, _max_seen}, 750

    assert %{active: 1, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
    assert_runtime_unchanged(runtime, 250)
    assert Process.alive?(connection)
    assert Process.alive?(adapter.pid)

    send(cleanup_caller, {:release_supervisor_crash_stop, :ok})

    assert_receive {:DOWN, ^child_ref, :process, child, _reason}, 1_000
    assert child == adapter.pid
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000

    assert %{active: 0, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "a directly supervised Connection retires during a runtime restart" do
    assert {:ok, connection} =
             Connection.start(["/bin/true"], process_adapter: DirectConnectionAdapter)

    connection_ref = Process.monitor(connection)
    runtime = runtime_snapshot()
    old_orchestrator = Map.fetch!(runtime.children, SymphonyElixir.Orchestrator)
    Process.exit(old_orchestrator, :kill)

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "an unverified cleanup guardian blocks the complete runtime restart" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    handle =
      CleanupGuardian.start_handle(
        self(),
        HeldCleanupAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0
      )

    guardian_ref = Process.monitor(handle.pid)
    :ok = CleanupGuardian.request_cleanup(handle)
    assert_receive {:runtime_guardian_cleanup_attempt, _worker, false}, 1_000

    runtime = runtime_snapshot()
    old_orchestrator = Map.fetch!(runtime.children, SymphonyElixir.Orchestrator)
    Process.exit(old_orchestrator, :kill)

    assert_runtime_unchanged(runtime, 750)
    assert Process.alive?(handle.pid)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(handle.pid, :retry_cleanup)

    assert_receive {:runtime_guardian_cleanup_attempt, _worker, true}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
    assert guardian == handle.pid
    assert CleanupGuardian.verified?(handle)

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "the cleanup registry blocks restart after CleanupSupervisor crashes" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    handle =
      CleanupGuardian.start_handle(
        self(),
        HeldCleanupAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0
      )

    guardian_ref = Process.monitor(handle.pid)
    :ok = CleanupGuardian.request_cleanup(handle)
    assert_receive {:runtime_guardian_cleanup_attempt, _worker, false}, 1_000

    runtime = runtime_snapshot()
    old_cleanup_supervisor = Map.fetch!(runtime.children, SymphonyElixir.CleanupSupervisor)
    Process.exit(old_cleanup_supervisor, :kill)

    assert_runtime_unchanged(runtime, 750)
    assert Process.alive?(handle.pid)
    refute CleanupGuardian.verified?(handle)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(handle.pid, :retry_cleanup)

    assert_receive {:runtime_guardian_cleanup_attempt, _worker, true}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
    assert guardian == handle.pid
    assert CleanupGuardian.verified?(handle)

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "CleanupSupervisor blocks restart after the cleanup registry crashes" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    handle =
      CleanupGuardian.start_handle(
        self(),
        HeldCleanupAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0
      )

    guardian_ref = Process.monitor(handle.pid)
    :ok = CleanupGuardian.request_cleanup(handle)
    assert_receive {:runtime_guardian_cleanup_attempt, _worker, false}, 1_000

    runtime = runtime_snapshot()
    old_cleanup_barrier = Map.fetch!(runtime.children, SymphonyElixir.CleanupBarrier)
    Process.exit(old_cleanup_barrier, :kill)

    assert_runtime_unchanged(runtime, 750)
    assert Process.alive?(handle.pid)
    refute CleanupGuardian.verified?(handle)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(handle.pid, :retry_cleanup)

    assert_receive {:runtime_guardian_cleanup_attempt, _worker, true}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, guardian, :normal}, 1_000
    assert guardian == handle.pid
    assert CleanupGuardian.verified?(handle)

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "an orchestrator crash retires an active App Server before the runtime restarts" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-runtime-restart-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    codex_binary = Path.join(test_root, "fake-codex")
    process_identity_file = Path.join(test_root, "app-server.identity")
    hook_result_file = Path.join(test_root, "after-run.result")

    File.mkdir_p!(test_root)
    install_active_fake_app_server!(codex_binary)

    after_run_hook = descendant_retirement_hook(process_identity_file, hook_result_file)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: "#{codex_binary} app-server",
      codex_read_timeout_ms: 1_000,
      hook_after_run: after_run_hook,
      hook_timeout_ms: 10_000
    )

    # The fake ignores TERM. Keeping this above Task.Supervisor's historical
    # five-second default proves that the runtime configures the task shutdown
    # barrier itself rather than only extending its wait for Task.Supervisor.
    put_codex_process_kill_timeout!(Workflow.workflow_file_path(), 6_000)

    runtime_supervisor = Process.whereis(SymphonyElixir.RuntimeSupervisor)
    old_orchestrator = Process.whereis(SymphonyElixir.Orchestrator)
    old_task_supervisor = Process.whereis(SymphonyElixir.TaskSupervisor)

    assert is_pid(runtime_supervisor)
    assert is_pid(old_orchestrator)
    assert is_pid(old_task_supervisor)

    issue = %Issue{
      id: "issue-runtime-restart",
      identifier: "MT-RUNTIME-RESTART",
      title: "Retire the predecessor runtime",
      description: "Prove restart ordering",
      state: "In Progress",
      url: "https://example.org/issues/MT-RUNTIME-RESTART",
      labels: []
    }

    recipient = self()

    assert {:ok, old_task} = AgentRunner.start_supervised(issue, recipient)
    assert_barrier_member!(old_task)

    task_ref = Process.monitor(old_task)

    on_exit(fn ->
      if Process.alive?(old_task) do
        Process.exit(old_task, :kill)
      end

      File.rm_rf(test_root)
    end)

    assert_receive {
                     :codex_worker_update,
                     "issue-runtime-restart",
                     %{
                       event: :session_started,
                       codex_app_server_pid: codex_app_server_pid
                     }
                   },
                   5_000

    {codex_app_server_pid, ""} = Integer.parse(codex_app_server_pid)
    {:ok, codex_start_time} = process_start_time(codex_app_server_pid)
    File.write!(process_identity_file, "#{codex_app_server_pid} #{codex_start_time}\n")

    assert process_identity_alive?(codex_app_server_pid, codex_start_time)

    Process.exit(old_orchestrator, :kill)

    await_retirement_before_replacement!(
      hook_result_file,
      runtime_supervisor,
      old_task_supervisor,
      old_orchestrator,
      10_000
    )

    assert Process.whereis(SymphonyElixir.RuntimeSupervisor) == runtime_supervisor
    assert Process.alive?(runtime_supervisor)
    assert File.read!(hook_result_file) == "descendant_retired\n"
    refute process_identity_alive?(codex_app_server_pid, codex_start_time)

    new_task_supervisor =
      await_registered_replacement(SymphonyElixir.TaskSupervisor, old_task_supervisor, 1_000)

    new_orchestrator =
      await_registered_replacement(SymphonyElixir.Orchestrator, old_orchestrator, 1_000)

    assert_receive {:DOWN, ^task_ref, :process, ^old_task, _reason}, 0

    assert Process.whereis(SymphonyElixir.RuntimeSupervisor) == runtime_supervisor
    assert Process.alive?(runtime_supervisor)
    refute Process.alive?(old_task)
    refute new_task_supervisor == old_task_supervisor
    refute new_orchestrator == old_orchestrator
  end

  defp assert_nested_supervisor_member_barrier(supervisor_name) do
    runtime = runtime_snapshot()
    supervisor = Map.fetch!(runtime.children, supervisor_name)
    test_pid = self()
    token = make_ref()

    assert {:ok, member} =
             Task.Supervisor.start_child(
               supervisor,
               fn ->
                 Process.flag(:trap_exit, true)
                 :ok = CleanupBarrier.register_runtime_member(self())
                 send(test_pid, {:runtime_member_ready, token, self()})

                 receive do
                   {:EXIT, ^supervisor, reason} ->
                     send(test_pid, {:runtime_member_trapped_exit, token, self(), reason})
                 end

                 receive do
                   {:release_runtime_member, ^token} -> :ok
                 end
               end,
               shutdown: :infinity
             )

    member_ref = Process.monitor(member)
    assert_receive {:runtime_member_ready, ^token, ^member}, 1_000
    Process.exit(supervisor, :kill)

    assert_receive {:runtime_member_trapped_exit, ^token, ^member, :killed}, 1_000
    assert_runtime_unchanged(runtime, 500)
    assert Process.alive?(member)

    send(member, {:release_runtime_member, token})
    assert_receive {:DOWN, ^member_ref, :process, ^member, :normal}, 1_000

    Enum.each(runtime.children, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
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

  defp install_active_fake_app_server!(path) do
    File.write!(
      path,
      """
      #!/bin/sh
      trap '' TERM
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-runtime-restart"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-runtime-restart"}}}'
            ;;
          5)
            printf '%s\\n' '{"id":4,"result":{}}'
            printf '%s\\n' '{"method":"turn/cancelled","params":{"threadId":"thread-runtime-restart","turn":{"id":"turn-runtime-restart"}}}'
            while :; do sleep 1; done
            ;;
        esac
      done
      """
    )

    File.chmod!(path, 0o755)
  end

  defp descendant_retirement_hook(identity_file, result_file) do
    "read pid original_start < '#{identity_file}'; " <>
      "state=$(awk '{print $3}' /proc/$pid/stat 2>/dev/null || true); " <>
      "current_start=$(awk '{print $22}' /proc/$pid/stat 2>/dev/null || true); " <>
      ~s|if [ -n "$state" ] && [ "$state" != Z ] && [ "$current_start" = "$original_start" ]; | <>
      "then printf '%s\\n' descendant_alive; else printf '%s\\n' descendant_retired; fi > '#{result_file}'"
  end

  defp put_codex_process_kill_timeout!(workflow_path, timeout_ms) do
    contents = File.read!(workflow_path)
    marker = "  stall_timeout_ms:"

    assert String.contains?(contents, marker)

    updated =
      String.replace(
        contents,
        marker,
        "  process_kill_timeout_ms: #{timeout_ms}\n#{marker}",
        global: false
      )

    File.write!(workflow_path, updated)
    :ok = WorkflowStore.force_reload()
  end

  defp process_start_time(pid) when is_integer(pid) and pid > 0 do
    with {:ok, stat} <- File.read("/proc/#{pid}/stat"),
         [start_time | _rest] <- stat |> String.split() |> Enum.drop(21),
         {start_time, ""} <- Integer.parse(start_time) do
      {:ok, start_time}
    else
      _error -> {:error, :process_identity_unavailable}
    end
  end

  defp process_identity_alive?(pid, expected_start_time) do
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

  defp await_retirement_before_replacement!(
         result_path,
         runtime_supervisor,
         old_task_supervisor,
         old_orchestrator,
         timeout_ms
       ) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    do_await_retirement_before_replacement!(
      result_path,
      runtime_supervisor,
      old_task_supervisor,
      old_orchestrator,
      deadline_ms
    )
  end

  defp do_await_retirement_before_replacement!(
         result_path,
         runtime_supervisor,
         old_task_supervisor,
         old_orchestrator,
         deadline_ms
       ) do
    case File.read(result_path) do
      {:ok, "descendant_retired\n"} ->
        :ok

      {:ok, result} ->
        flunk("after_run observed an unretired predecessor: #{inspect(result)}")

      {:error, :enoent} ->
        assert_runtime_not_replaced!(runtime_supervisor, old_task_supervisor, old_orchestrator)

        if System.monotonic_time(:millisecond) >= deadline_ms do
          flunk("timed out waiting for verified predecessor retirement")
        else
          Process.sleep(10)

          do_await_retirement_before_replacement!(
            result_path,
            runtime_supervisor,
            old_task_supervisor,
            old_orchestrator,
            deadline_ms
          )
        end

      {:error, reason} ->
        flunk("failed to read retirement marker: #{inspect(reason)}")
    end
  end

  defp assert_runtime_not_replaced!(runtime_supervisor, old_task_supervisor, old_orchestrator) do
    if Process.whereis(SymphonyElixir.RuntimeSupervisor) != runtime_supervisor do
      flunk("RuntimeSupervisor parent was replaced before predecessor retirement")
    end

    case Process.whereis(SymphonyElixir.TaskSupervisor) do
      pid when is_nil(pid) or pid == old_task_supervisor -> :ok
      _replacement -> flunk("TaskSupervisor was replaced before predecessor retirement")
    end

    case Process.whereis(SymphonyElixir.Orchestrator) do
      pid when is_nil(pid) or pid == old_orchestrator -> :ok
      _replacement -> flunk("Orchestrator was replaced before predecessor retirement")
    end
  end

  defp await_registered_replacement(name, old_pid, attempts)

  defp await_registered_replacement(_name, _old_pid, 0) do
    flunk("runtime child was not replaced before the deadline")
  end

  defp await_registered_replacement(name, old_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pending ->
        Process.sleep(10)
        await_registered_replacement(name, old_pid, attempts - 1)
    end
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
        _replacement -> flunk("#{inspect(name)} restarted before cleanup verification")
      end
    end)

    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(10)
      do_assert_runtime_unchanged(runtime, deadline_ms)
    else
      :ok
    end
  end
end
