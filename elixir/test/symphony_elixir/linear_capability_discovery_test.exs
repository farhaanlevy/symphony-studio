# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.LinearCapabilityDiscoveryTest do
  use SymphonyElixir.TestSupport

  alias Absinthe.Language.Source
  alias Absinthe.Phase.Parse
  alias SymphonyElixir.Linear.CapabilityDiscovery

  defmodule BoundedResponsePlug do
    @moduledoc false

    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, _request_body, conn} = read_body(conn)

      send(Keyword.fetch!(opts, :recipient), {
        :bounded_linear_request,
        Keyword.fetch!(opts, :label),
        get_req_header(conn, "authorization")
      })

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Keyword.fetch!(opts, :body))
    end
  end

  @check_keys ~w(connectivity project states labels blockers comments mutations)
  @project_slug "private-project-slug-canary"
  @api_key "private-linear-api-key-canary"
  @active_state "Active State Canary"
  @terminal_state "Terminal State Canary"
  @required_label "required-label-canary"
  @validation_team_key "VAL"
  @binding_key :binary.copy(<<0xA7>>, 32)

  setup do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: @api_key,
      tracker_project_slug: @project_slug,
      tracker_active_states: [@active_state],
      tracker_terminal_states: [@terminal_state],
      tracker_required_labels: [@required_label]
    )

    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_api_key) end)
    :ok
  end

  test "passes the bounded read-only capability matrix without returning raw identities" do
    {graphql, calls} = scripted_graphql(pass_responses())

    report = probe(graphql: graphql)

    assert Map.keys(report) |> Enum.sort() ==
             Enum.sort(
               @check_keys ++
                 ["configuredProjectBinding", "configuredProjectBindingGeneration", "reportVersion"]
             )

    assert report["reportVersion"] == 1
    assert report["configuredProjectBindingGeneration"] == 1

    expected_binding =
      "linear-project-v1-" <>
        (:crypto.mac(
           :hmac,
           :sha256,
           @binding_key,
           [
             "symphony-studio/linear-project-identity/v1\0",
             binding_frame("1"),
             binding_frame("viewer-id-canary"),
             binding_frame("project-id-canary"),
             binding_frame(@project_slug),
             <<1::unsigned-big-integer-size(32)>>,
             binding_frame("team-id-canary")
           ]
         )
         |> Base.encode16(case: :lower))

    assert report["configuredProjectBinding"] == expected_binding

    for check <- @check_keys -- ["mutations"] do
      assert report[check] == %{"reason" => "verified", "status" => "pass"}
    end

    assert report["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "schema_verified",
             "status" => "pass"
           }

    rendered = Jason.encode!(report)

    for private_value <- [
          @api_key,
          @project_slug,
          "viewer-id-canary",
          "project-id-canary",
          "project-name-canary",
          "team-id-canary",
          "state-active-id-canary",
          "state-terminal-id-canary",
          @active_state,
          @terminal_state,
          "label-id-canary",
          @required_label,
          "issue-id-canary",
          "comment-id-canary",
          "private-comment-body-canary",
          "relation-id-canary",
          "blocker-issue-id-canary",
          "shape-label-id-canary"
        ] do
      refute rendered =~ private_value
    end

    recorded_calls = calls.()
    assert length(recorded_calls) == 8

    for {query, _variables} <- recorded_calls do
      assert {:ok, _blueprint} = Parse.run(%Source{body: query}, [])
      assert String.trim_leading(query) =~ ~r/^query\s/
      refute String.trim_leading(query) =~ ~r/^mutation\s/
    end

    assert {_query, %{"projectSlug" => @project_slug}} =
             Enum.find(recorded_calls, fn {query, _variables} ->
               operation_name(query) == "SymphonyStudioLinearIssueShapes"
             end)
  end

  test "validation fixture mode proves two derived backlog fixtures without exposing identities" do
    {graphql, calls} = scripted_graphql(validation_pass_responses())

    report = probe(graphql: graphql, validation_fixtures: true)

    for check <- @check_keys -- ["mutations"] do
      assert report[check] == %{"reason" => "verified", "status" => "pass"}
    end

    assert report["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "schema_verified",
             "status" => "pass"
           }

    recorded_calls = calls.()

    assert Enum.map(recorded_calls, fn {query, _variables} -> operation_name(query) end) == [
             "SymphonyStudioLinearConnectivity",
             "SymphonyStudioLinearValidationProject",
             "SymphonyStudioLinearStates",
             "SymphonyStudioLinearLabels",
             "SymphonyStudioLinearValidationFixtures",
             "SymphonyStudioLinearSchemaCapabilities",
             "SymphonyStudioLinearConnectivity",
             "SymphonyStudioLinearValidationProject",
             "SymphonyStudioLinearValidationFixtures"
           ]

    for {query, variables} <- recorded_calls,
        operation_name(query) in [
          "SymphonyStudioLinearValidationProject",
          "SymphonyStudioLinearValidationFixtures"
        ] do
      assert variables["nestedFirst"] == 16
    end

    for {query, _variables} <- recorded_calls do
      assert {:ok, _blueprint} = Parse.run(%Source{body: query}, [])
      assert String.trim_leading(query) =~ ~r/^query\s/
      refute String.trim_leading(query) =~ ~r/^mutation\s/
    end

    rendered = Jason.encode!(report)

    for private_value <- [
          @validation_team_key,
          "VAL-1",
          "VAL-2",
          "validation-fixture-one-id-canary",
          "validation-fixture-two-id-canary",
          "validation-comment-id-canary",
          "validation-relation-id-canary"
        ] do
      refute rendered =~ private_value
    end
  end

  test "sealed broker mode needs no Linear credential and maps only the six exact queries" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: @project_slug,
      tracker_active_states: [@active_state],
      tracker_terminal_states: [@terminal_state],
      tracker_required_labels: [@required_label]
    )

    {graphql, calls} = scripted_graphql(validation_pass_responses())

    report =
      CapabilityDiscovery.probe(
        graphql: graphql,
        key_provider: fn -> {:ok, @binding_key} end,
        sealed_broker: true,
        validation_fixtures: true
      )

    for check <- @check_keys -- ["mutations"] do
      assert report[check] == %{"reason" => "verified", "status" => "pass"}
    end

    assert report["mutations"]["evidence"] == "schema_only"

    assert Enum.map(calls.(), fn {query, _variables} ->
             assert {:ok, operation} = CapabilityDiscovery.broker_operation(query)
             operation
           end) == [
             "connectivity",
             "validation_project",
             "states",
             "labels",
             "validation_fixtures",
             "mutation_schema",
             "connectivity",
             "validation_project",
             "validation_fixtures"
           ]

    assert {:error, :unknown_query} =
             CapabilityDiscovery.broker_operation("mutation Unsafe { issueUpdate(id: \"x\") }")
  end

  test "validation fixture mode fails closed on missing shape comment blocker and team evidence" do
    cases = [
      {[fixture_two: nil], "fixture_issue_missing"},
      {[fixture_two_state: "Todo"], "fixture_shape_mismatch"},
      {[comments: []], "fixture_comment_missing"},
      {[relations: []], "fixture_blocker_missing"},
      {[
         relations: [
           validation_relation(
             "external-issue-id-canary",
             "EXT-1"
           )
         ]
       ], "fixture_blocker_missing"}
    ]

    for {fixture_opts, reason} <- cases do
      {graphql, _calls} = scripted_graphql(validation_pass_responses(fixture_opts: fixture_opts))
      assert_all_blocked(probe(graphql: graphql, validation_fixtures: true), reason)
    end

    {graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        connection_response("projects", [
          project_node(
            "project-id-canary",
            ["team-id-canary", "team-id-canary-2"],
            @validation_team_key
          )
        ])
      ])

    assert_all_blocked(
      probe(graphql: graphql, validation_fixtures: true),
      "validation_team_mismatch"
    )
  end

  test "validation fixture mode rejects a fixture changed during its final read" do
    responses =
      validation_pass_responses(final_fixture_opts: [fixture_two_title: "Changed private title canary"])

    {graphql, _calls} = scripted_graphql(responses)
    assert_all_blocked(probe(graphql: graphql, validation_fixtures: true), "fixture_changed")
  end

  test "default binding key cannot be created inside the repository" do
    previous_state_home = System.get_env("XDG_STATE_HOME")

    state_home =
      Path.join(File.cwd!(), ".linear-binding-state-#{System.unique_integer([:positive])}")

    key_path = Path.join([state_home, "symphony-studio", "codex-identity-binding-v1.key"])

    on_exit(fn ->
      restore_env("XDG_STATE_HOME", previous_state_home)
      File.rm_rf!(state_home)
    end)

    System.put_env("XDG_STATE_HOME", state_home)

    report =
      CapabilityDiscovery.probe(graphql: fn _query, _variables -> flunk("unsafe key path must not make a request") end)

    assert report["configuredProjectBinding"] == nil
    assert report["configuredProjectBindingGeneration"] == 1

    for check <- @check_keys do
      assert report[check] == %{
               "reason" => "binding_key_unavailable",
               "status" => "blocked"
             }
    end

    refute File.exists?(key_path)
    refute File.exists?(state_home)
  end

  test "default binding key cannot be created beside an externally selected workflow" do
    previous_state_home = System.get_env("XDG_STATE_HOME")

    state_home =
      Path.join(
        Workflow.workflow_directory(),
        ".linear-binding-state-#{System.unique_integer([:positive])}"
      )

    key_path = Path.join([state_home, "symphony-studio", "codex-identity-binding-v1.key"])

    on_exit(fn ->
      restore_env("XDG_STATE_HOME", previous_state_home)
      File.rm_rf!(state_home)
    end)

    System.put_env("XDG_STATE_HOME", state_home)

    report =
      CapabilityDiscovery.probe(
        graphql: fn _query, _variables ->
          flunk("workflow-adjacent key path must not make a request")
        end
      )

    assert report["configuredProjectBinding"] == nil

    for check <- @check_keys do
      assert report[check] == %{
               "reason" => "binding_key_unavailable",
               "status" => "blocked"
             }
    end

    refute File.exists?(key_path)
    refute File.exists?(state_home)
  end

  test "symlinked external workflow still protects its repository root" do
    previous_state_home = System.get_env("XDG_STATE_HOME")
    original_workflow_path = Workflow.workflow_file_path()
    repository_root = Path.expand("..", File.cwd!())

    external_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-linear-external-workflow-#{System.unique_integer([:positive])}"
      )

    workflow_link = Path.join(external_root, "selected-workflow")
    state_home = Path.join(repository_root, ".linear-binding-state-#{System.unique_integer([:positive])}")
    key_path = Path.join([state_home, "symphony-studio", "codex-identity-binding-v1.key"])

    File.mkdir_p!(external_root)
    File.ln_s!(Path.join(File.cwd!(), "test/support"), workflow_link)
    Workflow.set_workflow_file_path(Path.join(workflow_link, "network_hermetic_workflow.md"))
    System.put_env("XDG_STATE_HOME", state_home)

    on_exit(fn ->
      restore_env("XDG_STATE_HOME", previous_state_home)
      Workflow.set_workflow_file_path(original_workflow_path)
      File.rm_rf!(state_home)
      File.rm_rf!(external_root)
    end)

    report =
      File.cd!(external_root, fn ->
        CapabilityDiscovery.probe(
          graphql: fn _query, _variables ->
            flunk("symlinked workflow key path must not make a request")
          end
        )
      end)

    assert report["configuredProjectBinding"] == nil

    for check <- @check_keys do
      assert report[check] == %{
               "reason" => "binding_key_unavailable",
               "status" => "blocked"
             }
    end

    refute File.exists?(key_path)
    refute File.exists?(state_home)
  end

  test "missing key and absent project both return exit-safe fully blocked reports" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: @project_slug
    )

    missing_key =
      probe(graphql: fn _query, _variables -> flunk("missing key must not make a request") end)

    assert_all_blocked(missing_key, "missing_api_key")
    refute Jason.encode!(missing_key) =~ @project_slug

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: @api_key,
      tracker_project_slug: @project_slug
    )

    {graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        connection_response("projects", [])
      ])

    absent_project = probe(graphql: graphql)
    assert_all_blocked(absent_project, "project_not_found")
  end

  test "URL-style project selector must end in the returned Linear slug ID" do
    {matching_graphql, _calls} =
      scripted_graphql(pass_responses(project_slug: "slug-canary"))

    matching = probe(graphql: matching_graphql)
    assert matching["project"] == %{"reason" => "verified", "status" => "pass"}

    {mismatched_graphql, _calls} =
      scripted_graphql(pass_responses(project_slug: "different-slug-canary"))

    assert_all_blocked(probe(graphql: mismatched_graphql), "project_binding_mismatch")
  end

  test "GraphQL errors, partial data, request failures, and malformed payloads fail closed" do
    private_error = "raw-private-graphql-error-canary"

    error_report =
      probe(
        graphql: fn _query, _variables ->
          {:ok,
           %{
             "data" => %{"viewer" => %{"id" => "viewer-id-canary"}},
             "errors" => [%{"message" => private_error}]
           }}
        end
      )

    assert_all_blocked(error_report, "graphql_error")
    refute Jason.encode!(error_report) =~ private_error

    request_failure =
      probe(graphql: fn _query, _variables -> {:error, {:http, 503, private_error}} end)

    assert_all_blocked(request_failure, "request_failed")
    refute Jason.encode!(request_failure) =~ private_error

    {graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}}
      ])

    malformed = probe(graphql: graphql)
    assert_all_blocked(malformed, "malformed_payload")

    {unknown_schema_graphql, _calls} =
      scripted_graphql(
        Enum.take(pass_responses(), 5) ++
          [{:ok, %{"data" => %{"mutationType" => nil}}}] ++
          Enum.drop(pass_responses(), 6)
      )

    unknown_schema = probe(graphql: unknown_schema_graphql)

    assert unknown_schema["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "mutation_schema_mismatch",
             "status" => "blocked"
           }

    for check <- @check_keys -- ["mutations"] do
      assert unknown_schema[check]["status"] == "pass"
    end
  end

  test "default client starts only its HTTP runtime and redacts startup failures" do
    private_reason = "private-runtime-start-reason-canary"
    parent = self()

    report =
      probe(
        runtime_starter: fn ->
          send(parent, :linear_runtime_start_attempted)
          {:error, private_reason}
        end
      )

    assert_receive :linear_runtime_start_attempted
    assert_all_blocked(report, "request_failed")
    refute Jason.encode!(report) =~ private_reason

    {graphql, _calls} = scripted_graphql(pass_responses())

    passing_report =
      probe(
        graphql: graphql,
        runtime_starter: fn -> flunk("injected GraphQL must remain runtime-hermetic") end
      )

    assert passing_report["connectivity"] == %{"reason" => "verified", "status" => "pass"}
  end

  test "duplicate entities and cyclic pagination fail closed" do
    duplicate_project = project_node()

    {duplicate_graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        connection_response("projects", [duplicate_project, duplicate_project])
      ])

    duplicate = probe(graphql: duplicate_graphql)
    assert_all_blocked(duplicate, "duplicate_entity")

    {cycle_graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        connection_response("projects", [project_node()], "cursor-cycle"),
        connection_response("projects", [project_node("project-id-canary-2")], "cursor-cycle")
      ])

    cycle = probe(graphql: cycle_graphql)
    assert_all_blocked(cycle, "pagination_cycle")
  end

  test "pagination is capped before a seventeenth page" do
    parent = self()

    graphql = fn query, variables ->
      send(parent, {:graphql_call, query, variables})

      case operation_name(query) do
        "SymphonyStudioLinearConnectivity" ->
          viewer_response()

        "SymphonyStudioLinearProject" ->
          connection_response("projects", [project_node()])

        "SymphonyStudioLinearStates" ->
          index = cursor_index(variables["after"])

          connection_response(
            "workflowStates",
            [state_node("state-id-#{index}", "state-#{index}")],
            Integer.to_string(index + 1)
          )

        _unexpected ->
          {:error, :unexpected_operation}
      end
    end

    report = probe(graphql: graphql)
    assert_all_blocked(report, "pagination_limit")

    calls = collect_calls([])
    assert Enum.count(calls, fn {query, _variables} -> operation_name(query) == "SymphonyStudioLinearStates" end) == 16
  end

  test "missing configured states and mutation fields remain independently blocked" do
    responses = [
      viewer_response(),
      connection_response("projects", [project_node()]),
      connection_response("workflowStates", [state_node("other-state-id", "Other State")]),
      connection_response("issueLabels", [label_node()]),
      issue_shape_response(),
      schema_response(comment_create: false),
      viewer_response(),
      connection_response("projects", [project_node()])
    ]

    {graphql, _calls} = scripted_graphql(responses)
    report = probe(graphql: graphql)

    assert report["states"] == %{
             "reason" => "configured_states_missing",
             "status" => "blocked"
           }

    assert report["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "mutation_schema_mismatch",
             "status" => "blocked"
           }

    for check <- ~w(connectivity project labels blockers comments) do
      assert report[check]["status"] == "pass"
    end
  end

  test "missing configured labels cannot become false-green" do
    responses = [
      viewer_response(),
      connection_response("projects", [project_node()]),
      connection_response("workflowStates", [
        state_node("state-active-id-canary", @active_state),
        state_node("state-terminal-id-canary", @terminal_state)
      ]),
      connection_response("issueLabels", [label_node("different-label")]),
      issue_shape_response(),
      schema_response(),
      viewer_response(),
      connection_response("projects", [project_node()])
    ]

    {graphql, _calls} = scripted_graphql(responses)
    report = probe(graphql: graphql)

    assert report["labels"] == %{
             "reason" => "configured_labels_missing",
             "status" => "blocked"
           }

    assert report["blockers"]["status"] == "pass"
    assert report["comments"]["status"] == "pass"

    assert report["mutations"] == %{
             "evidence" => "schema_only",
             "reason" => "schema_verified",
             "status" => "pass"
           }
  end

  test "rejects empty duplicate blank and overlapping lifecycle configuration before requesting Linear" do
    invalid_cases = [
      [tracker_active_states: [], tracker_terminal_states: [@terminal_state]],
      [tracker_active_states: [@active_state], tracker_terminal_states: []],
      [tracker_active_states: [""], tracker_terminal_states: [@terminal_state]],
      [tracker_active_states: [@active_state, String.upcase(@active_state)]],
      [tracker_active_states: [@active_state], tracker_terminal_states: [String.upcase(@active_state)]]
    ]

    for overrides <- invalid_cases do
      write_workflow_file!(
        Workflow.workflow_file_path(),
        Keyword.merge(
          [
            tracker_kind: "linear",
            tracker_api_token: @api_key,
            tracker_project_slug: @project_slug,
            tracker_active_states: [@active_state],
            tracker_terminal_states: [@terminal_state],
            tracker_required_labels: [@required_label]
          ],
          overrides
        )
      )

      report =
        probe(
          graphql: fn _query, _variables ->
            flunk("invalid lifecycle configuration must not make a request")
          end
        )

      assert_all_blocked(report, "invalid_state_configuration")
    end

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: @api_key,
      tracker_project_slug: @project_slug,
      tracker_active_states: [@active_state],
      tracker_terminal_states: [@terminal_state],
      tracker_required_labels: [""]
    )

    invalid_labels =
      probe(
        graphql: fn _query, _variables ->
          flunk("invalid label configuration must not make a request")
        end
      )

    assert_all_blocked(invalid_labels, "invalid_label_configuration")
  end

  test "requires configured states and team-scoped labels on every project team" do
    team_ids = ["team-id-canary", "team-id-canary-2"]

    responses = [
      viewer_response(),
      connection_response("projects", [project_node("project-id-canary", team_ids)]),
      connection_response("workflowStates", [
        state_node("state-active-id-canary", @active_state),
        state_node("state-terminal-id-canary", @terminal_state)
      ]),
      connection_response("issueLabels", [label_node(@required_label, "team-id-canary")]),
      issue_shape_response(),
      schema_response(),
      viewer_response(),
      connection_response("projects", [project_node("project-id-canary", team_ids)])
    ]

    {graphql, _calls} = scripted_graphql(responses)
    report = probe(graphql: graphql)

    assert report["states"] == %{
             "reason" => "configured_states_missing",
             "status" => "blocked"
           }

    assert report["labels"] == %{
             "reason" => "configured_labels_missing",
             "status" => "blocked"
           }
  end

  test "final viewer project teams and tracker snapshot must remain identical" do
    viewer_changed = List.replace_at(pass_responses(), 6, viewer_response("different-viewer-id"))
    {graphql, _calls} = scripted_graphql(viewer_changed)
    assert_all_blocked(probe(graphql: graphql), "viewer_changed")

    project_changed =
      List.replace_at(
        pass_responses(),
        7,
        connection_response("projects", [
          project_node("project-id-canary", ["team-id-canary", "team-id-canary-2"])
        ])
      )

    {graphql, _calls} = scripted_graphql(project_changed)
    assert_all_blocked(probe(graphql: graphql), "project_changed")

    parent = self()
    {:ok, script} = Agent.start_link(fn -> pass_responses() end)
    on_exit(fn -> if Process.alive?(script), do: Agent.stop(script) end)

    rotating_graphql = fn _query, _variables ->
      response =
        Agent.get_and_update(script, fn
          [next | rest] -> {next, rest}
          [] -> {{:error, :unexpected_request}, []}
        end)

      unless Process.get(:linear_config_rotated) do
        Process.put(:linear_config_rotated, true)

        write_workflow_file!(Workflow.workflow_file_path(),
          tracker_kind: "linear",
          tracker_endpoint: "https://api.linear.app/graphql",
          tracker_api_token: "rotated-private-key-canary",
          tracker_project_slug: @project_slug,
          tracker_active_states: [@active_state],
          tracker_terminal_states: [@terminal_state],
          tracker_required_labels: [@required_label]
        )

        send(parent, :linear_config_rotated)
      end

      response
    end

    assert_all_blocked(probe(graphql: rotating_graphql), "configuration_changed")
    assert_received :linear_config_rotated
  end

  test "schema-only mutation evidence rejects argument input and payload drift" do
    invalid_schemas = [
      schema_response(extra_comment_arg: true),
      schema_response(comment_issue_id_type: "ID"),
      schema_response(issue_state_id_type: "ID"),
      schema_response(comment_success_type: "String")
    ]

    for invalid_schema <- invalid_schemas do
      responses = List.replace_at(pass_responses(), 5, invalid_schema)
      {graphql, _calls} = scripted_graphql(responses)
      report = probe(graphql: graphql)

      assert report["mutations"] == %{
               "evidence" => "schema_only",
               "reason" => "mutation_schema_mismatch",
               "status" => "blocked"
             }
    end
  end

  test "bounds provider scalars and cursors" do
    too_large_viewer =
      probe(
        graphql: fn _query, _variables ->
          viewer_response(String.duplicate("v", 1_025))
        end
      )

    assert_all_blocked(too_large_viewer, "malformed_payload")

    {graphql, _calls} =
      scripted_graphql([
        viewer_response(),
        connection_response(
          "projects",
          [project_node()],
          String.duplicate("c", 1_025)
        )
      ])

    assert_all_blocked(probe(graphql: graphql), "pagination_limit")
  end

  test "client uses the supplied immutable key and caps raw loopback responses through an injected transport" do
    small_body = Jason.encode!(%{"data" => %{"viewer" => %{"id" => "viewer-id"}}})
    large_body = Jason.encode!(%{"data" => %{"viewer" => %{"id" => String.duplicate("x", 512)}}})
    {endpoint_a, server_a} = start_response_server(:a, small_body)
    {oversize_endpoint, oversize_server} = start_response_server(:oversize, large_body)

    on_exit(fn ->
      stop_server(server_a)
      stop_server(oversize_server)
    end)

    endpoint = "https://api.linear.app/graphql"
    snapshot = %{api_key: @api_key, endpoint: endpoint}

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: endpoint,
      tracker_api_token: "rotated-private-key-canary",
      tracker_project_slug: @project_slug
    )

    assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer-id"}}}} =
             Client.graphql("query Snapshot { viewer { id } }", %{},
               tracker: snapshot,
               request_fun: Client.bounded_request_fun_for_test(endpoint_a, 2 * 1_024 * 1_024)
             )

    assert_receive {:bounded_linear_request, :a, [@api_key]}
    refute_receive {:bounded_linear_request, :b, _authorization}

    assert {:error, {:linear_api_request, :linear_response_too_large}} =
             Client.graphql("query Oversize { viewer { id } }", %{},
               tracker: snapshot,
               request_fun: Client.bounded_request_fun_for_test(oversize_endpoint, 64),
               max_response_bytes: 64
             )

    assert_receive {:bounded_linear_request, :oversize, [@api_key]}
  end

  test "project binding is keyed and generation-bound rather than a slug dictionary oracle" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: nil,
      tracker_project_slug: @project_slug
    )

    first =
      CapabilityDiscovery.probe(
        graphql: fn _query, _variables -> flunk("missing key must not request") end,
        key_provider: fn -> {:ok, @binding_key} end
      )

    second =
      CapabilityDiscovery.probe(
        graphql: fn _query, _variables -> flunk("missing key must not request") end,
        key_provider: fn -> {:ok, :binary.copy(<<0xB8>>, 32)} end
      )

    assert first["configuredProjectBindingGeneration"] == 1
    assert first["configuredProjectBinding"] =~ ~r/^linear-project-v1-[0-9a-f]{64}$/
    refute first["configuredProjectBinding"] == second["configuredProjectBinding"]
    refute Jason.encode!(first) =~ @project_slug
  end

  test "successful project binding covers viewer project and sorted team identity" do
    {base_graphql, _calls} = scripted_graphql(pass_responses())

    {viewer_graphql, _calls} =
      scripted_graphql(pass_responses(viewer_id: "different-viewer-id-canary"))

    {project_graphql, _calls} =
      scripted_graphql(pass_responses(project_id: "different-project-id-canary"))

    {teams_graphql, _calls} =
      scripted_graphql(pass_responses(team_ids: ["different-team-id-canary", "team-id-canary"]))

    base = probe(graphql: base_graphql)["configuredProjectBinding"]
    different_viewer = probe(graphql: viewer_graphql)["configuredProjectBinding"]
    different_project = probe(graphql: project_graphql)["configuredProjectBinding"]
    different_teams = probe(graphql: teams_graphql)["configuredProjectBinding"]

    assert Enum.uniq([base, different_viewer, different_project, different_teams]) |> length() == 4

    for binding <- [base, different_viewer, different_project, different_teams] do
      assert binding =~ ~r/^linear-project-v1-[0-9a-f]{64}$/
    end

    {reordered_graphql, _calls} =
      scripted_graphql(pass_responses(team_ids: ["team-id-canary", "different-team-id-canary"]))

    assert probe(graphql: reordered_graphql)["configuredProjectBinding"] == different_teams
  end

  defp pass_responses(opts \\ []) do
    viewer_id = Keyword.get(opts, :viewer_id, "viewer-id-canary")
    project_id = Keyword.get(opts, :project_id, "project-id-canary")
    project_slug = Keyword.get(opts, :project_slug, @project_slug)
    team_ids = Keyword.get(opts, :team_ids, ["team-id-canary"])

    state_nodes =
      team_ids
      |> Enum.with_index()
      |> Enum.flat_map(fn {team_id, index} ->
        [
          state_node("state-active-id-canary-#{index}", @active_state, team_id),
          state_node("state-terminal-id-canary-#{index}", @terminal_state, team_id)
        ]
      end)

    [
      viewer_response(viewer_id),
      connection_response("projects", [project_node(project_id, team_ids, nil, project_slug)]),
      connection_response("workflowStates", state_nodes),
      connection_response("issueLabels", [label_node()]),
      issue_shape_response(),
      schema_response(),
      viewer_response(viewer_id),
      connection_response("projects", [project_node(project_id, team_ids, nil, project_slug)])
    ]
  end

  defp validation_pass_responses(opts \\ []) do
    viewer_id = Keyword.get(opts, :viewer_id, "viewer-id-canary")
    project_id = Keyword.get(opts, :project_id, "project-id-canary")
    team_id = Keyword.get(opts, :team_id, "team-id-canary")
    fixture_opts = Keyword.get(opts, :fixture_opts, [])
    final_fixture_opts = Keyword.get(opts, :final_fixture_opts, fixture_opts)

    [
      viewer_response(viewer_id),
      connection_response("projects", [
        project_node(project_id, [team_id], @validation_team_key)
      ]),
      connection_response("workflowStates", [
        state_node("state-active-id-canary", @active_state, team_id),
        state_node("state-terminal-id-canary", @terminal_state, team_id),
        state_node("state-backlog-id-canary", "Backlog", team_id)
      ]),
      connection_response("issueLabels", [label_node()]),
      validation_fixture_response(Keyword.merge([project_id: project_id, team_id: team_id], fixture_opts)),
      schema_response(),
      viewer_response(viewer_id),
      connection_response("projects", [
        project_node(project_id, [team_id], @validation_team_key)
      ]),
      validation_fixture_response(Keyword.merge([project_id: project_id, team_id: team_id], final_fixture_opts))
    ]
  end

  defp viewer_response(id \\ "viewer-id-canary") do
    {:ok, %{"data" => %{"viewer" => %{"id" => id}}}}
  end

  defp project_node(
         id \\ "project-id-canary",
         team_ids \\ ["team-id-canary"],
         team_key \\ nil,
         project_slug \\ @project_slug
       ) do
    teams =
      Enum.map(team_ids, fn team_id ->
        if is_binary(team_key), do: %{"id" => team_id, "key" => team_key}, else: %{"id" => team_id}
      end)

    %{
      "id" => id,
      "name" => "project-name-canary",
      "slugId" => project_slug,
      "teams" => %{
        "nodes" => teams,
        "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
      }
    }
  end

  defp state_node(id, name, team_id \\ "team-id-canary") do
    %{"id" => id, "name" => name, "team" => %{"id" => team_id}}
  end

  defp label_node(name \\ @required_label, team_id \\ nil) do
    team = if is_binary(team_id), do: %{"id" => team_id}, else: nil
    %{"id" => "label-id-canary-#{name}-#{team_id}", "name" => name, "team" => team}
  end

  defp issue_shape_response do
    {:ok,
     %{
       "data" => %{
         "issues" => %{
           "nodes" => [
             %{
               "comments" => %{
                 "nodes" => [
                   %{
                     "body" => "private-comment-body-canary",
                     "id" => "comment-id-canary"
                   }
                 ]
               },
               "id" => "issue-id-canary",
               "inverseRelations" => %{
                 "nodes" => [
                   %{
                     "id" => "relation-id-canary",
                     "issue" => %{"id" => "blocker-issue-id-canary"},
                     "type" => "blocks"
                   }
                 ]
               },
               "labels" => %{"nodes" => [%{"id" => "shape-label-id-canary"}]}
             }
           ]
         }
       }
     }}
  end

  defp validation_fixture_response(opts) do
    project_id = Keyword.fetch!(opts, :project_id)
    team_id = Keyword.fetch!(opts, :team_id)
    fixture_one_id = "validation-fixture-one-id-canary"
    fixture_two_id = "validation-fixture-two-id-canary"

    fixture_one =
      validation_fixture_node(
        fixture_one_id,
        "#{@validation_team_key}-1",
        project_id,
        team_id,
        title: Keyword.get(opts, :fixture_one_title, "Validation fixture one title canary"),
        comments: Keyword.get(opts, :comments, [%{"id" => "validation-comment-id-canary"}]),
        relations: []
      )

    fixture_two =
      validation_fixture_node(
        fixture_two_id,
        "#{@validation_team_key}-2",
        project_id,
        team_id,
        title: Keyword.get(opts, :fixture_two_title, "Validation fixture two title canary"),
        state: Keyword.get(opts, :fixture_two_state, "Backlog"),
        comments: [],
        relations:
          Keyword.get(opts, :relations, [
            validation_relation(fixture_one_id, "#{@validation_team_key}-1")
          ])
      )

    {:ok,
     %{
       "data" => %{
         "fixtureOne" => Keyword.get(opts, :fixture_one, fixture_one),
         "fixtureTwo" => Keyword.get(opts, :fixture_two, fixture_two)
       }
     }}
  end

  defp validation_fixture_node(id, identifier, project_id, team_id, opts) do
    %{
      "comments" => %{"nodes" => Keyword.fetch!(opts, :comments)},
      "description" => "Private validation fixture description canary",
      "id" => id,
      "identifier" => identifier,
      "inverseRelations" => %{"nodes" => Keyword.fetch!(opts, :relations)},
      "labels" => %{"nodes" => [%{"id" => "validation-label-id-canary"}]},
      "project" => %{"id" => project_id, "slugId" => @project_slug},
      "state" => %{"name" => Keyword.get(opts, :state, "Backlog")},
      "team" => %{"id" => team_id, "key" => @validation_team_key},
      "title" => Keyword.fetch!(opts, :title)
    }
  end

  defp validation_relation(issue_id, identifier) do
    %{
      "id" => "validation-relation-id-canary",
      "issue" => %{"id" => issue_id, "identifier" => identifier},
      "type" => "blocks"
    }
  end

  defp schema_response(opts \\ []) do
    comment_issue_id_type = Keyword.get(opts, :comment_issue_id_type, "String")
    issue_state_id_type = Keyword.get(opts, :issue_state_id_type, "String")
    comment_success_type = Keyword.get(opts, :comment_success_type, "Boolean")

    comment_args = [
      typed_field(
        "input",
        non_null_type(named_type("INPUT_OBJECT", "CommentCreateInput"))
      )
    ]

    comment_args =
      if Keyword.get(opts, :extra_comment_arg, false),
        do: comment_args ++ [typed_field("extra", named_type("SCALAR", "String"))],
        else: comment_args

    comment_create =
      if Keyword.get(opts, :comment_create, true) do
        [
          %{
            "args" => comment_args,
            "name" => "commentCreate",
            "type" => non_null_type(named_type("OBJECT", "CommentPayload"))
          }
        ]
      else
        []
      end

    {:ok,
     %{
       "data" => %{
         "commentCreateInput" => %{
           "inputFields" => [
             typed_field("issueId", named_type("SCALAR", comment_issue_id_type)),
             typed_field("body", named_type("SCALAR", "String"))
           ],
           "kind" => "INPUT_OBJECT"
         },
         "commentPayload" => %{
           "fields" => [
             typed_field(
               "success",
               non_null_type(named_type("SCALAR", comment_success_type))
             )
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
           "inputFields" => [typed_field("stateId", named_type("SCALAR", issue_state_id_type))],
           "kind" => "INPUT_OBJECT"
         },
         "mutationType" => %{
           "fields" =>
             comment_create ++
               [
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
                 },
                 %{
                   "args" => [],
                   "name" => "unrelatedMutationField",
                   "type" => named_type("SCALAR", "Boolean")
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

  defp binding_frame(value),
    do: [<<byte_size(value)::unsigned-big-integer-size(64)>>, value]

  defp connection_response(key, nodes, next_cursor \\ nil) do
    {:ok,
     %{
       "data" => %{
         key => %{
           "nodes" => nodes,
           "pageInfo" => %{
             "endCursor" => next_cursor,
             "hasNextPage" => is_binary(next_cursor)
           }
         }
       }
     }}
  end

  defp scripted_graphql(responses) do
    parent = self()
    {:ok, script} = Agent.start_link(fn -> responses end)
    on_exit(fn -> if Process.alive?(script), do: Agent.stop(script) end)

    graphql = fn query, variables ->
      send(parent, {:graphql_call, query, variables})

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
      {:graphql_call, query, variables} -> collect_calls([{query, variables} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp operation_name(query) do
    case Regex.run(~r/\bquery\s+([A-Za-z0-9_]+)/, query) do
      [_full, operation] -> operation
      _ -> nil
    end
  end

  defp cursor_index(nil), do: 0
  defp cursor_index(cursor), do: String.to_integer(cursor)

  defp assert_all_blocked(report, reason) do
    assert report["reportVersion"] == 1
    assert report["configuredProjectBindingGeneration"] == 1
    assert report["configuredProjectBinding"] =~ ~r/^linear-project-v1-[0-9a-f]{64}$/

    for check <- @check_keys do
      assert report[check] == %{"reason" => reason, "status" => "blocked"}
    end
  end

  defp probe(opts) do
    CapabilityDiscovery.probe(Keyword.put_new(opts, :key_provider, fn -> {:ok, @binding_key} end))
  end

  defp start_response_server(label, body) do
    {:ok, server} =
      Bandit.start_link(
        plug: {BoundedResponsePlug, recipient: self(), label: label, body: body},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    {"http://127.0.0.1:#{port}/graphql", server}
  end

  defp stop_server(server) do
    if Process.alive?(server) do
      try do
        Supervisor.stop(server)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end
end
