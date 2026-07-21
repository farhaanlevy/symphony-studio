# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Linear.CapabilityDiscovery do
  @moduledoc """
  Performs the bounded, read-only Linear capability probe used by Release 0.

  One immutable tracker snapshot supplies every request. Raw Linear identities,
  credentials, endpoint details, configured names, and provider errors remain
  process-local. A successful probe represents the verified viewer, project,
  exact slug, and sorted team set with a generation-bound keyed HMAC whose
  secret is stored outside the repository. Pre-verification failures retain a
  separate configuration-only binding.

  Mutation evidence is schema-only. The probe never executes a mutation and
  cannot prove that the current credential is authorized to comment or update
  an issue; R1-07 owns that permission and execution proof.
  """

  alias SymphonyElixir.Codex.IdentityBinding
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Workflow

  @report_version 1
  @binding_generation 1
  @configured_project_binding_domain "symphony-studio/linear-project-config/v1\0"
  @verified_project_binding_domain "symphony-studio/linear-project-identity/v1\0"
  @page_size 100
  @max_pages 16
  @max_items 1_024
  @max_response_bytes 2 * 1_024 * 1_024
  @max_endpoint_bytes 2_048
  @max_api_key_bytes 4_096
  @max_project_slug_bytes 256
  @max_name_bytes 256
  @max_id_bytes 1_024
  @max_cursor_bytes 1_024
  @max_team_key_bytes 64
  @max_configured_names 128
  @validation_fixture_state "Backlog"
  @validation_fixture_ordinals [1, 2]
  @nested_page_size 16
  @max_type_depth 6
  @check_keys ~w(connectivity project states labels blockers comments mutations)

  @viewer_query """
  query SymphonyStudioLinearConnectivity {
    viewer {
      id
    }
  }
  """

  @project_query """
  query SymphonyStudioLinearProject(
    $projectSlug: String!
    $first: Int!
    $after: String
    $nestedFirst: Int!
  ) {
    projects(
      filter: {slugId: {eq: $projectSlug}}
      first: $first
      after: $after
    ) {
      nodes {
        id
        slugId
        teams(first: $nestedFirst) {
          nodes {
            id
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @validation_project_query """
  query SymphonyStudioLinearValidationProject(
    $projectSlug: String!
    $first: Int!
    $after: String
    $nestedFirst: Int!
  ) {
    projects(
      filter: {slugId: {eq: $projectSlug}}
      first: $first
      after: $after
    ) {
      nodes {
        id
        slugId
        teams(first: $nestedFirst) {
          nodes {
            id
            key
          }
          pageInfo {
            hasNextPage
            endCursor
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @states_query """
  query SymphonyStudioLinearStates(
    $teamIds: [ID!]!
    $first: Int!
    $after: String
  ) {
    workflowStates(
      filter: {team: {id: {in: $teamIds}}}
      first: $first
      after: $after
    ) {
      nodes {
        id
        name
        team {
          id
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @labels_query """
  query SymphonyStudioLinearLabels(
    $filter: IssueLabelFilter!
    $first: Int!
    $after: String
  ) {
    issueLabels(
      filter: $filter
      first: $first
      after: $after
    ) {
      nodes {
        id
        name
        team {
          id
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @issue_shape_query """
  query SymphonyStudioLinearIssueShapes($projectSlug: String!, $first: Int!) {
    issues(
      filter: {project: {slugId: {eq: $projectSlug}}}
      first: $first
    ) {
      nodes {
        id
        labels(first: $first) {
          nodes {
            id
          }
        }
        inverseRelations(first: $first) {
          nodes {
            id
            type
            issue {
              id
            }
          }
        }
        comments(first: $first) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  @validation_fixtures_query """
  query SymphonyStudioLinearValidationFixtures(
    $fixtureOne: String!
    $fixtureTwo: String!
    $nestedFirst: Int!
  ) {
    fixtureOne: issue(id: $fixtureOne) {
      id
      identifier
      title
      description
      state {
        name
      }
      team {
        id
        key
      }
      project {
        id
        slugId
      }
      labels(first: $nestedFirst) {
        nodes {
          id
        }
      }
      inverseRelations(first: $nestedFirst) {
        nodes {
          id
          type
          issue {
            id
            identifier
          }
        }
      }
      comments(first: $nestedFirst) {
        nodes {
          id
        }
      }
    }
    fixtureTwo: issue(id: $fixtureTwo) {
      id
      identifier
      title
      description
      state {
        name
      }
      team {
        id
        key
      }
      project {
        id
        slugId
      }
      labels(first: $nestedFirst) {
        nodes {
          id
        }
      }
      inverseRelations(first: $nestedFirst) {
        nodes {
          id
          type
          issue {
            id
            identifier
          }
        }
      }
      comments(first: $nestedFirst) {
        nodes {
          id
        }
      }
    }
  }
  """

  @schema_query """
  query SymphonyStudioLinearSchemaCapabilities {
    mutationType: __type(name: "Mutation") {
      kind
      fields(includeDeprecated: true) {
        name
        args {
          name
          type {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
                ofType {
                  kind
                  name
                }
              }
            }
          }
        }
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
              }
            }
          }
        }
      }
    }
    commentCreateInput: __type(name: "CommentCreateInput") {
      kind
      inputFields {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
    issueUpdateInput: __type(name: "IssueUpdateInput") {
      kind
      inputFields {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
    commentPayload: __type(name: "CommentPayload") {
      kind
      fields(includeDeprecated: true) {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
    issuePayload: __type(name: "IssuePayload") {
      kind
      fields(includeDeprecated: true) {
        name
        type {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
            }
          }
        }
      }
    }
  }
  """

  @doc false
  @spec broker_operation(String.t()) :: {:ok, String.t()} | {:error, :unknown_query}
  def broker_operation(@viewer_query), do: {:ok, "connectivity"}
  def broker_operation(@validation_project_query), do: {:ok, "validation_project"}
  def broker_operation(@states_query), do: {:ok, "states"}
  def broker_operation(@labels_query), do: {:ok, "labels"}
  def broker_operation(@validation_fixtures_query), do: {:ok, "validation_fixtures"}
  def broker_operation(@schema_query), do: {:ok, "mutation_schema"}
  def broker_operation(_unknown), do: {:error, :unknown_query}

  @typedoc "A redacted status object emitted for one Linear capability."
  @type check_status :: %{required(String.t()) => String.t()}

  @typedoc "The strict, redacted Release 0 Linear capability report."
  @type report :: %{
          required(String.t()) => check_status() | String.t() | pos_integer() | nil
        }

  @doc "Runs the configured read-only Linear probe and returns a redacted report."
  @spec probe(keyword()) :: report()
  def probe(opts \\ []) when is_list(opts) do
    key_provider = Keyword.get(opts, :key_provider, fn -> load_default_binding_key(opts) end)

    case load_binding_key(key_provider) do
      {:ok, key} -> probe_with_key(opts, key)
      {:error, _reason} -> blocked_report(nil, "binding_key_unavailable")
    end
  rescue
    _error -> blocked_report(nil, "configuration_unavailable")
  catch
    _kind, _reason -> blocked_report(nil, "configuration_unavailable")
  end

  defp probe_with_key(opts, key) do
    case Config.settings() do
      {:ok, settings} -> probe_tracker(settings.tracker, opts, key)
      {:error, _reason} -> blocked_report(project_binding("<missing>", key), "configuration_unavailable")
    end
  end

  defp probe_tracker(tracker, opts, key) do
    binding = binding_for_tracker(tracker, key)
    validation_fixtures? = Keyword.get(opts, :validation_fixtures, false)
    sealed_broker? = Keyword.get(opts, :sealed_broker, false)

    with :ok <- validate_fixture_mode(validation_fixtures?),
         :ok <- validate_sealed_broker_mode(sealed_broker?, validation_fixtures?),
         {:ok, snapshot} <- tracker_snapshot(tracker, sealed_broker?),
         {:ok, graphql} <- graphql_function(opts, snapshot) do
      run_probe(snapshot, graphql, binding, key, validation_fixtures?, sealed_broker?)
    else
      {:error, reason} -> blocked_report(binding, Atom.to_string(reason))
    end
  end

  defp validate_fixture_mode(value) when is_boolean(value), do: :ok
  defp validate_fixture_mode(_invalid), do: {:error, :configuration_unavailable}

  defp validate_sealed_broker_mode(false, _validation_fixtures?), do: :ok
  defp validate_sealed_broker_mode(true, true), do: :ok

  defp validate_sealed_broker_mode(_invalid, _validation_fixtures?),
    do: {:error, :configuration_unavailable}

  defp tracker_snapshot(tracker, sealed_broker?) do
    with :ok <- validate_tracker_kind(tracker),
         {:ok, endpoint} <- bounded_config_value(Map.get(tracker, :endpoint), @max_endpoint_bytes, :invalid_endpoint),
         {:ok, project_slug} <-
           bounded_config_value(
             Map.get(tracker, :project_slug),
             @max_project_slug_bytes,
             :missing_project_configuration
           ),
         {:ok, api_key} <- tracker_api_key(tracker, sealed_broker?),
         {:ok, active_states} <- validate_state_names(Map.get(tracker, :active_states)),
         {:ok, terminal_states} <- validate_state_names(Map.get(tracker, :terminal_states)),
         :ok <- validate_state_sets(active_states, terminal_states),
         {:ok, required_labels} <- validate_label_names(Map.get(tracker, :required_labels)) do
      {:ok,
       %{
         active_states: active_states,
         api_key: api_key,
         endpoint: endpoint,
         kind: "linear",
         project_slug: project_slug,
         required_labels: required_labels,
         terminal_states: terminal_states
       }}
    end
  end

  defp tracker_api_key(_tracker, true), do: {:ok, nil}

  defp tracker_api_key(tracker, false),
    do: bounded_config_value(Map.get(tracker, :api_key), @max_api_key_bytes, :missing_api_key)

  defp tracker_api_key(_tracker, _invalid), do: {:error, :configuration_unavailable}

  defp validate_tracker_kind(tracker) do
    if match?(%{kind: "linear"}, tracker),
      do: :ok,
      else: {:error, :unsupported_tracker}
  end

  defp bounded_config_value(value, max_bytes, missing_reason) do
    cond do
      not is_binary(value) or String.trim(value) == "" -> {:error, missing_reason}
      byte_size(value) > max_bytes -> {:error, :configuration_limit}
      true -> {:ok, value}
    end
  end

  defp validate_state_names(names),
    do: validate_configured_names(names, false, :invalid_state_configuration)

  defp validate_label_names(names),
    do: validate_configured_names(names, true, :invalid_label_configuration)

  defp validate_configured_names(names, allow_empty, error_reason)
       when is_list(names) and length(names) <= @max_configured_names do
    valid =
      Enum.all?(names, fn name ->
        is_binary(name) and name == String.trim(name) and name != "" and byte_size(name) <= @max_name_bytes
      end)

    canonical = Enum.map(names, &normalize_name/1)
    unique = MapSet.size(MapSet.new(canonical)) == length(canonical)

    if valid and unique and (allow_empty or names != []),
      do: {:ok, names},
      else: {:error, error_reason}
  end

  defp validate_configured_names(_invalid, _allow_empty, error_reason), do: {:error, error_reason}

  defp validate_state_sets(active_states, terminal_states) do
    active = active_states |> Enum.map(&normalize_name/1) |> MapSet.new()
    terminal = terminal_states |> Enum.map(&normalize_name/1) |> MapSet.new()

    if MapSet.disjoint?(active, terminal),
      do: :ok,
      else: {:error, :invalid_state_configuration}
  end

  defp graphql_function(opts, snapshot) do
    case Keyword.fetch(opts, :graphql) do
      {:ok, graphql} when is_function(graphql, 2) ->
        {:ok, graphql}

      {:ok, _invalid} ->
        {:error, :configuration_unavailable}

      :error ->
        with false <- Keyword.get(opts, :sealed_broker, false),
             :ok <- ensure_graphql_runtime(opts) do
          tracker = %{api_key: snapshot.api_key, endpoint: snapshot.endpoint}

          {:ok,
           fn query, variables ->
             Client.graphql(query, variables,
               tracker: tracker,
               max_response_bytes: @max_response_bytes
             )
           end}
        else
          _blocked -> {:error, :request_failed}
        end
    end
  end

  defp ensure_graphql_runtime(opts) do
    starter = Keyword.get(opts, :runtime_starter, fn -> Application.ensure_all_started(:req) end)

    case starter do
      fun when is_function(fun, 0) ->
        case fun.() do
          {:ok, applications} when is_list(applications) -> :ok
          _unavailable -> {:error, :request_failed}
        end

      _invalid ->
        {:error, :request_failed}
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp run_probe(snapshot, graphql, configured_binding, key, validation_fixtures?, sealed_broker?) do
    with {:ok, viewer_id} <- probe_connectivity(graphql),
         {:ok, project} <- probe_project(graphql, snapshot.project_slug, validation_fixtures?),
         {:ok, states} <- probe_states(graphql, project.team_ids),
         {:ok, labels} <- probe_labels(graphql, project.team_ids),
         {:ok, fixture_snapshot} <-
           probe_issue_contract(graphql, snapshot.project_slug, project, validation_fixtures?),
         {:ok, mutation_status} <- probe_schema(graphql),
         {:ok, final_viewer_id} <- probe_connectivity(graphql),
         :ok <- same_viewer(viewer_id, final_viewer_id),
         {:ok, final_project} <-
           probe_project(graphql, snapshot.project_slug, validation_fixtures?),
         :ok <- same_project(project, final_project),
         {:ok, final_fixture_snapshot} <-
           probe_final_validation_fixtures(graphql, final_project, validation_fixtures?),
         :ok <- same_fixture_snapshot(fixture_snapshot, final_fixture_snapshot),
         :ok <- same_config_snapshot(snapshot, sealed_broker?) do
      binding = verified_project_binding(viewer_id, project, key)
      capability_report(binding, snapshot, project.team_ids, states, labels, mutation_status)
    else
      {:error, reason} -> blocked_report(configured_binding, Atom.to_string(reason))
    end
  end

  defp probe_connectivity(graphql) do
    with {:ok, body} <- call_graphql(graphql, @viewer_query, %{}),
         %{"data" => %{"viewer" => %{"id" => viewer_id}}} <- body,
         true <- bounded_string?(viewer_id, @max_id_bytes) do
      {:ok, viewer_id}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :malformed_payload}
    end
  end

  defp same_viewer(viewer_id, viewer_id), do: :ok
  defp same_viewer(_initial, _final), do: {:error, :viewer_changed}

  defp probe_project(graphql, project_slug, validation_fixtures?) do
    variables = %{"nestedFirst" => @nested_page_size, "projectSlug" => project_slug}
    query = if validation_fixtures?, do: @validation_project_query, else: @project_query
    decoder = if validation_fixtures?, do: &decode_validation_project/1, else: &decode_project/1

    case fetch_connection(graphql, query, variables, "projects", decoder) do
      {:ok, projects} -> exactly_one_project(projects, project_slug)
      {:error, reason} -> {:error, reason}
    end
  end

  defp exactly_one_project([], _project_slug), do: {:error, :project_not_found}

  defp exactly_one_project([%{slug: slug} = project], configured_project_slug) do
    if project_selector_matches?(configured_project_slug, slug),
      do: {:ok, project},
      else: {:error, :project_binding_mismatch}
  end

  defp exactly_one_project(_duplicate_or_ambiguous, _project_slug), do: {:error, :duplicate_entity}

  defp project_selector_matches?(project_slug, project_slug), do: true

  defp project_selector_matches?(configured_project_slug, returned_slug_id) do
    byte_size(configured_project_slug) > byte_size(returned_slug_id) + 1 and
      String.ends_with?(configured_project_slug, "-" <> returned_slug_id)
  end

  defp decode_project(%{
         "id" => id,
         "slugId" => slug,
         "teams" => %{"nodes" => teams, "pageInfo" => page_info}
       })
       when is_list(teams) do
    with true <- bounded_string?(id, @max_id_bytes),
         true <- bounded_string?(slug, @max_project_slug_bytes),
         :done <- decode_page_info(page_info),
         {:ok, team_ids} <- decode_team_ids(teams),
         true <- team_ids != [] do
      {:ok, %{id: id, slug: slug, team_ids: team_ids}}
    else
      {:error, reason} -> {:error, reason}
      {:next, _cursor} -> {:error, :pagination_limit}
      _malformed -> {:error, :malformed_payload}
    end
  end

  defp decode_project(_unknown), do: {:error, :malformed_payload}

  defp decode_validation_project(%{
         "id" => id,
         "slugId" => slug,
         "teams" => %{
           "nodes" => [%{"id" => team_id, "key" => team_key}],
           "pageInfo" => page_info
         }
       }) do
    with true <- bounded_string?(id, @max_id_bytes),
         true <- bounded_string?(slug, @max_project_slug_bytes),
         :done <- decode_page_info(page_info),
         true <- bounded_string?(team_id, @max_id_bytes),
         true <- bounded_team_key?(team_key) do
      {:ok, %{id: id, slug: slug, team_ids: [team_id], team_key: team_key}}
    else
      {:next, _cursor} -> {:error, :validation_team_mismatch}
      _invalid -> {:error, :validation_team_mismatch}
    end
  end

  defp decode_validation_project(_unknown), do: {:error, :validation_team_mismatch}

  defp decode_team_ids(teams) when length(teams) <= @page_size do
    Enum.reduce_while(teams, {:ok, MapSet.new(), []}, fn
      %{"id" => id}, {:ok, seen, ids} ->
        if bounded_string?(id, @max_id_bytes) and not MapSet.member?(seen, id) do
          {:cont, {:ok, MapSet.put(seen, id), [id | ids]}}
        else
          {:halt, {:error, :duplicate_or_malformed_entity}}
        end

      _unknown, _acc ->
        {:halt, {:error, :malformed_payload}}
    end)
    |> case do
      {:ok, _seen, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_team_ids(_too_many), do: {:error, :pagination_limit}

  defp same_project(%{id: id, slug: slug, team_ids: team_ids, team_key: team_key}, %{
         id: id,
         slug: slug,
         team_ids: final_team_ids,
         team_key: team_key
       }) do
    if MapSet.new(team_ids) == MapSet.new(final_team_ids),
      do: :ok,
      else: {:error, :project_changed}
  end

  defp same_project(
         %{id: id, slug: slug, team_ids: team_ids},
         %{
           id: id,
           slug: slug,
           team_ids: final_team_ids
         } = final_project
       )
       when not is_map_key(final_project, :team_key) do
    if MapSet.new(team_ids) == MapSet.new(final_team_ids),
      do: :ok,
      else: {:error, :project_changed}
  end

  defp same_project(_initial, _final), do: {:error, :project_changed}

  defp probe_states(graphql, team_ids) do
    variables = %{"teamIds" => team_ids}
    team_id_set = MapSet.new(team_ids)

    fetch_connection(
      graphql,
      @states_query,
      variables,
      "workflowStates",
      &decode_state(&1, team_id_set)
    )
  end

  defp decode_state(%{"id" => id, "name" => name, "team" => %{"id" => team_id}}, team_ids) do
    if bounded_string?(id, @max_id_bytes) and bounded_string?(name, @max_name_bytes) and
         bounded_string?(team_id, @max_id_bytes) and MapSet.member?(team_ids, team_id) do
      {:ok, %{id: id, name: name, team_id: team_id}}
    else
      {:error, :malformed_payload}
    end
  end

  defp decode_state(_unknown, _team_ids), do: {:error, :malformed_payload}

  defp probe_labels(graphql, team_ids) do
    variables = %{
      "filter" => %{
        "or" => [
          %{"team" => %{"id" => %{"in" => team_ids}}},
          %{"team" => %{"null" => true}}
        ]
      }
    }

    team_id_set = MapSet.new(team_ids)

    fetch_connection(
      graphql,
      @labels_query,
      variables,
      "issueLabels",
      &decode_label(&1, team_id_set)
    )
  end

  defp decode_label(%{"id" => id, "name" => name, "team" => team}, team_ids) do
    with true <- bounded_string?(id, @max_id_bytes),
         true <- bounded_string?(name, @max_name_bytes),
         {:ok, team_id} <- decode_label_team(team, team_ids) do
      {:ok, %{id: id, name: normalize_name(name), team_id: team_id}}
    else
      _malformed -> {:error, :malformed_payload}
    end
  end

  defp decode_label(_unknown, _team_ids), do: {:error, :malformed_payload}

  defp decode_label_team(nil, _team_ids), do: {:ok, nil}

  defp decode_label_team(%{"id" => team_id}, team_ids) do
    if bounded_string?(team_id, @max_id_bytes) and MapSet.member?(team_ids, team_id),
      do: {:ok, team_id},
      else: {:error, :malformed_payload}
  end

  defp decode_label_team(_unknown, _team_ids), do: {:error, :malformed_payload}

  defp probe_issue_contract(graphql, project_slug, _project, false) do
    with :ok <- probe_issue_shapes(graphql, project_slug), do: {:ok, :generic_project}
  end

  defp probe_issue_contract(graphql, _project_slug, project, true),
    do: probe_validation_fixtures(graphql, project)

  defp probe_final_validation_fixtures(_graphql, _project, false), do: {:ok, :generic_project}

  defp probe_final_validation_fixtures(graphql, project, true),
    do: probe_validation_fixtures(graphql, project)

  defp same_fixture_snapshot(:generic_project, :generic_project), do: :ok
  defp same_fixture_snapshot(snapshot, snapshot) when is_map(snapshot), do: :ok
  defp same_fixture_snapshot(_initial, _final), do: {:error, :fixture_changed}

  defp probe_issue_shapes(graphql, project_slug) do
    with {:ok, body} <-
           call_graphql(graphql, @issue_shape_query, %{
             "first" => 1,
             "projectSlug" => project_slug
           }),
         %{"data" => %{"issues" => %{"nodes" => issues}}} <- body,
         true <- is_list(issues) and length(issues) <= 1,
         :ok <- decode_issue_shapes(issues) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :malformed_payload}
    end
  end

  defp decode_issue_shapes(issues) do
    Enum.reduce_while(issues, :ok, fn
      %{
        "id" => id,
        "labels" => %{"nodes" => labels},
        "inverseRelations" => %{"nodes" => relations},
        "comments" => %{"nodes" => comments}
      },
      :ok
      when is_list(labels) and is_list(relations) and is_list(comments) ->
        if bounded_string?(id, @max_id_bytes) and bounded_shape_nodes?(labels, :entity) and
             bounded_shape_nodes?(comments, :entity) and bounded_shape_nodes?(relations, :relation) do
          {:cont, :ok}
        else
          {:halt, {:error, :malformed_payload}}
        end

      _unknown, :ok ->
        {:halt, {:error, :malformed_payload}}
    end)
  end

  defp bounded_shape_nodes?(nodes, :entity) when length(nodes) <= 1 do
    Enum.all?(nodes, fn
      %{"id" => id} -> bounded_string?(id, @max_id_bytes)
      _unknown -> false
    end)
  end

  defp bounded_shape_nodes?(nodes, :relation) when length(nodes) <= 1 do
    Enum.all?(nodes, fn
      %{"id" => id, "type" => type, "issue" => %{"id" => issue_id}} ->
        bounded_string?(id, @max_id_bytes) and bounded_string?(type, @max_name_bytes) and
          bounded_string?(issue_id, @max_id_bytes)

      _unknown ->
        false
    end)
  end

  defp bounded_shape_nodes?(_too_many, _kind), do: false

  defp probe_validation_fixtures(graphql, %{
         id: project_id,
         slug: project_slug,
         team_ids: [team_id],
         team_key: team_key
       }) do
    with {:ok, [fixture_one, fixture_two] = fixture_keys} <- validation_fixture_keys(team_key),
         {:ok, body} <-
           call_graphql(graphql, @validation_fixtures_query, %{
             "fixtureOne" => fixture_one,
             "fixtureTwo" => fixture_two,
             "nestedFirst" => @nested_page_size
           }),
         %{"data" => data} when is_map(data) <- body,
         {:ok, first} <-
           decode_validation_fixture(
             Map.get(data, "fixtureOne"),
             fixture_one,
             project_id,
             project_slug,
             team_id,
             team_key
           ),
         {:ok, second} <-
           decode_validation_fixture(
             Map.get(data, "fixtureTwo"),
             fixture_two,
             project_id,
             project_slug,
             team_id,
             team_key
           ),
         :ok <- distinct_validation_fixtures(first, second),
         :ok <- validation_comment_present([first, second]),
         :ok <- validation_blocker_present([first, second]) do
      {:ok, %{fixture_keys: fixture_keys, fixtures: [first, second]}}
    else
      {:error, reason} -> {:error, reason}
      _malformed -> {:error, :fixture_shape_mismatch}
    end
  end

  defp probe_validation_fixtures(_graphql, _project),
    do: {:error, :validation_team_mismatch}

  defp validation_fixture_keys(team_key) do
    keys = Enum.map(@validation_fixture_ordinals, &"#{team_key}-#{&1}")

    if Enum.all?(keys, &bounded_string?(&1, @max_id_bytes)),
      do: {:ok, keys},
      else: {:error, :validation_team_mismatch}
  end

  defp decode_validation_fixture(nil, _expected_identifier, _project_id, _project_slug, _team_id, _team_key),
    do: {:error, :fixture_issue_missing}

  defp decode_validation_fixture(
         %{
           "id" => id,
           "identifier" => identifier,
           "title" => title,
           "description" => description,
           "state" => %{"name" => @validation_fixture_state},
           "team" => %{"id" => team_id, "key" => team_key},
           "project" => %{"id" => project_id, "slugId" => project_slug},
           "labels" => %{"nodes" => labels},
           "comments" => %{"nodes" => comments},
           "inverseRelations" => %{"nodes" => relations}
         },
         identifier,
         project_id,
         project_slug,
         team_id,
         team_key
       )
       when is_list(labels) and is_list(comments) and is_list(relations) do
    with true <- bounded_string?(id, @max_id_bytes),
         true <- bounded_string?(title, @max_name_bytes),
         true <- bounded_optional_string?(description, @max_response_bytes),
         {:ok, label_ids} <- decode_validation_entity_ids(labels),
         {:ok, comment_ids} <- decode_validation_entity_ids(comments),
         {:ok, decoded_relations} <- decode_validation_relations(relations) do
      {:ok,
       %{
         comment_ids: comment_ids,
         description: description,
         id: id,
         identifier: identifier,
         label_ids: label_ids,
         relations: decoded_relations,
         state: @validation_fixture_state,
         title: title
       }}
    else
      _invalid -> {:error, :fixture_shape_mismatch}
    end
  end

  defp decode_validation_fixture(
         _unknown,
         _expected_identifier,
         _project_id,
         _project_slug,
         _team_id,
         _team_key
       ),
       do: {:error, :fixture_shape_mismatch}

  defp decode_validation_entity_ids(nodes)
       when is_list(nodes) and length(nodes) <= @nested_page_size do
    Enum.reduce_while(nodes, {:ok, MapSet.new(), []}, fn
      %{"id" => id}, {:ok, seen, ids} ->
        if bounded_string?(id, @max_id_bytes) and not MapSet.member?(seen, id) do
          {:cont, {:ok, MapSet.put(seen, id), [id | ids]}}
        else
          {:halt, {:error, :fixture_shape_mismatch}}
        end

      _unknown, _acc ->
        {:halt, {:error, :fixture_shape_mismatch}}
    end)
    |> case do
      {:ok, _seen, ids} -> {:ok, Enum.sort(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_validation_entity_ids(_invalid), do: {:error, :fixture_shape_mismatch}

  defp decode_validation_relations(nodes)
       when is_list(nodes) and length(nodes) <= @nested_page_size do
    Enum.reduce_while(nodes, {:ok, MapSet.new(), []}, fn
      %{
        "id" => id,
        "type" => type,
        "issue" => %{"id" => issue_id, "identifier" => identifier}
      },
      {:ok, seen, relations} ->
        if bounded_string?(id, @max_id_bytes) and bounded_string?(type, @max_name_bytes) and
             bounded_string?(issue_id, @max_id_bytes) and
             bounded_string?(identifier, @max_id_bytes) and not MapSet.member?(seen, id) do
          relation = %{id: id, issue_id: issue_id, issue_identifier: identifier, type: type}
          {:cont, {:ok, MapSet.put(seen, id), [relation | relations]}}
        else
          {:halt, {:error, :fixture_shape_mismatch}}
        end

      _unknown, _acc ->
        {:halt, {:error, :fixture_shape_mismatch}}
    end)
    |> case do
      {:ok, _seen, relations} ->
        {:ok, Enum.sort_by(relations, &{&1.id, &1.issue_id, &1.issue_identifier, &1.type})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_validation_relations(_invalid), do: {:error, :fixture_shape_mismatch}

  defp distinct_validation_fixtures(%{id: id, identifier: identifier}, %{
         id: other_id,
         identifier: other_identifier
       }) do
    if id != other_id and identifier != other_identifier,
      do: :ok,
      else: {:error, :fixture_shape_mismatch}
  end

  defp validation_comment_present(fixtures) do
    if Enum.any?(fixtures, &(&1.comment_ids != [])),
      do: :ok,
      else: {:error, :fixture_comment_missing}
  end

  defp validation_blocker_present(fixtures) do
    fixture_identifiers = Map.new(fixtures, &{&1.id, &1.identifier})

    present? =
      Enum.any?(fixtures, fn fixture ->
        Enum.any?(fixture.relations, fn relation ->
          normalize_name(relation.type) == "blocks" and relation.issue_id != fixture.id and
            Map.get(fixture_identifiers, relation.issue_id) == relation.issue_identifier
        end)
      end)

    if present?, do: :ok, else: {:error, :fixture_blocker_missing}
  end

  defp probe_schema(graphql) do
    with {:ok, body} <- call_graphql(graphql, @schema_query, %{}) do
      {:ok, mutation_schema_status(body)}
    end
  end

  defp mutation_schema_status(body) do
    case validate_mutation_schema(body) do
      :ok -> %{"evidence" => "schema_only", "reason" => "schema_verified", "status" => "pass"}
      {:error, _reason} -> %{"evidence" => "schema_only", "reason" => "mutation_schema_mismatch", "status" => "blocked"}
    end
  end

  defp validate_mutation_schema(%{
         "data" => %{
           "mutationType" => %{"kind" => "OBJECT", "fields" => mutation_fields},
           "commentCreateInput" => %{"kind" => "INPUT_OBJECT", "inputFields" => comment_input_fields},
           "issueUpdateInput" => %{"kind" => "INPUT_OBJECT", "inputFields" => issue_input_fields},
           "commentPayload" => %{"kind" => "OBJECT", "fields" => comment_payload_fields},
           "issuePayload" => %{"kind" => "OBJECT", "fields" => issue_payload_fields}
         }
       }) do
    with {:ok, mutations} <- decode_mutation_fields(mutation_fields),
         {:ok, comment_inputs} <- decode_typed_fields(comment_input_fields),
         {:ok, issue_inputs} <- decode_typed_fields(issue_input_fields),
         {:ok, comment_payload} <- decode_typed_fields(comment_payload_fields),
         {:ok, issue_payload} <- decode_typed_fields(issue_payload_fields),
         :ok <- validate_comment_create(mutations, comment_inputs, comment_payload) do
      validate_issue_update(mutations, issue_inputs, issue_payload)
    end
  end

  defp validate_mutation_schema(_unknown), do: {:error, :unknown_schema}

  defp decode_mutation_fields(fields) when is_list(fields) and length(fields) <= @max_items do
    reduce_unique_fields(fields, fn
      %{"name" => name, "args" => args, "type" => type} ->
        with true <- bounded_string?(name, @max_name_bytes),
             {:ok, signature} <- type_signature(type, 0),
             {:ok, decoded_args} <- decode_typed_fields(args) do
          {:ok, name, %{args: decoded_args, type: signature}}
        else
          _invalid -> {:error, :unknown_schema}
        end

      _unknown ->
        {:error, :unknown_schema}
    end)
  end

  defp decode_mutation_fields(_invalid), do: {:error, :unknown_schema}

  defp decode_typed_fields(fields) when is_list(fields) and length(fields) <= @max_items do
    reduce_unique_fields(fields, fn
      %{"name" => name, "type" => type} ->
        with true <- bounded_string?(name, @max_name_bytes),
             {:ok, signature} <- type_signature(type, 0) do
          {:ok, name, signature}
        else
          _invalid -> {:error, :unknown_schema}
        end

      _unknown ->
        {:error, :unknown_schema}
    end)
  end

  defp decode_typed_fields(_invalid), do: {:error, :unknown_schema}

  defp reduce_unique_fields(fields, decoder) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
      case decoder.(field) do
        {:ok, name, value} ->
          append_unique_field(acc, name, value)

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp append_unique_field(acc, name, value) do
    if Map.has_key?(acc, name),
      do: {:halt, {:error, :duplicate_entity}},
      else: {:cont, {:ok, Map.put(acc, name, value)}}
  end

  defp type_signature(%{"kind" => "NON_NULL", "ofType" => nested}, depth)
       when depth < @max_type_depth do
    with {:ok, signature} <- type_signature(nested, depth + 1), do: {:ok, {:non_null, signature}}
  end

  defp type_signature(%{"kind" => "LIST", "ofType" => nested}, depth)
       when depth < @max_type_depth do
    with {:ok, signature} <- type_signature(nested, depth + 1), do: {:ok, {:list, signature}}
  end

  defp type_signature(%{"kind" => kind, "name" => name}, _depth)
       when kind in ["SCALAR", "OBJECT", "INPUT_OBJECT", "ENUM", "INTERFACE", "UNION"] do
    if bounded_string?(name, @max_name_bytes),
      do: {:ok, {:named, kind, name}},
      else: {:error, :unknown_schema}
  end

  defp type_signature(_unknown, _depth), do: {:error, :unknown_schema}

  defp validate_comment_create(mutations, inputs, payload) do
    expected_args = %{
      "input" => {:non_null, {:named, "INPUT_OBJECT", "CommentCreateInput"}}
    }

    with %{args: ^expected_args, type: {:non_null, {:named, "OBJECT", "CommentPayload"}}} <-
           Map.get(mutations, "commentCreate"),
         {:named, "SCALAR", "String"} <- Map.get(inputs, "issueId"),
         {:named, "SCALAR", "String"} <- Map.get(inputs, "body"),
         {:non_null, {:named, "SCALAR", "Boolean"}} <- Map.get(payload, "success") do
      :ok
    else
      _mismatch -> {:error, :unknown_schema}
    end
  end

  defp validate_issue_update(mutations, inputs, payload) do
    expected_args = %{
      "id" => {:non_null, {:named, "SCALAR", "String"}},
      "input" => {:non_null, {:named, "INPUT_OBJECT", "IssueUpdateInput"}}
    }

    with %{args: ^expected_args, type: {:non_null, {:named, "OBJECT", "IssuePayload"}}} <-
           Map.get(mutations, "issueUpdate"),
         {:named, "SCALAR", "String"} <- Map.get(inputs, "stateId"),
         {:non_null, {:named, "SCALAR", "Boolean"}} <- Map.get(payload, "success") do
      :ok
    else
      _mismatch -> {:error, :unknown_schema}
    end
  end

  defp fetch_connection(graphql, query, variables, connection_key, decoder) do
    state = %{
      after_cursor: nil,
      items: [],
      page_count: 0,
      seen_cursors: [],
      seen_ids: MapSet.new()
    }

    fetch_connection(graphql, query, variables, connection_key, decoder, state)
  end

  defp fetch_connection(
         _graphql,
         _query,
         _variables,
         _connection_key,
         _decoder,
         %{page_count: page_count}
       )
       when page_count >= @max_pages,
       do: {:error, :pagination_limit}

  defp fetch_connection(graphql, query, variables, connection_key, decoder, state) do
    page_variables = Map.merge(variables, %{"after" => state.after_cursor, "first" => @page_size})

    with {:ok, body} <- call_graphql(graphql, query, page_variables),
         {:ok, raw_nodes, page_info} <- decode_connection(body, connection_key),
         {:ok, decoded, updated_seen_ids} <- decode_nodes(raw_nodes, decoder, state.seen_ids),
         :ok <- within_item_limit(state.items, decoded) do
      updated_state = %{state | items: state.items ++ decoded, seen_ids: updated_seen_ids}

      continue_connection(
        graphql,
        query,
        variables,
        connection_key,
        decoder,
        decode_page_info(page_info),
        updated_state
      )
    end
  end

  defp continue_connection(_graphql, _query, _variables, _connection_key, _decoder, :done, state),
    do: {:ok, state.items}

  defp continue_connection(
         _graphql,
         _query,
         _variables,
         _connection_key,
         _decoder,
         {:error, reason},
         _state
       ),
       do: {:error, reason}

  defp continue_connection(graphql, query, variables, connection_key, decoder, {:next, cursor}, state) do
    if Enum.member?(state.seen_cursors, cursor) do
      {:error, :pagination_cycle}
    else
      next_state = %{
        state
        | after_cursor: cursor,
          page_count: state.page_count + 1,
          seen_cursors: [cursor | state.seen_cursors]
      }

      fetch_connection(graphql, query, variables, connection_key, decoder, next_state)
    end
  end

  defp call_graphql(graphql, query, variables) do
    case graphql.(query, variables) do
      {:ok, body} when is_map(body) ->
        if Map.has_key?(body, "errors"), do: {:error, :graphql_error}, else: {:ok, body}

      {:ok, _malformed} ->
        {:error, :malformed_payload}

      {:error, _reason} ->
        {:error, :request_failed}

      _unknown ->
        {:error, :malformed_payload}
    end
  rescue
    _error -> {:error, :request_failed}
  catch
    _kind, _reason -> {:error, :request_failed}
  end

  defp decode_connection(%{"data" => data}, connection_key) when is_map(data) do
    case Map.get(data, connection_key) do
      %{"nodes" => nodes, "pageInfo" => page_info} when is_list(nodes) and is_map(page_info) ->
        {:ok, nodes, page_info}

      _unknown ->
        {:error, :malformed_payload}
    end
  end

  defp decode_connection(_unknown, _connection_key), do: {:error, :malformed_payload}

  defp decode_nodes(nodes, decoder, seen_ids) when length(nodes) <= @page_size do
    Enum.reduce_while(nodes, {:ok, [], seen_ids}, fn node, {:ok, decoded, seen} ->
      case decoder.(node) do
        {:ok, %{id: id} = item} -> append_decoded_node(item, id, decoded, seen)
        {:error, reason} -> {:halt, {:error, reason}}
        _unknown -> {:halt, {:error, :malformed_payload}}
      end
    end)
    |> case do
      {:ok, decoded, updated_seen} -> {:ok, Enum.reverse(decoded), updated_seen}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_nodes(_too_many, _decoder, _seen_ids), do: {:error, :pagination_limit}

  defp append_decoded_node(item, id, decoded, seen) do
    if bounded_string?(id, @max_id_bytes) and not MapSet.member?(seen, id),
      do: {:cont, {:ok, [item | decoded], MapSet.put(seen, id)}},
      else: {:halt, {:error, :duplicate_entity}}
  end

  defp decode_page_info(%{"hasNextPage" => false, "endCursor" => cursor})
       when is_nil(cursor),
       do: :done

  defp decode_page_info(%{"hasNextPage" => false, "endCursor" => cursor}) when is_binary(cursor) do
    if byte_size(cursor) <= @max_cursor_bytes,
      do: :done,
      else: {:error, :pagination_limit}
  end

  defp decode_page_info(%{"hasNextPage" => true, "endCursor" => cursor}) do
    if bounded_string?(cursor, @max_cursor_bytes),
      do: {:next, cursor},
      else: {:error, :pagination_limit}
  end

  defp decode_page_info(_malformed), do: {:error, :malformed_payload}

  defp within_item_limit(existing, incoming) do
    if length(existing) + length(incoming) <= @max_items,
      do: :ok,
      else: {:error, :pagination_limit}
  end

  defp same_config_snapshot(snapshot, sealed_broker?) do
    with {:ok, settings} <- Config.settings(),
         {:ok, final_snapshot} <- tracker_snapshot(settings.tracker, sealed_broker?),
         true <- final_snapshot == snapshot do
      :ok
    else
      _changed -> {:error, :configuration_changed}
    end
  end

  defp capability_report(binding, snapshot, team_ids, states, labels, mutation_status) do
    %{
      "blockers" => passed(),
      "comments" => passed(),
      "configuredProjectBinding" => binding,
      "configuredProjectBindingGeneration" => @binding_generation,
      "connectivity" => passed(),
      "labels" => labels_status(snapshot.required_labels, team_ids, labels),
      "mutations" => mutation_status,
      "project" => passed(),
      "reportVersion" => @report_version,
      "states" => states_status(snapshot, team_ids, states)
    }
  end

  defp states_status(snapshot, team_ids, states) do
    expected = MapSet.new(snapshot.active_states ++ snapshot.terminal_states)

    all_teams_match =
      Enum.all?(team_ids, fn team_id ->
        actual =
          states
          |> Enum.filter(&(&1.team_id == team_id))
          |> Enum.map(& &1.name)
          |> MapSet.new()

        MapSet.subset?(expected, actual)
      end)

    if all_teams_match, do: passed(), else: blocked("configured_states_missing")
  end

  defp labels_status(required_labels, team_ids, labels) do
    expected = required_labels |> Enum.map(&normalize_name/1) |> MapSet.new()
    global = labels |> Enum.filter(&is_nil(&1.team_id)) |> Enum.map(& &1.name) |> MapSet.new()

    all_teams_match =
      Enum.all?(team_ids, fn team_id ->
        team_labels =
          labels
          |> Enum.filter(&(&1.team_id == team_id))
          |> Enum.map(& &1.name)
          |> MapSet.new()

        MapSet.subset?(expected, MapSet.union(global, team_labels))
      end)

    if all_teams_match, do: passed(), else: blocked("configured_labels_missing")
  end

  defp blocked_report(binding, reason) do
    checks = Map.new(@check_keys, &{&1, blocked(reason)})

    checks
    |> Map.put("configuredProjectBinding", binding)
    |> Map.put("configuredProjectBindingGeneration", @binding_generation)
    |> Map.put("reportVersion", @report_version)
  end

  defp passed, do: %{"reason" => "verified", "status" => "pass"}
  defp blocked(reason), do: %{"reason" => reason, "status" => "blocked"}

  defp load_binding_key(key_provider) when is_function(key_provider, 0) do
    case key_provider.() do
      {:ok, key} when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
      _invalid -> {:error, :binding_key_unavailable}
    end
  rescue
    _error -> {:error, :binding_key_unavailable}
  catch
    _kind, _reason -> {:error, :binding_key_unavailable}
  end

  defp load_binding_key(_invalid), do: {:error, :binding_key_unavailable}

  defp load_default_binding_key(opts) do
    with {:ok, cwd} <- File.cwd() |> canonical_probe_root(),
         {:ok, workflow_root} <- Workflow.workflow_directory() |> canonical_probe_root() do
      configured_roots = Keyword.get(opts, :identity_forbidden_roots, [])

      forbidden_roots =
        [cwd, workflow_root, nearest_git_root(cwd), nearest_git_root(workflow_root) | configured_roots]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      IdentityBinding.load_or_create_key(IdentityBinding.default_key_path(), forbidden_roots)
    else
      _unavailable -> {:error, :binding_key_unavailable}
    end
  end

  defp canonical_probe_root({:ok, path}), do: canonical_probe_root(path)
  defp canonical_probe_root({:error, _reason}), do: {:error, :binding_key_unavailable}

  defp canonical_probe_root(path) when is_binary(path) do
    case PathSafety.canonicalize(path) do
      {:ok, canonical} -> {:ok, canonical}
      {:error, _reason} -> {:error, :binding_key_unavailable}
    end
  end

  defp nearest_git_root(path) do
    case File.lstat(Path.join(path, ".git")) do
      {:ok, _stat} ->
        path

      {:error, _reason} ->
        parent = Path.dirname(path)
        if parent == path, do: nil, else: nearest_git_root(parent)
    end
  end

  defp binding_for_tracker(tracker, key) do
    case Map.get(tracker, :project_slug) do
      slug when is_binary(slug) and byte_size(slug) > 0 and byte_size(slug) <= @max_project_slug_bytes ->
        project_binding(slug, key)

      _invalid ->
        project_binding("<unavailable>", key)
    end
  end

  defp project_binding(project_slug, key) do
    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        [
          @configured_project_binding_domain,
          binding_frame(Integer.to_string(@binding_generation)),
          binding_frame(project_slug)
        ]
      )

    "linear-project-v1-" <> Base.encode16(digest, case: :lower)
  end

  defp verified_project_binding(viewer_id, project, key) do
    sorted_team_ids = Enum.sort(project.team_ids)

    digest =
      :crypto.mac(
        :hmac,
        :sha256,
        key,
        [
          @verified_project_binding_domain,
          binding_frame(Integer.to_string(@binding_generation)),
          binding_frame(viewer_id),
          binding_frame(project.id),
          binding_frame(project.slug),
          <<length(sorted_team_ids)::unsigned-big-integer-size(32)>>,
          Enum.map(sorted_team_ids, &binding_frame/1)
        ]
      )

    "linear-project-v1-" <> Base.encode16(digest, case: :lower)
  end

  defp binding_frame(value) when is_binary(value),
    do: [<<byte_size(value)::unsigned-big-integer-size(64)>>, value]

  defp normalize_name(value), do: value |> String.trim() |> String.downcase()

  defp bounded_team_key?(value) do
    bounded_string?(value, @max_team_key_bytes) and value == String.trim(value)
  end

  defp bounded_optional_string?(nil, _max_bytes), do: true

  defp bounded_optional_string?(value, max_bytes) when is_binary(value),
    do: byte_size(value) <= max_bytes

  defp bounded_optional_string?(_invalid, _max_bytes), do: false

  defp bounded_string?(value, max_bytes) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes and
      String.trim(value) != ""
  end
end
