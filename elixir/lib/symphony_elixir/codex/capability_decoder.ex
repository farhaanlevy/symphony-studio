# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityDecoder do
  @moduledoc """
  Strict, bounded decoders for the no-model Codex capability surface.

  Returned values contain only policy-relevant metadata. Account email,
  Codex-home paths, quota amounts, usage totals, provider descriptions, and
  raw error content are never returned.
  """

  alias SymphonyElixir.Codex.{CapabilityError, IdentityBinding}

  @initialize_method "initialize"
  @account_method "account/read"
  @account_updated_method "account/updated"
  @model_method "model/list"
  @feature_method "experimentalFeature/list"
  @collaboration_method "collaborationMode/list"
  @usage_method "account/usage/read"

  @max_identifier_bytes 256
  @max_text_bytes 1_024
  @max_models_per_page 256
  @max_efforts_per_model 32
  @max_tiers_per_model 32
  @max_features_per_page 256
  @max_collaboration_modes 64
  @max_usage_buckets 400

  @plan_types ~w(
    free go plus pro prolite team self_serve_business_usage_based business
    enterprise_cbp_usage_based enterprise edu unknown
  )
  @auth_modes ~w(
    apikey chatgpt chatgptAuthTokens headers agentIdentity personalAccessToken bedrockApiKey
  )
  @feature_stages ~w(beta underDevelopment stable deprecated removed)
  @collaboration_mode_kinds ~w(plan default)
  @usage_summary_fields ~w(
    currentStreakDays lifetimeTokens longestRunningTurnSec longestStreakDays
    peakDailyTokens
  )

  @type decoded_page :: %{items: [map()], next_cursor: String.t() | nil}

  @spec initialize(term()) :: {:ok, map()} | {:error, CapabilityError.t()}
  def initialize(response) do
    with {:ok, response} <- object(response, @initialize_method),
         {:ok, codex_home} <- required_string(response, "codexHome", @initialize_method, @max_text_bytes),
         true <- Path.type(codex_home) == :absolute,
         {:ok, platform_family} <-
           required_string(response, "platformFamily", @initialize_method, @max_identifier_bytes),
         {:ok, platform_os} <-
           required_string(response, "platformOs", @initialize_method, @max_identifier_bytes),
         {:ok, user_agent} <-
           required_string(response, "userAgent", @initialize_method, @max_text_bytes) do
      {:ok,
       %{
         codex_home_absolute: true,
         platform_family: platform_family,
         platform_os: platform_os,
         user_agent: user_agent
       }}
    else
      false -> invalid(@initialize_method, :invalid_absolute_path)
      {:error, %CapabilityError{}} = error -> error
    end
  end

  def account(response, identity_key_provider, generation \\ 1)

  @spec account(term(), (-> {:ok, binary()} | {:error, CapabilityError.t()}), pos_integer()) ::
          {:ok, map()} | {:error, CapabilityError.t()}
  def account(response, identity_key_provider, generation)
      when is_function(identity_key_provider, 0) and is_integer(generation) and generation > 0 do
    with {:ok, response} <- object(response, @account_method),
         {:ok, requires_openai_auth} <-
           required_boolean(response, "requiresOpenaiAuth", @account_method) do
      decode_account_value(
        Map.get(response, "account"),
        requires_openai_auth,
        identity_key_provider,
        generation
      )
    end
  end

  def account(_response, _identity_key_provider, _generation),
    do: invalid(@account_method, :invalid_decoder_options)

  @spec account_updated(term()) :: {:ok, map()} | {:error, CapabilityError.t()}
  def account_updated(response) do
    with {:ok, response} <- object(response, @account_updated_method),
         {:ok, auth_mode} <-
           required_nullable_enum(response, "authMode", @auth_modes, @account_updated_method),
         {:ok, plan_type} <-
           required_nullable_enum(response, "planType", @plan_types, @account_updated_method) do
      canonical_mode = canonical_auth_mode(auth_mode)

      {:ok,
       %{
         auth_mode: canonical_mode,
         authenticated: not is_nil(auth_mode),
         identity_binding_action: if(is_nil(auth_mode), do: :invalidate, else: :revalidate),
         plan_type: plan_type
       }}
    end
  end

  @spec model_page(term()) :: {:ok, decoded_page()} | {:error, CapabilityError.t()}
  def model_page(response) do
    with {:ok, response} <- object(response, @model_method),
         {:ok, data} <- required_list(response, "data", @model_method, @max_models_per_page),
         {:ok, models} <- map_items(data, &decode_model/1),
         :ok <- unique_model_keys(models),
         {:ok, next_cursor} <- optional_cursor(response, @model_method) do
      {:ok, %{items: models, next_cursor: next_cursor}}
    end
  end

  @spec feature_page(term()) :: {:ok, decoded_page()} | {:error, CapabilityError.t()}
  def feature_page(response) do
    with {:ok, response} <- object(response, @feature_method),
         {:ok, data} <-
           required_list(response, "data", @feature_method, @max_features_per_page),
         {:ok, features} <- map_items(data, &decode_feature/1),
         :ok <- unique_field(features, :name, @feature_method),
         {:ok, next_cursor} <- optional_cursor(response, @feature_method) do
      {:ok, %{items: features, next_cursor: next_cursor}}
    end
  end

  @spec collaboration_modes(term()) :: {:ok, [map()]} | {:error, CapabilityError.t()}
  def collaboration_modes(response) do
    with {:ok, response} <- object(response, @collaboration_method),
         {:ok, data} <-
           required_list(
             response,
             "data",
             @collaboration_method,
             @max_collaboration_modes
           ),
         {:ok, modes} <- map_items(data, &decode_collaboration_mode/1),
         :ok <- unique_field(modes, :name, @collaboration_method) do
      {:ok, modes}
    end
  end

  @spec usage_shape(term()) :: {:ok, map()} | {:error, CapabilityError.t()}
  def usage_shape(response) do
    with {:ok, response} <- object(response, @usage_method),
         {:ok, summary} <- required_map(response, "summary", @usage_method),
         :ok <- validate_usage_summary(summary),
         {:ok, daily_buckets} <- optional_usage_buckets(response) do
      populated_summary_fields =
        Enum.filter(@usage_summary_fields, &(not is_nil(Map.get(summary, &1))))

      {:ok,
       %{
         daily_bucket_count: length(daily_buckets),
         populated_summary_fields: populated_summary_fields
       }}
    end
  end

  @spec reference_profile([map()], map()) :: map()
  def reference_profile(models, account) when is_list(models) and is_map(account) do
    sol = find_model(models, "gpt-5.6-sol")
    terra = find_model(models, "gpt-5.6-terra")
    sol_efforts = if sol, do: Map.fetch!(sol, :reasoning_efforts), else: []
    terra_efforts = if terra, do: Map.fetch!(terra, :reasoning_efforts), else: []

    result = %{
      chatgpt_authentication: account[:auth_mode] == :chatgpt and account[:authenticated] == true,
      identity_binding: get_in(account, [:identity, :status]) == :confirmed,
      sol_available: not is_nil(sol),
      sol_ultra: "ultra" in sol_efforts,
      sol_review_effort: Enum.any?(~w(high max), &(&1 in sol_efforts)),
      terra_available: not is_nil(terra),
      terra_high: "high" in terra_efforts,
      terra_medium: "medium" in terra_efforts
    }

    Map.put(result, :status, if(Enum.all?(result, fn {_key, value} -> value end), do: :pass, else: :fail))
  end

  defp decode_account_value(nil, requires_openai_auth, _key_provider, generation) do
    {:ok,
     %{
       auth_mode: :unavailable,
       authenticated: false,
       identity: IdentityBinding.unconfirmed(generation),
       plan_type: nil,
       requires_openai_auth: requires_openai_auth
     }}
  end

  defp decode_account_value(
         %{"type" => "apiKey"},
         requires_openai_auth,
         _key_provider,
         generation
       ) do
    {:ok,
     %{
       auth_mode: :api_key,
       authenticated: true,
       identity: IdentityBinding.unconfirmed(generation),
       plan_type: nil,
       requires_openai_auth: requires_openai_auth
     }}
  end

  defp decode_account_value(
         %{"type" => "chatgpt"} = account,
         requires_openai_auth,
         key_provider,
         generation
       ) do
    with {:ok, plan_type} <- required_enum(account, "planType", @plan_types, @account_method),
         {:ok, email} <- required_nullable_string(account, "email", @account_method, 320),
         {:ok, binding} <- derive_chatgpt_binding(account, email, key_provider, generation) do
      {:ok,
       %{
         auth_mode: :chatgpt,
         authenticated: true,
         identity: binding,
         plan_type: plan_type,
         requires_openai_auth: requires_openai_auth
       }}
    end
  end

  defp decode_account_value(
         %{"type" => "amazonBedrock"} = account,
         requires_openai_auth,
         _key_provider,
         generation
       ) do
    with :ok <- validate_bedrock_credential_source(account) do
      {:ok,
       %{
         auth_mode: :unsupported,
         authenticated: true,
         identity: IdentityBinding.unconfirmed(generation),
         plan_type: nil,
         requires_openai_auth: requires_openai_auth
       }}
    end
  end

  defp decode_account_value(_account, _requires_openai_auth, _key_provider, _generation),
    do: invalid(@account_method, :invalid_account)

  defp derive_chatgpt_binding(_account, nil, _key_provider, generation),
    do: {:ok, IdentityBinding.unconfirmed(generation)}

  defp derive_chatgpt_binding(account, email, key_provider, generation) when is_binary(email) do
    if String.trim(email) == "" do
      {:ok, IdentityBinding.unconfirmed(generation)}
    else
      with {:ok, key} <- key_provider.(),
           {:ok, binding} <- IdentityBinding.derive(account, key, generation) do
        {:ok, binding}
      else
        {:error, %CapabilityError{}} = error -> error
        _other -> invalid(@account_method, :identity_key_unavailable)
      end
    end
  end

  defp validate_bedrock_credential_source(account) do
    case Map.get(account, "credentialSource", "awsManaged") do
      source when source in ~w(codexManaged awsManaged) -> :ok
      _other -> invalid(@account_method, :invalid_account)
    end
  end

  defp decode_model(value) do
    with {:ok, model} <- object(value, @model_method),
         {:ok, id} <- required_string(model, "id", @model_method, @max_identifier_bytes),
         {:ok, slug} <-
           required_string(model, "model", @model_method, @max_identifier_bytes),
         {:ok, _description} <-
           required_string(model, "description", @model_method, @max_text_bytes),
         {:ok, _display_name} <-
           required_string(model, "displayName", @model_method, @max_text_bytes),
         {:ok, default_effort} <-
           required_string(
             model,
             "defaultReasoningEffort",
             @model_method,
             @max_identifier_bytes
           ),
         {:ok, efforts} <- decode_efforts(model),
         :ok <- member(efforts, default_effort, @model_method, :inconsistent_default_effort),
         {:ok, tiers} <- decode_service_tiers(model),
         {:ok, default_tier} <-
           nullable_string(model, "defaultServiceTier", @model_method, @max_identifier_bytes),
         :ok <- default_tier_supported(tiers, default_tier),
         {:ok, hidden} <- required_boolean(model, "hidden", @model_method),
         {:ok, is_default} <- required_boolean(model, "isDefault", @model_method) do
      {:ok,
       %{
         default_reasoning_effort: default_effort,
         default_service_tier: default_tier,
         hidden: hidden,
         id: id,
         is_default: is_default,
         model: slug,
         reasoning_efforts: efforts,
         service_tiers: tiers
       }}
    end
  end

  defp decode_efforts(model) do
    with {:ok, efforts} <-
           required_list(
             model,
             "supportedReasoningEfforts",
             @model_method,
             @max_efforts_per_model
           ),
         {:ok, efforts} <- map_items(efforts, &decode_effort/1),
         :ok <- unique_scalar(efforts, @model_method) do
      {:ok, efforts}
    end
  end

  defp decode_effort(value) do
    with {:ok, effort} <- object(value, @model_method),
         {:ok, _description} <-
           required_string(effort, "description", @model_method, @max_text_bytes) do
      required_string(
        effort,
        "reasoningEffort",
        @model_method,
        @max_identifier_bytes
      )
    end
  end

  defp decode_service_tiers(model) do
    with {:ok, tiers} <-
           optional_list(model, "serviceTiers", @model_method, @max_tiers_per_model, []),
         {:ok, tiers} <- map_items(tiers, &decode_service_tier/1),
         :ok <- unique_field(tiers, :id, @model_method) do
      {:ok, tiers}
    end
  end

  defp decode_service_tier(value) do
    with {:ok, tier} <- object(value, @model_method),
         {:ok, id} <- required_string(tier, "id", @model_method, @max_identifier_bytes),
         {:ok, name} <- required_string(tier, "name", @model_method, @max_identifier_bytes),
         {:ok, _description} <-
           required_string(tier, "description", @model_method, @max_text_bytes) do
      {:ok, %{id: id, name: name}}
    end
  end

  defp decode_feature(value) do
    with {:ok, feature} <- object(value, @feature_method),
         {:ok, name} <-
           required_string(feature, "name", @feature_method, @max_identifier_bytes),
         {:ok, stage} <-
           required_enum(feature, "stage", @feature_stages, @feature_method),
         {:ok, enabled} <- required_boolean(feature, "enabled", @feature_method),
         {:ok, default_enabled} <-
           required_boolean(feature, "defaultEnabled", @feature_method) do
      {:ok,
       %{
         default_enabled: default_enabled,
         enabled: enabled,
         name: name,
         stage: stage
       }}
    end
  end

  defp decode_collaboration_mode(value) do
    with {:ok, mode} <- object(value, @collaboration_method),
         {:ok, name} <-
           required_string(mode, "name", @collaboration_method, @max_identifier_bytes),
         {:ok, mode_kind} <-
           nullable_enum(mode, "mode", @collaboration_mode_kinds, @collaboration_method),
         {:ok, model} <-
           nullable_string(mode, "model", @collaboration_method, @max_identifier_bytes),
         {:ok, effort} <-
           nullable_string(
             mode,
             "reasoning_effort",
             @collaboration_method,
             @max_identifier_bytes
           ) do
      {:ok, %{mode: mode_kind, model: model, name: name, reasoning_effort: effort}}
    end
  end

  defp validate_usage_summary(summary) do
    Enum.reduce_while(@usage_summary_fields, :ok, fn field, :ok ->
      case Map.get(summary, field) do
        nil -> {:cont, :ok}
        value when is_integer(value) -> {:cont, :ok}
        _other -> {:halt, invalid(@usage_method, :invalid_usage_summary)}
      end
    end)
  end

  defp optional_usage_buckets(response) do
    with {:ok, buckets} <-
           optional_list(
             response,
             "dailyUsageBuckets",
             @usage_method,
             @max_usage_buckets,
             []
           ),
         {:ok, _validated} <- map_items(buckets, &decode_usage_bucket/1) do
      {:ok, buckets}
    end
  end

  defp decode_usage_bucket(value) do
    with {:ok, bucket} <- object(value, @usage_method),
         {:ok, _date} <- required_string(bucket, "startDate", @usage_method, 64),
         {:ok, _tokens} <- required_integer(bucket, "tokens", @usage_method) do
      {:ok, :valid}
    end
  end

  defp find_model(models, required) do
    Enum.find(models, fn model ->
      model[:hidden] == false and model[:model] == required
    end)
  end

  defp default_tier_supported(_tiers, nil), do: :ok

  defp default_tier_supported(tiers, default_tier) do
    member(Enum.map(tiers, & &1.id), default_tier, @model_method, :inconsistent_default_tier)
  end

  defp member(values, value, method, reason) do
    if value in values, do: :ok, else: invalid(method, reason)
  end

  defp canonical_auth_mode(nil), do: :unavailable
  defp canonical_auth_mode("apikey"), do: :api_key
  defp canonical_auth_mode("chatgpt"), do: :chatgpt
  defp canonical_auth_mode(_supported_other), do: :unsupported

  defp unique_model_keys(models) do
    with :ok <- unique_field(models, :id, @model_method) do
      unique_field(models, :model, @model_method)
    end
  end

  defp unique_field(items, field, method) do
    items |> Enum.map(&Map.fetch!(&1, field)) |> unique_scalar(method)
  end

  defp unique_scalar(items, method) do
    if Enum.uniq(items) == items, do: :ok, else: invalid(method, :duplicate_identifier)
  end

  defp optional_cursor(response, method) do
    case Map.get(response, "nextCursor") do
      nil ->
        {:ok, nil}

      cursor when is_binary(cursor) and cursor != "" and byte_size(cursor) <= @max_text_bytes ->
        {:ok, cursor}

      cursor when is_binary(cursor) and byte_size(cursor) > @max_text_bytes ->
        invalid(method, :response_limit_exceeded)

      _other ->
        invalid(method, :invalid_cursor)
    end
  end

  defp map_items(items, decoder) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, decoded} ->
      case decoder.(item) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, %CapabilityError{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, %CapabilityError{}} = error -> error
    end
  end

  defp object(value, _method) when is_map(value), do: {:ok, value}
  defp object(_value, method), do: invalid(method, :expected_object)

  defp required_map(map, key, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      :error -> invalid(method, :missing_required_field)
      {:ok, _other} -> invalid(method, :invalid_field_type)
    end
  end

  defp required_string(map, key, method, max_bytes) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" and byte_size(value) <= max_bytes ->
        {:ok, value}

      :error ->
        invalid(method, :missing_required_field)

      {:ok, value} when is_binary(value) and byte_size(value) > max_bytes ->
        invalid(method, :response_limit_exceeded)

      {:ok, _other} ->
        invalid(method, :invalid_field_type)
    end
  end

  defp nullable_string(map, key, method, max_bytes) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and byte_size(value) <= max_bytes -> {:ok, value}
      value when is_binary(value) -> invalid(method, :response_limit_exceeded)
      _other -> invalid(method, :invalid_field_type)
    end
  end

  defp required_nullable_string(map, key, method, max_bytes) do
    case Map.fetch(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} when is_binary(value) and byte_size(value) <= max_bytes -> {:ok, value}
      {:ok, value} when is_binary(value) -> invalid(method, :response_limit_exceeded)
      :error -> invalid(method, :missing_required_field)
      {:ok, _other} -> invalid(method, :invalid_field_type)
    end
  end

  defp required_boolean(map, key, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      :error -> invalid(method, :missing_required_field)
      {:ok, _other} -> invalid(method, :invalid_field_type)
    end
  end

  defp required_integer(map, key, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      :error -> invalid(method, :missing_required_field)
      {:ok, _other} -> invalid(method, :invalid_field_type)
    end
  end

  defp required_list(map, key, method, max_items) do
    case Map.fetch(map, key) do
      {:ok, value} when is_list(value) and length(value) <= max_items -> {:ok, value}
      {:ok, value} when is_list(value) -> invalid(method, :response_limit_exceeded)
      :error -> invalid(method, :missing_required_field)
      {:ok, _other} -> invalid(method, :invalid_field_type)
    end
  end

  defp optional_list(map, key, method, max_items, default) do
    case Map.get(map, key, default) do
      nil -> {:ok, default}
      value when is_list(value) and length(value) <= max_items -> {:ok, value}
      value when is_list(value) -> invalid(method, :response_limit_exceeded)
      _other -> invalid(method, :invalid_field_type)
    end
  end

  defp required_enum(map, key, values, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if value in values, do: {:ok, value}, else: invalid(method, :invalid_enum)

      :error ->
        invalid(method, :missing_required_field)

      {:ok, _other} ->
        invalid(method, :invalid_enum)
    end
  end

  defp nullable_enum(map, key, values, method) do
    case Map.get(map, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        if value in values, do: {:ok, value}, else: invalid(method, :invalid_enum)

      _other ->
        invalid(method, :invalid_enum)
    end
  end

  defp required_nullable_enum(map, key, values, method) do
    case Map.fetch(map, key) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        if value in values, do: {:ok, value}, else: invalid(method, :invalid_enum)

      :error ->
        invalid(method, :missing_required_field)

      {:ok, _other} ->
        invalid(method, :invalid_enum)
    end
  end

  defp invalid(method, reason),
    do: {:error, CapabilityError.new(:invalid_response_shape, method, reason)}
end
