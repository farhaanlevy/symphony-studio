# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.IntentMcpTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Studio.IntentMcp, as: IntentMcpTask

  setup do
    Mix.Task.reenable("studio.intent_mcp")
    :ok
  end

  test "prints owner-local usage without starting the protocol server" do
    output = capture_io(fn -> assert :ok = IntentMcpTask.run(["--help"]) end)

    assert output =~ "local Symphony Studio Intent MCP server"
    assert output =~ "scripts/studio_intent_mcp --data-root"
  end

  test "rejects unknown arguments and relative data roots" do
    assert_raise Mix.Error, ~r/studio.intent_mcp: invalid arguments/, fn ->
      IntentMcpTask.run(["unexpected"])
    end

    assert_raise Mix.Error, ~r/--data-root must be absolute/, fn ->
      IntentMcpTask.run(["--data-root", "relative"])
    end
  end

  test "runs the protocol-clean server to EOF with an absolute owner-local root" do
    root = Path.join(System.tmp_dir!(), "intent-mcp-task-#{System.unique_integer([:positive, :monotonic])}")

    on_exit(fn -> File.rm_rf(root) end)

    output =
      capture_io("", fn ->
        assert :ok = IntentMcpTask.run(["--data-root", root])
      end)

    assert output == ""
  end
end
