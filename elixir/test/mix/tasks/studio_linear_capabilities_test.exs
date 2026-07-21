# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.LinearCapabilitiesTest do
  use SymphonyElixir.TestSupport

  import ExUnit.CaptureIO

  alias Mix.Tasks.Studio.LinearCapabilities
  alias SymphonyElixir.Linear.CapabilityDiscovery

  @prefix "SYMPHONY_STUDIO_LINEAR_CAPABILITIES_JSON="
  @api_key "task-private-linear-api-key-canary"
  @project_slug "task-private-linear-project-canary"
  @active_state "Task Private Active State Canary"
  @terminal_state "Task Private Terminal State Canary"
  @required_label "task-private-required-label-canary"
  @viewer_id "task-private-viewer-id-canary"
  @project_id "task-private-project-id-canary"
  @team_id "task-private-team-id-canary"
  @binding_key :binary.copy(<<0xC7>>, 32)

  test "loads configuration without starting the Symphony application" do
    assert Mix.Task.requirements(LinearCapabilities) == ["app.config --no-compile"]
  end

  test "sealed entry requires a canonical absolute workflow before probing" do
    previous_state_home = System.get_env("XDG_STATE_HOME")

    root =
      Path.join(
        System.tmp_dir!(),
        "studio-linear-capabilities-sealed-input-#{System.unique_integer([:positive, :monotonic])}"
      )

    state_home = Path.join(root, "private-state")
    workflow = Path.join(root, "WORKFLOW.md")
    workflow_link = Path.join(root, "workflow-link.md")
    File.mkdir_p!(root)
    write_workflow_file!(workflow, tracker_kind: "linear", tracker_api_token: nil)
    File.ln_s!(workflow, workflow_link)
    System.put_env("XDG_STATE_HOME", state_home)

    on_exit(fn ->
      restore_env("XDG_STATE_HOME", previous_state_home)
      File.rm_rf!(root)
    end)

    assert_raise Mix.Error, ~r/missing --workflow/, fn ->
      LinearCapabilities.run_sealed(["--format", "json"])
    end

    assert_raise Mix.Error, ~r/invalid or unsafe workflow path/, fn ->
      LinearCapabilities.run_sealed([
        "--format",
        "json",
        "--workflow",
        "relative-WORKFLOW.md"
      ])
    end

    assert_raise Mix.Error, ~r/invalid or unsafe workflow path/, fn ->
      LinearCapabilities.run_sealed([
        "--format",
        "json",
        "--workflow",
        workflow_link
      ])
    end

    assert_raise Mix.Error, ~r/invalid or unsafe workflow path/, fn ->
      LinearCapabilities.run_sealed([
        "--format",
        "json",
        "--workflow",
        Path.join(root, "missing-WORKFLOW.md")
      ])
    end

    refute File.exists?(state_home)
  end

  test "sealed entry restores the workflow override and emits exactly one prefixed JSON record" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_state_home = System.get_env("XDG_STATE_HOME")
    original_workflow = Workflow.workflow_file_path()

    root =
      Path.join(
        System.tmp_dir!(),
        "studio-linear-capabilities-sealed-output-#{System.unique_integer([:positive, :monotonic])}"
      )

    state_home =
      Path.join(
        System.tmp_dir!(),
        "studio-linear-capabilities-sealed-state-#{System.unique_integer([:positive, :monotonic])}"
      )

    selected_workflow = Path.join(root, "WORKFLOW.md")
    restored_workflow = Path.join(root, "restored-WORKFLOW.md")
    File.mkdir_p!(root)

    write_workflow_file!(selected_workflow,
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: "task-private-sealed-project-canary"
    )

    System.delete_env("LINEAR_API_KEY")
    System.put_env("XDG_STATE_HOME", state_home)
    Workflow.set_workflow_file_path(restored_workflow)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("XDG_STATE_HOME", previous_state_home)
      Workflow.set_workflow_file_path(original_workflow)
      File.rm_rf!(root)
      File.rm_rf!(state_home)
    end)

    assert_raise Mix.Error, ~r/sealed read-only broker unavailable/, fn ->
      capture_io(fn ->
        LinearCapabilities.run_sealed([
          "--format",
          "json",
          "--workflow",
          selected_workflow
        ])
      end)
    end

    assert Workflow.workflow_file_path() == restored_workflow
    refute File.exists?(state_home)
  end

  test "prints exactly one final canonical JSON record for an exit-safe blocked probe" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_state_home = System.get_env("XDG_STATE_HOME")

    state_home =
      Path.join(
        System.tmp_dir!(),
        "symphony-linear-capability-state-#{System.unique_integer([:positive])}"
      )

    System.delete_env("LINEAR_API_KEY")
    System.put_env("XDG_STATE_HOME", state_home)

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("XDG_STATE_HOME", previous_state_home)
      File.rm_rf!(state_home)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: "task-private-project-slug-canary"
    )

    output = capture_io(fn -> assert :ok = LinearCapabilities.run(["--format", "json"]) end)
    assert [record] = String.split(output, "\n", trim: true)
    assert String.starts_with?(record, @prefix <> ~s({"blockers":))

    report = record |> String.replace_prefix(@prefix, "") |> Jason.decode!()
    assert report["reportVersion"] == 1
    assert report["connectivity"] == %{"reason" => "missing_api_key", "status" => "blocked"}
    assert report["configuredProjectBindingGeneration"] == 1
    assert report["configuredProjectBinding"] =~ ~r/^linear-project-v1-[0-9a-f]{64}$/
    refute output =~ "task-private-project-slug-canary"
  end

  test "prints one public successful report whose mutation evidence remains schema only" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_api_key) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: @api_key,
      tracker_project_slug: @project_slug,
      tracker_active_states: [@active_state],
      tracker_terminal_states: [@terminal_state],
      tracker_required_labels: [@required_label]
    )

    {graphql, calls} = scripted_graphql(pass_responses())

    probe = fn ->
      CapabilityDiscovery.probe(
        graphql: graphql,
        key_provider: fn -> {:ok, @binding_key} end
      )
    end

    output =
      capture_io(fn ->
        assert :ok =
                 LinearCapabilities.run_with_probe_for_test(
                   ["--format", "json"],
                   probe
                 )
      end)

    assert [record] = String.split(output, "\n", trim: true)
    assert String.starts_with?(record, @prefix <> ~s({"blockers":))

    report = record |> String.replace_prefix(@prefix, "") |> Jason.decode!()

    assert Map.keys(report) |> Enum.sort() ==
             ~w(blockers comments configuredProjectBinding configuredProjectBindingGeneration connectivity labels mutations project reportVersion states)

    assert report["reportVersion"] == 1
    assert report["configuredProjectBindingGeneration"] == 1
    assert report["configuredProjectBinding"] =~ ~r/^linear-project-v1-[0-9a-f]{64}$/

    for check <- ~w(connectivity project states labels blockers comments) do
      assert report[check] == %{"reason" => "verified", "status" => "pass"}
    end

    assert report["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "schema_verified",
             "status" => "pass"
           }

    assert Enum.map(calls.(), fn {query, _variables} -> operation_name(query) end) == [
             "SymphonyStudioLinearConnectivity",
             "SymphonyStudioLinearProject",
             "SymphonyStudioLinearStates",
             "SymphonyStudioLinearLabels",
             "SymphonyStudioLinearIssueShapes",
             "SymphonyStudioLinearSchemaCapabilities",
             "SymphonyStudioLinearConnectivity",
             "SymphonyStudioLinearProject"
           ]

    for private_canary <- [
          @api_key,
          @project_slug,
          @active_state,
          @terminal_state,
          @required_label,
          @viewer_id,
          @project_id,
          @team_id,
          "task-private-issue-id-canary",
          "task-private-comment-id-canary",
          "task-private-relation-id-canary",
          "https://api.linear.app/graphql"
        ] do
      refute output =~ private_canary
    end
  end

  test "documents the exact read-only collection contract and rejects other arguments" do
    output = capture_io(fn -> assert :ok = LinearCapabilities.run(["--help"]) end)

    assert output =~ "mix studio.linear_capabilities --format json"
    assert output =~ @prefix
    assert output =~ ~r/never executes a GraphQL\s+mutation/
    assert output =~ "schema surface"
    assert output =~ "--validation-fixtures"
    assert output =~ "Ordinary product use remains project-generic"
    assert output =~ "R1-07"

    assert_raise Mix.Error, ~r/--format must be json/, fn ->
      LinearCapabilities.run(["--format", "yaml"])
    end

    assert_raise Mix.Error, ~r/invalid arguments/, fn ->
      LinearCapabilities.run(["--format", "json", "unexpected"])
    end
  end

  test "forwards validation fixture mode only when the opt-in switch is present" do
    parent = self()

    probe = fn validation_fixtures? ->
      send(parent, {:validation_fixture_mode, validation_fixtures?})
      %{"reportVersion" => 1, "validationFixtureMode" => validation_fixtures?}
    end

    generic_output =
      capture_io(fn ->
        assert :ok =
                 LinearCapabilities.run_with_probe_for_test(
                   ["--format", "json"],
                   probe
                 )
      end)

    assert_received {:validation_fixture_mode, false}
    assert generic_output =~ ~s("validationFixtureMode":false)

    validation_output =
      capture_io(fn ->
        assert :ok =
                 LinearCapabilities.run_with_probe_for_test(
                   ["--format", "json", "--validation-fixtures"],
                   probe
                 )
      end)

    assert_received {:validation_fixture_mode, true}
    assert validation_output =~ ~s("validationFixtureMode":true)
  end

  defp pass_responses do
    [
      viewer_response(),
      connection_response("projects", [project_node()]),
      connection_response("workflowStates", [
        state_node("task-private-active-state-id-canary", @active_state),
        state_node("task-private-terminal-state-id-canary", @terminal_state)
      ]),
      connection_response("issueLabels", [label_node()]),
      issue_shape_response(),
      schema_response(),
      viewer_response(),
      connection_response("projects", [project_node()])
    ]
  end

  defp viewer_response do
    {:ok, %{"data" => %{"viewer" => %{"id" => @viewer_id}}}}
  end

  defp project_node do
    %{
      "id" => @project_id,
      "slugId" => @project_slug,
      "teams" => %{
        "nodes" => [%{"id" => @team_id}],
        "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
      }
    }
  end

  defp state_node(id, name) do
    %{"id" => id, "name" => name, "team" => %{"id" => @team_id}}
  end

  defp label_node do
    %{
      "id" => "task-private-label-id-canary",
      "name" => @required_label,
      "team" => nil
    }
  end

  defp issue_shape_response do
    {:ok,
     %{
       "data" => %{
         "issues" => %{
           "nodes" => [
             %{
               "comments" => %{
                 "nodes" => [%{"id" => "task-private-comment-id-canary"}]
               },
               "id" => "task-private-issue-id-canary",
               "inverseRelations" => %{
                 "nodes" => [
                   %{
                     "id" => "task-private-relation-id-canary",
                     "issue" => %{"id" => "task-private-blocker-issue-id-canary"},
                     "type" => "blocks"
                   }
                 ]
               },
               "labels" => %{
                 "nodes" => [%{"id" => "task-private-shape-label-id-canary"}]
               }
             }
           ]
         }
       }
     }}
  end

  defp schema_response do
    {:ok,
     %{
       "data" => %{
         "commentCreateInput" => %{
           "inputFields" => [
             typed_field("issueId", named_type("SCALAR", "String")),
             typed_field("body", named_type("SCALAR", "String"))
           ],
           "kind" => "INPUT_OBJECT"
         },
         "commentPayload" => %{
           "fields" => [
             typed_field("success", non_null_type(named_type("SCALAR", "Boolean")))
           ],
           "kind" => "OBJECT"
         },
         "issuePayload" => %{
           "fields" => [
             typed_field("success", non_null_type(named_type("SCALAR", "Boolean")))
           ],
           "kind" => "OBJECT"
         },
         "issueUpdateInput" => %{
           "inputFields" => [typed_field("stateId", named_type("SCALAR", "String"))],
           "kind" => "INPUT_OBJECT"
         },
         "mutationType" => %{
           "fields" => [
             %{
               "args" => [
                 typed_field(
                   "input",
                   non_null_type(named_type("INPUT_OBJECT", "CommentCreateInput"))
                 )
               ],
               "name" => "commentCreate",
               "type" => non_null_type(named_type("OBJECT", "CommentPayload"))
             },
             %{
               "args" => [
                 typed_field("id", non_null_type(named_type("SCALAR", "String"))),
                 typed_field(
                   "input",
                   non_null_type(named_type("INPUT_OBJECT", "IssueUpdateInput"))
                 )
               ],
               "name" => "issueUpdate",
               "type" => non_null_type(named_type("OBJECT", "IssuePayload"))
             }
           ],
           "kind" => "OBJECT"
         }
       }
     }}
  end

  defp typed_field(name, type), do: %{"name" => name, "type" => type}
  defp named_type(kind, name), do: %{"kind" => kind, "name" => name, "ofType" => nil}

  defp non_null_type(type),
    do: %{"kind" => "NON_NULL", "name" => nil, "ofType" => type}

  defp connection_response(key, nodes) do
    {:ok,
     %{
       "data" => %{
         key => %{
           "nodes" => nodes,
           "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
         }
       }
     }}
  end

  defp scripted_graphql(responses) do
    parent = self()
    {:ok, script} = Agent.start_link(fn -> responses end)
    on_exit(fn -> if Process.alive?(script), do: Agent.stop(script) end)

    graphql = fn query, variables ->
      send(parent, {:linear_task_graphql_call, query, variables})

      Agent.get_and_update(script, fn
        [response | rest] -> {response, rest}
        [] -> {{:error, :unexpected_request}, []}
      end)
    end

    calls = fn -> collect_calls([]) end
    {graphql, calls}
  end

  defp collect_calls(acc) do
    receive do
      {:linear_task_graphql_call, query, variables} ->
        collect_calls([{query, variables} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp operation_name(query) do
    case Regex.run(~r/\bquery\s+([A-Za-z0-9_]+)/, query) do
      [_full, operation] -> operation
      _no_operation -> nil
    end
  end
end
