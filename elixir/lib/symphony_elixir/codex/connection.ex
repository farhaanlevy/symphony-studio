# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16, updated 2026-07-17): Symphony
# Studio assigns stable logical operation IDs before transport, preserves them
# across wire retries, distinguishes omitted request params exactly, and
# registers process containment before initialization can complete.

defmodule SymphonyElixir.Codex.Connection do
  @moduledoc """
  Owns one fail-closed Codex App Server JSONL connection.

  The connection is the single authority for framing, request IDs, response
  correlation, absolute deadlines, overload retries, diagnostic stderr, and
  child-process teardown. Protocol corruption is terminal for the connection.
  """

  use GenServer

  alias SymphonyElixir.Codex.{
    CleanupBarrier,
    CleanupGuardian,
    JSONLFramer,
    ProcessAdapter,
    RequestPolicy,
    SchemaBundle,
    StderrDiagnostics,
    TransportError
  }

  alias SymphonyElixir.Identity

  @overload_code -32_001
  @default_max_frame_bytes 16_777_216
  @default_stderr_tail_bytes 65_536
  @default_kill_timeout_ms 2_000
  @default_overload_attempts 3
  @default_overload_base_ms 100
  @default_overload_max_ms 2_000
  @default_max_queued_messages 1_024
  @default_max_queued_bytes 16_777_216
  @default_max_server_requests 256
  @default_max_server_request_bytes 16_777_216
  @default_max_completed_request_ids 4_096
  @terminal_identity_domain "symphony-studio/terminal-identity/v1\0"
  @default_write_timeout_ms 5_000
  @cleanup_retry_interval_ms 250
  @supervisor SymphonyElixir.ConnectionSupervisor

  @type request_metadata :: %{
          attempt: pos_integer(),
          classification: RequestPolicy.classification(),
          method: String.t(),
          operation_id: String.t(),
          request_hash: String.t(),
          request_id: integer() | String.t(),
          run_id: String.t() | nil,
          attempt_id: String.t() | nil,
          send_state: :sent | :transmission_uncertain
        }

  @type message :: %{payload: map(), raw: binary()}
  @type request_params :: map() | :omitted

  @spec start([String.t()], keyword()) :: GenServer.on_start()
  def start([executable | _args] = argv, opts \\ []) when is_binary(executable) do
    owner = self()

    case Process.whereis(@supervisor) do
      supervisor when is_pid(supervisor) ->
        child_spec = %{
          id: {__MODULE__, make_ref()},
          start: {__MODULE__, :start_link, [{owner, argv, opts}]},
          restart: :temporary,
          shutdown: :infinity,
          type: :worker
        }

        try do
          DynamicSupervisor.start_child(supervisor, child_spec)
        catch
          :exit, _reason -> {:error, :connection_supervisor_unavailable}
        end

      nil ->
        GenServer.start(__MODULE__, {owner, argv, opts})
    end
  end

  @doc false
  @spec start_link({pid(), [String.t()], keyword()}) :: GenServer.on_start()
  def start_link({owner, [executable | _args] = argv, opts})
      when is_pid(owner) and is_binary(executable) and is_list(opts) do
    GenServer.start_link(__MODULE__, {owner, argv, opts})
  end

  @spec request(pid(), String.t(), request_params(), pos_integer()) ::
          {:ok, term(), request_metadata()} | {:error, TransportError.t()}
  def request(connection, method, params, timeout_ms)
      when is_pid(connection) and is_binary(method) and
             (is_map(params) or params == :omitted) and is_integer(timeout_ms) and timeout_ms > 0 do
    request_until(connection, method, params, monotonic_ms() + timeout_ms)
  end

  @spec request_until(pid(), String.t(), request_params(), integer()) ::
          {:ok, term(), request_metadata()} | {:error, TransportError.t()}
  def request_until(connection, method, params, deadline_ms)
      when is_pid(connection) and is_binary(method) and
             (is_map(params) or params == :omitted) and is_integer(deadline_ms) do
    GenServer.call(connection, {:request_until, method, params, deadline_ms}, :infinity)
  end

  @spec notify(pid(), String.t(), map() | :omitted) :: :ok | {:error, TransportError.t()}
  def notify(connection, method, params \\ :omitted)
      when is_pid(connection) and is_binary(method) and (is_map(params) or params == :omitted) do
    GenServer.call(connection, {:notify, method, params}, :infinity)
  end

  @spec respond(pid(), integer() | String.t(), map()) :: :ok | {:error, TransportError.t()}
  def respond(connection, request_id, result)
      when is_pid(connection) and (is_integer(request_id) or is_binary(request_id)) and is_map(result) do
    GenServer.call(connection, {:respond, request_id, result}, :infinity)
  end

  @spec respond_until(pid(), integer() | String.t(), map(), integer()) ::
          :ok | {:error, TransportError.t()}
  def respond_until(connection, request_id, result, deadline_ms)
      when is_pid(connection) and (is_integer(request_id) or is_binary(request_id)) and
             is_map(result) and is_integer(deadline_ms) do
    GenServer.call(connection, {:respond_until, request_id, result, deadline_ms}, :infinity)
  end

  @spec next_message(pid(), pos_integer()) :: {:ok, message()} | {:error, TransportError.t()}
  def next_message(connection, timeout_ms)
      when is_pid(connection) and is_integer(timeout_ms) and timeout_ms > 0 do
    next_message_until(connection, monotonic_ms() + timeout_ms)
  end

  @spec next_message_until(pid(), integer()) ::
          {:ok, message()} | {:error, TransportError.t()}
  def next_message_until(connection, deadline_ms)
      when is_pid(connection) and is_integer(deadline_ms) do
    GenServer.call(connection, {:next_message_until, deadline_ms}, :infinity)
  end

  @spec ack_terminal(pid(), String.t()) :: :ok | {:error, TransportError.t()}
  def ack_terminal(connection, method)
      when is_pid(connection) and
             method in ["turn/completed", "turn/failed", "turn/cancelled"] do
    GenServer.call(connection, {:ack_terminal, method}, :infinity)
  end

  @spec metadata(pid()) :: map()
  def metadata(connection) when is_pid(connection) do
    GenServer.call(connection, :metadata, :infinity)
  end

  @spec diagnostics(pid()) :: map()
  def diagnostics(connection) when is_pid(connection) do
    GenServer.call(connection, :diagnostics, :infinity)
  end

  @spec close(pid()) :: :ok | {:error, TransportError.t()}
  def close(connection) when is_pid(connection) do
    GenServer.call(connection, :close, :infinity)
  catch
    :exit, reason -> {:error, close_unverified_error(reason)}
  end

  @spec close_with_error(pid(), TransportError.t()) :: {:error, TransportError.t()}
  def close_with_error(connection, %TransportError{} = error) when is_pid(connection) do
    GenServer.call(connection, {:close_with_error, error}, :infinity)
  catch
    :exit, reason ->
      cleanup_error = close_unverified_error(reason)
      {:error, attach_cleanup_failure(error, {:error, cleanup_error})}
  end

  @spec mark_turn_blocked(pid(), :approval_required | :turn_input_required) ::
          :ok | {:error, TransportError.t()}
  def mark_turn_blocked(connection, blocker)
      when is_pid(connection) and blocker in [:approval_required, :turn_input_required] do
    GenServer.call(connection, {:mark_turn_blocked, blocker}, :infinity)
  end

  @impl true
  def init({_owner, _argv, _opts} = init_args) do
    Process.flag(:trap_exit, true)

    case CleanupBarrier.register_runtime_member(self()) do
      :ok -> init_registered(init_args)
      {:error, :barrier_unavailable} -> {:stop, :runtime_member_barrier_unavailable}
    end
  end

  defp init_registered({owner, argv, opts}) do
    owner_ref = Process.monitor(owner)
    process_opts = Keyword.take(opts, [:cd, :env, :kill_timeout_ms])
    process_adapter = Keyword.get(opts, :process_adapter, ProcessAdapter)

    case process_adapter.start(argv, process_opts) do
      {:ok, adapter} ->
        cleanup_timeout_ms = Keyword.get(opts, :kill_timeout_ms, @default_kill_timeout_ms) + 1_000

        case start_cleanup_guardian(process_adapter, adapter, cleanup_timeout_ms) do
          {:ok, cleanup_handle} ->
            notify_cleanup_authority(
              Keyword.get(opts, :on_cleanup_authority),
              cleanup_handle
            )

            state = %{
              active_turn: nil,
              adapter: adapter,
              cleanup_authority: :connection,
              cleanup_guardian: cleanup_handle.pid,
              cleanup_guardian_handed_off?: false,
              connection_supervisor: Process.whereis(@supervisor),
              cleanup_failure_notified: false,
              cleanup_retry_deadline_ms: nil,
              cleanup_retry_ref: nil,
              completed_ids: MapSet.new(),
              completed_terminal_turns: MapSet.new(),
              failure: nil,
              framer: JSONLFramer.new(Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes)),
              jitter_fn: Keyword.get(opts, :jitter_fn, &default_jitter/1),
              id_generator: Keyword.get(opts, :id_generator, &Identity.uuid4/0),
              kill_timeout_ms: Keyword.get(opts, :kill_timeout_ms, @default_kill_timeout_ms),
              metadata: Keyword.get(opts, :metadata, %{}),
              max_completed_request_ids: Keyword.get(opts, :max_completed_request_ids, @default_max_completed_request_ids),
              max_queued_bytes: Keyword.get(opts, :max_queued_bytes, @default_max_queued_bytes),
              max_queued_messages: Keyword.get(opts, :max_queued_messages, @default_max_queued_messages),
              max_outbound_frame_bytes: Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes),
              max_server_request_bytes:
                Keyword.get(
                  opts,
                  :max_server_request_bytes,
                  @default_max_server_request_bytes
                ),
              max_server_requests: Keyword.get(opts, :max_server_requests, @default_max_server_requests),
              next_id: Keyword.get(opts, :initial_request_id, 1),
              on_request: Keyword.get(opts, :on_request, fn _metadata -> :ok end),
              on_retry: Keyword.get(opts, :on_retry, fn _metadata -> :ok end),
              on_transport_failure: Keyword.get(opts, :on_transport_failure, fn _error -> :ok end),
              overload_backoff_base_ms: Keyword.get(opts, :overload_backoff_base_ms, @default_overload_base_ms),
              overload_backoff_max_ms: Keyword.get(opts, :overload_backoff_max_ms, @default_overload_max_ms),
              overload_max_attempts: Keyword.get(opts, :overload_max_attempts, @default_overload_attempts),
              owner: owner,
              owner_ref: owner_ref,
              pending: nil,
              process_adapter: process_adapter,
              queue: :queue.new(),
              queue_bytes: 0,
              queue_count: 0,
              schema_version: SchemaBundle.version(),
              server_request_bytes: 0,
              server_requests: %{},
              side_effect_operation: nil,
              stderr_diagnostics: StderrDiagnostics.new(Keyword.get(opts, :stderr_tail_bytes, @default_stderr_tail_bytes)),
              terminal_delivery: nil,
              write_timeout_ms: Keyword.get(opts, :write_timeout_ms, @default_write_timeout_ms),
              waiter: nil
            }

            notify_started(Keyword.get(opts, :on_started))
            {:ok, state}

          {:error, :cleanup_runtime_unavailable} ->
            fail_guardian_start_closed(
              owner_ref,
              process_adapter,
              adapter,
              cleanup_timeout_ms,
              opts
            )
        end

      {:error, reason} ->
        Process.demonitor(owner_ref, [:flush])
        notify_startup_cleanup_authority(Keyword.get(opts, :on_cleanup_authority), reason)

        error_kind = process_start_error_kind(reason)

        error =
          TransportError.new(
            error_kind,
            Map.merge(
              StderrDiagnostics.new(@default_stderr_tail_bytes)
              |> StderrDiagnostics.public_summary(),
              %{
                cleanup_verified: error_kind != :process_cleanup_failed,
                os_pid: nil,
                reason: adapter_failure_category(:start, reason),
                schema_version: SchemaBundle.version()
              }
            )
          )

        safe_callback(Keyword.get(opts, :on_transport_failure, fn _error -> :ok end), error)
        {:stop, error}
    end
  end

  defp notify_started(callback) when is_function(callback, 1) do
    _result = callback.(self())
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp notify_started(_callback), do: :ok

  defp start_cleanup_guardian(process_adapter, adapter, cleanup_timeout_ms) do
    {:ok, CleanupGuardian.start_handle(self(), process_adapter, adapter, cleanup_timeout_ms)}
  rescue
    _error -> {:error, :cleanup_runtime_unavailable}
  catch
    _kind, _reason -> {:error, :cleanup_runtime_unavailable}
  end

  defp notify_cleanup_authority(callback, %CleanupGuardian.Handle{} = handle)
       when is_function(callback, 1) do
    safe_callback(callback, handle)
  end

  defp notify_cleanup_authority(_callback, _handle), do: :ok

  defp fail_guardian_start_closed(
         owner_ref,
         process_adapter,
         adapter,
         cleanup_timeout_ms,
         opts
       ) do
    await_inline_adapter_cleanup(process_adapter, adapter, cleanup_timeout_ms)
    Process.demonitor(owner_ref, [:flush])

    error =
      TransportError.new(
        :process_start_failed,
        Map.merge(
          StderrDiagnostics.new(@default_stderr_tail_bytes)
          |> StderrDiagnostics.public_summary(),
          %{
            cleanup_verified: true,
            os_pid: nil,
            reason: :cleanup_runtime_unavailable,
            schema_version: SchemaBundle.version()
          }
        )
      )

    safe_callback(Keyword.get(opts, :on_transport_failure, fn _error -> :ok end), error)
    {:stop, error}
  end

  defp await_inline_adapter_cleanup(process_adapter, adapter, cleanup_timeout_ms) do
    case safe_inline_adapter_stop(process_adapter, adapter, cleanup_timeout_ms) do
      :ok ->
        :ok

      {:error, _reason} ->
        Process.sleep(@cleanup_retry_interval_ms)
        await_inline_adapter_cleanup(process_adapter, adapter, cleanup_timeout_ms)
    end
  end

  defp safe_inline_adapter_stop(process_adapter, adapter, cleanup_timeout_ms) do
    case process_adapter.stop(adapter, cleanup_timeout_ms) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :adapter_stop_failed}
    end
  rescue
    _error -> {:error, :adapter_stop_failed}
  catch
    _kind, _reason -> {:error, :adapter_stop_failed}
  end

  defp notify_startup_cleanup_authority(
         callback,
         {:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence, guardian}}
       )
       when is_function(callback, 1) and is_struct(guardian, CleanupGuardian.Handle) do
    safe_callback(callback, guardian)
  end

  defp notify_startup_cleanup_authority(_callback, _reason), do: :ok

  @impl true
  def handle_call(:metadata, _from, %{failure: %TransportError{}} = state) do
    {:reply, connection_metadata(state), state}
  end

  def handle_call(:diagnostics, _from, %{failure: %TransportError{}} = state) do
    {:reply, diagnostic_metadata(state), state}
  end

  def handle_call(:close, _from, %{failure: %TransportError{}} = state) do
    close_connection(state, nil)
  end

  def handle_call(
        {:close_with_error, %TransportError{} = error},
        _from,
        %{failure: %TransportError{}} = state
      ) do
    close_connection(state, maybe_uncertain(state, error))
  end

  def handle_call(_request, _from, %{failure: %TransportError{} = failure} = state) do
    {:reply, {:error, failure}, state}
  end

  def handle_call({:ack_terminal, method}, _from, state) do
    case state.terminal_delivery do
      %{method: ^method, thread_id: thread_id, turn_id: turn_id} ->
        case remember_terminal_turn(state, {thread_id, turn_id}) do
          {:ok, next_state} ->
            {:reply, :ok,
             %{
               next_state
               | active_turn: nil,
                 side_effect_operation: nil,
                 terminal_delivery: nil
             }}

          {:error, error} ->
            failed_state = fail_connection(state, error, [])
            {:reply, {:error, failed_state.failure}, failed_state}
        end

      nil ->
        error =
          transport_error(state, :invalid_json_rpc_frame, %{
            reason: :terminal_ack_without_delivery
          })

        next_state = fail_connection(state, error, [])
        {:reply, {:error, next_state.failure}, next_state}

      %{method: _other_method} ->
        error =
          transport_error(state, :invalid_json_rpc_frame, %{
            reason: :terminal_ack_mismatch
          })

        next_state = fail_connection(state, error, [])
        {:reply, {:error, next_state.failure}, next_state}
    end
  end

  def handle_call({:mark_turn_blocked, blocker}, _from, state)
      when blocker in [:approval_required, :turn_input_required] do
    case {state.active_turn, state.terminal_delivery} do
      {%{}, nil} ->
        {:reply, :ok,
         %{
           state
           | active_turn: nil,
             side_effect_operation: nil
         }}

      _other ->
        error =
          transport_error(state, :invalid_json_rpc_frame, %{
            reason: :turn_blocker_without_active_turn
          })

        next_state = fail_connection(state, error, [])
        {:reply, {:error, next_state.failure}, next_state}
    end
  end

  def handle_call(
        {:request_until, _method, _params, _deadline_ms},
        _from,
        %{pending: pending} = state
      )
      when not is_nil(pending) do
    error = transport_error(state, :invalid_json_rpc_frame, %{reason: :request_already_pending})
    {:reply, {:error, error}, state}
  end

  def handle_call({:request_until, method, params, deadline_ms}, from, state) do
    if monotonic_ms() >= deadline_ms do
      error =
        transport_error(state, :request_timeout, %{
          method: method,
          phase: :request_admission,
          send_state: :prepared
        })

      {:reply, {:error, error}, state}
    else
      prepare_request(method, params, deadline_ms, from, state)
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    payload =
      case params do
        :omitted -> %{"method" => method}
        %{} -> %{"method" => method, "params" => params}
      end

    case send_wire(state, payload) do
      :ok ->
        {:reply, :ok, state}

      {:error, error} ->
        next_state = fail_connection(state, error, [])
        {:reply, {:error, next_state.failure}, next_state}
    end
  end

  def handle_call({:respond, request_id, result}, _from, state) do
    handle_response_call(request_id, result, monotonic_ms() + state.write_timeout_ms, state)
  end

  def handle_call({:respond_until, request_id, result, deadline_ms}, _from, state) do
    handle_response_call(request_id, result, deadline_ms, state)
  end

  def handle_call({:next_message_until, _deadline_ms}, _from, %{waiter: waiter} = state)
      when not is_nil(waiter) do
    error = transport_error(state, :invalid_json_rpc_frame, %{reason: :message_waiter_already_pending})
    {:reply, {:error, error}, state}
  end

  def handle_call({:next_message_until, deadline_ms}, from, state) do
    if monotonic_ms() >= deadline_ms do
      fail_expired_message_call(state)
    else
      take_or_wait_for_message(state, from, deadline_ms)
    end
  end

  def handle_call(:metadata, _from, state) do
    {:reply, connection_metadata(state), state}
  end

  def handle_call(:diagnostics, _from, state) do
    {:reply, diagnostic_metadata(state), state}
  end

  def handle_call(:close, _from, state) do
    close_connection(state, unresolved_side_effect_error(state, :explicit_close))
  end

  def handle_call({:close_with_error, %TransportError{} = error}, _from, state) do
    close_connection(state, maybe_uncertain(state, error))
  end

  defp prepare_request(method, params, deadline_ms, from, state) do
    case bounded_request_hash(method, params, deadline_ms) do
      {:ok, request_hash} ->
        token = make_ref()
        remaining_ms = max(deadline_ms - monotonic_ms(), 0)

        pending = %{
          attempt: 1,
          classification: RequestPolicy.classify(method),
          deadline_ms: deadline_ms,
          deadline_ref: Process.send_after(self(), {:request_deadline, token}, remaining_ms),
          from: from,
          id: nil,
          method: method,
          operation_id: new_operation_id(state),
          run_id: Map.get(state.metadata, :run_id),
          attempt_id: Map.get(state.metadata, :attempt_id),
          params: params,
          request_hash: request_hash,
          retry_ref: nil,
          send_state: :prepared,
          token: token
        }

        case send_pending_request(%{state | pending: pending}) do
          {:ok, next_state} ->
            {:noreply, next_state}

          {:error, %TransportError{} = error, next_state} ->
            {:noreply, fail_connection(next_state, error, [])}
        end

      {:error, reason} ->
        error =
          transport_error(state, :request_timeout, %{
            method: method,
            phase: :request_preparation,
            reason: reason,
            send_state: :prepared
          })

        {:reply, {:error, error}, state}
    end
  end

  defp take_or_wait_for_message(state, from, deadline_ms) do
    case :queue.out(state.queue) do
      {{:value, message}, queue} ->
        if monotonic_ms() >= deadline_ms do
          fail_expired_message_call(state)
        else
          message_bytes = retained_message_bytes(message)

          {:reply, {:ok, message},
           %{
             state
             | queue: queue,
               queue_bytes: max(state.queue_bytes - message_bytes, 0),
               queue_count: max(state.queue_count - 1, 0)
           }}
        end

      {:empty, _queue} ->
        remaining_ms = deadline_ms - monotonic_ms()

        if remaining_ms <= 0 do
          fail_expired_message_call(state)
        else
          token = make_ref()
          timer_ref = Process.send_after(self(), {:message_deadline, token}, remaining_ms)

          {:noreply,
           %{
             state
             | waiter: %{
                 deadline_ms: deadline_ms,
                 from: from,
                 timer_ref: timer_ref,
                 token: token
               }
           }}
        end
    end
  end

  defp fail_expired_message_call(state) do
    next_state = fail_connection(state, message_timeout_error(state), [])
    {:reply, {:error, next_state.failure}, next_state}
  end

  defp handle_response_call(request_id, result, deadline_ms, state) do
    case Map.fetch(state.server_requests, request_id) do
      {:ok, request} ->
        payload = %{"id" => request_id, "result" => result}

        available_bytes =
          max(state.max_server_request_bytes - state.server_request_bytes, 0)

        case send_wire_until_with_limit(state, payload, deadline_ms, available_bytes) do
          {:ok, response_bytes} ->
            server_requests =
              Map.put(state.server_requests, request_id, %{request | response: payload})

            {:reply, :ok,
             %{
               state
               | server_requests: server_requests,
                 server_request_bytes: state.server_request_bytes + response_bytes
             }}

          {:error, error} ->
            next_state = fail_connection(state, error, [])
            {:reply, {:error, next_state.failure}, next_state}
        end

      :error ->
        error =
          transport_error(state, :invalid_json_rpc_frame, %{
            reason: :response_for_unknown_server_request,
            request_id: public_request_id(request_id)
          })

        next_state = fail_connection(state, error, [])
        {:reply, {:error, next_state.failure}, next_state}
    end
  end

  @impl true
  def handle_info({:stdout, os_pid, bytes}, state) when is_binary(bytes) do
    cond do
      adapter_os_pid(state.adapter) != os_pid ->
        {:noreply, state}

      pending_deadline_expired?(state) ->
        {:noreply, fail_connection(state, request_timeout_error(state), [])}

      waiter_deadline_expired?(state) ->
        {:noreply, fail_connection(state, message_timeout_error(state), [])}

      true ->
        handle_stdout(bytes, state)
    end
  end

  def handle_info({:stderr, os_pid, bytes}, state) when is_binary(bytes) do
    if adapter_os_pid(state.adapter) != os_pid do
      {:noreply, state}
    else
      next_state = append_stderr(state, bytes)

      cond do
        pending_deadline_expired?(next_state) ->
          {:noreply, fail_connection(next_state, request_timeout_error(next_state), [])}

        waiter_deadline_expired?(next_state) ->
          {:noreply, fail_connection(next_state, message_timeout_error(next_state), [])}

        true ->
          {:noreply, next_state}
      end
    end
  end

  def handle_info({:request_deadline, token}, %{pending: %{token: token}} = state) do
    error =
      transport_error(state, :request_timeout, %{
        attempt: state.pending.attempt,
        method: state.pending.method,
        operation_id: state.pending.operation_id,
        request_hash: state.pending.request_hash,
        request_id: state.pending.id,
        send_state: state.pending.send_state
      })

    {:noreply, fail_connection(state, error, [])}
  end

  def handle_info({:request_deadline, _token}, state), do: {:noreply, state}

  def handle_info({:overload_retry, token}, %{pending: %{token: token}} = state) do
    if pending_deadline_expired?(state) do
      {:noreply, fail_connection(state, request_timeout_error(state), [])}
    else
      pending = %{state.pending | retry_ref: nil, attempt: state.pending.attempt + 1}

      case send_pending_request(%{state | pending: pending}) do
        {:ok, next_state} ->
          {:noreply, next_state}

        {:error, error, next_state} ->
          {:noreply, fail_connection(next_state, error, [])}
      end
    end
  end

  def handle_info({:overload_retry, _token}, state), do: {:noreply, state}

  def handle_info({:message_deadline, token}, %{waiter: %{token: token}} = state) do
    error = transport_error(state, :request_timeout, %{phase: :message_wait})
    {:noreply, fail_connection(state, error, [])}
  end

  def handle_info({:message_deadline, _token}, state), do: {:noreply, state}

  def handle_info(
        {:EXIT, supervisor, reason},
        %{connection_supervisor: supervisor} = state
      )
      when is_pid(supervisor) do
    state = detach_connection_owner(state)

    case stop_adapter(state) do
      {:ok, next_state} ->
        {:stop, reason, next_state}

      {{:error, cleanup_error}, next_state} ->
        maybe_notify_transport_failure(next_state, cleanup_error)

        next_state = %{
          next_state
          | cleanup_failure_notified: true,
            failure: cleanup_error
        }

        if next_state.cleanup_guardian_handed_off? do
          {:stop, :cleanup_authority_handed_off, detach_handed_off_cleanup(next_state)}
        else
          {:noreply, next_state}
        end
    end
  end

  def handle_info(
        {:EXIT, child_pid, :normal},
        %{terminal_delivery: %{}, adapter: adapter} = state
      )
      when not is_nil(adapter) do
    if adapter_pid(adapter) == child_pid do
      state = %{state | stderr_diagnostics: StderrDiagnostics.finish(state.stderr_diagnostics)}

      case stop_adapter(state) do
        {:ok, next_state} ->
          {:noreply, next_state}

        {{:error, cleanup_error}, next_state} ->
          {:noreply, fail_connection(next_state, cleanup_error, [])}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, child_pid, reason}, state) do
    if adapter_pid(state.adapter) == child_pid do
      state = %{state | stderr_diagnostics: StderrDiagnostics.finish(state.stderr_diagnostics)}
      error = process_exit_error(state, reason)
      {:noreply, fail_connection(state, error, [])}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, owner_ref, :process, owner, _reason},
        %{owner_ref: owner_ref, owner: owner} = state
      ) do
    operation_error = unresolved_side_effect_error(state, :owner_down)
    maybe_notify_transport_failure(state, operation_error)

    case stop_adapter(state) do
      {:ok, next_state} ->
        {:stop, :owner_down, next_state}

      {{:error, cleanup_error}, next_state} ->
        error = attach_optional_cleanup_failure(operation_error, cleanup_error)
        maybe_notify_transport_failure(next_state, error)

        next_state = %{
          next_state
          | cleanup_failure_notified: true,
            failure: error,
            owner: nil,
            owner_ref: nil
        }

        if next_state.cleanup_guardian_handed_off? do
          {:stop, :cleanup_authority_handed_off, detach_handed_off_cleanup(next_state)}
        else
          {:noreply, next_state}
        end
    end
  end

  def handle_info(
        {:cleanup_guardian_verified, guardian},
        %{cleanup_guardian: guardian} = state
      ) do
    next_state = %{
      state
      | adapter: nil,
        cleanup_authority: :verified,
        cleanup_guardian: nil,
        cleanup_guardian_handed_off?: false,
        cleanup_retry_deadline_ms: nil,
        cleanup_retry_ref: cancel_cleanup_retry(state.cleanup_retry_ref)
    }

    if is_nil(next_state.owner) do
      {:stop, :normal, next_state}
    else
      {:noreply, next_state}
    end
  end

  def handle_info(
        {:cleanup_guardian_exhausted, guardian},
        %{cleanup_guardian: guardian, owner: nil} = state
      ) do
    next_state = %{
      state
      | adapter: nil,
        cleanup_guardian: nil,
        cleanup_guardian_handed_off?: true,
        cleanup_retry_deadline_ms: nil,
        cleanup_retry_ref: cancel_cleanup_retry(state.cleanup_retry_ref)
    }

    {:stop, :cleanup_authority_handed_off, next_state}
  end

  def handle_info(
        {:cleanup_guardian_exhausted, guardian},
        %{cleanup_guardian: guardian} = state
      ) do
    {:noreply,
     %{
       state
       | cleanup_retry_deadline_ms: nil,
         cleanup_retry_ref: cancel_cleanup_retry(state.cleanup_retry_ref),
         cleanup_guardian_handed_off?: true
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _result = stop_adapter(state)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> redact_status_field(:message, :redacted)
    |> redact_status_field(:reason, :redacted)
    |> redact_status_field(:log, :redacted)
    |> Map.update(:state, nil, &public_status_state/1)
  end

  defp public_status_state(nil), do: nil

  defp public_status_state(state) do
    %{
      active_turn: redact_active_turn(state.active_turn),
      adapter: redact_adapter(state.adapter),
      cleanup_guardian_active: is_pid(state.cleanup_guardian),
      cleanup_retry_pending: is_reference(state.cleanup_retry_ref),
      completed_request_count: MapSet.size(state.completed_ids),
      completed_terminal_turn_count: MapSet.size(state.completed_terminal_turns),
      failure: redact_failure(state.failure),
      framer: JSONLFramer.public_summary(state.framer),
      metadata: :redacted,
      pending: redact_pending(state.pending),
      queue_bytes: state.queue_bytes,
      queue_count: state.queue_count,
      schema_version: state.schema_version,
      server_request_bytes: state.server_request_bytes,
      server_request_count: map_size(state.server_requests),
      side_effect_operation: state.side_effect_operation,
      stderr_diagnostics: StderrDiagnostics.public_summary(state.stderr_diagnostics),
      terminal_delivery: redact_terminal_delivery(state.terminal_delivery),
      waiter_active: not is_nil(state.waiter)
    }
  end

  defp redact_status_field(status, key, replacement) do
    if Map.has_key?(status, key), do: Map.put(status, key, replacement), else: status
  end

  defp redact_active_turn(nil), do: nil

  defp redact_active_turn(active_turn) do
    %{
      operation: active_turn.operation,
      thread_id: public_request_id(active_turn.thread_id),
      turn_id: public_request_id(active_turn.turn_id)
    }
  end

  defp redact_terminal_delivery(nil), do: nil
  defp redact_terminal_delivery(%{method: method}), do: %{method: method}

  defp redact_adapter(nil), do: nil
  defp redact_adapter(adapter), do: %{os_pid: adapter_os_pid(adapter), present: true}

  defp redact_failure(nil), do: nil

  defp redact_failure(%TransportError{} = failure) do
    %{kind: failure.kind, message: failure.message}
  end

  defp handle_stdout(bytes, state) do
    case JSONLFramer.push(state.framer, bytes) do
      {:ok, frames, framer} ->
        next_state = %{state | framer: framer}

        case process_frames(frames, next_state) do
          {:ok, processed_state, actions} ->
            {:noreply, apply_actions(processed_state, Enum.reverse(actions))}

          {:error, error, processed_state, actions} ->
            {:noreply, fail_connection(processed_state, error, actions)}
        end

      {:error, {:frame_too_large, details}} ->
        error = transport_error(state, :frame_too_large, details)
        {:noreply, fail_connection(state, error, [])}
    end
  end

  defp process_frames(frames, state) do
    Enum.reduce_while(frames, {:ok, state, []}, fn frame, {:ok, current_state, actions} ->
      case process_frame(frame, current_state) do
        {:ok, next_state, next_actions} ->
          {:cont, {:ok, next_state, Enum.reverse(next_actions, actions)}}

        {:error, error, next_state} ->
          {:halt, {:error, error, next_state, actions}}
      end
    end)
  end

  defp process_frame(<<>>, state) do
    {:error, transport_error(state, :stdout_contamination, %{reason: :blank_frame}), state}
  end

  defp process_frame(frame, state) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, %{} = payload} ->
        route_payload(payload, frame, state)

      {:ok, _other} ->
        {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :non_object_json}), state}

      {:error, _reason} ->
        kind = if json_candidate?(frame), do: :malformed_json, else: :stdout_contamination
        {:error, transport_error(state, kind, %{frame_bytes: byte_size(frame)}), state}
    end
  end

  defp route_payload(%{"method" => method} = payload, raw, state) when is_binary(method) do
    route_server_message(payload, raw, state)
  end

  defp route_payload(%{"id" => _request_id} = payload, _raw, state) do
    route_response(payload, state)
  end

  defp route_payload(_payload, _raw, state) do
    {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :unknown_envelope}), state}
  end

  defp route_response(%{"id" => request_id, "result" => result} = payload, state) do
    if exact_keys?(payload, ["id", "result"]) and valid_request_id?(request_id) do
      resolve_response(request_id, {:result, result}, state)
    else
      {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_response_envelope}), state}
    end
  end

  defp route_response(%{"id" => request_id, "error" => error} = payload, state) do
    if exact_keys?(payload, ["error", "id"]) and valid_request_id?(request_id) and
         valid_error?(error) do
      resolve_response(request_id, {:error, error}, state)
    else
      {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_error_envelope}), state}
    end
  end

  defp route_response(_payload, state) do
    {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_response_envelope}), state}
  end

  defp resolve_response(request_id, response, state) do
    cond do
      MapSet.member?(state.completed_ids, request_id) ->
        {:error,
         transport_error(state, :duplicate_response_id, %{
           request_id: public_request_id(request_id)
         }), state}

      not is_nil(state.pending) and state.pending.id == request_id ->
        cond do
          pending_deadline_expired?(state) ->
            {:error, request_timeout_error(state), state}

          MapSet.size(state.completed_ids) >= state.max_completed_request_ids ->
            {:error,
             inbound_overflow_error(state, :completed_request_ids, %{
               limit: state.max_completed_request_ids
             }), state}

          true ->
            completed_ids = MapSet.put(state.completed_ids, request_id)
            resolve_pending_response(response, %{state | completed_ids: completed_ids})
        end

      true ->
        {:error,
         transport_error(state, :unexpected_response_id, %{
           request_id: public_request_id(request_id)
         }), state}
    end
  end

  defp resolve_pending_response({:result, result}, state) do
    metadata = request_metadata(state.pending)

    state =
      state
      |> maybe_track_side_effect(metadata)
      |> maybe_activate_turn(result, metadata)

    {from, next_state} = finish_pending(state)
    {:ok, next_state, [{:reply, from, {:ok, result, metadata}}]}
  end

  defp resolve_pending_response({:error, %{"code" => @overload_code} = error}, state) do
    handle_overload(error, state)
  end

  defp resolve_pending_response({:error, error}, state) do
    transport_error = response_error(state, error)
    {from, next_state} = finish_pending(state)
    {:ok, next_state, [{:reply, from, {:error, transport_error}}]}
  end

  defp maybe_track_side_effect(state, %{method: method} = metadata)
       when method in ["thread/start", "turn/start"] do
    operation =
      Map.take(metadata, [
        :attempt,
        :classification,
        :method,
        :operation_id,
        :request_hash,
        :request_id,
        :run_id,
        :attempt_id,
        :send_state
      ])

    %{state | side_effect_operation: operation}
  end

  defp maybe_track_side_effect(state, _metadata), do: state

  defp maybe_activate_turn(
         %{pending: %{method: "turn/start", params: %{"threadId" => thread_id}}} = state,
         %{"turn" => %{"id" => turn_id}},
         request_metadata
       )
       when is_binary(thread_id) and is_binary(turn_id) do
    active_turn =
      %{
        operation:
          Map.take(request_metadata, [
            :attempt,
            :classification,
            :method,
            :operation_id,
            :request_hash,
            :request_id,
            :run_id,
            :attempt_id,
            :send_state
          ]),
        thread_id: thread_id,
        turn_id: turn_id
      }

    %{state | active_turn: active_turn}
  end

  defp maybe_activate_turn(state, _result, _request_metadata), do: state

  defp handle_overload(error, %{pending: pending} = state) do
    if RequestPolicy.retry_overload?(pending.method) do
      retry_idempotent_request(error, state)
    else
      transport_error =
        transport_error(state, :overloaded, %{
          code: @overload_code,
          method: pending.method,
          operation_id: pending.operation_id,
          request_hash: pending.request_hash,
          request_id: pending.id,
          retryable: false
        })

      {from, next_state} = finish_pending(state)
      {:ok, next_state, [{:reply, from, {:error, transport_error}}]}
    end
  end

  defp retry_idempotent_request(_error, %{pending: pending} = state)
       when pending.attempt >= state.overload_max_attempts do
    transport_error =
      transport_error(state, :overload_exhausted, %{
        attempts: pending.attempt,
        method: pending.method,
        operation_id: pending.operation_id,
        request_hash: pending.request_hash,
        request_id: pending.id
      })

    {from, next_state} = finish_pending(state)
    {:ok, next_state, [{:reply, from, {:error, transport_error}}]}
  end

  defp retry_idempotent_request(_error, %{pending: pending} = state) do
    delay_cap_ms =
      min(
        state.overload_backoff_max_ms,
        state.overload_backoff_base_ms * Integer.pow(2, min(pending.attempt - 1, 30))
      )

    delay_ms = bounded_jitter(state.jitter_fn, delay_cap_ms)
    remaining_ms = pending.deadline_ms - monotonic_ms()

    if remaining_ms <= delay_ms do
      transport_error =
        transport_error(state, :overload_exhausted, %{
          attempts: pending.attempt,
          method: pending.method,
          operation_id: pending.operation_id,
          reason: :absolute_deadline,
          request_hash: pending.request_hash,
          request_id: pending.id
        })

      {from, next_state} = finish_pending(state)
      {:ok, next_state, [{:reply, from, {:error, transport_error}}]}
    else
      retry_ref = Process.send_after(self(), {:overload_retry, pending.token}, delay_ms)

      safe_callback(state.on_retry, %{
        attempt: pending.attempt + 1,
        delay_ms: delay_ms,
        method: pending.method,
        operation_id: pending.operation_id,
        request_hash: pending.request_hash
      })

      {:ok, %{state | pending: %{pending | retry_ref: retry_ref}}, []}
    end
  end

  defp route_server_message(%{"id" => request_id, "method" => method} = payload, raw, state)
       when (is_integer(request_id) or is_binary(request_id)) and is_binary(method) do
    params = Map.get(payload, "params", %{})

    if exact_keys?(payload, ["id", "method", "params"]) and is_map(params) do
      hash = RequestPolicy.canonical_hash(method, params)
      handle_server_request(request_id, hash, payload, raw, state)
    else
      {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_server_request}), state}
    end
  end

  defp route_server_message(%{"method" => method} = payload, raw, state)
       when is_binary(method) do
    params = Map.get(payload, "params", %{})

    if exact_keys?(payload, ["method", "params"]) and is_map(params) do
      case validate_terminal_message(method, payload, state) do
        {:ok, next_state, :deliver} ->
          {:ok, next_state, [{:deliver, %{payload: payload, raw: raw}}]}

        {:ok, next_state, :suppress} ->
          {:ok, next_state, []}

        {:error, error} ->
          {:error, error, state}
      end
    else
      {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_notification}), state}
    end
  end

  defp route_server_message(_payload, _raw, state) do
    {:error, transport_error(state, :invalid_json_rpc_frame, %{reason: :invalid_server_envelope}), state}
  end

  defp handle_server_request(request_id, hash, payload, raw, state) do
    case Map.fetch(state.server_requests, request_id) do
      :error ->
        request_bytes = byte_size(raw)
        next_server_request_bytes = state.server_request_bytes + request_bytes

        cond do
          map_size(state.server_requests) >= state.max_server_requests ->
            {:error,
             inbound_overflow_error(state, :server_requests, %{
               limit: state.max_server_requests
             }), state}

          next_server_request_bytes > state.max_server_request_bytes ->
            {:error,
             inbound_overflow_error(state, :server_request_bytes, %{
               limit: state.max_server_request_bytes,
               unit: :bytes
             }), state}

          true ->
            server_requests =
              Map.put(state.server_requests, request_id, %{
                hash: hash,
                request_bytes: request_bytes,
                response: nil
              })

            {:ok,
             %{
               state
               | server_requests: server_requests,
                 server_request_bytes: next_server_request_bytes
             }, [{:deliver, %{payload: payload, raw: raw}}]}
        end

      {:ok, %{hash: ^hash, response: nil}} ->
        {:ok, state, []}

      {:ok, %{hash: ^hash, response: response}} ->
        {:ok, state, [{:wire, response}]}

      {:ok, _different_request} ->
        {:error,
         transport_error(state, :invalid_json_rpc_frame, %{
           reason: :server_request_id_reused,
           request_id: public_request_id(request_id)
         }), state}
    end
  end

  defp validate_terminal_message(method, payload, state)
       when method in ["turn/completed", "turn/failed", "turn/cancelled"] do
    with {:ok, terminal_key} <- terminal_turn_key(payload, state) do
      cond do
        MapSet.member?(
          state.completed_terminal_turns,
          terminal_turn_digest(terminal_key)
        ) ->
          {:error,
           transport_error(state, :invalid_json_rpc_frame, %{
             reason: :duplicate_terminal_notification
           })}

        is_nil(state.active_turn) ->
          remember_suppressed_terminal(state, terminal_key)

        elem(terminal_key, 0) != state.active_turn.thread_id ->
          remember_suppressed_terminal(state, terminal_key)

        elem(terminal_key, 1) != state.active_turn.turn_id ->
          {:error,
           transport_error(state, :invalid_json_rpc_frame, %{
             reason: :terminal_turn_mismatch
           })}

        is_nil(state.terminal_delivery) ->
          {thread_id, turn_id} = terminal_key

          {:ok,
           %{
             state
             | terminal_delivery: %{
                 method: method,
                 thread_id: thread_id,
                 turn_id: turn_id
               }
           }, :deliver}

        true ->
          {:error,
           transport_error(state, :invalid_json_rpc_frame, %{
             reason: :terminal_delivery_unacknowledged
           })}
      end
    end
  end

  defp validate_terminal_message(_method, _payload, state), do: {:ok, state, :deliver}

  defp remember_suppressed_terminal(state, terminal_key) do
    with {:ok, next_state} <- remember_terminal_turn(state, terminal_key) do
      {:ok, next_state, :suppress}
    end
  end

  defp terminal_turn_key(payload, state) do
    thread_id = get_in(payload, ["params", "threadId"])
    turn_id = get_in(payload, ["params", "turn", "id"])

    if is_binary(thread_id) and thread_id != "" and is_binary(turn_id) and turn_id != "" do
      {:ok, {thread_id, turn_id}}
    else
      {:error,
       transport_error(state, :invalid_json_rpc_frame, %{
         reason: :invalid_terminal_identity
       })}
    end
  end

  defp remember_terminal_turn(state, terminal_key) do
    if MapSet.size(state.completed_terminal_turns) >= state.max_completed_request_ids do
      {:error,
       inbound_overflow_error(state, :completed_terminal_turns, %{
         limit: state.max_completed_request_ids
       })}
    else
      {:ok,
       %{
         state
         | completed_terminal_turns:
             MapSet.put(
               state.completed_terminal_turns,
               terminal_turn_digest(terminal_key)
             )
       }}
    end
  end

  defp terminal_turn_digest({thread_id, turn_id}) do
    :crypto.hash(
      :sha256,
      [
        @terminal_identity_domain,
        <<byte_size(thread_id)::unsigned-big-64>>,
        thread_id,
        <<byte_size(turn_id)::unsigned-big-64>>,
        turn_id
      ]
    )
  end

  defp apply_actions(state, []), do: state

  defp apply_actions(state, [{:reply, from, reply} | rest]) do
    GenServer.reply(from, reply)
    apply_actions(state, rest)
  end

  defp apply_actions(state, [{:deliver, message} | rest]) do
    case deliver_message(state, message) do
      {:ok, next_state} -> apply_actions(next_state, rest)
      {:error, error, next_state} -> fail_connection(next_state, error, rest)
    end
  end

  defp apply_actions(state, [{:wire, payload} | rest]) do
    case send_wire(state, payload) do
      :ok -> apply_actions(state, rest)
      {:error, error} -> fail_connection(state, error, rest)
    end
  end

  defp deliver_message(%{waiter: nil} = state, message) do
    message_bytes = retained_message_bytes(message)
    next_count = state.queue_count + 1
    next_bytes = state.queue_bytes + message_bytes

    cond do
      next_count > state.max_queued_messages ->
        {:error,
         inbound_overflow_error(state, :message_queue, %{
           limit: state.max_queued_messages,
           unit: :messages
         }), state}

      next_bytes > state.max_queued_bytes ->
        {:error,
         inbound_overflow_error(state, :message_queue, %{
           limit: state.max_queued_bytes,
           unit: :bytes
         }), state}

      true ->
        {:ok,
         %{
           state
           | queue: :queue.in(message, state.queue),
             queue_bytes: next_bytes,
             queue_count: next_count
         }}
    end
  end

  defp deliver_message(%{waiter: waiter} = state, message) do
    if monotonic_ms() >= waiter.deadline_ms do
      {:error, message_timeout_error(state), state}
    else
      cancel_timer(waiter.timer_ref)
      GenServer.reply(waiter.from, {:ok, message})
      {:ok, %{state | waiter: nil}}
    end
  end

  defp send_pending_request(%{pending: pending} = state) do
    if monotonic_ms() >= pending.deadline_ms do
      {:error, request_timeout_error(state), state}
    else
      request_id = state.next_id
      payload = request_payload(request_id, pending.method, pending.params)

      sending_pending =
        %{pending | id: request_id, send_state: :transmission_uncertain}

      sending_state = %{state | pending: sending_pending}

      case send_wire_until(sending_state, payload, pending.deadline_ms) do
        :ok ->
          next_pending = %{sending_pending | send_state: :sent}
          metadata = request_metadata(next_pending)
          safe_callback(state.on_request, metadata)

          {:ok, %{state | next_id: request_id + 1, pending: next_pending}}

        {:error, error} ->
          {:error, error, sending_state}
      end
    end
  end

  defp request_payload(request_id, method, :omitted) do
    %{"id" => request_id, "method" => method}
  end

  defp request_payload(request_id, method, %{} = params) do
    %{"id" => request_id, "method" => method, "params" => params}
  end

  defp send_wire(%{adapter: nil} = state, _payload) do
    {:error, transport_error(state, :connection_closed, %{})}
  end

  defp send_wire(state, payload) do
    send_wire_until(state, payload, monotonic_ms() + state.write_timeout_ms)
  end

  defp send_wire_until(%{adapter: nil} = state, _payload, _deadline_ms) do
    {:error, transport_error(state, :connection_closed, %{})}
  end

  defp send_wire_until(state, payload, deadline_ms) do
    case send_wire_until_with_limit(
           state,
           payload,
           deadline_ms,
           state.max_outbound_frame_bytes
         ) do
      {:ok, _encoded_bytes} -> :ok
      {:error, %TransportError{} = error} -> {:error, error}
    end
  end

  defp send_wire_until_with_limit(%{adapter: nil} = state, _payload, _deadline_ms, _limit) do
    {:error, transport_error(state, :connection_closed, %{})}
  end

  defp send_wire_until_with_limit(state, payload, deadline_ms, limit_bytes) do
    remaining_ms = deadline_ms - monotonic_ms()
    effective_limit = min(state.max_outbound_frame_bytes, max(limit_bytes, 0))

    result =
      if remaining_ms > 0 do
        bounded_encode_and_send(
          state.process_adapter,
          state.adapter,
          payload,
          remaining_ms,
          effective_limit
        )
      else
        {:error, :timeout}
      end

    case result do
      {:ok, encoded_bytes} ->
        {:ok, encoded_bytes}

      {:error, reason} ->
        {:error,
         transport_error(state, :write_failed, %{
           reason: adapter_failure_category(:send, reason)
         })}
    end
  end

  defp bounded_encode_and_send(
         process_adapter,
         adapter,
         payload,
         timeout_ms,
         limit_bytes
       ) do
    parent = self()
    token = make_ref()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        result = safe_encode_and_send(process_adapter, adapter, payload, limit_bytes)
        send(parent, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
        {:error, :adapter_write_failed}
    after
      timeout_ms ->
        Process.exit(worker, :kill)
        Process.demonitor(monitor_ref, [:flush])
        {:error, :timeout}
    end
  end

  defp safe_encode_and_send(process_adapter, adapter, payload, limit_bytes) do
    encoded =
      payload
      |> Jason.encode_to_iodata!()
      |> then(&IO.iodata_to_binary([&1, ?\n]))

    encoded_bytes = byte_size(encoded)

    if encoded_bytes > limit_bytes do
      {:error, :outbound_frame_too_large}
    else
      case process_adapter.send(adapter, encoded) do
        :ok -> {:ok, encoded_bytes}
        {:error, _reason} = error -> error
        _other -> {:error, :adapter_write_failed}
      end
    end
  rescue
    _error -> {:error, :request_encoding_failed}
  catch
    _kind, _reason -> {:error, :request_encoding_failed}
  end

  defp bounded_request_hash(method, params, deadline_ms) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      {:error, :absolute_deadline}
    else
      parent = self()
      token = make_ref()

      {worker, monitor_ref} =
        spawn_monitor(fn ->
          hash = RequestPolicy.canonical_hash(method, params)
          send(parent, {token, hash})
        end)

      receive do
        {^token, hash} when is_binary(hash) ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, hash}

        {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
          {:error, :request_hash_failed}
      after
        remaining_ms ->
          Process.exit(worker, :kill)
          Process.demonitor(monitor_ref, [:flush])
          {:error, :absolute_deadline}
      end
    end
  end

  defp finish_pending(%{pending: pending} = state) do
    cancel_pending_timers(pending)
    {pending.from, %{state | pending: nil}}
  end

  defp cancel_pending_timers(nil), do: :ok

  defp cancel_pending_timers(pending) do
    cancel_timer(pending.deadline_ref)
    cancel_timer(pending.retry_ref)
    :ok
  end

  defp fail_connection(%{failure: %TransportError{}} = state, _error, actions) do
    reply_actions_with_failure(actions, state.failure)
    state
  end

  defp fail_connection(state, %TransportError{} = original_error, actions) do
    original_error = maybe_uncertain(state, original_error)
    {stop_result, stopped_state} = stop_adapter(state)
    error = attach_cleanup_failure(original_error, stop_result)
    maybe_notify_transport_failure(stopped_state, error)
    reply_actions_with_failure(actions, error)

    if state.pending do
      cancel_pending_timers(state.pending)
      GenServer.reply(state.pending.from, {:error, error})
    end

    if state.waiter do
      cancel_timer(state.waiter.timer_ref)
      GenServer.reply(state.waiter.from, {:error, error})
    end

    next_state = %{
      stopped_state
      | active_turn: nil,
        framer: JSONLFramer.discard(stopped_state.framer),
        failure: error,
        pending: nil,
        queue: :queue.new(),
        queue_bytes: 0,
        queue_count: 0,
        server_request_bytes: 0,
        server_requests: %{},
        side_effect_operation: nil,
        terminal_delivery: nil,
        waiter: nil
    }

    next_state
  end

  defp attach_cleanup_failure(error, :ok), do: error

  defp attach_cleanup_failure(error, {:error, %TransportError{} = cleanup_error}) do
    cause =
      %{kind: error.kind, message: error.message}
      |> maybe_put_nested_cause(error.details[:cause])

    details =
      cleanup_error.details
      |> Map.put(:cause, cause)
      |> maybe_put_operation(error.details[:operation])

    %{cleanup_error | details: details}
  end

  defp maybe_put_nested_cause(cause, nested_cause) when is_map(nested_cause),
    do: Map.put(cause, :cause, nested_cause)

  defp maybe_put_nested_cause(cause, _nested_cause), do: cause

  defp reply_actions_with_failure(actions, error) do
    actions
    |> Enum.filter(fn
      {:reply, _from, _reply} -> true
      _other -> false
    end)
    |> Enum.each(fn {:reply, from, _reply} -> GenServer.reply(from, {:error, error}) end)
  end

  defp maybe_uncertain(_state, %TransportError{kind: :uncertain_external_outcome} = error),
    do: error

  defp maybe_uncertain(state, error) do
    case unresolved_operation(state) do
      nil -> error
      operation -> uncertain_error(state, error, operation)
    end
  end

  defp uncertain_error(state, cause, operation) do
    transport_error(state, :uncertain_external_outcome, %{
      cause: %{kind: cause.kind, message: cause.message},
      operation: operation,
      reconciliation_required: true
    })
  end

  defp process_exit_error(state, reason) do
    case JSONLFramer.finish(state.framer) do
      :ok ->
        transport_error(state, :process_exit, process_exit_details(reason))

      {:error, {:truncated_frame, details}} ->
        transport_error(state, :truncated_frame, details)
    end
  end

  defp process_exit_details({:exit_status, status}) when is_integer(status),
    do: %{reason: :nonzero_exit, raw_wait_status: status}

  defp process_exit_details(:normal), do: %{reason: :normal_exit}
  defp process_exit_details(:shutdown), do: %{reason: :shutdown}
  defp process_exit_details({:shutdown, _detail}), do: %{reason: :shutdown}
  defp process_exit_details(:killed), do: %{reason: :killed}
  defp process_exit_details(_reason), do: %{reason: :unknown_exit}

  defp stop_adapter(%{adapter: nil} = state), do: {:ok, state}

  defp stop_adapter(%{cleanup_authority: :guardian} = state) do
    error =
      transport_error(state, :process_cleanup_failed, %{
        reason: :cleanup_in_progress
      })

    {{:error, error}, state}
  end

  defp stop_adapter(state) do
    cleanup_wait_timeout_ms = state.kill_timeout_ms + 2_500

    case CleanupGuardian.request_cleanup_once(
           state.cleanup_guardian,
           cleanup_wait_timeout_ms
         ) do
      :ok ->
        {:ok,
         %{
           state
           | adapter: nil,
             cleanup_authority: :verified,
             cleanup_guardian: nil,
             cleanup_guardian_handed_off?: false,
             cleanup_retry_deadline_ms: nil,
             cleanup_retry_ref: cancel_cleanup_retry(state.cleanup_retry_ref)
         }}

      {:error, reason} ->
        error =
          transport_error(state, :process_cleanup_failed, %{
            reason: adapter_failure_category(:stop, reason)
          })

        {{:error, error}, %{state | cleanup_authority: :guardian}}
    end
  end

  defp close_connection(state, operation_error) do
    case stop_adapter(state) do
      {:ok, next_state} ->
        if operation_error do
          maybe_notify_transport_failure(next_state, operation_error)
          {:stop, :normal, {:error, operation_error}, %{next_state | failure: operation_error}}
        else
          {:stop, :normal, :ok, next_state}
        end

      {{:error, cleanup_error}, next_state} ->
        base_error = operation_error || state.failure
        error = attach_optional_cleanup_failure(base_error, cleanup_error)

        maybe_notify_transport_failure(next_state, error)

        {:reply, {:error, error}, %{next_state | cleanup_failure_notified: true, failure: error}}
    end
  end

  defp unresolved_side_effect_error(state, phase) do
    operation = unresolved_operation(state)

    if operation do
      cause = transport_error(state, :connection_closed, %{phase: phase})
      uncertain_error(state, cause, operation)
    end
  end

  defp unresolved_operation(state) do
    pending = Map.get(state, :pending)
    active_turn = Map.get(state, :active_turn)
    side_effect_operation = Map.get(state, :side_effect_operation)

    cond do
      is_map(pending) and
        pending.send_state in [:sent, :transmission_uncertain] and
          RequestPolicy.uncertain_after_send?(pending.method) ->
        request_metadata(pending)

      is_map(active_turn) and is_map(active_turn[:operation]) ->
        active_turn.operation

      is_map(side_effect_operation) ->
        side_effect_operation

      true ->
        nil
    end
  end

  defp attach_optional_cleanup_failure(nil, cleanup_error), do: cleanup_error

  defp attach_optional_cleanup_failure(%TransportError{} = error, cleanup_error) do
    attach_cleanup_failure(error, {:error, cleanup_error})
  end

  defp maybe_notify_transport_failure(_state, nil), do: :ok

  defp maybe_notify_transport_failure(state, %TransportError{} = error) do
    safe_callback(state.on_transport_failure, error)
  end

  defp detach_handed_off_cleanup(state) do
    %{
      state
      | adapter: nil,
        cleanup_guardian: nil,
        cleanup_retry_deadline_ms: nil,
        cleanup_retry_ref: cancel_cleanup_retry(state.cleanup_retry_ref)
    }
  end

  defp detach_connection_owner(state) do
    if is_reference(state.owner_ref) do
      Process.demonitor(state.owner_ref, [:flush])
    end

    %{state | owner: nil, owner_ref: nil}
  end

  defp cancel_cleanup_retry(nil), do: nil

  defp cancel_cleanup_retry(ref) do
    cancel_timer(ref)
    nil
  end

  defp append_stderr(state, bytes) do
    %{state | stderr_diagnostics: StderrDiagnostics.append(state.stderr_diagnostics, bytes)}
  end

  defp connection_metadata(state) do
    adapter_metadata =
      if state.adapter, do: state.process_adapter.metadata(state.adapter), else: %{}

    adapter_metadata
    |> Map.merge(state.metadata)
    |> Map.merge(active_turn_metadata(state.active_turn))
  end

  defp diagnostic_metadata(state) do
    Map.merge(
      %{
        os_pid: adapter_os_pid(state.adapter),
        schema_version: state.schema_version
      },
      StderrDiagnostics.public_summary(state.stderr_diagnostics)
    )
    |> Map.merge(Map.take(state.metadata, [:attempt_id, :run_id]))
    |> Map.merge(active_turn_metadata(state.active_turn))
  end

  defp transport_error(state, kind, details) do
    TransportError.new(kind, Map.merge(diagnostic_metadata(state), details))
  end

  defp response_error(state, error) do
    transport_error(state, :response_error, %{
      code: error["code"],
      data_present: Map.has_key?(error, "data"),
      message_present: Map.get(error, "message", "") != "",
      method: state.pending.method,
      operation_id: state.pending.operation_id,
      request_hash: state.pending.request_hash,
      request_id: state.pending.id
    })
  end

  defp request_metadata(pending) do
    %{
      attempt: pending.attempt,
      classification: pending.classification,
      method: pending.method,
      operation_id: pending.operation_id,
      request_hash: pending.request_hash,
      request_id: pending.id,
      run_id: Map.get(pending, :run_id),
      attempt_id: Map.get(pending, :attempt_id),
      send_state: normalize_send_state(pending.send_state)
    }
  end

  defp normalize_send_state(:sent), do: :sent
  defp normalize_send_state(_other), do: :transmission_uncertain

  defp valid_error?(%{"code" => code, "message" => message} = error)
       when is_integer(code) and is_binary(message) do
    Map.keys(error) -- ["code", "data", "message"] == []
  end

  defp valid_error?(_error), do: false

  defp valid_request_id?(request_id), do: is_integer(request_id) or is_binary(request_id)

  defp public_request_id(request_id) when is_integer(request_id), do: request_id

  defp public_request_id(request_id) when is_binary(request_id) do
    %{bytes: byte_size(request_id), type: :string}
  end

  defp public_request_id(_request_id), do: %{type: :invalid}

  defp exact_keys?(payload, allowed) do
    Map.keys(payload) -- allowed == [] and allowed -- Map.keys(payload) == []
  end

  defp json_candidate?(frame) do
    frame
    |> trim_ascii_whitespace()
    |> case do
      <<first, _rest::binary>> when first in [?{, ?[] -> true
      _other -> false
    end
  end

  defp trim_ascii_whitespace(<<byte, rest::binary>>) when byte in [9, 10, 13, 32],
    do: trim_ascii_whitespace(rest)

  defp trim_ascii_whitespace(bytes), do: bytes

  defp bounded_jitter(jitter_fn, cap_ms) do
    case safe_jitter(jitter_fn, cap_ms) do
      value when is_integer(value) and value >= 0 and value <= cap_ms -> value
      _invalid -> cap_ms
    end
  end

  defp safe_jitter(jitter_fn, cap_ms) do
    jitter_fn.(cap_ms)
  rescue
    _error -> cap_ms
  catch
    _kind, _reason -> cap_ms
  end

  defp default_jitter(0), do: 0
  defp default_jitter(cap_ms), do: :rand.uniform(cap_ms + 1) - 1

  defp safe_callback(callback, value) do
    callback.(value)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp adapter_failure_category(:start, {:invalid_argv, _detail}), do: :invalid_configuration
  defp adapter_failure_category(:start, {:invalid_options, _detail}), do: :invalid_configuration
  defp adapter_failure_category(:start, {:invalid_env, _detail}), do: :invalid_configuration
  defp adapter_failure_category(:start, {:invalid_cd, _detail}), do: :invalid_configuration

  defp adapter_failure_category(
         :start,
         {:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence}}
       ),
       do: :startup_rollback_unverified

  defp adapter_failure_category(
         :start,
         {:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence, %CleanupGuardian.Handle{}}}
       ),
       do: :startup_rollback_unverified

  defp adapter_failure_category(:start, :timeout), do: :start_timeout
  defp adapter_failure_category(:start, {:error, :enoent}), do: :executable_not_found
  defp adapter_failure_category(:start, :enoent), do: :executable_not_found
  defp adapter_failure_category(:start, _reason), do: :adapter_start_failed

  defp adapter_failure_category(:send, :noproc), do: :connection_closed
  defp adapter_failure_category(:send, {:error, :noproc}), do: :connection_closed
  defp adapter_failure_category(:send, :timeout), do: :write_timeout

  defp adapter_failure_category(:send, :outbound_frame_too_large),
    do: :outbound_frame_too_large

  defp adapter_failure_category(:send, :request_encoding_failed),
    do: :request_encoding_failed

  defp adapter_failure_category(:send, _reason), do: :adapter_write_failed

  defp adapter_failure_category(:stop, {:cleanup_timeout, _detail}), do: :cleanup_timeout
  defp adapter_failure_category(:stop, :timeout), do: :cleanup_timeout
  defp adapter_failure_category(:stop, _reason), do: :adapter_stop_failed

  defp process_start_error_kind({:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence}}),
    do: :process_cleanup_failed

  defp process_start_error_kind({:process_identity_unavailable, _reason, {:startup_rollback_unverified, _evidence, %CleanupGuardian.Handle{}}}),
    do: :process_cleanup_failed

  defp process_start_error_kind(_reason), do: :process_start_failed

  defp pending_deadline_expired?(%{pending: %{deadline_ms: deadline_ms}}),
    do: monotonic_ms() >= deadline_ms

  defp pending_deadline_expired?(_state), do: false

  defp waiter_deadline_expired?(%{waiter: %{deadline_ms: deadline_ms}}),
    do: monotonic_ms() >= deadline_ms

  defp waiter_deadline_expired?(_state), do: false

  defp request_timeout_error(%{pending: pending} = state) do
    transport_error(state, :request_timeout, %{
      attempt: pending.attempt,
      method: pending.method,
      operation_id: pending.operation_id,
      request_hash: pending.request_hash,
      request_id: pending.id,
      send_state: pending.send_state
    })
  end

  defp message_timeout_error(state) do
    transport_error(state, :request_timeout, %{phase: :message_wait})
  end

  defp inbound_overflow_error(state, collection, details) do
    transport_error(
      state,
      :inbound_state_overflow,
      Map.merge(details, %{collection: collection})
    )
  end

  defp retained_message_bytes(%{raw: raw}) when is_binary(raw), do: byte_size(raw)
  defp retained_message_bytes(_message), do: 0

  defp maybe_put_operation(details, nil), do: details
  defp maybe_put_operation(details, operation), do: Map.put(details, :operation, operation)

  defp active_turn_metadata(%{
         operation: operation,
         thread_id: thread_id,
         turn_id: turn_id
       })
       when is_map(operation) do
    operation
    |> Map.take([:attempt_id, :operation_id, :run_id])
    |> Map.put(:thread_id, thread_id)
    |> Map.put(:turn_id, turn_id)
  end

  defp active_turn_metadata(_active_turn), do: %{}

  defp new_operation_id(%{id_generator: generator}) when is_function(generator, 0) do
    case generator.() do
      operation_id when is_binary(operation_id) ->
        if operation_id == String.downcase(operation_id) and Identity.valid_uuid4?(operation_id),
          do: operation_id,
          else: Identity.uuid4()

      _other ->
        Identity.uuid4()
    end
  end

  defp new_operation_id(_state), do: Identity.uuid4()

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer_ref) do
    Process.cancel_timer(timer_ref, async: true, info: false)
    :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp adapter_pid(nil), do: nil
  defp adapter_pid(adapter), do: adapter.pid

  defp adapter_os_pid(nil), do: nil
  defp adapter_os_pid(adapter), do: adapter.os_pid

  defp redact_pending(nil), do: nil

  defp redact_pending(pending) do
    pending
    |> Map.drop([:from, :params])
    |> Map.put(:params, "[REDACTED]")
  end

  defp close_unverified_error(reason) do
    stderr_summary =
      @default_stderr_tail_bytes
      |> StderrDiagnostics.new()
      |> StderrDiagnostics.public_summary()

    TransportError.new(
      :process_cleanup_failed,
      Map.merge(stderr_summary, %{
        cleanup_verified: false,
        os_pid: nil,
        reason: close_exit_category(reason),
        schema_version: SchemaBundle.version()
      })
    )
  end

  defp close_exit_category({:noproc, _call}), do: :connection_unavailable
  defp close_exit_category({:normal, _call}), do: :connection_unavailable
  defp close_exit_category({:shutdown, _call}), do: :connection_unavailable
  defp close_exit_category({:timeout, _call}), do: :cleanup_timeout
  defp close_exit_category(_reason), do: :connection_unavailable
end
