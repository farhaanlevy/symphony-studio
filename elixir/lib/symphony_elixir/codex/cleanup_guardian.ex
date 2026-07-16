# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CleanupGuardian do
  @moduledoc """
  Retains process-cleanup authority independently of a transport connection.

  The guardian is deliberately not linked to the connection. It monitors the
  connection, owns a copy of the opaque process adapter handle, and retries a
  bounded adapter stop if cleanup was not verified before the connection exits.
  After the foreground retry window, it remains as a low-frequency cleanup
  authority instead of silently abandoning a possibly live process group.
  """

  @retry_interval_ms 250
  @persistent_retry_interval_ms 5_000

  @spec start(pid(), module(), term(), non_neg_integer()) :: pid()
  def start(connection, process_adapter, adapter, timeout_ms)
      when is_pid(connection) and is_atom(process_adapter) and is_integer(timeout_ms) and
             timeout_ms >= 0 do
    spawn(fn ->
      owner_ref = Process.monitor(connection)
      loop(connection, owner_ref, process_adapter, adapter, timeout_ms, false, nil)
    end)
  end

  @spec cleanup_verified(pid()) :: :ok
  def cleanup_verified(guardian) when is_pid(guardian) do
    send(guardian, :cleanup_verified)
    :ok
  end

  @spec request_cleanup(pid()) :: :ok
  def request_cleanup(guardian) when is_pid(guardian) do
    send(guardian, :cleanup_requested)
    :ok
  end

  defp loop(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         cleanup_requested?,
         deadline_ms
       ) do
    receive do
      :cleanup_verified ->
        Process.demonitor(owner_ref, [:flush])
        :ok

      :cleanup_requested when not cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms)
        )

      :cleanup_requested ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms
        )

      {:DOWN, ^owner_ref, :process, ^connection, _reason}
      when not cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_deadline(timeout_ms)
        )

      {:DOWN, ^owner_ref, :process, ^connection, _reason} ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms
        )

      :retry_cleanup when cleanup_requested? ->
        continue_after_cleanup_attempt(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          deadline_ms
        )

      _message ->
        loop(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          cleanup_requested?,
          deadline_ms
        )
    end
  end

  defp continue_after_cleanup_attempt(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms
       ) do
    if cleanup_deadline_exhausted?(deadline_ms) do
      continue_with_persistent_cleanup(
        connection,
        owner_ref,
        process_adapter,
        adapter,
        timeout_ms
      )
    else
      attempt_cleanup(
        connection,
        owner_ref,
        process_adapter,
        adapter,
        timeout_ms,
        deadline_ms
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
         timeout_ms
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
      :persistent
    )
  end

  defp attempt_cleanup(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms
       ) do
    case bounded_stop(process_adapter, adapter, timeout_ms) do
      :ok ->
        send(connection, {:cleanup_guardian_verified, self()})
        Process.demonitor(owner_ref, [:flush])
        :ok

      {:error, _reason} ->
        continue_after_failed_cleanup(
          connection,
          owner_ref,
          process_adapter,
          adapter,
          timeout_ms,
          deadline_ms
        )
    end
  end

  defp continue_after_failed_cleanup(
         connection,
         owner_ref,
         process_adapter,
         adapter,
         timeout_ms,
         deadline_ms
       ) do
    Process.send_after(self(), :retry_cleanup, retry_interval(deadline_ms))

    loop(
      connection,
      owner_ref,
      process_adapter,
      adapter,
      timeout_ms,
      true,
      deadline_ms
    )
  end

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

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
