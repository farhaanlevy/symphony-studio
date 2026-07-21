# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.DepthGuardTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../priv/hooks/studio_depth_guard.exs", __DIR__)
  @blocked_reason "symphony_studio_recursive_spawn_denied\n"

  test "allows only a root spawn event with no top-level subagent identity" do
    root_event = %{
      "hook_event_name" => "PreToolUse",
      "tool_input" => %{"agent_type" => "nested text is not identity"},
      "tool_name" => "collaborationspawn_agent",
      "tool_use_id" => "root-spawn"
    }

    assert {"", 0} = run_guard(Jason.encode!(root_event))
  end

  test "blocks a spawned child's plain or namespaced recursive spawn" do
    for tool_name <- ["spawn_agent", "collaborationspawn_agent"] do
      child_event = %{
        "agent_id" => "child-id",
        "agent_type" => "explorer",
        "hook_event_name" => "PreToolUse",
        "tool_input" => %{"message" => "nested work"},
        "tool_name" => tool_name,
        "tool_use_id" => "child-spawn"
      }

      assert {@blocked_reason, 2} = run_guard(Jason.encode!(child_event))
    end
  end

  test "fails closed for malformed, unrelated, and oversized hook input" do
    unrelated = %{
      "hook_event_name" => "PreToolUse",
      "tool_input" => %{},
      "tool_name" => "exec_command"
    }

    for input <- [
          "not-json",
          Jason.encode!(%{"tool_name" => "collaborationspawn_agent"}),
          Jason.encode!(unrelated),
          String.duplicate("x", 65_537)
        ] do
      assert {@blocked_reason, 2} = run_guard(input)
    end
  end

  defp run_guard(input) do
    elixir = System.find_executable("elixir") || flunk("elixir executable not found")
    shell = System.find_executable("sh") || flunk("sh executable not found")

    input_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-depth-guard-#{System.unique_integer([:positive, :monotonic])}.json"
      )

    File.write!(input_path, input, [:binary, :exclusive])

    try do
      System.cmd(
        shell,
        ["-c", ~S[exec "$1" "$2" < "$3"], "depth-guard", elixir, @script, input_path],
        stderr_to_stdout: true
      )
    after
      File.rm(input_path)
    end
  end
end
