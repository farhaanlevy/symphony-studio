# Downstream modification notice (2026-07-16): Symphony Studio starts its
# vendored process supervisor after establishing a systemd-safe shell fallback
# and couples each in-memory orchestrator lifetime to its agent and hook tasks.
defmodule SymphonyElixir do
  @moduledoc """
  Entry point for the Symphony orchestrator.
  """

  @doc """
  Start the orchestrator in the current BEAM node.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    SymphonyElixir.Orchestrator.start_link(opts)
  end
end

defmodule SymphonyElixir.Application do
  @moduledoc """
  OTP application entrypoint that starts core supervisors and workers.
  """

  use Application

  alias SymphonyElixir.ErlexecRuntime
  alias SymphonyElixir.EventSink.{Memory, Noop}
  alias SymphonyElixir.Studio.Intent.{AdmissionSink, Store}

  @preview_event_sink SymphonyElixir.StudioEventSink

  @impl true
  def start(_type, _args) do
    :ok = SymphonyElixir.LogFile.configure()

    with {:ok, erlexec_runtime} <- ErlexecRuntime.prepare() do
      case preview_children() do
        {:ok, preview_children} ->
          start_supervisor(erlexec_runtime, preview_children)

        {:error, _reason} = error ->
          _cleanup_result = ErlexecRuntime.cleanup(erlexec_runtime)
          error
      end
    end
  end

  @doc """
  Prepares the deterministic shell environment required by vendored `erlexec`.

  `erlexec` requires a nonblank `SHELL` value even when callers use its
  shell-free argv mode. Service managers commonly omit that interactive-shell
  variable, so Symphony supplies `/bin/sh` only when no usable operator value
  is present.
  """
  @spec prepare_erlexec_environment() :: :ok
  def prepare_erlexec_environment do
    ErlexecRuntime.prepare_shell_environment()
  end

  @doc false
  @spec start_erlexec_supervisor() :: Supervisor.on_start()
  def start_erlexec_supervisor do
    :ok = prepare_erlexec_environment()
    :exec_app.start(:normal, [])
  end

  @impl true
  def stop(state) do
    SymphonyElixir.StatusDashboard.render_offline_status()
    _cleanup_result = cleanup_erlexec_runtime(state)
    :ok
  end

  defp cleanup_erlexec_runtime(%{erlexec_runtime: runtime}),
    do: ErlexecRuntime.cleanup(runtime)

  defp cleanup_erlexec_runtime(_state), do: :ok

  defp start_supervisor(erlexec_runtime, preview_children) do
    children =
      [
        erlexec_child_spec(),
        {Phoenix.PubSub, name: SymphonyElixir.PubSub},
        SymphonyElixir.WorkflowStore
      ] ++
        preview_children ++
        [
          SymphonyElixir.RuntimeSupervisor,
          SymphonyElixir.HttpServer,
          SymphonyElixir.StatusDashboard
        ]

    case Supervisor.start_link(
           children,
           strategy: :one_for_one,
           name: SymphonyElixir.Supervisor
         ) do
      {:ok, supervisor} ->
        {:ok, supervisor, %{erlexec_runtime: erlexec_runtime}}

      {:error, _reason} = error ->
        _cleanup_result = ErlexecRuntime.cleanup(erlexec_runtime)
        error
    end
  end

  defp preview_children do
    case System.get_env("SYMPHONY_STUDIO_DATA_ROOT") do
      nil ->
        {:ok, []}

      root when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute do
          with {:ok, store} <- Store.open(root: Path.join(root, "intent")) do
            {children, downstream} = preview_event_downstream()
            target = AdmissionSink.target(store, downstream)
            Application.put_env(:symphony_elixir, :event_sink, target)
            {:ok, children}
          end
        else
          {:error, :invalid_preview_data_root}
        end

      _invalid ->
        {:error, :invalid_preview_data_root}
    end
  end

  defp preview_event_downstream do
    case Application.get_env(:symphony_elixir, :event_sink, Noop) do
      downstream when downstream in [nil, Noop] ->
        child =
          Supervisor.child_spec(
            {Memory, name: @preview_event_sink, max_runs: 128, max_events_per_run: 512, max_dedup_entries_per_run: 1_024},
            id: @preview_event_sink
          )

        {[child], {Memory, @preview_event_sink}}

      downstream ->
        {[], downstream}
    end
  end

  defp erlexec_child_spec do
    %{
      id: :erlexec,
      start: {__MODULE__, :start_erlexec_supervisor, []},
      restart: :permanent,
      shutdown: 10_000,
      type: :supervisor,
      modules: [:exec_app]
    }
  end
end
