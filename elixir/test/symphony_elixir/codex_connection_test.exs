# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio verifies stable
# operation correlation across transport retries, responses, and uncertainty.

defmodule SymphonyElixir.Codex.ConnectionTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Codex.{CleanupGuardian, Connection, TransportError}
  alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

  defmodule FailFirstStopAdapter do
    @moduledoc false
    alias SymphonyElixir.Codex.ProcessAdapter
    @canary "PRIVATE-STOP-REASON-CANARY"

    def canary, do: @canary

    def start(argv, opts), do: ProcessAdapter.start(argv, opts)
    def send(adapter, data), do: ProcessAdapter.send(adapter, data)
    def metadata(adapter), do: ProcessAdapter.metadata(adapter)

    def stop(adapter, timeout_ms) do
      counter = Application.fetch_env!(:symphony_elixir, :fail_first_stop_counter)

      case Agent.get_and_update(counter, fn count -> {count, count + 1} end) do
        0 -> {:error, {:private_adapter_reason, @canary}}
        _later_attempt -> ProcessAdapter.stop(adapter, timeout_ms)
      end
    end
  end

  defmodule CanaryStartAdapter do
    @moduledoc false
    @canary "PRIVATE-START-REASON-CANARY"

    def canary, do: @canary
    def start(_argv, _opts), do: {:error, {:private_adapter_reason, @canary}}
  end

  defmodule UnverifiedStartRollbackAdapter do
    @moduledoc false
    @canary "PRIVATE-STARTUP-ROLLBACK-CANARY"

    def canary, do: @canary

    def start(_argv, _opts) do
      {:error,
       {:process_identity_unavailable, {:private_adapter_reason, @canary},
        {:startup_rollback_unverified,
         %{
           group_empty: false,
           manager_alive: true,
           private: @canary
         }}}}
    end
  end

  defmodule CanarySendAdapter do
    @moduledoc false
    @canary "PRIVATE-SEND-REASON-CANARY"

    def canary, do: @canary

    def start(_argv, _opts) do
      child =
        spawn_link(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {:ok, %{pid: child, os_pid: System.unique_integer([:positive])}}
    end

    def send(_adapter, _data), do: {:error, {:private_adapter_reason, @canary}}
    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      if Process.alive?(adapter.pid), do: Kernel.send(adapter.pid, :stop)
      :ok
    end
  end

  defmodule CanaryExitAdapter do
    @moduledoc false
    @canary "PRIVATE-EXIT-REASON-CANARY"

    def canary, do: @canary

    def start(_argv, _opts) do
      child = spawn_link(fn -> exit({:private_adapter_reason, @canary}) end)
      {:ok, %{pid: child, os_pid: System.unique_integer([:positive])}}
    end

    def send(_adapter, _data), do: :ok
    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}
    def stop(_adapter, _timeout_ms), do: :ok
  end

  defmodule SleepingSendAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      child = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: child, os_pid: System.unique_integer([:positive])}}
    end

    def send(_adapter, _data) do
      Process.sleep(5_000)
      :ok
    end

    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)
      :ok
    end
  end

  defmodule ServerRequestThenSleepingSendAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      child = spawn_link(fn -> Process.sleep(:infinity) end)
      os_pid = System.unique_integer([:positive])

      request =
        Jason.encode!(%{
          "id" => "server-deadline",
          "method" => "item/commandExecution/requestApproval",
          "params" => %{}
        }) <> "\n"

      Kernel.send(self(), {:stdout, os_pid, request})
      {:ok, %{pid: child, os_pid: os_pid}}
    end

    def send(_adapter, _data) do
      Process.sleep(5_000)
      :ok
    end

    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)
      :ok
    end
  end

  defmodule RecordingAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      test_pid = Application.fetch_env!(:symphony_elixir, :connection_recording_test_pid)
      child = spawn_link(fn -> Process.sleep(:infinity) end)
      {:ok, %{pid: child, os_pid: System.unique_integer([:positive]), test_pid: test_pid}}
    end

    def send(adapter, _data) do
      Kernel.send(adapter.test_pid, :adapter_transmitted)
      :ok
    end

    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)
      :ok
    end
  end

  defmodule ControlledStopAdapter do
    @moduledoc false

    def stop(%{allow_stop: allow_stop} = adapter, _timeout_ms) do
      allowed? = Agent.get(allow_stop, & &1)

      if test_pid = Map.get(adapter, :test_pid) do
        send(test_pid, {:controlled_stop_attempt, self(), allowed?})
      end

      if allowed?, do: :ok, else: {:error, :cleanup_still_blocked}
    end
  end

  defmodule FaultingStopAdapter do
    @moduledoc false

    def stop(%{mode: mode, test_pid: test_pid}, _timeout_ms) do
      send(test_pid, {:faulting_stop_attempt, mode, self()})

      case mode do
        :ok -> :ok
        :kill -> Process.exit(self(), :kill)
        :sleep -> Process.sleep(:infinity)
        :raise -> raise "cleanup fault"
        :throw -> throw(:cleanup_fault)
        :unexpected -> :unexpected
      end
    end
  end

  defmodule DelayedCleanupAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      %{allow_stop: allow_stop, test_pid: test_pid} =
        Application.fetch_env!(:symphony_elixir, :delayed_cleanup_test_control)

      child = spawn(fn -> Process.sleep(:infinity) end)

      adapter = %{
        allow_stop: allow_stop,
        os_pid: System.unique_integer([:positive]),
        pid: child,
        test_pid: test_pid
      }

      Kernel.send(test_pid, {:delayed_cleanup_adapter_started, adapter})
      {:ok, adapter}
    end

    def send(_adapter, _data), do: :ok
    def metadata(adapter), do: %{os_pid: adapter.os_pid, pid: adapter.pid}

    def stop(adapter, _timeout_ms) do
      if Agent.get(adapter.allow_stop, & &1) do
        child_ref = Process.monitor(adapter.pid)
        if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)

        receive do
          {:DOWN, ^child_ref, :process, _child, _reason} ->
            Kernel.send(adapter.test_pid, {:delayed_cleanup_verified, self()})
            :ok
        after
          200 ->
            Process.demonitor(child_ref, [:flush])
            {:error, :cleanup_timeout}
        end
      else
        Kernel.send(adapter.test_pid, {:delayed_cleanup_attempt, self()})
        {:error, :cleanup_still_blocked}
      end
    end
  end

  defmodule ConcurrentStopProbeAdapter do
    @moduledoc false

    def start(_argv, _opts) do
      %{counter: counter, test_pid: test_pid} =
        Application.fetch_env!(:symphony_elixir, :concurrent_stop_probe_control)

      child = spawn_link(fn -> Process.sleep(:infinity) end)

      adapter = %{
        counter: counter,
        os_pid: System.unique_integer([:positive]),
        pid: child,
        test_pid: test_pid
      }

      Kernel.send(test_pid, {:concurrent_stop_probe_started, adapter})
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

      Kernel.send(adapter.test_pid, {:concurrent_stop_entered, self(), active, max_seen})

      try do
        receive do
          {:release_concurrent_stop, result} ->
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

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-connection-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "successful connection publishes its established cleanup authority before readiness" do
    parent = self()

    assert {:ok, connection} =
             Connection.start(["/fake-app-server"],
               process_adapter: CanarySendAdapter,
               on_cleanup_authority: fn handle ->
                 send(parent, {:established_cleanup_authority, handle})
               end,
               on_started: fn pid -> send(parent, {:connection_ready, pid}) end
             )

    connection_ref = Process.monitor(connection)

    assert_receive {:established_cleanup_authority, %CleanupGuardian.Handle{} = handle},
                   1_000

    assert_receive {:connection_ready, ^connection}, 1_000
    assert Process.alive?(handle.pid)
    refute CleanupGuardian.verified?(handle)

    assert :ok = Connection.close(connection)
    assert CleanupGuardian.verified?(handle)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal}, 1_000
    assert AgentRunner.connection_retired_for_test(connection, handle)
  end

  test "dead established connection is not retired before its guardian proves cleanup" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)
    connection = spawn(fn -> Process.sleep(:infinity) end)

    handle =
      CleanupGuardian.start_handle(
        connection,
        ControlledStopAdapter,
        %{allow_stop: allow_stop},
        0
      )

    connection_ref = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :killed}, 1_000

    refute AgentRunner.connection_retired_for_test(connection, handle)
    Agent.update(allow_stop, fn _blocked -> true end)
    :ok = CleanupGuardian.request_cleanup(handle)
    assert eventually(fn -> CleanupGuardian.verified?(handle) end)
    assert AgentRunner.connection_retired_for_test(connection, handle)
  end

  test "cleanup guardian retains authority after its foreground retry window" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    guardian =
      CleanupGuardian.start(
        self(),
        ControlledStopAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0
      )

    guardian_ref = Process.monitor(guardian)

    send(guardian, :unrelated_message)
    assert :ok = CleanupGuardian.request_cleanup(guardian)
    assert_receive {:cleanup_guardian_exhausted, ^guardian}, 4_000

    flush_controlled_stop_attempts()
    send(guardian, :retry_cleanup)
    assert_receive {:controlled_stop_attempt, _worker, false}, 1_000
    Process.sleep(50)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(guardian, :retry_cleanup)

    assert_receive {:controlled_stop_attempt, _worker, true}, 1_000
    assert_receive {:cleanup_guardian_verified, ^guardian}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000

    noise_guardian =
      CleanupGuardian.start(
        self(),
        FaultingStopAdapter,
        %{mode: :ok, test_pid: self()},
        0
      )

    noise_guardian_ref = Process.monitor(noise_guardian)
    send(noise_guardian, :unrelated_message)
    assert :ok = CleanupGuardian.cleanup_verified(noise_guardian)

    assert_receive {:DOWN, ^noise_guardian_ref, :process, ^noise_guardian, :normal}, 1_000

    owner = spawn(fn -> Process.sleep(:infinity) end)

    owner_guardian =
      CleanupGuardian.start(
        owner,
        FaultingStopAdapter,
        %{mode: :ok, test_pid: self()},
        0
      )

    owner_guardian_ref = Process.monitor(owner_guardian)
    Process.exit(owner, :kill)

    assert_receive {:faulting_stop_attempt, :ok, _worker}, 1_000
    assert_receive {:DOWN, ^owner_guardian_ref, :process, ^owner_guardian, :normal}, 1_000

    Enum.each([:kill, :raise, :throw, :unexpected, :sleep], fn mode ->
      faulting_guardian =
        CleanupGuardian.start(
          self(),
          FaultingStopAdapter,
          %{mode: mode, test_pid: self()},
          0
        )

      faulting_guardian_ref = Process.monitor(faulting_guardian)
      assert :ok = CleanupGuardian.request_cleanup(faulting_guardian)
      assert_receive {:faulting_stop_attempt, ^mode, _worker}, 1_000
      assert :ok = CleanupGuardian.cleanup_verified(faulting_guardian)

      assert_receive {:DOWN, ^faulting_guardian_ref, :process, ^faulting_guardian, :normal},
                     2_000
    end)
  end

  test "runtime cleanup guardian fails closed after an unacknowledged pre-ready death" do
    {:ok, allow_stop} = Agent.start_link(fn -> true end)

    pre_ready_death = fn _guardian_fun ->
      guardian = spawn(fn -> :ok end)
      guardian_ref = Process.monitor(guardian)
      assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
      {:ok, guardian}
    end

    assert_raise RuntimeError, "runtime cleanup guardian unavailable", fn ->
      CleanupGuardian.start_handle_with_starter_for_test(
        self(),
        ControlledStopAdapter,
        %{allow_stop: allow_stop, test_pid: self()},
        0,
        pre_ready_death
      )
    end

    refute_receive {:controlled_stop_attempt, _worker, _allowed?}, 100
  end

  test "late owner exit retires a Connection after guardian handoff" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)
    test_pid = self()

    previous_control =
      Application.get_env(:symphony_elixir, :delayed_cleanup_test_control)

    Application.put_env(:symphony_elixir, :delayed_cleanup_test_control, %{
      allow_stop: allow_stop,
      test_pid: test_pid
    })

    on_exit(fn ->
      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :delayed_cleanup_test_control)
      else
        Application.put_env(
          :symphony_elixir,
          :delayed_cleanup_test_control,
          previous_control
        )
      end
    end)

    owner =
      spawn(fn ->
        result =
          Connection.start(["/bin/true"],
            kill_timeout_ms: 0,
            process_adapter: DelayedCleanupAdapter
          )

        send(test_pid, {:late_owner_connection, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:late_owner_connection, ^owner, {:ok, connection}}, 1_000
    assert_receive {:delayed_cleanup_adapter_started, adapter}, 1_000

    assert {:error, %TransportError{kind: :process_cleanup_failed}} =
             Connection.close(connection)

    state = wait_for_guardian_handoff!(connection)
    guardian = state.cleanup_guardian
    guardian_ref = Process.monitor(guardian)
    connection_ref = Process.monitor(connection)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000
    assert Process.alive?(guardian)
    assert Process.alive?(adapter.pid)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(guardian, :retry_cleanup)

    assert_receive {:delayed_cleanup_verified, _worker}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    refute Process.alive?(adapter.pid)
  end

  test "a failed close transfers all retry authority to one guardian caller" do
    {:ok, counter} =
      Agent.start(fn -> %{active: 0, callers: MapSet.new(), max_seen: 0} end)

    previous_control = Application.get_env(:symphony_elixir, :concurrent_stop_probe_control)

    Application.put_env(:symphony_elixir, :concurrent_stop_probe_control, %{
      counter: counter,
      test_pid: self()
    })

    parent = self()

    owner =
      spawn(fn ->
        result =
          Connection.start(["/bin/true"],
            kill_timeout_ms: 0,
            process_adapter: ConcurrentStopProbeAdapter
          )

        send(parent, {:concurrent_stop_connection, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:concurrent_stop_connection, ^owner, {:ok, connection}}, 1_000
    assert_receive {:concurrent_stop_probe_started, adapter}, 1_000

    connection_ref = Process.monitor(connection)

    on_exit(fn ->
      if Process.alive?(counter) do
        counter
        |> Agent.get(& &1.callers)
        |> Enum.each(&send(&1, {:release_concurrent_stop, :ok}))
      end

      if Process.alive?(owner), do: Process.exit(owner, :kill)
      if Process.alive?(adapter.pid), do: Process.exit(adapter.pid, :kill)

      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :concurrent_stop_probe_control)
      else
        Application.put_env(
          :symphony_elixir,
          :concurrent_stop_probe_control,
          previous_control
        )
      end
    end)

    close_task = Task.async(fn -> Connection.close(connection) end)

    assert_receive {:concurrent_stop_entered, initial_caller, 1, 1}, 1_000
    refute initial_caller == connection
    send(initial_caller, {:release_concurrent_stop, {:error, :cleanup_held}})

    assert {:error, %TransportError{kind: :process_cleanup_failed}} =
             Task.await(close_task, 1_000)

    assert_receive {:concurrent_stop_entered, guardian_caller, 1, 1}, 1_000
    refute guardian_caller == connection

    Process.exit(owner, :kill)

    refute_receive {:concurrent_stop_entered, _second_caller, _active, _max_seen}, 750

    assert %{active: 1, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
    assert Process.alive?(connection)
    assert Process.alive?(adapter.pid)

    send(guardian_caller, {:release_concurrent_stop, :ok})

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000
    refute Process.alive?(adapter.pid)
    assert %{active: 0, max_seen: 1} = Agent.get(counter, &Map.take(&1, [:active, :max_seen]))
  end

  test "runtime supervisor exit detaches an already-handed-off Connection without overlap" do
    {:ok, allow_stop} = Agent.start(fn -> false end)
    test_pid = self()
    previous_control = Application.get_env(:symphony_elixir, :delayed_cleanup_test_control)

    Application.put_env(:symphony_elixir, :delayed_cleanup_test_control, %{
      allow_stop: allow_stop,
      test_pid: test_pid
    })

    on_exit(fn ->
      if is_nil(previous_control) do
        Application.delete_env(:symphony_elixir, :delayed_cleanup_test_control)
      else
        Application.put_env(
          :symphony_elixir,
          :delayed_cleanup_test_control,
          previous_control
        )
      end
    end)

    assert {:ok, connection} =
             Connection.start(["/bin/true"],
               kill_timeout_ms: 0,
               process_adapter: DelayedCleanupAdapter
             )

    assert_receive {:delayed_cleanup_adapter_started, adapter}, 1_000

    assert {:error, %TransportError{kind: :process_cleanup_failed}} =
             Connection.close(connection)

    guardian = wait_for_guardian_handoff!(connection).cleanup_guardian
    guardian_ref = Process.monitor(guardian)
    connection_ref = Process.monitor(connection)

    on_exit(fn ->
      if Process.alive?(allow_stop) do
        Agent.update(allow_stop, fn _blocked -> true end)
      end

      if Process.alive?(guardian), do: send(guardian, :retry_cleanup)
    end)

    runtime_children = [
      SymphonyElixir.CleanupBarrier,
      SymphonyElixir.CleanupSupervisor,
      SymphonyElixir.ConnectionSupervisor,
      SymphonyElixir.WorkspaceHookSupervisor,
      SymphonyElixir.TaskSupervisor,
      SymphonyElixir.Orchestrator
    ]

    runtime = Map.new(runtime_children, &{&1, Process.whereis(&1)})
    Process.exit(Map.fetch!(runtime, SymphonyElixir.Orchestrator), :kill)

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000
    assert Process.alive?(guardian)
    assert Process.alive?(adapter.pid)

    Enum.each(runtime, fn {name, old_pid} ->
      current = Process.whereis(name)
      assert is_nil(current) or current == old_pid
    end)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(guardian, :retry_cleanup)

    assert_receive {:delayed_cleanup_verified, _worker}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    refute Process.alive?(adapter.pid)

    Enum.each(runtime, fn {name, old_pid} ->
      assert is_pid(await_registered_replacement(name, old_pid, 2_000))
    end)
  end

  test "closing a dead connection returns a wrapped typed cleanup failure" do
    connection = spawn(fn -> :ok end)
    connection_ref = Process.monitor(connection)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal}, 1_000

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{cleanup_verified: false, reason: :connection_unavailable}
            }} = Connection.close(connection)
  end

  test "closing a dead connection with uncertainty preserves its operation and cause" do
    connection = spawn(fn -> :ok end)
    connection_ref = Process.monitor(connection)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal}, 1_000

    operation = %{
      classification: :conservative,
      method: "item/tool/call",
      request_hash: String.duplicate("a", 64),
      send_state: :sent
    }

    uncertainty =
      TransportError.new(:uncertain_external_outcome, %{
        cause: %{kind: :request_timeout, message: "bounded timeout"},
        operation: operation,
        reconciliation_required: true
      })

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{
                cause: %{
                  kind: :uncertain_external_outcome,
                  cause: %{kind: :request_timeout}
                },
                cleanup_verified: false,
                operation: ^operation
              }
            }} = Connection.close_with_error(connection, uncertainty)
  end

  test "ownerless connection hands persistent cleanup authority to its guardian" do
    {:ok, allow_stop} = Agent.start_link(fn -> false end)

    Application.put_env(:symphony_elixir, :delayed_cleanup_test_control, %{
      allow_stop: allow_stop,
      test_pid: self()
    })

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :delayed_cleanup_test_control)
    end)

    parent = self()

    owner =
      spawn(fn ->
        {:ok, connection} =
          Connection.start(["/bin/true"],
            kill_timeout_ms: 50,
            process_adapter: DelayedCleanupAdapter
          )

        Kernel.send(parent, {:delayed_cleanup_connection, connection})
        Process.sleep(:infinity)
      end)

    assert_receive {:delayed_cleanup_adapter_started, adapter}, 1_000
    assert_receive {:delayed_cleanup_connection, connection}, 1_000
    state = :sys.get_state(connection)
    guardian = state.cleanup_guardian
    connection_ref = Process.monitor(connection)
    guardian_ref = Process.monitor(guardian)

    Process.exit(owner, :kill)
    assert_receive {:delayed_cleanup_attempt, _worker}, 1_000

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :cleanup_authority_handed_off},
                   5_000

    assert Process.alive?(guardian)
    assert Process.alive?(adapter.pid)

    Agent.update(allow_stop, fn _blocked -> true end)
    send(guardian, :retry_cleanup)

    assert_receive {:delayed_cleanup_verified, _worker}, 1_000
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    refute Process.alive?(adapter.pid)
  end

  test "keeps bounded categorical stderr separate from a valid JSONL response", %{root: root} do
    secret = "transport-secret-value"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.generated_stderr("OPENAI_API_KEY=#{secret}\n", 24, fragments: [7, 11, :rest]),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, stderr_tail_bytes: 256)

    assert {:ok, %{"account" => nil}, metadata} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert metadata.attempt == 1
    diagnostics = Connection.diagnostics(connection)
    assert diagnostics.stderr_present
    assert diagnostics.stderr_bytes_seen > 256
    assert diagnostics.stderr_bytes_retained == 0
    assert diagnostics.stderr_truncated
    assert diagnostics.stderr_categories == [:unclassified]
    refute Map.has_key?(diagnostics, :stderr_tail)
    refute inspect(diagnostics) =~ secret
  end

  test "never exposes arbitrary stderr or JSON-RPC error messages", %{root: root} do
    canary = "CONFIDENTIAL-PROMPT-CANARY-#{System.unique_integer([:positive])}"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.stderr("private prompt: #{canary}\n", fragments: [3, 5, :rest]),
        FakeCodex.response_error(1, -32_000, "server echoed #{canary}"),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:error, %TransportError{kind: :response_error} = error} =
             Connection.request(connection, "account/read", %{}, 2_000)

    diagnostics = Connection.diagnostics(connection)
    refute inspect(error) =~ canary
    refute inspect(diagnostics) =~ canary
    refute term_contains_binary?(:sys.get_state(connection), canary)
    assert diagnostics.stderr_present
    assert diagnostics.stderr_categories == [:unclassified]
    assert diagnostics.stderr_chunks_seen > 0
    refute Map.has_key?(diagnostics, :stderr_tail)
  end

  test "categorizes private adapter start, write, and exit reasons without reflecting them" do
    assert {:error,
            %TransportError{
              kind: :process_start_failed,
              details: %{reason: :adapter_start_failed}
            } = start_error} =
             Connection.start(["/bin/true"], process_adapter: CanaryStartAdapter)

    refute inspect(start_error) =~ CanaryStartAdapter.canary()

    assert {:ok, send_connection} =
             Connection.start(["/bin/true"], process_adapter: CanarySendAdapter)

    assert {:error,
            %TransportError{
              kind: :write_failed,
              details: %{reason: :adapter_write_failed}
            } = send_error} = Connection.request(send_connection, "account/read", %{}, 2_000)

    refute inspect(send_error) =~ CanarySendAdapter.canary()
    assert :ok = Connection.close(send_connection)

    assert {:ok, exit_connection} =
             Connection.start(["/bin/true"], process_adapter: CanaryExitAdapter)

    assert %TransportError{
             kind: :process_exit,
             details: %{reason: :unknown_exit}
           } = exit_error = wait_for_failure!(exit_connection)

    refute inspect(exit_error) =~ CanaryExitAdapter.canary()
    assert :ok = Connection.close(exit_connection)
  end

  test "classifies unverified startup rollback as cleanup failure and reports it before stop" do
    test_pid = self()

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{
                cleanup_verified: false,
                reason: :startup_rollback_unverified
              }
            } = error} =
             Connection.start(["/bin/true"],
               process_adapter: UnverifiedStartRollbackAdapter,
               on_transport_failure: fn failure ->
                 send(test_pid, {:startup_transport_failure, failure})
               end
             )

    assert_receive {:startup_transport_failure, ^error}, 1_000
    refute inspect(error) =~ UnverifiedStartRollbackAdapter.canary()
  end

  test "classifies a known stderr condition across split chunks", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.stderr("Authentication failed\n", fragments: [8, 5, :rest]),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"account" => nil}, _metadata} =
             Connection.request(connection, "account/read", %{}, 2_000)

    diagnostics = Connection.diagnostics(connection)
    assert diagnostics.stderr_categories == [:authentication]
    assert diagnostics.stderr_chunks_seen > 0
    assert diagnostics.stderr_line_count == 1
    refute diagnostics.stderr_invalid_utf8
  end

  test "reports invalid UTF-8 stderr without exposing private diagnostic state", %{root: root} do
    canary = "STATUS-CANARY-#{System.unique_integer([:positive])}"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.stderr(<<canary::binary, 10, 255, 10>>),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"account" => nil}, _metadata} =
             Connection.request(connection, "account/read", %{}, 2_000)

    diagnostics = Connection.diagnostics(connection)
    status = :sys.get_status(connection)
    assert diagnostics.stderr_invalid_utf8
    assert diagnostics.stderr_line_count == 2
    refute term_contains_binary?(:sys.get_state(connection), canary)
    refute inspect(status) =~ canary
    refute inspect(status) =~ <<255>>
  end

  test "redacts raw requests and callback fields from OTP status reports" do
    canary = "SYS-STATUS-PRIVATE-CANARY-#{System.unique_integer([:positive])}"
    Application.put_env(:symphony_elixir, :connection_recording_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :connection_recording_test_pid)
    end)

    {:ok, connection} =
      Connection.start(["/bin/true"],
        kill_timeout_ms: 50,
        process_adapter: RecordingAdapter
      )

    parent = self()

    caller =
      spawn(fn ->
        result = Connection.request(connection, "account/read", %{"private" => canary}, 5_000)
        send(parent, {:status_request_result, result})
      end)

    assert_receive :adapter_transmitted, 1_000

    status = :sys.get_status(connection)
    refute inspect(status) =~ canary

    raw_status = %{
      state: :sys.get_state(connection),
      message: {:private_message, canary},
      reason: {:private_reason, canary},
      log: [{:private_log, canary}]
    }

    refute inspect(Connection.format_status(raw_status)) =~ canary
    caller_ref = Process.monitor(caller)
    assert :ok = Connection.close(connection)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, _reason}, 1_000
    refute_received {:status_request_result, {:ok, _result, _metadata}}
  end

  test "rejects non-protocol stdout as terminal contamination", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout("human log output\n")
      ])

    connection = start_connection!(fixture)

    assert {:error, %TransportError{kind: :stdout_contamination}} =
             Connection.request(connection, "account/read", %{}, 2_000)
  end

  test "classifies invalid UTF-8 stdout without crashing the transport", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout(<<255, 254, ?\n>>)
      ])

    connection = start_connection!(fixture)

    assert {:error, %TransportError{kind: :stdout_contamination}} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert Process.alive?(connection)
  end

  test "rejects malformed JSON as a terminal typed failure", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout(~s({"id":1,"result":\n))
      ])

    connection = start_connection!(fixture)

    assert {:error, %TransportError{kind: :malformed_json}} =
             Connection.request(connection, "account/read", %{}, 2_000)
  end

  test "rejects a frame as soon as it exceeds the configured maximum", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.generated_stdout("x", 512,
          prefix: "{\"id\":1,\"result\":{\"padding\":\"",
          suffix: "\"}}\n",
          fragments: [64, 64, :rest]
        )
      ])

    connection = start_connection!(fixture, max_frame_bytes: 256)

    assert {:error, %TransportError{kind: :frame_too_large, details: details}} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert details.limit == 256
    assert details.observed > details.limit
  end

  test "rejects unexpected and duplicate response IDs", %{root: root} do
    unexpected =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(999, %{})
      ])

    unexpected_connection = start_connection!(unexpected)

    assert {:error, %TransportError{kind: :unexpected_response_id}} =
             Connection.request(unexpected_connection, "account/read", %{}, 2_000)

    first = Jason.encode!(%{"id" => 1, "result" => %{"ok" => true}})

    duplicate =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout(first <> "\n" <> first <> "\n")
      ])

    duplicate_connection = start_connection!(duplicate)
    result = Connection.request(duplicate_connection, "account/read", %{}, 2_000)

    error =
      case result do
        {:error, %TransportError{} = failure} -> failure
        {:ok, _result, _metadata} -> wait_for_failure!(duplicate_connection)
      end

    assert error.kind == :duplicate_response_id
  end

  test "uses one absolute deadline even when bytes keep arriving", %{root: root} do
    response = Jason.encode!(%{"id" => 1, "result" => %{}}) <> "\n"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout(response, fragments: [1, 1, 1, :rest], delay_ms: 30)
      ])

    connection = start_connection!(fixture, kill_timeout_ms: 50)
    started_ms = System.monotonic_time(:millisecond)

    assert {:error, %TransportError{kind: :request_timeout}} =
             Connection.request(connection, "account/read", %{}, 55)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    assert elapsed_ms < 500
  end

  test "bounds a stalled adapter write by the request deadline" do
    {:ok, connection} =
      Connection.start(["/bin/true"],
        kill_timeout_ms: 50,
        process_adapter: SleepingSendAdapter
      )

    started_ms = System.monotonic_time(:millisecond)

    assert {:error, %TransportError{kind: :write_failed, details: %{reason: :write_timeout}}} =
             Connection.request(connection, "account/read", %{}, 40)

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    assert elapsed_ms < 500
    assert :ok = Connection.close(connection)
  end

  test "bounds a stalled server response by its supplied absolute deadline" do
    {:ok, connection} =
      Connection.start(["/bin/true"],
        kill_timeout_ms: 50,
        process_adapter: ServerRequestThenSleepingSendAdapter
      )

    assert {:ok, %{payload: %{"id" => "server-deadline"}}} =
             Connection.next_message(connection, 1_000)

    deadline_ms = System.monotonic_time(:millisecond) + 40
    started_ms = System.monotonic_time(:millisecond)

    assert {:error, %TransportError{kind: :write_failed, details: %{reason: :write_timeout}}} =
             Connection.respond_until(
               connection,
               "server-deadline",
               %{"decision" => "decline"},
               deadline_ms
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    assert elapsed_ms < 500
    assert :ok = Connection.close(connection)
  end

  test "preparation and encoding cannot transmit after a tiny absolute deadline" do
    test_pid = self()
    Application.put_env(:symphony_elixir, :connection_recording_test_pid, test_pid)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :connection_recording_test_pid)
    end)

    large_prompt = :binary.copy("x", 8_000_000)

    {:ok, connection} =
      Connection.start(["/bin/true"],
        kill_timeout_ms: 50,
        process_adapter: RecordingAdapter
      )

    started_ms = System.monotonic_time(:millisecond)

    assert {:error, %TransportError{kind: :request_timeout}} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-deadline", "input" => [large_prompt]},
               1
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    assert elapsed_ms < 500
    refute_received :adapter_transmitted
    assert :ok = Connection.close(connection)
  end

  test "request deadline includes GenServer admission queue time" do
    test_pid = self()
    Application.put_env(:symphony_elixir, :connection_recording_test_pid, test_pid)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :connection_recording_test_pid)
    end)

    {:ok, connection} =
      Connection.start(["/bin/true"],
        kill_timeout_ms: 50,
        process_adapter: RecordingAdapter
      )

    :ok = :sys.suspend(connection)

    task =
      Task.async(fn ->
        Connection.request(
          connection,
          "turn/start",
          %{"threadId" => "thread-admission", "input" => []},
          100
        )
      end)

    try do
      wait_for_mailbox!(connection)
      Process.sleep(150)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error,
            %TransportError{
              kind: :request_timeout,
              details: %{phase: :request_admission, send_state: :prepared}
            }} = Task.await(task, 2_000)

    refute_received :adapter_transmitted
    assert :ok = Connection.close(connection)
  end

  test "rejects a response queued before its timer when resumed after the absolute deadline", %{
    root: root
  } do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.barrier("late-response", timeout_ms: 30_000),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert :ok = FakeCodex.release!(fixture, "ready")
    task = Task.async(fn -> Connection.request(connection, "account/read", %{}, 300) end)
    wait_for_barrier!(fixture, "late-response")
    deadline_ms = :sys.get_state(connection).pending.deadline_ms

    :ok = :sys.suspend(connection)

    try do
      assert :ok = FakeCodex.release!(fixture, "late-response")
      sleep_past_deadline(deadline_ms)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error, %TransportError{kind: :request_timeout}} = Task.await(task, 2_000)
  end

  test "rejects stderr queued before a request timer once the absolute deadline passed", %{
    root: root
  } do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.barrier("request-pending", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert :ok = FakeCodex.release!(fixture, "ready")
    task = Task.async(fn -> Connection.request(connection, "account/read", %{}, 300) end)
    wait_for_barrier!(fixture, "request-pending")
    state = :sys.get_state(connection)
    deadline_ms = state.pending.deadline_ms
    os_pid = state.adapter.os_pid
    :ok = :sys.suspend(connection)

    try do
      send(connection, {:stderr, os_pid, "authentication failed"})
      sleep_past_deadline(deadline_ms)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error, %TransportError{kind: :request_timeout}} = Task.await(task, 2_000)
    diagnostics = Connection.diagnostics(connection)
    assert diagnostics.stderr_chunks_seen == 1
    assert diagnostics.stderr_categories == [:authentication]
  end

  test "retries overload only for an idempotent request within the original deadline", %{root: root} do
    run_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    attempt_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    test_pid = self()

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.response_error(1, -32_001, "busy"),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(2, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection =
      start_connection!(fixture,
        jitter_fn: fn _cap -> 0 end,
        metadata: %{run_id: run_id, attempt_id: attempt_id},
        on_request: fn metadata -> send(test_pid, {:wire_request, metadata}) end,
        overload_backoff_base_ms: 1,
        overload_backoff_max_ms: 1,
        overload_max_attempts: 2
      )

    assert {:ok, %{"account" => nil}, metadata} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert metadata.attempt == 2
    assert metadata.request_id == 2
    assert metadata.classification == :idempotent
    assert metadata.run_id == run_id
    assert metadata.attempt_id == attempt_id
    assert SymphonyElixir.Identity.valid_uuid4?(metadata.operation_id)

    assert_receive {:wire_request, %{request_id: 1} = first_wire}
    assert_receive {:wire_request, %{request_id: 2} = second_wire}
    assert first_wire.operation_id == second_wire.operation_id
    assert second_wire.operation_id == metadata.operation_id
    assert first_wire.request_hash == second_wire.request_hash
  end

  test "assigns distinct operation IDs to intentionally separate identical requests", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(2, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"account" => nil}, first} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert {:ok, %{"account" => nil}, second} =
             Connection.request(connection, "account/read", %{}, 2_000)

    assert first.request_hash == second.request_hash
    assert first.operation_id != second.operation_id
    assert SymphonyElixir.Identity.valid_uuid4?(first.operation_id)
    assert SymphonyElixir.Identity.valid_uuid4?(second.operation_id)
  end

  test "never transmits an overload retry after the original absolute deadline", %{root: root} do
    test_pid = self()

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.response_error(1, -32_001, "busy"),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}})
      ])

    connection =
      start_connection!(fixture,
        jitter_fn: fn _cap -> 100 end,
        on_retry: fn metadata -> send(test_pid, {:retry_scheduled, metadata}) end,
        overload_backoff_base_ms: 100,
        overload_backoff_max_ms: 100,
        overload_max_attempts: 2
      )

    assert :ok = FakeCodex.release!(fixture, "ready")
    task = Task.async(fn -> Connection.request(connection, "account/read", %{}, 300) end)
    assert_receive {:retry_scheduled, %{attempt: 2}}, 1_000
    deadline_ms = :sys.get_state(connection).pending.deadline_ms
    :ok = :sys.suspend(connection)

    try do
      sleep_past_deadline(deadline_ms)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error, %TransportError{kind: :request_timeout}} = Task.await(task, 2_000)

    assert [%{"id" => 1, "method" => "account/read", "params" => %{}}] =
             FakeCodex.received!(fixture)
  end

  test "does not retry overload for a side-effecting request", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.response_error(1, -32_001, "busy"),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection =
      start_connection!(fixture,
        jitter_fn: fn _cap -> 0 end,
        overload_max_attempts: 5
      )

    assert {:error, %TransportError{kind: :overloaded, details: details}} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-1", "input" => []},
               2_000
             )

    assert details.retryable == false
    assert details.method == "turn/start"
  end

  test "marks a sent side effect uncertain without retaining request parameters", %{root: root} do
    secret_prompt = "prompt-must-not-appear-in-diagnostics"
    run_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    attempt_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.raw_stdout("transport broke\n")
      ])

    connection =
      start_connection!(fixture, metadata: %{run_id: run_id, attempt_id: attempt_id})

    assert {:error,
            %TransportError{
              kind: :uncertain_external_outcome,
              details: %{operation: operation, reconciliation_required: true} = details
            }} =
             Connection.request(
               connection,
               "turn/start",
               %{
                 "threadId" => "thread-1",
                 "input" => [%{"type" => "text", "text" => secret_prompt}]
               },
               2_000
             )

    assert operation.method == "turn/start"
    assert operation.send_state == :sent
    assert operation.run_id == run_id
    assert operation.attempt_id == attempt_id
    assert SymphonyElixir.Identity.valid_uuid4?(operation.operation_id)
    assert is_binary(operation.request_hash)
    refute Map.has_key?(operation, :params)
    refute inspect(details) =~ secret_prompt
  end

  test "preserves active-turn uncertainty when an idempotent request times out", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.response(1, %{"turn" => %{"id" => "turn-active-read"}}),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.barrier("read-pending", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"turn" => %{"id" => "turn-active-read"}}, _metadata} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-active-read", "input" => []},
               2_000
             )

    read_task = Task.async(fn -> Connection.request(connection, "account/read", %{}, 300) end)
    wait_for_barrier!(fixture, "read-pending")

    assert {:error,
            %TransportError{
              kind: :uncertain_external_outcome,
              details: %{
                cause: %{kind: :request_timeout},
                operation:
                  %{
                    classification: :side_effecting,
                    method: "turn/start",
                    request_id: 1,
                    send_state: :sent
                  } = operation,
                reconciliation_required: true
              }
            }} = Task.await(read_task, 2_000)

    refute Map.has_key?(operation, :params)

    state = :sys.get_state(connection)
    assert %TransportError{kind: :uncertain_external_outcome} = state.failure
    assert state.active_turn == nil
    assert state.side_effect_operation == nil
    assert state.pending == nil
  end

  test "explicit close reports an acknowledged thread start as unresolved", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "thread/start"}, match: :subset),
        FakeCodex.response(1, %{"thread" => %{"id" => "thread-close"}}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"thread" => %{"id" => "thread-close"}}, _metadata} =
             Connection.request(connection, "thread/start", %{"cwd" => root}, 2_000)

    assert {:error,
            %TransportError{
              kind: :uncertain_external_outcome,
              details: %{operation: %{method: "thread/start", send_state: :sent}}
            }} = Connection.close(connection)
  end

  test "explicit close reports an active acknowledged turn as unresolved", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.response(1, %{"turn" => %{"id" => "turn-close"}}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"turn" => %{"id" => "turn-close"}}, _metadata} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-close", "input" => []},
               2_000
             )

    assert {:error,
            %TransportError{
              kind: :uncertain_external_outcome,
              details: %{operation: %{method: "turn/start", send_state: :sent}}
            }} = Connection.close(connection)
  end

  test "owner death while a side effect is sent emits uncertainty before cleanup", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.barrier("response-held", timeout_ms: 30_000)
      ])

    parent = self()

    owner =
      spawn(fn ->
        {:ok, connection} =
          Connection.start(fixture.argv,
            env: [{"LANG", "C.UTF-8"}],
            kill_timeout_ms: 250,
            on_transport_failure: fn error -> send(parent, {:owner_transport_failure, error}) end
          )

        send(parent, {:owner_connection, connection})

        result =
          Connection.request(
            connection,
            "turn/start",
            %{"threadId" => "thread-owner", "input" => []},
            30_000
          )

        send(parent, {:unexpected_owner_result, result})
      end)

    assert_receive {:owner_connection, connection}, 1_000
    wait_for_barrier!(fixture, "response-held")
    connection_ref = Process.monitor(connection)
    Process.exit(owner, :kill)

    assert_receive {:owner_transport_failure,
                    %TransportError{
                      kind: :uncertain_external_outcome,
                      details: %{operation: %{method: "turn/start", send_state: :sent}}
                    }},
                   2_000

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 5_000
    refute_received {:unexpected_owner_result, _result}
  end

  test "terminal delivery remains uncertain until the consumer acknowledges it", %{root: root} do
    terminal = %{
      "method" => "turn/completed",
      "params" => %{
        "threadId" => "thread-terminal-race",
        "turn" => %{"id" => "turn-terminal-race"}
      }
    }

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.response(1, %{"turn" => %{"id" => "turn-terminal-race"}}),
        FakeCodex.raw_send_json(terminal),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    parent = self()

    owner =
      spawn(fn ->
        {:ok, connection} =
          Connection.start(fixture.argv,
            env: [{"LANG", "C.UTF-8"}],
            kill_timeout_ms: 250,
            on_transport_failure: fn error -> send(parent, {:terminal_transport_failure, error}) end
          )

        {:ok, _result, _metadata} =
          Connection.request(
            connection,
            "turn/start",
            %{"threadId" => "thread-terminal-race", "input" => []},
            2_000
          )

        {:ok, %{payload: ^terminal}} = Connection.next_message(connection, 2_000)
        send(parent, {:terminal_delivered, connection})
        Process.sleep(:infinity)
      end)

    assert_receive {:terminal_delivered, connection}, 2_000
    connection_ref = Process.monitor(connection)
    Process.exit(owner, :kill)

    assert_receive {:terminal_transport_failure,
                    %TransportError{
                      kind: :uncertain_external_outcome,
                      details: %{operation: %{method: "turn/start", send_state: :sent}}
                    }},
                   2_000

    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 5_000
  end

  test "correlates a coalesced turn/start response and terminal notification atomically", %{
    root: root
  } do
    response = Jason.encode!(%{"id" => 1, "result" => %{"turn" => %{"id" => "turn-1"}}})

    terminal =
      Jason.encode!(%{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1"}
        }
      })

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.raw_stdout(response <> "\n" <> terminal <> "\n"),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"turn" => %{"id" => "turn-1"}}, _metadata} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-1", "input" => []},
               2_000
             )

    assert {:ok, %{payload: %{"method" => "turn/completed"}}} =
             Connection.next_message(connection, 2_000)

    assert :ok = Connection.ack_terminal(connection, "turn/completed")
    assert :ok = Connection.close(connection)
  end

  test "allows terminal acknowledgement after an immediate normal child exit", %{root: root} do
    terminal =
      %{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => "thread-normal-exit",
          "turn" => %{"id" => "turn-normal-exit"}
        }
      }

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "turn/start"}, match: :subset),
        FakeCodex.response(1, %{"turn" => %{"id" => "turn-normal-exit"}}),
        FakeCodex.raw_send_json(terminal),
        FakeCodex.exit(0)
      ])

    connection = start_connection!(fixture)

    assert {:ok, %{"turn" => %{"id" => "turn-normal-exit"}}, _metadata} =
             Connection.request(
               connection,
               "turn/start",
               %{"threadId" => "thread-normal-exit", "input" => []},
               2_000
             )

    assert {:ok, %{payload: ^terminal}} = Connection.next_message(connection, 2_000)
    wait_for_adapter_gone!(connection)
    assert :ok = Connection.ack_terminal(connection, "turn/completed")
    assert :ok = Connection.close(connection)
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "does not deliver a waiter message after its absolute deadline", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.barrier("late-message", timeout_ms: 30_000),
        FakeCodex.raw_send_json(%{"method" => "test/notice", "params" => %{}}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert :ok = FakeCodex.release!(fixture, "ready")
    task = Task.async(fn -> Connection.next_message(connection, 300) end)
    wait_for_waiter!(connection)
    deadline_ms = :sys.get_state(connection).waiter.deadline_ms
    :ok = :sys.suspend(connection)

    try do
      assert :ok = FakeCodex.release!(fixture, "late-message")
      sleep_past_deadline(deadline_ms)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error, %TransportError{kind: :request_timeout}} = Task.await(task, 2_000)
  end

  test "message deadline includes GenServer admission queue time", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.raw_send_json(%{"method" => "test/notice", "params" => %{}}),
        FakeCodex.barrier("message-sent", timeout_ms: 30_000),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert :ok = FakeCodex.release!(fixture, "ready")
    wait_for_barrier!(fixture, "message-sent")
    wait_for_queue_count!(connection, 1)
    :ok = :sys.suspend(connection)
    task = Task.async(fn -> Connection.next_message(connection, 100) end)

    try do
      wait_for_mailbox!(connection)
      Process.sleep(150)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error,
            %TransportError{
              kind: :request_timeout,
              details: %{phase: :message_wait}
            }} = Task.await(task, 2_000)
  end

  test "rejects stderr queued before a waiter timer once the absolute deadline passed", %{
    root: root
  } do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.barrier("ready", timeout_ms: 30_000),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert :ok = FakeCodex.release!(fixture, "ready")
    task = Task.async(fn -> Connection.next_message(connection, 300) end)
    wait_for_waiter!(connection)
    state = :sys.get_state(connection)
    deadline_ms = state.waiter.deadline_ms
    os_pid = state.adapter.os_pid
    :ok = :sys.suspend(connection)

    try do
      send(connection, {:stderr, os_pid, "authentication failed"})
      sleep_past_deadline(deadline_ms)
    after
      :ok = :sys.resume(connection)
    end

    assert {:error,
            %TransportError{
              kind: :request_timeout,
              details: %{phase: :message_wait}
            }} = Task.await(task, 2_000)

    diagnostics = Connection.diagnostics(connection)
    assert diagnostics.stderr_chunks_seen == 1
    assert diagnostics.stderr_categories == [:authentication]
  end

  test "fails closed when the retained notification queue reaches its hard cap", %{root: root} do
    frames =
      1..3
      |> Enum.map_join(fn index ->
        Jason.encode!(%{"method" => "test/notice", "params" => %{"index" => index}}) <> "\n"
      end)

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout(frames),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, max_queued_messages: 2)

    assert %TransportError{
             kind: :inbound_state_overflow,
             details: %{collection: :message_queue, limit: 2, unit: :messages}
           } = wait_for_failure!(connection)
  end

  test "fails closed when server-request deduplication reaches its hard cap", %{root: root} do
    frames =
      [
        %{"id" => "server-1", "method" => "test/request", "params" => %{}},
        %{"id" => "server-2", "method" => "test/request", "params" => %{}}
      ]
      |> Enum.map_join(&(Jason.encode!(&1) <> "\n"))

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout(frames),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, max_server_requests: 1)

    assert %TransportError{
             kind: :inbound_state_overflow,
             details: %{collection: :server_requests, limit: 1}
           } = wait_for_failure!(connection)
  end

  test "fails closed when retained server requests exceed their cumulative byte cap", %{root: root} do
    requests =
      [
        %{
          "id" => "server-bytes-1",
          "method" => "test/request",
          "params" => %{"padding" => :binary.copy("a", 64)}
        },
        %{
          "id" => "server-bytes-2",
          "method" => "test/request",
          "params" => %{"padding" => :binary.copy("b", 64)}
        }
      ]

    encoded = Enum.map(requests, &(Jason.encode!(&1) <> "\n"))
    [first, second] = encoded

    retained_bytes =
      first
      |> then(&(byte_size(&1) - 1))
      |> Kernel.+(byte_size(second) - 1)

    limit = retained_bytes - 1

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout(first <> second),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, max_server_request_bytes: limit)

    assert %TransportError{
             kind: :inbound_state_overflow,
             details: %{collection: :server_request_bytes, limit: ^limit, unit: :bytes}
           } = wait_for_failure!(connection)

    state = :sys.get_state(connection)
    assert state.server_request_bytes == 0
    assert state.server_requests == %{}
  end

  test "bounds retained server responses by the cumulative server-request byte cap", %{root: root} do
    request = %{"id" => "server-response", "method" => "test/request", "params" => %{}}
    raw_request = Jason.encode!(request) <> "\n"
    limit = byte_size(raw_request) + 64

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout(raw_request),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, max_server_request_bytes: limit)

    assert {:ok, %{payload: ^request}} = Connection.next_message(connection, 2_000)

    assert {:error,
            %TransportError{
              kind: :write_failed,
              details: %{reason: :outbound_frame_too_large}
            }} =
             Connection.respond(connection, "server-response", %{
               "padding" => :binary.copy("private-response", 32)
             })

    state = :sys.get_state(connection)
    assert state.server_request_bytes == 0
    assert state.server_requests == %{}
  end

  test "discards partial stdout bytes after a terminal framing failure", %{root: root} do
    canary = "PARTIAL-STDOUT-CANARY-#{System.unique_integer([:positive])}"

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout("{\"method\":\"#{canary}"),
        FakeCodex.exit(1)
      ])

    connection = start_connection!(fixture)
    assert %TransportError{kind: :truncated_frame} = wait_for_failure!(connection)

    state = :sys.get_state(connection)
    refute term_contains_binary?(state, canary)
    refute inspect(:sys.get_status(connection)) =~ canary
  end

  test "discards queued server requests and responses after protocol failure", %{root: root} do
    canary = "SERVER-REQUEST-CANARY-#{System.unique_integer([:positive])}"

    request =
      Jason.encode!(%{
        "id" => canary,
        "method" => "test/request",
        "params" => %{"private" => canary}
      })

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.raw_stdout(request <> "\nnot protocol\n"),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture)
    assert %TransportError{kind: :stdout_contamination} = wait_for_failure!(connection)

    state = :sys.get_state(connection)
    assert state.server_requests == %{}
    assert state.queue_count == 0
    refute term_contains_binary?(state, canary)
    refute inspect(:sys.get_status(connection)) =~ canary
  end

  test "fails closed instead of evicting completed response IDs", %{root: root} do
    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(1, %{"account" => nil}),
        FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
        FakeCodex.response(2, %{"account" => nil}),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, max_completed_request_ids: 1)
    assert {:ok, %{"account" => nil}, _metadata} = Connection.request(connection, "account/read", %{}, 2_000)

    assert {:error,
            %TransportError{
              kind: :inbound_state_overflow,
              details: %{collection: :completed_request_ids, limit: 1}
            }} = Connection.request(connection, "account/read", %{}, 2_000)
  end

  test "cleans a TERM-resistant descendant when the group leader exits naturally" do
    python =
      "import json,os,signal,time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "print(json.dumps({'method':'test/pid','params':{'pid':os.getpid()}}), flush=True); " <>
        "time.sleep(60)"

    script = "/usr/bin/python3 -c #{inspect(python)} & sleep 0.20; exit 0"

    {:ok, connection} =
      Connection.start(["/bin/sh", "-c", script],
        env: [{"PATH", "/usr/bin:/bin"}],
        kill_timeout_ms: 150
      )

    assert {:ok, %{payload: %{"params" => %{"pid" => namespace_child_pid}}}} =
             Connection.next_message(connection, 1_000)

    assert is_integer(namespace_child_pid)
    adapter = :sys.get_state(connection).adapter
    child_pid = host_pid_for_namespace_pid(adapter, namespace_child_pid)
    assert os_process_exists?(child_pid)
    assert %TransportError{kind: :process_exit} = wait_for_failure!(connection)
    refute_process_exists(child_pid)
    assert :ok = Connection.close(connection)
  end

  test "promotes cleanup failure to a top-level non-retryable blocker", %{root: root} do
    {:ok, stop_counter} = Agent.start(fn -> 0 end)
    previous_counter = Application.get_env(:symphony_elixir, :fail_first_stop_counter)
    Application.put_env(:symphony_elixir, :fail_first_stop_counter, stop_counter)

    on_exit(fn ->
      if is_nil(previous_counter) do
        Application.delete_env(:symphony_elixir, :fail_first_stop_counter)
      else
        Application.put_env(:symphony_elixir, :fail_first_stop_counter, previous_counter)
      end
    end)

    fixture =
      FakeCodex.create!(root, [
        FakeCodex.expect(%{"id" => 1, "method" => "account/read", "params" => %{}}),
        FakeCodex.raw_stdout("not protocol\n"),
        FakeCodex.barrier("hold", timeout_ms: 30_000)
      ])

    connection = start_connection!(fixture, process_adapter: FailFirstStopAdapter)

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{cause: %{kind: :stdout_contamination}}
            } = error} = Connection.request(connection, "account/read", %{}, 2_000)

    refute inspect(error) =~ FailFirstStopAdapter.canary()
    wait_for_cleanup_verified!(connection)
    assert :ok = Connection.close(connection)
  end

  defp start_connection!(fixture, opts \\ []) do
    defaults = [
      env: [{"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}],
      kill_timeout_ms: 250,
      max_frame_bytes: 16_777_216,
      stderr_tail_bytes: 1_024
    ]

    {:ok, connection} = Connection.start(fixture.argv, Keyword.merge(defaults, opts))

    on_exit(fn ->
      if Process.alive?(connection), do: Connection.close(connection)
    end)

    connection
  end

  defp wait_for_failure!(connection, attempts \\ 400)

  defp wait_for_failure!(_connection, 0), do: flunk("connection did not enter a failed state")

  defp wait_for_failure!(connection, attempts) do
    case :sys.get_state(connection).failure do
      %TransportError{} = failure ->
        failure

      nil ->
        Process.sleep(5)
        wait_for_failure!(connection, attempts - 1)
    end
  end

  defp wait_for_waiter!(connection, attempts \\ 100)

  defp wait_for_waiter!(_connection, 0), do: flunk("connection did not install a message waiter")

  defp wait_for_waiter!(connection, attempts) do
    if :sys.get_state(connection).waiter do
      :ok
    else
      Process.sleep(5)
      wait_for_waiter!(connection, attempts - 1)
    end
  end

  defp wait_for_queue_count!(connection, expected, attempts \\ 400)

  defp wait_for_queue_count!(_connection, expected, 0),
    do: flunk("connection queue did not reach #{expected} messages")

  defp wait_for_queue_count!(connection, expected, attempts) do
    if :sys.get_state(connection).queue_count == expected do
      :ok
    else
      Process.sleep(5)
      wait_for_queue_count!(connection, expected, attempts - 1)
    end
  end

  defp wait_for_mailbox!(connection, attempts \\ 100)

  defp wait_for_mailbox!(_connection, 0),
    do: flunk("connection did not receive the queued call")

  defp wait_for_mailbox!(connection, attempts) do
    case Process.info(connection, :message_queue_len) do
      {:message_queue_len, length} when length > 0 ->
        :ok

      _other ->
        Process.sleep(5)
        wait_for_mailbox!(connection, attempts - 1)
    end
  end

  defp wait_for_adapter_gone!(connection, attempts \\ 200)

  defp wait_for_adapter_gone!(_connection, 0), do: flunk("connection adapter remained active")

  defp wait_for_adapter_gone!(connection, attempts) do
    state = :sys.get_state(connection)

    cond do
      state.failure ->
        flunk("connection failed before terminal acknowledgement: #{inspect(state.failure)}")

      is_nil(state.adapter) ->
        :ok

      true ->
        Process.sleep(5)
        wait_for_adapter_gone!(connection, attempts - 1)
    end
  end

  defp wait_for_cleanup_verified!(connection, attempts \\ 200)

  defp wait_for_cleanup_verified!(_connection, 0),
    do: flunk("cleanup guardian did not verify adapter retirement")

  defp wait_for_cleanup_verified!(connection, attempts) do
    if is_nil(:sys.get_state(connection).adapter) do
      :ok
    else
      Process.sleep(5)
      wait_for_cleanup_verified!(connection, attempts - 1)
    end
  end

  defp wait_for_guardian_handoff!(connection, attempts \\ 500)

  defp wait_for_guardian_handoff!(_connection, 0),
    do: flunk("cleanup guardian did not enter persistent handoff")

  defp wait_for_guardian_handoff!(connection, attempts) do
    state = :sys.get_state(connection)

    if state.cleanup_guardian_handed_off? do
      state
    else
      Process.sleep(10)
      wait_for_guardian_handoff!(connection, attempts - 1)
    end
  end

  defp await_registered_replacement(name, old_pid, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_registered_replacement(name, old_pid, deadline_ms)
  end

  defp do_await_registered_replacement(name, old_pid, deadline_ms) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _pending ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(10)
          do_await_registered_replacement(name, old_pid, deadline_ms)
        else
          flunk("#{inspect(name)} did not restart after cleanup handoff")
        end
    end
  end

  defp wait_for_barrier!(fixture, name, attempts \\ 400)

  defp wait_for_barrier!(_fixture, name, 0), do: flunk("barrier #{inspect(name)} was not reached")

  defp wait_for_barrier!(fixture, name, attempts) do
    waiting_path = Path.join([fixture.root, "barriers", "#{name}.waiting"])

    if File.exists?(waiting_path) do
      :ok
    else
      Process.sleep(5)
      wait_for_barrier!(fixture, name, attempts - 1)
    end
  end

  defp host_pid_for_namespace_pid(adapter, namespace_pid, attempts \\ 100)

  defp host_pid_for_namespace_pid(adapter, namespace_pid, attempts) when attempts > 0 do
    host_pid =
      "/proc/[0-9]*/ns/pid"
      |> Path.wildcard()
      |> Enum.find_value(fn path ->
        with {:ok, pid_namespace} <- File.read_link(path),
             true <- pid_namespace == adapter.namespace_root.pid_namespace,
             {host_pid, ""} <- path |> namespace_host_pid() |> Integer.parse(),
             ^namespace_pid <- namespace_pid_for_host_pid(host_pid) do
          host_pid
        else
          _other -> nil
        end
      end)

    if is_integer(host_pid) do
      host_pid
    else
      Process.sleep(10)
      host_pid_for_namespace_pid(adapter, namespace_pid, attempts - 1)
    end
  end

  defp host_pid_for_namespace_pid(_adapter, namespace_pid, 0),
    do: flunk("namespace PID #{namespace_pid} was not visible in the managed namespace")

  defp namespace_pid_for_host_pid(host_pid) do
    with {:ok, status} <- File.read("/proc/#{host_pid}/status"),
         line when is_binary(line) <-
           Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "NSpid:")),
         [_host_pid, _namespace_pid | _rest] = identifiers <-
           line
           |> String.replace_prefix("NSpid:", "")
           |> String.split()
           |> Enum.map(&String.to_integer/1) do
      List.last(identifiers)
    else
      _other -> nil
    end
  end

  defp namespace_host_pid(path) do
    path
    |> Path.dirname()
    |> Path.dirname()
    |> Path.basename()
  end

  defp refute_process_exists(pid, attempts \\ 100)

  defp refute_process_exists(pid, attempts) when attempts > 0 do
    if os_process_exists?(pid) do
      Process.sleep(20)
      refute_process_exists(pid, attempts - 1)
    else
      refute os_process_exists?(pid)
    end
  end

  defp refute_process_exists(pid, 0), do: refute(os_process_exists?(pid))

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when is_function(fun, 0) and attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(fun, 0) when is_function(fun, 0), do: fun.()

  defp os_process_exists?(pid), do: File.exists?("/proc/#{pid}/stat")

  defp term_contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp term_contains_binary?(term, needle) when is_struct(term),
    do: term |> Map.from_struct() |> term_contains_binary?(needle)

  defp term_contains_binary?(term, needle) when is_map(term),
    do: Enum.any?(term, fn {key, value} -> term_contains_binary?(key, needle) or term_contains_binary?(value, needle) end)

  defp term_contains_binary?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> term_contains_binary?(needle)

  defp term_contains_binary?(term, needle) when is_list(term),
    do: Enum.any?(term, &term_contains_binary?(&1, needle))

  defp term_contains_binary?(_term, _needle), do: false

  defp flush_controlled_stop_attempts do
    receive do
      {:controlled_stop_attempt, _worker, _allowed?} -> flush_controlled_stop_attempts()
    after
      0 -> :ok
    end
  end

  defp sleep_past_deadline(deadline_ms) do
    remaining_ms = deadline_ms - System.monotonic_time(:millisecond)
    Process.sleep(max(remaining_ms + 50, 50))
  end
end
