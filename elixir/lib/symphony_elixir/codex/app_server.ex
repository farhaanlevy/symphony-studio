# Downstream modification notice (2026-07-16): Symphony Studio keeps outbound
# requests within the pinned contract, adds stable operation correlation,
# registers connection startup containment, adds opt-in managed tools, launches
# local Codex without a shell, and gates remote execution until R5.
defmodule SymphonyElixir.Codex.AppServer do
  @moduledoc """
  Minimal client for the Codex app-server JSON-RPC 2.0 stream over stdio.
  """

  require Logger

  alias SymphonyElixir.Codex.{
    Connection,
    DynamicTool,
    RequestPolicy,
    SchemaBundle,
    TransportError
  }

  alias SymphonyElixir.{Config, Identity}
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PathSafety

  @remote_workers_error {:unsupported_release_feature, :remote_workers, :release_5}

  @public_event_detail_keys %{
    approval_auto_declined: [:decision, :request_id_type, :request_kind],
    approval_required: [:request_id_type, :request_kind],
    notification: [:method_category],
    other_message: [:message_category],
    session_started: [:operation_id, :session_id, :thread_id, :turn_id],
    startup_failed: [:reason],
    tool_call_completed: [:operation_id, :request_id_type, :request_kind, :tool_kind],
    tool_call_failed: [:operation_id, :request_id_type, :request_kind, :tool_kind],
    turn_cancelled: [:terminal],
    turn_completed: [:terminal],
    turn_ended_with_error: [:reason, :session_id],
    turn_failed: [:terminal],
    turn_input_required: [:request_id_type, :request_kind],
    uncertain_external_outcome: [:operation, :reason],
    unsupported_tool_call: [:operation_id, :request_id_type, :request_kind, :tool_kind]
  }

  @public_event_metadata_keys [
    :attempt_id,
    :cleanup_scope,
    :codex_app_server_pid,
    :operation_id,
    :remote_cleanup_conformance,
    :run_id,
    :thread_id,
    :turn_id,
    :usage
  ]

  @base_child_environment ~w(
    ALL_PROXY CODEX_HOME HOME HTTPS_PROXY HTTP_PROXY LANG LC_ALL LOGNAME NO_PROXY
    PATH SHELL SSH_AUTH_SOCK SSL_CERT_DIR
    SSL_CERT_FILE TMPDIR USER XDG_CACHE_HOME XDG_CONFIG_HOME XDG_DATA_HOME
    all_proxy http_proxy https_proxy no_proxy
  )

  @type session :: %{
          connection: pid(),
          metadata: map(),
          approval_policy: String.t() | map(),
          dynamic_tool_options: keyword(),
          fail_closed_approval_requests: boolean(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map(),
          thread_id: String.t(),
          workspace: Path.t(),
          worker_host: String.t() | nil
        }

  @type turn_error ::
          TransportError.t()
          | {:approval_required | :turn_input_required | :turn_failed | :turn_cancelled, map()}

  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        result = run_turn(session, prompt, issue, opts)

        case stop_session(session, result) do
          :ok -> result
          {:error, reason} -> {:error, reason}
        end
      catch
        kind, reason ->
          case stop_session(session) do
            :ok -> :erlang.raise(kind, reason, __STACKTRACE__)
            {:error, cleanup_reason} -> {:error, cleanup_reason}
          end
      end
    end
  end

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)

    with :ok <- validate_release_worker(worker_host),
         {:ok, settings} <- Config.settings(),
         :ok <- validate_release_worker_config(settings.worker),
         {:ok, expanded_workspace} <- validate_workspace_cwd(workspace, settings.workspace.root),
         {:ok, session_policies} <- session_policies(settings, expanded_workspace, opts),
         {:ok, command_argv} <- Config.codex_command_argv(settings.codex.command),
         {:ok, connection} <-
           start_connection(expanded_workspace, command_argv, settings.codex, opts) do
      metadata = connection_metadata(connection, worker_host)

      case do_start_session(connection, expanded_workspace, session_policies) do
        {:ok, thread_id} ->
          {:ok,
           %{
             connection: connection,
             metadata: metadata,
             approval_policy: session_policies.approval_policy,
             fail_closed_approval_requests: session_policies.approval_policy == "never",
             thread_sandbox: session_policies.thread_sandbox,
             turn_sandbox_policy: session_policies.turn_sandbox_policy,
             dynamic_tool_options: session_policies.dynamic_tool_options,
             thread_id: thread_id,
             workspace: expanded_workspace,
             worker_host: worker_host
           }}

        {:error, reason} ->
          close_failed_session_start(connection, reason)
      end
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, turn_error()}
  def run_turn(
        %{
          connection: connection,
          metadata: metadata,
          approval_policy: approval_policy,
          fail_closed_approval_requests: fail_closed_approval_requests,
          turn_sandbox_policy: turn_sandbox_policy,
          thread_id: thread_id,
          workspace: workspace
        } = session,
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)

    dynamic_tool_options = Map.get(session, :dynamic_tool_options, [])

    tool_executor =
      Keyword.get(opts, :tool_executor, fn tool, arguments ->
        DynamicTool.execute(tool, arguments, dynamic_tool_options)
      end)

    case start_turn(connection, thread_id, prompt, workspace, approval_policy, turn_sandbox_policy) do
      {:ok, turn_id, request_metadata} ->
        session_id = public_session_id(thread_id, turn_id)

        turn_metadata =
          metadata
          |> Map.merge(Map.take(request_metadata, [:attempt_id, :operation_id, :run_id]))
          |> Map.put(:thread_id, thread_id)
          |> Map.put(:turn_id, turn_id)

        Logger.info("Codex session started for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_started,
          %{
            session_id: session_id,
            thread_id: thread_id,
            turn_id: turn_id,
            operation_id: request_metadata.operation_id
          },
          turn_metadata
        )

        case await_turn_completion(
               connection,
               on_message,
               tool_executor,
               fail_closed_approval_requests
             ) do
          {:ok, result} ->
            Logger.info("Codex session completed for #{issue_context(issue)} session_id=#{session_id}")

            {:ok,
             %{
               result: result,
               session_id: session_id,
               thread_id: thread_id,
               turn_id: turn_id,
               operation_id: request_metadata.operation_id
             }}

          {:error, reason} ->
            public_reason = public_error(reason)

            Logger.warning("Codex session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(public_reason)}")

            emit_message(
              on_message,
              :turn_ended_with_error,
              %{
                session_id: session_id,
                reason: public_reason
              },
              turn_metadata
            )

            maybe_emit_uncertain_outcome(on_message, reason, turn_metadata)

            {:error, reason}
        end

      {:error, reason} ->
        public_reason = public_error(reason)
        Logger.error("Codex session failed for #{issue_context(issue)}: #{inspect(public_reason)}")
        emit_message(on_message, :startup_failed, %{reason: public_reason}, metadata)
        maybe_emit_uncertain_outcome(on_message, reason, metadata)
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok | {:error, TransportError.t()}
  def stop_session(session), do: stop_session(session, nil)

  @spec stop_session(session(), term()) :: :ok | {:error, TransportError.t()}

  def stop_session(%{connection: connection}, {:error, %TransportError{} = error})
      when is_pid(connection) do
    Connection.close_with_error(connection, error)
  end

  def stop_session(%{connection: connection}, _result) when is_pid(connection) do
    Connection.close(connection)
  end

  @doc """
  Requests cancellation of the active pinned-protocol turn.

  The acknowledgement only proves that App Server accepted the interrupt.
  Callers must still wait for the worker to finish and for `stop_session/2` to
  verify process retirement before deleting its workspace.
  """
  @spec interrupt_turn(session(), String.t()) :: :ok | {:error, term()}
  def interrupt_turn(%{connection: connection, thread_id: thread_id}, turn_id)
      when is_pid(connection) and is_binary(thread_id) and thread_id != "" and
             is_binary(turn_id) and turn_id != "" do
    case request(connection, "turn/interrupt", %{
           "threadId" => thread_id,
           "turnId" => turn_id
         }) do
      {:ok, %{}, _request_metadata} ->
        :ok

      {:ok, _invalid_result, request_metadata} ->
        {:error, invalid_side_effect_response(request_metadata)}

      {:error, _reason} = error ->
        error
    end
  end

  def interrupt_turn(_session, _turn_id), do: {:error, :invalid_turn_interrupt_context}

  @spec close_failed_session_start(pid(), TransportError.t()) :: {:error, TransportError.t()}
  defp close_failed_session_start(connection, %TransportError{} = reason) do
    Connection.close_with_error(connection, reason)
  end

  defp validate_release_worker(nil), do: :ok
  defp validate_release_worker(_worker_host), do: {:error, @remote_workers_error}

  defp validate_release_worker_config(%{ssh_hosts: []}), do: :ok
  defp validate_release_worker_config(_worker), do: {:error, @remote_workers_error}

  defp validate_workspace_cwd(workspace, workspace_root)
       when is_binary(workspace) and is_binary(workspace_root) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(workspace_root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp start_connection(workspace, command_argv, codex, opts) do
    notify_connection_lifecycle(opts, :on_connection_starting, [])

    case Connection.start(command_argv, connection_options(workspace, codex, opts)) do
      {:ok, _connection} = started ->
        started

      {:error, _reason} = error ->
        notify_connection_lifecycle(opts, :on_connection_start_failed, [])
        error
    end
  end

  defp notify_connection_lifecycle(opts, key, args) when is_list(opts) and is_list(args) do
    callback = Keyword.get(opts, key)

    if is_function(callback, length(args)) do
      apply(callback, args)
    end

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp connection_options(workspace, codex, opts) do
    [
      env: child_environment(),
      kill_timeout_ms: codex.process_kill_timeout_ms,
      max_frame_bytes: codex.max_frame_bytes,
      metadata: Map.merge(worker_metadata(nil), correlation_metadata(opts)),
      on_cleanup_authority: Keyword.get(opts, :on_cleanup_authority),
      overload_backoff_base_ms: codex.overload_backoff_base_ms,
      overload_backoff_max_ms: codex.overload_backoff_max_ms,
      overload_max_attempts: codex.overload_max_attempts,
      on_started: Keyword.get(opts, :on_connection_started),
      on_transport_failure: Keyword.get(opts, :on_transport_failure, fn _error -> :ok end),
      process_adapter: Keyword.get(opts, :process_adapter, SymphonyElixir.Codex.ProcessAdapter),
      stderr_tail_bytes: codex.stderr_tail_bytes
    ]
    |> Keyword.put(:cd, workspace)
  end

  defp child_environment do
    extra = Application.get_env(:symphony_elixir, :codex_child_environment_allowlist, [])

    (@base_child_environment ++ extra)
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) -> [{name, value}]
        nil -> []
      end
    end)
  end

  defp worker_metadata(_host), do: %{cleanup_scope: :local_pid_namespace}

  defp connection_metadata(connection, worker_host) when is_pid(connection) do
    metadata = Connection.metadata(connection)

    base_metadata =
      metadata
      |> Map.take([
        :attempt_id,
        :cleanup_scope,
        :operation_id,
        :remote_cleanup_conformance,
        :run_id,
        :thread_id,
        :turn_id
      ])
      |> maybe_put_codex_pid(metadata)

    case worker_host do
      host when is_binary(host) -> Map.put(base_metadata, :worker_host, host)
      _ -> base_metadata
    end
  end

  defp maybe_put_codex_pid(metadata, %{target_pid: target_pid}) do
    Map.put(metadata, :codex_app_server_pid, to_string(target_pid))
  end

  defp maybe_put_codex_pid(metadata, _connection_metadata), do: metadata

  defp correlation_metadata(opts) do
    correlation =
      case Keyword.get(opts, :correlation, %{}) do
        value when is_map(value) -> value
        _value -> %{}
      end

    correlation
    |> Map.take([:attempt_id, :run_id])
    |> Enum.reduce(%{}, fn {key, value}, public ->
      if canonical_uuid4?(value), do: Map.put(public, key, value), else: public
    end)
  end

  defp canonical_uuid4?(value) when is_binary(value),
    do: value == String.downcase(value) and Identity.valid_uuid4?(value)

  defp canonical_uuid4?(_value), do: false

  defp send_initialize(connection) do
    params = %{
      "capabilities" => %{
        "experimentalApi" => true
      },
      "clientInfo" => %{
        "name" => "symphony-orchestrator",
        "title" => "Symphony Orchestrator",
        "version" => "0.1.0"
      }
    }

    case request(connection, "initialize", params) do
      {:ok, _result, _metadata} -> Connection.notify(connection, "initialized")
      other -> other
    end
  end

  defp session_policies(settings, workspace, opts) do
    runtime_policy_options =
      if Keyword.get(opts, :managed, false), do: [managed: true], else: []

    dynamic_tool_options =
      if Keyword.get(opts, :managed, false) do
        [policy: :managed, trusted_context: Keyword.get(opts, :trusted_tool_context, %{})]
      else
        [policy: :upstream]
      end

    with {:ok, turn_sandbox_policy} <-
           Schema.resolve_runtime_turn_sandbox_policy(
             settings,
             workspace,
             runtime_policy_options
           ) do
      {:ok,
       %{
         approval_policy: settings.codex.approval_policy,
         dynamic_tool_options: dynamic_tool_options,
         thread_sandbox: settings.codex.thread_sandbox,
         turn_sandbox_policy: turn_sandbox_policy
       }}
    end
  end

  defp do_start_session(connection, workspace, session_policies) do
    case send_initialize(connection) do
      :ok -> start_thread(connection, workspace, session_policies)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_thread(connection, workspace, %{
         approval_policy: approval_policy,
         dynamic_tool_options: dynamic_tool_options,
         thread_sandbox: thread_sandbox
       }) do
    params = %{
      "approvalPolicy" => approval_policy,
      "sandbox" => thread_sandbox,
      "cwd" => workspace,
      "dynamicTools" => DynamicTool.tool_specs(dynamic_tool_options)
    }

    case request(connection, "thread/start", params) do
      {:ok, %{"thread" => %{"id" => thread_id}}, _metadata}
      when is_binary(thread_id) and thread_id != "" ->
        {:ok, thread_id}

      {:ok, _invalid_result, request_metadata} ->
        {:error, invalid_side_effect_response(request_metadata)}

      other ->
        other
    end
  end

  defp start_turn(connection, thread_id, prompt, workspace, approval_policy, turn_sandbox_policy) do
    params = %{
      "threadId" => thread_id,
      "input" => [
        %{
          "type" => "text",
          "text" => prompt
        }
      ],
      "cwd" => workspace,
      "approvalPolicy" => approval_policy,
      "sandboxPolicy" => turn_sandbox_policy
    }

    case request(connection, "turn/start", params) do
      {:ok, %{"turn" => %{"id" => turn_id}}, request_metadata}
      when is_binary(turn_id) and turn_id != "" ->
        {:ok, turn_id, request_metadata}

      {:ok, _invalid_result, request_metadata} ->
        {:error, invalid_side_effect_response(request_metadata)}

      other ->
        other
    end
  end

  defp invalid_side_effect_response(request_metadata) when is_map(request_metadata) do
    TransportError.new(:uncertain_external_outcome, %{
      cause: %{
        kind: :invalid_side_effect_response,
        message: "Codex App Server returned an invalid side-effect response"
      },
      operation:
        Map.take(request_metadata, [
          :attempt,
          :attempt_id,
          :classification,
          :method,
          :operation_id,
          :request_hash,
          :request_id,
          :run_id,
          :send_state
        ]),
      reconciliation_required: true,
      schema_version: SchemaBundle.version()
    })
  end

  defp request(connection, method, params) do
    Connection.request(connection, method, params, Config.codex_request_timeout(method))
  end

  defp await_turn_completion(connection, on_message, tool_executor, fail_closed_approval_requests) do
    deadline_ms = monotonic_ms() + Config.settings!().codex.turn_timeout_ms

    receive_loop(
      connection,
      on_message,
      deadline_ms,
      tool_executor,
      fail_closed_approval_requests
    )
  end

  defp receive_loop(
         connection,
         on_message,
         deadline_ms,
         tool_executor,
         fail_closed_approval_requests
       ) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      details =
        connection
        |> Connection.diagnostics()
        |> Map.put(:phase, :turn)

      {:error, TransportError.new(:request_timeout, details)}
    else
      case Connection.next_message_until(connection, deadline_ms) do
        {:ok, %{payload: payload, raw: payload_string}} ->
          handle_incoming(
            connection,
            on_message,
            payload,
            payload_string,
            deadline_ms,
            tool_executor,
            fail_closed_approval_requests
          )

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_incoming(
         connection,
         on_message,
         payload,
         payload_string,
         deadline_ms,
         tool_executor,
         fail_closed_approval_requests
       ) do
    case payload do
      %{"method" => "turn/completed"} ->
        emit_turn_event(on_message, :turn_completed, payload, payload_string, connection, payload)

        case Connection.ack_terminal(connection, "turn/completed") do
          :ok -> {:ok, :turn_completed}
          {:error, reason} -> {:error, reason}
        end

      %{"method" => "turn/failed", "params" => _} ->
        emit_turn_event(
          on_message,
          :turn_failed,
          payload,
          payload_string,
          connection,
          Map.get(payload, "params")
        )

        terminal_error(connection, "turn/failed", :turn_failed)

      %{"method" => "turn/cancelled", "params" => _} ->
        emit_turn_event(
          on_message,
          :turn_cancelled,
          payload,
          payload_string,
          connection,
          Map.get(payload, "params")
        )

        terminal_error(connection, "turn/cancelled", :turn_cancelled)

      %{"method" => method}
      when is_binary(method) ->
        handle_turn_method(
          connection,
          on_message,
          payload,
          payload_string,
          method,
          deadline_ms,
          tool_executor,
          fail_closed_approval_requests
        )

      payload ->
        emit_message(
          on_message,
          :other_message,
          %{message_category: :unknown_envelope},
          metadata_from_message(connection, payload)
        )

        receive_loop(
          connection,
          on_message,
          deadline_ms,
          tool_executor,
          fail_closed_approval_requests
        )
    end
  end

  defp emit_turn_event(
         on_message,
         event,
         payload,
         _payload_string,
         connection,
         _payload_details
       ) do
    emit_message(
      on_message,
      event,
      %{terminal: event},
      metadata_from_message(connection, payload)
    )
  end

  defp handle_turn_method(
         connection,
         on_message,
         payload,
         _payload_string,
         method,
         deadline_ms,
         tool_executor,
         fail_closed_approval_requests
       ) do
    metadata = metadata_from_message(connection, payload)

    bounded_tool_executor = fn tool_name, arguments ->
      run_tool_with_deadline(
        connection,
        tool_executor,
        tool_name,
        arguments,
        deadline_ms
      )
    end

    approval_context = %{
      connection: connection,
      deadline_ms: deadline_ms,
      fail_closed_approval_requests: fail_closed_approval_requests,
      metadata: metadata,
      on_message: on_message,
      tool_executor: bounded_tool_executor
    }

    case maybe_handle_approval_request(
           method,
           payload,
           approval_context
         ) do
      :input_required ->
        emit_message(
          on_message,
          :turn_input_required,
          public_request_metadata(payload),
          metadata
        )

        blocked_turn_error(connection, :turn_input_required, payload)

      :approved ->
        receive_loop(
          connection,
          on_message,
          deadline_ms,
          tool_executor,
          fail_closed_approval_requests
        )

      {:error, reason} ->
        {:error, reason}

      :approval_required ->
        emit_message(
          on_message,
          :approval_required,
          public_request_metadata(payload),
          metadata
        )

        blocked_turn_error(connection, :approval_required, payload)

      :unhandled ->
        if needs_input?(method, payload) do
          emit_message(
            on_message,
            :turn_input_required,
            public_request_metadata(payload),
            metadata
          )

          blocked_turn_error(connection, :turn_input_required, payload)
        else
          emit_message(
            on_message,
            :notification,
            %{method_category: notification_method_category(method)},
            metadata
          )

          Logger.debug("Codex notification received category=#{notification_method_category(method)}")

          receive_loop(
            connection,
            on_message,
            deadline_ms,
            tool_executor,
            fail_closed_approval_requests
          )
        end
    end
  end

  defp maybe_handle_approval_request(
         "item/commandExecution/requestApproval",
         %{"id" => id} = payload,
         context
       ) do
    deny_or_require(id, "decline", payload, context)
  end

  defp maybe_handle_approval_request(
         "item/tool/call",
         %{"id" => id, "params" => params} = payload,
         %{
           connection: connection,
           tool_executor: tool_executor
         } = context
       ) do
    tool_name = tool_call_name(params)
    arguments = tool_call_arguments(params)

    case tool_executor.(tool_name, arguments) do
      {:ok, result, deadline_ms, operation} ->
        handle_tool_result(
          connection,
          id,
          payload,
          tool_name,
          result,
          deadline_ms,
          operation,
          context
        )

      {:error, %TransportError{} = error} ->
        {:error, error}
    end
  end

  defp maybe_handle_approval_request(
         "execCommandApproval",
         %{"id" => id} = payload,
         context
       ) do
    deny_or_require(id, "denied", payload, context)
  end

  defp maybe_handle_approval_request(
         "applyPatchApproval",
         %{"id" => id} = payload,
         context
       ) do
    deny_or_require(id, "denied", payload, context)
  end

  defp maybe_handle_approval_request(
         "item/fileChange/requestApproval",
         %{"id" => id} = payload,
         context
       ) do
    deny_or_require(id, "decline", payload, context)
  end

  defp maybe_handle_approval_request(
         "item/tool/requestUserInput",
         %{"id" => _id, "params" => _params},
         _context
       ) do
    :input_required
  end

  defp maybe_handle_approval_request(
         "item/permissions/requestApproval",
         %{"id" => id} = payload,
         %{
           connection: connection,
           deadline_ms: deadline_ms,
           fail_closed_approval_requests: true,
           metadata: metadata,
           on_message: on_message
         }
       ) do
    result = %{"permissions" => %{}, "scope" => "turn"}

    case Connection.respond_until(connection, id, result, deadline_ms) do
      :ok ->
        emit_message(
          on_message,
          :approval_auto_declined,
          payload
          |> public_request_metadata()
          |> Map.put(:decision, :no_permissions_granted),
          metadata
        )

        :approved

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_handle_approval_request(
         "item/permissions/requestApproval",
         %{"id" => _id},
         %{fail_closed_approval_requests: false}
       ) do
    :approval_required
  end

  defp maybe_handle_approval_request(
         "mcpServer/elicitation/request",
         %{"id" => id} = payload,
         %{
           connection: connection,
           deadline_ms: deadline_ms,
           fail_closed_approval_requests: true,
           metadata: metadata,
           on_message: on_message
         }
       ) do
    case Connection.respond_until(connection, id, %{"action" => "decline"}, deadline_ms) do
      :ok ->
        emit_message(
          on_message,
          :approval_auto_declined,
          payload
          |> public_request_metadata()
          |> Map.put(:decision, :decline),
          metadata
        )

        :approved

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_handle_approval_request(_method, _payload, _context) do
    :unhandled
  end

  defp handle_tool_result(
         connection,
         id,
         payload,
         tool_name,
         result,
         deadline_ms,
         operation,
         context
       ) do
    if monotonic_ms() >= deadline_ms do
      {:error, uncertain_tool_response_deadline(Connection.diagnostics(connection), operation)}
    else
      respond_with_tool_result(
        connection,
        id,
        payload,
        tool_name,
        result,
        deadline_ms,
        operation,
        context
      )
    end
  end

  defp respond_with_tool_result(
         connection,
         id,
         payload,
         tool_name,
         result,
         deadline_ms,
         operation,
         %{metadata: metadata, on_message: on_message}
       ) do
    response = Map.take(result, ["success", "contentItems"])

    case Connection.respond_until(connection, id, response, deadline_ms) do
      :ok ->
        emit_tool_result(on_message, metadata, payload, tool_name, result, operation)
        :approved

      {:error, reason} ->
        {:error,
         uncertain_tool_response_failure(
           Connection.diagnostics(connection),
           operation,
           reason
         )}
    end
  end

  defp emit_tool_result(on_message, metadata, payload, tool_name, result, operation) do
    event = tool_result_event(result, supported_dynamic_tool?(tool_name))

    event_details =
      payload
      |> public_request_metadata()
      |> Map.put(:tool_kind, public_tool_kind(tool_name))
      |> Map.put(:operation_id, operation[:operation_id])

    emit_message(on_message, event, event_details, metadata)
  end

  defp tool_result_event(%{"success" => true}, _supported?), do: :tool_call_completed
  defp tool_result_event(_result, false), do: :unsupported_tool_call
  defp tool_result_event(_result, true), do: :tool_call_failed

  defp normalize_dynamic_tool_result(%{} = original_result) do
    result = normalize_dynamic_tool_result_keys(original_result)

    normalize_dynamic_tool_result_map(result)
  end

  defp normalize_dynamic_tool_result(result) do
    output = inspect(result)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => dynamic_tool_content_items(output)
    }
  end

  defp normalize_dynamic_tool_result_map(%{"success" => success} = result) when is_boolean(success) do
    output =
      case Map.get(result, "output") do
        existing_output when is_binary(existing_output) -> existing_output
        _ -> dynamic_tool_output(result)
      end

    content_items =
      case Map.get(result, "contentItems") do
        existing_items when is_list(existing_items) ->
          case normalize_dynamic_tool_content_items(existing_items) do
            {:ok, normalized_items} -> normalized_items
            :error -> dynamic_tool_content_items(output)
          end

        _ ->
          dynamic_tool_content_items(output)
      end

    %{"success" => success, "output" => output, "contentItems" => content_items}
  end

  defp normalize_dynamic_tool_result_map(result) do
    output = inspect(result)

    %{
      "success" => false,
      "output" => output,
      "contentItems" => dynamic_tool_content_items(output)
    }
  end

  defp normalize_dynamic_tool_result_keys(result) do
    Enum.reduce(result, %{}, fn
      {key, value}, normalized when is_atom(key) -> Map.put(normalized, Atom.to_string(key), value)
      {key, value}, normalized -> Map.put(normalized, key, value)
    end)
  end

  defp normalize_dynamic_tool_content_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, normalized_items} ->
      case normalize_dynamic_tool_content_item(item) do
        {:ok, normalized_item} -> {:cont, {:ok, [normalized_item | normalized_items]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, normalized_items} -> {:ok, Enum.reverse(normalized_items)}
      :error -> :error
    end
  end

  defp normalize_dynamic_tool_content_item(item) when is_map(item) do
    normalized_item = normalize_dynamic_tool_result_keys(item)

    case normalized_item do
      %{"type" => "inputText", "text" => text} when map_size(normalized_item) == 2 and is_binary(text) ->
        {:ok, normalized_item}

      %{"type" => "inputImage", "imageUrl" => image_url}
      when map_size(normalized_item) == 2 and is_binary(image_url) ->
        {:ok, normalized_item}

      _ ->
        :error
    end
  end

  defp normalize_dynamic_tool_content_item(_item), do: :error

  defp dynamic_tool_output(%{"contentItems" => [%{"text" => text} | _]}) when is_binary(text), do: text
  defp dynamic_tool_output(result), do: Jason.encode!(result, pretty: true)

  defp dynamic_tool_content_items(output) when is_binary(output) do
    [
      %{
        "type" => "inputText",
        "text" => output
      }
    ]
  end

  defp deny_or_require(
         id,
         decision,
         payload,
         %{
           connection: connection,
           deadline_ms: deadline_ms,
           fail_closed_approval_requests: true,
           metadata: metadata,
           on_message: on_message
         }
       ) do
    case Connection.respond_until(connection, id, %{"decision" => decision}, deadline_ms) do
      :ok ->
        emit_message(
          on_message,
          :approval_auto_declined,
          payload
          |> public_request_metadata()
          |> Map.put(:decision, public_decision(decision)),
          metadata
        )

        :approved

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deny_or_require(_id, _decision, _payload, %{fail_closed_approval_requests: false}) do
    :approval_required
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  @doc false
  @spec emit_message_for_test((map() -> term()), atom(), map(), map()) :: :ok
  def emit_message_for_test(on_message, event, details, metadata) do
    emit_message(on_message, event, details, metadata)
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> public_event_metadata()
      |> Map.merge(public_event_details(event, details))
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    safe_message_callback(on_message, message)
  end

  defp safe_message_callback(on_message, message) do
    _result = on_message.(message)
    :ok
  rescue
    _error ->
      Logger.warning("Codex event callback failed failure_kind=exception")
      :ok
  catch
    _kind, _reason ->
      Logger.warning("Codex event callback failed failure_kind=throw")
      :ok
  end

  defp maybe_emit_uncertain_outcome(
         on_message,
         %TransportError{kind: :uncertain_external_outcome} = reason,
         metadata
       ) do
    operation = reason.details[:operation]

    emit_message(
      on_message,
      :uncertain_external_outcome,
      %{reason: public_error(reason), operation: operation},
      uncertainty_metadata(metadata, operation)
    )
  end

  defp maybe_emit_uncertain_outcome(_on_message, _reason, _metadata), do: :ok

  defp uncertainty_metadata(metadata, operation) when is_map(metadata) and is_map(operation) do
    case Map.get(operation, :operation_id) || Map.get(operation, "operation_id") do
      operation_id when is_binary(operation_id) ->
        if Identity.valid_uuid4?(operation_id),
          do: Map.put(metadata, :operation_id, operation_id),
          else: Map.delete(metadata, :operation_id)

      _missing ->
        Map.delete(metadata, :operation_id)
    end
  end

  defp uncertainty_metadata(metadata, _operation) when is_map(metadata) do
    Map.delete(metadata, :operation_id)
  end

  defp terminal_error(connection, method, kind) do
    case Connection.ack_terminal(connection, method) do
      :ok -> {:error, {kind, %{terminal: true}}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp blocked_turn_error(connection, kind, payload) do
    case Connection.mark_turn_blocked(connection, kind) do
      :ok -> {:error, {kind, public_request_metadata(payload)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec public_request_metadata(map()) :: map()
  defp public_request_metadata(payload) when is_map(payload) do
    %{
      request_id_type: public_request_id_type(Map.get(payload, "id")),
      request_kind: public_request_kind(Map.get(payload, "method"))
    }
  end

  defp public_request_id_type(value) when is_integer(value), do: :integer
  defp public_request_id_type(value) when is_binary(value), do: :string
  defp public_request_id_type(nil), do: :absent
  defp public_request_id_type(_value), do: :invalid

  defp public_request_kind("mcpServer/elicitation/request"), do: :mcp_elicitation
  defp public_request_kind("item/tool/requestUserInput"), do: :tool_user_input

  defp public_request_kind(method) when is_binary(method) do
    if String.starts_with?(method, "turn/"), do: :turn_request, else: :other_request
  end

  defp public_request_kind(_method), do: :unknown

  @spec public_event_details(atom(), map()) :: map()
  defp public_event_details(event, details) when is_map(details) do
    Map.take(details, Map.get(@public_event_detail_keys, event, []))
  end

  defp public_event_metadata(metadata) when is_map(metadata) do
    public_metadata =
      metadata
      |> Map.take(@public_event_metadata_keys)
      |> Map.delete(:usage)

    case public_usage(Map.get(metadata, :usage)) do
      nil -> public_metadata
      usage -> Map.put(public_metadata, :usage, usage)
    end
  end

  defp public_event_metadata(_metadata), do: %{}

  defp public_usage(usage) when is_map(usage) do
    %{}
    |> maybe_put_usage_count(
      :input_tokens,
      usage_count(usage, [
        :input_tokens,
        :prompt_tokens,
        :inputTokens,
        :promptTokens,
        "input_tokens",
        "prompt_tokens",
        "inputTokens",
        "promptTokens"
      ])
    )
    |> maybe_put_usage_count(
      :output_tokens,
      usage_count(usage, [
        :output_tokens,
        :completion_tokens,
        :outputTokens,
        :completionTokens,
        "output_tokens",
        "completion_tokens",
        "outputTokens",
        "completionTokens"
      ])
    )
    |> maybe_put_usage_count(
      :total_tokens,
      usage_count(usage, [
        :total_tokens,
        :totalTokens,
        "total_tokens",
        "totalTokens"
      ])
    )
    |> case do
      empty when map_size(empty) == 0 -> nil
      counts -> counts
    end
  end

  defp public_usage(_usage), do: nil

  defp usage_count(usage, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(usage, key) do
        value when is_integer(value) and value >= 0 -> value
        _value -> nil
      end
    end)
  end

  defp maybe_put_usage_count(counts, _key, nil), do: counts
  defp maybe_put_usage_count(counts, key, value), do: Map.put(counts, key, value)

  defp public_tool_kind(tool_name) do
    cond do
      not is_binary(tool_name) -> :invalid
      supported_dynamic_tool?(tool_name) -> :supported
      true -> :unsupported
    end
  end

  defp public_decision("decline"), do: :decline
  defp public_decision("denied"), do: :denied
  defp public_decision(_decision), do: :deny

  defp public_session_id(thread_id, turn_id) do
    digest =
      :sha256
      |> :crypto.hash([thread_id, <<0>>, turn_id])
      |> Base.encode16(case: :lower)
      |> binary_part(0, 24)

    "session-#{digest}"
  end

  @spec notification_method_category(String.t()) :: :turn | :mcp | :other
  defp notification_method_category(method)
       when method in [
              "turn/started",
              "turn/completed",
              "turn/failed",
              "turn/cancelled",
              "turn/input_required",
              "turn/needs_input"
            ],
       do: :turn

  defp notification_method_category("mcpServer/elicitation/request"), do: :mcp
  defp notification_method_category(method) when is_binary(method), do: :other

  @spec public_error(turn_error()) :: map()
  defp public_error(%TransportError{} = error) do
    %{kind: error.kind, message: error.message, details: error.details}
  end

  defp public_error({kind, _details}) when is_atom(kind), do: %{kind: kind}

  defp run_tool_with_deadline(
         connection,
         tool_executor,
         tool_name,
         arguments,
         deadline_ms
       ) do
    diagnostics = Connection.diagnostics(connection)

    with {:ok, operation} <-
           prepare_tool_operation(tool_name, arguments, deadline_ms, diagnostics) do
      run_prepared_tool(
        tool_executor,
        tool_name,
        arguments,
        deadline_ms,
        diagnostics,
        operation
      )
    end
  end

  defp safe_tool_execution(tool_executor, tool_name, arguments) do
    result =
      tool_name
      |> tool_executor.(arguments)
      |> normalize_dynamic_tool_result()

    {:ok, result}
  rescue
    _error -> {:error, :tool_execution_failed}
  catch
    _kind, _reason -> {:error, :tool_execution_failed}
  end

  defp prepare_tool_operation(tool_name, arguments, deadline_ms, diagnostics) do
    remaining_ms = deadline_ms - monotonic_ms()

    if remaining_ms <= 0 do
      {:error, turn_deadline_error(diagnostics, :tool_preparation)}
    else
      parent = self()
      token = make_ref()

      {worker, monitor_ref} =
        spawn_monitor(fn ->
          operation = %{
            attempt_id: diagnostics[:attempt_id],
            classification: :conservative,
            method: "item/tool/call",
            operation_id: Identity.uuid4(),
            request_hash:
              RequestPolicy.canonical_hash("item/tool/call", %{
                "arguments" => arguments,
                "tool" => tool_name
              }),
            run_id: diagnostics[:run_id],
            send_state: :prepared
          }

          send(parent, {token, operation})
        end)

      receive do
        {^token, operation} when is_map(operation) ->
          Process.demonitor(monitor_ref, [:flush])
          {:ok, operation}

        {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
          {:error, tool_execution_error(diagnostics)}
      after
        remaining_ms ->
          Process.exit(worker, :kill)
          Process.demonitor(monitor_ref, [:flush])
          {:error, turn_deadline_error(diagnostics, :tool_preparation)}
      end
    end
  end

  defp run_prepared_tool(
         tool_executor,
         tool_name,
         arguments,
         deadline_ms,
         diagnostics,
         operation
       ) do
    remaining_ms = deadline_ms - monotonic_ms()
    parent = self()
    token = make_ref()

    if remaining_ms <= 0 do
      {:error, turn_deadline_error(diagnostics, :tool_execution)}
    else
      sent_operation = Map.put(operation, :send_state, :sent)

      {worker, monitor_ref} =
        spawn_monitor(fn ->
          result = safe_tool_execution(tool_executor, tool_name, arguments)
          send(parent, {token, result})
        end)

      receive do
        {^token, {:ok, result}} ->
          Process.demonitor(monitor_ref, [:flush])

          if monotonic_ms() < deadline_ms do
            {:ok, result, deadline_ms, sent_operation}
          else
            {:error, uncertain_tool_timeout(diagnostics, sent_operation)}
          end

        {^token, {:error, :tool_execution_failed}} ->
          Process.demonitor(monitor_ref, [:flush])
          {:error, uncertain_tool_execution_failure(diagnostics, sent_operation)}

        {:DOWN, ^monitor_ref, :process, ^worker, _reason} ->
          {:error, uncertain_tool_execution_failure(diagnostics, sent_operation)}
      after
        remaining_ms ->
          Process.exit(worker, :kill)
          Process.demonitor(monitor_ref, [:flush])
          {:error, uncertain_tool_timeout(diagnostics, sent_operation)}
      end
    end
  end

  defp uncertain_tool_timeout(diagnostics, operation) do
    TransportError.new(
      :uncertain_external_outcome,
      Map.merge(diagnostics, %{
        cause: %{
          kind: :request_timeout,
          message: "Codex dynamic tool execution exceeded the turn deadline"
        },
        operation: operation,
        reconciliation_required: true
      })
    )
  end

  defp uncertain_tool_execution_failure(diagnostics, operation) do
    TransportError.new(
      :uncertain_external_outcome,
      Map.merge(diagnostics, %{
        cause: %{
          kind: :response_error,
          message: "Codex dynamic tool execution failed after dispatch"
        },
        operation: operation,
        reconciliation_required: true
      })
    )
  end

  defp uncertain_tool_response_deadline(diagnostics, operation) do
    TransportError.new(
      :uncertain_external_outcome,
      Map.merge(diagnostics, %{
        cause: %{
          kind: :request_timeout,
          message: "Codex dynamic tool response exceeded the turn deadline"
        },
        operation: operation,
        reconciliation_required: true
      })
    )
  end

  defp uncertain_tool_response_failure(diagnostics, operation, reason) do
    TransportError.new(
      :uncertain_external_outcome,
      Map.merge(diagnostics, %{
        cause: bounded_transport_cause(reason),
        operation: operation,
        reconciliation_required: true
      })
    )
  end

  @spec bounded_transport_cause(TransportError.t()) :: %{kind: atom(), message: String.t()}
  defp bounded_transport_cause(%TransportError{details: %{cause: cause}} = error)
       when is_map(cause) do
    case Map.take(cause, [:kind, :message]) do
      %{kind: kind, message: message} when is_atom(kind) and is_binary(message) ->
        %{kind: kind, message: message}

      _other ->
        %{kind: error.kind, message: error.message}
    end
  end

  defp bounded_transport_cause(%TransportError{} = error),
    do: %{kind: error.kind, message: error.message}

  defp tool_execution_error(diagnostics) do
    TransportError.new(
      :response_error,
      Map.merge(diagnostics, %{
        message_present: false,
        phase: :tool_execution,
        reason: :tool_execution_failed
      })
    )
  end

  @spec turn_deadline_error(map(), atom()) :: TransportError.t()
  defp turn_deadline_error(diagnostics, phase) when is_map(diagnostics) do
    TransportError.new(
      :request_timeout,
      Map.merge(diagnostics, %{phase: phase})
    )
  end

  defp metadata_from_message(connection, payload) do
    connection |> connection_metadata(nil) |> maybe_set_usage(payload)
  end

  @spec maybe_set_usage(map(), map()) :: map()
  defp maybe_set_usage(metadata, payload) when is_map(payload) do
    usage = Map.get(payload, "usage") || Map.get(payload, :usage)

    if is_map(usage) do
      Map.put(metadata, :usage, usage)
    else
      metadata
    end
  end

  defp default_on_message(_message), do: :ok

  defp tool_call_name(params) when is_map(params) do
    value =
      case Map.fetch(params, "tool") do
        {:ok, tool} -> tool
        :error -> Map.get(params, :tool)
      end

    case value do
      name when is_binary(name) and byte_size(name) > 0 -> name
      _ -> nil
    end
  end

  defp tool_call_name(_params), do: nil

  defp supported_dynamic_tool?(tool_name) do
    Enum.any?(DynamicTool.tool_specs(), &(&1["name"] == tool_name))
  end

  defp tool_call_arguments(params) when is_map(params) do
    case Map.fetch(params, "arguments") do
      {:ok, arguments} -> arguments
      :error -> Map.get(params, :arguments, %{})
    end
  end

  defp tool_call_arguments(_params), do: %{}

  defp needs_input?("mcpServer/elicitation/request", payload) when is_map(payload), do: true

  defp needs_input?(method, payload)
       when is_binary(method) and is_map(payload) do
    String.starts_with?(method, "turn/") && input_required_method?(method, payload)
  end

  defp needs_input?(_method, _payload), do: false

  defp input_required_method?(method, payload) when is_binary(method) do
    method in [
      "turn/input_required",
      "turn/needs_input",
      "turn/need_input",
      "turn/request_input",
      "turn/request_response",
      "turn/provide_input",
      "turn/approval_required"
    ] || request_payload_requires_input?(payload)
  end

  defp request_payload_requires_input?(payload) do
    params = Map.get(payload, "params")
    needs_input_field?(payload) || needs_input_field?(params)
  end

  defp needs_input_field?(payload) when is_map(payload) do
    Map.get(payload, "requiresInput") == true or
      Map.get(payload, "needsInput") == true or
      Map.get(payload, "input_required") == true or
      Map.get(payload, "inputRequired") == true or
      Map.get(payload, "type") == "input_required" or
      Map.get(payload, "type") == "needs_input"
  end

  defp needs_input_field?(_payload), do: false

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
