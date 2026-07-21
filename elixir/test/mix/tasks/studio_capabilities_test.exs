# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.CapabilitiesTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Studio.Capabilities
  alias SymphonyElixir.Codex.RequestPolicy
  alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

  @prefix "SYMPHONY_STUDIO_CAPABILITIES_JSON="

  test "prints one redacted final record with the exact successful no-model request receipts" do
    assert Mix.Task.requirements(Capabilities) == ["app.config --no-compile"]

    previous_state_home = System.get_env("XDG_STATE_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "studio-capabilities-success-#{System.unique_integer([:positive, :monotonic])}"
      )

    cwd = Path.join(root, "repository")
    state_home = Path.join(root, "private-state")
    workflow = SymphonyElixir.Workflow.workflow_file_path()
    missing_workflow = Path.join(root, "missing-WORKFLOW.md")
    File.mkdir_p!(cwd)
    System.put_env("XDG_STATE_HOME", state_home)
    Application.put_env(:symphony_elixir, :workflow_file_path, missing_workflow)

    on_exit(fn ->
      restore_env("XDG_STATE_HOME", previous_state_home)
      SymphonyElixir.Workflow.set_workflow_file_path(workflow)
      File.rm_rf!(root)
    end)

    fixture = FakeCodex.create!(root, successful_probe_steps())
    codex_bin = write_launcher!(root, fixture.command)

    output =
      capture_io(fn ->
        assert :ok =
                 Capabilities.run_sealed([
                   "--format",
                   "json",
                   "--codex-bin",
                   codex_bin,
                   "--cwd",
                   cwd,
                   "--workflow",
                   workflow
                 ])
      end)

    assert Application.fetch_env!(:symphony_elixir, :workflow_file_path) == missing_workflow

    assert [record] = String.split(output, "\n", trim: true)
    assert String.starts_with?(record, @prefix <> ~s({"capabilityReport":))

    report = record |> String.replace_prefix(@prefix, "") |> Jason.decode!()
    assert report["reportVersion"] == 1
    assert report["capabilityReport"]["noModelWork"]
    assert report["capabilityReport"]["account"]["authMode"] == "chatgpt"

    receipts = report["requestReceipts"]

    expected_requests = [
      {"initialize", initialize_params(), "handshake", "object", "pass"},
      {"account/read", %{}, "idempotent", "object", "pass"},
      {"account/rateLimits/read", :omitted, "idempotent", "omitted", "pass"},
      {"model/list", %{"includeHidden" => true, "limit" => 100}, "idempotent", "object", "pass"},
      {"model/list", %{"cursor" => "opaque-next", "includeHidden" => true, "limit" => 100}, "idempotent", "object", "pass"},
      {"account/usage/read", :omitted, "idempotent", "omitted", "pass"},
      {"experimentalFeature/list", %{"limit" => 100}, "idempotent", "object", "pass"},
      {"collaborationMode/list", %{}, "idempotent", "object", "unsupported"},
      {"account/read", %{}, "idempotent", "object", "pass"}
    ]

    assert length(receipts) == 9

    for {{method, params, classification, params_shape, outcome}, receipt, sequence} <-
          Enum.zip([expected_requests, receipts, 1..9]) do
      assert receipt == %{
               "attempt" => 1,
               "classification" => classification,
               "method" => method,
               "outcome" => outcome,
               "paramsShape" => params_shape,
               "requestHash" => RequestPolicy.canonical_hash(method, params),
               "sequence" => sequence
             }
    end

    received = FakeCodex.received!(fixture)

    assert Enum.map(received, & &1["method"]) == [
             "initialize",
             "initialized",
             "account/read",
             "account/rateLimits/read",
             "model/list",
             "model/list",
             "account/usage/read",
             "experimentalFeature/list",
             "collaborationMode/list",
             "account/read"
           ]

    refute Enum.any?(received, fn payload ->
             payload["method"] in [
               "account/rateLimitResetCredit/consume",
               "review/start",
               "thread/start",
               "turn/start"
             ]
           end)

    refute output =~ "task-private-canary"
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "runs the compiled sealed entry directly from an empty non-project directory" do
    root =
      Path.join(
        System.tmp_dir!(),
        "studio-capabilities-direct-#{System.unique_integer([:positive, :monotonic])}"
      )

    runtime_root = Path.join(root, "runtime")
    repository = Path.join(root, "repository")
    workflow = SymphonyElixir.Workflow.workflow_file_path()

    for directory <- [
          runtime_root,
          repository,
          Path.join(root, "codex-home"),
          Path.join(root, "home"),
          Path.join(root, "tmp"),
          Path.join(root, "xdg-cache"),
          Path.join(root, "xdg-config"),
          Path.join(root, "xdg-data"),
          Path.join(root, "xdg-state")
        ] do
      File.mkdir_p!(directory)
      File.chmod!(directory, 0o700)
    end

    on_exit(fn -> File.rm_rf!(root) end)

    fixture = FakeCodex.create!(root, successful_probe_steps())
    codex_bin = write_launcher!(root, fixture.command)
    elixir = System.find_executable("elixir") || flunk("pinned Elixir runner unavailable")
    erlang_root = :code.root_dir() |> List.to_string() |> Path.expand()
    erl = Path.join(erlang_root, "bin/erl")

    assert Path.type(elixir) == :absolute
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(elixir)
    assert {:ok, %File.Stat{type: :regular}} = File.lstat(erl)
    assert File.ls!(runtime_root) == []

    code_paths =
      Mix.Project.build_path()
      |> Path.expand()
      |> Path.join("lib/*/ebin")
      |> Path.wildcard()
      |> Enum.sort()

    assert Enum.any?(code_paths, &String.ends_with?(&1, "/symphony_elixir/ebin"))
    assert Enum.any?(code_paths, &String.ends_with?(&1, "/erlexec/ebin"))

    arguments =
      Enum.flat_map(code_paths, &["-pa", &1]) ++
        [
          "-e",
          "Mix.Tasks.Studio.Capabilities.run_sealed(System.argv())",
          "--",
          "--format",
          "json",
          "--codex-bin",
          codex_bin,
          "--cwd",
          repository,
          "--workflow",
          workflow
        ]

    safe_environment = %{
      "CODEX_HOME" => Path.join(root, "codex-home"),
      "ERL_CRASH_DUMP" => Path.join(root, "erl_crash.dump"),
      "ERL_ROOTDIR" => erlang_root,
      "HOME" => Path.join(root, "home"),
      "LANG" => "C.UTF-8",
      "LC_ALL" => "C.UTF-8",
      "NO_COLOR" => "1",
      "PATH" => "#{Path.join(erlang_root, "bin")}:/usr/bin:/bin",
      "SHELL" => "/bin/sh",
      "TMPDIR" => Path.join(root, "tmp"),
      "TZ" => "UTC",
      "XDG_CACHE_HOME" => Path.join(root, "xdg-cache"),
      "XDG_CONFIG_HOME" => Path.join(root, "xdg-config"),
      "XDG_DATA_HOME" => Path.join(root, "xdg-data"),
      "XDG_STATE_HOME" => Path.join(root, "xdg-state")
    }

    cleared_environment =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(safe_environment, &1))
      |> Enum.map(&{&1, nil})

    environment = cleared_environment ++ Enum.to_list(safe_environment)

    assert {output, 0} =
             System.cmd(elixir, arguments,
               cd: runtime_root,
               env: environment,
               stderr_to_stdout: true
             )

    assert [record] = String.split(output, "\n", trim: true)
    assert String.starts_with?(record, @prefix <> ~s({"capabilityReport":))
    assert File.ls!(runtime_root) == []

    report = record |> String.replace_prefix(@prefix, "") |> Jason.decode!()
    assert report["capabilityReport"]["noModelWork"]
    assert length(report["requestReceipts"]) == 9
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "documents the exact no-model JSON collection contract" do
    output = capture_io(fn -> assert :ok = Capabilities.run(["--help"]) end)
    sealed_output = capture_io(fn -> assert :ok = Capabilities.run_sealed(["--help"]) end)

    assert sealed_output == output
    assert output =~ "--format json"
    assert output =~ "--codex-bin /absolute/path/to/codex"
    assert output =~ "--workflow /absolute/path/to/checkout/elixir/WORKFLOW.md"
    assert output =~ "SYMPHONY_STUDIO_CAPABILITIES_JSON="
    assert output =~ "never starts"
    refute output =~ "turn/start"
  end

  test "rejects incomplete, non-JSON, positional, and relative collection inputs" do
    assert_raise Mix.Error, ~r/missing --workflow/, fn ->
      Capabilities.run_sealed([
        "--format",
        "json",
        "--codex-bin",
        System.find_executable("true"),
        "--cwd",
        File.cwd!()
      ])
    end

    assert_raise Mix.Error, ~r/missing --codex-bin/, fn ->
      Capabilities.run(["--format", "json", "--cwd", File.cwd!()])
    end

    assert_raise Mix.Error, ~r/--format must be json/, fn ->
      Capabilities.run(["--format", "yaml"])
    end

    assert_raise Mix.Error, ~r/invalid arguments/, fn ->
      Capabilities.run(["--format", "json", "unexpected"])
    end

    assert_raise Mix.Error, ~r/invalid or unsafe path/, fn ->
      Capabilities.run([
        "--format",
        "json",
        "--codex-bin",
        "relative-codex",
        "--cwd",
        File.cwd!()
      ])
    end
  end

  test "rejects a symlinked launcher even when its target is executable" do
    root =
      Path.join(
        System.tmp_dir!(),
        "studio-capabilities-task-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    target = Path.join(root, "target")
    link = Path.join(root, "codex")
    File.write!(target, "fixture")
    File.chmod!(target, 0o700)
    File.ln_s!(target, link)
    on_exit(fn -> File.rm_rf!(root) end)

    assert_raise Mix.Error, ~r/invalid or unsafe path/, fn ->
      Capabilities.run([
        "--format",
        "json",
        "--codex-bin",
        link,
        "--cwd",
        File.cwd!()
      ])
    end
  end

  defp successful_probe_steps do
    [
      FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset),
      FakeCodex.response(1, FakeCodex.initialize_response(user_agent: "task-private-canary/0.144.3")),
      FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
      FakeCodex.expect(%{"id" => 2, "method" => "account/read", "params" => %{}}),
      FakeCodex.response_for(2, "account/read", chatgpt_account()),
      FakeCodex.expect(
        %{"id" => 3, "method" => "account/rateLimits/read"},
        absent: [["params"]]
      ),
      FakeCodex.response_for(3, "account/rateLimits/read", quota_response()),
      FakeCodex.expect(%{
        "id" => 4,
        "method" => "model/list",
        "params" => %{"includeHidden" => true, "limit" => 100}
      }),
      FakeCodex.response_for(4, "model/list", %{
        "data" => [model("gpt-5.6-sol", ~w(high ultra))],
        "nextCursor" => "opaque-next"
      }),
      FakeCodex.expect(%{
        "id" => 5,
        "method" => "model/list",
        "params" => %{
          "cursor" => "opaque-next",
          "includeHidden" => true,
          "limit" => 100
        }
      }),
      FakeCodex.response_for(5, "model/list", %{
        "data" => [model("gpt-5.6-terra", ~w(medium high))],
        "nextCursor" => nil
      }),
      FakeCodex.expect(%{"id" => 6, "method" => "account/usage/read"},
        absent: [["params"]]
      ),
      FakeCodex.response_for(6, "account/usage/read", %{
        "summary" => %{},
        "dailyUsageBuckets" => nil
      }),
      FakeCodex.expect(%{
        "id" => 7,
        "method" => "experimentalFeature/list",
        "params" => %{"limit" => 100}
      }),
      FakeCodex.response_for(7, "experimentalFeature/list", %{
        "data" => [
          %{
            "defaultEnabled" => true,
            "enabled" => true,
            "name" => "multi_agent",
            "stage" => "stable"
          },
          %{
            "defaultEnabled" => false,
            "enabled" => false,
            "name" => "multi_agent_v2",
            "stage" => "underDevelopment"
          }
        ],
        "nextCursor" => nil
      }),
      FakeCodex.expect(%{"id" => 8, "method" => "collaborationMode/list", "params" => %{}}),
      FakeCodex.response_error(8, -32_601, "method unavailable: task-private-canary"),
      FakeCodex.expect(%{"id" => 9, "method" => "account/read", "params" => %{}}),
      FakeCodex.response_for(9, "account/read", chatgpt_account()),
      FakeCodex.exit(0)
    ]
  end

  defp initialize_params do
    %{
      "capabilities" => %{"experimentalApi" => true},
      "clientInfo" => %{
        "name" => "symphony-orchestrator",
        "title" => "Symphony Orchestrator",
        "version" => "0.1.0"
      }
    }
  end

  defp chatgpt_account do
    %{
      "account" => %{
        "email" => "task-private-canary@example.invalid",
        "planType" => "pro",
        "type" => "chatgpt"
      },
      "requiresOpenaiAuth" => true
    }
  end

  defp quota_response do
    %{
      "rateLimits" => %{},
      "rateLimitsByLimitId" => %{
        "task-private-canary-limit" => %{
          "credits" => %{
            "balance" => "task-private-canary-balance",
            "hasCredits" => true,
            "unlimited" => false
          },
          "limitId" => "task-private-canary-limit",
          "primary" => %{"usedPercent" => 42}
        }
      }
    }
  end

  defp model(slug, efforts) do
    %{
      "defaultReasoningEffort" => hd(efforts),
      "description" => "Fixture model",
      "displayName" => slug,
      "hidden" => false,
      "id" => slug,
      "isDefault" => slug == "gpt-5.6-sol",
      "model" => slug,
      "supportedReasoningEfforts" => Enum.map(efforts, &%{"description" => "Fixture effort", "reasoningEffort" => &1})
    }
  end

  defp write_launcher!(root, command) do
    launcher = Path.join(root, "codex")
    File.write!(launcher, "#!/bin/sh\nexec #{command}\n")
    File.chmod!(launcher, 0o700)
    launcher
  end
end
