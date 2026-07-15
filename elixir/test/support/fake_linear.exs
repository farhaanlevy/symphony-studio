# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.FakeLinear do
  @moduledoc """
  Stateful loopback-only Linear GraphQL fixture.

  Operation-name extraction is test routing, not a security parser, and must
  never be reused for Studio's managed GraphQL allowlist.
  """

  import ExUnit.Assertions

  alias SymphonyElixir.TestSupport.FakeLinear.{Plug, State}

  @default_states %{
    "Todo" => "state-todo",
    "In Progress" => "state-in-progress",
    "Done" => "state-done"
  }

  @type fixture :: %{
          endpoint: String.t(),
          project_slug: String.t(),
          server: pid(),
          state: pid(),
          token: String.t()
        }

  @spec start!(keyword()) :: fixture()
  def start!(opts \\ []) do
    token = Keyword.get(opts, :token, "fake-linear-token")
    project_slug = Keyword.get(opts, :project_slug, "project")
    state_options = Keyword.put_new(opts, :states, @default_states)
    {:ok, state} = State.start_link(state_options)

    {:ok, server} =
      Bandit.start_link(
        plug: {Plug, state: state, token: token},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)

    %{
      endpoint: "http://127.0.0.1:#{port}/graphql",
      project_slug: project_slug,
      server: server,
      state: state,
      token: token
    }
  end

  @spec stop(fixture()) :: :ok
  def stop(fixture) do
    safe_stop(fixture.server, &Supervisor.stop/1)
    safe_stop(fixture.state, &GenServer.stop/1)
    :ok
  end

  @spec endpoint(fixture()) :: String.t()
  def endpoint(fixture), do: fixture.endpoint

  @spec workflow_overrides(fixture()) :: keyword()
  def workflow_overrides(fixture) do
    [
      tracker_kind: "linear",
      tracker_endpoint: fixture.endpoint,
      tracker_api_token: fixture.token,
      tracker_project_slug: fixture.project_slug
    ]
  end

  @spec issue(keyword()) :: map()
  def issue(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    identifier = Keyword.get(opts, :identifier, String.upcase(String.replace(id, "issue-", "STU-")))

    %{
      id: id,
      identifier: identifier,
      title: Keyword.get(opts, :title, "Fixture issue #{identifier}"),
      description: Keyword.get(opts, :description, "Deterministic fixture issue"),
      priority: Keyword.get(opts, :priority, 2),
      state: Keyword.get(opts, :state, "Todo"),
      project_slug: Keyword.get(opts, :project_slug, "project"),
      branch_name: Keyword.get(opts, :branch_name, "fixture/#{String.downcase(identifier)}"),
      url: Keyword.get(opts, :url, "https://linear.example.invalid/#{identifier}"),
      assignee_id: Keyword.get(opts, :assignee_id),
      labels: Keyword.get(opts, :labels, []),
      blocker_ids: Keyword.get(opts, :blocker_ids, []),
      created_at: Keyword.get(opts, :created_at, "2026-07-14T00:00:00Z"),
      updated_at: Keyword.get(opts, :updated_at, "2026-07-14T00:00:00Z"),
      revision: Keyword.get(opts, :revision, 1)
    }
  end

  @spec put_issue(fixture(), map()) :: :ok
  def put_issue(fixture, issue), do: GenServer.call(fixture.state, {:put_issue, issue})

  @spec patch_issue(fixture(), String.t(), map()) :: :ok | {:error, :not_found}
  def patch_issue(fixture, issue_id, changes) do
    GenServer.call(fixture.state, {:patch_issue, issue_id, changes})
  end

  @spec set_blockers(fixture(), String.t(), [String.t()]) :: :ok | {:error, :not_found}
  def set_blockers(fixture, issue_id, blocker_ids) do
    patch_issue(fixture, issue_id, %{blocker_ids: blocker_ids})
  end

  @spec script_next(fixture(), String.t(), term()) :: :ok
  def script_next(fixture, operation, action) do
    GenServer.call(fixture.state, {:script_next, operation, action})
  end

  @spec requests(fixture()) :: [map()]
  def requests(fixture), do: GenServer.call(fixture.state, :requests)

  @spec requests(fixture(), String.t()) :: [map()]
  def requests(fixture, operation) do
    Enum.filter(requests(fixture), &(&1.operation == operation))
  end

  @spec comments(fixture(), String.t()) :: [map()]
  def comments(fixture, issue_id), do: GenServer.call(fixture.state, {:comments, issue_id})

  @spec snapshot(fixture()) :: map()
  def snapshot(fixture), do: GenServer.call(fixture.state, :snapshot)

  @spec verify!(fixture()) :: :ok
  def verify!(fixture) do
    assert snapshot(fixture).scripts == %{}, "fake Linear has unconsumed scripted responses"
    :ok
  end

  defp safe_stop(pid, stop_fun) do
    if Process.alive?(pid) do
      try do
        stop_fun.(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end
end

defmodule SymphonyElixir.TestSupport.FakeLinear.State do
  @moduledoc false

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    issues = Keyword.get(opts, :issues, [])

    state = %{
      clock: 0,
      comments: %{},
      issue_order: Enum.map(issues, & &1.id),
      issues: Map.new(issues, &{&1.id, &1}),
      project_slug: Keyword.get(opts, :project_slug, "project"),
      requests: [],
      scripts: %{},
      states: Keyword.fetch!(opts, :states),
      viewer_id: Keyword.get(opts, :viewer_id, "viewer-fixture")
    }

    {:ok, state}
  end

  @spec dispatch(pid(), map()) :: {pos_integer(), map()}
  def dispatch(server, request), do: GenServer.call(server, {:dispatch, request})

  @impl GenServer
  def handle_call({:dispatch, request}, _from, state) do
    operation = request.operation

    {action, scripts} =
      if request.auth_valid and not Map.has_key?(request, :error) and not is_nil(operation) do
        pop_script(state.scripts, operation)
      else
        {:pass, state.scripts}
      end

    request_record = %{
      auth_valid: request.auth_valid,
      method: request.method,
      operation: operation,
      path: request.path,
      sequence: length(state.requests) + 1,
      variables: request.variables
    }

    state = %{state | requests: state.requests ++ [request_record], scripts: scripts}
    {status, body, state} = dispatch_action(action, request, state)
    {:reply, {status, body}, state}
  end

  def handle_call({:put_issue, issue}, _from, state) do
    order = if Map.has_key?(state.issues, issue.id), do: state.issue_order, else: state.issue_order ++ [issue.id]
    {:reply, :ok, %{state | issues: Map.put(state.issues, issue.id, issue), issue_order: order}}
  end

  def handle_call({:patch_issue, issue_id, changes}, _from, state) do
    case Map.fetch(state.issues, issue_id) do
      {:ok, issue} ->
        clock = state.clock + 1

        updated =
          issue
          |> Map.merge(changes)
          |> Map.put(:revision, issue.revision + 1)
          |> Map.put(:updated_at, logical_time(clock))

        {:reply, :ok, %{state | clock: clock, issues: Map.put(state.issues, issue_id, updated)}}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:script_next, operation, action}, _from, state) do
    scripts = Map.update(state.scripts, operation, [action], &(&1 ++ [action]))
    {:reply, :ok, %{state | scripts: scripts}}
  end

  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}

  def handle_call({:comments, issue_id}, _from, state) do
    {:reply, Map.get(state.comments, issue_id, []), state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      clock: state.clock,
      comments: state.comments,
      issue_order: state.issue_order,
      issues: state.issues,
      requests: state.requests,
      scripts: state.scripts,
      states: state.states
    }

    {:reply, snapshot, state}
  end

  defp pop_script(scripts, operation) do
    case Map.get(scripts, operation, []) do
      [action | rest] ->
        updated = if rest == [], do: Map.delete(scripts, operation), else: Map.put(scripts, operation, rest)
        {action, updated}

      [] ->
        {:pass, scripts}
    end
  end

  defp dispatch_action(_action, %{auth_valid: false}, state) do
    {401, %{"errors" => [%{"message" => "unauthorized"}]}, state}
  end

  defp dispatch_action(_action, %{operation: nil, error: error}, state) do
    {400, %{"errors" => [%{"message" => to_string(error)}]}, state}
  end

  defp dispatch_action(:pass, request, state), do: route(request, state)

  defp dispatch_action({:http_error, status, body}, _request, state),
    do: {status, body, state}

  defp dispatch_action({:graphql_error, code, message}, _request, state) do
    body = %{"errors" => [%{"extensions" => %{"code" => code}, "message" => message}]}
    {200, body, state}
  end

  defp dispatch_action({:response, status, body}, _request, state), do: {status, body, state}

  defp dispatch_action({:after_commit, action}, request, state) do
    {_status, _body, committed_state} = route(request, state)
    dispatch_action(action, request, committed_state)
  end

  defp route(%{operation: "SymphonyLinearPoll", variables: variables}, state) do
    matching =
      state.issue_order
      |> Enum.map(&state.issues[&1])
      |> Enum.filter(fn issue ->
        issue.project_slug == variables["projectSlug"] and issue.state in variables["stateNames"]
      end)

    offset = decode_cursor(variables["after"])
    first = variables["first"] || 50
    page = Enum.slice(matching, offset, first)
    next_offset = offset + length(page)
    has_next = next_offset < length(matching)

    body = %{
      "data" => %{
        "issues" => %{
          "nodes" => Enum.map(page, &render_issue(&1, state)),
          "pageInfo" => %{
            "hasNextPage" => has_next,
            "endCursor" => if(has_next, do: "offset:#{next_offset}", else: nil)
          }
        }
      }
    }

    {200, body, state}
  end

  defp route(%{operation: "SymphonyLinearIssuesById", variables: variables}, state) do
    nodes =
      variables["ids"]
      |> Enum.flat_map(fn id ->
        case Map.fetch(state.issues, id) do
          {:ok, issue} -> [render_issue(issue, state)]
          :error -> []
        end
      end)

    {200, %{"data" => %{"issues" => %{"nodes" => nodes}}}, state}
  end

  defp route(%{operation: "SymphonyLinearViewer"}, state) do
    {200, %{"data" => %{"viewer" => %{"id" => state.viewer_id}}}, state}
  end

  defp route(%{operation: "SymphonyCreateComment", variables: variables}, state) do
    issue_id = variables["issueId"]
    existing = Map.get(state.comments, issue_id, [])
    comment = %{"body" => variables["body"], "id" => "comment-#{length(existing) + 1}"}
    comments = Map.put(state.comments, issue_id, existing ++ [comment])
    {200, %{"data" => %{"commentCreate" => %{"success" => true}}}, %{state | comments: comments}}
  end

  defp route(%{operation: "SymphonyResolveStateId", variables: variables}, state) do
    nodes =
      case Map.fetch(state.states, variables["stateName"]) do
        {:ok, state_id} -> [%{"id" => state_id}]
        :error -> []
      end

    body = %{"data" => %{"issue" => %{"team" => %{"states" => %{"nodes" => nodes}}}}}
    {200, body, state}
  end

  defp route(%{operation: "SymphonyUpdateIssueState", variables: variables}, state) do
    state_name =
      Enum.find_value(state.states, fn {name, id} -> if id == variables["stateId"], do: name end)

    case {Map.fetch(state.issues, variables["issueId"]), state_name} do
      {{:ok, issue}, name} when is_binary(name) ->
        clock = state.clock + 1

        updated =
          issue
          |> Map.put(:state, name)
          |> Map.put(:revision, issue.revision + 1)
          |> Map.put(:updated_at, logical_time(clock))

        new_state = %{state | clock: clock, issues: Map.put(state.issues, issue.id, updated)}
        {200, %{"data" => %{"issueUpdate" => %{"success" => true}}}, new_state}

      _ ->
        {200, %{"data" => %{"issueUpdate" => %{"success" => false}}}, state}
    end
  end

  defp route(%{operation: operation}, state) do
    {400, %{"errors" => [%{"message" => "unregistered operation #{operation}"}]}, state}
  end

  defp render_issue(issue, state) do
    blockers =
      Enum.flat_map(issue.blocker_ids, fn blocker_id ->
        case Map.fetch(state.issues, blocker_id) do
          {:ok, blocker} ->
            [
              %{
                "type" => "blocks",
                "issue" => %{
                  "id" => blocker.id,
                  "identifier" => blocker.identifier,
                  "state" => %{"name" => blocker.state}
                }
              }
            ]

          :error ->
            []
        end
      end)

    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "priority" => issue.priority,
      "state" => %{"name" => issue.state},
      "branchName" => issue.branch_name,
      "url" => issue.url,
      "assignee" => if(issue.assignee_id, do: %{"id" => issue.assignee_id}, else: nil),
      "labels" => %{"nodes" => Enum.map(issue.labels, &%{"name" => &1})},
      "inverseRelations" => %{"nodes" => blockers},
      "createdAt" => issue.created_at,
      "updatedAt" => issue.updated_at
    }
  end

  defp decode_cursor(nil), do: 0

  defp decode_cursor("offset:" <> offset) do
    case Integer.parse(offset) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp decode_cursor(_cursor), do: 0

  defp logical_time(clock) do
    ~U[2026-07-14 00:00:00Z]
    |> DateTime.add(clock, :second)
    |> DateTime.to_iso8601()
  end
