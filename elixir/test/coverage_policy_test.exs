# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CoveragePolicyTest do
  use ExUnit.Case, async: false

  @baseline_structural_modules [
    SymphonyElixir.Config,
    SymphonyElixir.Linear.Client,
    SymphonyElixir.SpecsCheck,
    SymphonyElixir.Orchestrator,
    SymphonyElixir.Orchestrator.State,
    SymphonyElixir.AgentRunner,
    SymphonyElixir.CLI,
    SymphonyElixir.Codex.AppServer,
    SymphonyElixir.Codex.CleanupGuardian,
    SymphonyElixir.Codex.CapabilityDiscovery,
    SymphonyElixir.Codex.CompatibilityCircuit,
    SymphonyElixir.Codex.Connection,
    SymphonyElixir.Codex.DynamicTool,
    SymphonyElixir.Codex.IdentityBinding,
    SymphonyElixir.Codex.ProcessAdapter,
    SymphonyElixir.Codex.ProcessAdapter.IdentityTracker,
    SymphonyElixir.Codex.SchemaBundle,
    SymphonyElixir.Config.ManagedWorkspace,
    SymphonyElixir.ErlexecRuntime,
    SymphonyElixir.HttpServer,
    SymphonyElixir.StatusDashboard,
    SymphonyElixir.LogFile,
    SymphonyElixir.Linear.CapabilityDiscovery,
    SymphonyElixir.Linear.ReadOnlyBroker,
    SymphonyElixir.Workspace,
    SymphonyElixir.WorkspaceHookRunner,
    SymphonyElixirWeb.DashboardLive,
    SymphonyElixirWeb.Endpoint,
    SymphonyElixirWeb.ErrorHTML,
    SymphonyElixirWeb.ErrorJSON,
    SymphonyElixirWeb.Layouts,
    SymphonyElixirWeb.ObservabilityApiController,
    SymphonyElixirWeb.Presenter,
    SymphonyElixirWeb.StaticAssetController,
    SymphonyElixirWeb.StaticAssets,
    SymphonyElixirWeb.Router,
    SymphonyElixirWeb.Router.Helpers,
    Mix.Tasks.Studio.Capabilities,
    Mix.Tasks.Studio.LinearCapabilities
  ]

  @preview_structural_modules [
    SymphonyElixir.Application,
    SymphonyElixir.Studio.LinearWriteBroker.Fake,
    SymphonyElixirWeb.PreviewVerificationController,
    Mix.Tasks.Studio.IntentMcp
  ]

  @registered_evidence %{
    SymphonyElixir.Application => [
      {SymphonyElixir.CoreTest,
       [
         "duplicate application start releases its runtime lease and supervised stop state"
       ]},
      {SymphonyElixir.NetworkHermeticityTest,
       [
         "erlexec startup supplies the fixed fallback for missing or blank SHELL",
         "erlexec startup preserves an operator-provided nonblank SHELL"
       ]}
    ],
    SymphonyElixir.Studio.LinearWriteBroker.Fake => [
      {SymphonyElixir.Studio.IntentServiceTest,
       [
         "runs clarification, digest-bound publication, first-ready transition, and actual admission",
         "surfaces uncertain publication and resumes only by exact reconciliation",
         "preserves confirmed mappings when a later publication action is blocked"
       ]}
    ],
    SymphonyElixirWeb.PreviewVerificationController => [
      {SymphonyElixirWeb.PreviewVerificationControllerTest,
       [
         "GET exposes only the bounded read-only verification projection",
         "non-GET methods remain disabled"
       ]}
    ],
    Mix.Tasks.Studio.IntentMcp => [
      {Mix.Tasks.Studio.IntentMcpTest,
       [
         "prints owner-local usage without starting the protocol server",
         "rejects unknown arguments and relative data roots",
         "runs the protocol-clean server to EOF with an absolute owner-local root"
       ]}
    ]
  }

  test "keeps the 100 percent threshold and the structural inventory closed" do
    coverage = Mix.Project.config() |> Keyword.fetch!(:test_coverage)
    ignored = Keyword.fetch!(coverage, :ignore_modules)

    assert coverage |> Keyword.fetch!(:summary) |> Keyword.fetch!(:threshold) == 100
    assert ignored == @baseline_structural_modules ++ @preview_structural_modules
    assert length(ignored) == length(Enum.uniq(ignored))
    assert Enum.all?(ignored, &is_atom/1)
  end

  test "binds every preview structural classification to exact registered ExUnit evidence" do
    assert MapSet.new(Map.keys(@registered_evidence)) == MapSet.new(@preview_structural_modules)

    Enum.each(@registered_evidence, fn {module, registrations} ->
      assert Code.ensure_loaded?(module), "expected #{inspect(module)} to be loadable"
      assert registrations != [], "expected registered evidence for #{inspect(module)}"

      Enum.each(registrations, fn {test_module, exact_names} ->
        assert Code.ensure_loaded?(test_module),
               "expected #{inspect(test_module)} to be loaded by the selected ExUnit suite"

        assert function_exported?(test_module, :__ex_unit__, 0),
               "expected #{inspect(test_module)} to be registered by ExUnit"

        registered_tests = test_module.__ex_unit__().tests

        Enum.each(exact_names, fn exact_name ->
          test_name = "test " <> exact_name

          assert [registered] = Enum.filter(registered_tests, &(Atom.to_string(&1.name) == test_name))
          assert registered.case == test_module
          assert registered.module == test_module
          assert registered.tags.test_type == :test
        end)
      end)
    end)
  end
end
