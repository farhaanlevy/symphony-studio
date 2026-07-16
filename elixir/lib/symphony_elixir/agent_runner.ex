# Downstream modification notice (2026-07-16): Symphony Studio propagates
# stable run/attempt correlation, owns cooperative cancellation and supervised
# hook containment, and preserves typed App Server blockers.
defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger

  alias SymphonyElixir.Codex.{
    AppServer,
    CleanupBarrier,
    CleanupGuardian,
    Connection,
    TransportError
  }

  alias SymphonyElixir.{
    Config,
    Identity,
    Linear.Issue,
    PromptBuilder,
    Tracker,
    Workspace,
    WorkspaceHookRunner
  }

  @remote_workers_error {:unsupported_release_feature, :remote_workers, :release_5}
  @cancel_discovery_ms 50
  @cancel_settle_ms 100
  @hook_retirement_ms 5_000
  @attempt_runtime_message_tags [
    :agent_attempt_cleanup_authority,
    :agent_attempt_connection,
    :agent_attempt_connection_state,
    :agent_attempt_hook_runner,
    :agent_attempt_result,
    :agent_attempt_session,
    :agent_attempt_turn,
    :agent_attempt_workspace
  ]
  @protocol_failure_kinds [
    :duplicate_response_id,
    :frame_too_large,
    :inbound_state_overflow,
    :invalid_json_rpc_frame,
    :malformed_json,
    :stdout_contamination,
    :truncated_frame,
    :unexpected_response_id
  ]

  @type worker_host :: String.t() | nil

  @doc false
  @spec start_supervised(map(), pid() | nil, keyword()) :: DynamicSupervisor.on_start_child()
  def start_supervised(issue, codex_update_recipient \\ nil, opts \\ []) do
    Task.Supervisor.start_child(
      SymphonyElixir.TaskSupervisor,
      fn -> run(issue, codex_update_recipient, opts) end,
      shutdown: :infinity
    )
  end

  @doc false
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec transport_blocker_update_for_test(term()) :: map() | nil
  def transport_blocker_update_for_test(reason), do: transport_blocker_update(reason)

  @doc false
  @spec cancellation_finish_result_for_test(term(), term()) :: :ok | {:error, term()}
  def cancellation_finish_result_for_test(attempt_result, cancellation_result) do
    cancellation_finish_result(
      %{result: normalize_attempt_result(attempt_result)},
      cancellation_result
    )
  end

  @doc false
  @spec connection_retired_for_test(pid() | atom(), CleanupGuardian.Handle.t() | nil) ::
          boolean()
  def connection_retired_for_test(connection, cleanup_handle) do
    cleanup_authority =
      case cleanup_handle do
        %CleanupGuardian.Handle{} = handle -> %{handle: handle}
        nil -> nil
      end

    connection_retired?(%{
      connection: connection,
      startup_cleanup_authority: cleanup_authority,
      startup_cleanup_verified?: is_nil(cleanup_handle)
    })
  end

  @doc false
  @spec turn_runtime_id_for_test(String.t() | nil, map()) :: String.t() | nil
  def turn_runtime_id_for_test(current_turn_id, message) do
    case turn_runtime_update(message) do
      {:set, turn_id} -> turn_id
      :clear -> nil
      :unchanged -> current_turn_id
    end
  end

  @doc false
  @spec cancel(pid(), non_neg_integer()) ::
          {:ok, %{workspace_path: Path.t() | nil, workspace_root: Path.t() | nil}}
          | {:error, term()}
  def cancel(controller, timeout_ms) when is_pid(controller) and is_integer(timeout_ms) and timeout_ms >= 0 do
    if Process.alive?(controller),
      do: do_cancel(controller, timeout_ms),
      else: {:error, :agent_cancel_controller_not_alive}
  end

  defp do_cancel(controller, timeout_ms) do
    token = make_ref()
    monitor_ref = Process.monitor(controller)
    send(controller, {:cancel_agent_attempt, self(), token})

    receive do
      {:agent_attempt_cancelled, ^token, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^controller, reason} ->
        {:error, {:agent_cancel_controller_exit, exit_category(reason)}}
    after
      timeout_ms ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, :agent_cancel_timeout}
    end
  end

  @doc false
  @spec cancellation_timeout_ms() :: pos_integer()
  def cancellation_timeout_ms do
    settings = Config.settings!()

    settings.codex.read_timeout_ms * 2 +
      settings.hooks.timeout_ms * 3 +
      settings.codex.process_kill_timeout_ms * 6 + 15_000
  end

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)
    opts = Keyword.put(opts, :correlation, correlation_context(opts))

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    previous_trap_exit = Process.flag(:trap_exit, true)
    register_runtime_member!()
    attempt_token = make_ref()
    controller = self()

    worker =
      spawn_link(fn ->
        result = safely_run_attempt(issue, codex_update_recipient, opts, worker_host, controller, attempt_token)
        send(controller, {:agent_attempt_result, attempt_token, result})
      end)

    result =
      try do
        await_attempt(%{
          after_run_complete?: false,
          attempt_token: attempt_token,
          cancel_waiters: [],
          codex_update_recipient: codex_update_recipient,
          connection: :not_started,
          correlation: correlation_from_opts(opts),
          external_exit: nil,
          hook_cleanup_error: nil,
          hook_cleanup_verified?: true,
          hook_runner: nil,
          issue: issue,
          result: :pending,
          session: nil,
          startup_cleanup_authority: nil,
          startup_cleanup_verified?: true,
          worker: worker,
          worker_exit: :pending,
          worker_host: worker_host,
          workspace: nil,
          workspace_hook_runner: Keyword.get(opts, :workspace_hook_runner, WorkspaceHookRunner),
          workspace_root: nil,
          turn_id: nil
        })
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end

    finish_attempt(issue, result, codex_update_recipient, correlation_from_opts(opts))
  end

  defp register_runtime_member! do
    case CleanupBarrier.register_runtime_member(self()) do
      :ok -> :ok
      {:error, :barrier_unavailable} -> exit(:runtime_member_barrier_unavailable)
    end
  end

  defp safely_run_attempt(issue, codex_update_recipient, opts, worker_host, controller, attempt_token) do
    with :ok <- validate_release_worker(worker_host) do
      run_on_worker_host(
        issue,
        codex_update_recipient,
        opts,
        worker_host,
        controller,
        attempt_token
      )
    end
  rescue
    _error -> {:error, :agent_attempt_exception}
  catch
    _kind, _reason -> {:error, :agent_attempt_exit}
  end

  defp await_attempt(state) do
    case attempt_completion(state) do
      {:complete, result} ->
        {state, result} = finalize_attempt(state, result)
        complete_after_finalization(state, result)

      :pending ->
        receive_attempt_message(state)
    end
  end

  defp receive_attempt_message(state) do
    receive do
      {:DOWN, _ref, :process, _pid, _reason} = message ->
        handle_attempt_message(state, message)

      {:EXIT, _from, _reason} = message ->
        handle_attempt_message(state, message)

      {:cancel_agent_attempt, _caller, _cancel_token} = message ->
        handle_attempt_message(state, message)

      {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
        handle_attempt_message(state, message)
    end
  end

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_cleanup_authority, token, guardian}
       )
       when is_struct(guardian, CleanupGuardian.Handle),
       do: state |> put_startup_cleanup_authority(guardian) |> await_attempt()

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_connection, token, connection}
       )
       when is_pid(connection),
       do: await_attempt(%{state | connection: connection})

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_connection_state, token, connection_state}
       )
       when connection_state in [:cleanup_unverified, :not_started, :starting],
       do: await_attempt(put_connection_state(state, connection_state))

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_workspace, token, %{path: workspace, root: workspace_root}}
       )
       when is_binary(workspace) and is_binary(workspace_root),
       do:
         state
         |> put_attempt_workspace(%{path: workspace, root: workspace_root})
         |> await_attempt()

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_session, token, session}
       )
       when is_map(session),
       do: await_attempt(%{state | session: session})

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_turn, token, turn_id}
       )
       when is_binary(turn_id) or is_nil(turn_id),
       do: await_attempt(%{state | turn_id: turn_id})

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_hook_runner, token, event}
       ),
       do: state |> integrate_hook_runner_event(event) |> await_attempt()

  defp handle_attempt_message(
         %{attempt_token: token} = state,
         {:agent_attempt_result, token, result}
       ),
       do: await_attempt(%{state | result: normalize_attempt_result(result)})

  defp handle_attempt_message(%{worker: worker} = state, {:EXIT, worker, reason}),
    do: await_attempt(%{state | worker_exit: reason})

  defp handle_attempt_message(state, {:DOWN, ref, :process, pid, reason}),
    do: state |> integrate_cleanup_authority_down(ref, pid, reason) |> await_attempt()

  defp handle_attempt_message(state, {:cancel_agent_attempt, caller, cancel_token})
       when is_pid(caller) and is_reference(cancel_token) do
    state = %{state | cancel_waiters: [{caller, cancel_token}]}
    {state, cancellation_result} = cancel_attempt(state)
    finish_cancelled_attempt(state, cancellation_finish_result(state, cancellation_result))
  end

  defp handle_attempt_message(state, {:EXIT, _from, reason}) do
    {state, cancellation_result} = cancel_attempt(%{state | external_exit: reason})
    finish_external_exit(state, reason, cancellation_finish_result(state, cancellation_result))
  end

  defp handle_attempt_message(state, _message), do: await_attempt(state)

  defp finish_cancelled_attempt(state, outcome) do
    {state, result} = finalize_attempt(state, outcome)
    reply_cancel_waiters(state, result)
    complete_after_finalization(state, result)
  end

  defp finish_external_exit(state, reason, :ok) do
    case finalize_attempt(state, :ok) do
      {_state, :ok} -> {:external_exit, reason}
      {state, {:error, safety_reason}} -> hold_external_containment(state, reason, safety_reason)
    end
  end

  defp finish_external_exit(state, reason, {:error, safety_reason}) do
    hold_external_containment(state, reason, safety_reason)
  end

  defp hold_external_containment(state, external_reason, safety_reason) do
    Logger.error("Holding runtime restart behind unverified agent containment external_exit=#{exit_category(external_reason)} failure_kind=#{failure_kind(safety_reason)}")

    hold_external_containment_loop(state, external_reason, safety_reason)
  end

  defp hold_external_containment_loop(state, external_reason, safety_reason) do
    if recovered_containment?(state, safety_reason) do
      {:external_exit, external_reason}
    else
      receive do
        {:DOWN, ref, :process, pid, reason} ->
          state = integrate_cleanup_authority_down(state, ref, pid, reason)
          hold_external_containment_loop(state, external_reason, safety_reason)

        {:cancel_agent_attempt, caller, cancel_token}
        when is_pid(caller) and is_reference(cancel_token) ->
          send(caller, {:agent_attempt_cancelled, cancel_token, {:error, safety_reason}})
          hold_external_containment_loop(state, external_reason, safety_reason)

        {:EXIT, _from, _reason} ->
          hold_external_containment_loop(state, external_reason, safety_reason)

        {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
          state = integrate_attempt_message(state, message)
          hold_external_containment_loop(state, external_reason, safety_reason)
      end
    end
  end

  defp attempt_completion(%{worker_exit: :pending}), do: :pending

  defp attempt_completion(%{result: :pending, worker_exit: reason}),
    do: {:complete, {:error, {:agent_attempt_worker_exit, exit_category(reason)}}}

  defp attempt_completion(%{result: result, worker_exit: :normal}),
    do: {:complete, result}

  defp attempt_completion(%{worker_exit: reason}),
    do: {:complete, {:error, {:agent_attempt_worker_exit, exit_category(reason)}}}

  defp cancel_attempt(state) do
    state = collect_attempt_messages(state, @cancel_discovery_ms)
    interrupt_result = request_active_turn_interrupt(state)
    state = await_worker_retirement(state, cooperative_cancel_wait_ms(state))

    {state, retirement_result} =
      if worker_retired?(state) do
        {state, verify_connection_retired(state)}
      else
        retire_connection_and_worker(state)
      end

    state =
      state
      |> collect_attempt_messages(@cancel_discovery_ms)
      |> await_hook_runner_retirement(@hook_retirement_ms)

    hook_retirement_result = hook_runner_retirement_result(state)

    cancellation_result =
      cond do
        not worker_retired?(state) -> {:error, :agent_worker_not_retired}
        retirement_result != :ok -> retirement_result
        not connection_retired?(state) -> {:error, :app_server_process_not_retired}
        hook_retirement_result != :ok -> hook_retirement_result
        interrupt_result != :ok -> interrupt_result
        true -> :ok
      end

    {state, cancellation_result}
  end

  defp request_active_turn_interrupt(%{session: session, turn_id: turn_id})
       when is_map(session) and is_binary(turn_id) and turn_id != "" do
    case AppServer.interrupt_turn(session, turn_id) do
      :ok -> :ok
      {:error, _reason} -> {:error, :active_turn_interrupt_unverified}
    end
  catch
    :exit, _reason -> {:error, :active_turn_interrupt_unverified}
    _kind, _reason -> {:error, :active_turn_interrupt_unverified}
  end

  defp request_active_turn_interrupt(_state), do: :ok

  defp cooperative_cancel_wait_ms(%{connection: connection}) when is_pid(connection) do
    Config.settings!().codex.process_kill_timeout_ms + 1_000
  end

  defp cooperative_cancel_wait_ms(%{connection: :starting}) do
    Config.settings!().codex.process_kill_timeout_ms + 1_000
  end

  defp cooperative_cancel_wait_ms(%{workspace: workspace}) when is_binary(workspace) do
    Config.settings!().hooks.timeout_ms + 1_000
  end

  defp cooperative_cancel_wait_ms(_state), do: @cancel_settle_ms

  defp retire_connection_and_worker(state) do
    retirement_result = retire_connection(state)
    state = await_worker_retirement(state, Config.settings!().codex.process_kill_timeout_ms + 1_000)

    state =
      if worker_retired?(state) do
        state
      else
        Process.exit(state.worker, :shutdown)
        await_worker_retirement(state, Config.settings!().codex.process_kill_timeout_ms + 1_000)
      end

    state =
      if worker_retired?(state) do
        state
      else
        Process.exit(state.worker, :kill)
        await_worker_retirement(state, Config.settings!().codex.process_kill_timeout_ms + 1_000)
      end

    {state, retirement_result}
  end

  defp retire_connection(%{connection: :not_started}), do: :ok

  defp retire_connection(%{connection: :cleanup_unverified}),
    do: {:error, :app_server_process_cleanup_failed}

  defp retire_connection(%{connection: :starting}),
    do: {:error, :app_server_connection_discovery_incomplete}

  defp retire_connection(%{connection: connection} = state) when is_pid(connection) do
    if Process.alive?(connection) do
      result =
        case state.session do
          %{} = session -> AppServer.stop_session(session)
          _missing_session -> Connection.close(connection)
        end

      _ = await_process_exit(connection, Config.settings!().codex.process_kill_timeout_ms + 1_000)

      cond do
        Process.alive?(connection) -> normalize_retirement_error(result)
        result == :ok -> :ok
        true -> normalize_retirement_error(result)
      end
    else
      :ok
    end
  end

  defp verify_connection_retired(state) do
    if connection_retired?(state), do: :ok, else: retire_connection(state)
  end

  defp normalize_retirement_error({:error, %TransportError{kind: :process_cleanup_failed}}),
    do: {:error, :app_server_process_cleanup_failed}

  defp normalize_retirement_error({:error, %TransportError{kind: :uncertain_external_outcome}}),
    do: {:error, :app_server_uncertain_external_outcome}

  defp normalize_retirement_error({:error, _reason}),
    do: {:error, :app_server_process_not_retired}

  defp normalize_retirement_error(:ok), do: {:error, :app_server_process_not_retired}

  defp await_worker_retirement(state, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_worker_retirement(state, deadline_ms)
  end

  defp do_await_worker_retirement(state, deadline_ms) do
    state = collect_attempt_messages(state, 0)

    cond do
      worker_retired?(state) ->
        state

      monotonic_ms() >= deadline_ms ->
        state

      true ->
        remaining_ms = max(deadline_ms - monotonic_ms(), 0)

        receive do
          {:EXIT, _from, _reason} = message ->
            state
            |> integrate_attempt_message(message)
            |> do_await_worker_retirement(deadline_ms)

          {:cancel_agent_attempt, _caller, _cancel_token} = message ->
            state
            |> integrate_attempt_message(message)
            |> do_await_worker_retirement(deadline_ms)

          {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
            state
            |> integrate_attempt_message(message)
            |> do_await_worker_retirement(deadline_ms)
        after
          remaining_ms -> state
        end
    end
  end

  defp await_hook_runner_retirement(state, timeout_ms)
       when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline_ms = monotonic_ms() + timeout_ms
    do_await_hook_runner_retirement(state, deadline_ms)
  end

  defp do_await_hook_runner_retirement(state, deadline_ms) do
    state = collect_attempt_messages(state, 0)

    cond do
      is_nil(state.hook_runner) ->
        state

      monotonic_ms() >= deadline_ms ->
        state

      true ->
        remaining_ms = max(deadline_ms - monotonic_ms(), 0)

        receive do
          {:EXIT, _from, _reason} = message ->
            state
            |> integrate_attempt_message(message)
            |> do_await_hook_runner_retirement(deadline_ms)

          {:cancel_agent_attempt, _caller, _cancel_token} = message ->
            state
            |> integrate_attempt_message(message)
            |> do_await_hook_runner_retirement(deadline_ms)

          {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
            state
            |> integrate_attempt_message(message)
            |> do_await_hook_runner_retirement(deadline_ms)
        after
          remaining_ms -> state
        end
    end
  end

  defp hook_runner_retirement_result(%{hook_cleanup_error: error}) when not is_nil(error),
    do: {:error, error}

  defp hook_runner_retirement_result(%{hook_runner: nil}), do: :ok

  defp hook_runner_retirement_result(%{hook_runner: %{pid: runner}}) when is_pid(runner),
    do: {:error, :workspace_hook_runner_not_retired}

  defp collect_attempt_messages(state, timeout_ms) do
    receive do
      {:DOWN, ref, :process, pid, reason} ->
        state
        |> integrate_cleanup_authority_down(ref, pid, reason)
        |> collect_attempt_messages(0)

      {:EXIT, _from, _reason} = message ->
        state
        |> integrate_attempt_message(message)
        |> collect_attempt_messages(0)

      {:cancel_agent_attempt, _caller, _cancel_token} = message ->
        state
        |> integrate_attempt_message(message)
        |> collect_attempt_messages(0)

      {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
        state
        |> integrate_attempt_message(message)
        |> collect_attempt_messages(0)
    after
      timeout_ms -> state
    end
  end

  defp integrate_attempt_message(state, {:agent_attempt_connection, token, connection})
       when token == state.attempt_token and is_pid(connection),
       do: %{state | connection: connection}

  defp integrate_attempt_message(
         state,
         {:agent_attempt_cleanup_authority, token, guardian}
       )
       when token == state.attempt_token and is_struct(guardian, CleanupGuardian.Handle),
       do: put_startup_cleanup_authority(state, guardian)

  defp integrate_attempt_message(
         state,
         {:agent_attempt_connection_state, token, connection_state}
       )
       when token == state.attempt_token and
              connection_state in [:cleanup_unverified, :not_started, :starting],
       do: put_connection_state(state, connection_state)

  defp integrate_attempt_message(
         state,
         {:agent_attempt_workspace, token, %{path: workspace, root: workspace_root}}
       )
       when token == state.attempt_token and is_binary(workspace) and is_binary(workspace_root) do
    put_attempt_workspace(state, %{path: workspace, root: workspace_root})
  end

  defp integrate_attempt_message(state, {:agent_attempt_session, token, session})
       when token == state.attempt_token and is_map(session),
       do: %{state | session: session}

  defp integrate_attempt_message(state, {:agent_attempt_hook_runner, token, event})
       when token == state.attempt_token,
       do: integrate_hook_runner_event(state, event)

  defp integrate_attempt_message(state, {:agent_attempt_turn, token, turn_id})
       when token == state.attempt_token and (is_binary(turn_id) or is_nil(turn_id)),
       do: %{state | turn_id: turn_id}

  defp integrate_attempt_message(state, {:agent_attempt_result, token, result})
       when token == state.attempt_token,
       do: %{state | result: normalize_attempt_result(result)}

  defp integrate_attempt_message(state, {:EXIT, worker, reason}) when worker == state.worker,
    do: %{state | worker_exit: reason}

  defp integrate_attempt_message(
         state,
         {:cancel_agent_attempt, caller, cancel_token}
       )
       when is_pid(caller) and is_reference(cancel_token) do
    %{state | cancel_waiters: [{caller, cancel_token} | state.cancel_waiters]}
  end

  defp integrate_attempt_message(state, {:EXIT, _from, reason}),
    do: %{state | external_exit: state.external_exit || reason}

  defp integrate_attempt_message(state, _message), do: state

  defp put_startup_cleanup_authority(%{startup_cleanup_authority: nil} = state, guardian)
       when is_struct(guardian, CleanupGuardian.Handle) do
    %{
      state
      | startup_cleanup_authority: %{
          handle: guardian,
          pid: guardian.pid,
          ref: Process.monitor(guardian.pid)
        },
        startup_cleanup_verified?: false
    }
  end

  defp put_startup_cleanup_authority(state, _guardian), do: state

  defp integrate_cleanup_authority_down(
         %{startup_cleanup_authority: %{handle: handle, pid: pid, ref: ref}} = state,
         ref,
         pid,
         _reason
       ) do
    if CleanupGuardian.verified?(handle) do
      %{
        state
        | connection: :not_started,
          startup_cleanup_authority: nil,
          startup_cleanup_verified?: true
      }
    else
      %{
        state
        | startup_cleanup_authority: %{
            handle: handle,
            pid: pid,
            ref: ref,
            lost?: true
          }
      }
    end
  end

  defp integrate_cleanup_authority_down(state, _ref, _pid, _reason), do: state

  defp integrate_hook_runner_event(
         state,
         {hook_ref, {:workspace_hook_runner_started, runner}}
       )
       when is_reference(hook_ref) and is_pid(runner) do
    %{
      state
      | hook_cleanup_error: nil,
        hook_cleanup_verified?: false,
        hook_runner: %{ref: hook_ref, pid: runner}
    }
  end

  defp integrate_hook_runner_event(
         %{hook_runner: %{ref: hook_ref, pid: runner}} = state,
         {hook_ref, {:workspace_hook_runner_cleanup_failed, runner, _error}}
       )
       when is_reference(hook_ref) and is_pid(runner) do
    %{
      state
      | hook_cleanup_error: :workspace_hook_cleanup_unverified,
        hook_cleanup_verified?: false
    }
  end

  defp integrate_hook_runner_event(
         state,
         {hook_ref, {:workspace_hook_runner_stopped, runner, result}}
       )
       when is_reference(hook_ref) and is_pid(runner) do
    state = maybe_clear_hook_runner(state, hook_ref, runner)

    cond do
      hook_cleanup_failure_result?(result) ->
        %{
          state
          | hook_cleanup_error: :workspace_hook_cleanup_unverified,
            hook_cleanup_verified?: false
        }

      hook_result_verifies_containment?(result) ->
        %{state | hook_cleanup_error: nil, hook_cleanup_verified?: true}

      true ->
        %{state | hook_cleanup_verified?: false}
    end
  end

  defp integrate_hook_runner_event(state, _event), do: state

  defp maybe_clear_hook_runner(
         %{hook_runner: %{ref: hook_ref, pid: runner}} = state,
         hook_ref,
         runner
       ),
       do: %{state | hook_runner: nil}

  defp maybe_clear_hook_runner(state, _hook_ref, _runner), do: state

  defp put_connection_state(%{connection: connection} = state, _connection_state)
       when is_pid(connection),
       do: state

  defp put_connection_state(%{connection: :cleanup_unverified} = state, _connection_state),
    do: state

  defp put_connection_state(state, :cleanup_unverified),
    do: %{state | connection: :cleanup_unverified}

  defp put_connection_state(%{connection: :not_started} = state, :starting),
    do: %{state | connection: :starting}

  defp put_connection_state(%{connection: :starting} = state, :not_started),
    do: %{state | connection: :not_started}

  defp put_connection_state(state, _connection_state), do: state

  defp put_attempt_workspace(state, %{path: workspace, root: workspace_root} = binding) do
    send_worker_runtime_info(
      state.codex_update_recipient,
      state.issue,
      state.worker_host,
      binding,
      state.correlation
    )

    %{state | workspace: workspace, workspace_root: workspace_root}
  end

  defp worker_retired?(%{worker: worker, worker_exit: worker_exit}) do
    worker_exit != :pending or not Process.alive?(worker)
  end

  defp connection_retired?(%{connection: :not_started} = state),
    do: cleanup_authority_verified?(state)

  defp connection_retired?(%{connection: :cleanup_unverified}), do: false
  defp connection_retired?(%{connection: :starting}), do: false

  defp connection_retired?(%{connection: connection} = state) when is_pid(connection),
    do: not Process.alive?(connection) and cleanup_authority_verified?(state)

  defp cleanup_authority_verified?(%{startup_cleanup_authority: %{handle: handle}})
       when is_struct(handle, CleanupGuardian.Handle),
       do: CleanupGuardian.verified?(handle)

  defp cleanup_authority_verified?(state),
    do: Map.get(state, :startup_cleanup_verified?, true)

  defp await_process_exit(pid, timeout_ms) when is_pid(pid) and is_integer(timeout_ms) do
    monitor_ref = Process.monitor(pid)

    result =
      receive do
        {:DOWN, ^monitor_ref, :process, ^pid, _reason} -> :ok
      after
        max(timeout_ms, 0) -> :timeout
      end

    Process.demonitor(monitor_ref, [:flush])
    result
  end

  defp finalize_attempt(state, result) do
    discovery_ms = if cleanup_failure_result?(result), do: @cancel_discovery_ms, else: 0
    state = collect_attempt_messages(state, discovery_ms)

    if cleanup_failure_result?(result) do
      {state, result}
    else
      finalize_contained_attempt(state, result)
    end
  end

  defp finalize_contained_attempt(state, result) do
    state = await_hook_runner_retirement(state, @hook_retirement_ms)
    hook_retirement_result = hook_runner_retirement_result(state)
    safe_to_run_hook? = worker_retired?(state) and connection_retired?(state)

    cond do
      not safe_to_run_hook? ->
        {state, {:error, :agent_attempt_containment_not_retired}}

      hook_retirement_result != :ok ->
        {state, hook_retirement_result}

      true ->
        finalize_after_run(state, result)
    end
  end

  defp finalize_after_run(state, result) do
    case run_after_run_once(state) do
      {:ok, state} -> {state, result}
      {:error, state, reason} -> {state, {:error, reason}}
    end
  end

  defp cleanup_failure_result?({:error, reason}), do: workspace_cleanup_failure?(reason)
  defp cleanup_failure_result?(_result), do: false

  defp run_after_run_once(%{after_run_complete?: true} = state), do: {:ok, state}

  defp run_after_run_once(%{workspace: workspace, workspace_root: root} = state)
       when is_binary(workspace) and is_binary(root) do
    state = %{state | after_run_complete?: true}

    hook_opts =
      workspace_lifecycle_opts(
        self(),
        state.attempt_token,
        state.workspace_hook_runner
      )

    hook_result =
      Workspace.run_after_run_hook_bound(
        workspace,
        root,
        state.issue,
        state.worker_host,
        hook_opts
      )

    state = collect_attempt_messages(state, 0)

    cond do
      hook_result != :ok ->
        {:error, state, :after_run_cleanup_unverified}

      hook_runner_retirement_result(state) != :ok ->
        {:error, state, :after_run_cleanup_unverified}

      true ->
        {:ok, state}
    end
  end

  defp run_after_run_once(state), do: {:ok, %{state | after_run_complete?: true}}

  defp complete_after_finalization(state, result) do
    if cleanup_failure_result?(result) and startup_cleanup_pending?(state) do
      hold_startup_cleanup_authority(state, result)
    else
      complete_after_verified_finalization(state, result)
    end
  end

  defp complete_after_verified_finalization(%{external_exit: nil}, result), do: result

  defp complete_after_verified_finalization(%{external_exit: reason}, :ok),
    do: {:external_exit, reason}

  defp complete_after_verified_finalization(
         %{external_exit: reason} = state,
         {:error, failure}
       ) do
    if restart_blocking_failure?(failure) do
      hold_external_containment(state, reason, failure)
    else
      {:external_exit, reason}
    end
  end

  defp hold_startup_cleanup_authority(state, result) do
    receive do
      {:DOWN, ref, :process, pid, reason} ->
        state = integrate_cleanup_authority_down(state, ref, pid, reason)
        complete_after_finalization(state, result)

      {:cancel_agent_attempt, caller, cancel_token}
      when is_pid(caller) and is_reference(cancel_token) ->
        send(caller, {:agent_attempt_cancelled, cancel_token, cancellation_reply(state, result)})
        hold_startup_cleanup_authority(state, result)

      {:EXIT, _from, reason} ->
        state = %{state | external_exit: state.external_exit || reason}
        hold_startup_cleanup_authority(state, result)

      {tag, _token, _value} = message when tag in @attempt_runtime_message_tags ->
        state = integrate_attempt_message(state, message)
        complete_after_finalization(state, result)
    end
  end

  defp startup_cleanup_pending?(%{startup_cleanup_authority: %{}}), do: true
  defp startup_cleanup_pending?(_state), do: false

  defp cancellation_finish_result(%{result: {:error, reason} = error}, :ok) do
    if cancellation_preserving_failure?(reason), do: error, else: :ok
  end

  defp cancellation_finish_result(_state, :ok), do: :ok
  defp cancellation_finish_result(_state, {:error, reason}), do: {:error, reason}
  defp cancellation_finish_result(_state, reason), do: {:error, reason}

  defp cancellation_reply(state, :ok) do
    {:ok, %{workspace_path: state.workspace, workspace_root: state.workspace_root}}
  end

  defp cancellation_reply(_state, {:error, _reason} = error), do: error
  defp cancellation_reply(_state, reason), do: {:error, reason}

  defp reply_cancel_waiters(state, result) do
    reply = cancellation_reply(state, result)

    Enum.each(state.cancel_waiters, fn {caller, cancel_token} ->
      send(caller, {:agent_attempt_cancelled, cancel_token, reply})
    end)

    :ok
  end

  defp normalize_attempt_result(:ok), do: :ok
  defp normalize_attempt_result({:error, _reason} = error), do: error
  defp normalize_attempt_result(other), do: {:error, {:invalid_agent_attempt_result, failure_kind(other)}}

  defp finish_attempt(_issue, :ok, _recipient, _correlation), do: :ok

  defp finish_attempt(_issue, {:external_exit, reason}, _recipient, _correlation) do
    exit(reason)
  end

  defp finish_attempt(issue, {:error, reason}, recipient, correlation) do
    maybe_send_workspace_cleanup_blocker(recipient, issue, reason, correlation)
    kind = failure_kind(reason)
    Logger.error("Agent run failed for #{issue_context(issue)} failure_kind=#{kind}")
    raise RuntimeError, "Agent run failed for #{issue_context(issue)} failure_kind=#{kind}"
  end

  defp maybe_send_workspace_cleanup_blocker(recipient, issue, reason, correlation) do
    if workspace_cleanup_failure?(reason) do
      send_codex_update(
        recipient,
        issue,
        %{
          event: :process_cleanup_failed,
          reason: %{kind: :workspace_cleanup_failed},
          timestamp: DateTime.utc_now()
        },
        correlation
      )
    else
      :ok
    end
  end

  defp workspace_cleanup_failure?(:after_run_cleanup_unverified), do: true
  defp workspace_cleanup_failure?(:agent_attempt_containment_not_retired), do: true
  defp workspace_cleanup_failure?(:agent_worker_not_retired), do: true
  defp workspace_cleanup_failure?(:app_server_connection_discovery_incomplete), do: true
  defp workspace_cleanup_failure?(:app_server_process_cleanup_failed), do: true
  defp workspace_cleanup_failure?(:app_server_process_not_retired), do: true
  defp workspace_cleanup_failure?(:workspace_hook_cleanup_unverified), do: true
  defp workspace_cleanup_failure?(:workspace_hook_runner_not_retired), do: true

  defp workspace_cleanup_failure?(%TransportError{kind: :process_cleanup_failed}),
    do: true

  defp workspace_cleanup_failure?({:workspace_bootstrap_cleanup_blocked, _reason, _binding}),
    do: true

  defp workspace_cleanup_failure?({:workspace_bootstrap_rollback_failed, _hook, _reason, _binding}),
    do: true

  defp workspace_cleanup_failure?({:workspace_hook_cleanup_failed, _hook_name, _phase}),
    do: true

  defp workspace_cleanup_failure?({:workspace_hook_runner_failed, _hook_name}), do: true

  defp workspace_cleanup_failure?({:workspace_hook_supervisor_unavailable, _hook_name}),
    do: true

  defp workspace_cleanup_failure?(_reason), do: false

  defp restart_blocking_failure?(reason) do
    workspace_cleanup_failure?(reason) or
      match?(%TransportError{kind: :uncertain_external_outcome}, reason)
  end

  defp cancellation_preserving_failure?(:app_server_uncertain_external_outcome), do: true

  defp cancellation_preserving_failure?(reason),
    do: restart_blocking_failure?(reason)

  defp hook_cleanup_failure_result?({:error, {:workspace_hook_cleanup_failed, _hook_name, _phase}}),
    do: true

  defp hook_cleanup_failure_result?(_result), do: false

  defp hook_result_verifies_containment?(:ok), do: true

  defp hook_result_verifies_containment?({:error, {classification, _hook_name}})
       when classification in [
              :workspace_hook_aborted,
              :workspace_hook_cleanup_recovered,
              :workspace_hook_invalid_output_limit,
              :workspace_hook_owner_exited,
              :workspace_hook_start_failed
            ],
       do: true

  defp hook_result_verifies_containment?({:error, {classification, _hook_name, _detail}})
       when classification in [:workspace_hook_timeout],
       do: true

  defp hook_result_verifies_containment?({:error, {:workspace_hook_failed, _hook_name, _status, _summary}}),
    do: true

  defp hook_result_verifies_containment?({:error, {:workspace_hook_output_limit, _hook_name, _limit, _summary}}),
    do: true

  defp hook_result_verifies_containment?(_result), do: false

  defp recovered_containment?(state, safety_reason) do
    recovered_hook_containment?(state, safety_reason) or
      recovered_startup_cleanup_containment?(state, safety_reason)
  end

  defp recovered_hook_containment?(state, safety_reason) do
    recoverable_hook_containment_failure?(safety_reason) and
      state.hook_cleanup_verified? and
      is_nil(state.hook_cleanup_error) and
      is_nil(state.hook_runner) and
      worker_retired?(state) and
      connection_retired?(state)
  end

  defp recovered_startup_cleanup_containment?(state, safety_reason) do
    recoverable_startup_cleanup_failure?(safety_reason) and
      state.startup_cleanup_verified? and
      is_nil(state.startup_cleanup_authority) and
      worker_retired?(state) and
      connection_retired?(state)
  end

  defp recoverable_startup_cleanup_failure?(%TransportError{kind: :process_cleanup_failed}),
    do: true

  defp recoverable_startup_cleanup_failure?(:app_server_process_cleanup_failed), do: true
  defp recoverable_startup_cleanup_failure?(_reason), do: false

  defp recoverable_hook_containment_failure?(:after_run_cleanup_unverified), do: true
  defp recoverable_hook_containment_failure?(:workspace_hook_cleanup_unverified), do: true
  defp recoverable_hook_containment_failure?(:workspace_hook_runner_not_retired), do: true

  defp recoverable_hook_containment_failure?({:workspace_hook_cleanup_failed, _hook, _phase}),
    do: true

  defp recoverable_hook_containment_failure?({:workspace_hook_runner_failed, _hook}),
    do: true

  defp recoverable_hook_containment_failure?({:workspace_bootstrap_cleanup_blocked, reason, _binding}),
    do: recoverable_hook_containment_failure?(reason)

  defp recoverable_hook_containment_failure?({:workspace_bootstrap_rollback_failed, _hook, reason, _binding}),
    do: recoverable_hook_containment_failure?(reason)

  defp recoverable_hook_containment_failure?(_reason), do: false

  defp maybe_send_turn_runtime_info(controller, attempt_token, message)
       when is_pid(controller) do
    case turn_runtime_update(message) do
      {:set, turn_id} -> send(controller, {:agent_attempt_turn, attempt_token, turn_id})
      :clear -> send(controller, {:agent_attempt_turn, attempt_token, nil})
      :unchanged -> :ok
    end
  end

  defp turn_runtime_update(%{event: :session_started, turn_id: turn_id})
       when is_binary(turn_id) and turn_id != "",
       do: {:set, turn_id}

  defp turn_runtime_update(%{event: event})
       when event in [:turn_completed, :turn_failed, :turn_cancelled],
       do: :clear

  defp turn_runtime_update(_message), do: :unchanged

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp run_on_worker_host(
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         controller,
         attempt_token
       ) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    workspace_opts =
      workspace_lifecycle_opts(
        controller,
        attempt_token,
        Keyword.get(opts, :workspace_hook_runner, WorkspaceHookRunner)
      )

    case Workspace.create_for_issue_bound(issue, worker_host, workspace_opts) do
      {:ok, %{path: workspace, root: workspace_root}} ->
        with :ok <-
               Workspace.run_before_run_hook_bound(
                 workspace,
                 workspace_root,
                 issue,
                 worker_host,
                 workspace_opts
               ) do
          run_codex_turns(
            workspace,
            issue,
            codex_update_recipient,
            opts,
            worker_host,
            controller,
            attempt_token
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_lifecycle_opts(controller, attempt_token, hook_runner)
       when is_pid(controller) and is_reference(attempt_token) and is_atom(hook_runner) do
    [
      hook_runner: hook_runner,
      on_bound: fn binding ->
        send(controller, {:agent_attempt_workspace, attempt_token, binding})
      end,
      hook_observer: fn hook_ref, event ->
        send(controller, {:agent_attempt_hook_runner, attempt_token, {hook_ref, event}})
      end
    ]
  end

  defp codex_message_handler(recipient, issue, correlation, controller, attempt_token) do
    fn message ->
      maybe_send_turn_runtime_info(controller, attempt_token, message)
      send_codex_update(recipient, issue, message, correlation)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message, correlation)
       when is_binary(issue_id) and is_pid(recipient) and is_map(message) and is_map(correlation) do
    send(recipient, {:codex_worker_update, issue_id, Map.merge(message, correlation)})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message, _correlation), do: :ok

  defp send_worker_runtime_info(
         recipient,
         %Issue{id: issue_id},
         worker_host,
         %{path: workspace, root: workspace_root},
         correlation
       )
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) and
              is_binary(workspace_root) and is_map(correlation) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       Map.merge(
         %{
           worker_host: worker_host,
           workspace_path: workspace,
           workspace_root: workspace_root
         },
         correlation
       )}
    )

    :ok
  end

  defp send_worker_runtime_info(
         _recipient,
         _issue,
         _worker_host,
         _workspace,
         _correlation
       ),
       do: :ok

  defp run_codex_turns(
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         controller,
         attempt_token
       ) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    correlation = correlation_from_opts(opts)

    on_transport_failure = fn reason ->
      maybe_send_transport_blocker(codex_update_recipient, issue, reason, correlation)
      maybe_mark_connection_cleanup_unverified(controller, attempt_token, reason)
    end

    turn_context = %{
      attempt_token: attempt_token,
      codex_update_recipient: codex_update_recipient,
      controller: controller,
      correlation: correlation,
      issue: issue,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      opts: opts,
      workspace: workspace
    }

    case AppServer.start_session(workspace,
           worker_host: worker_host,
           correlation: correlation,
           managed: Keyword.get(opts, :managed, false),
           on_cleanup_authority: fn guardian ->
             send(
               controller,
               {:agent_attempt_cleanup_authority, attempt_token, guardian}
             )
           end,
           process_adapter: Keyword.get(opts, :process_adapter, SymphonyElixir.Codex.ProcessAdapter),
           trusted_tool_context: %{
             issue_id: issue.id,
             run_id: correlation.run_id
           },
           on_connection_starting: fn ->
             send(controller, {:agent_attempt_connection_state, attempt_token, :starting})
           end,
           on_connection_started: fn connection ->
             send(controller, {:agent_attempt_connection, attempt_token, connection})
           end,
           on_connection_start_failed: fn ->
             send(controller, {:agent_attempt_connection_state, attempt_token, :not_started})
           end,
           on_transport_failure: on_transport_failure
         ) do
      {:ok, session} ->
        send(controller, {:agent_attempt_session, attempt_token, session})
        send_app_server_session_ready(codex_update_recipient, issue, session, correlation)

        run_codex_session(session, turn_context)

      {:error, reason} ->
        maybe_send_transport_blocker(codex_update_recipient, issue, reason, correlation)
        {:error, reason}
    end
  end

  defp run_codex_session(session, turn_context) do
    result = do_run_codex_turns(session, turn_context, 1)

    case AppServer.stop_session(session, result) do
      :ok ->
        result

      {:error, reason} ->
        maybe_send_transport_blocker(
          turn_context.codex_update_recipient,
          turn_context.issue,
          reason,
          turn_context.correlation
        )

        {:error, reason}
    end
  catch
    kind, reason ->
      case AppServer.stop_session(session) do
        :ok ->
          :erlang.raise(kind, reason, __STACKTRACE__)

        {:error, cleanup_reason} ->
          maybe_send_transport_blocker(
            turn_context.codex_update_recipient,
            turn_context.issue,
            cleanup_reason,
            turn_context.correlation
          )

          {:error, cleanup_reason}
      end
  end

  defp maybe_send_transport_blocker(recipient, issue, reason, correlation) do
    case transport_blocker_update(reason) do
      nil -> :ok
      update -> send_codex_update(recipient, issue, update, correlation)
    end
  end

  defp maybe_mark_connection_cleanup_unverified(
         controller,
         attempt_token,
         %TransportError{kind: :process_cleanup_failed}
       )
       when is_pid(controller) and is_reference(attempt_token) do
    send(
      controller,
      {:agent_attempt_connection_state, attempt_token, :cleanup_unverified}
    )

    :ok
  end

  defp maybe_mark_connection_cleanup_unverified(_controller, _attempt_token, _reason),
    do: :ok

  defp transport_blocker_update(%TransportError{kind: :uncertain_external_outcome} = reason) do
    %{
      event: :uncertain_external_outcome,
      operation: reason.details[:operation],
      reason: reason,
      timestamp: DateTime.utc_now()
    }
  end

  defp transport_blocker_update(%TransportError{kind: :process_cleanup_failed} = reason) do
    %{
      event: :process_cleanup_failed,
      reason: reason,
      timestamp: DateTime.utc_now()
    }
  end

  defp transport_blocker_update(%TransportError{kind: kind} = reason)
       when kind in @protocol_failure_kinds do
    %{
      event: :app_server_protocol_failure,
      reason: reason,
      timestamp: DateTime.utc_now()
    }
  end

  defp transport_blocker_update({:turn_input_required, _metadata}) do
    %{
      event: :turn_input_required,
      reason: %{kind: :turn_input_required},
      timestamp: DateTime.utc_now()
    }
  end

  defp transport_blocker_update({:approval_required, _metadata}) do
    %{
      event: :approval_required,
      reason: %{kind: :approval_required},
      timestamp: DateTime.utc_now()
    }
  end

  defp transport_blocker_update(_reason), do: nil

  defp send_app_server_session_ready(recipient, issue, session, correlation) do
    metadata = Map.get(session, :metadata, %{})

    send_codex_update(
      recipient,
      issue,
      %{
        codex_app_server_pid: metadata[:codex_app_server_pid],
        event: :app_server_session_ready,
        thread_id: Map.get(session, :thread_id),
        timestamp: DateTime.utc_now()
      },
      correlation
    )
  end

  defp validate_release_worker(nil), do: :ok
  defp validate_release_worker(_worker_host), do: {:error, @remote_workers_error}

  defp do_run_codex_turns(app_session, turn_context, turn_number) do
    prompt =
      build_turn_prompt(
        turn_context.issue,
        turn_context.opts,
        turn_number,
        turn_context.max_turns
      )

    case AppServer.run_turn(
           app_session,
           prompt,
           turn_context.issue,
           correlation: turn_context.correlation,
           on_message:
             codex_message_handler(
               turn_context.codex_update_recipient,
               turn_context.issue,
               turn_context.correlation,
               turn_context.controller,
               turn_context.attempt_token
             )
         ) do
      {:ok, turn_session} ->
        Logger.info(
          "Completed agent run for #{issue_context(turn_context.issue)} session_id=#{turn_session[:session_id]} workspace=#{turn_context.workspace} turn=#{turn_number}/#{turn_context.max_turns}"
        )

        case continue_with_issue?(turn_context.issue, turn_context.issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < turn_context.max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{turn_context.max_turns}")

            do_run_codex_turns(
              app_session,
              %{turn_context | issue: refreshed_issue},
              turn_number + 1
            )

          {:continue, refreshed_issue} ->
            Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator")

            :ok

          {:done, _refreshed_issue} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        maybe_send_transport_blocker(
          turn_context.codex_update_recipient,
          turn_context.issue,
          reason,
          turn_context.correlation
        )

        {:error, reason}
    end
  end

  defp correlation_context(opts) when is_list(opts) do
    correlation = Keyword.get(opts, :correlation, %{})

    %{
      run_id: valid_or_new_id(Map.get(correlation, :run_id) || Keyword.get(opts, :run_id)),
      attempt_id: valid_or_new_id(Map.get(correlation, :attempt_id) || Keyword.get(opts, :attempt_id))
    }
  end

  defp correlation_from_opts(opts) when is_list(opts) do
    Keyword.fetch!(opts, :correlation)
  end

  defp valid_or_new_id(value) when is_binary(value) do
    if value == String.downcase(value) and Identity.valid_uuid4?(value),
      do: value,
      else: Identity.uuid4()
  end

  defp valid_or_new_id(_value), do: Identity.uuid4()

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) and issue_routable?(refreshed_issue) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp selected_worker_host(nil, []), do: nil

  defp selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp failure_kind(%TransportError{kind: kind}) when is_atom(kind), do: kind

  defp failure_kind(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp failure_kind(kind) when is_atom(kind), do: kind
  defp failure_kind(%{__struct__: module}) when is_atom(module), do: :exception
  defp failure_kind(_reason), do: :unclassified_error

  defp exit_category(reason) when is_atom(reason), do: reason

  defp exit_category(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: elem(reason, 0)

  defp exit_category(_reason), do: :unclassified_exit

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
