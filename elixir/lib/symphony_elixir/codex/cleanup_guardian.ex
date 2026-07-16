# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CleanupGuardian.Handle do
  @moduledoc false

  @enforce_keys [:pid, :status]
  defstruct [:pid, :status]

  @type t :: %__MODULE__{pid: pid(), status: :atomics.atomics_ref()}
end

defmodule SymphonyElixir.Codex.CleanupGuardian do
  @moduledoc """
  Retains process-cleanup authority independently of a transport connection.

  The guardian is deliberately not linked to the connection. It monitors the
  connection, owns a copy of the opaque process adapter handle, and retries a
  bounded adapter stop if cleanup was not verified before the connection exits.
  Established Connections delegate even their first physical stop here, so no
  supervisor transition can overlap Connection and guardian stop callers.
  Under the application runtime it is supervised by `CleanupSupervisor`; it
  traps that supervisor's shutdown and does not let a replacement runtime start
  until cleanup is verified. After the foreground retry window, it remains as a
  low-frequency cleanup authority instead of silently abandoning a possibly
  live process group.

  A supervisor-start error is not proof that no guardian child exists. The
  caller adopts a matching ready acknowledgement even after an error or exit;
  an ambiguity without acknowledgement holds fail closed instead of exposing
  a second inline cleanup authority.
  """

  @retry_interval_ms 250
  @persistent_retry_interval_ms 5_000
  @ready_timeout_ms 1_000
  @supervisor SymphonyElixir.CleanupSupervisor
  @active 0
  @verified 1

  alias __MODULE__.Handle
  alias SymphonyElixir.Codex.CleanupBarrier

  @spec start(pid(), module(), term(), non_neg_integer()) :: pid()
  def start(connection, process_adapter, adapter, timeout_ms)
      when is_pid(connection) and is_atom(process_adapter) and is_integer(timeout_ms) and
             timeout_ms >= 0 do
    start_handle(connection, process_adapter, adapter, timeout_ms).pid
  end

  @doc false
  @spec start_handle(pid(), module(), term(), non_neg_integer()) :: Handle.t()
  def start_handle(connection, process_adapter, adapter, timeout_ms)
      when is_pid(connection) and is_atom(process_adapter) and is_integer(timeout_ms) and
             timeout_ms >= 0 do
    do_start_handle(
      connection,
      process_adapter,
      adapter,
      timeout_ms,
      &start_supervised_guardian/1
    )
  end

  @doc false
  @spec start_handle_with_starter_for_test(
          pid(),
          module(),
          term(),
          non_neg_integer(),
          ((-> term()) -> {:ok, pid()} | {:error, term()})
        ) :: Handle.t()
  def start_handle_with_starter_for_test(
        connection,
        process_adapter,
        adapter,
        timeout_ms,
        starter
      )
      when is_pid(connection) and is_atom(process_adapter) and is_integer(timeout_ms) and
             timeout_ms >= 0 and is_function(starter, 1) do
    do_start_handle(connection, process_adapter, adapter, timeout_ms, starter)
  end

  defp do_start_handle(connection, process_adapter, adapter, timeout_ms, starter) do
    status = :atomics.new(1, [])
    :ok = :atomics.put(status, 1, @active)

    guardian_builder = fn ready_recipient, ready_token ->
      fn ->
        Process.flag(:trap_exit, true)
        owner_ref = Process.monitor(connection)
        send(ready_recipient, {:cleanup_guardian_ready, ready_token, self()})

        :verified =
          loop(connection, owner_ref, process_adapter, adapter, timeout_ms, false, nil, status)
      end
    end

    guardian =
      case start_acknowledged_guardian(starter, guardian_builder) do
        {:ok, guardian} ->
          guardian

        {:error, _reason} ->
          if runtime_supervised?() do
            raise "runtime cleanup guardian unavailable"
          else
            start_unlinked_acknowledged_guardian(guardian_builder)
          end
      end

    handle = %Handle{pid: guardian, status: status}
    register_runtime_handle(handle)
    handle
  end

  @spec cleanup_verified(pid() | Handle.t()) :: :ok
  def cleanup_verified(guardian) when is_pid(guardian) do
    send(guardian, :cleanup_verified)
    :ok
  end

  def cleanup_verified(%Handle{pid: guardian}), do: cleanup_verified(guardian)

  @spec request_cleanup(pid() | Handle.t()) :: :ok
  def request_cleanup(guardian) when is_pid(guardian) do
    send(guardian, :cleanup_requested)
    :ok
  end

  def request_cleanup(%Handle{pid: guardian}), do: request_cleanup(guardian)

  @doc false
  @spec request_cleanup_once(pid(), non_neg_integer()) :: :ok | {:error, term()}
  def request_cleanup_once(guardian, wait_timeout_ms)
      when is_pid(guardian) and is_integer(wait_timeout_ms) and wait_timeout_ms >= 0 do
    monitor_ref = Process.monitor(guardian)
    token = make_ref()
    send(guardian, {:cleanup_requested_once, self(), token})

    receive do
      {:cleanup_guardian_attempt_result, ^token, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^guardian, _reason} ->
        {:error, :cleanup_guardian_unavailable}
    after
      wait_timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cleanup_in_progress}
    end
  end

  @doc false
  @spec verified?(Handle.t()) :: boolean()
  def verified?(%Handle{status: status}), do: :atomics.get(status, 1) == @verified

  defp loop(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         cleanup_requested?,
         deadline_ms,
         status
       ) do
    receive do
      :cleanup_verified ->
        :ok = mark_verified(status)
        Process.demonitor(owner_ref, [:flush])
        :verified

      :cleanup_requested when not cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms),
          status
        )

      {:cleanup_requested_once, waiter, token} when not cleanup_requested? ->
        attempt_cleanup(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms),
          status,
          {waiter, token}
        )

      {:cleanup_requested_once, waiter, token} ->
        send(waiter, {:cleanup_guardian_attempt_result, token, {:error, :cleanup_in_progress}})

        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms,
          status
        )

      :cleanup_requested ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms,
          status
        )

      {:DOWN, ^owner_ref, :process, ^connection, _reason}
      when not cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms),
          status
        )

      {:DOWN, ^owner_ref, :process, ^connection, _reason} ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms,
          status
        )

      :retry_cleanup when cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          deadline_ms,
          status
        )

      {:EXIT, _supervisor, _reason} when not cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms),
          status
        )

      {:EXIT, _supervisor, _reason} ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms,
          status
        )

      _message ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms,
          status
        )
    end
  end

  defp continue_after_cleanup_attempt(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms,
         status
       ) do
    if cleanup_deadline_exhausted?(deadline_ms) do
      continue_with_persistent_cleanup(
        connection,
        owner_ref,
        process_adapter,
        adapter,
        timeout_ms,
        status
      )
    else
      attempt_cleanup(
        connection,
        owner_ref,
        process_adapter,
        adapter,
        timeout_ms,
        deadline_ms,
        status
      )
    end
  end

  defp cleanup_deadline_exhausted?(:persistent), do: false
  defp cleanup_deadline_exhausted?(deadline_ms), do: monotonic_ms() >= deadline_ms

  defp continue_with_persistent_cleanup(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         status
       ) do
    send(connection, {:cleanup_guardian_exhausted, self()})
    Process.send_after(self(), :retry_cleanup, @persistent_retry_interval_ms)

    loop(
      connection,
      owner_ref,
      process_adapter,
      adapter,
      timeout_ms,
      true,
      :persistent,
      status
    )
  end

  defp attempt_cleanup(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms,
         status,
         observer \\ nil
       ) do
    case bounded_stop(process_adapter, adapter, timeout_ms) do
      :ok ->
        :ok = mark_verified(status)
        notify_attempt_observer(observer, :ok)
        send(connection, {:cleanup_guardian_verified, self()})
        Process.demonitor(owner_ref, [:flush])
        :verified

      {:error, _reason} = error ->
        notify_attempt_observer(observer, error)

        continue_after_failed_cleanup(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          deadline_ms,
          status
        )
    end
  end

  defp notify_attempt_observer(nil, _result), do: :ok

  defp notify_attempt_observer({waiter, token}, result) do
    send(waiter, {:cleanup_guardian_attempt_result, token, result})
    :ok
  end

  defp continue_after_failed_cleanup(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms,
         status
       ) do
    Process.send_after(self(), :retry_cleanup, retry_interval(deadline_ms))

    loop(
      connection,
      owner_ref,
      process_adapter,
      adapter,
      timeout_ms,
      true,
      deadline_ms,
      status
    )
  end

  defp mark_verified(status), do: :atomics.put(status, 1, @verified)

  defp retry_interval(:persistent), do: @persistent_retry_interval_ms
  defp retry_interval(_deadline_ms), do: @retry_interval_ms

  defp cleanup_deadline(timeout_ms),
    do: monotonic_ms() + max(timeout_ms * 3, 3_000)

  defp bounded_stop(process_adapter, adapter, timeout_ms) do
    parent = self()
    token = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_stop(process_adapter, adapter, timeout_ms)
        send(parent, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_stop_result(result)

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        {:error, :adapter_stop_failed}
    after
      timeout_ms + 1_000 ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :cleanup_timeout}
    end
  end

  defp safe_stop(process_adapter, adapter, timeout_ms) do
    process_adapter.stop(adapter, timeout_ms)
  rescue
    _error -> {:error, :adapter_stop_failed}
  catch
    _kind, _reason -> {:error, :adapter_stop_failed}
  end

  defp normalize_stop_result(:ok), do: :ok
  defp normalize_stop_result({:error, _reason} = error), do: error
  defp normalize_stop_result(_other), do: {:error, :adapter_stop_failed}

  defp start_supervised_guardian(guardian_fun) do
    case Process.whereis(@supervisor) do
      supervisor when is_pid(supervisor) ->
        case Task.Supervisor.start_child(supervisor, guardian_fun, shutdown: :infinity) do
          {:ok, guardian} -> {:ok, guardian}
          {:error, _reason} -> {:error, :cleanup_guardian_start_ambiguous}
        end

      nil ->
        {:error, :cleanup_guardian_not_started}
    end
  catch
    :exit, _reason -> {:error, :cleanup_guardian_start_ambiguous}
  end

  defp start_acknowledged_guardian(starter, guardian_builder) do
    ready_token = make_ref()
    guardian_fun = guardian_builder.(self(), ready_token)

    case invoke_guardian_starter(starter, guardian_fun) do
      {:ok, guardian} when is_pid(guardian) ->
        await_guardian_ready(guardian, ready_token)

      {:error, :cleanup_guardian_not_started} = error ->
        error

      {:error, _ambiguous_reason} ->
        await_ambiguous_guardian_ready(ready_token)
    end
  end

  defp invoke_guardian_starter(starter, guardian_fun) do
    case starter.(guardian_fun) do
      {:ok, guardian} when is_pid(guardian) -> {:ok, guardian}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :cleanup_guardian_start_ambiguous}
    end
  rescue
    _error -> {:error, :cleanup_guardian_start_ambiguous}
  catch
    _kind, _reason -> {:error, :cleanup_guardian_start_ambiguous}
  end

  defp await_ambiguous_guardian_ready(ready_token) do
    receive do
      {:cleanup_guardian_ready, ^ready_token, guardian} when is_pid(guardian) ->
        {:ok, guardian}
    after
      @ready_timeout_ms -> hold_ambiguous_guardian_start(ready_token)
    end
  end

  defp hold_ambiguous_guardian_start(ready_token) do
    receive do
      {:cleanup_guardian_ready, ^ready_token, guardian} when is_pid(guardian) ->
        {:ok, guardian}
    after
      @persistent_retry_interval_ms -> hold_ambiguous_guardian_start(ready_token)
    end
  end

  defp await_guardian_ready(guardian, ready_token) do
    monitor_ref = Process.monitor(guardian)

    receive do
      {:cleanup_guardian_ready, ^ready_token, ^guardian} ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, guardian}

      {:DOWN, ^monitor_ref, :process, ^guardian, _reason} ->
        {:error, :cleanup_guardian_not_ready}
    after
      @ready_timeout_ms ->
        Process.exit(guardian, :kill)
        await_killed_guardian(guardian, monitor_ref)
        {:error, :cleanup_guardian_not_ready}
    end
  end

  defp await_killed_guardian(guardian, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^guardian, _reason} -> :ok
    after
      @ready_timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        :ok
    end
  end

  defp start_unlinked_acknowledged_guardian(guardian_builder) do
    case start_acknowledged_guardian(
           fn guardian_fun -> {:ok, spawn(guardian_fun)} end,
           guardian_builder
         ) do
      {:ok, guardian} -> guardian
      {:error, _reason} -> raise "cleanup guardian fallback failed"
    end
  end

  defp runtime_supervised?, do: is_pid(Process.whereis(SymphonyElixir.RuntimeSupervisor))

  defp register_runtime_handle(handle) do
    if runtime_supervised?(), do: register_supervised_runtime_handle(handle), else: :ok
  end

  defp register_supervised_runtime_handle(handle) do
    case CleanupBarrier.register(handle) do
      :ok -> :ok
      {:error, :barrier_unavailable} -> handle_unavailable_runtime_barrier(handle)
    end
  end

  defp handle_unavailable_runtime_barrier(handle) do
    if is_pid(Process.whereis(@supervisor)) do
      :ok
    else
      await_unbarriered_guardian_cleanup(handle)
      raise "runtime cleanup barrier unavailable"
    end
  end

  defp await_unbarriered_guardian_cleanup(handle) do
    monitor_ref = Process.monitor(handle.pid)
    request_cleanup(handle)
    await_unbarriered_guardian_down(handle, monitor_ref)
  end

  defp await_unbarriered_guardian_down(handle, monitor_ref) do
    cond do
      verified?(handle) ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      Process.alive?(handle.pid) ->
        receive do
          {:DOWN, ^monitor_ref, :process, _guardian, _reason} ->
            await_unbarriered_guardian_down(handle, monitor_ref)
        after
          @persistent_retry_interval_ms ->
            request_cleanup(handle)
            await_unbarriered_guardian_down(handle, monitor_ref)
        end

      true ->
        hold_lost_unbarriered_authority()
    end
  end

  defp hold_lost_unbarriered_authority do
    receive do
      _message -> hold_lost_unbarriered_authority()
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
