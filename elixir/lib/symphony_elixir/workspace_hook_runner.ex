# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio contains hooks,
# allowlists their environment, bounds output, and verifies descendant cleanup.

defmodule SymphonyElixir.WorkspaceHookRunner do
  @moduledoc false

  alias SymphonyElixir.Codex.{CleanupBarrier, CleanupGuardian, ProcessAdapter}

  @allowed_environment_names ~w(HOME LANG LC_ALL LC_CTYPE LOGNAME PATH SOURCE_REPO_URL TERM TMPDIR USER)
  @default_output_limit_bytes 65_536
  @cleanup_timeout_ms 2_000
  @hook_kill_grace_ms 0
  @runner_overhead_ms 8_000
  @supervisor SymphonyElixir.WorkspaceHookSupervisor

  @typedoc "Content-free hook output accounting."
  @type output_summary :: %{
          stdout_bytes: non_neg_integer(),
          stderr_bytes: non_neg_integer(),
          truncated: boolean()
        }

  @doc "Runs a local workspace hook with a cleared, explicitly allowlisted environment."
  @spec run(String.t(), Path.t(), String.t(), pos_integer(), keyword()) ::
          :ok | {:error, term()}
  def run(command, workspace, hook_name, timeout_ms, opts \\ [])
      when is_binary(command) and is_binary(workspace) and is_binary(hook_name) and
             is_integer(timeout_ms) and timeout_ms > 0 and is_list(opts) do
    output_limit_bytes = Keyword.get(opts, :output_limit_bytes, @default_output_limit_bytes)
    owner = self()
    observer = Keyword.get(opts, :observer)
    result_ref = make_ref()
    begin_ref = make_ref()

    runner_fun = fn ->
      Process.flag(:trap_exit, true)
      register_runtime_member!()
      owner_monitor = Process.monitor(owner)
      maybe_notify(observer, {:workspace_hook_runner_started, self()})

      result =
        try do
          await_begin(
            begin_ref,
            owner,
            owner_monitor,
            fn ->
              run_owned(
                command,
                workspace,
                hook_name,
                timeout_ms,
                output_limit_bytes,
                owner,
                owner_monitor,
                result_ref
              )
            end,
            hook_name
          )
        rescue
          _error -> {:error, {:workspace_hook_runner_failed, hook_name}}
        catch
          _kind, _reason -> {:error, {:workspace_hook_runner_failed, hook_name}}
        end

      complete_runner(result, owner, result_ref, observer, hook_name)
    end

    with {:ok, runner} <- start_runner(runner_fun, hook_name) do
      Process.link(runner)
      monitor_ref = Process.monitor(runner)
      send(runner, {:workspace_hook_runner_begin, begin_ref})

      receive do
        {^result_ref, result} ->
          Process.unlink(runner)
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^runner, _reason} ->
          {:error, {:workspace_hook_runner_failed, hook_name}}
      after
        timeout_ms + @runner_overhead_ms ->
          send(runner, {:workspace_hook_runner_abort, result_ref})
          await_runner_down(monitor_ref, runner)
          Process.unlink(runner)
          Process.demonitor(monitor_ref, [:flush])
          {:error, {:workspace_hook_cleanup_failed, hook_name, :runner_timeout}}
      end
    end
  end

  @doc false
  @spec await_startup_cleanup_for_test(CleanupGuardian.Handle.t(), (term() -> term()), String.t()) :: :ok
  def await_startup_cleanup_for_test(%CleanupGuardian.Handle{} = handle, observer, hook_name)
      when is_function(observer, 1) and is_binary(hook_name) do
    hold_startup_cleanup_authority(handle, observer, hook_name)
  end

  defp start_runner(runner_fun, hook_name) do
    case Process.whereis(@supervisor) do
      supervisor when is_pid(supervisor) ->
        case Task.Supervisor.start_child(supervisor, runner_fun, shutdown: :infinity) do
          {:ok, runner} -> {:ok, runner}
          {:error, _reason} -> {:error, {:workspace_hook_supervisor_unavailable, hook_name}}
        end

      nil ->
        {:error, {:workspace_hook_supervisor_unavailable, hook_name}}
    end
  catch
    :exit, _reason -> {:error, {:workspace_hook_supervisor_unavailable, hook_name}}
  end

  defp register_runtime_member! do
    case CleanupBarrier.register_runtime_member(self()) do
      :ok -> :ok
      {:error, :barrier_unavailable} -> exit(:runtime_member_barrier_unavailable)
    end
  end

  defp await_begin(begin_ref, owner, owner_monitor, run_fun, hook_name) do
    receive do
      {:workspace_hook_runner_begin, ^begin_ref} ->
        run_fun.()

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        {:error, {:workspace_hook_owner_exited, hook_name}}

      {:EXIT, ^owner, _reason} ->
        {:error, {:workspace_hook_owner_exited, hook_name}}

      {:EXIT, _supervisor, _reason} ->
        {:error, {:workspace_hook_aborted, hook_name}}
    after
      @runner_overhead_ms ->
        {:error, {:workspace_hook_cleanup_failed, hook_name, :begin_timeout}}
    end
  end

  defp complete_runner(
         {:hold_cleanup, adapter, error},
         owner,
         result_ref,
         observer,
         hook_name
       ) do
    maybe_notify(observer, {:workspace_hook_runner_cleanup_failed, self(), error})
    send(owner, {result_ref, error})
    hold_cleanup_authority(adapter, observer, hook_name)
  end

  defp complete_runner(
         {:hold_startup_cleanup, guardian, error},
         owner,
         result_ref,
         observer,
         hook_name
       )
       when is_struct(guardian, CleanupGuardian.Handle) do
    maybe_notify(observer, {:workspace_hook_runner_cleanup_failed, self(), error})
    send(owner, {result_ref, error})
    hold_startup_cleanup_authority(guardian, observer, hook_name)
  end

  defp complete_runner(result, owner, result_ref, observer, _hook_name) do
    maybe_notify(observer, {:workspace_hook_runner_stopped, self(), result})
    send(owner, {result_ref, result})
  end

  defp hold_cleanup_authority(adapter, observer, hook_name) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        recovered = {:error, {:workspace_hook_cleanup_recovered, hook_name}}
        maybe_notify(observer, {:workspace_hook_runner_stopped, self(), recovered})
        :ok

      {:error, _reason} ->
        receive do
          _message -> hold_cleanup_authority(adapter, observer, hook_name)
        after
          @cleanup_timeout_ms -> hold_cleanup_authority(adapter, observer, hook_name)
        end
    end
  end

  defp hold_startup_cleanup_authority(guardian, observer, hook_name) do
    monitor_ref = Process.monitor(guardian.pid)
    await_startup_cleanup_authority(guardian, monitor_ref, observer, hook_name)
  end

  defp await_startup_cleanup_authority(guardian, monitor_ref, observer, hook_name) do
    receive do
      {:cleanup_guardian_verified, guardian_pid} when guardian_pid == guardian.pid ->
        Process.demonitor(monitor_ref, [:flush])
        notify_startup_cleanup_recovered(observer, hook_name)

      {:DOWN, ^monitor_ref, :process, guardian_pid, _reason} when guardian_pid == guardian.pid ->
        if CleanupGuardian.verified?(guardian) do
          notify_startup_cleanup_recovered(observer, hook_name)
        else
          hold_lost_startup_cleanup_authority()
        end

      _message ->
        await_startup_cleanup_authority(guardian, monitor_ref, observer, hook_name)
    end
  end

  defp notify_startup_cleanup_recovered(observer, hook_name) do
    recovered = {:error, {:workspace_hook_cleanup_recovered, hook_name}}
    maybe_notify(observer, {:workspace_hook_runner_stopped, self(), recovered})
    :ok
  end

  defp hold_lost_startup_cleanup_authority do
    receive do
      _message -> hold_lost_startup_cleanup_authority()
    end
  end

  defp run_owned(
         command,
         workspace,
         hook_name,
         timeout_ms,
         output_limit_bytes,
         owner,
         owner_monitor,
         result_ref
       )
       when is_integer(output_limit_bytes) and output_limit_bytes > 0 do
    case ProcessAdapter.start(["/bin/sh", "-c", command],
           cd: workspace,
           env: allowed_environment(),
           kill_timeout_ms: @hook_kill_grace_ms
         ) do
      {:ok, adapter} ->
        collect(
          adapter,
          hook_name,
          timeout_ms,
          output_limit_bytes,
          owner,
          owner_monitor,
          result_ref
        )

      {:error, reason} ->
        handle_start_failure(reason, hook_name)
    end
  end

  defp run_owned(
         _command,
         _workspace,
         hook_name,
         _timeout_ms,
         _output_limit_bytes,
         _owner,
         _owner_monitor,
         _result_ref
       ) do
    {:error, {:workspace_hook_invalid_output_limit, hook_name}}
  end

  defp handle_start_failure(reason, hook_name) do
    cleanup_error = {:error, {:workspace_hook_cleanup_failed, hook_name, :start}}

    case startup_cleanup_guardian(reason) do
      {:ok, guardian} ->
        {:hold_startup_cleanup, guardian, cleanup_error}

      :none ->
        handle_start_failure_without_guardian(reason, hook_name, cleanup_error)
    end
  end

  defp handle_start_failure_without_guardian(reason, hook_name, cleanup_error) do
    if process_start_cleanup_failure?(reason) do
      cleanup_error
    else
      {:error, {:workspace_hook_start_failed, hook_name}}
    end
  end

  defp collect(
         adapter,
         hook_name,
         timeout_ms,
         output_limit_bytes,
         owner,
         owner_monitor,
         result_ref
       ) do
    process_metadata = ProcessAdapter.metadata(adapter)

    state = %{
      hook_name: hook_name,
      timeout_ms: timeout_ms,
      deadline_ms: monotonic_ms() + timeout_ms,
      output_limit_bytes: output_limit_bytes,
      output_summary: empty_output_summary(),
      owner: owner,
      owner_monitor: owner_monitor,
      result_ref: result_ref,
      os_pid: process_metadata.os_pid,
      manager_pid: process_metadata.pid
    }

    collect_until_exit(adapter, state)
  end

  defp collect_until_exit(adapter, state) do
    remaining_ms = max(state.deadline_ms - monotonic_ms(), 0)

    receive do
      {:stdout, os_pid, data} when os_pid == state.os_pid ->
        output_summary =
          account_output(state.output_summary, :stdout, data, state.output_limit_bytes)

        continue_or_stop_for_output_limit(adapter, state, output_summary)

      {:stderr, os_pid, data} when os_pid == state.os_pid ->
        output_summary =
          account_output(state.output_summary, :stderr, data, state.output_limit_bytes)

        continue_or_stop_for_output_limit(adapter, state, output_summary)

      {:EXIT, pid, reason} when pid == state.manager_pid ->
        finish_after_exit(adapter, state.hook_name, reason, state.output_summary)

      {:EXIT, owner, _reason} when owner == state.owner ->
        finish_owner_exit(adapter, state.hook_name)

      {:DOWN, owner_monitor, :process, owner, _reason}
      when owner_monitor == state.owner_monitor and owner == state.owner ->
        finish_owner_exit(adapter, state.hook_name)

      {:EXIT, _supervisor, _reason} ->
        finish_abort(adapter, state.hook_name)

      {:workspace_hook_runner_abort, result_ref} when result_ref == state.result_ref ->
        finish_abort(adapter, state.hook_name)
    after
      remaining_ms ->
        finish_timeout(adapter, state.hook_name, state.timeout_ms)
    end
  end

  defp continue_or_stop_for_output_limit(adapter, state, %{truncated: true} = output_summary) do
    finish_output_limit(adapter, state.hook_name, state.output_limit_bytes, output_summary)
  end

  defp continue_or_stop_for_output_limit(adapter, state, output_summary) do
    collect_until_exit(adapter, %{state | output_summary: output_summary})
  end

  defp finish_owner_exit(adapter, hook_name) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        {:error, {:workspace_hook_owner_exited, hook_name}}

      {:error, _reason} ->
        {:hold_cleanup, adapter, {:error, {:workspace_hook_cleanup_failed, hook_name, :owner_exit}}}
    end
  end

  defp finish_abort(adapter, hook_name) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        {:error, {:workspace_hook_aborted, hook_name}}

      {:error, _reason} ->
        {:hold_cleanup, adapter, {:error, {:workspace_hook_cleanup_failed, hook_name, :abort}}}
    end
  end

  defp finish_after_exit(adapter, hook_name, reason, output_summary) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        classify_exit(hook_name, reason, output_summary)

      {:error, _reason} ->
        {:hold_cleanup, adapter, {:error, {:workspace_hook_cleanup_failed, hook_name, :exit}}}
    end
  end

  defp finish_timeout(adapter, hook_name, timeout_ms) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        {:error, {:workspace_hook_timeout, hook_name, timeout_ms}}

      {:error, _reason} ->
        {:hold_cleanup, adapter, {:error, {:workspace_hook_cleanup_failed, hook_name, :timeout}}}
    end
  end

  defp finish_output_limit(adapter, hook_name, output_limit_bytes, output_summary) do
    case ProcessAdapter.stop(adapter, @cleanup_timeout_ms) do
      :ok ->
        {:error, {:workspace_hook_output_limit, hook_name, output_limit_bytes, output_summary}}

      {:error, _reason} ->
        {:hold_cleanup, adapter, {:error, {:workspace_hook_cleanup_failed, hook_name, :output_limit}}}
    end
  end

  defp classify_exit(_hook_name, :normal, _output_summary), do: :ok

  defp classify_exit(hook_name, {:exit_status, raw_status}, output_summary)
       when is_integer(raw_status) and raw_status >= 0 do
    status = if rem(raw_status, 256) == 0, do: div(raw_status, 256), else: raw_status
    {:error, {:workspace_hook_failed, hook_name, status, output_summary}}
  end

  defp classify_exit(hook_name, _reason, output_summary) do
    {:error, {:workspace_hook_failed, hook_name, :process_exit, output_summary}}
  end

  defp account_output(summary, stream, data, output_limit_bytes) do
    bytes = data |> IO.iodata_to_binary() |> byte_size()
    key = if stream == :stdout, do: :stdout_bytes, else: :stderr_bytes
    captured_bytes = summary.stdout_bytes + summary.stderr_bytes
    available_bytes = max(output_limit_bytes - captured_bytes, 0)
    accepted_bytes = min(bytes, available_bytes)

    summary
    |> Map.update!(key, &(&1 + accepted_bytes))
    |> Map.put(:truncated, summary.truncated or bytes > available_bytes)
  end

  defp process_start_cleanup_failure?({:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence}}),
    do: true

  defp process_start_cleanup_failure?({:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence, %CleanupGuardian.Handle{}}}),
    do: true

  defp process_start_cleanup_failure?(_reason), do: false

  defp startup_cleanup_guardian({:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence, %CleanupGuardian.Handle{} = guardian}}),
    do: {:ok, guardian}

  defp startup_cleanup_guardian(_reason), do: :none

  defp empty_output_summary do
    %{stdout_bytes: 0, stderr_bytes: 0, truncated: false}
  end

  defp allowed_environment do
    @allowed_environment_names
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) -> [{name, value}]
        nil -> []
      end
    end)
    |> ensure_path()
  end

  defp ensure_path(environment) do
    case List.keyfind(environment, "PATH", 0) do
      nil -> [{"PATH", "/usr/local/bin:/usr/bin:/bin"} | environment]
      {_name, _value} -> environment
    end
  end

  defp await_runner_down(monitor_ref, runner) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^runner, _reason} -> :ok
    after
      @cleanup_timeout_ms -> :ok
    end
  end

  defp maybe_notify(observer, message) when is_pid(observer), do: send(observer, message)
  defp maybe_notify(observer, message) when is_function(observer, 1), do: observer.(message)
  defp maybe_notify(_observer, _message), do: :ok

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
