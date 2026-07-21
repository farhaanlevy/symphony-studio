# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.CodexV2CapHookConformanceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.{AppServer, Connection}
  alias SymphonyElixir.TestSupport.FakeResponses

  @codex_version "codex-cli 0.144.3"
  @cap_error "collab spawn failed: agent thread limit reached"
  @depth_guard_error "Tool call blocked by PreToolUse hook: " <>
                       "symphony_studio_recursive_spawn_denied. Tool: " <>
                       "collaborationspawn_agent"
  @request_timeout_ms 10_000
  @turn_timeout_ms 20_000

  test "installed pinned App Server completes a zero-token loopback Sol Ultra turn" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    response_id = "resp-root-smoke"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "root-smoke",
               %{
                 input_values: ["symphony-r006-root-smoke"],
                 model: "gpt-5.6-sol",
                 stage: 1
               },
               {:sse,
                [
                  FakeResponses.response_created(response_id),
                  FakeResponses.assistant_message("msg-root-smoke", "done"),
                  FakeResponses.completed(response_id)
                ]}
             )

    runtime = start_runtime!(fixture, raw_cap: 1)

    assert {:ok, %{"thread" => %{"id" => thread_id}}, _metadata} =
             Connection.request(
               runtime.connection,
               "thread/start",
               thread_start_params(runtime.workspace, 1),
               @request_timeout_ms
             )

    assert {:ok, %{"turn" => %{"id" => turn_id}}, _metadata} =
             Connection.request(
               runtime.connection,
               "turn/start",
               turn_start_params(thread_id, "symphony-r006-root-smoke"),
               @request_timeout_ms
             )

    assert {:ok, terminal} = await_turn_terminal(runtime.connection, thread_id, turn_id)
    assert terminal["method"] == "turn/completed"
    assert terminal["params"]["turn"]["status"] == "completed"
    assert :ok = Connection.ack_terminal(runtime.connection, "turn/completed")

    assert [request] = FakeResponses.requests(fixture)
    assert request.label == "root-smoke"
    assert request.model == "gpt-5.6-sol"
    assert request.transport == :loopback
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "raw V2 cap one counts the root and admits zero non-root children" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    call_id = "call-r006-cap-one"
    root_prompt = "symphony-r006-cap-one-root"
    child_prompt = "symphony-r006-cap-one-child-must-not-start"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-one-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-cap-one-root"),
                  spawn_call(call_id, child_prompt, "cap_one_child"),
                  FakeResponses.completed("resp-cap-one-root")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-one-root-followup",
               %{
                 input_values: [call_id, @cap_error],
                 model: "gpt-5.6-sol",
                 stage: 2
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-cap-one", "capacity observed"),
                  FakeResponses.completed("resp-cap-one-followup")
                ]}
             )

    runtime = start_runtime!(fixture, raw_cap: 1)
    assert {:ok, terminal, observed_messages} = run_turn(runtime, 1, root_prompt)
    assert terminal["method"] == "turn/completed"
    assert terminal["params"]["turn"]["status"] == "completed"

    assert Enum.map(FakeResponses.requests(fixture), & &1.label) == [
             "cap-one-root",
             "cap-one-root-followup"
           ]

    refute Enum.any?(FakeResponses.requests(fixture), &(&1.model == "gpt-5.6-terra"))
    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 1)
    assert :ok = assert_request_quiescence(fixture, 2)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "raw V2 cap two admits one active non-root child and rejects the second" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    call_one = "call-r006-cap-two-one"
    call_two = "call-r006-cap-two-two"
    root_prompt = "symphony-r006-cap-two-root"
    child_prompt = "symphony-r006-cap-two-held-child"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-two-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-cap-two-root"),
                  spawn_call(call_one, child_prompt, "cap_two_child_one"),
                  spawn_call(call_two, child_prompt, "cap_two_child_two"),
                  FakeResponses.completed("resp-cap-two-root")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-two-active-child",
               %{input_values: [child_prompt], model: "gpt-5.6-terra", stage: 2},
               {:hold, "resp-cap-two-child", [FakeResponses.response_created("resp-cap-two-child")]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-two-root-followup",
               %{
                 input_values: [call_one, call_two, @cap_error],
                 model: "gpt-5.6-sol",
                 stage: 2
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-cap-two", "capacity observed"),
                  FakeResponses.completed("resp-cap-two-followup")
                ]}
             )

    runtime = start_runtime!(fixture, raw_cap: 2)
    assert {:ok, terminal, observed_messages} = run_turn(runtime, 2, root_prompt)
    assert terminal["method"] == "turn/completed"

    assert wait_until(fn ->
             FakeResponses.held_labels(fixture) == ["cap-two-active-child"]
           end) == :ok,
           "child hold missing; receipts=#{inspect(FakeResponses.requests(fixture))}"

    receipts = FakeResponses.requests(fixture)
    assert length(Enum.filter(receipts, &(&1.model == "gpt-5.6-terra"))) == 1
    refute Enum.any?(receipts, &(&1.label == :unexpected))

    assert MapSet.new(Enum.map(receipts, & &1.label)) ==
             MapSet.new(["cap-two-root", "cap-two-active-child", "cap-two-root-followup"])

    assert :ok = FakeResponses.release_all(fixture)
    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 2)
    assert :ok = assert_request_quiescence(fixture, 3)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "raw V2 cap three admits two active non-root children and rejects the third" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    call_ids = [
      "call-r006-cap-three-one",
      "call-r006-cap-three-two",
      "call-r006-cap-three-three"
    ]

    root_prompt = "symphony-r006-cap-three-root"
    child_prompt = "symphony-r006-cap-three-held-child"

    root_events =
      [FakeResponses.response_created("resp-cap-three-root")] ++
        Enum.map(Enum.with_index(call_ids, 1), fn {call_id, index} ->
          spawn_call(call_id, child_prompt, "cap_three_child_#{index}")
        end) ++ [FakeResponses.completed("resp-cap-three-root")]

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-three-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse, root_events}
             )

    for {label, response_id} <- [
          {"cap-three-active-child-one", "resp-cap-three-child-one"},
          {"cap-three-active-child-two", "resp-cap-three-child-two"}
        ] do
      assert :ok =
               FakeResponses.expect!(
                 fixture,
                 label,
                 %{input_values: [child_prompt], model: "gpt-5.6-terra", stage: 2},
                 {:hold, response_id, [FakeResponses.response_created(response_id)]}
               )
    end

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "cap-three-root-followup",
               %{input_values: call_ids ++ [@cap_error], model: "gpt-5.6-sol", stage: 2},
               {:sse,
                [
                  FakeResponses.assistant_message("msg-cap-three", "capacity observed"),
                  FakeResponses.completed("resp-cap-three-followup")
                ]}
             )

    runtime = start_runtime!(fixture, raw_cap: 3)
    assert {:ok, terminal, observed_messages} = run_turn(runtime, 3, root_prompt)
    assert terminal["method"] == "turn/completed"

    expected_holds = ["cap-three-active-child-one", "cap-three-active-child-two"]

    assert wait_until(fn -> FakeResponses.held_labels(fixture) == expected_holds end) == :ok,
           "two child holds missing; receipts=#{inspect(FakeResponses.requests(fixture))}"

    receipts = FakeResponses.requests(fixture)
    assert length(Enum.filter(receipts, &(&1.model == "gpt-5.6-terra"))) == 2
    refute Enum.any?(receipts, &(&1.label == :unexpected))

    assert MapSet.new(Enum.map(receipts, & &1.label)) ==
             MapSet.new([
               "cap-three-root",
               "cap-three-active-child-one",
               "cap-three-active-child-two",
               "cap-three-root-followup"
             ])

    assert :ok = FakeResponses.release_all(fixture)

    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 3)
    assert :ok = assert_request_quiescence(fixture, 4)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "native V2 ignores configured max depth and permits a depth-two grandchild" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    root_call = "call-r006-depth-root-child"
    nested_call = "call-r006-depth-grandchild"
    root_prompt = "symphony-r006-depth-root"
    child_prompt = "symphony-r006-depth-child"
    grandchild_prompt = "symphony-r006-depth-grandchild"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "depth-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-depth-root"),
                  spawn_call(root_call, child_prompt, "depth_child"),
                  FakeResponses.completed("resp-depth-root")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "depth-child",
               %{input_values: [child_prompt], model: "gpt-5.6-terra", stage: 2},
               {:sse,
                [
                  FakeResponses.response_created("resp-depth-child"),
                  spawn_call(nested_call, grandchild_prompt, "depth_grandchild"),
                  FakeResponses.completed("resp-depth-child")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "depth-root-followup",
               %{
                 input_excludes: [@cap_error],
                 input_values: [root_call],
                 model: "gpt-5.6-sol",
                 stage: 2
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-depth-root", "root complete"),
                  FakeResponses.completed("resp-depth-root-followup")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "depth-grandchild",
               %{input_values: [grandchild_prompt], model: "gpt-5.6-terra", stage: 3},
               {:sse,
                [
                  FakeResponses.response_created("resp-depth-grandchild"),
                  FakeResponses.assistant_message("msg-depth-grandchild", "grandchild complete"),
                  FakeResponses.completed("resp-depth-grandchild")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "depth-child-followup",
               %{
                 input_excludes: [@cap_error],
                 input_values: [nested_call],
                 model: "gpt-5.6-terra",
                 stage: 3
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-depth-child", "child complete"),
                  FakeResponses.completed("resp-depth-child-followup")
                ]}
             )

    runtime = start_runtime!(fixture, raw_cap: 3)
    assert {:ok, terminal, observed_messages} = run_turn(runtime, 3, root_prompt)
    assert terminal["method"] == "turn/completed"

    assert wait_until(fn -> length(FakeResponses.requests(fixture)) == 5 end) == :ok,
           "grandchild flow missing; receipts=#{inspect(FakeResponses.requests(fixture))}"

    receipts = FakeResponses.requests(fixture)
    assert Enum.count(receipts, &(&1.model == "gpt-5.6-terra")) == 3
    assert Enum.any?(receipts, &(&1.label == "depth-grandchild"))
    refute Enum.any?(receipts, &(&1.label == :unexpected))
    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 3)
    assert :ok = assert_request_quiescence(fixture, 5)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "trusted Studio depth guard permits the root and blocks a child's recursive spawn" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    root_call = "call-r006-guard-root-child"
    nested_call = "call-r006-guard-recursive-child"
    root_prompt = "symphony-r006-guard-root"
    child_prompt = "symphony-r006-guard-child"
    forbidden_grandchild_prompt = "symphony-r006-guard-grandchild-must-not-start"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "guard-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-guard-root"),
                  spawn_call(root_call, child_prompt, "guard_child"),
                  FakeResponses.completed("resp-guard-root")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "guard-child",
               %{input_values: [child_prompt], model: "gpt-5.6-terra", stage: 2},
               {:sse,
                [
                  FakeResponses.response_created("resp-guard-child"),
                  spawn_call(nested_call, forbidden_grandchild_prompt, "guard_grandchild"),
                  FakeResponses.completed("resp-guard-child")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "guard-root-followup",
               %{
                 input_excludes: [@cap_error],
                 input_values: [root_call],
                 model: "gpt-5.6-sol",
                 stage: 2
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-guard-root", "root complete"),
                  FakeResponses.completed("resp-guard-root-followup")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "guard-child-followup",
               %{
                 input_values: [nested_call, @depth_guard_error],
                 model: "gpt-5.6-terra",
                 stage: 3
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-guard-child", "guard observed"),
                  FakeResponses.completed("resp-guard-child-followup")
                ]}
             )

    guard_command = depth_guard_command()
    runtime = start_runtime!(fixture, raw_cap: 3, hook_command: guard_command)
    trusted_hook = trust_hook!(runtime, guard_command)
    assert trusted_hook["matcher"] == "collaborationspawn_agent"

    assert {:ok, terminal, observed_messages} = run_turn(runtime, 3, root_prompt)
    assert terminal["method"] == "turn/completed"

    assert wait_until(fn -> length(FakeResponses.requests(fixture)) == 4 end) == :ok,
           "guarded child flow missing; receipts=#{inspect(FakeResponses.requests(fixture))} " <>
             "hooks=#{inspect(hook_receipts(observed_messages ++ queued_payloads(runtime.connection)))}"

    receipts = FakeResponses.requests(fixture)

    assert Enum.count(receipts, &(&1.model == "gpt-5.6-terra")) == 2,
           "recursive request observed; " <>
             "hooks=#{inspect(hook_receipts(observed_messages ++ queued_payloads(runtime.connection)))}"

    refute Enum.any?(receipts, &(&1.label == :unexpected))
    refute Enum.any?(receipts, &(&1.label == "guard-grandchild"))

    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 2)

    assert assert_request_quiescence(fixture, 4) == :ok,
           "recursive request arrived after the guard result; " <>
             "hooks=#{inspect(hook_receipts(observed_messages ++ queued_payloads(runtime.connection)))}"

    hook_evidence = hook_receipts(observed_messages ++ queued_payloads(runtime.connection))
    root_thread_id = terminal["params"]["threadId"]
    assert Enum.any?(hook_evidence, &(&1.status == "completed" and &1.thread_id == root_thread_id))

    assert Enum.any?(hook_evidence, fn evidence ->
             evidence.status == "blocked" and evidence.thread_id != root_thread_id and
               %{
                 "kind" => "feedback",
                 "text" => "symphony_studio_recursive_spawn_denied"
               } in evidence.entries
           end)

    assert :ok = FakeResponses.verify!(fixture)
  end

  test "trusted hook execution failure is fail-open and permits the depth-two grandchild" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    root_call = "call-r006-fail-open-root-child"
    nested_call = "call-r006-fail-open-grandchild"
    root_prompt = "symphony-r006-fail-open-root"
    child_prompt = "symphony-r006-fail-open-child"
    grandchild_prompt = "symphony-r006-fail-open-grandchild"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "fail-open-root",
               %{input_values: [root_prompt], model: "gpt-5.6-sol", stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-fail-open-root"),
                  spawn_call(root_call, child_prompt, "fail_open_child"),
                  FakeResponses.completed("resp-fail-open-root")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "fail-open-child",
               %{input_values: [child_prompt], model: "gpt-5.6-terra", stage: 2},
               {:sse,
                [
                  FakeResponses.response_created("resp-fail-open-child"),
                  spawn_call(nested_call, grandchild_prompt, "fail_open_grandchild"),
                  FakeResponses.completed("resp-fail-open-child")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "fail-open-root-followup",
               %{
                 input_excludes: [@cap_error],
                 input_values: [root_call],
                 model: "gpt-5.6-sol",
                 stage: 2
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-fail-open-root", "root complete"),
                  FakeResponses.completed("resp-fail-open-root-followup")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "fail-open-grandchild",
               %{input_values: [grandchild_prompt], model: "gpt-5.6-terra", stage: 3},
               {:sse,
                [
                  FakeResponses.response_created("resp-fail-open-grandchild"),
                  FakeResponses.assistant_message(
                    "msg-fail-open-grandchild",
                    "grandchild complete"
                  ),
                  FakeResponses.completed("resp-fail-open-grandchild")
                ]}
             )

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "fail-open-child-followup",
               %{
                 input_excludes: [@cap_error],
                 input_values: [nested_call],
                 model: "gpt-5.6-terra",
                 stage: 3
               },
               {:sse,
                [
                  FakeResponses.assistant_message("msg-fail-open-child", "child complete"),
                  FakeResponses.completed("resp-fail-open-child-followup")
                ]}
             )

    receipt_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-r006-hook-failure-#{System.unique_integer([:positive])}.log"
      )

    on_exit(fn -> File.rm(receipt_path) end)
    failing_command = hook_failure_command(receipt_path)
    runtime = start_runtime!(fixture, raw_cap: 3, hook_command: failing_command)
    trusted_hook = trust_hook!(runtime, failing_command)
    assert trusted_hook["trustStatus"] == "trusted"

    assert {:ok, terminal, observed_messages} = run_turn(runtime, 3, root_prompt)
    assert terminal["method"] == "turn/completed"

    assert wait_until(fn -> length(FakeResponses.requests(fixture)) == 5 end) == :ok,
           "fail-open grandchild flow missing; receipts=#{inspect(FakeResponses.requests(fixture))}"

    assert :ok = await_terminal_thread_count(runtime.connection, observed_messages, 3)
    assert :ok = assert_request_quiescence(fixture, 5)
    root_thread_id = terminal["params"]["threadId"]

    assert wait_until(fn -> "child:7" in hook_failure_receipts(receipt_path) end) == :ok,
           "child hook failure receipt missing"

    hook_evidence = hook_receipts(observed_messages ++ queued_payloads(runtime.connection))
    assert "root:7" in hook_failure_receipts(receipt_path)
    assert "child:7" in hook_failure_receipts(receipt_path)
    assert Enum.any?(hook_evidence, &(&1.status == "failed" and &1.thread_id == root_thread_id))
    assert Enum.any?(hook_evidence, &(&1.status == "failed" and &1.thread_id != root_thread_id))

    refute Enum.any?(hook_evidence, &(&1.status == "blocked"))
    assert Enum.any?(FakeResponses.requests(fixture), &(&1.label == "fail-open-grandchild"))
    assert :ok = FakeResponses.verify!(fixture)
  end

  defp start_runtime!(fixture, opts) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-r006-codex-#{System.unique_integer([:positive])}"
      )

    codex_home = Path.join(root, "codex-home")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(codex_home)
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "AGENTS.md"), "# Synthetic loopback workspace\n")
    File.write!(Path.join(codex_home, "config.toml"), config_toml(fixture, opts))

    codex =
      System.get_env("SYMPHONY_CODEX_CONFORMANCE_BIN") ||
        Path.expand("~/.local/bin/codex")

    assert Path.type(codex) == :absolute, "pinned Codex executable path must be absolute"
    assert File.regular?(codex), "pinned Codex executable is missing"
    assert {version, 0} = System.cmd(codex, ["--version"], env: [], stderr_to_stdout: true)
    assert String.trim(version) == @codex_version

    env = [
      {"CODEX_HOME", codex_home},
      {"HOME", root},
      {"LANG", "C.UTF-8"},
      {"LC_ALL", "C.UTF-8"},
      {"PATH", "/usr/local/bin:/usr/bin:/bin"}
    ]

    assert {:ok, connection} =
             Connection.start([codex, "app-server"],
               cd: workspace,
               env: env,
               kill_timeout_ms: 2_000,
               max_frame_bytes: 16_777_216,
               stderr_tail_bytes: 16_384
             )

    on_exit(fn ->
      if Process.alive?(connection), do: Connection.close(connection)
      File.rm_rf(root)
    end)

    assert {:ok, %{"userAgent" => user_agent}} = AppServer.initialize_connection(connection)
    assert is_binary(user_agent)

    %{codex_home: codex_home, connection: connection, root: root, workspace: workspace}
  end

  defp config_toml(fixture, opts) do
    raw_cap = Keyword.fetch!(opts, :raw_cap)
    hook_command = Keyword.get(opts, :hook_command)

    hook_feature =
      if is_binary(hook_command) do
        """
        [features]
        hooks = true

        """
      else
        ""
      end

    hook_config =
      if is_binary(hook_command) do
        """

        [hooks]

        [[hooks.PreToolUse]]
        matcher = "collaborationspawn_agent"

        [[hooks.PreToolUse.hooks]]
        type = "command"
        command = #{Jason.encode!(hook_command)}
        timeout = 5
        """
      else
        ""
      end

    """
    model = "gpt-5.6-sol"
    model_provider = "mock_provider"
    approval_policy = "never"
    sandbox_mode = "read-only"

    #{hook_feature}
    [features.multi_agent_v2]
    enabled = true
    max_concurrent_threads_per_session = #{raw_cap}
    non_code_mode_only = false
    tool_namespace = "collaboration"

    [model_providers.mock_provider]
    name = "Symphony loopback conformance"
    base_url = "#{fixture.base_url}"
    wire_api = "responses"
    request_max_retries = 0
    stream_max_retries = 0
    supports_websockets = false
    #{hook_config}
    """
  end

  defp thread_start_params(workspace, raw_cap) do
    %{
      "approvalPolicy" => "never",
      "config" => %{
        "agents.max_depth" => 1,
        "features.multi_agent_v2.enabled" => true,
        "features.multi_agent_v2.max_concurrent_threads_per_session" => raw_cap,
        "features.multi_agent_v2.non_code_mode_only" => false,
        "features.multi_agent_v2.tool_namespace" => "collaboration"
      },
      "cwd" => workspace,
      "model" => "gpt-5.6-sol",
      "modelProvider" => "mock_provider",
      "sandbox" => "read-only"
    }
  end

  defp turn_start_params(thread_id, prompt) do
    %{
      "effort" => "ultra",
      "input" => [%{"text" => prompt, "type" => "text"}],
      "threadId" => thread_id
    }
  end

  defp run_turn(runtime, raw_cap, prompt) do
    with {:ok, %{"thread" => %{"id" => thread_id}}, _metadata} <-
           Connection.request(
             runtime.connection,
             "thread/start",
             thread_start_params(runtime.workspace, raw_cap),
             @request_timeout_ms
           ),
         {:ok, %{"turn" => %{"id" => turn_id}}, _metadata} <-
           Connection.request(
             runtime.connection,
             "turn/start",
             turn_start_params(thread_id, prompt),
             @request_timeout_ms
           ),
         {:ok, terminal, messages} <-
           await_turn_terminal_with_messages(runtime.connection, thread_id, turn_id),
         :ok <- Connection.ack_terminal(runtime.connection, terminal["method"]) do
      {:ok, terminal, messages}
    end
  end

  defp spawn_call(call_id, message, task_name) do
    FakeResponses.function_call(call_id, "collaboration", "spawn_agent", %{
      "fork_turns" => "none",
      "message" => message,
      "model" => "gpt-5.6-terra",
      "task_name" => task_name
    })
  end

  defp depth_guard_command do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")

    script =
      Path.expand(
        "../../priv/hooks/studio_depth_guard.exs",
        __DIR__
      )

    hook_runtime_path() <> shell_quote(elixir) <> " " <> shell_quote(script)
  end

  defp hook_failure_command(receipt_path) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    script = Path.expand("../support/codex_hook_fail_open_fixture.exs", __DIR__)

    hook_runtime_path() <>
      shell_quote(elixir) <> " " <> shell_quote(script) <> " " <> shell_quote(receipt_path)
  end

  defp hook_runtime_path do
    "PATH=" <> shell_quote(System.fetch_env!("PATH")) <> " "
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp hook_failure_receipts(path) do
    case File.read(path) do
      {:ok, contents} -> String.split(contents, "\n", trim: true)
      {:error, :enoent} -> []
      {:error, _reason} -> []
    end
  end

  defp trust_hook!(runtime, expected_command) do
    assert {:ok,
            %{
              "data" => [
                %{
                  "errors" => [],
                  "hooks" => [hook],
                  "warnings" => []
                }
              ]
            }, _metadata} =
             Connection.request(
               runtime.connection,
               "hooks/list",
               %{"cwds" => [runtime.workspace]},
               @request_timeout_ms
             )

    assert hook["command"] == expected_command
    assert hook["enabled"]
    assert hook["matcher"] == "collaborationspawn_agent"
    assert hook["trustStatus"] == "untrusted"
    assert is_binary(hook["key"]) and hook["key"] != ""
    assert hook["currentHash"] =~ ~r/\Asha256:[0-9a-f]{64}\z/

    assert {:ok, %{}, _metadata} =
             Connection.request(
               runtime.connection,
               "config/batchWrite",
               %{
                 "edits" => [
                   %{
                     "keyPath" => "hooks.state",
                     "mergeStrategy" => "upsert",
                     "value" => %{
                       hook["key"] => %{"trusted_hash" => hook["currentHash"]}
                     }
                   }
                 ],
                 "expectedVersion" => nil,
                 "filePath" => nil,
                 "reloadUserConfig" => true
               },
               @request_timeout_ms
             )

    assert {:ok,
            %{
              "data" => [
                %{
                  "errors" => [],
                  "hooks" => [trusted_hook],
                  "warnings" => []
                }
              ]
            }, _metadata} =
             Connection.request(
               runtime.connection,
               "hooks/list",
               %{"cwds" => [runtime.workspace]},
               @request_timeout_ms
             )

    assert trusted_hook["key"] == hook["key"]
    assert trusted_hook["currentHash"] == hook["currentHash"]
    assert trusted_hook["trustStatus"] == "trusted"
    trusted_hook
  end

  defp wait_until(predicate, attempts \\ 200)

  defp wait_until(_predicate, 0), do: {:error, :timeout}

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end

  defp assert_request_quiescence(fixture, expected_count, checks \\ 50)

  defp assert_request_quiescence(fixture, expected_count, 0) do
    if length(FakeResponses.requests(fixture)) == expected_count,
      do: :ok,
      else: {:error, :unexpected_request_count}
  end

  defp assert_request_quiescence(fixture, expected_count, checks) do
    if length(FakeResponses.requests(fixture)) == expected_count do
      Process.sleep(10)
      assert_request_quiescence(fixture, expected_count, checks - 1)
    else
      {:error, :unexpected_request_count}
    end
  end

  defp await_terminal_thread_count(connection, _observed_messages, expected_count, attempts \\ 200)

  defp await_terminal_thread_count(connection, _observed_messages, expected_count, 0) do
    actual_count = completed_terminal_count(connection)

    if actual_count == expected_count,
      do: :ok,
      else: {:error, {:terminal_thread_count_timeout, expected_count, actual_count}}
  end

  defp await_terminal_thread_count(connection, observed_messages, expected_count, attempts) do
    actual_count = completed_terminal_count(connection)

    if actual_count == expected_count do
      :ok
    else
      Process.sleep(10)

      await_terminal_thread_count(
        connection,
        observed_messages,
        expected_count,
        attempts - 1
      )
    end
  end

  defp completed_terminal_count(connection) do
    connection
    |> :sys.get_state()
    |> Map.fetch!(:completed_terminal_turns)
    |> MapSet.size()
  end

  defp await_turn_terminal(connection, thread_id, turn_id) do
    with {:ok, terminal, _messages} <-
           await_turn_terminal_with_messages(connection, thread_id, turn_id) do
      {:ok, terminal}
    end
  end

  defp await_turn_terminal_with_messages(connection, thread_id, turn_id) do
    deadline = System.monotonic_time(:millisecond) + @turn_timeout_ms
    do_await_turn_terminal(connection, thread_id, turn_id, deadline, [])
  end

  defp do_await_turn_terminal(connection, thread_id, turn_id, deadline, messages) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :turn_terminal_timeout}
    else
      case Connection.next_message(connection, remaining) do
        {:ok,
         %{
           payload:
             %{
               "method" => method,
               "params" => %{"threadId" => ^thread_id, "turn" => %{"id" => ^turn_id}}
             } = payload
         }}
        when method in ["turn/completed", "turn/failed", "turn/cancelled"] ->
          {:ok, payload, Enum.reverse([payload | messages])}

        {:ok, %{payload: payload}} ->
          do_await_turn_terminal(connection, thread_id, turn_id, deadline, [payload | messages])

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp queued_payloads(connection) do
    connection
    |> :sys.get_state()
    |> Map.fetch!(:queue)
    |> :queue.to_list()
    |> Enum.map(& &1.payload)
  end

  defp hook_receipts(payloads) do
    payloads
    |> Enum.filter(&(&1["method"] == "hook/completed"))
    |> Enum.map(fn payload ->
      run = get_in(payload, ["params", "run"]) || %{}

      %{
        entries: Enum.map(run["entries"] || [], &Map.take(&1, ["kind", "text"])),
        event_name: run["eventName"],
        status: run["status"],
        thread_id: get_in(payload, ["params", "threadId"]),
        turn_id: get_in(payload, ["params", "turnId"])
      }
    end)
  end
end
