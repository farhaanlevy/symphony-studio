# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.FakeCodexAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

  test "fixture exposes absolute direct argv and its command rendering round-trips" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fake-codex-argv-#{System.unique_integer([:positive])}"
      )

    try do
      fixture = FakeCodex.create!(test_root, [FakeCodex.exit(0)])
      [env, path_assignment, elixir | _arguments] = fixture.argv

      assert Path.type(env) == :absolute
      assert Path.type(elixir) == :absolute
      assert path_assignment == "PATH=#{System.fetch_env!("PATH")}"
      assert OptionParser.split(fixture.command) == fixture.argv
      assert {"", 0} = System.cmd(env, tl(fixture.argv), stderr_to_stdout: true)
      assert :ok = FakeCodex.assert_complete!(fixture)
    after
      File.rm_rf(test_root)
    end
  end

  test "strict fixture proves the real initialize and session ordering" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-fake-codex-integration-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "STU-2")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(thread_id: "thread-r002", turn_id: "turn-r002") ++
            [
              FakeCodex.turn_completed_notification("thread-r002", "turn-r002"),
              FakeCodex.exit(0)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command
      )

      issue = %Issue{
        id: "issue-r002",
        identifier: "STU-2",
        title: "Exercise strict fixture",
        description: "Prove exact startup ordering",
        state: "In Progress",
        url: "https://example.invalid/STU-2"
      }

      assert {:ok, result} = AppServer.run(workspace, "Run strict fixture", issue)
      assert result.thread_id == "thread-r002"
      assert result.turn_id == "turn-r002"

      received = FakeCodex.received!(fixture)

      assert Enum.map(received, & &1["method"]) == [
               "initialize",
               "initialized",
               "thread/start",
               "turn/start"
             ]

      assert Enum.map(received, &Map.get(&1, "id")) == [1, nil, 2, 3]
      assert Enum.each(received, &FakeCodex.assert_client_message_valid!/1) == :ok
      assert :ok = FakeCodex.assert_received!(fixture, %{"method" => "turn/start"})
      assert :ok = FakeCodex.assert_complete!(fixture)

      terminal_send = fixture |> FakeCodex.trace!() |> Enum.at(-3)
      assert terminal_send["kind"] == "sent_json"
      assert terminal_send["fragmentCount"] == 1
      assert terminal_send["fragments"] == []
      assert terminal_send["delayMs"] == 0
    after
      File.rm_rf(test_root)
    end
  end

  test "fixture fails a mismatched method before emitting a scripted response" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-mismatch-#{System.unique_integer([:positive])}")

    try do
      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 1, "method" => "initialize"}),
          FakeCodex.response(1, %{}),
          FakeCodex.exit(0)
        ])

      input = Jason.encode!(%{"id" => 1, "method" => "thread/start", "params" => %{}}) <> "\n"

      {_output, 64} = run_fixture(fixture, input)

      trace = FakeCodex.trace!(fixture)
      assert Enum.map(trace, & &1["kind"]) == ["received", "failure"]
      refute Enum.any?(trace, &(&1["kind"] == "sent_json"))
    after
      File.rm_rf(test_root)
    end
  end

  test "schema-invalid request terminates the scenario before a valid follow-up" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-schema-#{System.unique_integer([:positive])}")

    try do
      expected = %{
        "id" => 1,
        "method" => "initialize",
        "params" => %{"clientInfo" => %{"name" => "fixture-test", "version" => "1.0"}}
      }

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(expected),
          FakeCodex.response(1, %{"accepted" => true}),
          FakeCodex.exit(0)
        ])

      input =
        [
          Map.put(expected, "unexpected", true),
          expected
        ]
        |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

      {output, 64} = run_fixture(fixture, input)

      assert output =~ "fake-codex-app-server: invalid_client_payload"

      trace = FakeCodex.trace!(fixture)

      assert Enum.map(trace, & &1["kind"]) == [
               "received",
               "rejected",
               "failure"
             ]

      assert Enum.at(trace, 1)["reason"]["kind"] == "unexpected_fields"
      assert List.last(trace)["failureKind"] == "invalid_client_payload"
      assert List.last(trace)["status"] == 64
      assert length(FakeCodex.received!(fixture)) == 1
      refute Enum.any?(trace, &(&1["kind"] in ["sent_json", "complete"]))
    after
      File.rm_rf(test_root)
    end
  end

  test "fixture rejects an exit step that could hide unconsumed work" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-exit-#{System.unique_integer([:positive])}")

    assert_raise ArgumentError, ~r/exit step at index 0 must be the final scenario step/, fn ->
      FakeCodex.create!(test_root, [
        FakeCodex.exit(0),
        FakeCodex.expect(%{"id" => 1, "method" => "initialize"})
      ])
    end

    refute File.exists?(test_root)
  end

  test "fixture oracle rejects nested sandbox and dynamic-tool response drift" do
    assert_raise ArgumentError, ~r/violates pinned schema json\/ServerRequest.json/, fn ->
      FakeCodex.request(99, "item/fileChange/requestApproval", %{})
    end

    assert %{"payload" => %{"id" => 99}, "type" => "send_json"} =
             FakeCodex.raw_send_json(%{"id" => 99, "method" => "raw/negative"})

    assert_raise ArgumentError, ~r/violates pinned schema json\/JSONRPCResponse.json/, fn ->
      FakeCodex.response(%{"invalid" => "id"}, %{})
    end

    assert_raise ArgumentError, ~r/violates pinned schema json\/JSONRPCError.json/, fn ->
      FakeCodex.response_error(nil, -32_001, "invalid id")
    end

    assert %{"payload" => %{"id" => nil, "result" => %{}}, "type" => "send_json"} =
             FakeCodex.raw_send_json(%{"id" => nil, "result" => %{}})

    valid_turn = %{
      "id" => 3,
      "method" => "turn/start",
      "params" => %{
        "threadId" => "thread-oracle",
        "input" => [],
        "sandboxPolicy" => %{
          "type" => "workspaceWrite",
          "writableRoots" => ["/tmp/workspace"],
          "networkAccess" => false
        }
      }
    }

    assert :ok = FakeCodex.assert_client_message_valid!(valid_turn)

    invalid_turn =
      put_in(
        valid_turn,
        ["params", "sandboxPolicy", "readOnlyAccess"],
        %{"type" => "fullAccess"}
      )

    assert_raise ExUnit.AssertionError, ~r/contains unsupported fields/, fn ->
      FakeCodex.assert_client_message_valid!(invalid_turn)
    end

    valid_result = %{
      "success" => true,
      "contentItems" => [%{"type" => "inputText", "text" => "done"}]
    }

    assert :ok = FakeCodex.assert_dynamic_tool_response_valid!(valid_result)

    assert FakeCodex.no_grant_permissions_response() == %{
             "permissions" => %{},
             "scope" => "turn"
           }

    assert FakeCodex.fail_closed_callback_response("item/commandExecution/requestApproval") == %{
             "decision" => "decline"
           }

    assert FakeCodex.fail_closed_callback_response("item/fileChange/requestApproval") == %{
             "decision" => "decline"
           }

    assert FakeCodex.fail_closed_callback_response("execCommandApproval") == %{"decision" => "denied"}
    assert FakeCodex.fail_closed_callback_response("applyPatchApproval") == %{"decision" => "denied"}

    assert FakeCodex.fail_closed_callback_response("mcpServer/elicitation/request") == %{
             "action" => "decline"
           }

    assert_raise ExUnit.AssertionError, ~r/only success and contentItems/, fn ->
      FakeCodex.assert_dynamic_tool_response_valid!(Map.put(valid_result, "output", "internal"))
    end

    assert_raise ExUnit.AssertionError, ~r/contains unsupported fields/, fn ->
      FakeCodex.assert_dynamic_tool_response_valid!(%{
        valid_result
        | "contentItems" => [%{"type" => "inputText", "text" => "done", "extra" => true}]
      })
    end
  end

  test "two fixtures isolate traces and support response errors and fragmented output" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-isolation-#{System.unique_integer([:positive])}")

    try do
      first =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 7, "method" => "account/read"}),
          FakeCodex.response_error(7, -32_001, "overloaded", nil, fragments: [1, 2, :rest])
        ])

      second =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 8, "method" => "model/list"}),
          FakeCodex.response(8, %{"data" => []}, fragments: [3, :rest])
        ])

      run = fn fixture, payload ->
        run_fixture(fixture, Jason.encode!(payload) <> "\n")
      end

      first_task = Task.async(fn -> run.(first, %{"id" => 7, "method" => "account/read"}) end)
      second_task = Task.async(fn -> run.(second, %{"id" => 8, "method" => "model/list"}) end)

      {first_output, 0} = Task.await(first_task)
      {second_output, 0} = Task.await(second_task)

      assert Jason.decode!(String.trim(first_output))["error"]["code"] == -32_001
      assert Jason.decode!(String.trim(second_output))["result"]["data"] == []
      refute first.trace_path == second.trace_path
      assert :ok = FakeCodex.assert_complete!(first)
      assert :ok = FakeCodex.assert_complete!(second)
    after
      File.rm_rf(test_root)
    end
  end

  test "compact generated streams emit multi-megabyte stdout and stderr with bounded scenarios" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-generated-#{System.unique_integer([:positive])}")

    try do
      stdout = "OUT:" <> :binary.copy("ab", 700_000) <> ":END"
      raw_stderr = "fragmented-stderr"
      legacy_stderr = "legacy-stderr"
      generated_stderr = "ERR:" <> :binary.copy("z", 1_100_000) <> ":END"
      expected_output = stdout <> raw_stderr <> legacy_stderr <> generated_stderr

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.generated_stdout("ab", 700_000,
            prefix: "OUT:",
            suffix: ":END",
            fragments: [7, 1_048_577, :rest]
          ),
          FakeCodex.stderr(raw_stderr, fragments: [1, 2, :rest], delay_ms: 1),
          %{"type" => "stderr", "base64" => Base.encode64(legacy_stderr)},
          FakeCodex.generated_stderr("z", 1_100_000,
            prefix: "ERR:",
            suffix: ":END",
            fragments: [5, 1_000_000, :rest]
          ),
          FakeCodex.exit(0)
        ])

      assert File.stat!(fixture.scenario_path).size < 4_096
      assert {^expected_output, 0} = run_fixture(fixture, "fixture-input")

      trace = FakeCodex.trace!(fixture)

      assert Enum.map(trace, & &1["kind"]) == [
               "sent_stdout",
               "sent_stderr",
               "sent_stderr",
               "sent_stderr",
               "exit",
               "complete"
             ]

      [stdout_trace, raw_stderr_trace, legacy_stderr_trace, generated_stderr_trace | _terminal] = trace
      assert stdout_trace["bytes"] == byte_size(stdout)
      assert stdout_trace["fragmentCount"] == 3
      assert stdout_trace["fragments"] == [7, 1_048_577, "rest"]
      assert raw_stderr_trace["bytes"] == byte_size(raw_stderr)
      assert raw_stderr_trace["delayMs"] == 1
      assert raw_stderr_trace["fragmentCount"] == 3
      assert legacy_stderr_trace["bytes"] == byte_size(legacy_stderr)
      assert legacy_stderr_trace["delayMs"] == 0
      assert legacy_stderr_trace["fragmentCount"] == 1
      assert generated_stderr_trace["bytes"] == byte_size(generated_stderr)
      assert generated_stderr_trace["fragmentCount"] == 3
      assert :ok = FakeCodex.assert_complete!(fixture)
    after
      File.rm_rf(test_root)
    end
  end

  test "trace previews safely encode arbitrary bytes and split multibyte text" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-binary-#{System.unique_integer([:positive])}")

    try do
      arbitrary = :binary.copy(<<255>>, 300)
      split_multibyte = "x" <> :binary.copy("é", 128)
      expected_output = arbitrary <> split_multibyte
      expected_input = %{"method" => "fixture/input", "params" => %{"text" => "café"}}

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(expected_input),
          FakeCodex.generated_stdout(<<255>>, 300),
          FakeCodex.generated_stderr("é", 128, prefix: "x"),
          FakeCodex.exit(0)
        ])

      input = Jason.encode!(expected_input) <> "\n"
      assert {^expected_output, 0} = run_fixture(fixture, input)
      assert FakeCodex.received!(fixture) == [expected_input]

      for stream_trace <- fixture |> FakeCodex.trace!() |> Enum.slice(1, 2) do
        assert String.valid?(stream_trace["preview"])
        assert stream_trace["preview"] =~ "...<truncated>"
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "named barrier release waits for runner readiness without a caller sleep" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-barrier-#{System.unique_integer([:positive])}")

    try do
      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.barrier("transport-ready"),
          FakeCodex.raw_stdout("released\n"),
          FakeCodex.exit(0)
        ])

      task = Task.async(fn -> run_fixture(fixture, "fixture-input") end)
      assert :ok = FakeCodex.release!(fixture, "transport-ready")
      assert :ok = FakeCodex.release!(fixture, "transport-ready")
      assert {"released\n", 0} = Task.await(task, 10_000)

      assert Enum.map(FakeCodex.trace!(fixture), & &1["kind"]) == [
               "barrier_waiting",
               "barrier_released",
               "sent_stdout",
               "exit",
               "complete"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "named barrier records timeout and rejects a late release" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-timeout-#{System.unique_integer([:positive])}")

    try do
      fixture = FakeCodex.create!(test_root, [FakeCodex.barrier("expired", timeout_ms: 25)])

      {output, 67} = run_fixture(fixture, "fixture-input")
      assert output =~ "fake-codex-app-server: barrier_timeout"

      assert_raise ExUnit.AssertionError, ~r/barrier "expired" already timed out/, fn ->
        FakeCodex.release!(fixture, "expired", 100)
      end

      refute File.exists?(Path.join([fixture.root, "barriers", "expired.release"]))

      assert Enum.map(FakeCodex.trace!(fixture), & &1["kind"]) == [
               "barrier_waiting",
               "failure"
             ]
    after
      File.rm_rf(test_root)
    end
  end

  test "runner rejects post-create scenario field drift before emitting output" do
    test_root =
      Path.join(System.tmp_dir!(), "symphony-fake-codex-strict-#{System.unique_integer([:positive])}")

    try do
      fixture = FakeCodex.create!(test_root, [FakeCodex.raw_stdout("must-not-send")])
      scenario = fixture.scenario_path |> File.read!() |> Jason.decode!()
      [step] = scenario["steps"]
      drifted = put_in(scenario, ["steps"], [Map.put(step, "unexpected", true)])
      File.write!(fixture.scenario_path, Jason.encode!(drifted))

      {output, 64} = run_fixture(fixture, "fixture-input")
      assert output =~ "fake-codex-app-server: invalid_scenario"
      refute output =~ "must-not-send"

      assert [%{"failureKind" => "invalid_scenario", "details" => details}] =
               FakeCodex.trace!(fixture)

      assert details["kind"] == "unexpected_fields"

      nested_fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.raw_stdout("must-not-send"),
          FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset)
        ])

      nested_scenario = nested_fixture.scenario_path |> File.read!() |> Jason.decode!()
      [output_step, expect_step] = nested_scenario["steps"]

      drifted_validation = Map.put(expect_step["validation"], "unexpected", true)

      nested_drift =
        put_in(nested_scenario, ["steps"], [output_step, Map.put(expect_step, "validation", drifted_validation)])

      File.write!(nested_fixture.scenario_path, Jason.encode!(nested_drift))

      {nested_output, 64} = run_fixture(nested_fixture, "fixture-input")
      assert nested_output =~ "fake-codex-app-server: invalid_scenario"
      refute nested_output =~ "must-not-send"

      assert [%{"failureKind" => "invalid_scenario", "details" => nested_details}] =
               FakeCodex.trace!(nested_fixture)

      assert nested_details["kind"] == "invalid_validation"
    after
      File.rm_rf(test_root)
    end
  end

  defp run_fixture(fixture, input) do
    bash = System.find_executable("bash") || raise "bash executable not found"

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(bash)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [~c"-lc", String.to_charlist(fixture.command)]
        ]
      )

    true = Port.command(port, input)
    collect_fixture_output(port, "")
  end

  defp collect_fixture_output(port, output) do
    receive do
      {^port, {:data, bytes}} -> collect_fixture_output(port, output <> bytes)
      {^port, {:exit_status, status}} -> {output, status}
    after
      5_000 ->
        Port.close(port)
        flunk("fake App Server process did not exit")
    end
  end
end
