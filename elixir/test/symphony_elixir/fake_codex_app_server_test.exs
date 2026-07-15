# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.FakeCodexAppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

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
