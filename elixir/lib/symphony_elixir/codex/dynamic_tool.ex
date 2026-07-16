# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio parses every
# Linear document and adds an opt-in, issue-scoped managed read policy.
defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.

  The default policy preserves Symphony's raw, single-operation Linear query
  or mutation contract. The opt-in `:managed` policy accepts only bounded,
  issue-scoped reads and requires trusted issue/run context supplied by the
  host runtime rather than by tool arguments.
  """

  alias Absinthe.Blueprint
  alias Absinthe.Phase.Parse

  alias Absinthe.Language.{
    Argument,
    Document,
    Field,
    Fragment,
    FragmentSpread,
    InlineFragment,
    OperationDefinition,
    SelectionSet,
    Source,
    StringValue,
    Variable
  }

  alias SymphonyElixir.{Identity, Linear.Client}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_argument_keys ["query", "variables", :query, :variables]
  @upstream_description """
  Execute one raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @managed_description """
  Read allowlisted metadata for the current Linear issue with one bounded `issue(id: ...)`
  query. Mutations, relationship traversal, fragments, directives, introspection, and other
  roots are denied. Subject to Linear API limits.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @managed_read_roots ["issue"]
  @managed_issue_read_paths [
    ["id"],
    ["identifier"],
    ["title"],
    ["description"],
    ["url"],
    ["priority"],
    ["priorityLabel"],
    ["createdAt"],
    ["updatedAt"],
    ["dueDate"],
    ["branchName"],
    ["state", "id"],
    ["state", "name"],
    ["state", "type"],
    ["assignee", "id"],
    ["assignee", "name"],
    ["team", "id"],
    ["team", "key"],
    ["team", "name"],
    ["project", "id"],
    ["project", "name"],
    ["project", "slugId"],
    ["labels", "nodes", "id"],
    ["labels", "nodes", "name"]
  ]
  @managed_max_document_bytes 65_536
  @managed_max_variables_bytes 65_536
  @managed_max_tokens 10_000
  @managed_max_issue_id_bytes 256

  @error_messages %{
    invalid_tool_options: "Dynamic tool host options are invalid.",
    invalid_tool_policy: "Dynamic tool policy is invalid.",
    missing_query: "`linear_graphql` requires a non-empty `query` string.",
    invalid_arguments:
      "`linear_graphql` expects either a GraphQL query string or an object with " <>
        "`query` and optional `variables`.",
    invalid_variables: "`linear_graphql.variables` must be a JSON object when provided.",
    unexpected_arguments: "`linear_graphql` accepts only `query` and optional `variables` arguments.",
    graphql_parse_error: "`linear_graphql.query` is not a valid GraphQL document.",
    graphql_operation_count: "`linear_graphql.query` must contain exactly one GraphQL operation.",
    graphql_operation_type_denied: "`linear_graphql.query` must contain a query or mutation operation.",
    managed_context_required: "Managed Linear access requires trusted issue and run context.",
    managed_document_too_large: "Managed Linear query exceeds the document size limit.",
    managed_variables_too_large: "Managed Linear variables exceed the encoded size limit.",
    managed_variables_invalid: "Managed Linear variables must be JSON encodable.",
    managed_mutation_denied: "Managed Linear access does not permit raw mutations.",
    managed_subscription_denied: "Managed Linear access does not permit subscriptions.",
    managed_fragments_denied: "Managed Linear access does not permit fragments.",
    managed_directives_denied: "Managed Linear access does not permit directives.",
    managed_introspection_denied: "Managed Linear access does not permit introspection fields.",
    managed_definition_denied: "Managed Linear access does not permit non-operation definitions.",
    managed_read_root_denied: "Managed Linear query contains a root field that is not allowed.",
    managed_read_field_denied: "Managed Linear query contains a field path that is not allowed.",
    managed_issue_scope_denied: "Managed Linear query must be bound to the trusted current issue.",
    missing_linear_api_token:
      "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` " <>
        "or export `LINEAR_API_KEY`."
  }

  @type policy :: :upstream | :managed
  @type trusted_context :: %{issue_id: String.t(), run_id: Identity.uuid()}

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "code" => "unsupported_dynamic_tool",
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: tool_specs([])

  @spec tool_specs(keyword()) :: [map()]
  def tool_specs(opts) do
    description =
      case normalize_policy(opts) do
        {:ok, :managed} -> @managed_description
        _other -> @upstream_description
      end

    [
      %{
        "type" => "function",
        "name" => @linear_graphql_tool,
        "description" => description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    case prepare_linear_graphql(arguments, opts) do
      {:ok, query, variables} ->
        linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)
        invoke_linear_client(linear_client, query, variables)

      {:error, policy, context, reason} ->
        audit_denial(opts, policy, context, reason)
        failure_response(tool_error_payload(reason))
    end
  end

  defp prepare_linear_graphql(arguments, opts) do
    case normalize_policy(opts) do
      {:ok, policy} ->
        prepare_linear_graphql(arguments, opts, policy)

      {:error, reason} ->
        {:error, :upstream, %{}, reason}
    end
  end

  defp prepare_linear_graphql(arguments, opts, policy) do
    with {:ok, context} <- trusted_context(policy, opts),
         {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         :ok <- validate_managed_bounds(policy, query, variables),
         {:ok, document} <- parse_document(query, policy),
         :ok <- reject_managed_directive_tokens(policy, query),
         {:ok, operation} <- single_operation(document),
         :ok <- authorize_operation(policy, document, operation, variables, context) do
      {:ok, query, variables}
    else
      {:error, reason} ->
        context = safe_trusted_context(policy, opts)
        {:error, policy, context, reason}
    end
  end

  defp normalize_policy(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.get(opts, :policy, :upstream) do
        policy when policy in [:upstream, :managed] -> {:ok, policy}
        _other -> {:error, :invalid_tool_policy}
      end
    else
      {:error, :invalid_tool_options}
    end
  end

  defp normalize_policy(_opts), do: {:error, :invalid_tool_options}

  defp trusted_context(:upstream, _opts), do: {:ok, %{}}

  defp trusted_context(:managed, opts) do
    with context when is_map(context) <- Keyword.get(opts, :trusted_context),
         {:ok, issue_id} <- fetch_context_value(context, :issue_id),
         {:ok, run_id} <- fetch_context_value(context, :run_id),
         true <- valid_issue_id?(issue_id),
         true <- canonical_uuid4?(run_id) do
      {:ok, %{issue_id: issue_id, run_id: run_id}}
    else
      _invalid -> {:error, :managed_context_required}
    end
  end

  defp safe_trusted_context(:managed, opts) do
    case trusted_context(:managed, opts) do
      {:ok, context} -> context
      {:error, _reason} -> %{}
    end
  end

  defp safe_trusted_context(:upstream, _opts), do: %{}

  defp fetch_context_value(context, atom_key) do
    string_key = Atom.to_string(atom_key)

    case {Map.fetch(context, atom_key), Map.fetch(context, string_key)} do
      {{:ok, value}, :error} -> {:ok, value}
      {:error, {:ok, value}} -> {:ok, value}
      {{:ok, value}, {:ok, value}} -> {:ok, value}
      _ambiguous_or_missing -> :error
    end
  end

  defp valid_issue_id?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..@managed_max_issue_id_bytes and
      value == String.trim(value)
  end

  defp valid_issue_id?(_value), do: false

  defp canonical_uuid4?(value) when is_binary(value) do
    String.valid?(value) and value == String.downcase(value) and Identity.valid_uuid4?(value)
  end

  defp canonical_uuid4?(_value), do: false

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    with :ok <- validate_argument_keys(arguments),
         {:ok, query} <- normalize_query(arguments),
         {:ok, variables} <- normalize_variables(arguments) do
      {:ok, query, variables}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp validate_argument_keys(arguments) do
    if Enum.all?(Map.keys(arguments), &(&1 in @linear_graphql_argument_keys)) do
      :ok
    else
      {:error, :unexpected_arguments}
    end
  end

  defp normalize_query(arguments) do
    case fetch_argument(arguments, "query", :query) do
      {:ok, query} when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _missing_or_invalid ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case fetch_argument(arguments, "variables", :variables) do
      :error -> {:ok, %{}}
      {:ok, nil} -> {:ok, %{}}
      {:ok, variables} when is_map(variables) -> {:ok, variables}
      {:ok, _variables} -> {:error, :invalid_variables}
    end
  end

  defp fetch_argument(arguments, string_key, atom_key) do
    case Map.fetch(arguments, string_key) do
      :error -> Map.fetch(arguments, atom_key)
      result -> result
    end
  end

  defp validate_managed_bounds(:upstream, _query, _variables), do: :ok

  defp validate_managed_bounds(:managed, query, variables) do
    with true <- byte_size(query) <= @managed_max_document_bytes,
         {:ok, encoded_variables} <- Jason.encode(variables),
         true <- byte_size(encoded_variables) <= @managed_max_variables_bytes do
      :ok
    else
      false when byte_size(query) > @managed_max_document_bytes ->
        {:error, :managed_document_too_large}

      false ->
        {:error, :managed_variables_too_large}

      {:error, _reason} ->
        {:error, :managed_variables_invalid}
    end
  end

  defp parse_document(query, policy) do
    options = if policy == :managed, do: [token_limit: @managed_max_tokens], else: []

    case Parse.run(%Source{body: query}, options) do
      {:ok, %Blueprint{input: %Document{} = document}} -> {:ok, document}
      _parse_failure -> {:error, :graphql_parse_error}
    end
  rescue
    _error -> {:error, :graphql_parse_error}
  catch
    _kind, _reason -> {:error, :graphql_parse_error}
  end

  defp reject_managed_directive_tokens(:upstream, _query), do: :ok

  defp reject_managed_directive_tokens(:managed, query) do
    {:ok, tokens} = Parse.tokenize(query, token_limit: @managed_max_tokens)

    if Enum.any?(tokens, &match?({:@, _location}, &1)),
      do: {:error, :managed_directives_denied},
      else: :ok
  rescue
    _error -> {:error, :graphql_parse_error}
  catch
    _kind, _reason -> {:error, :graphql_parse_error}
  end

  defp single_operation(%Document{definitions: definitions}) do
    case Enum.filter(definitions, &match?(%OperationDefinition{}, &1)) do
      [operation] -> {:ok, operation}
      _not_one -> {:error, :graphql_operation_count}
    end
  end

  defp authorize_operation(:upstream, _document, %OperationDefinition{operation: operation}, _variables, _context)
       when operation in [:query, :mutation],
       do: :ok

  defp authorize_operation(:upstream, _document, _operation, _variables, _context),
    do: {:error, :graphql_operation_type_denied}

  defp authorize_operation(
         :managed,
         document,
         %OperationDefinition{operation: operation} = definition,
         variables,
         context
       ) do
    with :ok <- authorize_managed_operation_type(operation),
         :ok <- reject_managed_definitions(document),
         :ok <- reject_fragments(definition),
         :ok <- reject_directives(definition),
         :ok <- reject_introspection(definition),
         :ok <- authorize_read_roots(definition),
         :ok <- authorize_read_fields(definition) do
      authorize_issue_scope(definition, variables, context)
    end
  end

  defp authorize_managed_operation_type(:query), do: :ok
  defp authorize_managed_operation_type(:mutation), do: {:error, :managed_mutation_denied}
  defp authorize_managed_operation_type(:subscription), do: {:error, :managed_subscription_denied}
  defp authorize_managed_operation_type(_other), do: {:error, :graphql_operation_type_denied}

  defp reject_managed_definitions(%Document{definitions: definitions}) do
    cond do
      Enum.any?(definitions, &match?(%Fragment{}, &1)) ->
        {:error, :managed_fragments_denied}

      Enum.any?(definitions, &(not match?(%OperationDefinition{}, &1))) ->
        {:error, :managed_definition_denied}

      true ->
        :ok
    end
  end

  defp reject_fragments(%OperationDefinition{selection_set: selection_set}) do
    if fragment_free?(selection_set), do: :ok, else: {:error, :managed_fragments_denied}
  end

  defp fragment_free?(%SelectionSet{selections: selections}) do
    Enum.all?(selections, fn
      %Field{selection_set: nil} -> true
      %Field{selection_set: nested} -> fragment_free?(nested)
      %FragmentSpread{} -> false
      %InlineFragment{} -> false
      _unknown -> false
    end)
  end

  defp fragment_free?(_selection_set), do: false

  defp reject_directives(%OperationDefinition{} = operation) do
    operation_directives = operation.directives
    variable_directives = Enum.flat_map(operation.variable_definitions, & &1.directives)

    if operation_directives == [] and variable_directives == [] and
         fields_have_no_directives?(operation.selection_set) do
      :ok
    else
      {:error, :managed_directives_denied}
    end
  end

  defp fields_have_no_directives?(%SelectionSet{selections: selections}) do
    Enum.all?(selections, fn
      %Field{directives: [], selection_set: nil} -> true
      %Field{directives: [], selection_set: nested} -> fields_have_no_directives?(nested)
      _not_plain_field -> false
    end)
  end

  defp fields_have_no_directives?(_selection_set), do: false

  defp reject_introspection(%OperationDefinition{selection_set: selection_set}) do
    if fields_exclude_introspection?(selection_set),
      do: :ok,
      else: {:error, :managed_introspection_denied}
  end

  defp fields_exclude_introspection?(%SelectionSet{selections: selections}) do
    Enum.all?(selections, fn
      %Field{name: "__" <> _rest} -> false
      %Field{selection_set: nil} -> true
      %Field{selection_set: nested} -> fields_exclude_introspection?(nested)
      _not_field -> false
    end)
  end

  defp fields_exclude_introspection?(_selection_set), do: false

  defp authorize_read_roots(%OperationDefinition{
         selection_set: %SelectionSet{selections: roots}
       }) do
    if Enum.all?(roots, fn
         %Field{name: name} -> name in @managed_read_roots
         _not_field -> false
       end) do
      :ok
    else
      {:error, :managed_read_root_denied}
    end
  end

  defp authorize_read_roots(_operation), do: {:error, :managed_read_root_denied}

  defp authorize_read_fields(%OperationDefinition{
         selection_set: %SelectionSet{selections: roots}
       }) do
    if Enum.all?(roots, &managed_root_fields_allowed?/1) do
      :ok
    else
      {:error, :managed_read_field_denied}
    end
  end

  defp authorize_read_fields(_operation), do: {:error, :managed_read_field_denied}

  defp managed_root_fields_allowed?(%Field{
         name: "issue",
         selection_set: %SelectionSet{} = selection_set
       }),
       do: managed_selection_allowed?(selection_set, [])

  defp managed_root_fields_allowed?(_root), do: false

  defp managed_selection_allowed?(%SelectionSet{selections: selections}, prefix) do
    Enum.all?(selections, fn
      %Field{name: name, arguments: [], selection_set: nil} ->
        (prefix ++ [name]) in @managed_issue_read_paths

      %Field{name: name, arguments: [], selection_set: %SelectionSet{} = nested} ->
        path = prefix ++ [name]
        managed_path_prefix?(path) and managed_selection_allowed?(nested, path)

      _field_or_selection ->
        false
    end)
  end

  defp managed_path_prefix?(path) do
    Enum.any?(@managed_issue_read_paths, fn allowed_path ->
      length(allowed_path) > length(path) and Enum.take(allowed_path, length(path)) == path
    end)
  end

  defp authorize_issue_scope(
         %OperationDefinition{selection_set: %SelectionSet{selections: roots}},
         variables,
         %{issue_id: issue_id}
       ) do
    if Enum.all?(roots, &issue_root_bound?(&1, variables, issue_id)) do
      :ok
    else
      {:error, :managed_issue_scope_denied}
    end
  end

  defp issue_root_bound?(%Field{arguments: [%Argument{name: "id", value: value}]}, variables, issue_id) do
    case value do
      %StringValue{value: ^issue_id} -> true
      %Variable{name: name} -> variable_matches_issue?(variables, name, issue_id)
      _other -> false
    end
  end

  defp issue_root_bound?(_root, _variables, _issue_id), do: false

  defp variable_matches_issue?(variables, name, issue_id) do
    variables
    |> Enum.filter(fn {key, _value} -> variable_key_name(key) == name end)
    |> case do
      [{_key, ^issue_id}] -> true
      _missing_ambiguous_or_mismatched -> false
    end
  end

  defp variable_key_name(key) when is_binary(key), do: key
  defp variable_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp variable_key_name(_key), do: nil

  defp audit_denial(opts, policy, context, reason) when is_list(opts) do
    if Keyword.keyword?(opts) do
      do_audit_denial(opts, policy, context, reason)
    else
      :ok
    end
  end

  defp audit_denial(_opts, _policy, _context, _reason), do: :ok

  defp do_audit_denial(opts, policy, context, reason) do
    case Keyword.get(opts, :audit_callback) do
      callback when is_function(callback, 1) ->
        event =
          %{
            decision: :denied,
            error_code: error_code(reason),
            policy: policy,
            tool: @linear_graphql_tool
          }
          |> Map.merge(context)

        safe_audit_callback(callback, event)

      _not_configured ->
        :ok
    end
  end

  defp safe_audit_callback(callback, event) do
    callback.(event)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke_linear_client(linear_client, query, variables) do
    case linear_client.(query, variables, []) do
      {:ok, response} -> graphql_response(response)
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _invalid -> failure_response(generic_tool_error_payload())
    end
  rescue
    _error -> failure_response(generic_tool_error_payload())
  catch
    _kind, _reason -> failure_response(generic_tool_error_payload())
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _other -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload({:linear_api_status, status}) when is_integer(status) do
    %{
      "error" => %{
        "code" => "linear_api_status",
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, _reason}) do
    %{
      "error" => %{
        "code" => "linear_api_request",
        "message" => "Linear GraphQL request failed before receiving a successful response."
      }
    }
  end

  defp tool_error_payload(reason) when is_atom(reason) do
    case Map.fetch(@error_messages, reason) do
      {:ok, message} ->
        %{"error" => %{"code" => error_code(reason), "message" => message}}

      :error ->
        generic_tool_error_payload()
    end
  end

  defp tool_error_payload(_reason), do: generic_tool_error_payload()

  defp generic_tool_error_payload do
    %{
      "error" => %{
        "code" => "linear_graphql_execution_failed",
        "message" => "Linear GraphQL tool execution failed."
      }
    }
  end

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
