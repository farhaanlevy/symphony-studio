# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.MCPServerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Studio.Intent.MCPServer
  alias SymphonyElixir.Studio.LinearWriteBroker.Linear

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    project_root = Path.join(System.tmp_dir!(), "intent-mcp-project-#{unique}")
    data_root = Path.join(System.tmp_dir!(), "intent-mcp-data-#{unique}")
    File.mkdir_p!(project_root)
    File.write!(Path.join(project_root, "README.md"), "# MCP fixture\n")

    on_exit(fn ->
      File.rm_rf(project_root)
      File.rm_rf(data_root)
    end)

    %{data_root: data_root, project_root: project_root}
  end

  test "negotiates MCP lifecycle and lists exactly the eight intent tools", ctx do
    responses =
      MCPServer.exchange_for_test(
        [
          %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "method" => "initialize",
            "params" => %{
              "capabilities" => %{},
              "clientInfo" => %{"name" => "test", "version" => "1"},
              "protocolVersion" => "2025-11-25"
            }
          },
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list", "params" => %{}}
        ],
        data_root: ctx.data_root
      )

    assert [initialize, listed] = responses
    assert initialize["result"]["protocolVersion"] == "2025-11-25"
    assert initialize["result"]["capabilities"] == %{"tools" => %{"listChanged" => false}}
    assert String.contains?(initialize["result"]["instructions"], "publish_linear_backlog")

    tools = listed["result"]["tools"]
    assert length(tools) == 8

    assert Enum.map(tools, & &1["name"]) == [
             "studio_attach_project",
             "studio_submit_intent",
             "studio_answer_clarifications",
             "studio_present_proposal",
             "studio_approve_publication",
             "studio_publish_approved_plan",
             "studio_start_first_ready",
             "studio_get_intent_status"
           ]

    publish = Enum.find(tools, &(&1["name"] == "studio_publish_approved_plan"))
    assert publish["annotations"]["idempotentHint"]
    assert publish["annotations"]["openWorldHint"]
    assert publish["annotations"]["destructiveHint"]
  end

  test "returns structured tool content and keeps exact confirmation errors model-visible", ctx do
    messages = [
      initialize_message(),
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      %{
        "jsonrpc" => "2.0",
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "studio_attach_project",
          "arguments" => %{"command_id" => "attach-mcp", "project_root" => ctx.project_root}
        }
      }
    ]

    [_initialized, attached] = MCPServer.exchange_for_test(messages, data_root: ctx.data_root)
    result = attached["result"]

    refute result["isError"]
    assert result["structuredContent"]["lifecycle_state"] == "project_attached"
    assert Jason.decode!(hd(result["content"])["text"]) == result["structuredContent"]

    project_id = result["structuredContent"]["project"]["project_id"]

    submit_messages = [
      initialize_message(),
      %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
      %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "studio_submit_intent",
          "arguments" => %{
            "command_id" => "submit-mcp",
            "project_id" => project_id,
            "source" => %{"content" => "Build the operator workflow.", "kind" => "prompt"}
          }
        }
      }
    ]

    [_initialized, submitted] =
      MCPServer.exchange_for_test(submit_messages, data_root: ctx.data_root)

    refute submitted["result"]["isError"]
    assert submitted["result"]["structuredContent"]["intent_id"] =~ ~r/^intent_/
  end

  test "rejects tool use before initialized without emitting a notification response", ctx do
    responses =
      MCPServer.exchange_for_test(
        [
          %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}},
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
        ],
        data_root: ctx.data_root
      )

    assert [response] = responses
    assert response["error"]["code"] == -32_600
  end

  test "rejects unknown tools and malformed tool arguments at the JSON-RPC boundary", ctx do
    responses =
      MCPServer.exchange_for_test(
        [
          initialize_message(),
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          %{
            "jsonrpc" => "2.0",
            "id" => 2,
            "method" => "tools/call",
            "params" => %{"name" => "studio_not_a_tool", "arguments" => %{}}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => 3,
            "method" => "tools/call",
            "params" => %{"name" => "studio_attach_project", "arguments" => "invalid"}
          },
          %{
            "jsonrpc" => "2.0",
            "id" => 4,
            "method" => "tools/call",
            "params" => %{
              "name" => "studio_attach_project",
              "arguments" => %{
                "command_id" => "attach-extra",
                "project_root" => ctx.project_root,
                "unexpected" => true
              }
            }
          }
        ],
        data_root: ctx.data_root
      )

    assert [_initialized, unknown, malformed, extra] = responses
    assert unknown["error"]["code"] == -32_602
    assert malformed["error"]["code"] == -32_602
    assert extra["error"]["code"] == -32_602
  end

  test "precompiled entrypoint rejects invalid CLI options without starting", ctx do
    stderr = ExUnit.CaptureIO.capture_io(:stderr, fn -> assert MCPServer.main(["--data-root", "relative"]) == 64 end)

    assert stderr =~ "--data-root must be absolute"
    refute File.exists?(ctx.data_root)
  end

  test "precompiled CLI options bind the typed production broker without starting STDIO", ctx do
    assert {:ok, opts} = MCPServer.production_options_for_test(["--data-root", ctx.data_root])

    assert opts[:data_root] == Path.expand(ctx.data_root)
    assert opts[:broker] == Linear.target()

    assert {:ok, [broker: broker]} = MCPServer.production_options_for_test([])
    assert broker == Linear.target()
  end

  defp initialize_message do
    %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "capabilities" => %{},
        "clientInfo" => %{"name" => "test", "version" => "1"},
        "protocolVersion" => "2025-11-25"
      }
    }
  end
end
