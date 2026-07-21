# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.Capabilities do
  @moduledoc """
  Runs the bounded no-model Codex capability probe and prints redacted JSON.

  This task is a collection boundary, not a readiness authority. The Release 0
  sealer selects and verifies the exact native executable, loads this
  already-compiled task through a project-independent Elixir VM, validates the
  ordered request receipts, and binds the result to the source and conformance
  evidence before it can become green.

      mise exec -C elixir -- mix studio.capabilities \
        --format json --codex-bin /absolute/path/to/codex \
        --cwd /absolute/path/to/checkout \
        --workflow /absolute/path/to/checkout/elixir/WORKFLOW.md

  It initializes App Server and reads capability metadata only. It never starts
  a thread or turn, starts a review, consumes a reset credit, or writes a
  readiness artifact. The machine-readable result is the single final line
  prefixed with `SYMPHONY_STUDIO_CAPABILITIES_JSON=`. An ordinary direct Mix
  task invocation may compile first; the sealed authenticated entry loads only
  fingerprint-bound compiled code and forbids any output before the final
  record.
  """

  use Mix.Task

  import Bitwise, only: [band: 2]

  alias SymphonyElixir.Codex.{CapabilityDiscovery, CapabilityReport}
  alias SymphonyElixir.{ErlexecRuntime, PathSafety, Workflow}

  @requirements ["app.config --no-compile"]
  @shortdoc "Print the redacted no-model Codex capability evidence"
  @switches [
    codex_bin: :string,
    cwd: :string,
    format: :string,
    help: :boolean,
    workflow: :string
  ]
  @aliases [h: :help]
  @evidence_version 1
  @json_prefix "SYMPHONY_STUDIO_CAPABILITIES_JSON="

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    run_with_output(args, fn line -> Mix.shell().info(line) end, false)
  end

  @doc false
  @spec run_sealed([String.t()]) :: :ok
  def run_sealed(args) do
    run_with_output(args, &IO.puts/1, true)
  end

  defp run_with_output(args, output, require_workflow)
       when is_function(output, 1) and is_boolean(require_workflow) do
    case parse_args(args, require_workflow) do
      :help ->
        output.(@moduledoc)
        :ok

      {:ok, options} ->
        encoded = with_workflow(options, &collect_live_evidence/1) |> Jason.encode!()

        output.(@json_prefix <> encoded)

        :ok

      {:error, reason} ->
        Mix.raise("studio.capabilities: #{reason}")
    end
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
        with {:ok, codex_bin} <- required_path(options, :codex_bin, :regular_executable),
             {:ok, cwd} <- required_path(options, :cwd, :directory),
             {:ok, workflow} <- workflow_path(options, require_workflow) do
          {:ok, %{codex_bin: codex_bin, cwd: cwd, workflow: workflow}}
        end
    end
  end

  defp workflow_path(options, true), do: required_path(options, :workflow, :regular_file)

  defp workflow_path(options, false) do
    case options[:workflow] do
      nil -> {:ok, nil}
      _path -> required_path(options, :workflow, :regular_file)
    end
  end

  defp required_path(options, key, expected_type) do
    case options[key] do
      value when is_binary(value) -> validate_path(value, expected_type)
      _missing -> {:error, "missing --#{key |> Atom.to_string() |> String.replace("_", "-")}"}
    end
  end

  defp validate_path(path, expected_type) do
    expanded = Path.expand(path)

    with true <- Path.type(path) == :absolute,
         {:ok, ^expanded} <- PathSafety.canonicalize(expanded),
         {:ok, stat} <- File.lstat(expanded),
         :ok <- validate_stat(stat, expected_type) do
      {:ok, expanded}
    else
      _invalid -> {:error, "invalid or unsafe path"}
    end
  end

  defp validate_stat(%File.Stat{type: :directory}, :directory), do: :ok

  defp validate_stat(%File.Stat{type: :regular}, :regular_file), do: :ok

  defp validate_stat(%File.Stat{type: :regular, mode: mode}, :regular_executable)
       when band(mode, 0o111) != 0,
       do: :ok

  defp validate_stat(_stat, _expected_type), do: {:error, :invalid_type}

  defp with_workflow(%{workflow: nil} = options, collect), do: collect.(options)

  defp with_workflow(%{workflow: workflow} = options, collect) do
    previous = Application.fetch_env(:symphony_elixir, :workflow_file_path)

    try do
      :ok = Workflow.set_workflow_file_path(workflow)
      collect.(options)
    after
      restore_workflow_path(previous)
    end
  end

  defp restore_workflow_path({:ok, path}), do: Workflow.set_workflow_file_path(path)
  defp restore_workflow_path(:error), do: Workflow.clear_workflow_file_path()

  defp collect_live_evidence(%{codex_bin: codex_bin, cwd: cwd}) do
    parent = self()
    receipt_ref = make_ref()

    result =
      with_erlexec(fn ->
        CapabilityDiscovery.probe(
          command_argv: [codex_bin, "app-server"],
          cwd: cwd,
          on_request: fn metadata -> send(parent, {receipt_ref, metadata}) end
        )
      end)

    receipts = collect_receipts(receipt_ref, [])

    with {:ok, discovery} <- result,
         {:ok, report} <- CapabilityReport.public(discovery) do
      %{
        "capabilityReport" => report,
        "reportVersion" => @evidence_version,
        "requestReceipts" =>
          receipts
          |> Enum.with_index(1)
          |> Enum.map(fn {metadata, sequence} -> public_receipt(metadata, sequence, report) end)
      }
    else
      {:error, error} -> Mix.raise(Exception.message(error))
    end
  end

  defp with_erlexec(fun) when is_function(fun, 0) do
    case Process.whereis(:exec) do
      pid when is_pid(pid) ->
        fun.()

      nil ->
        with {:ok, runtime} <- ErlexecRuntime.prepare(),
             {:ok, supervisor} <- SymphonyElixir.Application.start_erlexec_supervisor() do
          try do
            fun.()
          after
            Supervisor.stop(supervisor, :normal, :infinity)
            _cleanup = ErlexecRuntime.cleanup(runtime)
          end
        else
          {:error, reason} -> Mix.raise("isolated process runtime unavailable: #{inspect(reason)}")
        end
    end
  end

  defp collect_receipts(receipt_ref, receipts) do
    receive do
      {^receipt_ref, metadata} -> collect_receipts(receipt_ref, [metadata | receipts])
    after
      0 -> Enum.reverse(receipts)
    end
  end

  defp public_receipt(metadata, sequence, report) do
    %{
      "attempt" => Map.fetch!(metadata, :attempt),
      "classification" => metadata |> Map.fetch!(:classification) |> Atom.to_string(),
      "method" => Map.fetch!(metadata, :method),
      "outcome" => receipt_outcome(Map.fetch!(metadata, :method), report),
      "paramsShape" => params_shape(Map.fetch!(metadata, :method)),
      "requestHash" => Map.fetch!(metadata, :request_hash),
      "sequence" => sequence
    }
  end

  defp receipt_outcome(method, report) do
    case method do
      "account/rateLimits/read" -> status_or_pass(report["quotaShape"])
      "account/usage/read" -> status_or_pass(report["optional"]["usage"])
      "experimentalFeature/list" -> status_or_pass(report["optional"]["experimentalFeatures"])
      "collaborationMode/list" -> status_or_pass(report["optional"]["collaborationModes"])
      _required -> "pass"
    end
  end

  defp status_or_pass(%{"status" => "available"}), do: "pass"
  defp status_or_pass(%{"status" => status}), do: status
  defp status_or_pass(_available), do: "pass"

  defp params_shape(method)
       when method in ["account/rateLimits/read", "account/usage/read"],
       do: "omitted"

  defp params_shape(_method), do: "object"
end
