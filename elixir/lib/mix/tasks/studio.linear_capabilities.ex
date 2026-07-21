# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.LinearCapabilities do
  @moduledoc """
  Runs the bounded, read-only Linear capability probe and prints redacted JSON.

      mise exec -C elixir -- mix studio.linear_capabilities --format json

  The task loads one immutable tracker snapshot from the exact selected
  `WORKFLOW.md` through `SymphonyElixir.Config`. It never executes a GraphQL
  mutation. A passing `mutations` row proves only the exact schema surface;
  current-credential mutation permission and execution remain unproven until
  R1-07. Release validation may add `--validation-fixtures` to verify the
  dedicated private fixture shape without exposing its team key, issue keys, or
  provider identities. Ordinary product use remains project-generic. Its only
  machine-readable output is the single final line prefixed with
  `SYMPHONY_STUDIO_LINEAR_CAPABILITIES_JSON=`.
  """

  use Mix.Task

  alias SymphonyElixir.Linear.{CapabilityDiscovery, ReadOnlyBroker}
  alias SymphonyElixir.{PathSafety, Workflow}

  @requirements ["app.config --no-compile"]
  @shortdoc "Print the redacted read-only Linear capability evidence"
  @switches [
    format: :string,
    help: :boolean,
    validation_fixtures: :boolean,
    workflow: :string
  ]
  @aliases [h: :help]
  @json_prefix "SYMPHONY_STUDIO_LINEAR_CAPABILITIES_JSON="

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    run_with_output(args, fn line -> Mix.shell().info(line) end, false, :direct)
  end

  @doc false
  @spec run_sealed([String.t()]) :: :ok
  def run_sealed(args) do
    run_with_output(args, &IO.puts/1, true, :sealed_broker)
  end

  @doc false
  @spec run_with_probe_for_test([String.t()], (-> map()) | (boolean() -> map())) :: :ok
  def run_with_probe_for_test(args, probe) when is_list(args) and is_function(probe, 0) do
    run_with_probe(args, fn _validation_fixtures? -> probe.() end, fn line -> Mix.shell().info(line) end, false)
  end

  def run_with_probe_for_test(args, probe) when is_list(args) and is_function(probe, 1) do
    run_with_probe(args, probe, fn line -> Mix.shell().info(line) end, false)
  end

  defp run_with_output(args, output, require_workflow, mode)
       when is_function(output, 1) and is_boolean(require_workflow) and
              mode in [:direct, :sealed_broker] do
    run_with_probe(
      args,
      probe_for_mode(mode),
      output,
      require_workflow
    )
  end

  defp probe_for_mode(:direct) do
    fn validation_fixtures? ->
      CapabilityDiscovery.probe(validation_fixtures: validation_fixtures?)
    end
  end

  defp probe_for_mode(:sealed_broker) do
    fn validation_fixtures? ->
      case ReadOnlyBroker.with_graphql(&probe_with_broker(&1, validation_fixtures?)) do
        {:ok, report} when is_map(report) -> report
        _blocked -> Mix.raise("studio.linear_capabilities: sealed read-only broker unavailable")
      end
    end
  end

  defp probe_with_broker(broker, validation_fixtures?) do
    CapabilityDiscovery.probe(
      graphql: fn query, variables -> broker_graphql(broker, query, variables) end,
      sealed_broker: true,
      validation_fixtures: validation_fixtures?
    )
  end

  defp broker_graphql(broker, query, variables) do
    case CapabilityDiscovery.broker_operation(query) do
      {:ok, operation} -> broker.(operation, variables)
      _unknown -> {:error, :request_failed}
    end
  end

  defp run_with_probe(args, probe, output, require_workflow) do
    case parse_args(args, require_workflow) do
      :help ->
        output.(@moduledoc)
        :ok

      {:ok, validation_fixtures?, workflow} ->
        report = collect_report(workflow, probe, validation_fixtures?)

        output.(@json_prefix <> canonical_json(report))
        :ok

      {:error, reason} ->
        Mix.raise("studio.linear_capabilities: #{reason}")
    end
  end

  defp collect_report(workflow, probe, validation_fixtures?) do
    with_workflow(workflow, fn ->
      without_caller_logs(fn -> probe.(validation_fixtures?) end)
    end)
  end

  defp parse_args(args, require_workflow) do
    {options, positional, invalid} =
      OptionParser.parse(args, strict: @switches, aliases: @aliases)

    cond do
      options[:help] ->
        :help

      invalid != [] or positional != [] ->
        {:error, "invalid arguments"}

      options[:format] != "json" ->
        {:error, "--format must be json"}

      true ->
        with {:ok, workflow} <- workflow_path(options, require_workflow) do
          {:ok, Keyword.get(options, :validation_fixtures, false), workflow}
        end
    end
  end

  defp workflow_path(options, false) do
    case options[:workflow] do
      nil -> {:ok, nil}
      path -> validate_workflow_path(path)
    end
  end

  defp workflow_path(options, true) do
    case options[:workflow] do
      path when is_binary(path) -> validate_workflow_path(path)
      _missing -> {:error, "missing --workflow"}
    end
  end

  defp validate_workflow_path(path) do
    expanded = Path.expand(path)

    with true <- Path.type(path) == :absolute,
         {:ok, ^expanded} <- PathSafety.canonicalize(expanded),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(expanded) do
      {:ok, expanded}
    else
      _invalid -> {:error, "invalid or unsafe workflow path"}
    end
  end

  defp with_workflow(nil, collect), do: collect.()

  defp with_workflow(workflow, collect) do
    previous = Application.fetch_env(:symphony_elixir, :workflow_file_path)

    try do
      :ok = Workflow.set_workflow_file_path(workflow)
      collect.()
    after
      restore_workflow_path(previous)
    end
  end

  defp restore_workflow_path({:ok, path}), do: Workflow.set_workflow_file_path(path)
  defp restore_workflow_path(:error), do: Workflow.clear_workflow_file_path()

  defp without_caller_logs(fun) when is_function(fun, 0) do
    caller = self()
    was_enabled = Logger.enabled?(caller)
    Logger.disable(caller)

    try do
      fun.()
    after
      if was_enabled, do: Logger.enable(caller)
    end
  end

  defp canonical_json(value) when is_map(value) do
    encoded =
      value
      |> Enum.map(fn {key, nested} -> {to_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(key) <> ":" <> canonical_json(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &canonical_json/1) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)
end
