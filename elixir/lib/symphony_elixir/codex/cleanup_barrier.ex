# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CleanupBarrier do
  @moduledoc """
  Keeps registered cleanup authority and member lifetimes inside the runtime
  restart barrier.

  `CleanupSupervisor` normally owns each guardian. This independent registry
  is the reciprocal failure barrier: if that supervisor itself crashes, the
  orphaned but acknowledged guardian remains registered here and a
  `:one_for_all` restart cannot complete until its durable handle proves
  cleanup. Connections, AgentRunners, and workspace-hook runners are also
  monitored so a killed nested supervisor cannot orphan a predecessor beside
  the replacement runtime. If this registry crashes instead, the nested
  supervisors retain their members and `CleanupSupervisor` still owns each
  guardian.
  """

  use GenServer

  alias SymphonyElixir.Codex.CleanupGuardian

  @name SymphonyElixir.CleanupBarrier
  @poll_interval_ms 250

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, %{}, name: @name)

  @spec register(CleanupGuardian.Handle.t()) :: :ok | {:error, :barrier_unavailable}
  def register(%CleanupGuardian.Handle{} = handle) do
    GenServer.call(@name, {:register, handle}, :infinity)
  catch
    :exit, _reason -> {:error, :barrier_unavailable}
  end

  @spec register_member(pid()) :: :ok | {:error, :barrier_unavailable}
  def register_member(member) when is_pid(member) do
    GenServer.call(@name, {:register_member, member}, :infinity)
  catch
    :exit, _reason -> {:error, :barrier_unavailable}
  end

  @spec register_runtime_member(pid()) :: :ok | {:error, :barrier_unavailable}
  def register_runtime_member(member) when is_pid(member) do
    if is_pid(Process.whereis(SymphonyElixir.RuntimeSupervisor)) do
      register_member(member)
    else
      :ok
    end
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:register, %CleanupGuardian.Handle{} = handle}, _from, state) do
    {:reply, :ok, register_handle(state, handle)}
  end

  def handle_call({:register_member, member}, _from, state) when is_pid(member) do
    {:reply, :ok, register_member(state, member)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state, pid) do
      %{kind: :cleanup, handle: handle, ref: ^ref} ->
        if CleanupGuardian.verified?(handle) do
          {:noreply, Map.delete(state, pid)}
        else
          {:noreply, Map.put(state, pid, %{kind: :cleanup, handle: handle, ref: nil})}
        end

      %{kind: :member, ref: ^ref} ->
        {:noreply, Map.delete(state, pid)}

      _unknown ->
        {:noreply, state}
    end
  end

  def handle_info(:poll_cleanup_barrier, state) do
    {:noreply, prune_verified(state)}
  end

  @impl true
  def terminate(_reason, state) do
    await_cleanup(state)
  end

  defp register_handle(state, handle) do
    cond do
      CleanupGuardian.verified?(handle) ->
        state

      Map.has_key?(state, handle.pid) ->
        state

      true ->
        Map.put(state, handle.pid, %{
          kind: :cleanup,
          handle: handle,
          ref: Process.monitor(handle.pid)
        })
    end
  end

  defp register_member(state, member) do
    cond do
      Map.has_key?(state, member) ->
        state

      Process.alive?(member) ->
        Map.put(state, member, %{kind: :member, ref: Process.monitor(member)})

      true ->
        state
    end
  end

  defp await_cleanup(state) do
    state = prune_verified(state)

    if map_size(state) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, pid, _reason} ->
          await_cleanup(mark_down(state, pid, ref))
      after
        @poll_interval_ms -> await_cleanup(state)
      end
    end
  end

  defp mark_down(state, pid, ref) do
    case Map.get(state, pid) do
      %{kind: :cleanup, handle: handle, ref: ^ref} ->
        Map.put(state, pid, %{kind: :cleanup, handle: handle, ref: nil})

      %{kind: :member, ref: ^ref} ->
        Map.delete(state, pid)

      _unknown ->
        state
    end
  end

  defp prune_verified(state) do
    Enum.reduce(state, %{}, &retain_pending_entry/2)
  end

  defp retain_pending_entry({pid, %{kind: :cleanup, handle: handle} = entry}, pending) do
    if CleanupGuardian.verified?(handle) do
      discard_entry(entry, pending)
    else
      Map.put(pending, pid, entry)
    end
  end

  defp retain_pending_entry({pid, %{kind: :member} = entry}, pending) do
    if Process.alive?(pid) do
      Map.put(pending, pid, entry)
    else
      discard_entry(entry, pending)
    end
  end

  defp discard_entry(entry, pending) do
    if is_reference(entry.ref), do: Process.demonitor(entry.ref, [:flush])
    pending
  end
end
