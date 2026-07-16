# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio hardens local
# workspace identity, hooks, symlinks, cleanup bounds, and remote release gates.

defmodule SymphonyElixir.Workspace do
  @moduledoc """
  Creates isolated per-issue workspaces for parallel Codex agents.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety, SSH, WorkspaceHookRunner}

  @remote_workspace_marker "__SYMPHONY_WORKSPACE__"
  @remote_workers_error {:unsupported_release_feature, :remote_workers, :release_5}
  @max_identifier_bytes 180
  @identifier_digest_bytes 16

  @type worker_host :: String.t() | nil
  @type binding :: %{path: Path.t(), root: Path.t()}

  @spec create_for_issue(map() | String.t() | nil, worker_host()) ::
          {:ok, Path.t()} | {:error, term()}
  def create_for_issue(issue_or_identifier, worker_host \\ nil) do
    case create_for_issue_bound(issue_or_identifier, worker_host) do
      {:ok, %{path: workspace}} -> {:ok, workspace}
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates an issue workspace and returns its immutable path/root binding."
  @spec create_for_issue_bound(map() | String.t() | nil, worker_host(), keyword()) ::
          {:ok, binding()} | {:error, term()}
  def create_for_issue_bound(issue_or_identifier, worker_host \\ nil, opts \\ []) do
    issue_context = issue_context(issue_or_identifier)

    try do
      safe_id = safe_identifier(issue_context.issue_identifier)

      with :ok <- validate_worker_host(worker_host),
           settings <- Config.settings!(),
           {:ok, workspace} <- workspace_path_for_issue(safe_id, worker_host, settings),
           :ok <- validate_workspace_path(workspace, worker_host, settings.workspace.root),
           {:ok, workspace, created?} <- ensure_workspace(workspace, worker_host),
           binding = %{path: workspace, root: settings.workspace.root},
           :ok <- publish_workspace_binding(binding, opts),
           :ok <-
             maybe_run_after_create_hook(
               workspace,
               issue_context,
               created?,
               worker_host,
               settings.hooks,
               settings.workspace.root,
               opts
             ) do
        {:ok, binding}
      end
    rescue
      error in [ArgumentError, ErlangError, File.Error] ->
        Logger.error("Workspace creation failed #{issue_log_context(issue_context)} worker_host=#{worker_host_for_log(worker_host)} error=#{Exception.message(error)}")
        {:error, error}
    end
  end

  defp ensure_workspace(workspace, nil) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :directory}} ->
        {:ok, workspace, false}

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:workspace_issue_symlink, workspace}}

      {:ok, _stat} ->
        File.rm_rf!(workspace)
        create_workspace(workspace)

      {:error, :enoent} ->
        create_workspace(workspace)

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp ensure_workspace(workspace, worker_host) when is_binary(worker_host) do
    script =
      [
        "set -eu",
        remote_shell_assign("workspace", workspace),
        "if [ -d \"$workspace\" ]; then",
        "  created=0",
        "elif [ -e \"$workspace\" ]; then",
        "  rm -rf \"$workspace\"",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "else",
        "  mkdir -p \"$workspace\"",
        "  created=1",
        "fi",
        "cd \"$workspace\"",
        "printf '%s\\t%s\\t%s\\n' '#{@remote_workspace_marker}' \"$created\" \"$(pwd -P)\""
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, Config.settings!().hooks.timeout_ms) do
      {:ok, {output, 0}} ->
        parse_remote_workspace_output(output)

      {:ok, {output, status}} ->
        {:error, {:workspace_prepare_failed, worker_host, status, output}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace(workspace) do
    File.mkdir_p!(workspace)

    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :directory}} -> {:ok, workspace, true}
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:workspace_issue_symlink, workspace}}
      {:ok, %File.Stat{type: type}} -> {:error, {:workspace_not_directory, workspace, type}}
      {:error, reason} -> {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  @spec remove(Path.t()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace), do: remove(workspace, nil)

  @spec remove(Path.t(), worker_host()) :: {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove(workspace, nil) do
    settings = Config.settings!()

    case validate_workspace_path(workspace, nil, settings.workspace.root) do
      :ok ->
        remove_bound(workspace, settings.workspace.root, settings.hooks)

      {:error, {:workspace_issue_symlink, _symlink_path}} ->
        remove_bound(workspace, settings.workspace.root)

      {:error, reason} ->
        {:error, reason, ""}
    end
  end

  def remove(workspace, worker_host) when is_binary(worker_host) do
    case validate_worker_host(worker_host) do
      :ok -> remove_remote(workspace, worker_host)
      {:error, reason} -> {:error, reason, ""}
    end
  end

  defp remove_remote(workspace, worker_host) do
    settings = Config.settings!()
    maybe_run_before_remove_hook(workspace, worker_host, settings.hooks)

    script =
      [
        remote_shell_assign("workspace", workspace),
        "rm -rf \"$workspace\""
      ]
      |> Enum.join("\n")

    case run_remote_command(worker_host, script, settings.hooks.timeout_ms) do
      {:ok, {_output, 0}} -> {:ok, []}
      {:ok, {output, status}} -> {:error, {:workspace_remove_failed, worker_host, status, output}, ""}
      {:error, reason} -> {:error, reason, ""}
    end
  end

  @doc "Removes one normalized direct child of an explicitly captured canonical workspace root."
  @spec remove_bound(Path.t(), Path.t()) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_bound(workspace, canonical_root)
      when is_binary(workspace) and is_binary(canonical_root) do
    remove_bound(workspace, canonical_root, nil)
  end

  def remove_bound(workspace, canonical_root) do
    {:error, {:workspace_bound_invalid, workspace, canonical_root}, ""}
  end

  @doc "Runs a captured before-remove hook, then revalidates and removes one bound workspace."
  @spec remove_bound(Path.t(), Path.t(), map() | nil) ::
          {:ok, [String.t()]} | {:error, term(), String.t()}
  def remove_bound(workspace, canonical_root, hooks)
      when is_binary(workspace) and is_binary(canonical_root) and
             (is_map(hooks) or is_nil(hooks)) do
    with :ok <- validate_canonical_root(canonical_root),
         :ok <- validate_bound_workspace_path(workspace, canonical_root),
         :ok <- maybe_run_bound_before_remove_hook(workspace, hooks),
         :ok <- validate_canonical_root(canonical_root),
         :ok <- validate_bound_workspace_path(workspace, canonical_root) do
      File.rm_rf(workspace)
    else
      {:error, reason} -> {:error, reason, ""}
    end
  end

  def remove_bound(workspace, canonical_root, hooks) do
    {:error, {:workspace_bound_invalid, workspace, canonical_root, hooks}, ""}
  end

  @spec remove_issue_workspaces(term()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier), do: remove_issue_workspaces(identifier, nil)

  @spec remove_issue_workspaces(term(), worker_host()) :: :ok | {:error, term()}
  def remove_issue_workspaces(identifier, worker_host) when is_binary(identifier) and is_binary(worker_host) do
    with :ok <- validate_worker_host(worker_host) do
      settings = Config.settings!()
      safe_id = safe_identifier(identifier)

      {:ok, workspace} = workspace_path_for_issue(safe_id, worker_host, settings)

      case remove(workspace, worker_host) do
        {:ok, _removed} -> :ok
        {:error, reason, _detail} -> {:error, reason}
      end
    end
  end

  def remove_issue_workspaces(identifier, nil) when is_binary(identifier) do
    settings = Config.settings!()
    safe_id = safe_identifier(identifier)

    case settings.worker.ssh_hosts do
      [] ->
        {:ok, workspace} = workspace_path_for_issue(safe_id, nil, settings)

        case remove(workspace, nil) do
          {:ok, _removed} -> :ok
          {:error, reason, _detail} -> {:error, reason}
        end

      _worker_hosts ->
        {:error, @remote_workers_error}
    end
  end

  def remove_issue_workspaces(_identifier, worker_host) when is_binary(worker_host) do
    {:error, @remote_workers_error}
  end

  def remove_issue_workspaces(_identifier, _worker_host) do
    :ok
  end

  @spec run_before_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_before_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    settings = Config.settings!()
    run_before_run_hook_bound(workspace, settings.workspace.root, issue_or_identifier, worker_host)
  end

  @doc "Runs the current before-run hook against an immutable workspace root binding."
  @spec run_before_run_hook_bound(
          Path.t(),
          Path.t(),
          map() | String.t() | nil,
          worker_host(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def run_before_run_hook_bound(
        workspace,
        root,
        issue_or_identifier,
        worker_host \\ nil,
        opts \\ []
      )
      when is_binary(workspace) and is_binary(root) do
    issue_context = issue_context(issue_or_identifier)
    settings = Config.settings!()

    with :ok <- validate_worker_host(worker_host),
         :ok <- validate_bound_hook_workspace(workspace, root, worker_host) do
      case settings.hooks.before_run do
        nil ->
          :ok

        command ->
          run_hook(
            command,
            workspace,
            issue_context,
            "before_run",
            worker_host,
            settings.hooks,
            opts
          )
      end
    end
  end

  @spec run_after_run_hook(Path.t(), map() | String.t() | nil, worker_host()) ::
          :ok | {:error, term()}
  def run_after_run_hook(workspace, issue_or_identifier, worker_host \\ nil) when is_binary(workspace) do
    settings = Config.settings!()
    run_after_run_hook_bound(workspace, settings.workspace.root, issue_or_identifier, worker_host)
  end

  @doc "Runs the current after-run hook against an immutable workspace root binding."
  @spec run_after_run_hook_bound(
          Path.t(),
          Path.t(),
          map() | String.t() | nil,
          worker_host(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def run_after_run_hook_bound(
        workspace,
        root,
        issue_or_identifier,
        worker_host \\ nil,
        opts \\ []
      )
      when is_binary(workspace) and is_binary(root) do
    issue_context = issue_context(issue_or_identifier)
    settings = Config.settings!()

    with :ok <- validate_worker_host(worker_host),
         :ok <- validate_bound_hook_workspace(workspace, root, worker_host) do
      case settings.hooks.after_run do
        nil ->
          :ok

        command ->
          run_hook(
            command,
            workspace,
            issue_context,
            "after_run",
            worker_host,
            settings.hooks,
            opts
          )
          |> ignore_hook_failure()
      end
    end
  end

  defp workspace_path_for_issue(safe_id, nil, settings) when is_binary(safe_id) do
    {:ok, Path.join(settings.workspace.root, safe_id)}
  end

  defp workspace_path_for_issue(safe_id, worker_host, settings)
       when is_binary(safe_id) and is_binary(worker_host) do
    {:ok, Path.join(settings.workspace.root, safe_id)}
  end

  defp safe_identifier(identifier) when is_binary(identifier) do
    if ordinary_identifier?(identifier) do
      identifier
    else
      identifier_with_digest(identifier)
    end
  end

  defp safe_identifier(identifier) do
    identifier_with_digest(identifier)
  end

  defp ordinary_identifier?(identifier) do
    byte_size(identifier) <= @max_identifier_bytes and String.valid?(identifier) and
      Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, identifier)
  end

  defp identifier_with_digest(identifier) do
    digest =
      identifier
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> binary_part(0, @identifier_digest_bytes)
      |> Base.encode16(case: :lower)

    suffix = "--" <> digest
    prefix_limit = @max_identifier_bytes - byte_size(suffix)

    prefix =
      identifier
      |> identifier_binary()
      |> sanitize_identifier_bytes()
      |> binary_part_safely(prefix_limit)
      |> normalize_identifier_prefix()

    prefix <> suffix
  end

  defp identifier_binary(identifier) when is_binary(identifier), do: identifier
  defp identifier_binary(_identifier), do: "issue"

  defp sanitize_identifier_bytes(identifier) do
    for <<byte <- identifier>>, into: <<>> do
      if safe_identifier_byte?(byte), do: <<byte>>, else: "_"
    end
  end

  defp safe_identifier_byte?(byte)
       when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?-, ?_, ?.],
       do: true

  defp safe_identifier_byte?(_byte), do: false

  defp binary_part_safely(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary
  defp binary_part_safely(binary, max_bytes), do: binary_part(binary, 0, max_bytes)

  defp normalize_identifier_prefix(prefix) do
    normalized = String.trim_leading(prefix, ".")

    if normalized == "" or normalized in [".", ".."], do: "issue", else: normalized
  end

  defp rollback_new_workspace(workspace, canonical_root, hook_reason, hook_error) do
    if hook_cleanup_failure?(hook_reason) do
      {:error, {:workspace_bootstrap_cleanup_blocked, hook_reason, %{path: workspace, root: canonical_root}}}
    else
      case remove_bound(workspace, canonical_root) do
        {:ok, _removed} ->
          hook_error

        {:error, rollback_reason, _detail} ->
          detail = %{path: workspace, root: canonical_root}

          {:error, {:workspace_bootstrap_rollback_failed, hook_failure_class(hook_reason), rollback_reason, detail}}
      end
    end
  end

  defp maybe_run_after_create_hook(
         workspace,
         issue_context,
         created?,
         worker_host,
         hooks,
         canonical_root,
         opts
       ) do
    if created? do
      run_configured_after_create_hook(
        hooks.after_create,
        workspace,
        issue_context,
        worker_host,
        hooks,
        canonical_root,
        opts
      )
    else
      :ok
    end
  end

  defp run_configured_after_create_hook(
         nil,
         _workspace,
         _issue_context,
         _worker_host,
         _hooks,
         _root,
         _opts
       ),
       do: :ok

  defp run_configured_after_create_hook(
         command,
         workspace,
         issue_context,
         worker_host,
         hooks,
         canonical_root,
         opts
       ) do
    case run_hook(command, workspace, issue_context, "after_create", worker_host, hooks, opts) do
      :ok ->
        :ok

      {:error, hook_reason} = hook_error ->
        rollback_new_workspace(workspace, canonical_root, hook_reason, hook_error)
    end
  end

  defp maybe_run_bound_before_remove_hook(_workspace, nil), do: :ok

  defp maybe_run_bound_before_remove_hook(workspace, hooks) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :directory}} ->
        case hooks.before_remove do
          nil ->
            :ok

          command ->
            command
            |> run_hook(
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove",
              nil,
              hooks
            )
            |> classify_bound_before_remove_result()
        end

      {:ok, _non_directory} ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp classify_bound_before_remove_result(:ok), do: :ok

  defp classify_bound_before_remove_result({:error, reason}) do
    if hook_cleanup_failure?(reason) do
      {:error, {:workspace_before_remove_hook_cleanup_failed, reason}}
    else
      :ok
    end
  end

  defp maybe_run_before_remove_hook(workspace, worker_host, hooks) when is_binary(worker_host) do
    case hooks.before_remove do
      nil ->
        :ok

      command ->
        script =
          [
            remote_shell_assign("workspace", workspace),
            "if [ -d \"$workspace\" ]; then",
            "  cd \"$workspace\"",
            "  #{command}",
            "fi"
          ]
          |> Enum.join("\n")

        run_remote_command(worker_host, script, hooks.timeout_ms)
        |> case do
          {:ok, {output, status}} ->
            handle_hook_command_result(
              {output, status},
              workspace,
              %{issue_id: nil, issue_identifier: Path.basename(workspace)},
              "before_remove"
            )

          {:error, {:workspace_hook_timeout, "before_remove", _timeout_ms} = reason} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}
        end
        |> ignore_hook_failure()
    end
  end

  defp ignore_hook_failure(:ok), do: :ok

  defp ignore_hook_failure({:error, reason} = error) when is_tuple(reason) do
    if hook_cleanup_failure?(reason), do: error, else: :ok
  end

  defp ignore_hook_failure({:error, _reason}), do: :ok

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, hooks, opts \\ [])

  defp run_hook(command, workspace, issue_context, hook_name, nil, hooks, opts) do
    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local")

    hook_runner = Keyword.get(opts, :hook_runner, WorkspaceHookRunner)

    case hook_runner.run(
           command,
           workspace,
           hook_name,
           hooks.timeout_ms,
           hook_runner_options(opts)
         ) do
      :ok ->
        :ok

      {:error, reason} = error ->
        Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=local classification=#{hook_failure_class(reason)}")

        error
    end
  end

  defp run_hook(command, workspace, issue_context, hook_name, worker_host, hooks, _opts)
       when is_binary(worker_host) do
    timeout_ms = hooks.timeout_ms

    Logger.info("Running workspace hook hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} worker_host=#{worker_host}")

    case run_remote_command(worker_host, "cd #{shell_escape(workspace)} && #{command}", timeout_ms) do
      {:ok, cmd_result} ->
        handle_hook_command_result(cmd_result, workspace, issue_context, hook_name)

      {:error, {:workspace_hook_timeout, ^hook_name, _timeout_ms} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp publish_workspace_binding(binding, opts) when is_list(opts) do
    case Keyword.get(opts, :on_bound) do
      callback when is_function(callback, 1) ->
        callback.(binding)
        :ok

      _no_callback ->
        :ok
    end
  end

  defp publish_workspace_binding(_binding, _opts), do: :ok

  defp hook_runner_options(opts) when is_list(opts) do
    case Keyword.get(opts, :hook_observer) do
      observer when is_function(observer, 2) ->
        hook_ref = make_ref()
        [observer: fn event -> observer.(hook_ref, event) end]

      _no_observer ->
        []
    end
  end

  defp handle_hook_command_result({_output, 0}, _workspace, _issue_id, _hook_name) do
    :ok
  end

  defp handle_hook_command_result({output, status}, workspace, issue_context, hook_name) do
    output_bytes = output |> IO.iodata_to_binary() |> byte_size()

    Logger.warning("Workspace hook failed hook=#{hook_name} #{issue_log_context(issue_context)} workspace=#{workspace} status=#{status} output_bytes=#{output_bytes}")

    output_summary = %{
      stdout_bytes: min(output_bytes, 65_536),
      stderr_bytes: 0,
      truncated: output_bytes > 65_536
    }

    {:error, {:workspace_hook_failed, hook_name, status, output_summary}}
  end

  defp validate_workspace_path(workspace, nil, canonical_root) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)

    with :ok <- validate_normalized_root(canonical_root),
         :ok <- validate_direct_child(expanded_workspace, canonical_root) do
      reject_issue_leaf_symlink(expanded_workspace)
    end
  end

  defp validate_workspace_path(workspace, worker_host, _canonical_root)
       when is_binary(workspace) and is_binary(worker_host) do
    cond do
      String.trim(workspace) == "" ->
        {:error, {:workspace_path_unreadable, workspace, :empty}}

      String.contains?(workspace, ["\n", "\r", <<0>>]) ->
        {:error, {:workspace_path_unreadable, workspace, :invalid_characters}}

      true ->
        :ok
    end
  end

  defp validate_bound_hook_workspace(workspace, root, nil) do
    with :ok <- validate_canonical_root(root),
         :ok <- validate_bound_workspace_path(workspace, root) do
      reject_issue_leaf_symlink(workspace)
    end
  end

  defp validate_bound_hook_workspace(workspace, _root, worker_host)
       when is_binary(workspace) and is_binary(worker_host) do
    validate_workspace_path(workspace, worker_host, workspace)
  end

  defp validate_bound_workspace_path(workspace, canonical_root) do
    expanded_workspace = Path.expand(workspace)

    with true <- expanded_workspace == workspace,
         :ok <- validate_direct_child(expanded_workspace, canonical_root) do
      :ok
    else
      false -> {:error, {:workspace_not_normalized, workspace, expanded_workspace}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_canonical_root(canonical_root) do
    with :ok <- validate_normalized_root(canonical_root) do
      case PathSafety.canonicalize(canonical_root) do
        {:ok, ^canonical_root} ->
          :ok

        {:ok, other_root} ->
          {:error, {:workspace_root_not_canonical, canonical_root, other_root}}

        {:error, {:path_canonicalize_failed, path, reason}} ->
          {:error, {:workspace_path_unreadable, path, reason}}
      end
    end
  end

  defp validate_normalized_root(canonical_root) do
    expanded_root = Path.expand(canonical_root)

    cond do
      Path.type(canonical_root) != :absolute ->
        {:error, {:workspace_root_not_absolute, canonical_root}}

      expanded_root != canonical_root ->
        {:error, {:workspace_root_not_normalized, canonical_root, expanded_root}}

      true ->
        :ok
    end
  end

  defp validate_direct_child(workspace, canonical_root) do
    cond do
      workspace == canonical_root ->
        {:error, {:workspace_equals_root, workspace, canonical_root}}

      Path.dirname(workspace) == canonical_root ->
        :ok

      true ->
        {:error, {:workspace_outside_root, workspace, canonical_root}}
    end
  end

  defp reject_issue_leaf_symlink(workspace) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:workspace_issue_symlink, workspace}}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:workspace_path_unreadable, workspace, reason}}
    end
  end

  defp validate_worker_host(nil), do: :ok
  defp validate_worker_host(worker_host) when is_binary(worker_host), do: {:error, @remote_workers_error}
  defp validate_worker_host(worker_host), do: {:error, {:invalid_worker_host, worker_host}}

  defp hook_failure_class({classification, _hook_name}) when is_atom(classification), do: classification

  defp hook_failure_class({classification, _hook_name, _detail}) when is_atom(classification),
    do: classification

  defp hook_failure_class({classification, _hook_name, _status, _summary})
       when is_atom(classification),
       do: classification

  defp hook_failure_class(_reason), do: :workspace_hook_failed

  defp hook_cleanup_failure?({:workspace_hook_cleanup_failed, _hook_name, _phase}), do: true
  defp hook_cleanup_failure?({:workspace_hook_runner_failed, _hook_name}), do: true
  defp hook_cleanup_failure?({:workspace_hook_supervisor_unavailable, _hook_name}), do: true
  defp hook_cleanup_failure?(_reason), do: false

  defp remote_shell_assign(variable_name, raw_path)
       when is_binary(variable_name) and is_binary(raw_path) do
    [
      "#{variable_name}=#{shell_escape(raw_path)}",
      "case \"$#{variable_name}\" in",
      "  '~') #{variable_name}=\"$HOME\" ;;",
      "  '~/'*) " <> variable_name <> "=\"$HOME/${" <> variable_name <> "#~/}\" ;;",
      "esac"
    ]
    |> Enum.join("\n")
  end

  defp parse_remote_workspace_output(output) do
    lines = String.split(IO.iodata_to_binary(output), "\n", trim: true)

    payload =
      Enum.find_value(lines, fn line ->
        case String.split(line, "\t", parts: 3) do
          [@remote_workspace_marker, created, path] when created in ["0", "1"] and path != "" ->
            {created == "1", path}

          _ ->
            nil
        end
      end)

    case payload do
      {created?, workspace} when is_boolean(created?) and is_binary(workspace) ->
        {:ok, workspace, created?}

      _ ->
        {:error, {:workspace_prepare_failed, :invalid_output, output}}
    end
  end

  defp run_remote_command(worker_host, script, timeout_ms)
       when is_binary(worker_host) and is_binary(script) and is_integer(timeout_ms) and timeout_ms > 0 do
    task =
      Task.async(fn ->
        SSH.run(worker_host, script, stderr_to_stdout: true)
      end)

    case Task.yield(task, timeout_ms) do
      {:ok, result} ->
        result

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:workspace_hook_timeout, "remote_command", timeout_ms}}
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    %{
      issue_id: issue_id,
      issue_identifier: identifier || "issue"
    }
  end

  defp issue_context(identifier) when is_binary(identifier) do
    %{
      issue_id: nil,
      issue_identifier: identifier
    }
  end

  defp issue_context(_identifier) do
    %{
      issue_id: nil,
      issue_identifier: "issue"
    }
  end

  defp issue_log_context(%{issue_id: issue_id, issue_identifier: issue_identifier}) do
    "issue_id=#{issue_id || "n/a"} issue_identifier=#{issue_identifier || "issue"}"
  end
end
