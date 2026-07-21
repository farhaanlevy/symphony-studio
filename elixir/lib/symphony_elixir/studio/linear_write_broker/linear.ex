# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Linear do
  @moduledoc """
  Production least-privilege Linear adapter for approved Studio intent plans.

  The adapter is bound to the dedicated Symphony Studio project and team. It
  supports exactly three mutations: issue creation in Backlog, `blocks`
  relation creation, and moving the selected first-ready issue to Todo. Exact
  client-generated UUIDs make issue and relation reconciliation idempotent.
  """

  import Bitwise

  @behaviour SymphonyElixir.Studio.LinearWriteBroker

  alias SymphonyElixir.Studio.LinearWriteBroker
  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Result, Transport}

  @project_slug "symphony-studio-build-week-3f2698765546"
  @team_name "Symphony Studio"
  @team_key "SYM"
  @backlog_state "Backlog"
  @todo_state "Todo"
  @provider "linear"
  @max_id_bytes 256
  @max_identifier_bytes 64

  @binding_query """
  query SymphonyStudioWriteBinding($projectSlug: String!, $first: Int!, $nestedFirst: Int!) {
    projects(filter: {slugId: {eq: $projectSlug}}, first: $first) {
      nodes {
        id
        slugId
        teams(first: $nestedFirst) {
          nodes {
            id
            key
            name
            states(first: $nestedFirst) {
              nodes { id name type }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  @issue_query """
  query SymphonyStudioWriteIssue($id: String!) {
    issue(id: $id) {
      id
      identifier
      title
      description
      project { id slugId }
      team { id key name }
      state { id name type }
    }
  }
  """

  @relation_query """
  query SymphonyStudioWriteRelation($id: String!) {
    issueRelation(id: $id) {
      id
      type
      issue {
        id
        identifier
        description
        project { id slugId }
        team { id key name }
      }
      relatedIssue {
        id
        identifier
        description
        project { id slugId }
        team { id key name }
      }
    }
  }
  """

  @issue_create_mutation """
  mutation SymphonyStudioWriteIssueCreate($input: IssueCreateInput!) {
    issueCreate(input: $input) {
      success
      issue {
        id
        identifier
        title
        description
        project { id slugId }
        team { id key name }
        state { id name type }
      }
    }
  }
  """

  @relation_create_mutation """
  mutation SymphonyStudioWriteRelationCreate($input: IssueRelationCreateInput!) {
    issueRelationCreate(input: $input) {
      success
      issueRelation {
        id
        type
        issue { id identifier }
        relatedIssue { id identifier }
      }
    }
  }
  """

  @issue_update_mutation """
  mutation SymphonyStudioWriteIssueUpdate($id: String!, $stateId: String!) {
    issueUpdate(id: $id, input: {stateId: $stateId}) {
      success
      issue {
        id
        identifier
        project { id slugId }
        team { id key name }
        state { id name type }
      }
    }
  }
  """

  @enforce_keys [:transport]
  defstruct @enforce_keys

  @type t :: %__MODULE__{transport: {module(), term()}}

  @doc "Returns the production broker target without reading either Linear credential."
  @spec target() :: LinearWriteBroker.target()
  def target, do: {__MODULE__, %__MODULE__{transport: Transport.target()}}

  @doc "Returns an explicitly injected transport target for deterministic contract tests."
  @spec target({module(), term()}) :: LinearWriteBroker.target()
  def target({module, _server} = transport) when is_atom(module) do
    {__MODULE__, %__MODULE__{transport: transport}}
  end

  @impl true
  def reconcile(%__MODULE__{} = adapter, %Command{kind: :issue} = command),
    do: reconcile_issue(adapter, command)

  def reconcile(%__MODULE__{} = adapter, %Command{kind: :relation} = command),
    do: reconcile_relation(adapter, command)

  def reconcile(%__MODULE__{} = adapter, %Command{kind: :transition} = command),
    do: reconcile_transition(adapter, command)

  @impl true
  def execute(%__MODULE__{} = adapter, %Command{kind: :issue} = command),
    do: execute_issue(adapter, command)

  def execute(%__MODULE__{} = adapter, %Command{kind: :relation} = command),
    do: execute_relation(adapter, command)

  def execute(%__MODULE__{} = adapter, %Command{kind: :transition} = command),
    do: execute_transition(adapter, command)

  defp reconcile_issue(adapter, command) do
    id = external_uuid(command.idempotency_key)

    with {:ok, issue} <- fetch_issue(adapter, id) do
      case issue do
        nil -> {:ok, Result.absent(@provider)}
        issue -> confirmed_issue_result(command, id, issue)
      end
    end
  end

  defp execute_issue(adapter, command) do
    id = external_uuid(command.idempotency_key)

    with {:ok, binding} <- fetch_binding(adapter) do
      input = %{
        "description" => command.payload["description"],
        "id" => id,
        "projectId" => binding.project_id,
        "stateId" => binding.backlog_state_id,
        "teamId" => binding.team_id,
        "title" => command.payload["title"]
      }

      execute_issue_mutation(adapter, command, id, input)
    end
  end

  defp execute_issue_mutation(adapter, command, id, input) do
    with {:ok, body} <- graphql(adapter, @issue_create_mutation, %{"input" => input}),
         %{"data" => %{"issueCreate" => %{"success" => true, "issue" => issue}}} <- body do
      command
      |> confirmed_issue_result(id, issue)
      |> confirm_after_mutation()
    else
      {:error, reason} -> uncertain(reason)
      _malformed -> uncertain(:malformed_issue_create_response)
    end
  end

  defp confirmed_issue_result(command, expected_id, issue) do
    with :ok <- validate_managed_issue(issue, command, expected_id, @backlog_state) do
      {:ok,
       %Result{
         status: :confirmed,
         provider: @provider,
         external_id: issue["id"],
         issue_identifier: issue["identifier"],
         details: %{"outcome" => "created", "state" => @backlog_state}
       }}
    end
  end

  defp reconcile_relation(adapter, command) do
    id = external_uuid(command.idempotency_key)

    with {:ok, relation} <- fetch_relation(adapter, id) do
      case relation do
        nil -> {:ok, Result.absent(@provider)}
        relation -> confirmed_relation_result(command, id, relation)
      end
    end
  end

  defp execute_relation(adapter, command) do
    id = external_uuid(command.idempotency_key)
    prerequisite_id = command.payload["prerequisite_issue_id"]
    dependent_id = command.payload["dependent_issue_id"]

    with {:ok, prerequisite} <- fetch_issue(adapter, prerequisite_id),
         {:ok, dependent} <- fetch_issue(adapter, dependent_id),
         :ok <- validate_relation_endpoint(prerequisite, command, prerequisite_id),
         :ok <- validate_relation_endpoint(dependent, command, dependent_id) do
      input = %{
        "id" => id,
        "issueId" => prerequisite_id,
        "relatedIssueId" => dependent_id,
        "type" => "blocks"
      }

      execute_relation_mutation(adapter, command, id, input)
    end
  end

  defp execute_relation_mutation(adapter, command, id, input) do
    with {:ok, body} <- graphql(adapter, @relation_create_mutation, %{"input" => input}),
         %{
           "data" => %{
             "issueRelationCreate" => %{"success" => true, "issueRelation" => relation}
           }
         } <- body do
      command
      |> confirmed_relation_result(id, relation)
      |> confirm_after_mutation()
    else
      {:error, reason} -> uncertain(reason)
      _malformed -> uncertain(:malformed_relation_create_response)
    end
  end

  defp confirmed_relation_result(command, expected_id, relation) do
    prerequisite_id = command.payload["prerequisite_issue_id"]
    dependent_id = command.payload["dependent_issue_id"]

    with %{
           "id" => ^expected_id,
           "type" => "blocks",
           "issue" => %{"id" => ^prerequisite_id, "identifier" => prerequisite_identifier},
           "relatedIssue" => %{"id" => ^dependent_id, "identifier" => dependent_identifier}
         } <- relation,
         :ok <- deny_protected_identifiers([prerequisite_identifier, dependent_identifier]) do
      {:ok,
       %Result{
         status: :confirmed,
         provider: @provider,
         external_id: expected_id,
         issue_identifier: nil,
         details: %{"outcome" => "created", "relation" => "blocks"}
       }}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :rejected}
    end
  end

  defp reconcile_transition(adapter, command) do
    issue_id = command.payload["issue_id"]

    with {:ok, issue} <- fetch_issue(adapter, issue_id),
         :ok <- validate_transition_issue(issue, command, issue_id) do
      case get_in(issue, ["state", "name"]) do
        @todo_state -> confirmed_transition_result(command, issue)
        @backlog_state -> {:ok, Result.absent(@provider)}
        _other -> {:error, :rejected}
      end
    end
  end

  defp execute_transition(adapter, command) do
    issue_id = command.payload["issue_id"]

    with {:ok, binding} <- fetch_binding(adapter),
         {:ok, issue} <- fetch_issue(adapter, issue_id),
         :ok <- validate_transition_issue(issue, command, issue_id),
         @backlog_state <- get_in(issue, ["state", "name"]) do
      execute_transition_mutation(adapter, command, issue_id, binding.todo_state_id)
    else
      {:error, :protected_linear_issue_denied} -> {:error, :protected_linear_issue_denied}
      {:error, _reason} = error -> error
      _unexpected_state -> {:error, :rejected}
    end
  end

  defp execute_transition_mutation(adapter, command, issue_id, todo_state_id) do
    with {:ok, body} <-
           graphql(adapter, @issue_update_mutation, %{
             "id" => issue_id,
             "stateId" => todo_state_id
           }),
         %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => updated}}} <- body do
      command
      |> confirmed_transition_result(updated)
      |> confirm_after_mutation()
    else
      {:error, reason} -> uncertain(reason)
      _malformed -> uncertain(:malformed_issue_update_response)
    end
  end

  defp confirmed_transition_result(command, issue) do
    expected_id = command.payload["issue_id"]
    expected_identifier = command.payload["issue_identifier"]

    with :ok <- validate_issue_binding(issue),
         %{
           "id" => ^expected_id,
           "identifier" => ^expected_identifier,
           "state" => %{"name" => @todo_state}
         } <- issue,
         :ok <- deny_protected_identifiers([expected_identifier]) do
      {:ok,
       %Result{
         status: :confirmed,
         provider: @provider,
         external_id: expected_id,
         issue_identifier: expected_identifier,
         details: %{"outcome" => "transitioned", "state" => @todo_state}
       }}
    else
      {:error, _reason} = error -> error
      _mismatch -> {:error, :rejected}
    end
  end

  defp fetch_binding(adapter) do
    with {:ok, body} <-
           graphql(adapter, @binding_query, %{
             "first" => 2,
             "nestedFirst" => 64,
             "projectSlug" => @project_slug
           }),
         %{
           "data" => %{
             "projects" => %{
               "nodes" => [project],
               "pageInfo" => %{"hasNextPage" => false}
             }
           }
         } <- body,
         {:ok, binding} <- decode_binding(project) do
      {:ok, binding}
    else
      {:error, _reason} = error -> error
      _malformed -> {:error, :project_binding_rejected}
    end
  end

  defp decode_binding(%{
         "id" => project_id,
         "slugId" => slug,
         "teams" => %{
           "nodes" => [
             %{
               "id" => team_id,
               "key" => @team_key,
               "name" => @team_name,
               "states" => %{
                 "nodes" => states,
                 "pageInfo" => %{"hasNextPage" => false}
               }
             }
           ],
           "pageInfo" => %{"hasNextPage" => false}
         }
       })
       when is_list(states) do
    with true <- valid_id?(project_id),
         true <- project_slug_matches?(slug),
         true <- valid_id?(team_id),
         {:ok, backlog_id} <- unique_state_id(states, @backlog_state),
         {:ok, todo_id} <- unique_state_id(states, @todo_state),
         true <- backlog_id != todo_id do
      {:ok,
       %{
         backlog_state_id: backlog_id,
         project_id: project_id,
         team_id: team_id,
         todo_state_id: todo_id
       }}
    else
      _invalid -> {:error, :project_binding_rejected}
    end
  end

  defp decode_binding(_invalid), do: {:error, :project_binding_rejected}

  defp unique_state_id(states, name) do
    case Enum.filter(states, &match?(%{"id" => _, "name" => ^name}, &1)) do
      [%{"id" => id}] -> if(valid_id?(id), do: {:ok, id}, else: {:error, :invalid_state})
      _missing_or_duplicate -> {:error, :invalid_state}
    end
  end

  defp fetch_issue(adapter, id) do
    case graphql(adapter, @issue_query, %{"id" => id}) do
      {:ok, %{"data" => %{"issue" => issue}}} when is_map(issue) or is_nil(issue) -> {:ok, issue}
      {:ok, _malformed} -> {:error, :malformed_issue_response}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_relation(adapter, id) do
    case graphql(adapter, @relation_query, %{"id" => id}) do
      {:ok, %{"data" => %{"issueRelation" => relation}}}
      when is_map(relation) or is_nil(relation) ->
        {:ok, relation}

      {:ok, _malformed} ->
        {:error, :malformed_relation_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_managed_issue(issue, command, expected_id, expected_state) do
    with :ok <- validate_issue_binding(issue),
         %{
           "id" => ^expected_id,
           "identifier" => identifier,
           "title" => title,
           "description" => description,
           "state" => %{"name" => ^expected_state}
         } <- issue,
         true <- valid_identifier?(identifier),
         false <- LinearWriteBroker.protected_identifier?(identifier),
         true <- title == command.payload["title"],
         true <- description == command.payload["description"] do
      :ok
    else
      true -> {:error, :protected_linear_issue_denied}
      {:error, _reason} = error -> error
      _mismatch -> {:error, :rejected}
    end
  end

  defp validate_relation_endpoint(issue, command, expected_id) do
    marker_prefix =
      "Idempotency marker: symphony-intent:v1:#{command.intent_id}:#{command.proposal_digest}:issue:"

    with :ok <- validate_issue_binding(issue),
         %{
           "id" => ^expected_id,
           "identifier" => identifier,
           "description" => description,
           "state" => %{"name" => @backlog_state}
         } <- issue,
         true <- valid_identifier?(identifier),
         false <- LinearWriteBroker.protected_identifier?(identifier),
         true <- is_binary(description) and String.contains?(description, marker_prefix) do
      :ok
    else
      true -> {:error, :protected_linear_issue_denied}
      {:error, _reason} = error -> error
      _mismatch -> {:error, :rejected}
    end
  end

  defp validate_transition_issue(issue, command, expected_id) do
    marker_prefix =
      "Idempotency marker: symphony-intent:v1:#{command.intent_id}:#{command.proposal_digest}:issue:#{command.subject_id}"

    with :ok <- validate_issue_binding(issue),
         %{
           "id" => ^expected_id,
           "identifier" => identifier,
           "description" => description
         } <- issue,
         true <- identifier == command.payload["issue_identifier"],
         false <- LinearWriteBroker.protected_identifier?(identifier),
         true <- is_binary(description) and String.contains?(description, marker_prefix) do
      :ok
    else
      true -> {:error, :protected_linear_issue_denied}
      {:error, _reason} = error -> error
      _mismatch -> {:error, :rejected}
    end
  end

  defp validate_issue_binding(%{
         "project" => %{"id" => project_id, "slugId" => slug},
         "team" => %{"id" => team_id, "key" => @team_key, "name" => @team_name}
       }) do
    if valid_id?(project_id) and valid_id?(team_id) and project_slug_matches?(slug),
      do: :ok,
      else: {:error, :project_binding_rejected}
  end

  defp validate_issue_binding(_invalid), do: {:error, :project_binding_rejected}

  defp deny_protected_identifiers(identifiers) do
    if Enum.any?(identifiers, &LinearWriteBroker.protected_identifier?/1),
      do: {:error, :protected_linear_issue_denied},
      else: :ok
  end

  defp project_slug_matches?(slug) when is_binary(slug) do
    slug == @project_slug or
      (byte_size(@project_slug) > byte_size(slug) + 1 and
         String.ends_with?(@project_slug, "-" <> slug))
  end

  defp project_slug_matches?(_invalid), do: false

  defp valid_id?(value), do: bounded_string?(value, @max_id_bytes)
  defp valid_identifier?(value), do: bounded_string?(value, @max_identifier_bytes)

  defp bounded_string?(value, max) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..max and value == String.trim(value)
  end

  defp bounded_string?(_value, _max), do: false

  defp graphql(%__MODULE__{transport: {module, server}}, query, variables) do
    if Code.ensure_loaded?(module) and function_exported?(module, :graphql, 3) do
      case module.graphql(server, query, variables) do
        {:ok, %{"errors" => _private_errors}} -> {:error, :linear_write_graphql_failed}
        {:ok, %{} = body} -> {:ok, body}
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _invalid -> {:error, :linear_write_transport_failed}
      end
    else
      {:error, :linear_write_transport_failed}
    end
  rescue
    _error -> {:error, :linear_write_transport_failed}
  catch
    _kind, _reason -> {:error, :linear_write_transport_failed}
  end

  defp uncertain(reason) do
    {:ok, Result.uncertain(@provider, %{"reason" => sanitize_reason(reason)})}
  end

  defp confirm_after_mutation({:ok, %Result{status: :confirmed}} = result), do: result
  defp confirm_after_mutation({:error, reason}), do: uncertain(reason)

  defp sanitize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sanitize_reason(_private), do: "linear_write_failed"

  defp external_uuid(key) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, "symphony-studio/linear-write/v1\0" <> key)

    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000

    Enum.join(
      [hex(a, 8), hex(b, 4), hex(c, 4), hex(d, 4), hex(e, 12)],
      "-"
    )
  end

  defp hex(value, width) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(width, "0")
  end
end
