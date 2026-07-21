# Downstream modification notice (2026-07-17): Symphony Studio bounds Linear
# responses, pins the credential-bearing endpoint, and sanitizes tracker errors.
defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @issue_page_size 50
  @default_max_graphql_response_bytes 2 * 1_024 * 1_024
  @trusted_linear_endpoints [
    "https://api.linear.app/graphql",
    "https://api.linear.app:443/graphql"
  ]
  @max_linear_endpoint_bytes 2_048
  @max_linear_api_key_bytes 4_096
  @response_size_key :symphony_linear_response_size
  @response_chunks_key :symphony_linear_response_chunks
  @response_too_large_key :symphony_linear_response_too_large
  @test_request_fun_key {__MODULE__, :request_fun_for_test}
  @public_tracker_error_atoms [
    :invalid_linear_response_body,
    :invalid_linear_response_json,
    :invalid_linear_response_limit,
    :invalid_linear_tracker_snapshot,
    :linear_missing_end_cursor,
    :linear_response_encoding_unsupported,
    :linear_response_too_large,
    :linear_unknown_payload,
    :missing_linear_api_token,
    :missing_linear_project_slug,
    :missing_linear_viewer_identity,
    :untrusted_linear_endpoint
  ]

  @query """
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
  """

  @query_by_ids """
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
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    result =
      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          with {:ok, assignee_filter} <- routing_assignee_filter() do
            do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
          end
      end

    sanitize_tracker_result(result)
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    result =
      if normalized_states == [] do
        {:ok, []}
      else
        tracker = Config.settings!().tracker
        project_slug = tracker.project_slug

        cond do
          is_nil(tracker.api_key) ->
            {:error, :missing_linear_api_token}

          is_nil(project_slug) ->
            {:error, :missing_linear_project_slug}

          true ->
            do_fetch_by_states(project_slug, normalized_states, nil)
        end
      end

    sanitize_tracker_result(result)
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    result =
      case ids do
        [] ->
          {:ok, []}

        ids ->
          with {:ok, assignee_filter} <- routing_assignee_filter() do
            do_fetch_issue_states(ids, assignee_filter)
          end
      end

    sanitize_tracker_result(result)
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    max_response_bytes = Keyword.get(opts, :max_response_bytes, @default_max_graphql_response_bytes)

    with :ok <- validate_max_response_bytes(max_response_bytes),
         {:ok, tracker} <- graphql_tracker_snapshot(opts),
         :ok <- validate_trusted_linear_endpoint(tracker.endpoint),
         {:ok, request_fun} <- graphql_request_fun(opts, tracker.endpoint, max_response_bytes),
         {:ok, headers} <- graphql_headers(tracker.api_key),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers),
         {:ok, decoded_body} <- decode_bounded_graphql_body(body, max_response_bytes) do
      {:ok, decoded_body}
    else
      {:ok, %{status: status}} ->
        Logger.error("Linear GraphQL request failed class=api_status status=#{status}")

        {:error, {:linear_api_status, status}}

      {:error, :untrusted_linear_endpoint} ->
        Logger.error("Linear GraphQL request failed class=untrusted_endpoint")
        {:error, :untrusted_linear_endpoint}

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed class=request_error")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec bounded_request_fun_for_test(String.t(), pos_integer()) :: (map(), list() -> term())
  def bounded_request_fun_for_test(endpoint, max_response_bytes)
      when is_binary(endpoint) and is_integer(max_response_bytes) and max_response_bytes > 0 do
    fn payload, headers ->
      post_graphql_request(payload, headers, endpoint, max_response_bytes)
    end
  end

  @doc false
  @spec with_request_fun_for_test((map(), list() -> term()), (-> result)) :: result when result: term()
  def with_request_fun_for_test(request_fun, fun)
      when is_function(request_fun, 2) and is_function(fun, 0) do
    previous = Process.get(@test_request_fun_key)
    Process.put(@test_request_fun_key, request_fun)

    try do
      fun.()
    after
      case previous do
        value when is_function(value, 2) -> Process.put(@test_request_fun_key, value)
        _unset -> Process.delete(@test_request_fun_key)
      end
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec next_page_cursor_for_test(map()) :: {:ok, String.t()} | :done | {:error, term()}
  def next_page_cursor_for_test(page_info) when is_map(page_info), do: next_page_cursor(page_info)

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    result =
      case ids do
        [] ->
          {:ok, []}

        ids ->
          do_fetch_issue_states(ids, nil, graphql_fun)
      end

    sanitize_tracker_result(result)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states_page(project_slug, state_names, assignee_filter, nil, [])
  end

  defp do_fetch_by_states_page(project_slug, state_names, assignee_filter, after_cursor, acc_issues) do
    with {:ok, body} <-
           graphql(@query, %{
             projectSlug: project_slug,
             stateNames: state_names,
             first: @issue_page_size,
             relationFirst: @issue_page_size,
             after: after_cursor
           }),
         {:ok, issues, page_info} <- decode_linear_page_response(body, assignee_filter) do
      updated_acc = prepend_page_issues(issues, acc_issues)

      case next_page_cursor(page_info) do
        {:ok, next_cursor} ->
          do_fetch_by_states_page(project_slug, state_names, assignee_filter, next_cursor, updated_acc)

        :done ->
          {:ok, finalize_paginated_issues(updated_acc)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp graphql_tracker_snapshot(opts) do
    tracker = Keyword.get_lazy(opts, :tracker, fn -> Config.settings!().tracker end)

    with %{api_key: api_key, endpoint: endpoint} <- tracker,
         true <- bounded_present_binary?(api_key, @max_linear_api_key_bytes),
         true <- bounded_present_binary?(endpoint, @max_linear_endpoint_bytes) do
      {:ok, %{api_key: api_key, endpoint: endpoint}}
    else
      _invalid -> {:error, :invalid_linear_tracker_snapshot}
    end
  rescue
    _error -> {:error, :invalid_linear_tracker_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_linear_tracker_snapshot}
  end

  defp graphql_request_fun(opts, endpoint, max_response_bytes) do
    case Keyword.fetch(opts, :request_fun) do
      {:ok, request_fun} when is_function(request_fun, 2) ->
        {:ok, request_fun}

      {:ok, _invalid} ->
        {:error, :invalid_linear_request_fun}

      :error ->
        case Process.get(@test_request_fun_key) do
          request_fun when is_function(request_fun, 2) ->
            {:ok, request_fun}

          nil ->
            {:ok,
             fn payload, headers ->
               post_graphql_request(payload, headers, endpoint, max_response_bytes)
             end}

          _invalid ->
            {:error, :invalid_linear_request_fun}
        end
    end
  end

  defp validate_trusted_linear_endpoint(endpoint) when endpoint in @trusted_linear_endpoints,
    do: :ok

  defp validate_trusted_linear_endpoint(_endpoint), do: {:error, :untrusted_linear_endpoint}

  defp sanitize_tracker_result({:ok, _value} = result), do: result

  defp sanitize_tracker_result({:error, reason}) do
    {:error, sanitize_tracker_error(reason)}
  end

  defp sanitize_tracker_error({:linear_api_request, _private_reason}),
    do: :linear_transport_failed

  defp sanitize_tracker_error({:linear_graphql_errors, _private_errors}),
    do: :linear_graphql_failed

  defp sanitize_tracker_error({:linear_api_status, status})
       when is_integer(status) and status >= 100 and status <= 599,
       do: {:linear_api_status, status}

  defp sanitize_tracker_error(reason) when reason in @public_tracker_error_atoms,
    do: reason

  defp sanitize_tracker_error(_private_reason), do: :linear_tracker_failed

  defp graphql_headers(token) when is_binary(token) do
    {:ok,
     [
       {"Authorization", token},
       {"Content-Type", "application/json"}
     ]}
  end

  defp post_graphql_request(payload, headers, endpoint, max_response_bytes) do
    into = fn {:data, data}, {request, response} ->
      collect_bounded_response(data, request, response, max_response_bytes)
    end

    case Req.post(endpoint,
           headers: headers,
           json: payload,
           connect_options: [timeout: 30_000],
           receive_timeout: 30_000,
           redirect: false,
           compressed: false,
           raw: true,
           into: into
         ) do
      {:ok, response} -> finalize_bounded_response(response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect_bounded_response(data, request, response, max_response_bytes) when is_binary(data) do
    current_size = Req.Response.get_private(response, @response_size_key, 0)
    updated_size = current_size + byte_size(data)

    if updated_size > max_response_bytes do
      response =
        response
        |> Req.Response.put_private(@response_too_large_key, true)
        |> Req.Response.put_private(@response_chunks_key, [])

      {:halt, {request, response}}
    else
      response =
        response
        |> Req.Response.put_private(@response_size_key, updated_size)
        |> Req.Response.update_private(@response_chunks_key, [data], &[data | &1])

      {:cont, {request, response}}
    end
  end

  defp finalize_bounded_response(response) do
    cond do
      Req.Response.get_private(response, @response_too_large_key, false) ->
        {:error, :linear_response_too_large}

      unsupported_content_encoding?(response) ->
        {:error, :linear_response_encoding_unsupported}

      true ->
        chunks = Req.Response.get_private(response, @response_chunks_key, [])
        {:ok, %{response | body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
    end
  end

  defp unsupported_content_encoding?(response) do
    response
    |> Req.Response.get_header("content-encoding")
    |> Enum.any?(fn encoding -> String.downcase(String.trim(encoding)) not in ["", "identity"] end)
  end

  defp decode_bounded_graphql_body(body, _max_response_bytes) when is_map(body), do: {:ok, body}

  defp decode_bounded_graphql_body(body, max_response_bytes) when is_binary(body) do
    if byte_size(body) <= max_response_bytes do
      case Jason.decode(body) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _invalid} -> {:error, :invalid_linear_response_body}
        {:error, _reason} -> {:error, :invalid_linear_response_json}
      end
    else
      {:error, :linear_response_too_large}
    end
  end

  defp decode_bounded_graphql_body(_body, _max_response_bytes),
    do: {:error, :invalid_linear_response_body}

  defp validate_max_response_bytes(value) when is_integer(value) and value > 0,
    do: :ok

  defp validate_max_response_bytes(_invalid), do: {:error, :invalid_linear_response_limit}

  defp bounded_present_binary?(value, max_bytes) do
    is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max_bytes and
      byte_size(String.trim(value)) > 0
  end

  defp decode_linear_response(response, assignee_filter) when is_map(response) do
    with :ok <- reject_graphql_errors(response) do
      decode_linear_data_response(response, assignee_filter)
    end
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_data_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter)
       when is_list(nodes) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_data_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(response, assignee_filter) do
    with :ok <- reject_graphql_errors(response) do
      decode_linear_page_data_response(response, assignee_filter)
    end
  end

  defp decode_linear_page_data_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       )
       when is_list(nodes) do
    with {:ok, issues} <-
           decode_linear_data_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_data_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp reject_graphql_errors(%{"errors" => errors}) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp reject_graphql_errors(_response), do: :ok

  defp next_page_cursor(%{has_next_page: true, end_cursor: end_cursor})
       when is_binary(end_cursor) and byte_size(end_cursor) > 0 do
    {:ok, end_cursor}
  end

  defp next_page_cursor(%{has_next_page: true}), do: {:error, :linear_missing_end_cursor}
  defp next_page_cursor(_), do: :done

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_viewer_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_viewer_assignee_filter do
    case graphql(@viewer_query, %{}) do
      {:ok, body} ->
        decode_viewer_assignee_filter(body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_viewer_assignee_filter(body) do
    with :ok <- reject_graphql_errors(body),
         %{"data" => %{"viewer" => viewer}} when is_map(viewer) <- body,
         viewer_id when is_binary(viewer_id) <- assignee_id(viewer) do
      {:ok, %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :missing_linear_viewer_identity}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        if String.downcase(String.trim(relation_type)) == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"])
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
