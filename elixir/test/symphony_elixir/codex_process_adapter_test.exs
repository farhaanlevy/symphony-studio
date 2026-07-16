# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CodexProcessAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.{CleanupGuardian, ProcessAdapter}
  alias SymphonyElixir.Codex.ProcessAdapter.CleanupEvidence
  alias SymphonyElixir.Codex.ProcessAdapter.IdentityTracker
  alias SymphonyElixir.Codex.ProcessAdapter.StartupCleanup

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  test "startup cleanup handoff retains the real partial handle until proof succeeds" do
    manager = spawn(fn -> Process.sleep(:infinity) end)
    manager_ref = Process.monitor(manager)

    cleanup = %StartupCleanup{
      pid: manager,
      process_group_id: 2_000_000_000,
      namespace_root: nil
    }

    assert {:error, {:startup_cleanup_unverified, evidence}} =
             ProcessAdapter.stop(cleanup, 0)

    assert evidence.manager_alive
    assert evidence.group_empty
    assert evidence.namespace_kill == :not_captured

    handle = CleanupGuardian.start_handle(self(), ProcessAdapter, cleanup, 0)
    guardian_ref = Process.monitor(handle.pid)
    :ok = CleanupGuardian.request_cleanup(handle)

    refute CleanupGuardian.verified?(handle)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^manager_ref, :process, ^manager, :killed}, 1_000

    send(handle.pid, :retry_cleanup)
    assert_receive {:cleanup_guardian_verified, guardian}, 1_000
    assert guardian == handle.pid
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    assert CleanupGuardian.verified?(handle)
  end

  test "keeps stdout and stderr distinct and accepts stdin" do
    script = ~S"""
    IFS= read -r line
    printf 'out:%s\n' "$line"
    printf 'err:%s\n' "$line" >&2
    """

    assert {:ok, adapter} =
             ProcessAdapter.start(["/bin/sh", "-c", script],
               env: [{"PATH", "/usr/bin:/bin"}]
             )

    assert ProcessAdapter.alive?(adapter)
    assert :ok = ProcessAdapter.send(adapter, "hello\n")

    {stdout, stderr, exit_reason} = collect_until_exit(adapter)

    assert stdout == "out:hello\n"
    assert stderr == "err:hello\n"
    assert exit_reason == :normal

    metadata = ProcessAdapter.metadata(adapter)
    assert metadata.pid == adapter.pid
    assert metadata.os_pid == adapter.os_pid
    assert metadata.process_group_id == adapter.os_pid
    assert metadata.namespace_root_pid == adapter.namespace_root.pid
    assert metadata.target_pid == adapter.target_identity.pid
    refute metadata.target_pid == metadata.os_pid
    assert metadata.owner == self()
  end

  test "clears the ambient environment and passes only explicit pairs" do
    canary_name = "SYMPHONY_PROCESS_ADAPTER_CANARY"
    previous_canary = System.get_env(canary_name)
    System.put_env(canary_name, "must-not-leak")

    try do
      assert {:ok, adapter} =
               ProcessAdapter.start(["/usr/bin/env"],
                 env: [{"SYMPHONY_ALLOWED", "visible"}]
               )

      {stdout, "", :normal} = collect_until_exit(adapter)
      lines = String.split(stdout, "\n", trim: true)

      assert lines == ["SYMPHONY_ALLOWED=visible"]

      assert {:ok, locale_adapter} =
               ProcessAdapter.start(["/usr/bin/env"],
                 env: [{"LC_CTYPE", "C"}, {"SYMPHONY_ALLOWED", "visible"}]
               )

      {locale_stdout, "", :normal} = collect_until_exit(locale_adapter)

      assert locale_stdout
             |> String.split("\n", trim: true)
             |> Enum.sort() == ["LC_CTYPE=C", "SYMPHONY_ALLOWED=visible"]

      invalid_secret = "invalid-value-must-not-be-reflected"

      assert {:error, validation_error} =
               ProcessAdapter.start(["/usr/bin/env"], env: [{"INVALID-NAME", invalid_secret}])

      refute inspect(validation_error) =~ invalid_secret

      assert {:error, {:invalid_env, :pair_too_large}} =
               ProcessAdapter.start(["/usr/bin/env"],
                 env: [{"TOO_LARGE", :binary.copy("x", 131_070)}]
               )

      aggregate_environment =
        for index <- 1..9 do
          {"SYMPHONY_LARGE_#{index}", :binary.copy("x", 120_000)}
        end

      assert {:error, {:invalid_env, :aggregate_too_large}} =
               ProcessAdapter.start(["/usr/bin/env"], env: aggregate_environment)

      assert {:error, {:invalid_argv, :argument_too_large}} =
               ProcessAdapter.start(["/bin/echo", :binary.copy("x", 131_072)])

      combined_environment = Enum.take(aggregate_environment, 8)

      assert {:error, {:invalid_process_payload, :too_large}} =
               ProcessAdapter.start(["/bin/echo", :binary.copy("x", 100_000)],
                 env: combined_environment
               )
    after
      restore_env(canary_name, previous_canary)
    end
  end

  test "keeps target loader controls out of every trusted outer helper" do
    script = ~S"""
    printf '%s:%s\n' "$SYMPHONY_TARGET_ONLY" "$LD_LIBRARY_PATH"
    IFS= read -r _line
    """

    assert {:ok, adapter} =
             ProcessAdapter.start(["/bin/sh", "-c", script],
               env: [
                 {"SYMPHONY_TARGET_ONLY", "visible"},
                 {"LD_LIBRARY_PATH", "/target-only/loader-path"}
               ]
             )

    try do
      assert_receive {:stdout, os_pid, "visible:/target-only/loader-path\n"}
                     when os_pid == adapter.os_pid,
                     1_000

      assert {:ok, ""} = File.read("/proc/#{adapter.os_pid}/environ")
      assert :ok = ProcessAdapter.send(adapter, "done\n")
      assert {"", "", :normal} = collect_until_exit(adapter)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "passes argv literally without shell evaluation" do
    marker =
      Path.join(
        System.tmp_dir!(),
        "symphony-process-adapter-#{System.unique_integer([:positive])}"
      )

    argument = "$(touch #{marker});$HOME"

    assert {:ok, adapter} = ProcessAdapter.start(["/bin/echo", argument])
    {stdout, "", :normal} = collect_until_exit(adapter)

    assert stdout == argument <> "\n"
    refute File.exists?(marker)
  end

  test "send uses the stable manager handle instead of a stale numeric OS pid" do
    assert {:ok, first_adapter} = ProcessAdapter.start(["/bin/cat"])
    assert {:ok, second_adapter} = ProcessAdapter.start(["/bin/cat"])
    stale_numeric_adapter = %{first_adapter | os_pid: second_adapter.os_pid}
    first_os_pid = first_adapter.os_pid
    second_os_pid = second_adapter.os_pid

    try do
      assert :ok = ProcessAdapter.send(stale_numeric_adapter, "stable-manager\n")

      assert_receive {:stdout, ^first_os_pid, "stable-manager\n"}, 1_000

      refute_receive {:stdout, ^second_os_pid, "stable-manager\n"}, 100
    after
      ProcessAdapter.stop(first_adapter, 2_000)
      ProcessAdapter.stop(second_adapter, 2_000)
    end
  end

  test "reports normal and nonzero linked exits without rewriting erlexec messages" do
    assert {:ok, normal_adapter} = ProcessAdapter.start(["/bin/sh", "-c", "exit 0"])
    normal_pid = normal_adapter.pid
    assert_receive {:EXIT, ^normal_pid, :normal}, 1_000

    assert {:ok, failure_adapter} = ProcessAdapter.start(["/bin/sh", "-c", "exit 7"])
    failure_pid = failure_adapter.pid
    raw_failure_status = 7 * 256
    assert_receive {:EXIT, ^failure_pid, {:exit_status, ^raw_failure_status}}, 1_000
  end

  test "owner death terminates the linked process and its descendant group" do
    parent = self()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)

        script = "sleep 60 & child=$!; printf '%s\\n' \"$child\"; wait \"$child\""

        {:ok, adapter} =
          ProcessAdapter.start(["/bin/sh", "-c", script],
            env: [{"PATH", "/usr/bin:/bin"}],
            kill_timeout_ms: 200
          )

        Kernel.send(parent, {:owner_started, self(), adapter})

        receive do
          {:stdout, os_pid, data} when os_pid == adapter.os_pid ->
            Kernel.send(parent, {:owner_stdout, self(), data})
        end

        Process.sleep(:infinity)
      end)

    owner_monitor = Process.monitor(owner)

    assert_receive {:owner_started, ^owner, adapter}, 1_000
    assert_receive {:owner_stdout, ^owner, child_output}, 1_000
    namespace_child_pid = child_output |> String.trim() |> String.to_integer()
    child_pid = host_pid_for_namespace_pid(adapter, namespace_child_pid)

    try do
      assert os_process_exists?(adapter.os_pid)
      assert os_process_exists?(child_pid)

      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000
      refute_process_exists(adapter.os_pid)
      refute_process_exists(child_pid)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "stop kills a TERM-resistant descendant after its group leader exits" do
    python =
      "import os,signal,time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "print(os.getpid(), flush=True); time.sleep(60)"

    script = "/usr/bin/python3 -c '#{python}' & child=$!; wait \"$child\""

    assert {:ok, adapter} =
             ProcessAdapter.start(["/bin/sh", "-c", script], kill_timeout_ms: 150)

    assert_receive {:stdout, os_pid, child_output} when os_pid == adapter.os_pid, 1_000
    namespace_child_pid = child_output |> String.trim() |> String.to_integer()
    child_pid = host_pid_for_namespace_pid(adapter, namespace_child_pid)

    try do
      assert os_process_exists?(child_pid)
      assert :ok = ProcessAdapter.stop(adapter, 2_000)
      refute_process_exists(adapter.os_pid)
      refute_process_exists(child_pid)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "containment anchor cleans a resistant descendant after an unobserved leader exit" do
    python =
      "import os,signal,time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "print(os.getpid(), flush=True); time.sleep(60)"

    script = "/usr/bin/python3 -c '#{python}' & sleep 0.05; exit 0"

    assert {:ok, adapter} =
             ProcessAdapter.start(["/bin/sh", "-c", script], kill_timeout_ms: 100)

    assert_receive {:stdout, os_pid, child_output} when os_pid == adapter.os_pid, 1_000
    namespace_child_pid = child_output |> String.trim() |> String.to_integer()
    assert namespace_child_pid == 3
    manager_pid = adapter.pid

    assert_receive {:EXIT, ^manager_pid, :normal}, 1_000
    sentinel_ref = make_ref()
    send(self(), {:DOWN, sentinel_ref, :process, self(), :sentinel})
    assert :ok = ProcessAdapter.stop(adapter, 2_000)
    assert_receive {:DOWN, ^sentinel_ref, :process, _pid, :sentinel}, 0
    refute_receive {:DOWN, _ref, :process, ^manager_pid, _reason}, 0
    assert :retired = IdentityTracker.group_state(adapter.identity_tracker)
  end

  test "stop remains bounded when the process ignores TERM" do
    canary_name = "SYMPHONY_PIDFD_HELPER_ENV_CANARY"
    previous_canary = System.get_env(canary_name)
    System.put_env(canary_name, "must-not-reach-cleanup-helper")
    on_exit(fn -> restore_env(canary_name, previous_canary) end)

    python =
      "import signal,time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "print('ready', flush=True); time.sleep(60)"

    assert {:ok, adapter} =
             ProcessAdapter.start(["/usr/bin/python3", "-c", python],
               kill_timeout_ms: 5_000
             )

    assert_receive {:stdout, os_pid, "ready\n"} when os_pid == adapter.os_pid, 1_000

    started_at_ms = System.monotonic_time(:millisecond)
    manager_pid = adapter.pid
    sentinel_ref = make_ref()
    send(self(), {:DOWN, sentinel_ref, :process, self(), :sentinel})

    try do
      assert :ok = ProcessAdapter.stop(adapter, 400)
      elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

      assert elapsed_ms < 1_000
      assert CleanupEvidence.complete?(false, [], :retired)
      refute CleanupEvidence.complete?(true, [], :retired)
      refute CleanupEvidence.complete?(false, [%{pid: adapter.os_pid}], :retired)
      refute CleanupEvidence.complete?(false, :unavailable, :retired)
      refute CleanupEvidence.complete?(false, [], %{pid: adapter.namespace_root.pid})

      refute CleanupEvidence.complete?(
               false,
               [],
               {:identity_check_failed, :process_identity_unavailable}
             )

      assert_receive {:DOWN, ^sentinel_ref, :process, _pid, :sentinel}, 0
      refute_receive {:DOWN, _ref, :process, ^manager_pid, _reason}, 0
      refute_process_exists(adapter.os_pid)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "containment and pidfd helpers ignore workspace Python startup hooks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-process-adapter-sitecustomize-#{System.unique_integer([:positive])}"
      )

    try do
      marker = Path.join(test_root, "sitecustomize-ran")
      File.mkdir_p!(test_root)

      File.write!(
        Path.join(test_root, "sitecustomize.py"),
        "open(#{inspect(marker)}, 'wb').write(b'hijacked')\n"
      )

      assert {:ok, adapter} =
               ProcessAdapter.start(
                 ["/bin/sh", "-c", "printf 'ready\\n'; trap '' TERM; sleep 60"],
                 cd: test_root,
                 env: [{"PATH", "/usr/bin:/bin"}, {"PYTHONPATH", test_root}],
                 kill_timeout_ms: 100
               )

      assert_receive {:stdout, os_pid, "ready\n"} when os_pid == adapter.os_pid, 1_000
      refute File.exists?(marker)

      assert :ok = ProcessAdapter.stop(adapter, 2_000)
      refute File.exists?(marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "managed target cannot ptrace the trusted namespace root" do
    python = ~S"""
    import ctypes
    import time

    libc = ctypes.CDLL(None, use_errno=True)
    ctypes.set_errno(0)
    result = libc.ptrace(0x4206, 1, 0, 0)
    print(f"{result}:{ctypes.get_errno()}", flush=True)
    time.sleep(60)
    """

    assert {:ok, adapter} =
             ProcessAdapter.start(["/usr/bin/python3", "-c", python],
               kill_timeout_ms: 100
             )

    try do
      assert_receive {:stdout, os_pid, "-1:1\n"} when os_pid == adapter.os_pid, 1_000
      assert os_process_exists?(adapter.namespace_root.pid)
      assert :ok = ProcessAdapter.stop(adapter, 2_000)
      refute_process_exists(adapter.namespace_root.pid)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "managed child cannot see or signal the outer containment anchor" do
    python = ~S"""
    import os
    import signal
    import sys
    import time

    outer_pid = int(sys.stdin.readline().strip())
    try:
        os.kill(outer_pid, signal.SIGKILL)
        outcome = "unexpected-signal"
    except ProcessLookupError:
        outcome = "isolated"
    except PermissionError:
        outcome = "blocked"
    os.kill(0, signal.SIGCONT)
    print(f"{outcome}:{os.getpid()}", flush=True)
    time.sleep(60)
    """

    assert {:ok, adapter} =
             ProcessAdapter.start(["/usr/bin/python3", "-c", python],
               kill_timeout_ms: 100
             )

    anchor = adapter.identity_tracker.anchor

    try do
      assert os_process_exists?(anchor.pid)

      assert {"", 0} =
               System.cmd("/bin/kill", ["-STOP", Integer.to_string(anchor.pid)], stderr_to_stdout: true)

      wait_for_process_state(anchor.pid, ["T", "t"])
      assert :ok = ProcessAdapter.send(adapter, "#{anchor.pid}\n")

      assert_receive {:stdout, os_pid, isolation_output} when os_pid == adapter.os_pid, 1_000
      assert String.trim(isolation_output) in ["isolated:2", "blocked:2"]
      assert os_process_exists?(anchor.pid)
      assert process_state(anchor.pid) in ["T", "t"]

      assert {"", 0} =
               System.cmd("/bin/kill", ["-CONT", Integer.to_string(anchor.pid)], stderr_to_stdout: true)

      assert :ok = ProcessAdapter.stop(adapter, 2_000)
    after
      System.cmd("/bin/kill", ["-CONT", Integer.to_string(anchor.pid)], stderr_to_stdout: true)
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "inner group attack cannot kill the supervisor or orphan a setsid descendant" do
    python = ~S"""
    import os
    import signal
    import sys
    import time

    child = os.fork()
    if child == 0:
        os.setsid()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print(f"descendant:{os.getpid()}", flush=True)
        while True:
            time.sleep(1)

    if sys.stdin.readline().strip() == "attack":
        os.kill(0, signal.SIGKILL)
    """

    assert {:ok, adapter} =
             ProcessAdapter.start(["/usr/bin/python3", "-c", python],
               kill_timeout_ms: 100
             )

    assert_receive {:stdout, os_pid, output} when os_pid == adapter.os_pid, 1_000
    ["descendant", namespace_pid] = output |> String.trim() |> String.split(":", parts: 2)
    descendant_pid = host_pid_for_namespace_pid(adapter, String.to_integer(namespace_pid))
    namespace_root = adapter.namespace_root
    anchor = adapter.identity_tracker.anchor

    try do
      assert os_process_exists?(adapter.os_pid)
      assert os_process_exists?(namespace_root.pid)
      assert os_process_exists?(anchor.pid)
      assert os_process_exists?(descendant_pid)

      assert :ok = ProcessAdapter.send(adapter, "attack\n")
      assert :ok = ProcessAdapter.stop(adapter, 2_000)

      refute_process_exists(adapter.os_pid)
      refute_process_exists(namespace_root.pid)
      refute_process_exists(anchor.pid)
      refute_process_exists(descendant_pid)
      assert :retired = IdentityTracker.exact_identity_state(namespace_root)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "stop retains verified cleanup authority after the containment anchor is killed" do
    python =
      "import os,signal,time; " <>
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); " <>
        "child=os.fork(); " <>
        "print(child if child else os.getpid(), flush=True) if child else None; " <>
        "time.sleep(60)"

    assert {:ok, adapter} =
             ProcessAdapter.start(["/usr/bin/python3", "-c", python],
               kill_timeout_ms: 100
             )

    assert_receive {:stdout, os_pid, child_output} when os_pid == adapter.os_pid, 1_000
    namespace_child_pid = child_output |> String.trim() |> String.to_integer()
    child_pid = host_pid_for_namespace_pid(adapter, namespace_child_pid)
    anchor = adapter.identity_tracker.anchor

    try do
      assert os_process_exists?(adapter.os_pid)
      assert os_process_exists?(child_pid)
      assert os_process_exists?(anchor.pid)

      assert {"", 0} =
               System.cmd("/bin/kill", ["-KILL", Integer.to_string(anchor.pid)], stderr_to_stdout: true)

      wait_for_zombie_or_exit(anchor.pid)

      assert :ok = ProcessAdapter.stop(adapter, 2_000)
      refute_process_exists(adapter.os_pid)
      refute_process_exists(child_pid)
      refute_process_exists(anchor.pid)
    after
      ProcessAdapter.stop(adapter, 2_000)
    end
  end

  test "identity tracker follows known descendants but never authorizes a reused group" do
    process_group_id = 41_000
    session_id = 7_000
    leader = process_identity(process_group_id, 100, process_group_id, session_id)
    child = process_identity(process_group_id + 1, 200, process_group_id, session_id)
    {:ok, snapshot} = Agent.start_link(fn -> [leader, child] end)
    reader = fn ^process_group_id -> {:ok, Agent.get(snapshot, & &1)} end

    assert {:ok, tracker} =
             IdentityTracker.start(leader,
               proc_reader: reader,
               poll_interval_ms: 60_000
             )

    {:links, links} = Process.info(self(), :links)
    refute tracker.pid in links

    assert {:active, initial_members} = IdentityTracker.group_state(tracker)
    assert Enum.map(initial_members, & &1.pid) |> Enum.sort() == [leader.pid, child.pid]

    Agent.update(snapshot, fn _members -> [child] end)

    assert :signal_authorized =
             IdentityTracker.with_current_group(tracker, 250, fn ^process_group_id ->
               Kernel.send(self(), :original_group_signal)
               :signal_authorized
             end)

    assert_receive :original_group_signal

    reused_leader = %{leader | start_time: leader.start_time + 1}
    reused_child = %{child | start_time: child.start_time + 1}
    reused_member = process_identity(process_group_id + 2, 300, process_group_id, session_id)
    Agent.update(snapshot, fn _members -> [reused_leader, reused_child, reused_member] end)

    assert :retired =
             IdentityTracker.with_current_group(tracker, 250, fn _group_id ->
               Kernel.send(self(), :reused_group_signal)
             end)

    refute_receive :reused_group_signal
    refute Process.alive?(tracker.pid)
  end

  test "identity tracker never learns a wholly reused group before its first refresh" do
    process_group_id = 42_000
    session_id = 8_000
    leader = process_identity(process_group_id, 400, process_group_id, session_id)
    replacement = %{leader | start_time: leader.start_time + 1}
    reader = fn ^process_group_id -> {:ok, [replacement]} end

    assert {:ok, tracker} =
             IdentityTracker.start(leader,
               proc_reader: reader,
               poll_interval_ms: 60_000
             )

    assert :retired =
             IdentityTracker.with_current_group(tracker, 250, fn _group_id ->
               Kernel.send(self(), :wholly_reused_group_signal)
             end)

    refute_receive :wholly_reused_group_signal
  end

  test "identity tracker blocks on an unproven descendant continuity gap" do
    process_group_id = 42_500
    session_id = 8_500
    leader = process_identity(process_group_id, 450, process_group_id, session_id)
    {:ok, snapshot} = Agent.start_link(fn -> [leader] end)
    reader = fn ^process_group_id -> {:ok, Agent.get(snapshot, & &1)} end

    assert {:ok, tracker} =
             IdentityTracker.start(leader,
               proc_reader: reader,
               poll_interval_ms: 60_000
             )

    assert {:active, [_leader]} = IdentityTracker.group_state(tracker)

    unobserved_descendant =
      process_identity(process_group_id + 1, 451, process_group_id, session_id)

    Agent.update(snapshot, fn _members -> [unobserved_descendant] end)

    assert {:error, :process_group_identity_discontinuity} =
             IdentityTracker.with_current_group(tracker, 250, fn _group_id ->
               Kernel.send(self(), :unproven_descendant_signal)
             end)

    refute_receive :unproven_descendant_signal
    Agent.update(snapshot, fn _members -> [] end)
    assert :retired = IdentityTracker.group_state(tracker)
    refute Process.alive?(tracker.pid)
  end

  test "identity tracker refuses signals and stops after bounded proc read exhaustion" do
    process_group_id = 43_000
    leader = process_identity(process_group_id, 500, process_group_id, 9_000)
    reader = fn ^process_group_id -> {:error, :injected_proc_failure} end

    assert {:ok, tracker} =
             IdentityTracker.start(leader,
               proc_reader: reader,
               poll_interval_ms: 60_000
             )

    for expected <- [:proc_read_failed, :proc_read_failed, :identity_tracking_exhausted] do
      assert {:error, ^expected} =
               IdentityTracker.with_current_group(tracker, 250, fn _group_id ->
                 Kernel.send(self(), :unverified_group_signal)
               end)
    end

    refute_receive :unverified_group_signal
    refute Process.alive?(tracker.pid)
    assert {:error, :identity_tracking_exhausted} = IdentityTracker.group_state(tracker)
  end

  defp collect_until_exit(adapter, stdout \\ "", stderr \\ "") do
    receive do
      {:stdout, os_pid, data} when os_pid == adapter.os_pid ->
        collect_until_exit(adapter, stdout <> data, stderr)

      {:stderr, os_pid, data} when os_pid == adapter.os_pid ->
        collect_until_exit(adapter, stdout, stderr <> data)

      {:EXIT, pid, reason} when pid == adapter.pid ->
        {stdout, stderr, reason}
    after
      2_000 -> flunk("managed process did not exit")
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp process_identity(pid, start_time, process_group_id, session_id) do
    %{
      pid: pid,
      state: "S",
      process_group_id: process_group_id,
      session_id: session_id,
      start_time: start_time
    }
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

  defp wait_for_zombie_or_exit(pid, attempts \\ 100)

  defp wait_for_zombie_or_exit(pid, attempts) when attempts > 0 do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} ->
        :ok

      {:ok, contents} ->
        if String.contains?(contents, ") Z ") do
          :ok
        else
          Process.sleep(10)
          wait_for_zombie_or_exit(pid, attempts - 1)
        end
    end
  end

  defp wait_for_zombie_or_exit(pid, 0),
    do: flunk("process #{pid} did not become a zombie or exit")

  defp wait_for_process_state(pid, states, attempts \\ 100)

  defp wait_for_process_state(pid, states, attempts) when attempts > 0 do
    if process_state(pid) in states do
      :ok
    else
      Process.sleep(10)
      wait_for_process_state(pid, states, attempts - 1)
    end
  end

  defp wait_for_process_state(pid, states, 0),
    do: flunk("process #{pid} did not enter one of #{inspect(states)}")

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

  defp process_state(pid) do
    with {:ok, contents} <- File.read("/proc/#{pid}/stat"),
         [{closing_index, 2} | _rest] <-
           contents |> :binary.matches(") ") |> Enum.reverse(),
         trailing <- binary_part(contents, closing_index + 2, byte_size(contents) - closing_index - 2),
         [state | _rest] <- :binary.split(trailing, " ", [:global]) do
      state
    else
      _other -> nil
    end
  end

  defp os_process_exists?(pid), do: File.exists?("/proc/#{pid}/stat")
end
