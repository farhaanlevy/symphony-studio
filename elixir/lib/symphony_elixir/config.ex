# Downstream modification notice (2026-07-16): Symphony Studio validates the
# non-shell launch contract, deadlines, staged scope, and workflow-relative roots.
defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @remote_workers_release :release_5
  @max_codex_command_bytes 65_536
  @max_codex_command_arguments 256
  @max_codex_command_argument_bytes 16_384

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config, base_dir: Workflow.workflow_directory())

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @doc """
  Converts the legacy `codex.command` string into a non-shell argv.

  Only the first-word `$CODEX_BIN` compatibility token is expanded. Arguments
  remain literal, so command substitution and glob syntax cannot execute.
  """
  @spec codex_command_argv(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def codex_command_argv(command) when is_binary(command) do
    with :ok <- validate_codex_command_characters(command),
         {:ok, argv} <- split_codex_command(command),
         :ok <- validate_codex_command_limits(argv),
         :ok <- validate_codex_command_tokens(argv),
         {:ok, executable} <- resolve_codex_executable(hd(argv)) do
      {:ok, [executable | tl(argv)]}
    end
  end

  def codex_command_argv(_command), do: {:error, {:invalid_codex_command, :not_a_string}}

  @doc "Returns the configured absolute deadline for a synchronous App Server method."
  @spec codex_request_timeout(String.t()) :: pos_integer()
  def codex_request_timeout(method) when is_binary(method) do
    codex = settings!().codex

    case method do
      "initialize" -> codex.initialize_timeout_ms
      "thread/start" -> codex.thread_start_timeout_ms
      "turn/start" -> codex.turn_start_timeout_ms
      _ordinary_read -> codex.read_timeout_ms
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp validate_semantics(settings) do
    with :ok <- validate_remote_workers(settings.worker),
         :ok <- validate_tracker_kind(settings.tracker),
         :ok <- validate_tracker_credentials(settings.tracker) do
      validate_codex_command(settings.codex.command)
    end
  end

  defp validate_remote_workers(%{ssh_hosts: []}), do: :ok

  defp validate_remote_workers(_worker) do
    {:error, {:unsupported_release_feature, :remote_workers, @remote_workers_release}}
  end

  defp validate_tracker_kind(%{kind: nil}), do: {:error, :missing_tracker_kind}
  defp validate_tracker_kind(%{kind: kind}) when kind in ["linear", "memory"], do: :ok

  defp validate_tracker_kind(%{kind: kind}) do
    {:error, {:unsupported_tracker_kind, kind}}
  end

  defp validate_tracker_credentials(%{kind: "linear"} = tracker) do
    cond do
      not is_binary(tracker.api_key) -> {:error, :missing_linear_api_token}
      not is_binary(tracker.project_slug) -> {:error, :missing_linear_project_slug}
      true -> :ok
    end
  end

  defp validate_tracker_credentials(_tracker), do: :ok

  defp validate_codex_command(command) do
    case codex_command_argv(command) do
      {:ok, _argv} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_codex_command_characters(command) do
    cond do
      byte_size(command) > @max_codex_command_bytes ->
        {:error, {:invalid_codex_command, :command_too_long}}

      String.contains?(command, [<<0>>, "\r", "\n"]) ->
        {:error, {:invalid_codex_command, :forbidden_character}}

      true ->
        :ok
    end
  end

  defp split_codex_command(command) do
    case OptionParser.split(command) do
      [] -> {:error, {:invalid_codex_command, :blank}}
      argv -> {:ok, argv}
    end
  rescue
    RuntimeError -> {:error, {:invalid_codex_command, :malformed}}
  end

  defp validate_codex_command_limits(argv) do
    cond do
      length(argv) > @max_codex_command_arguments ->
        {:error, {:invalid_codex_command, :too_many_arguments}}

      oversized_index =
          Enum.find_index(argv, &(byte_size(&1) > @max_codex_command_argument_bytes)) ->
        {:error, {:invalid_codex_command, {:argument_too_long, oversized_index}}}

      true ->
        :ok
    end
  end

  defp validate_codex_command_tokens([executable | arguments]) do
    cond do
      environment_assignment?(executable) ->
        {:error, {:invalid_codex_command, :environment_assignment}}

      control_operator_index = Enum.find_index(arguments, &control_operator?/1) ->
        {:error, {:invalid_codex_command, {:control_operator, control_operator_index + 1}}}

      true ->
        :ok
    end
  end

  defp environment_assignment?(token) do
    Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*=/, token)
  end

  defp control_operator?(token) when token in [";", "&&", "||", "|", "&", "(", ")"], do: true

  defp control_operator?(token) do
    Regex.match?(~r/^(?:\d*)?(?:>>?|<<?|<>|>&|<&)/, token)
  end

  defp resolve_codex_executable("$CODEX_BIN") do
    case System.get_env("CODEX_BIN") do
      value when is_binary(value) and value != "" -> resolve_codex_executable(value)
      _missing -> {:error, {:invalid_codex_command, :missing_codex_bin}}
    end
  end

  defp resolve_codex_executable(executable) do
    case System.find_executable(executable) do
      path when is_binary(path) -> {:ok, Path.expand(path)}
      nil -> {:error, {:invalid_codex_command, :executable_not_found}}
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
