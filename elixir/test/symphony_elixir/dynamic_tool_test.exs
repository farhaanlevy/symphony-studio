# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): prove upstream single-operation
# compatibility and the opt-in, AST-enforced managed Linear policy.
defmodule SymphonyElixir.Codex.DynamicToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Codex.DynamicTool, Identity}

  test "tool_specs advertises the upstream linear_graphql input contract" do
    assert [
             %{
               "description" => description,
               "inputSchema" => %{
                 "additionalProperties" => false,
                 "properties" => %{
                   "query" => _,
                   "variables" => _
                 },
                 "required" => ["query"],
                 "type" => "object"
               },
               "name" => "linear_graphql",
               "type" => "function"
             }
           ] = DynamicTool.tool_specs()

    assert description =~ "query or mutation"
  end

  test "managed tool_specs states the read-only boundary" do
    [spec] = DynamicTool.tool_specs(policy: :managed)

    assert spec["description"] =~ "current Linear issue"
    assert spec["description"] =~ "Mutations"
    assert spec["description"] =~ "Linear API limits"
  end

  test "unsupported tools return a classified failure with the supported tool list" do
    response = DynamicTool.execute("not_a_real_tool", %{})

    assert response["success"] == false

    assert decode_output(response) == %{
             "error" => %{
               "code" => "unsupported_dynamic_tool",
               "message" => ~s(Unsupported dynamic tool: "not_a_real_tool".),
               "supportedTools" => ["linear_graphql"]
             }
           }

    assert response["contentItems"] == [
             %{
               "type" => "inputText",
               "text" => response["output"]
             }
           ]
  end

  test "upstream linear_graphql returns successful query responses as tool text" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Viewer { viewer { id } }",
          "variables" => %{"includeTeams" => false}
        },
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_123"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{"includeTeams" => false}, []}

    assert response["success"] == true
    assert decode_output(response) == %{"data" => %{"viewer" => %{"id" => "usr_123"}}}
    assert response["contentItems"] == [%{"type" => "inputText", "text" => response["output"]}]
  end

  test "upstream linear_graphql accepts a trimmed raw query string" do
    test_pid = self()

    response =
      DynamicTool.execute(
        "linear_graphql",
        "  query Viewer { viewer { id } }  ",
        linear_client: fn query, variables, opts ->
          send(test_pid, {:linear_client_called, query, variables, opts})
          {:ok, %{"data" => %{"viewer" => %{"id" => "usr_456"}}}}
        end
      )

    assert_received {:linear_client_called, "query Viewer { viewer { id } }", %{}, []}
    assert response["success"] == true
  end

  test "upstream linear_graphql preserves one raw mutation" do
    test_pid = self()
    query = "mutation Comment { commentCreate(input: {body: \"ready\"}) { success } }"

    response =
      DynamicTool.execute("linear_graphql", %{"query" => query},
        linear_client: fn forwarded, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded, variables, opts})
          {:ok, %{"data" => %{"commentCreate" => %{"success" => true}}}}
        end
      )

    assert_received {:linear_client_called, ^query, %{}, []}
    assert response["success"] == true
  end

  test "upstream linear_graphql preserves fragments and directives in one operation" do
    test_pid = self()

    query = """
    query Viewer($includeName: Boolean!) @client {
      viewer { ...ViewerFields @include(if: $includeName) }
    }
    fragment ViewerFields on User { id name }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query, "variables" => %{"includeName" => true}},
        linear_client: fn forwarded, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded, variables, opts})
          {:ok, %{"data" => %{}}}
        end
      )

    assert_received {:linear_client_called, forwarded, %{"includeName" => true}, []}
    assert forwarded == String.trim(query)
    assert response["success"] == true
  end

  test "upstream parser does not count operation words inside strings or comments" do
    test_pid = self()

    query = """
    # mutation Hidden { issueUpdate { success } }
    query Search { viewer(search: "mutation StillHidden { nope }") { id } }
    """

    response =
      DynamicTool.execute("linear_graphql", %{"query" => query},
        linear_client: fn forwarded, variables, opts ->
          send(test_pid, {:linear_client_called, forwarded, variables, opts})
          {:ok, %{"data" => %{}}}
        end
      )

    assert_received {:linear_client_called, forwarded, %{}, []}
    assert forwarded == String.trim(query)
    assert response["success"] == true
  end

  test "linear_graphql rejects unexpected top-level arguments before Linear" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }", "operationName" => "Viewer"},
        linear_client: fn _query, _variables, _opts ->
          flunk("linear client should not be called for unexpected keys")
        end
      )

    assert_error_code(response, "unexpected_arguments")
  end

  test "linear_graphql normalizes missing and null variables while preserving maps" do
    query = "query Viewer { viewer { id } }"
    variables = %{"includeTeams" => false}

    for {arguments, expected_variables} <- [
          {%{"query" => query}, %{}},
          {%{"query" => query, "variables" => nil}, %{}},
          {%{"query" => query, "variables" => variables}, variables}
        ] do
      response =
        DynamicTool.execute("linear_graphql", arguments,
          linear_client: fn forwarded_query, forwarded_variables, opts ->
            assert forwarded_query == query
            assert forwarded_variables == expected_variables
            assert opts == []
            {:ok, %{"data" => %{}}}
          end
        )

      assert response["success"] == true
    end
  end

  test "linear_graphql rejects multi-operation, operation-free, malformed, and subscription documents" do
    documents = [
      {"query Viewer { viewer { id } } query Teams { teams { nodes { id } } }", "graphql_operation_count"},
      {"fragment ViewerFields on User { id }", "graphql_operation_count"},
      {"query Viewer {", "graphql_parse_error"},
      {"subscription Updates { issueUpdated { id } }", "graphql_operation_type_denied"}
    ]

    for {query, expected_code} <- documents do
      response =
        DynamicTool.execute("linear_graphql", %{"query" => query},
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for #{expected_code}")
          end
        )

      assert_error_code(response, expected_code)
    end
  end

  test "linear_graphql rejects blank, missing, and invalid argument forms" do
    cases = [
      {"   ", "missing_query"},
      {%{"variables" => %{"commentId" => "comment-1"}}, "missing_query"},
      {%{"query" => "   "}, "missing_query"},
      {[:not, :valid], "invalid_arguments"}
    ]

    for {arguments, expected_code} <- cases do
      response =
        DynamicTool.execute("linear_graphql", arguments,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called for invalid arguments")
          end
        )

      assert_error_code(response, expected_code)
    end
  end

  test "linear_graphql rejects every non-object JSON variables value" do
    for variables <- [false, true, 0, 1.5, "bad", ["bad"]] do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => "query Viewer { viewer { id } }", "variables" => variables},
          linear_client: fn _query, _forwarded_variables, _opts ->
            flunk("linear client should not be called for invalid variables")
          end
        )

      assert_error_code(response, "invalid_variables")
    end
  end

  test "linear_graphql marks GraphQL errors as failures while preserving their body" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "mutation BadMutation { nope }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{"errors" => [%{"message" => "Unknown field `nope`"}], "data" => nil}}
        end
      )

    assert response["success"] == false

    assert decode_output(response) == %{
             "data" => nil,
             "errors" => [%{"message" => "Unknown field `nope`"}]
           }

    atom_response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts ->
          {:ok, %{errors: [%{message: "boom"}], data: nil}}
        end
      )

    assert atom_response["success"] == false
  end

  test "linear_graphql emits stable transport and execution errors without raw reasons" do
    query = %{"query" => "query Viewer { viewer { id } }"}

    missing_token =
      DynamicTool.execute("linear_graphql", query,
        linear_client: fn _query, _variables, _opts ->
          {:error, :missing_linear_api_token}
        end
      )

    assert_error_code(missing_token, "missing_linear_api_token")

    status_error =
      DynamicTool.execute("linear_graphql", query,
        linear_client: fn _query, _variables, _opts ->
          {:error, {:linear_api_status, 503}}
        end
      )

    assert decode_output(status_error)["error"] == %{
             "code" => "linear_api_status",
             "message" => "Linear GraphQL request failed with HTTP 503.",
             "status" => 503
           }

    request_error =
      DynamicTool.execute("linear_graphql", query,
        linear_client: fn _query, _variables, _opts ->
          {:error, {:linear_api_request, {:secret, "DO_NOT_EXPOSE"}}}
        end
      )

    assert_error_code(request_error, "linear_api_request")
    refute request_error["output"] =~ "DO_NOT_EXPOSE"

    for callback <- [
          fn _query, _variables, _opts -> {:error, {:unexpected, "DO_NOT_EXPOSE"}} end,
          fn _query, _variables, _opts -> :unexpected_response end,
          fn _query, _variables, _opts -> raise "DO_NOT_EXPOSE" end,
          fn _query, _variables, _opts -> exit(:do_not_expose) end
        ] do
      response = DynamicTool.execute("linear_graphql", query, linear_client: callback)
      assert_error_code(response, "linear_graphql_execution_failed")
      refute response["output"] =~ "DO_NOT_EXPOSE"
    end
  end

  test "linear_graphql rejects malformed host options with a stable error" do
    response = DynamicTool.execute("linear_graphql", "query Viewer { viewer { id } }", [:not_keyword])
    assert_error_code(response, "invalid_tool_options")
  end

  test "managed policy forwards a literal issue-scoped read" do
    test_pid = self()
    context = trusted_context()
    query = ~s|query Current { issue(id: "#{context.issue_id}") { id title } }|

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query},
        managed_opts(context,
          linear_client: fn forwarded, variables, opts ->
            send(test_pid, {:linear_client_called, forwarded, variables, opts})
            {:ok, %{"data" => %{"issue" => %{"id" => context.issue_id}}}}
          end
        )
      )

    assert_received {:linear_client_called, ^query, %{}, []}
    assert response["success"] == true
  end

  test "managed policy forwards variable-bound aliases for only the trusted issue" do
    test_pid = self()
    context = trusted_context()

    query = """
    query Current($issueId: ID!) {
      first: issue(id: $issueId) { id }
      second: issue(id: $issueId) { title }
    }
    """

    variables = %{"issueId" => context.issue_id}

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query, "variables" => variables},
        managed_opts(context,
          linear_client: fn forwarded, forwarded_variables, opts ->
            send(test_pid, {:linear_client_called, forwarded, forwarded_variables, opts})
            {:ok, %{"data" => %{}}}
          end
        )
      )

    assert_received {:linear_client_called, forwarded, ^variables, []}
    assert forwarded == String.trim(query)
    assert response["success"] == true
  end

  test "managed policy requires canonical trusted issue and run context" do
    query = %{"query" => ~s|query { issue(id: "issue-123") { id } }|}

    invalid_contexts = [
      nil,
      %{},
      %{issue_id: " issue-123", run_id: Identity.uuid4()},
      %{issue_id: <<255>>, run_id: Identity.uuid4()},
      %{issue_id: "issue-123", run_id: String.upcase(Identity.uuid4())},
      %{issue_id: "issue-123", run_id: "not-a-uuid"},
      %{"issue_id" => "other", issue_id: "issue-123", run_id: Identity.uuid4()}
    ]

    for context <- invalid_contexts do
      response =
        DynamicTool.execute("linear_graphql", query,
          policy: :managed,
          trusted_context: context,
          linear_client: fn _query, _variables, _opts ->
            flunk("linear client should not be called without trusted context")
          end
        )

      assert_error_code(response, "managed_context_required")
    end
  end

  test "managed policy enforces document, token, and encoded-variable bounds" do
    context = trusted_context()

    document_response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => String.duplicate("x", 65_537)},
        managed_opts(context, linear_client: never_linear_client())
      )

    assert_error_code(document_response, "managed_document_too_large")

    variables_response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Current($issueId: ID!) { issue(id: $issueId) { id } }",
          "variables" => %{
            "issueId" => context.issue_id,
            "padding" => String.duplicate("x", 65_536)
          }
        },
        managed_opts(context, linear_client: never_linear_client())
      )

    assert_error_code(variables_response, "managed_variables_too_large")

    invalid_variables_response =
      DynamicTool.execute(
        "linear_graphql",
        %{
          "query" => "query Current($issueId: ID!) { issue(id: $issueId) { id } }",
          "variables" => %{"issueId" => context.issue_id, "invalid" => self()}
        },
        managed_opts(context, linear_client: never_linear_client())
      )

    assert_error_code(invalid_variables_response, "managed_variables_invalid")

    token_heavy_query =
      "query Current { issue(id: \"#{context.issue_id}\") { " <>
        Enum.map_join(1..10_001, " ", &"f#{&1}") <> " } }"

    token_response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => token_heavy_query},
        managed_opts(context, linear_client: never_linear_client())
      )

    assert_error_code(token_response, "graphql_parse_error")
  end

  test "managed policy denies raw mutations and subscriptions before Linear" do
    context = trusted_context()

    mutation =
      "mutation Change { issueUpdate(id: \"#{context.issue_id}\", input: {}) { success } }"

    documents = [
      {mutation, "managed_mutation_denied"},
      {"subscription Updates { issueUpdated { id } }", "managed_subscription_denied"}
    ]

    for {query, expected_code} <- documents do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => query},
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, expected_code)
    end
  end

  test "managed policy denies named, spread, and inline fragment paths" do
    context = trusted_context()

    documents = [
      """
      query Current($issueId: ID!) { issue(id: $issueId) { ...IssueFields } }
      fragment IssueFields on Issue { id }
      """,
      """
      query Current($issueId: ID!) { issue(id: $issueId) { ... on Issue { id } } }
      """
    ]

    for query <- documents do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => query, "variables" => %{"issueId" => context.issue_id}},
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, "managed_fragments_denied")
    end
  end

  test "managed policy denies operation, variable, and field directives" do
    context = trusted_context()

    documents = [
      "query Current($issueId: ID!) @audit { issue(id: $issueId) { id } }",
      "query Current($issueId: ID! @audit) { issue(id: $issueId) { id } }",
      "query Current($issueId: ID!) { issue(id: $issueId) @skip(if: false) { id } }"
    ]

    for query <- documents do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => query, "variables" => %{"issueId" => context.issue_id}},
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, "managed_directives_denied")
    end
  end

  test "managed policy denies nested introspection and unknown roots through aliases" do
    context = trusted_context()

    documents = [
      {"query Current($issueId: ID!) { issue(id: $issueId) { __typename } }", "managed_introspection_denied"},
      {"query Current { safeAlias: viewer { id } }", "managed_read_root_denied"},
      {"query Current { schemaAlias: __schema { queryType { name } } }", "managed_introspection_denied"}
    ]

    for {query, expected_code} <- documents do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => query, "variables" => %{"issueId" => context.issue_id}},
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, expected_code)
    end
  end

  test "managed policy denies unknown fields and relationship fan-out from the trusted issue" do
    context = trusted_context()

    documents = [
      "query Current($issueId: ID!) { issue(id: $issueId) { comments { nodes { body } } } }",
      "query Current($issueId: ID!) { issue(id: $issueId) { team { issues { nodes { id } } } } }",
      "query Current($issueId: ID!) { issue(id: $issueId) { title(format: markdown) } }",
      "query Current($issueId: ID!) { issue(id: $issueId) { unknownScalar } }"
    ]

    for query <- documents do
      response =
        DynamicTool.execute(
          "linear_graphql",
          %{"query" => query, "variables" => %{"issueId" => context.issue_id}},
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, "managed_read_field_denied")
    end
  end

  test "managed policy permits only the explicit nested current-issue metadata paths" do
    test_pid = self()
    context = trusted_context()

    query = """
    query Current($issueId: ID!) {
      issue(id: $issueId) {
        id
        state { id name type }
        assignee { id name }
        team { id key name }
        project { id name slugId }
        labels { nodes { id name } }
      }
    }
    """

    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => query, "variables" => %{"issueId" => context.issue_id}},
        managed_opts(context,
          linear_client: fn forwarded, variables, opts ->
            send(test_pid, {:linear_client_called, forwarded, variables, opts})
            {:ok, %{"data" => %{}}}
          end
        )
      )

    issue_id = context.issue_id
    assert_received {:linear_client_called, forwarded, %{"issueId" => ^issue_id}, []}
    assert forwarded == String.trim(query)
    assert response["success"] == true
  end

  test "managed policy binds every allowed root to the exact trusted issue" do
    context = trusted_context()

    cases = [
      {%{"query" => ~s|query { issue(id: "other-issue") { id } }|}, "managed_issue_scope_denied"},
      {%{
         "query" => "query Current($issueId: ID!) { issue(id: $issueId) { id } }",
         "variables" => %{"issueId" => "other-issue"}
       }, "managed_issue_scope_denied"},
      {%{"query" => "query Current { issue { id } }"}, "managed_issue_scope_denied"},
      {%{
         "query" => ~s|query Current { issue(id: "#{context.issue_id}", identifier: "SYM-1") { id } }|
       }, "managed_issue_scope_denied"},
      {%{
         "query" => ~s|query Current { one: issue(id: "#{context.issue_id}") { id } two: issue(id: "other") { id } }|
       }, "managed_issue_scope_denied"}
    ]

    for {arguments, expected_code} <- cases do
      response =
        DynamicTool.execute(
          "linear_graphql",
          arguments,
          managed_opts(context, linear_client: never_linear_client())
        )

      assert_error_code(response, expected_code)
    end
  end

  test "managed denial audit is content-free and callback failures cannot change policy" do
    context = trusted_context()
    test_pid = self()

    arguments = %{
      "query" => "query DO_NOT_LOG { leaked: viewer(search: \"DO_NOT_LOG\") { id } }",
      "variables" => %{"secret" => "DO_NOT_LOG"}
    }

    response =
      DynamicTool.execute(
        "linear_graphql",
        arguments,
        managed_opts(context,
          audit_callback: fn event -> send(test_pid, {:audit, event}) end,
          linear_client: never_linear_client()
        )
      )

    assert_error_code(response, "managed_read_root_denied")

    issue_id = context.issue_id
    run_id = context.run_id

    assert_received {:audit,
                     %{
                       decision: :denied,
                       error_code: "managed_read_root_denied",
                       issue_id: ^issue_id,
                       policy: :managed,
                       run_id: ^run_id,
                       tool: "linear_graphql"
                     } = event}

    refute inspect(event) =~ "DO_NOT_LOG"

    callback_failure =
      DynamicTool.execute(
        "linear_graphql",
        arguments,
        managed_opts(context,
          audit_callback: fn _event -> raise "DO_NOT_LOG" end,
          linear_client: never_linear_client()
        )
      )

    assert_error_code(callback_failure, "managed_read_root_denied")
    refute callback_failure["output"] =~ "DO_NOT_LOG"
  end

  test "linear_graphql falls back to inspect for successful non-JSON payloads" do
    response =
      DynamicTool.execute(
        "linear_graphql",
        %{"query" => "query Viewer { viewer { id } }"},
        linear_client: fn _query, _variables, _opts -> {:ok, :ok} end
      )

    assert response["success"] == true
    assert response["output"] == ":ok"
  end

  defp trusted_context do
    %{issue_id: "issue-123", run_id: Identity.uuid4()}
  end

  defp managed_opts(context, extra) do
    Keyword.merge([policy: :managed, trusted_context: context], extra)
  end

  defp never_linear_client do
    fn _query, _variables, _opts -> flunk("linear client should not be called") end
  end

  defp assert_error_code(response, expected_code) do
    assert response["success"] == false
    assert get_in(decode_output(response), ["error", "code"]) == expected_code
  end

  defp decode_output(response), do: Jason.decode!(response["output"])
end
