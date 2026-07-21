# Downstream modification notice (2026-07-16): Symphony Studio adds stable
# run/attempt event correlation while preserving typed App Server blockers and
# the identity-bound protocol compatibility circuit, exact workspace cleanup,
# and cancellation/retry convergence.
defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{AgentRunner, Config, Event, EventSink, Identity, StatusDashboard, Tracker, Workspace}
  alias SymphonyElixir.Codex.{CompatibilityCircuit, TransportError}
  alias SymphonyElixir.Linear.Issue

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  @transport_blocker_events [
    :app_server_protocol_failure,
    :process_cleanup_failed,
    :uncertain_external_outcome
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
  @compatibility_circuit_error "codex App Server compatibility circuit is open for the pinned identity"
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      :compatibility_manifest_path,
      :compatibility_schema_version,
      :compatibility_circuit,
      :event_sink,
      :event_clock,
      :id_generator,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      retry_attempts: %{},
      codex_totals: nil,
      codex_rate_limits: nil
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      codex_totals: @empty_codex_totals,
      codex_rate_limits: nil,
      compatibility_manifest_path: Keyword.get(opts, :compatibility_manifest_path),
      compatibility_schema_version: Keyword.get(opts, :compatibility_schema_version),
      compatibility_circuit: nil,
      event_sink: Keyword.get(opts, :event_sink, EventSink.default_target()),
      event_clock: Keyword.get(opts, :event_clock, &DateTime.utc_now/0),
      id_generator: Keyword.get(opts, :id_generator, &Identity.uuid4/0)
    }

    state = refresh_compatibility_circuit(state)

    run_terminal_workspace_cleanup_if_valid()
    state = schedule_tick(state, 0)

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        state = append_attempt_exit_event(state, issue_id, Map.fetch!(running, issue_id), reason)
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        exit_category = agent_exit_category(reason)

        Logger.info("Agent task finished for issue_id=#{issue_id} session_id=#{session_id} exit_category=#{exit_category}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        if correlation_matches?(running_entry, runtime_info) do
          updated_running_entry =
            running_entry
            |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
            |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])
            |> maybe_put_runtime_value(:workspace_root, runtime_info[:workspace_root])

          notify_dashboard()
          {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        else
          {:noreply, state}
        end
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %State{} = state
      ) do
    case record_codex_event(state, issue_id, update) do
      {:appended, state, event_update, :running} ->
        state = maybe_trip_compatibility_circuit(state, event_update)
        running = state.running

        case Map.get(running, issue_id) do
          nil ->
            notify_dashboard()
            {:noreply, integrate_late_transport_blocker(state, issue_id, event_update)}

          running_entry ->
            {updated_running_entry, token_delta} =
              integrate_codex_update(running_entry, event_update)

            state =
              state
              |> apply_codex_token_delta(token_delta)
              |> apply_codex_rate_limits(event_update)

            notify_dashboard()
            {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
        end

      {:appended, state, event_update, :late} ->
        state = maybe_trip_compatibility_circuit(state, event_update)
        next_state = integrate_late_transport_blocker(state, issue_id, event_update)
        notify_dashboard()
        {:noreply, next_state}

      {:duplicate, state} ->
        {:noreply, state}

      {:rejected, state} ->
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    state = refresh_compatibility_circuit(state)

    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message_category=#{message_category(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)
    else
      Logger.info("Agent task completed for issue_id=#{issue_id} session_id=#{session_id}; scheduling active-state continuation check")

      state
      |> complete_issue(issue_id)
      |> schedule_issue_retry(issue_id, 1, %{
        identifier: running_entry.identifier,
        issue_url: running_entry.issue.url,
        delay_type: :continuation,
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        workspace_root: Map.get(running_entry, :workspace_root),
        run_id: Map.get(running_entry, :run_id),
        attempt_id: Map.get(running_entry, :attempt_id),
        event_sequence: Map.get(running_entry, :event_sequence, 0),
        last_event_id: Map.get(running_entry, :last_event_id),
        last_event_type: Map.get(running_entry, :last_event_type)
      })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)

      app_server_session_started?(running_entry) ->
        timestamp = DateTime.utc_now()

        uncertain_entry = %{
          running_entry
          | last_codex_event: :uncertain_external_outcome,
            last_codex_timestamp: timestamp
        }

        block_input_required_agent_down(
          state,
          issue_id,
          uncertain_entry,
          session_id,
          :uncertain_external_outcome
        )

      true ->
        retry_agent_down(state, issue_id, running_entry, session_id, reason)
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    exit_category = agent_exit_category(reason)
    error = blocker_error(running_entry, "agent exited: #{exit_category}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    exit_category = agent_exit_category(reason)

    Logger.warning("Agent task exited for issue_id=#{issue_id} session_id=#{session_id} exit_category=#{exit_category}; scheduling retry")

    next_attempt = next_retry_attempt_from_running(running_entry)

    schedule_issue_retry(state, issue_id, next_attempt, %{
      identifier: running_entry.identifier,
      issue_url: running_entry.issue.url,
      error: "agent exited: #{exit_category}",
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      workspace_root: Map.get(running_entry, :workspace_root),
      run_id: Map.get(running_entry, :run_id),
      attempt_id: Map.get(running_entry, :attempt_id),
      event_sequence: Map.get(running_entry, :event_sequence, 0),
      last_event_id: Map.get(running_entry, :last_event_id),
      last_event_type: Map.get(running_entry, :last_event_type)
    })
  end

  defp maybe_dispatch(%State{} = state) do
    state = refresh_compatibility_circuit(state)

    case Config.validate!() do
      :ok ->
        state =
          state
          |> reconcile_running_issues()
          |> reconcile_blocked_issues()

        with false <- compatibility_circuit_open?(state),
             {:ok, issues} <- Tracker.fetch_candidate_issues(),
             true <- available_slots(state) > 0 do
          choose_issues(issues, state)
        else
          result -> dispatch_failure(state, result)
        end

      result ->
        dispatch_failure(state, result)
    end
  end

  defp dispatch_failure(state, true), do: state
  defp dispatch_failure(state, false), do: state

  defp dispatch_failure(state, {:error, :missing_linear_api_token}) do
    Logger.error("Linear API token missing in WORKFLOW.md")
    state
  end

  defp dispatch_failure(state, {:error, :missing_linear_project_slug}) do
    Logger.error("Linear project slug missing in WORKFLOW.md")
    state
  end

  defp dispatch_failure(state, {:error, :missing_tracker_kind}) do
    Logger.error("Tracker kind missing in WORKFLOW.md")
    state
  end

  defp dispatch_failure(state, {:error, {:unsupported_tracker_kind, kind}}) do
    Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")
    state
  end

  defp dispatch_failure(state, {:error, {:invalid_workflow_config, message}}) do
    Logger.error("Invalid WORKFLOW.md config: #{message}")
    state
  end

  defp dispatch_failure(state, {:error, {:missing_workflow_file, path, reason}}) do
    Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
    state
  end

  defp dispatch_failure(state, {:error, :workflow_front_matter_not_a_map}) do
    Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
    state
  end

  defp dispatch_failure(state, {:error, {:workflow_parse_error, reason}}) do
    Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
    state
  end

  defp dispatch_failure(
         state,
         {:error, {:unsupported_release_feature, _feature, _release}}
       ) do
    Logger.error("WORKFLOW.md validation failed failure_kind=unsupported_release_feature")
    state
  end

  defp dispatch_failure(state, {:error, _reason}) do
    Logger.error("Failed to fetch from tracker failure_kind=tracker_fetch_failed")
    state
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, _reason} ->
          Logger.debug("Failed to refresh running issue states failure_kind=tracker_refresh_failed; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, _reason} ->
          Logger.debug("Failed to refresh blocked issue states failure_kind=tracker_refresh_failed; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec reconcile_blocked_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_blocked_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_blocked_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec handle_retry_issue_lookup_for_test(Issue.t(), term(), String.t(), non_neg_integer(), map()) ::
          term()
  def handle_retry_issue_lookup_for_test(%Issue{} = issue, %State{} = state, issue_id, attempt, metadata)
      when is_binary(issue_id) and is_integer(attempt) and attempt >= 0 and is_map(metadata) do
    {:noreply, updated_state} = handle_retry_issue_lookup(issue, state, issue_id, attempt, metadata)
    updated_state
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true)

      !issue_routable?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      preserve_block_on_terminal?(state, issue.id) ->
        Logger.warning("Issue remains safety-blocked pending verified cleanup: #{issue_context(issue)} state=#{issue.state}")
        refresh_blocked_issue_state(state, issue)

      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; reconciling bound cleanup")
        cleanup_blocked_terminal_issue(state, issue.id)

      !issue_routable?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      cond do
        MapSet.member?(visible_issue_ids, issue_id) ->
          state_acc

        preserve_block_on_terminal?(state_acc, issue_id) ->
          Logger.warning("Issue remains safety-blocked while absent from tracker refresh: issue_id=#{issue_id}")
          state_acc

        true ->
          Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
          release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp preserve_block_on_terminal?(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id, %{})
    |> Map.get(:preserve_on_terminal?, false)
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_unblocked_issue_claim(state, issue_id)

      %{pid: _pid, ref: _ref} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        terminate_running_entry(state, issue_id, running_entry, cleanup_workspace)

      _ ->
        release_unblocked_issue_claim(state, issue_id)
    end
  end

  defp release_unblocked_issue_claim(%State{} = state, issue_id) do
    if Map.has_key?(state.blocked, issue_id), do: state, else: release_issue_claim(state, issue_id)
  end

  defp terminate_running_entry(state, issue_id, running_entry, cleanup_workspace) do
    case stop_running_task(running_entry) do
      {:ok, cancellation_metadata} ->
        running_entry = merge_cancellation_metadata(running_entry, cancellation_metadata)
        cleanup_terminated_entry(state, issue_id, running_entry, cleanup_workspace)

      {:error, _reason} ->
        block_issue_from_entry(
          state,
          issue_id,
          running_entry,
          "agent process cleanup failed and requires operator reconciliation",
          preserve_on_terminal: true
        )
    end
  end

  defp cleanup_terminated_entry(state, issue_id, running_entry, cleanup_workspace) do
    case maybe_cleanup_bound_workspace(running_entry, cleanup_workspace) do
      :ok ->
        release_terminated_issue(state, issue_id)

      {:error, _reason} ->
        block_issue_from_entry(
          state,
          issue_id,
          running_entry,
          "bound workspace cleanup failed and requires operator reconciliation",
          preserve_on_terminal: true
        )
    end
  end

  defp merge_cancellation_metadata(running_entry, cancellation_metadata)
       when is_map(running_entry) and is_map(cancellation_metadata) do
    [:workspace_path, :workspace_root]
    |> Enum.reduce(running_entry, fn key, entry ->
      case Map.get(cancellation_metadata, key) do
        value when is_binary(value) and value != "" -> Map.put(entry, key, value)
        _missing -> entry
      end
    end)
  end

  defp maybe_cleanup_bound_workspace(_running_entry, false), do: :ok

  defp maybe_cleanup_bound_workspace(running_entry, true) do
    case {Map.get(running_entry, :workspace_path), Map.get(running_entry, :workspace_root)} do
      {workspace_path, workspace_root}
      when is_binary(workspace_path) and workspace_path != "" and
             is_binary(workspace_root) and workspace_root != "" ->
        Workspace.remove_bound(
          workspace_path,
          workspace_root,
          Config.settings!().hooks
        )
        |> normalize_workspace_cleanup()

      _missing_binding ->
        {:error, :workspace_binding_missing}
    end
  end

  defp release_terminated_issue(%State{} = state, issue_id) do
    state = discard_issue_retry(state, issue_id)

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id)
    }
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    timeout_ms = Config.settings!().codex.stall_timeout_ms

    cond do
      timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      handle_stalled_issue(state, issue_id, running_entry, now, elapsed_ms)
    else
      state
    end
  end

  defp handle_stalled_issue(state, issue_id, running_entry, now, elapsed_ms) do
    cond do
      input_required_blocker?(running_entry) ->
        block_stalled_input_required_issue(state, issue_id, running_entry, elapsed_ms)

      app_server_session_started?(running_entry) ->
        block_stalled_app_server_issue(state, issue_id, running_entry, now, elapsed_ms)

      true ->
        retry_stalled_issue(state, issue_id, running_entry, elapsed_ms)
    end
  end

  defp block_stalled_input_required_issue(state, issue_id, running_entry, elapsed_ms) do
    error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")
    log_stalled_block(issue_id, running_entry, elapsed_ms, error)

    state
    |> record_session_completion_totals(running_entry)
    |> stop_and_block_issue(issue_id, running_entry, error)
  end

  defp block_stalled_app_server_issue(state, issue_id, running_entry, now, elapsed_ms) do
    error = "codex App Server session stalled with an uncertain external outcome; reconciliation required"

    uncertain_entry = %{
      running_entry
      | last_codex_event: :uncertain_external_outcome,
        last_codex_timestamp: now
    }

    log_stalled_block(issue_id, uncertain_entry, elapsed_ms, error)

    state
    |> record_session_completion_totals(uncertain_entry)
    |> stop_and_block_issue(issue_id, uncertain_entry, error)
  end

  defp log_stalled_block(issue_id, running_entry, elapsed_ms, error) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")
  end

  defp retry_stalled_issue(state, issue_id, running_entry, elapsed_ms) do
    identifier = Map.get(running_entry, :identifier, issue_id)
    session_id = running_entry_session_id(running_entry)

    Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

    next_attempt = next_retry_attempt_from_running(running_entry)

    next_state = terminate_running_issue(state, issue_id, false)

    if Map.has_key?(next_state.blocked, issue_id) do
      next_state
    else
      schedule_issue_retry(next_state, issue_id, next_attempt, %{
        identifier: identifier,
        issue_url: running_entry.issue.url,
        error: "stalled for #{elapsed_ms}ms without codex activity",
        worker_host: Map.get(running_entry, :worker_host),
        workspace_path: Map.get(running_entry, :workspace_path),
        workspace_root: Map.get(running_entry, :workspace_root),
        run_id: Map.get(running_entry, :run_id),
        attempt_id: Map.get(running_entry, :attempt_id),
        event_sequence: Map.get(running_entry, :event_sequence, 0),
        last_event_id: Map.get(running_entry, :last_event_id),
        last_event_type: Map.get(running_entry, :last_event_type)
      })
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  defp last_activity_timestamp(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp last_activity_timestamp(_running_entry), do: nil

  defp app_server_session_started?(running_entry) when is_map(running_entry) do
    value = Map.get(running_entry, :codex_app_server_pid)
    (is_binary(value) and value != "") or is_integer(value)
  end

  defp app_server_session_started?(_running_entry), do: false

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [
      :turn_input_required,
      :approval_required,
      :app_server_protocol_failure,
      :process_cleanup_failed,
      :uncertain_external_outcome
    ] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"

  defp codex_event_blocker_error(:uncertain_external_outcome),
    do: "codex operation has an uncertain external outcome and requires reconciliation"

  defp codex_event_blocker_error(:process_cleanup_failed),
    do: "codex process cleanup failed and requires operator reconciliation"

  defp codex_event_blocker_error(:app_server_protocol_failure),
    do: "codex App Server protocol failed and requires compatibility reconciliation"

  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(%{cancel_mode: :cooperative, pid: pid} = running_entry)
       when is_pid(pid) do
    cancel_timeout_ms =
      case Map.get(running_entry, :cancel_timeout_ms) do
        timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 -> timeout_ms
        _missing -> AgentRunner.cancellation_timeout_ms()
      end

    result = AgentRunner.cancel(pid, cancel_timeout_ms)
    demonitor_running_entry(running_entry)

    case result do
      {:ok, metadata} when is_map(metadata) ->
        {:ok, metadata}

      {:error, _reason} = error ->
        # The cooperative controller may have entered cancellation and retained
        # sole cleanup authority, or a timeout may leave its state unconfirmed.
        # Its Task child uses `shutdown: :infinity`, so synchronous termination
        # could block the Orchestrator before it records the safety block. The
        # blocked entry, TaskSupervisor, and CleanupBarrier retain and capacity-
        # account that holder while the issue keeps its claim and workspace.
        error
    end
  end

  defp stop_running_task(running_entry) when is_map(running_entry) do
    terminate_task(Map.get(running_entry, :pid))
    demonitor_running_entry(running_entry)
    {:ok, %{}}
  end

  defp demonitor_running_entry(running_entry) do
    case Map.get(running_entry, :ref) do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _missing_ref -> :ok
    end
  end

  defp retained_controller_pid(%{cancel_mode: :cooperative, pid: pid}) when is_pid(pid),
    do: pid

  defp retained_controller_pid(_running_entry), do: nil

  defp retained_controller_issue_state(%{
         cancel_mode: :cooperative,
         pid: pid,
         issue: %Issue{state: issue_state}
       })
       when is_pid(pid) and is_binary(issue_state),
       do: issue_state

  defp retained_controller_issue_state(_running_entry), do: nil

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    case stop_running_task(running_entry) do
      {:ok, cancellation_metadata} ->
        running_entry = merge_cancellation_metadata(running_entry, cancellation_metadata)
        block_issue_from_entry(state, issue_id, running_entry, error)

      {:error, _reason} ->
        block_issue_from_entry(
          state,
          issue_id,
          running_entry,
          "agent process cleanup failed and requires operator reconciliation",
          preserve_on_terminal: true
        )
    end
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error, opts \\ []) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      workspace_root: Map.get(running_entry, :workspace_root),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp),
      run_id: Map.get(running_entry, :run_id),
      attempt_id: Map.get(running_entry, :attempt_id),
      event_sequence: Map.get(running_entry, :event_sequence, 0),
      last_event_id: Map.get(running_entry, :last_event_id),
      last_event_type: Map.get(running_entry, :last_event_type),
      preserve_on_terminal?:
        Keyword.get(opts, :preserve_on_terminal, false) or
          safety_cleanup_event?(Map.get(running_entry, :last_codex_event)),
      compatibility_circuit_block?: Map.get(running_entry, :compatibility_circuit_block?, false),
      retained_controller_pid: retained_controller_pid(running_entry),
      retained_controller_issue_state: retained_controller_issue_state(running_entry)
    }

    state = discard_issue_retry(state, issue_id)

    %{
      state
      | running: Map.delete(state.running, issue_id),
        completed: MapSet.delete(state.completed, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp integrate_late_transport_blocker(%State{} = state, issue_id, %{event: event} = update)
       when event in @transport_blocker_events do
    case {Map.get(state.blocked, issue_id), Map.get(state.retry_attempts, issue_id)} do
      {%{} = blocked_entry, _retry_entry} ->
        error = codex_event_blocker_error(event) || Map.get(blocked_entry, :error)

        updated_entry =
          Map.merge(blocked_entry, %{
            error: error,
            last_codex_event: event,
            last_codex_timestamp: update.timestamp,
            last_codex_message: summarize_codex_update(update),
            last_event_id: Map.get(update, :studio_event_id),
            last_event_type: Map.get(update, :studio_event_type),
            compatibility_circuit_block?: false,
            preserve_on_terminal?:
              Map.get(blocked_entry, :preserve_on_terminal?, false) or
                safety_cleanup_event?(event)
          })

        %{state | blocked: Map.put(state.blocked, issue_id, updated_entry)}

      {nil, %{} = retry_entry} ->
        block_retry_entry(
          state,
          issue_id,
          retry_entry,
          event,
          update.timestamp,
          summarize_codex_update(update),
          false
        )

      {nil, nil} ->
        block_late_running_attempt(state, issue_id, event, update)
    end
  end

  defp integrate_late_transport_blocker(%State{} = state, _issue_id, _update), do: state

  defp block_late_running_attempt(state, issue_id, event, update) do
    case Map.get(state.running, issue_id) do
      %{} = running_entry ->
        updated_entry =
          Map.merge(running_entry, %{
            last_codex_event: event,
            last_codex_timestamp: update.timestamp,
            last_codex_message: summarize_codex_update(update),
            last_event_id: Map.get(update, :studio_event_id),
            last_event_type: Map.get(update, :studio_event_type)
          })

        stop_and_block_issue(
          state,
          issue_id,
          updated_entry,
          codex_event_blocker_error(event) || "prior attempt requires reconciliation"
        )

      _missing ->
        state
    end
  end

  defp safety_cleanup_event?(:process_cleanup_failed), do: true
  defp safety_cleanup_event?(_event), do: false

  defp block_retry_entry(
         state,
         issue_id,
         retry_entry,
         event,
         timestamp,
         last_message,
         compatibility_circuit_block?
       ) do
    identifier = Map.get(retry_entry, :identifier) || issue_id

    issue = %Issue{
      id: issue_id,
      identifier: identifier,
      url: Map.get(retry_entry, :issue_url)
    }

    blocked_entry = %{
      issue_id: issue_id,
      identifier: identifier,
      issue: issue,
      worker_host: Map.get(retry_entry, :worker_host),
      workspace_path: Map.get(retry_entry, :workspace_path),
      workspace_root: Map.get(retry_entry, :workspace_root),
      session_id: "n/a",
      error: codex_event_blocker_error(event) || @compatibility_circuit_error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: last_message,
      last_codex_event: event,
      last_codex_timestamp: timestamp,
      run_id: Map.get(retry_entry, :run_id),
      attempt_id: Map.get(retry_entry, :attempt_id),
      event_sequence: Map.get(retry_entry, :event_sequence, 0),
      last_event_id: Map.get(retry_entry, :last_event_id),
      last_event_type: Map.get(retry_entry, :last_event_type),
      preserve_on_terminal?: event == :process_cleanup_failed,
      compatibility_circuit_block?: compatibility_circuit_block?
    }

    state = discard_issue_retry(state, issue_id)

    %{
      state
      | completed: MapSet.delete(state.completed, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp block_retry_metadata_for_circuit(state, issue_id, metadata) do
    retry_entry = %{
      identifier: metadata[:identifier],
      issue_url: metadata[:issue_url],
      worker_host: metadata[:worker_host],
      workspace_path: metadata[:workspace_path],
      workspace_root: metadata[:workspace_root],
      run_id: metadata[:run_id],
      attempt_id: metadata[:attempt_id],
      event_sequence: metadata[:event_sequence],
      last_event_id: metadata[:last_event_id],
      last_event_type: metadata[:last_event_type]
    }

    block_retry_entry(
      state,
      issue_id,
      retry_entry,
      :app_server_protocol_failure,
      DateTime.utc_now(),
      nil,
      true
    )
  end

  defp block_undispatched_issue_for_circuit(%State{} = state, %Issue{} = issue) do
    running_entry = %{
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: nil,
      session_id: "n/a",
      last_codex_message: nil,
      last_codex_event: :app_server_protocol_failure,
      last_codex_timestamp: DateTime.utc_now(),
      compatibility_circuit_block?: true
    }

    block_issue_from_entry(state, issue.id, running_entry, @compatibility_circuit_error)
  end

  defp cancel_retry_timer(retry_entry) do
    case Map.get(retry_entry, :timer_ref) do
      timer_ref when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        :ok

      _other ->
        :ok
    end
  end

  defp discard_issue_retry(%State{} = state, issue_id) do
    case Map.pop(state.retry_attempts, issue_id) do
      {nil, _retry_attempts} ->
        state

      {retry_entry, retry_attempts} ->
        cancel_retry_timer(retry_entry)
        %{state | retry_attempts: retry_attempts}
    end
  end

  defp maybe_trip_compatibility_circuit(%State{} = state, update) do
    if protocol_failure_update?(update) do
      state
      |> trip_compatibility_circuit()
      |> block_pending_retries_for_circuit()
    else
      state
    end
  end

  defp trip_compatibility_circuit(%State{} = state) do
    workspace_root = Config.settings!().workspace.root

    case CompatibilityCircuit.trip(workspace_root, compatibility_circuit_opts(state)) do
      {:ok, marker} ->
        %{state | compatibility_circuit: marker}

      {:error, failure_category} ->
        Logger.error("Unable to persist App Server compatibility circuit failure_category=#{failure_category}")
        %{state | compatibility_circuit: %{kind: :marker_persistence_failed}}
    end
  end

  defp refresh_compatibility_circuit(%State{compatibility_circuit: %{kind: :marker_persistence_failed}} = state) do
    state
  end

  defp refresh_compatibility_circuit(%State{} = state) do
    workspace_root = Config.settings!().workspace.root

    case CompatibilityCircuit.status(workspace_root, compatibility_circuit_opts(state)) do
      :clear -> state
      :cleared -> release_compatibility_circuit_blocks(%{state | compatibility_circuit: nil})
      {:open, marker} -> %{state | compatibility_circuit: marker}
    end
  end

  defp compatibility_circuit_opts(state) do
    []
    |> maybe_put_circuit_option(:manifest_path, state.compatibility_manifest_path)
    |> maybe_put_circuit_option(:schema_version, state.compatibility_schema_version)
  end

  defp maybe_put_circuit_option(opts, _key, nil), do: opts
  defp maybe_put_circuit_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp compatibility_circuit_open?(%State{compatibility_circuit: nil}), do: false
  defp compatibility_circuit_open?(%State{}), do: true

  defp block_pending_retries_for_circuit(%State{} = state) do
    Enum.reduce(state.retry_attempts, state, fn {issue_id, retry_entry}, state_acc ->
      block_retry_entry(
        state_acc,
        issue_id,
        retry_entry,
        :app_server_protocol_failure,
        DateTime.utc_now(),
        nil,
        true
      )
    end)
  end

  defp release_compatibility_circuit_blocks(%State{} = state) do
    releasable_ids =
      state.blocked
      |> Enum.flat_map(fn
        {issue_id, %{compatibility_circuit_block?: true}} -> [issue_id]
        _entry -> []
      end)

    Enum.reduce(releasable_ids, state, fn issue_id, state_acc ->
      %{
        state_acc
        | blocked: Map.delete(state_acc.blocked, issue_id),
          claimed: MapSet.delete(state_acc.claimed, issue_id),
          completed: MapSet.delete(state_acc.completed, issue_id)
      }
    end)
  end

  defp protocol_failure_update?(%{event: :app_server_protocol_failure}), do: true

  defp protocol_failure_update?(%{event: :uncertain_external_outcome, reason: reason}) do
    protocol_failure_reason?(reason, 0)
  end

  defp protocol_failure_update?(%{reason: reason}) do
    protocol_failure_reason?(reason, 0)
  end

  defp protocol_failure_update?(_update), do: false

  defp protocol_failure_reason?(_reason, depth) when depth > 4, do: false

  defp protocol_failure_reason?(%TransportError{kind: kind, details: details}, depth) do
    kind in @protocol_failure_kinds or
      protocol_failure_reason?(Map.get(details, :cause) || Map.get(details, "cause"), depth + 1)
  end

  defp protocol_failure_reason?(reason, depth) when is_map(reason) do
    kind = Map.get(reason, :kind) || Map.get(reason, "kind")

    protocol_failure_kind?(kind) or
      protocol_failure_reason?(Map.get(reason, :cause) || Map.get(reason, "cause"), depth + 1)
  end

  defp protocol_failure_reason?(_reason, _depth), do: false

  defp protocol_failure_kind?(kind) when kind in @protocol_failure_kinds, do: true

  defp protocol_failure_kind?(kind) when is_binary(kind) do
    kind in Enum.map(@protocol_failure_kinds, &Atom.to_string/1)
  end

  defp protocol_failure_kind?(_kind), do: false

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    not compatibility_circuit_open?(state) and
      candidate_issue?(issue, active_states, terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, state) and
      worker_slots_available?(state)
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, %State{} = state) do
    limit = Config.max_concurrent_agents_for_state(issue_state)

    used =
      running_issue_count_for_state(state.running, issue_state) +
        retained_blocked_controller_count(state.blocked, issue_state: issue_state)

    limit > used
  end

  defp state_slots_available?(_issue, _state), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp retained_blocked_controller_count(blocked, opts \\ []) when is_map(blocked) do
    issue_state = Keyword.get(opts, :issue_state)
    worker_host = Keyword.get(opts, :worker_host)

    Enum.count(blocked, fn
      {_issue_id, %{retained_controller_pid: pid} = entry} when is_pid(pid) ->
        Process.alive?(pid) and retained_entry_matches?(entry, issue_state, worker_host)

      _entry ->
        false
    end)
  end

  defp retained_entry_matches?(_entry, nil, nil), do: true

  defp retained_entry_matches?(entry, issue_state, nil) when is_binary(issue_state) do
    case Map.get(entry, :retained_controller_issue_state) do
      retained_state when is_binary(retained_state) ->
        normalize_issue_state(retained_state) == normalize_issue_state(issue_state)

      _missing_state ->
        false
    end
  end

  defp retained_entry_matches?(entry, nil, worker_host) when is_binary(worker_host),
    do: Map.get(entry, :worker_host) == worker_host

  defp retained_entry_matches?(entry, issue_state, worker_host)
       when is_binary(issue_state) and is_binary(worker_host) do
    retained_entry_matches?(entry, issue_state, nil) and
      retained_entry_matches?(entry, nil, worker_host)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  defp issue_routable?(%Issue{} = issue) do
    Issue.routable?(issue, Config.settings!().tracker.required_labels)
  end

  defp todo_issue_blocked_by_non_terminal?(
         %Issue{state: issue_state, blocked_by: blockers},
         terminal_states
       )
       when is_binary(issue_state) and is_list(blockers) do
    normalize_issue_state(issue_state) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          !terminal_issue_state?(blocker_state, terminal_states)

        _ ->
          true
      end)
  end

  defp todo_issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(
         %State{} = state,
         issue,
         attempt \\ nil,
         preferred_worker_host \\ nil,
         run_metadata \\ %{}
       ) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host, run_metadata)

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, _reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)} failure_kind=tracker_refresh_failed")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host, run_metadata) do
    state = refresh_compatibility_circuit(state)
    recipient = self()

    case {compatibility_circuit_open?(state), select_worker_host(state, preferred_worker_host)} do
      {true, _worker_host} ->
        block_undispatched_issue_for_circuit(state, issue)

      {false, :no_worker_capacity} ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      {false, worker_host} ->
        spawn_issue_on_worker_host(
          state,
          issue,
          attempt,
          recipient,
          worker_host,
          run_metadata
        )
    end
  end

  defp spawn_issue_on_worker_host(
         %State{} = state,
         issue,
         attempt,
         recipient,
         worker_host,
         run_metadata
       ) do
    run_id = valid_id_or_new(state, Map.get(run_metadata, :run_id))
    attempt_id = new_identity(state)
    event_sequence = non_negative_sequence(Map.get(run_metadata, :event_sequence))

    case AgentRunner.start_supervised(issue, recipient,
           attempt: attempt,
           worker_host: worker_host,
           correlation: %{run_id: run_id, attempt_id: attempt_id}
         ) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            cancel_mode: :cooperative,
            cancel_timeout_ms: AgentRunner.cancellation_timeout_ms(),
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: Map.get(run_metadata, :workspace_path),
            workspace_root: Map.get(run_metadata, :workspace_root),
            session_id: nil,
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0,
            retry_attempt: normalize_retry_attempt(attempt),
            run_id: run_id,
            attempt_id: attempt_id,
            event_sequence: event_sequence,
            last_event_id: Map.get(run_metadata, :last_event_id),
            last_event_type: Map.get(run_metadata, :last_event_type),
            started_at: DateTime.utc_now()
          })

        state = discard_issue_retry(state, issue.id)

        state = %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id)
        }

        append_internal_event(
          state,
          issue.id,
          :running,
          "worker.attempt.started",
          "info",
          %{
            "retry_attempt" => normalize_retry_attempt(attempt),
            "worker_kind" => if(is_nil(worker_host), do: "local", else: "remote")
          }
        )

      {:error, reason} ->
        failure_category = task_start_failure_category(reason)

        Logger.error("Unable to spawn agent for #{issue_context(issue)} failure_category=#{failure_category}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{failure_category}",
          worker_host: worker_host,
          run_id: run_id,
          event_sequence: event_sequence,
          last_event_id: Map.get(run_metadata, :last_event_id),
          last_event_type: Map.get(run_metadata, :last_event_type)
        })
    end
  end

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    state = discard_issue_retry(state, issue_id)

    %{
      state
      | completed: MapSet.put(state.completed, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    if compatibility_circuit_open?(state) do
      block_retry_metadata_for_circuit(state, issue_id, metadata)
    else
      do_schedule_issue_retry(state, issue_id, attempt, metadata)
    end
  end

  defp do_schedule_issue_retry(%State{} = state, issue_id, attempt, metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    workspace_root = pick_retry_value(previous_retry, metadata, :workspace_root)
    run_id = pick_retry_value(previous_retry, metadata, :run_id)
    attempt_id = pick_retry_value(previous_retry, metadata, :attempt_id)

    event_sequence =
      max(
        non_negative_sequence(Map.get(previous_retry, :event_sequence)),
        non_negative_sequence(Map.get(metadata, :event_sequence))
      )

    last_event_id = pick_retry_value(previous_retry, metadata, :last_event_id)
    last_event_type = pick_retry_value(previous_retry, metadata, :last_event_type)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    next_state = %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path,
            workspace_root: workspace_root,
            run_id: run_id,
            attempt_id: attempt_id,
            event_sequence: event_sequence,
            last_event_id: last_event_id,
            last_event_type: last_event_type
          })
    }

    if canonical_uuid4?(run_id) do
      %{next_state | claimed: MapSet.put(next_state.claimed, issue_id)}
    else
      next_state
    end
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path),
          workspace_root: Map.get(retry_entry, :workspace_root),
          run_id: Map.get(retry_entry, :run_id),
          attempt_id: Map.get(retry_entry, :attempt_id),
          event_sequence: Map.get(retry_entry, :event_sequence, 0),
          last_event_id: Map.get(retry_entry, :last_event_id),
          last_event_type: Map.get(retry_entry, :last_event_type)
        }

        {:ok, attempt, metadata, discard_issue_retry(state, issue_id)}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    state = refresh_compatibility_circuit(state)

    case Config.validate!() do
      :ok ->
        if compatibility_circuit_open?(state) do
          {:noreply, block_retry_metadata_for_circuit(state, issue_id, metadata)}
        else
          do_handle_retry_issue(state, issue_id, attempt, metadata)
        end

      {:error, _reason} ->
        Logger.warning("Retry deferred for issue_id=#{issue_id}; workflow validation failed")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt,
           Map.put(metadata, :error, "workflow validation failed")
         )}
    end
  end

  defp do_handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, reason} ->
        failure_category = retry_lookup_failure_category(reason)

        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} failure_category=#{failure_category}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{failure_category}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        case cleanup_retry_workspace(metadata) do
          :ok ->
            {:noreply, release_issue_claim(state, issue_id)}

          {:error, _reason} ->
            running_entry = %{
              identifier: issue.identifier,
              issue: issue,
              worker_host: metadata[:worker_host],
              workspace_path: metadata[:workspace_path],
              workspace_root: metadata[:workspace_root],
              run_id: metadata[:run_id],
              attempt_id: metadata[:attempt_id],
              event_sequence: metadata[:event_sequence],
              last_event_id: metadata[:last_event_id],
              last_event_type: metadata[:last_event_type]
            }

            {:noreply,
             block_issue_from_entry(
               state,
               issue_id,
               running_entry,
               "bound workspace cleanup failed and requires operator reconciliation",
               preserve_on_terminal: true
             )}
        end

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_retry_workspace(%{
         workspace_path: workspace_path,
         workspace_root: workspace_root
       })
       when is_binary(workspace_path) and workspace_path != "" and
              is_binary(workspace_root) and workspace_root != "" do
    Workspace.remove_bound(
      workspace_path,
      workspace_root,
      Config.settings!().hooks
    )
    |> normalize_workspace_cleanup()
  end

  defp cleanup_retry_workspace(%{workspace_path: workspace_path})
       when is_binary(workspace_path) and workspace_path != "" do
    {:error, :workspace_binding_missing}
  end

  defp cleanup_retry_workspace(_metadata), do: {:error, :workspace_binding_missing}

  defp cleanup_blocked_terminal_issue(%State{} = state, issue_id) do
    case Map.get(state.blocked, issue_id) do
      %{} = blocked_entry ->
        case maybe_cleanup_bound_workspace(blocked_entry, true) do
          :ok ->
            release_issue_claim(state, issue_id)

          {:error, _reason} ->
            updated_entry = %{
              blocked_entry
              | error: "bound workspace cleanup failed and requires operator reconciliation",
                preserve_on_terminal?: true
            }

            %{
              state
              | claimed: MapSet.put(state.claimed, issue_id),
                blocked: Map.put(state.blocked, issue_id, updated_entry)
            }
        end

      _missing ->
        release_issue_claim(state, issue_id)
    end
  end

  defp normalize_workspace_cleanup({:ok, _removed}), do: :ok
  defp normalize_workspace_cleanup({:error, reason, _detail}), do: {:error, reason}

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, _reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues failure_kind=tracker_fetch_failed")
    end
  end

  defp run_terminal_workspace_cleanup_if_valid do
    case Config.validate!() do
      :ok ->
        run_terminal_workspace_cleanup()

      {:error, _reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup because workflow validation failed")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp handle_active_retry(state, issue, attempt, metadata) do
    state = refresh_compatibility_circuit(state)

    if compatibility_circuit_open?(state) do
      {:noreply, block_undispatched_issue_for_circuit(state, issue)}
    else
      do_handle_active_retry(state, issue, attempt, metadata)
    end
  end

  defp do_handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host], metadata)}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    state = discard_issue_retry(state, issue_id)

    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id)
    }
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    if metadata[:delay_type] == :continuation and attempt == 1 do
      @continuation_retry_delay_ms
    else
      failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_value(previous_retry, metadata, key) do
    Map.get(metadata, key) || Map.get(previous_retry, key)
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {worker_host_load(state, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_host_load(%State{} = state, worker_host) when is_binary(worker_host) do
    running_worker_host_count(state.running, worker_host) +
      retained_blocked_controller_count(state.blocked, worker_host: worker_host)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        worker_host_load(state, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp agent_exit_category(:normal), do: :normal
  defp agent_exit_category(:shutdown), do: :shutdown
  defp agent_exit_category({:shutdown, _reason}), do: :shutdown
  defp agent_exit_category(:killed), do: :killed
  defp agent_exit_category(:kill), do: :killed
  defp agent_exit_category(:noproc), do: :process_missing
  defp agent_exit_category(:noconnection), do: :node_disconnected
  defp agent_exit_category({kind, _reason}) when kind in [:error, :exit, :throw], do: :exception
  defp agent_exit_category(_reason), do: :worker_failure

  defp task_start_failure_category(:max_children), do: :capacity_exhausted
  defp task_start_failure_category(:already_present), do: :already_present
  defp task_start_failure_category(_reason), do: :task_start_failed

  defp retry_lookup_failure_category(_reason), do: :tracker_lookup_failed

  defp message_category(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) -> tag
      _other -> :unclassified
    end
  end

  defp message_category(message) when is_atom(message), do: message
  defp message_category(_message), do: :unclassified

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running) -
        retained_blocked_controller_count(state.blocked),
      0
    )
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          run_id: Map.get(metadata, :run_id),
          attempt_id: Map.get(metadata, :attempt_id),
          session_id: metadata.session_id,
          codex_app_server_pid: metadata.codex_app_server_pid,
          codex_input_tokens: metadata.codex_input_tokens,
          codex_output_tokens: metadata.codex_output_tokens,
          codex_total_tokens: metadata.codex_total_tokens,
          turn_count: Map.get(metadata, :turn_count, 0),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          last_event_id: Map.get(metadata, :last_event_id),
          last_event_sequence: Map.get(metadata, :event_sequence, 0),
          last_event_type: Map.get(metadata, :last_event_type),
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path),
          run_id: Map.get(retry, :run_id),
          attempt_id: Map.get(retry, :attempt_id),
          last_event_id: Map.get(retry, :last_event_id),
          last_event_sequence: Map.get(retry, :event_sequence, 0),
          last_event_type: Map.get(retry, :last_event_type)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          run_id: Map.get(metadata, :run_id),
          attempt_id: Map.get(metadata, :attempt_id),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event),
          last_event_id: Map.get(metadata, :last_event_id),
          last_event_sequence: Map.get(metadata, :event_sequence, 0),
          last_event_type: Map.get(metadata, :last_event_type)
        }
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       compatibility_circuit: compatibility_circuit_snapshot(state.compatibility_circuit),
       codex_totals: state.codex_totals,
       rate_limits: Map.get(state, :codex_rate_limits),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp compatibility_circuit_snapshot(nil), do: %{open?: false}

  defp compatibility_circuit_snapshot(marker) when is_map(marker) do
    %{
      open?: true,
      kind: Map.get(marker, :kind),
      schema_version: Map.get(marker, :schema_version),
      codex_version: Map.get(marker, :codex_version),
      compatibility_manifest_sha256: Map.get(marker, :compatibility_manifest_sha256)
    }
  end

  defp record_codex_event(%State{} = state, issue_id, update) do
    with {:ok, location, metadata, state, run_id, attempt_id, projection} <-
           event_context(state, issue_id, update),
         type <- normalized_event_type(update[:event]),
         sequence <- Map.get(metadata, :event_sequence, 0) + 1,
         attrs <-
           event_attrs(
             state,
             issue_id,
             metadata,
             update,
             %{run_id: run_id, attempt_id: attempt_id, sequence: sequence},
             type,
             event_severity(update[:event]),
             public_event_payload(update)
           ),
         {:ok, event} <- Event.new(attrs) do
      case append_to_event_sink(state, event) do
        :appended ->
          state = put_event_cursor(state, location, issue_id, metadata, event)

          event_update =
            Map.merge(update, %{
              run_id: run_id,
              attempt_id: attempt_id,
              studio_event_id: event.event_id,
              studio_event_sequence: event.sequence,
              studio_event_type: event.type
            })

          {:appended, state, event_update, projection}

        :duplicate ->
          {:duplicate, state}

        :rejected ->
          {:rejected, state}
      end
    else
      {:error, reason} ->
        Logger.warning("Rejected structured codex event #{structured_event_log_context(state, issue_id, update)} failure_kind=#{event_failure_category(reason)}")

        {:rejected, state}
    end
  end

  defp append_internal_event(
         %State{} = state,
         issue_id,
         location,
         type,
         severity,
         payload
       ) do
    case event_metadata(state, location, issue_id) do
      nil ->
        state

      metadata ->
        run_id = valid_id_or_new(state, Map.get(metadata, :run_id))
        attempt_id = valid_id_or_new(state, Map.get(metadata, :attempt_id))
        sequence = non_negative_sequence(Map.get(metadata, :event_sequence)) + 1
        metadata = Map.merge(metadata, %{run_id: run_id, attempt_id: attempt_id})
        state = put_event_metadata(state, location, issue_id, metadata)

        attrs =
          event_attrs(
            state,
            issue_id,
            metadata,
            %{timestamp: event_now(state)},
            %{run_id: run_id, attempt_id: attempt_id, sequence: sequence},
            type,
            severity,
            payload
          )

        with {:ok, event} <- Event.new(attrs),
             :appended <- append_to_event_sink(state, event) do
          put_event_cursor(state, location, issue_id, metadata, event)
        else
          :duplicate -> state
          _error -> state
        end
    end
  end

  defp append_attempt_exit_event(state, issue_id, _running_entry, reason) do
    append_internal_event(
      state,
      issue_id,
      :running,
      "worker.attempt.exited",
      if(reason == :normal, do: "info", else: "error"),
      %{"exit_category" => reason |> agent_exit_category() |> Atom.to_string()}
    )
  end

  defp event_context(%State{} = state, issue_id, update) do
    case locate_event_metadata(state, issue_id) do
      {location, metadata} ->
        resolve_event_context(state, issue_id, update, location, metadata)

      nil ->
        {:error, :missing_run_context}
    end
  end

  defp resolve_event_context(state, issue_id, update, location, metadata) do
    stored_run_id = Map.get(metadata, :run_id)
    stored_attempt_id = Map.get(metadata, :attempt_id)

    with {:ok, incoming_run_id} <- incoming_identity(update, :run_id),
         {:ok, incoming_attempt_id} <- incoming_identity(update, :attempt_id),
         :ok <- require_matching_run_id(stored_run_id, incoming_run_id) do
      build_event_context(
        state,
        issue_id,
        location,
        metadata,
        stored_run_id,
        incoming_run_id,
        stored_attempt_id,
        incoming_attempt_id
      )
    end
  end

  defp build_event_context(
         state,
         issue_id,
         location,
         metadata,
         stored_run_id,
         incoming_run_id,
         stored_attempt_id,
         incoming_attempt_id
       ) do
    run_id = canonical_identity_or_new(state, stored_run_id, incoming_run_id)
    current_attempt_id = canonical_identity_or_new(state, stored_attempt_id, incoming_attempt_id)
    event_attempt_id = incoming_attempt_id || current_attempt_id

    metadata =
      Map.merge(metadata, %{
        run_id: run_id,
        attempt_id: current_attempt_id,
        event_sequence: non_negative_sequence(Map.get(metadata, :event_sequence))
      })

    state = put_event_metadata(state, location, issue_id, metadata)

    projection =
      if location == :running and
           identity_absent_or_equal?(incoming_attempt_id, current_attempt_id) do
        :running
      else
        :late
      end

    {:ok, location, metadata, state, run_id, event_attempt_id, projection}
  end

  defp locate_event_metadata(state, issue_id) do
    cond do
      is_map(Map.get(state.running, issue_id)) -> {:running, Map.fetch!(state.running, issue_id)}
      is_map(Map.get(state.retry_attempts, issue_id)) -> {:retrying, Map.fetch!(state.retry_attempts, issue_id)}
      is_map(Map.get(state.blocked, issue_id)) -> {:blocked, Map.fetch!(state.blocked, issue_id)}
      true -> nil
    end
  end

  defp event_metadata(state, :running, issue_id), do: Map.get(state.running, issue_id)

  defp put_event_metadata(state, :running, issue_id, metadata) do
    %{state | running: Map.put(state.running, issue_id, metadata)}
  end

  defp put_event_metadata(state, :retrying, issue_id, metadata) do
    %{state | retry_attempts: Map.put(state.retry_attempts, issue_id, metadata)}
  end

  defp put_event_metadata(state, :blocked, issue_id, metadata) do
    %{state | blocked: Map.put(state.blocked, issue_id, metadata)}
  end

  defp put_event_cursor(state, location, issue_id, metadata, event) do
    put_event_metadata(
      state,
      location,
      issue_id,
      Map.merge(metadata, %{
        event_sequence: event.sequence,
        last_event_id: event.event_id,
        last_event_type: event.type
      })
    )
  end

  defp event_attrs(
         state,
         issue_id,
         metadata,
         update,
         %{run_id: run_id, attempt_id: attempt_id, sequence: sequence},
         type,
         severity,
         payload
       ) do
    operation_id = operation_id_from_update(update)

    %{
      schema_version: 1,
      sequence: sequence,
      occurred_at: event_timestamp(state, update[:timestamp]),
      issue_id: issue_id,
      issue_identifier: event_issue_identifier(metadata, issue_id),
      run_id: run_id,
      attempt_id: attempt_id,
      thread_id: safe_identifier(update[:thread_id]),
      turn_id: safe_identifier(update[:turn_id]),
      type: type,
      severity: severity,
      payload: payload,
      redacted: true
    }
    |> maybe_put_event_operation_id(operation_id)
  end

  defp append_to_event_sink(%State{} = state, event) do
    case EventSink.append(state.event_sink || EventSink.Noop, event) do
      {:ok, result} when result in [:appended, :accepted] -> :appended
      {:ok, :duplicate} -> :duplicate
      {:error, reason} -> handle_event_sink_error(reason, event)
    end
  rescue
    _error ->
      Logger.warning("Structured event sink failed #{structured_event_log_context(event)} failure_kind=exception; continuing without persistence")

      :appended
  catch
    :exit, _reason ->
      Logger.warning("Structured event sink failed #{structured_event_log_context(event)} failure_kind=exit; continuing without persistence")

      :appended
  end

  defp handle_event_sink_error(reason, event) do
    context = structured_event_log_context(event)

    if event_sink_contract_error?(reason) do
      Logger.error("Structured event sink rejected producer event #{context} failure_kind=#{event_failure_category(reason)}")

      :rejected
    else
      Logger.warning("Structured event sink unavailable #{context} failure_kind=#{event_failure_category(reason)}; continuing without persistence")

      :appended
    end
  end

  defp event_sink_contract_error?(reason) do
    match?({:event_conflict, _}, reason) or
      match?({:invalid_event, _}, reason)
  end

  defp event_issue_identifier(%{identifier: identifier}, _issue_id) when is_binary(identifier),
    do: identifier

  defp event_issue_identifier(_metadata, issue_id), do: issue_id

  defp structured_event_log_context(%Event{} = event) do
    structured_event_log_context(%{
      issue_id: event.issue_id,
      issue_identifier: event.issue_identifier,
      run_id: event.run_id,
      attempt_id: event.attempt_id,
      operation_id: event.operation_id,
      event_type: event.type
    })
  end

  defp structured_event_log_context(fields) when is_map(fields) do
    "issue_id=#{event_log_token(fields[:issue_id])} " <>
      "issue_identifier=#{event_log_token(fields[:issue_identifier])} " <>
      "run_id=#{event_log_token(fields[:run_id])} " <>
      "attempt_id=#{event_log_token(fields[:attempt_id])} " <>
      "operation_id=#{event_log_token(fields[:operation_id])} " <>
      "event_type=#{event_log_token(fields[:event_type])}"
  end

  defp structured_event_log_context(%State{} = state, issue_id, update) do
    {trusted_issue_id, issue_identifier, stored_run_id, stored_attempt_id} =
      case locate_event_metadata(state, issue_id) do
        {_location, metadata} ->
          {
            issue_id,
            event_issue_identifier(metadata, issue_id),
            Map.get(metadata, :run_id),
            Map.get(metadata, :attempt_id)
          }

        nil ->
          {nil, nil, nil, nil}
      end

    structured_event_log_context(%{
      issue_id: trusted_issue_id,
      issue_identifier: issue_identifier,
      run_id: canonical_event_log_identity(stored_run_id, update[:run_id]),
      attempt_id: canonical_event_log_identity(stored_attempt_id, update[:attempt_id]),
      operation_id: operation_id_from_update(update),
      event_type: :unvalidated
    })
  end

  defp canonical_event_log_identity(stored, incoming) do
    cond do
      canonical_uuid4?(stored) -> stored
      canonical_uuid4?(incoming) -> incoming
      true -> nil
    end
  end

  defp event_log_token(nil), do: "n/a"
  defp event_log_token(value) when is_atom(value), do: value |> Atom.to_string() |> event_log_token()

  defp event_log_token(value) when is_binary(value) and byte_size(value) <= 512 do
    if String.valid?(value) do
      value
      |> String.replace(~r/[^\p{L}\p{N}._:@\/-]+/u, "_")
      |> String.trim("_")
      |> case do
        "" -> "n/a"
        token -> token
      end
    else
      "n/a"
    end
  end

  defp event_log_token(_value), do: "n/a"

  defp normalized_event_type(event) when is_atom(event) do
    "codex." <> normalize_event_type_segment(Atom.to_string(event))
  end

  defp normalized_event_type(event) when is_binary(event) do
    if String.valid?(event) and byte_size(event) <= 512 do
      normalized = normalize_event_type_segment(event)

      if String.starts_with?(normalized, ["codex.", "worker.", "run.", "operation."]) do
        normalized
      else
        "codex." <> normalized
      end
    else
      event
    end
  end

  defp normalized_event_type(event), do: event

  defp normalize_event_type_segment(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, ".")
    |> String.trim(".")
    |> case do
      "" -> "notification"
      normalized -> normalized
    end
  end

  defp event_severity(event)
       when event in [
              :app_server_protocol_failure,
              :process_cleanup_failed,
              :uncertain_external_outcome
            ],
       do: "error"

  defp event_severity(event) when event in [:approval_required, :turn_input_required],
    do: "warning"

  defp event_severity(_event), do: "info"

  defp public_event_payload(update) do
    %{}
    |> maybe_put_public_value("decision", update[:decision])
    |> maybe_put_public_value("method_category", update[:method_category])
    |> maybe_put_public_value("operation_id", operation_id_from_update(update))
    |> maybe_put_public_value("request_id_type", update[:request_id_type])
    |> maybe_put_public_value("request_kind", update[:request_kind])
    |> maybe_put_public_value("session_id", update[:session_id])
    |> maybe_put_public_value("terminal", update[:terminal])
    |> maybe_put_public_value("tool_kind", update[:tool_kind])
    |> maybe_put_public_value("failure_kind", public_failure_kind(update[:reason]))
    |> maybe_put_public_value("usage", public_usage(update))
  end

  defp public_usage(update) do
    usage = extract_token_usage(update)

    %{}
    |> maybe_put_public_value("input_tokens", get_token_usage(usage, :input))
    |> maybe_put_public_value("output_tokens", get_token_usage(usage, :output))
    |> maybe_put_public_value("total_tokens", get_token_usage(usage, :total))
    |> case do
      empty when map_size(empty) == 0 -> nil
      public -> public
    end
  end

  defp public_failure_kind(%TransportError{kind: kind}), do: Atom.to_string(kind)
  defp public_failure_kind(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp public_failure_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp public_failure_kind(_reason), do: nil

  defp maybe_put_public_value(map, _key, nil), do: map
  defp maybe_put_public_value(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_put_public_value(map, key, value) when is_boolean(value), do: Map.put(map, key, value)
  defp maybe_put_public_value(map, key, value) when is_number(value), do: Map.put(map, key, value)
  defp maybe_put_public_value(map, key, value) when is_atom(value), do: Map.put(map, key, Atom.to_string(value))
  defp maybe_put_public_value(map, key, value) when is_map(value), do: Map.put(map, key, value)
  defp maybe_put_public_value(map, _key, _value), do: map

  defp operation_id_from_update(update) do
    operation = if is_map(update[:operation]), do: update[:operation], else: %{}

    candidate =
      update[:operation_id] || Map.get(operation, :operation_id) || Map.get(operation, "operation_id")

    if canonical_uuid4?(candidate), do: candidate, else: nil
  end

  defp maybe_put_event_operation_id(attrs, nil), do: attrs
  defp maybe_put_event_operation_id(attrs, operation_id), do: Map.put(attrs, :operation_id, operation_id)

  defp event_timestamp(_state, %DateTime{} = timestamp) do
    timestamp
    |> DateTime.to_unix(:microsecond)
    |> DateTime.from_unix!(:microsecond)
  rescue
    _error -> timestamp
  end

  defp event_timestamp(state, _timestamp), do: event_now(state)

  defp event_now(%State{event_clock: clock}) when is_function(clock, 0), do: clock.()
  defp event_now(_state), do: DateTime.utc_now()

  defp valid_id_or_new(state, candidate) do
    if canonical_uuid4?(candidate), do: candidate, else: new_identity(state)
  end

  defp new_identity(%State{id_generator: generator}) when is_function(generator, 0) do
    case generator.() do
      generated when is_binary(generated) ->
        if canonical_uuid4?(generated), do: generated, else: Identity.uuid4()

      _other ->
        Identity.uuid4()
    end
  end

  defp new_identity(_state), do: Identity.uuid4()

  defp incoming_identity(update, key) when is_map(update) and is_atom(key) do
    case Map.fetch(update, key) do
      :error -> {:ok, nil}
      {:ok, candidate} -> validate_incoming_identity(candidate, key)
    end
  end

  defp validate_incoming_identity(candidate, _key) when is_binary(candidate) do
    if canonical_uuid4?(candidate), do: {:ok, candidate}, else: {:error, :invalid_correlation_id}
  end

  defp validate_incoming_identity(_candidate, _key), do: {:error, :invalid_correlation_id}

  defp require_matching_run_id(stored, incoming)
       when is_binary(stored) and is_binary(incoming) do
    if canonical_uuid4?(stored) and stored != incoming,
      do: {:error, :run_id_mismatch},
      else: :ok
  end

  defp require_matching_run_id(_stored, _incoming), do: :ok

  defp canonical_identity_or_new(state, stored, incoming) do
    cond do
      canonical_uuid4?(stored) -> stored
      canonical_uuid4?(incoming) -> incoming
      true -> new_identity(state)
    end
  end

  defp identity_absent_or_equal?(nil, _current), do: true
  defp identity_absent_or_equal?(incoming, current), do: incoming == current

  defp canonical_uuid4?(value) when is_binary(value),
    do: value == String.downcase(value) and Identity.valid_uuid4?(value)

  defp canonical_uuid4?(_value), do: false

  defp non_negative_sequence(sequence) when is_integer(sequence) and sequence >= 0, do: sequence
  defp non_negative_sequence(_sequence), do: 0

  defp correlation_matches?(metadata, incoming) do
    correlation_field_matches?(metadata, incoming, :run_id) and
      correlation_field_matches?(metadata, incoming, :attempt_id)
  end

  defp correlation_field_matches?(metadata, incoming, key) do
    stored = Map.get(metadata, key)

    case {canonical_uuid4?(stored), Map.fetch(incoming, key)} do
      {true, {:ok, ^stored}} -> true
      {true, _missing_or_mismatch} -> false
      {false, :error} -> true
      {false, {:ok, candidate}} -> canonical_uuid4?(candidate)
    end
  end

  defp safe_identifier(value) when is_binary(value) and byte_size(value) <= 512, do: value
  defp safe_identifier(_value), do: nil

  defp safe_binary_or_existing(_existing, incoming) when is_binary(incoming), do: incoming
  defp safe_binary_or_existing(existing, _incoming), do: existing

  defp event_failure_category(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp event_failure_category({kind, _details}) when is_atom(kind), do: Atom.to_string(kind)

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        last_event_id: Map.get(update, :studio_event_id),
        last_event_type: Map.get(update, :studio_event_type),
        thread_id: safe_binary_or_existing(Map.get(running_entry, :thread_id), update[:thread_id]),
        turn_id: safe_binary_or_existing(Map.get(running_entry, :turn_id), update[:turn_id]),
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message:
        Map.take(update, [
          :decision,
          :method_category,
          :operation,
          :operation_id,
          :reason,
          :request_id_type,
          :request_kind,
          :session_id,
          :terminal,
          :thread_id,
          :tool_kind,
          :turn_id,
          :usage
        ]),
      timestamp: update[:timestamp]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    codex_totals =
      apply_token_delta(
        state.codex_totals,
        %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          seconds_running: runtime_seconds
        }
      )

    %{state | codex_totals: codex_totals}
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !todo_issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state)
  end

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        %{state | codex_rate_limits: rate_limits}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
