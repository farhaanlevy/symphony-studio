# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityDiscovery do
  @moduledoc """
  Runs one bounded, no-model Codex App Server capability probe.

  The probe initializes one connection and reads only account, rate-limit,
  model, usage, feature, and collaboration metadata. It never starts a thread
  or turn, starts a review, or consumes a reset credit.
  """

  alias SymphonyElixir.Codex.{
    AppServer,
    CapabilityDecoder,
    CapabilityError,
    Connection,
    IdentityBinding,
    QuotaShape,
    SchemaBundle,
    TransportError
  }

  alias SymphonyElixir.{Config, PathSafety, Workflow}

  @model_page_size 100
  @feature_page_size 100
  @max_pages 16
  @max_models 1_024
  @max_features 1_024

  @type result :: %{
          account: map(),
          initialize: map(),
          models: [map()],
          no_model_work: true,
          optional: map(),
          quota: map(),
          reference_profile: map(),
          schema_version: String.t()
        }

  def probe(opts \\ [])

  @spec probe(keyword()) :: {:ok, result()} | {:error, CapabilityError.t()}
  def probe(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: do_probe(opts),
      else: {:error, CapabilityError.new(:invalid_probe_options)}
  end

  def probe(_invalid), do: {:error, CapabilityError.new(:invalid_probe_options)}

  defp do_probe(opts) do
    with {:ok, settings} <- configured_settings(),
         {:ok, argv} <- command_argv(settings, opts),
         {:ok, cwd} <- probe_cwd(opts),
         {:ok, forbidden_roots} <- identity_forbidden_roots(cwd, opts),
         {:ok, connection} <- open_connection(cwd, argv, settings.codex, opts) do
      run_and_close(connection, Keyword.put(opts, :identity_forbidden_roots, forbidden_roots))
    end
  end

  defp identity_forbidden_roots(cwd, opts) do
    configured = Keyword.get(opts, :identity_forbidden_roots, [])

    if is_list(configured) and Enum.all?(configured, &is_binary/1) do
      canonical_forbidden_roots([cwd, Workflow.workflow_directory() | configured])
    else
      {:error, CapabilityError.new(:invalid_probe_options)}
    end
  end

  defp canonical_forbidden_roots(roots) do
    with {:ok, canonical} <- canonicalize_roots(roots) do
      forbidden =
        canonical
        |> Enum.flat_map(&[&1, nearest_git_root(&1)])
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {:ok, forbidden}
    end
  end

  defp canonicalize_roots(roots) do
    Enum.reduce_while(roots, {:ok, []}, fn root, {:ok, canonical} ->
      case PathSafety.canonicalize(root) do
        {:ok, path} -> {:cont, {:ok, canonical ++ [path]}}
        {:error, _reason} -> {:halt, {:error, CapabilityError.new(:identity_key_unavailable)}}
      end
    end)
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

  defp configured_settings do
    case Config.settings() do
      {:ok, settings} -> {:ok, settings}
      {:error, _reason} -> {:error, CapabilityError.new(:configuration_unavailable)}
    end
  end

  defp command_argv(settings, opts) do
    result =
      case Keyword.get(opts, :command_argv) do
        nil ->
          Config.codex_command_argv(settings.codex.command)

        argv ->
          {:ok, argv}
      end

    case result do
      {:ok, [executable | _arguments] = argv}
      when is_binary(executable) and executable != "" ->
        if Enum.all?(argv, &(is_binary(&1) and &1 != "")),
          do: {:ok, argv},
          else: {:error, CapabilityError.new(:codex_command_unavailable)}

      _invalid ->
        {:error, CapabilityError.new(:codex_command_unavailable)}
    end
  end

  defp probe_cwd(opts) do
    case Keyword.get(opts, :cwd) do
      nil ->
        case File.cwd() do
          {:ok, cwd} -> {:ok, cwd}
          {:error, _reason} -> {:error, CapabilityError.new(:probe_cwd_unavailable)}
        end

      cwd when is_binary(cwd) ->
        expanded = Path.expand(cwd)
        if File.dir?(expanded), do: {:ok, expanded}, else: {:error, CapabilityError.new(:probe_cwd_unavailable)}

      _invalid ->
        {:error, CapabilityError.new(:probe_cwd_unavailable)}
    end
  end

  defp open_connection(cwd, argv, codex, opts) do
    case AppServer.open_connection(cwd, argv, codex, opts) do
      {:ok, connection} -> {:ok, connection}
      {:error, _reason} -> {:error, CapabilityError.new(:connection_start_failed)}
    end
  end

  defp run_and_close(connection, opts) do
    result = safe_probe_connection(connection, opts)
    cleanup = Connection.close(connection)

    case {result, cleanup} do
      {{:ok, _result} = success, :ok} -> success
      {{:error, %CapabilityError{}} = error, :ok} -> error
      {_result, {:error, %TransportError{}}} -> {:error, CapabilityError.new(:connection_cleanup_failed)}
    end
  end

  defp safe_probe_connection(connection, opts) do
    do_probe_connection(connection, opts)
  rescue
    _error -> {:error, CapabilityError.new(:probe_failed, nil, :unexpected_exception)}
  catch
    _kind, _reason -> {:error, CapabilityError.new(:probe_failed, nil, :unexpected_exit)}
  end

  defp do_probe_connection(connection, opts) do
    with {:ok, initialize_response} <- initialize(connection),
         {:ok, initialize} <- CapabilityDecoder.initialize(initialize_response),
         {:ok, account_response} <- required_request(connection, "account/read", %{}),
         {:ok, account} <- decode_account(account_response, opts),
         {:ok, quota} <- read_quota(connection, account),
         {:ok, models} <- collect_models(connection),
         {:ok, optional} <- collect_optional(connection, account),
         {:ok, account} <- revalidate_account(connection, account, opts) do
      reference_profile = CapabilityDecoder.reference_profile(models, account)

      {:ok,
       %{
         account: account,
         initialize: initialize,
         models: models,
         no_model_work: true,
         optional: optional,
         quota: quota,
         reference_profile: reference_profile,
         schema_version: SchemaBundle.version()
       }}
    end
  end

  defp initialize(connection) do
    case AppServer.initialize_connection(connection) do
      {:ok, response} -> {:ok, response}
      {:error, %TransportError{} = error} -> transport_failure(error, "initialize")
    end
  end

  defp decode_account(response, opts) do
    key_path = Keyword.get(opts, :identity_key_path, IdentityBinding.default_key_path())
    forbidden_roots = Keyword.get(opts, :identity_forbidden_roots, [])
    generation = Keyword.get(opts, :identity_generation, 1)

    CapabilityDecoder.account(
      response,
      fn -> IdentityBinding.load_or_create_key(key_path, forbidden_roots) end,
      generation
    )
  end

  defp collect_models(connection) do
    fetch_pages(
      connection,
      "model/list",
      %{"includeHidden" => true, "limit" => @model_page_size},
      &CapabilityDecoder.model_page/1,
      @max_models,
      [:id, :model],
      :required
    )
  end

  defp read_quota(connection, account) do
    method = "account/rateLimits/read"

    case Connection.request(connection, method, :omitted, Config.codex_request_timeout(method)) do
      {:ok, response, _metadata} ->
        QuotaShape.full(response)

      {:error, %TransportError{kind: :response_error, details: %{code: -32_600}}}
      when account.auth_mode != :chatgpt ->
        {:ok, %{status: :auth_restricted}}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_601}}}
      when account.auth_mode != :chatgpt ->
        {:ok, %{status: :unsupported}}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_601}}} ->
        {:error, CapabilityError.new(:required_method_unsupported, method)}

      {:error, %TransportError{kind: :response_error}} ->
        {:error, CapabilityError.new(:required_method_unavailable, method)}

      {:error, %TransportError{} = error} ->
        transport_failure(error, method)
    end
  end

  defp revalidate_account(connection, account, opts) do
    with {:ok, response} <- required_request(connection, "account/read", %{}),
         {:ok, current_account} <- decode_account(response, opts) do
      if current_account == account,
        do: {:ok, current_account},
        else: {:error, CapabilityError.new(:identity_changed_during_probe, "account/read")}
    end
  end

  defp collect_features(connection) do
    fetch_optional_pages(
      connection,
      "experimentalFeature/list",
      %{"limit" => @feature_page_size},
      &CapabilityDecoder.feature_page/1,
      @max_features,
      [:name],
      :optional
    )
  end

  defp collect_optional(connection, account) do
    with {:ok, usage} <-
           optional_request(
             connection,
             "account/usage/read",
             :omitted,
             &CapabilityDecoder.usage_shape/1,
             account
           ),
         {:ok, features} <- collect_features(connection),
         {:ok, collaboration_modes} <-
           optional_request(
             connection,
             "collaborationMode/list",
             %{},
             &CapabilityDecoder.collaboration_modes/1
           ) do
      {:ok,
       %{
         collaboration_modes: collaboration_modes,
         experimental_features: features,
         usage: usage
       }}
    end
  end

  defp fetch_pages(
         connection,
         method,
         first_params,
         decoder,
         max_items,
         identity_fields,
         availability
       ) do
    context = %{
      availability: availability,
      connection: connection,
      decoder: decoder,
      first_params: first_params,
      identity_fields: identity_fields,
      max_items: max_items,
      method: method
    }

    state = %{
      cursor: nil,
      items: [],
      page: 0,
      seen_cursors: [],
      seen_items: MapSet.new()
    }

    do_fetch_pages(context, state)
  end

  defp do_fetch_pages(%{method: method}, %{page: page}) when page >= @max_pages do
    {:error, CapabilityError.new(:pagination_limit_exceeded, method)}
  end

  defp do_fetch_pages(context, state) do
    params =
      if is_nil(state.cursor),
        do: context.first_params,
        else: Map.put(context.first_params, "cursor", state.cursor)

    with {:ok, response} <-
           page_request(
             context.connection,
             context.method,
             params,
             context.availability,
             state.page
           ),
         {:ok, %{items: page_items, next_cursor: next_cursor}} <- context.decoder.(response),
         {:ok, seen_items} <-
           merge_unique_items(
             page_items,
             context.identity_fields,
             state.seen_items,
             context.method
           ),
         {:ok, items} <-
           append_bounded(state.items, page_items, context.max_items, context.method),
         {:ok, seen_cursors} <-
           accept_cursor(next_cursor, state.seen_cursors, context.method) do
      if is_nil(next_cursor) do
        {:ok, items}
      else
        next_state = %{
          state
          | cursor: next_cursor,
            items: items,
            page: state.page + 1,
            seen_cursors: seen_cursors,
            seen_items: seen_items
        }

        do_fetch_pages(context, next_state)
      end
    end
  end

  defp fetch_optional_pages(connection, method, params, decoder, max_items, identity_fields, availability) do
    case fetch_pages(connection, method, params, decoder, max_items, identity_fields, availability) do
      {:ok, items} ->
        {:ok, %{items: items, status: :available}}

      {:error, %CapabilityError{kind: :optional_method_unsupported}} ->
        {:ok, %{status: :unsupported}}

      {:error, %CapabilityError{kind: :optional_method_unavailable}} ->
        {:ok, %{status: :unavailable}}

      {:error, %CapabilityError{}} = error ->
        error
    end
  end

  defp optional_request(connection, method, params, decoder, account \\ nil) do
    case Connection.request(connection, method, params, Config.codex_request_timeout(method)) do
      {:ok, response, _metadata} ->
        decode_optional_response(response, decoder)

      {:error, %TransportError{} = error} ->
        classify_optional_error(error, method, account)
    end
  end

  defp decode_optional_response(response, decoder) do
    case decoder.(response) do
      {:ok, decoded} -> {:ok, %{result: decoded, status: :available}}
      {:error, %CapabilityError{}} = error -> error
    end
  end

  defp classify_optional_error(
         %TransportError{kind: :response_error, details: %{code: -32_601}},
         _method,
         _account
       ),
       do: {:ok, %{status: :unsupported}}

  defp classify_optional_error(
         %TransportError{kind: :response_error, details: %{code: -32_600}},
         "account/usage/read",
         %{auth_mode: auth_mode}
       )
       when auth_mode != :chatgpt,
       do: {:ok, %{status: :auth_restricted}}

  defp classify_optional_error(
         %TransportError{kind: :response_error, details: %{code: -32_600}},
         method,
         _account
       ),
       do: {:error, CapabilityError.new(:optional_method_probe_failed, method, :invalid_request)}

  defp classify_optional_error(
         %TransportError{kind: :response_error, details: %{code: -32_602}},
         method,
         _account
       ),
       do: {:error, CapabilityError.new(:optional_method_probe_failed, method, :response_error)}

  defp classify_optional_error(
         %TransportError{kind: :response_error},
         _method,
         _account
       ),
       do: {:ok, %{status: :unavailable}}

  defp classify_optional_error(%TransportError{} = error, method, _account),
    do: transport_failure(error, method)

  defp required_request(connection, method, params) do
    case Connection.request(connection, method, params, Config.codex_request_timeout(method)) do
      {:ok, response, _metadata} ->
        {:ok, response}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_601}}} ->
        {:error, CapabilityError.new(:required_method_unsupported, method)}

      {:error, %TransportError{kind: :response_error}} ->
        {:error, CapabilityError.new(:required_method_unavailable, method)}

      {:error, %TransportError{} = error} ->
        transport_failure(error, method)
    end
  end

  defp page_request(connection, method, params, :required, _page),
    do: required_request(connection, method, params)

  defp page_request(connection, method, params, :optional, page) do
    case Connection.request(connection, method, params, Config.codex_request_timeout(method)) do
      {:ok, response, _metadata} ->
        {:ok, response}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_601}}}
      when page == 0 ->
        {:error, CapabilityError.new(:optional_method_unsupported, method)}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_600}}} ->
        {:error, CapabilityError.new(:optional_method_probe_failed, method, :invalid_request)}

      {:error, %TransportError{kind: :response_error, details: %{code: -32_602}}} ->
        {:error, CapabilityError.new(:optional_method_probe_failed, method, :response_error)}

      {:error, %TransportError{kind: :response_error}} ->
        {:error, CapabilityError.new(:optional_method_unavailable, method, :response_error)}

      {:error, %TransportError{} = error} ->
        transport_failure(error, method)
    end
  end

  defp transport_failure(%TransportError{kind: kind}, method) do
    {:error, CapabilityError.new(:transport_failure, method, kind)}
  end

  defp merge_unique_items(items, fields, seen, method) do
    Enum.reduce_while(items, {:ok, seen}, fn item, {:ok, current} ->
      identities = Enum.map(fields, &{&1, Map.fetch!(item, &1)})

      if Enum.any?(identities, &MapSet.member?(current, &1)) do
        {:halt, {:error, CapabilityError.new(:duplicate_capability, method)}}
      else
        {:cont, {:ok, Enum.reduce(identities, current, &MapSet.put(&2, &1))}}
      end
    end)
  end

  defp append_bounded(items, page_items, max_items, method) do
    if length(items) + length(page_items) <= max_items,
      do: {:ok, items ++ page_items},
      else: {:error, CapabilityError.new(:pagination_limit_exceeded, method)}
  end

  defp accept_cursor(nil, seen, _method), do: {:ok, seen}

  defp accept_cursor(cursor, seen, method) do
    if Enum.member?(seen, cursor),
      do: {:error, CapabilityError.new(:pagination_cycle, method)},
      else: {:ok, [cursor | seen]}
  end
end
