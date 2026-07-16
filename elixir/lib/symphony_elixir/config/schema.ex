# Downstream modification notice (2026-07-16): Symphony Studio validates and
# safely adapts pinned policies, canonical workspace roots, and managed sandboxes.
defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.Config.ManagedWorkspace
  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.linear.app/graphql")
      field(:api_key, :string)
      field(:project_slug, :string)
      field(:assignee, :string)
      field(:required_labels, {:array, :string}, default: [])
      field(:active_states, {:array, :string}, default: ["Todo", "In Progress"])
      field(:terminal_states, {:array, :string}, default: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:kind, :endpoint, :api_key, :project_slug, :assignee, :required_labels, :active_states, :terminal_states],
        empty_values: []
      )
      |> update_change(:required_labels, fn labels ->
        labels
        |> Enum.map(&(String.trim(&1) |> String.downcase()))
        |> Enum.uniq()
      end)
    end
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [:max_concurrent_agents, :max_turns, :max_retry_backoff_ms, :max_concurrent_agents_by_state],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    @max_process_kill_timeout_ms 30_000
    @max_stderr_tail_bytes 1_048_576
    embedded_schema do
      field(:command, :string, default: "codex app-server")

      field(:approval_policy, StringOrMap,
        default: %{
          "granular" => %{
            "sandbox_approval" => false,
            "rules" => false,
            "mcp_elicitations" => false,
            "skill_approval" => false,
            "request_permissions" => false
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:initialize_timeout_ms, :integer, default: 15_000)
      field(:thread_start_timeout_ms, :integer, default: 30_000)
      field(:turn_start_timeout_ms, :integer, default: 30_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
      field(:max_frame_bytes, :integer, default: 16_777_216)
      field(:stderr_tail_bytes, :integer, default: 65_536)
      field(:process_kill_timeout_ms, :integer, default: 2_000)
      field(:overload_max_attempts, :integer, default: 3)
      field(:overload_backoff_base_ms, :integer, default: 100)
      field(:overload_backoff_max_ms, :integer, default: 2_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :initialize_timeout_ms,
          :thread_start_timeout_ms,
          :turn_start_timeout_ms,
          :stall_timeout_ms,
          :max_frame_bytes,
          :stderr_tail_bytes,
          :process_kill_timeout_ms,
          :overload_max_attempts,
          :overload_backoff_base_ms,
          :overload_backoff_max_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_change(:approval_policy, &Schema.validate_approval_policy/2)
      |> validate_inclusion(:thread_sandbox, ~w(read-only workspace-write danger-full-access))
      |> validate_change(:turn_sandbox_policy, &Schema.validate_turn_sandbox_policy/2)
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:initialize_timeout_ms, greater_than: 0)
      |> validate_number(:thread_start_timeout_ms, greater_than: 0)
      |> validate_number(:turn_start_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
      |> validate_number(:max_frame_bytes, greater_than: 0)
      |> validate_number(:stderr_tail_bytes,
        greater_than: 0,
        less_than_or_equal_to: @max_stderr_tail_bytes
      )
      |> validate_number(:process_kill_timeout_ms,
        greater_than: 0,
        less_than_or_equal_to: @max_process_kill_timeout_ms
      )
      |> validate_number(:overload_max_attempts, greater_than: 0)
      |> validate_number(:overload_backoff_base_ms, greater_than: 0)
      |> validate_number(:overload_backoff_max_ms, greater_than: 0)
      |> validate_overload_backoff()
    end

    defp validate_overload_backoff(changeset) do
      base_ms = get_field(changeset, :overload_backoff_base_ms)
      max_ms = get_field(changeset, :overload_backoff_max_ms)

      if is_integer(base_ms) and is_integer(max_ms) and max_ms < base_ms do
        add_error(
          changeset,
          :overload_backoff_max_ms,
          "must be greater than or equal to overload_backoff_base_ms"
        )
      else
        changeset
      end
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config), do: parse(config, [])

  @spec parse(map(), keyword()) ::
          {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config, opts) when is_map(config) and is_list(opts) do
    base_dir = Keyword.get(opts, :base_dir, File.cwd!())

    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        finalize_settings(settings, base_dir)

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        case normalize_turn_sandbox_policy(policy) do
          {:ok, normalized_policy} ->
            normalized_policy

          {:error, reason} ->
            raise ArgumentError, "invalid explicit Codex turn sandbox policy: #{reason}"
        end

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    with :ok <- validate_managed_runtime_mode(opts),
         :ok <- validate_remote_runtime_workspace(settings, workspace, opts),
         {:ok, policy} <- runtime_turn_sandbox_policy(settings, workspace, opts) do
      maybe_narrow_managed_policy(settings, workspace, policy, opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_approval_policy(atom(), term()) :: keyword(String.t())
  def validate_approval_policy(_field, value)
      when value in ["untrusted", "on-failure", "on-request", "never"],
      do: []

  def validate_approval_policy(field, %{"reject" => policy} = value) when map_size(value) == 1,
    do: validate_boolean_policy(field, policy, ~w(sandbox_approval rules mcp_elicitations))

  def validate_approval_policy(field, %{"granular" => policy} = value) when map_size(value) == 1,
    do:
      validate_boolean_policy(
        field,
        policy,
        ~w(sandbox_approval rules mcp_elicitations skill_approval request_permissions)
      )

  def validate_approval_policy(field, _value),
    do: [{field, "must match the pinned Codex approval policy contract"}]

  @doc false
  @spec validate_turn_sandbox_policy(atom(), term()) :: keyword(String.t())
  def validate_turn_sandbox_policy(field, value) do
    case normalize_turn_sandbox_policy(value) do
      {:ok, _policy} -> []
      {:error, reason} -> [{field, reason}]
    end
  end

  @doc false
  @spec normalize_turn_sandbox_policy(term()) :: {:ok, map()} | {:error, String.t()}
  def normalize_turn_sandbox_policy(policy) when is_map(policy) do
    policy
    |> normalize_keys()
    |> normalize_pinned_turn_sandbox_policy()
  end

  def normalize_turn_sandbox_policy(_policy),
    do: {:error, "must match the pinned Codex turn sandbox policy contract"}

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
  end

  defp finalize_settings(settings, base_dir) do
    tracker = %{
      settings.tracker
      | api_key: resolve_secret_setting(settings.tracker.api_key, System.get_env("LINEAR_API_KEY")),
        assignee: resolve_secret_setting(settings.tracker.assignee, System.get_env("LINEAR_ASSIGNEE"))
    }

    codex = %{
      settings.codex
      | approval_policy:
          settings.codex.approval_policy
          |> normalize_keys()
          |> normalize_approval_policy(),
        turn_sandbox_policy: normalize_optional_turn_sandbox_policy(settings.codex.turn_sandbox_policy)
    }

    with {:ok, workspace_root} <-
           resolve_workspace_root(
             settings.workspace.root,
             Path.join(System.tmp_dir!(), "symphony_workspaces"),
             base_dir
           ) do
      workspace = %{settings.workspace | root: workspace_root}
      {:ok, %{settings | tracker: tracker, workspace: workspace, codex: codex}}
    end
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_turn_sandbox_policy(nil), do: nil

  defp normalize_optional_turn_sandbox_policy(value) do
    {:ok, normalized_policy} = normalize_turn_sandbox_policy(value)
    normalized_policy
  end

  defp normalize_pinned_turn_sandbox_policy(%{"type" => "dangerFullAccess"} = policy) do
    with :ok <- validate_exact_keys(policy, ~w(type)) do
      {:ok, policy}
    end
  end

  defp normalize_pinned_turn_sandbox_policy(%{"type" => "readOnly"} = policy) do
    with :ok <- validate_exact_keys(policy, ~w(type networkAccess)),
         :ok <- validate_optional_boolean(policy, "networkAccess") do
      {:ok, policy}
    end
  end

  defp normalize_pinned_turn_sandbox_policy(%{"type" => "externalSandbox"} = policy) do
    with :ok <- validate_exact_keys(policy, ~w(type networkAccess)),
         :ok <- validate_optional_enum(policy, "networkAccess", ~w(restricted enabled)) do
      {:ok, policy}
    end
  end

  defp normalize_pinned_turn_sandbox_policy(%{"type" => "workspaceWrite"} = policy) do
    allowed_keys = ~w(type writableRoots networkAccess excludeTmpdirEnvVar excludeSlashTmp)

    with :ok <- validate_exact_keys(policy, allowed_keys),
         {:ok, writable_roots} <- normalize_optional_writable_roots(policy),
         :ok <- validate_optional_boolean(policy, "networkAccess"),
         :ok <- validate_optional_boolean(policy, "excludeTmpdirEnvVar"),
         :ok <- validate_optional_boolean(policy, "excludeSlashTmp") do
      normalized_policy =
        if Map.has_key?(policy, "writableRoots") do
          Map.put(policy, "writableRoots", writable_roots)
        else
          policy
        end

      {:ok, normalized_policy}
    end
  end

  defp normalize_pinned_turn_sandbox_policy(_policy),
    do: {:error, "must match the pinned Codex turn sandbox policy contract"}

  defp validate_exact_keys(policy, allowed_keys) do
    case Map.keys(policy) -- allowed_keys do
      [] -> :ok
      unsupported -> {:error, "contains unsupported keys: #{Enum.sort(unsupported) |> Enum.join(", ")}"}
    end
  end

  defp validate_optional_boolean(policy, key) do
    case Map.fetch(policy, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, "#{key} must be a boolean when provided"}
    end
  end

  defp validate_optional_enum(policy, key, allowed_values) do
    case Map.fetch(policy, key) do
      :error ->
        :ok

      {:ok, value} ->
        if value in allowed_values do
          :ok
        else
          {:error, "#{key} must be one of: #{Enum.join(allowed_values, ", ")}"}
        end
    end
  end

  defp normalize_optional_writable_roots(policy) do
    case Map.fetch(policy, "writableRoots") do
      :error ->
        {:ok, []}

      {:ok, roots} when is_list(roots) ->
        Enum.reduce_while(roots, {:ok, []}, &prepend_normalized_writable_root/2)
        |> case do
          {:ok, normalized_roots} -> {:ok, Enum.reverse(normalized_roots)}
          {:error, _reason} = error -> error
        end

      {:ok, _roots} ->
        {:error, "writableRoots must be a list of absolute paths when provided"}
    end
  end

  defp prepend_normalized_writable_root(root, {:ok, normalized_roots}) do
    case normalize_absolute_path(root) do
      {:ok, normalized_root} -> {:cont, {:ok, [normalized_root | normalized_roots]}}
      {:error, reason} -> {:halt, {:error, "writableRoots #{reason}"}}
    end
  end

  defp normalize_absolute_path(path) when is_binary(path) do
    if path != "" and Path.type(path) == :absolute do
      {:ok, Path.expand(path)}
    else
      {:error, "must contain only non-empty absolute paths"}
    end
  end

  defp normalize_absolute_path(_path),
    do: {:error, "must contain only non-empty absolute paths"}

  defp normalize_explicit_runtime_turn_sandbox_policy(policy) do
    case normalize_turn_sandbox_policy(policy) do
      {:ok, normalized_policy} ->
        {:ok, normalized_policy}

      {:error, reason} ->
        {:error, {:unsafe_turn_sandbox_policy, {:invalid_explicit_policy, reason}}}
    end
  end

  defp runtime_turn_sandbox_policy(settings, workspace, opts) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        normalize_explicit_runtime_turn_sandbox_policy(policy)

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  defp validate_managed_runtime_mode(opts) do
    if Keyword.get(opts, :managed, false) and Keyword.get(opts, :remote, false) do
      {:error, {:unsafe_turn_sandbox_policy, :managed_remote_workspace_unsupported}}
    else
      :ok
    end
  end

  defp maybe_narrow_managed_policy(settings, workspace, policy, opts) do
    if Keyword.get(opts, :managed, false) do
      narrow_managed_policy(settings, workspace, policy)
    else
      {:ok, policy}
    end
  end

  defp narrow_managed_policy(settings, workspace, %{"type" => "workspaceWrite"} = policy) do
    with {:ok, canonical_workspace} <- ManagedWorkspace.validate(settings.workspace.root, workspace) do
      {:ok,
       policy
       |> Map.put("writableRoots", [canonical_workspace])
       |> Map.put_new("networkAccess", false)}
    end
  end

  defp narrow_managed_policy(_settings, _workspace, %{"type" => "readOnly"} = policy) do
    {:ok, Map.put_new(policy, "networkAccess", false)}
  end

  defp narrow_managed_policy(_settings, _workspace, %{"type" => type}) do
    {:error, {:unsafe_turn_sandbox_policy, {:managed_policy_type, type}}}
  end

  defp normalize_approval_policy("on-failure"), do: "on-request"
  defp normalize_approval_policy(value) when is_binary(value), do: value

  defp normalize_approval_policy(%{"reject" => legacy}) do
    %{
      "granular" => %{
        "sandbox_approval" => not Map.get(legacy, "sandbox_approval", false),
        "rules" => not Map.get(legacy, "rules", false),
        "mcp_elicitations" => not Map.get(legacy, "mcp_elicitations", false),
        "skill_approval" => false,
        "request_permissions" => false
      }
    }
  end

  defp normalize_approval_policy(%{"granular" => granular}) do
    defaults = %{
      "sandbox_approval" => false,
      "rules" => false,
      "mcp_elicitations" => false,
      "skill_approval" => false,
      "request_permissions" => false
    }

    %{"granular" => Map.merge(defaults, granular)}
  end

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp validate_boolean_policy(field, policy, allowed_keys) when is_map(policy) do
    invalid_keys = Map.keys(policy) -- allowed_keys
    invalid_values = Enum.reject(policy, fn {_key, value} -> is_boolean(value) end)

    if invalid_keys == [] and invalid_values == [] do
      []
    else
      [{field, "contains unsupported keys or non-boolean approval flags"}]
    end
  end

  defp validate_boolean_policy(field, _policy, _allowed_keys),
    do: [{field, "approval policy flags must be a map"}]

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_workspace_root(value, default, base_dir)
       when is_binary(value) and is_binary(default) and is_binary(base_dir) do
    resolved_path = resolve_path_value(value, default)
    expanded_path = Path.expand(resolved_path, Path.expand(base_dir))

    case PathSafety.canonicalize(expanded_path) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:invalid_workflow_config, "workspace.root could not be canonicalized: #{format_path_error(reason)}"}}
    end
  end

  defp format_path_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_path_error({classification, _detail}) when is_atom(classification), do: Atom.to_string(classification)

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp validate_remote_runtime_workspace(settings, workspace, opts) do
    if Keyword.get(opts, :remote, false) do
      workspace_root = default_workspace_root(workspace, settings.workspace.root)

      case normalize_absolute_path(workspace_root) do
        {:ok, ^workspace_root} ->
          :ok

        {:ok, _normalized_workspace_root} ->
          {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root, "must be normalized"}}}

        {:error, reason} ->
          {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root, reason}}}
      end
    else
      :ok
    end
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