end

defmodule SymphonyElixir.TestSupport.FakeLinear.Plug do
  @moduledoc false

  import Plug.Conn

  alias SymphonyElixir.TestSupport.FakeLinear.State

  @operation_regex ~r/\b(?:query|mutation)\s+([_A-Za-z][_0-9A-Za-z]*)\b/
  @operation_documents %{
    "SymphonyLinearPoll" => """
    query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
      issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
        nodes {
          id
          identifier
          title
          description
          priority
          state {
            name
          }
          branchName
          url
          assignee {
            id
          }
          labels {
            nodes {
              name
            }
          }
          inverseRelations(first: $relationFirst) {
            nodes {
              type
              issue {
                id
                identifier
                state {
                  name
                }
              }
            }
          }
          createdAt
          updatedAt
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
    """,
    "SymphonyLinearIssuesById" => """
    query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
      issues(filter: {id: {in: $ids}}, first: $first) {
        nodes {
          id
          identifier
          title
          description
          priority
          state {
            name
          }
          branchName
          url
          assignee {
            id
          }
          labels {
            nodes {
              name
            }
          }
          inverseRelations(first: $relationFirst) {
            nodes {
              type
              issue {
                id
                identifier
                state {
                  name
                }
              }
            }
          }
          createdAt
          updatedAt
        }
      }
    }
    """,
    "SymphonyLinearViewer" => """
    query SymphonyLinearViewer {
      viewer {
        id
      }
    }
    """,
    "SymphonyCreateComment" => """
    mutation SymphonyCreateComment($issueId: String!, $body: String!) {
      commentCreate(input: {issueId: $issueId, body: $body}) {
        success
      }
    }
    """,
    "SymphonyResolveStateId" => """
    query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
      issue(id: $issueId) {
        team {
          states(filter: {name: {eq: $stateName}}, first: 1) {
            nodes {
              id
            }
          }
        }
      }
    }
    """,
    "SymphonyUpdateIssueState" => """
    mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: {stateId: $stateId}) {
        success
      }
    }
    """
  }
  @operation_variable_contracts %{
    "SymphonyLinearPoll" => %{
      required: %{
        "first" => :integer,
        "projectSlug" => :string,
        "relationFirst" => :integer,
        "stateNames" => {:list, :string}
      },
      optional: %{"after" => {:nullable, :string}}
    },
    "SymphonyLinearIssuesById" => %{
      required: %{
        "first" => :integer,
        "ids" => {:list, :string},
        "relationFirst" => :integer
      },
      optional: %{}
    },
    "SymphonyLinearViewer" => %{required: %{}, optional: %{}},
    "SymphonyCreateComment" => %{
      required: %{"body" => :string, "issueId" => :string},
      optional: %{}
    },
    "SymphonyResolveStateId" => %{
      required: %{"issueId" => :string, "stateName" => :string},
      optional: %{}
    },
    "SymphonyUpdateIssueState" => %{
      required: %{"issueId" => :string, "stateId" => :string},
      optional: %{}
    }
  }

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST", request_path: "/graphql"} = conn, opts) do
    {:ok, body, conn} = read_complete_body(conn, "")
    token = Keyword.fetch!(opts, :token)
    state = Keyword.fetch!(opts, :state)
    auth_valid = get_req_header(conn, "authorization") == [token]
    request = parse_request(body, conn, auth_valid)

    {status, response} = State.dispatch(state, request)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(response))
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(405, Jason.encode!(%{"errors" => [%{"message" => "method not allowed"}]}))
  end

  defp read_complete_body(conn, acc) do
    case read_body(conn) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_complete_body(conn, acc <> body)
      {:error, reason} -> raise "fake Linear body read failed: #{inspect(reason)}"
    end
  end

  defp parse_request(body, conn, auth_valid) do
    case Jason.decode(body) do
      {:ok, %{"query" => query} = payload} when is_binary(query) ->
        route_payload(query, payload, conn, auth_valid)

      _ ->
        invalid_request(conn, auth_valid, %{}, :malformed_json)
    end
  end

  defp route_payload(query, payload, conn, auth_valid) do
    operations = Regex.scan(@operation_regex, query, capture: :all_but_first) |> List.flatten()
    operation_name = Map.get(payload, "operationName")
    raw_variables = Map.get(payload, "variables")

    case validate_routed_payload(query, payload, operations, operation_name, raw_variables) do
      {:ok, operation, variables} ->
        base_request(conn, auth_valid, operation, variables)

      {:error, error, variables} ->
        invalid_request(conn, auth_valid, variables, error)
    end
  end

  defp validate_routed_payload(query, payload, operations, operation_name, raw_variables) do
    with :ok <- validate_envelope_keys(payload),
         :ok <- validate_operation_name(operation_name),
         {:ok, variables} <- normalize_variables(raw_variables),
         {:ok, operation, variables} <- select_operation(operations, operation_name, variables),
         {:ok, operation, variables} <-
           validate_routed_operation(operation, query, variables) do
      {:ok, operation, variables}
    else
      {:error, error} -> {:error, error, %{}}
      {:error, error, variables} -> {:error, error, variables}
    end
  end

  defp validate_envelope_keys(payload) do
    if Map.keys(payload) -- ["operationName", "query", "variables"] == [],
      do: :ok,
      else: {:error, :invalid_envelope_keys}
  end

  defp validate_operation_name(nil), do: :ok
  defp validate_operation_name(operation_name) when is_binary(operation_name), do: :ok
  defp validate_operation_name(_operation_name), do: {:error, :invalid_operation_name}

  defp normalize_variables(nil), do: {:ok, %{}}
  defp normalize_variables(variables) when is_map(variables), do: {:ok, variables}
  defp normalize_variables(_variables), do: {:error, :invalid_variables}

  defp select_operation([operation], nil, variables),
    do: {:ok, operation, variables}

  defp select_operation([operation], operation, variables),
    do: {:ok, operation, variables}

  defp select_operation(_operations, operation_name, variables)
       when is_binary(operation_name),
       do: {:error, :operation_name_mismatch, variables}

  defp select_operation(_operations, nil, variables),
    do: {:error, :expected_one_named_operation, variables}

  defp validate_routed_operation(operation, query, variables) do
    case validate_operation_contract(operation, query, variables) do
      :ok -> {:ok, operation, variables}
      {:error, error} -> {:error, error, variables}
    end
  end

  defp validate_operation_contract(operation, query, variables) do
    with {:ok, expected_document} <- Map.fetch(@operation_documents, operation),
         true <- canonical_document(query) == canonical_document(expected_document),
         :ok <- validate_operation_variables(operation, variables) do
      :ok
    else
      :error -> {:error, :unregistered_operation}
      false -> {:error, :query_document_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_operation_variables(operation, variables) do
    %{required: required, optional: optional} = Map.fetch!(@operation_variable_contracts, operation)
    allowed_keys = Map.keys(required) ++ Map.keys(optional)

    valid? =
      Map.keys(variables) -- allowed_keys == [] and
        Enum.all?(required, fn {key, type} ->
          case Map.fetch(variables, key) do
            {:ok, value} -> valid_variable?(type, value)
            :error -> false
          end
        end) and
        Enum.all?(optional, fn {key, type} ->
          case Map.fetch(variables, key) do
            {:ok, value} -> valid_variable?(type, value)
            :error -> true
          end
        end)

    if valid?, do: :ok, else: {:error, :invalid_operation_variables}
  end

  defp valid_variable?(:string, value), do: is_binary(value)

  defp valid_variable?(:integer, value) do
    is_integer(value) and value >= -2_147_483_648 and value <= 2_147_483_647
  end

  defp valid_variable?({:list, type}, value) when is_list(value),
    do: Enum.all?(value, &valid_variable?(type, &1))

  defp valid_variable?({:list, _type}, _value), do: false
  defp valid_variable?({:nullable, _type}, nil), do: true
  defp valid_variable?({:nullable, type}, value), do: valid_variable?(type, value)

  defp canonical_document(document) do
    document
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/\s*([!$():,=@\[\]{}|&])\s*/, "\\1")
  end

  defp base_request(conn, auth_valid, operation, variables) do
    %{
      auth_valid: auth_valid,
      method: conn.method,
      operation: operation,
      path: conn.request_path,
      variables: variables
    }
  end

  defp invalid_request(conn, auth_valid, variables, error) do
    conn
    |> base_request(auth_valid, nil, variables)
    |> Map.put(:error, error)
  end
end
