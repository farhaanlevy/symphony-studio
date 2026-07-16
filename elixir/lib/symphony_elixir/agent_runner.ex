# Downstream modification notice (2026-07-15): Symphony Studio propagates
# typed App Server uncertainty and process-cleanup failures as worker blockers.
defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.Codex.{AppServer, TransportError}
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @remote_workers_error {:unsupported_release_feature, :remote_workers, :release_5}
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
  @spec continue_with_issue_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:continue, Issue.t()} | {:done, Issue.t()} | {:error, term()}
  def continue_with_issue_for_test(%Issue{} = issue, issue_state_fetcher)
      when is_function(issue_state_fetcher, 1) do
    continue_with_issue?(issue, issue_state_fetcher)
  end

  @doc false
  @spec transport_blocker_update_for_test(term()) :: map() | nil
  def transport_blocker_update_for_test(reason), do: transport_blocker_update(reason)

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    result =
      with :ok <- validate_release_worker(worker_host) do
        run_on_worker_host(issue, codex_update_recipient, opts, worker_host)
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        kind = failure_kind(reason)
        Logger.error("Agent run failed for #{issue_context(issue)} failure_kind=#{kind}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)} failure_kind=#{kind}"
    end
  end

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue) do
    fn message ->
      send_codex_update(recipient, issue, message)
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    on_transport_failure = fn reason ->
      maybe_send_transport_blocker(codex_update_recipient, issue, reason)
    end

    case AppServer.start_session(workspace,
           worker_host: worker_host,
           on_transport_failure: on_transport_failure
         ) do
      {:ok, session} ->
        send_app_server_session_ready(codex_update_recipient, issue, session)

        run_codex_session(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          max_turns
        )

      {:error, reason} ->
        maybe_send_transport_blocker(codex_update_recipient, issue, reason)
        {:error, reason}
    end
  end

  defp run_codex_session(
         session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         max_turns
       ) do
    result =
      do_run_codex_turns(
        session,
        workspace,
        issue,
        codex_update_recipient,
        opts,
        issue_state_fetcher,
        1,
        max_turns
      )

    case AppServer.stop_session(session, result) do
      :ok ->
        result

      {:error, reason} ->
        maybe_send_transport_blocker(codex_update_recipient, issue, reason)
        {:error, reason}
    end
  catch
    kind, reason ->
      case AppServer.stop_session(session) do
        :ok ->
          :erlang.raise(kind, reason, __STACKTRACE__)

        {:error, cleanup_reason} ->
          maybe_send_transport_blocker(codex_update_recipient, issue, cleanup_reason)
          {:error, cleanup_reason}
      end
  end

  defp maybe_send_transport_blocker(recipient, issue, reason) do
    case transport_blocker_update(reason) do
      nil -> :ok
      update -> send_codex_update(recipient, issue, update)
    end
  end

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

  defp send_app_server_session_ready(recipient, issue, session) do
    metadata = Map.get(session, :metadata, %{})

    send_codex_update(recipient, issue, %{
      codex_app_server_pid: metadata[:codex_app_server_pid],
      event: :app_server_session_ready,
      thread_id: Map.get(session, :thread_id),
      timestamp: DateTime.utc_now()
    })
  end

  defp validate_release_worker(nil), do: :ok
  defp validate_release_worker(_worker_host), do: {:error, @remote_workers_error}

  defp do_run_codex_turns(app_session, workspace, issue, codex_update_recipient, opts, issue_state_fetcher, turn_number, max_turns) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    case AppServer.run_turn(
           app_session,
           prompt,
           issue,
           on_message: codex_message_handler(codex_update_recipient, issue)
         ) do
      {:ok, turn_session} ->
        Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns}")

        case continue_with_issue?(issue, issue_state_fetcher) do
          {:continue, refreshed_issue} when turn_number < max_turns ->
            Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns}")

            do_run_codex_turns(
              app_session,
              workspace,
              refreshed_issue,
              codex_update_recipient,
              opts,
              issue_state_fetcher,
              turn_number + 1,
              max_turns
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
        maybe_send_transport_blocker(codex_update_recipient, issue, reason)
        {:error, reason}
    end
  end

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

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
