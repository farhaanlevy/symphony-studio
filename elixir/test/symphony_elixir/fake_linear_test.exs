# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.FakeLinearTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Adapter
  alias SymphonyElixir.TestSupport.FakeLinear

  setup do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    Application.delete_env(:symphony_elixir, :linear_client_module)

    on_exit(fn ->
      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :linear_client_module)
      else
        Application.put_env(:symphony_elixir, :linear_client_module, previous_client)
      end
    end)

    :ok
  end

  test "real client paginates candidates and by-id reads through loopback HTTP" do
    issues =
      Enum.map(1..55, fn index ->
        FakeLinear.issue(
          id: "issue-#{index}",
          identifier: "STU-#{index}",
          state: "Todo",
          labels: ["Studio", "R0"],
          blocker_ids: if(index == 55, do: ["issue-1"], else: [])
        )
      end)

    fixture = FakeLinear.start!(issues: issues)
    on_exit(fn -> FakeLinear.stop(fixture) end)
    write_fake_linear_workflow!(Workflow.workflow_file_path(), fixture)

    assert {:ok, candidates} = Client.fetch_candidate_issues()
    assert Enum.map(candidates, & &1.id) == Enum.map(1..55, &"issue-#{&1}")
    assert List.last(candidates).blocked_by == [%{id: "issue-1", identifier: "STU-1", state: "Todo"}]
    assert List.first(candidates).labels == ["studio", "r0"]

    requested_ids = Enum.map(1..55, &"issue-#{&1}") |> Enum.reverse()
    assert {:ok, reconciled} = Client.fetch_issue_states_by_ids(requested_ids)
    assert Enum.map(reconciled, & &1.id) == requested_ids

    assert length(FakeLinear.requests(fixture, "SymphonyLinearPoll")) == 2
    assert length(FakeLinear.requests(fixture, "SymphonyLinearIssuesById")) == 2
    assert :ok = FakeLinear.verify!(fixture)
  end

  test "real adapter mutates deterministic comments and state with scriptable failures" do
    issue = FakeLinear.issue(id: "issue-1", identifier: "STU-1", state: "Todo")
    fixture = FakeLinear.start!(issues: [issue])
    on_exit(fn -> FakeLinear.stop(fixture) end)
    write_fake_linear_workflow!(Workflow.workflow_file_path(), fixture)

    assert :ok = Adapter.create_comment("issue-1", "fixture comment")
    assert FakeLinear.comments(fixture, "issue-1") == [%{"body" => "fixture comment", "id" => "comment-1"}]

    assert :ok = Adapter.update_issue_state("issue-1", "Done")
    assert FakeLinear.snapshot(fixture).issues["issue-1"].state == "Done"
    assert FakeLinear.snapshot(fixture).issues["issue-1"].revision == 2

    assert :ok =
             FakeLinear.script_next(
               fixture,
               "SymphonyCreateComment",
               {:http_error, 503, %{"error" => "unavailable"}}
             )

    assert {:error, {:linear_api_status, 503}} = Adapter.create_comment("issue-1", "not committed")
    assert length(FakeLinear.comments(fixture, "issue-1")) == 1

    assert :ok =
             FakeLinear.script_next(
               fixture,
               "SymphonyCreateComment",
               {:after_commit, {:http_error, 503, %{"error" => "lost response"}}}
             )

    assert {:error, {:linear_api_status, 503}} = Adapter.create_comment("issue-1", "committed once")

    assert Enum.map(FakeLinear.comments(fixture, "issue-1"), & &1["body"]) == [
             "fixture comment",
             "committed once"
           ]

    assert :ok = FakeLinear.patch_issue(fixture, "issue-1", %{title: "Externally changed"})
    assert FakeLinear.snapshot(fixture).issues["issue-1"].revision == 3
    assert :ok = FakeLinear.set_blockers(fixture, "issue-1", [])
    assert FakeLinear.snapshot(fixture).issues["issue-1"].revision == 4
    assert :ok = FakeLinear.verify!(fixture)
  end

  test "fixture rejects bad transport input without recording the credential" do
    fixture = FakeLinear.start!()
    on_exit(fn -> FakeLinear.stop(fixture) end)

    assert {:ok, %{status: 401}} =
             Req.post(fixture.endpoint,
               headers: [{"authorization", "wrong-token"}],
               json: %{"query" => "query SymphonyLinearViewer { viewer { id } }", "variables" => %{}}
             )

    assert {:ok, %{status: 400}} =
             Req.post(fixture.endpoint,
               headers: [{"authorization", fixture.token}, {"content-type", "application/json"}],
               body: "{not-json"
             )

    assert {:ok, %{status: 405}} = Req.get(fixture.endpoint)

    requests = FakeLinear.requests(fixture)
    assert Enum.map(requests, & &1.auth_valid) == [false, true]
    refute inspect(requests) =~ fixture.token
  end

  test "unauthorized requests cannot consume a scripted response" do
    fixture = FakeLinear.start!()
    on_exit(fn -> FakeLinear.stop(fixture) end)

    assert :ok =
             FakeLinear.script_next(
               fixture,
               "SymphonyLinearViewer",
               {:graphql_error, "SCRIPTED", "consumed by authorized request"}
             )

    request = %{
      "query" => "query SymphonyLinearViewer { viewer { id } }",
      "variables" => %{}
    }

    assert {:ok, %{status: 401}} =
             Req.post(fixture.endpoint,
               headers: [{"authorization", "wrong-token"}],
               json: request
             )

    assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyLinearViewer")

    assert {:ok, %{status: 200, body: body}} =
             Req.post(fixture.endpoint,
               headers: [{"authorization", fixture.token}],
               json: request
             )

    assert get_in(body, ["errors", Access.at(0), "extensions", "code"]) == "SCRIPTED"
    assert :ok = FakeLinear.verify!(fixture)
  end

  test "invalid GraphQL envelopes and operation contracts cannot consume scripted responses" do
    fixture = FakeLinear.start!()
    on_exit(fn -> FakeLinear.stop(fixture) end)

    assert :ok =
             FakeLinear.script_next(
               fixture,
               "SymphonyLinearViewer",
               {:graphql_error, "SCRIPTED", "consumed by a valid request"}
             )

    query = "query SymphonyLinearViewer { viewer { id } }"
    headers = [{"authorization", fixture.token}]

    assert {:ok, %{status: 400}} =
             Req.post(fixture.endpoint,
               headers: headers,
               json: %{"query" => query, "variables" => []}
             )

    assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyLinearViewer")

    assert {:ok, %{status: 400}} =
             Req.post(fixture.endpoint,
               headers: headers,
               json: %{"operationName" => 42, "query" => query, "variables" => %{}}
             )

    assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyLinearViewer")

    assert {:ok,
            %{
              status: 400,
              body: %{"errors" => [%{"message" => "invalid_envelope_keys"}]}
            }} =
             Req.post(fixture.endpoint,
               headers: headers,
               json: %{"query" => query, "unexpected" => true, "variables" => %{}}
             )

    assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyLinearViewer")

    assert {:ok, %{status: 200, body: body}} =
             Req.post(fixture.endpoint,
               headers: headers,
               json: %{
                 "operationName" => "SymphonyLinearViewer",
                 "query" => query,
                 "variables" => nil
               }
             )

    assert get_in(body, ["errors", Access.at(0), "extensions", "code"]) == "SCRIPTED"

    assert :ok =
             FakeLinear.script_next(
               fixture,
               "SymphonyCreateComment",
               {:graphql_error, "SCRIPTED_MUTATION", "consumed by a valid mutation"}
             )

    mutation = """
    mutation SymphonyCreateComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    """

    invalid_variables = [
      %{"issueId" => "issue-1"},
      %{"body" => nil, "issueId" => "issue-1"},
      %{"body" => false, "issueId" => "issue-1"},
      %{"body" => "comment", "extra" => true, "issueId" => "issue-1"}
    ]

    Enum.each(invalid_variables, fn variables ->
      assert {:ok,
              %{
                status: 400,
                body: %{"errors" => [%{"message" => "invalid_operation_variables"}]}
              }} =
               Req.post(fixture.endpoint,
                 headers: headers,
                 json: %{"query" => mutation, "variables" => variables}
               )

      assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyCreateComment")
    end)

    mismatched_documents = [
      String.replace(mutation, "success", "id"),
      String.replace(mutation, "commentCreate", "comment Create")
    ]

    Enum.each(mismatched_documents, fn mismatched_document ->
      assert {:ok,
              %{
                status: 400,
                body: %{"errors" => [%{"message" => "query_document_mismatch"}]}
              }} =
               Req.post(fixture.endpoint,
                 headers: headers,
                 json: %{
                   "query" => mismatched_document,
                   "variables" => %{"body" => "comment", "issueId" => "issue-1"}
                 }
               )

      assert Map.has_key?(FakeLinear.snapshot(fixture).scripts, "SymphonyCreateComment")
    end)

    assert {:ok, %{status: 200, body: body}} =
             Req.post(fixture.endpoint,
               headers: headers,
               json: %{
                 "query" => mutation,
                 "variables" => %{"body" => "comment", "issueId" => "issue-1"}
               }
             )

    assert get_in(body, ["errors", Access.at(0), "extensions", "code"]) == "SCRIPTED_MUTATION"
    assert :ok = FakeLinear.verify!(fixture)
  end

  test "workflow overrides preserve a non-default project slug" do
    issue =
      FakeLinear.issue(
        id: "issue-custom-project",
        identifier: "STU-77",
        project_slug: "custom-project",
        state: "Todo"
      )

    fixture = FakeLinear.start!(issues: [issue], project_slug: "custom-project")
    on_exit(fn -> FakeLinear.stop(fixture) end)
    write_fake_linear_workflow!(Workflow.workflow_file_path(), fixture)

    assert {:ok, [candidate]} = Client.fetch_candidate_issues()
    assert candidate.id == "issue-custom-project"
    assert FakeLinear.workflow_overrides(fixture)[:tracker_project_slug] == "custom-project"
    assert :ok = FakeLinear.verify!(fixture)
  end

  test "ordinary generated workflows cannot address the real Linear endpoint" do
    workflow = File.read!(Workflow.workflow_file_path())
    assert workflow =~ ~s(kind: "memory")
    assert workflow =~ ~s(endpoint: "http://127.0.0.1:0/graphql")
    refute workflow =~ "https://api.linear.app/graphql"
  end
end
