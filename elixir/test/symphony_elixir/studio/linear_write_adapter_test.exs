# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteAdapterTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Studio.Intent.Store
  alias SymphonyElixir.Studio.IntentService
  alias SymphonyElixir.Studio.LinearWriteBroker
  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Linear, Result}

  defmodule FakeTransport do
    use Agent

    @behaviour SymphonyElixir.Studio.LinearWriteBroker.Transport

    @project_id "project-studio"
    @project_slug "symphony-studio-build-week-3f2698765546"
    @team_id "team-studio"
    @backlog_id "state-backlog"
    @todo_id "state-todo"

    @spec start_link(keyword()) :: Agent.on_start()
    def start_link(opts \\ []) do
      Agent.start_link(fn ->
        %{
          calls: [],
          fail_after: Keyword.get(opts, :fail_after),
          issues: fixture_issues(),
          next_number: 3,
          relations: %{}
        }
      end)
    end

    @spec calls(Agent.agent()) :: [map()]
    def calls(server), do: Agent.get(server, &Enum.reverse(&1.calls))

    @spec issues(Agent.agent()) :: [map()]
    def issues(server), do: Agent.get(server, &Map.values(&1.issues))

    @impl true
    def graphql(server, query, variables) do
      Agent.get_and_update(server, fn state -> dispatch(query, variables, state) end)
    end

    defp dispatch(query, variables, state) do
      operation = operation(query)
      state = %{state | calls: [%{operation: operation, variables: variables} | state.calls]}

      case operation do
        :binding -> {binding_response(), state}
        :issue -> issue_response(variables, state)
        :relation -> relation_response(variables, state)
        :issue_create -> create_issue(variables, state)
        :relation_create -> create_relation(variables, state)
        :issue_update -> update_issue(variables, state)
        :unknown -> {{:error, :unexpected_operation}, state}
      end
    end

    defp operation(query) do
      cond do
        String.contains?(query, "query SymphonyStudioWriteBinding") -> :binding
        String.contains?(query, "query SymphonyStudioWriteIssue(") -> :issue
        String.contains?(query, "query SymphonyStudioWriteRelation") -> :relation
        String.contains?(query, "mutation SymphonyStudioWriteIssueCreate") -> :issue_create
        String.contains?(query, "mutation SymphonyStudioWriteRelationCreate") -> :relation_create
        String.contains?(query, "mutation SymphonyStudioWriteIssueUpdate") -> :issue_update
        true -> :unknown
      end
    end

    defp binding_response do
      {:ok,
       %{
         "data" => %{
           "projects" => %{
             "nodes" => [
               %{
                 "id" => @project_id,
                 "slugId" => @project_slug,
                 "teams" => %{
                   "nodes" => [
                     %{
                       "id" => @team_id,
                       "key" => "SYM",
                       "name" => "Symphony Studio",
                       "states" => %{
                         "nodes" => [
                           %{"id" => @backlog_id, "name" => "Backlog", "type" => "backlog"},
                           %{"id" => @todo_id, "name" => "Todo", "type" => "unstarted"}
                         ],
                         "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
                       }
                     }
                   ],
                   "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
                 }
               }
             ],
             "pageInfo" => %{"endCursor" => nil, "hasNextPage" => false}
           }
         }
       }}
    end

    defp issue_response(%{"id" => id}, state) do
      {{:ok, %{"data" => %{"issue" => Map.get(state.issues, id)}}}, state}
    end

    defp relation_response(%{"id" => id}, state) do
      {{:ok, %{"data" => %{"issueRelation" => Map.get(state.relations, id)}}}, state}
    end

    defp create_issue(%{"input" => input}, state) do
      identifier = "SYM-#{state.next_number}"
      issue = issue(input["id"], identifier, input["title"], input["description"], @backlog_id, "Backlog")
      next = %{state | issues: Map.put(state.issues, issue["id"], issue), next_number: state.next_number + 1}
      response = {:ok, %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}}}
      maybe_fail_after(:issue_create, response, next)
    end

    defp create_relation(%{"input" => input}, state) do
      prerequisite = Map.fetch!(state.issues, input["issueId"])
      dependent = Map.fetch!(state.issues, input["relatedIssueId"])

      relation = %{
        "id" => input["id"],
        "type" => input["type"],
        "issue" => relation_issue(prerequisite),
        "relatedIssue" => relation_issue(dependent)
      }

      next = %{state | relations: Map.put(state.relations, relation["id"], relation)}

      response =
        {:ok,
         %{
           "data" => %{
             "issueRelationCreate" => %{"success" => true, "issueRelation" => relation}
           }
         }}

      maybe_fail_after(:relation_create, response, next)
    end

    defp update_issue(%{"id" => id, "stateId" => @todo_id}, state) do
      issue = state.issues |> Map.fetch!(id) |> put_in(["state"], state(@todo_id, "Todo", "unstarted"))
      next = %{state | issues: Map.put(state.issues, id, issue)}
      response = {:ok, %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => issue}}}}
      maybe_fail_after(:issue_update, response, next)
    end

    defp maybe_fail_after(operation, _response, %{fail_after: operation} = state) do
      {{:error, :simulated_lost_response}, %{state | fail_after: nil}}
    end

    defp maybe_fail_after(_operation, response, state), do: {response, state}

    defp fixture_issues do
      %{
        "fixture-1" => issue("fixture-1", "SYM-1", "Protected fixture one", "fixture", @backlog_id, "Backlog"),
        "fixture-2" => issue("fixture-2", "SYM-2", "Protected fixture two", "fixture", @backlog_id, "Backlog")
      }
    end

    defp issue(id, identifier, title, description, state_id, state_name) do
      %{
        "description" => description,
        "id" => id,
        "identifier" => identifier,
        "project" => %{"id" => @project_id, "slugId" => @project_slug},
        "state" => state(state_id, state_name, if(state_name == "Backlog", do: "backlog", else: "unstarted")),
        "team" => %{"id" => @team_id, "key" => "SYM", "name" => "Symphony Studio"},
        "title" => title
      }
    end

    defp state(id, name, type), do: %{"id" => id, "name" => name, "type" => type}

    defp relation_issue(issue) do
      Map.take(issue, ["description", "id", "identifier", "project", "team"])
    end
  end

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    project_root = Path.join(System.tmp_dir!(), "linear-adapter-project-#{unique}")
    data_root = Path.join(System.tmp_dir!(), "linear-adapter-data-#{unique}")
    File.mkdir_p!(Path.join(project_root, "lib"))
    File.write!(Path.join(project_root, "README.md"), "# Adapter test project\n")
    File.write!(Path.join(project_root, "lib/example.ex"), "defmodule Example do\nend\n")
    {:ok, store} = Store.open(root: data_root)
    {:ok, transport} = FakeTransport.start_link()

    on_exit(fn ->
      File.rm_rf(project_root)
      File.rm_rf(data_root)
    end)

    %{project_root: project_root, store: store, transport: transport}
  end

  test "publishes approved tasks once in Backlog, creates only blocks relations, and starts one Todo issue", ctx do
    opts = [store: ctx.store, broker: Linear.target({FakeTransport, ctx.transport})]
    ready = approved_intent(ctx.project_root, opts)
    task_count = length(ready["proposal"]["tasks"])
    relation_count = Enum.sum(Enum.map(ready["proposal"]["tasks"], &length(&1["depends_on"])))

    {:ok, published} = IntentService.publish_approved_plan(ready["intent_id"], "publish-real-1", opts)
    assert published["publication"]["status"] == "complete"
    assert map_size(published["publication"]["tasks"]) == task_count
    assert map_size(published["publication"]["relations"]) == relation_count

    mutation_calls = mutation_calls(ctx.transport)
    assert Enum.count(mutation_calls, &(&1.operation == :issue_create)) == task_count
    assert Enum.count(mutation_calls, &(&1.operation == :relation_create)) == relation_count
    assert Enum.all?(managed_issues(ctx.transport), &(get_in(&1, ["state", "name"]) == "Backlog"))

    {:ok, replayed} = IntentService.publish_approved_plan(ready["intent_id"], "publish-real-2", opts)
    assert replayed["publication"]["status"] == "complete"
    assert mutation_calls(ctx.transport) == mutation_calls

    {:ok, waiting} =
      IntentService.start_first_ready(
        ready["intent_id"],
        "start_first_ready",
        "start-real-1",
        opts
      )

    assert waiting["start"]["status"] == "waiting_for_admission"
    assert waiting["start"]["issue_identifier"] not in ["SYM-1", "SYM-2"]

    managed = managed_issues(ctx.transport)
    assert Enum.count(managed, &(get_in(&1, ["state", "name"]) == "Todo")) == 1
    assert Enum.count(managed, &(get_in(&1, ["state", "name"]) == "Backlog")) == task_count - 1

    names = mutation_calls(ctx.transport) |> Enum.map(& &1.operation) |> MapSet.new()
    assert names == MapSet.new([:issue_create, :relation_create, :issue_update])
  end

  test "client-generated issue identity reconciles a lost create response without a duplicate" do
    {:ok, transport} = FakeTransport.start_link(fail_after: :issue_create)
    broker = Linear.target({FakeTransport, transport})
    digest = String.duplicate("a", 64)

    {:ok, command} =
      Command.issue("intent_12345678", digest, %{
        "acceptance_criteria" => ["The adapter proves exact idempotency."],
        "depends_on" => [],
        "description" => "Create one deterministic test issue.",
        "id" => "task_12345678",
        "title" => "Prove deterministic issue creation"
      })

    assert {:ok, %Result{status: :absent}} = LinearWriteBroker.reconcile(broker, command)
    assert {:ok, %Result{status: :uncertain}} = LinearWriteBroker.execute(broker, command)

    assert {:ok, %Result{status: :confirmed, issue_identifier: identifier}} =
             LinearWriteBroker.reconcile(broker, command)

    assert String.starts_with?(identifier, "SYM-")
    assert Enum.count(mutation_calls(transport), &(&1.operation == :issue_create)) == 1
  end

  test "rejects protected fixture relation endpoints before any mutation", ctx do
    digest = String.duplicate("b", 64)

    {:ok, command} =
      Command.relation(
        "intent_12345678",
        digest,
        "task_abcdefgh",
        %{"issue_id" => "fixture-1"},
        %{"issue_id" => "fixture-2"}
      )

    assert {:error, :protected_linear_issue_denied} =
             LinearWriteBroker.execute(Linear.target({FakeTransport, ctx.transport}), command)

    assert mutation_calls(ctx.transport) == []
  end

  test "transport contract contains no comment, label, admin, or arbitrary mutation", ctx do
    opts = [store: ctx.store, broker: Linear.target({FakeTransport, ctx.transport})]
    ready = approved_intent(ctx.project_root, opts)
    {:ok, _published} = IntentService.publish_approved_plan(ready["intent_id"], "publish-contract", opts)

    queries = FakeTransport.calls(ctx.transport)
    mutation_names = queries |> Enum.filter(&mutation?/1) |> Enum.map(& &1.operation) |> MapSet.new()
    assert mutation_names == MapSet.new([:issue_create, :relation_create])

    inspected = inspect(queries)
    refute inspected =~ "comment"
    refute inspected =~ "label"
    refute inspected =~ "admin"
  end

  defp approved_intent(project_root, opts) do
    suffix = System.unique_integer([:positive, :monotonic])
    {:ok, attached} = IntentService.attach_project(project_root, "attach-#{suffix}", opts)

    {:ok, submitted} =
      IntentService.submit_intent(
        attached["project"]["project_id"],
        %{
          "kind" => "markdown",
          "content" => """
          Build a reliable operator workflow with deterministic evidence.

          - Present the approved result to the operator
          - Verify the workflow with repository tests

          Do not change unrelated infrastructure.
          """
        },
        "submit-#{suffix}",
        opts
      )

    proposed =
      if submitted["lifecycle_state"] == "clarification_required" do
        {:ok, answered} =
          IntentService.answer_clarifications(
            submitted["intent_id"],
            %{"use_recommended_defaults" => true},
            "answer-#{suffix}",
            opts
          )

        answered
      else
        submitted
      end

    {:ok, presented} =
      IntentService.present_proposal(proposed["intent_id"], "present-#{suffix}", opts)

    {:ok, approved} =
      IntentService.approve_publication(
        proposed["intent_id"],
        presented["proposal"]["digest"],
        "publish_linear_backlog",
        "approve-#{suffix}",
        opts
      )

    approved
  end

  defp mutation_calls(server), do: Enum.filter(FakeTransport.calls(server), &mutation?/1)

  defp mutation?(%{operation: operation}),
    do: operation in [:issue_create, :relation_create, :issue_update]

  defp managed_issues(server) do
    server
    |> FakeTransport.issues()
    |> Enum.reject(&(&1["identifier"] in ["SYM-1", "SYM-2"]))
  end
end
