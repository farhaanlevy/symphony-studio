# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityReport do
  @moduledoc """
  Builds the persistence-safe public result of a no-model capability probe.

  The report deliberately omits account email and plan, Codex-home paths,
  quota amounts, usage totals, provider text, and raw payloads. It retains the
  non-reversible local identity binding required to prevent cross-account
  readiness and resume confusion.
  """

  alias SymphonyElixir.Codex.CapabilityError

  @report_version 1

  @spec public(map()) :: {:ok, map()} | {:error, CapabilityError.t()}
  def public(result) when is_map(result) do
    {:ok, build(result)}
  rescue
    _error -> {:error, CapabilityError.new(:public_report_failed)}
  catch
    _kind, _reason -> {:error, CapabilityError.new(:public_report_failed)}
  end

  def public(_result), do: {:error, CapabilityError.new(:public_report_failed)}

  defp build(%{
         account: account,
         initialize: initialize,
         models: models,
         no_model_work: true,
         optional: optional,
         quota: quota,
         reference_profile: reference_profile,
         schema_version: schema_version
       }) do
    %{
      "account" => public_account(account),
      "initialize" => public_initialize(initialize, schema_version),
      "models" => models |> Enum.map(&public_model/1) |> Enum.sort_by(&{&1["model"], &1["id"]}),
      "noModelWork" => true,
      "optional" => public_optional(optional),
      "quotaShape" => public_quota(quota),
      "referenceProfile" => public_reference_profile(reference_profile),
      "reportVersion" => @report_version,
      "schemaVersion" => required_string(schema_version)
    }
  end

  defp public_initialize(
         %{
           codex_home_absolute: codex_home_absolute,
           platform_family: platform_family,
           platform_os: platform_os,
           user_agent: user_agent
         },
         schema_version
       ) do
    true = is_boolean(codex_home_absolute)
    user_agent = required_string(user_agent)
    schema_version = required_string(schema_version)

    %{
      "codexHomeAbsolute" => codex_home_absolute,
      "platformFamily" => required_string(platform_family),
      "platformOs" => required_string(platform_os),
      "userAgentSha256" => sha256(user_agent),
      "versionAdvertised" => version_advertised?(user_agent, schema_version)
    }
  end

  defp public_account(%{
         auth_mode: auth_mode,
         authenticated: authenticated,
         identity: identity,
         plan_type: _omitted_plan_type,
         requires_openai_auth: requires_openai_auth
       }) do
    true = is_boolean(authenticated)
    true = is_boolean(requires_openai_auth)

    %{
      "authMode" => atom_name(auth_mode),
      "authenticated" => authenticated,
      "identity" => public_identity(identity),
      "requiresOpenaiAuth" => requires_openai_auth
    }
  end

  defp public_identity(%{
         binding_id: binding_id,
         evidence: evidence,
         generation: generation,
         provider_identifier_available: provider_identifier_available,
         status: status
       }) do
    true = is_integer(generation) and generation > 0
    true = is_boolean(provider_identifier_available)

    %{
      "bindingId" => nullable_string(binding_id),
      "evidence" => atom_name(evidence),
      "generation" => generation,
      "providerIdentifierAvailable" => provider_identifier_available,
      "status" => atom_name(status)
    }
  end

  defp public_model(%{
         default_reasoning_effort: default_reasoning_effort,
         default_service_tier: default_service_tier,
         hidden: hidden,
         id: id,
         is_default: is_default,
         model: model,
         reasoning_efforts: reasoning_efforts,
         service_tiers: service_tiers
       }) do
    true = is_boolean(hidden)
    true = is_boolean(is_default)

    %{
      "defaultReasoningEffort" => required_string(default_reasoning_effort),
      "defaultServiceTier" => nullable_string(default_service_tier),
      "hidden" => hidden,
      "id" => required_string(id),
      "isDefault" => is_default,
      "model" => required_string(model),
      "reasoningEfforts" => sorted_strings(reasoning_efforts),
      "fastServiceTierId" => fast_service_tier_id(service_tiers),
      "serviceTierIds" =>
        service_tiers
        |> Enum.map(fn %{id: tier_id, name: tier_name} ->
          _validated_but_omitted_name = required_string(tier_name)
          required_string(tier_id)
        end)
        |> Enum.sort()
    }
  end

  defp public_quota(%{
         bucket_count: bucket_count,
         bucket_source: bucket_source,
         fields: fields,
         out_of_range_values: out_of_range_values,
         reset_credits: reset_credits,
         window_slot_count: window_slot_count
       }) do
    true = is_integer(bucket_count) and bucket_count >= 0
    true = is_integer(window_slot_count) and window_slot_count >= 0
    true = is_boolean(out_of_range_values)

    %{
      "bucketCount" => bucket_count,
      "bucketSource" => atom_name(bucket_source),
      "fields" => sorted_atoms(fields),
      "outOfRangeValues" => out_of_range_values,
      "resetCredits" => public_reset_credits(reset_credits),
      "windowSlotCount" => window_slot_count
    }
  end

  defp public_quota(%{status: status}) when status in [:auth_restricted, :unsupported],
    do: %{"status" => atom_name(status)}

  defp public_reset_credits(%{details: details, summary: summary}) do
    %{"details" => atom_name(details), "summary" => atom_name(summary)}
  end

  defp public_optional(%{
         collaboration_modes: collaboration_modes,
         experimental_features: experimental_features,
         usage: usage
       }) do
    %{
      "collaborationModes" => public_optional_result(collaboration_modes, &public_collaboration_modes/1),
      "experimentalFeatures" => public_optional_items(experimental_features, &public_features/1),
      "usage" => public_optional_result(usage, &public_usage/1)
    }
  end

  defp public_optional_result(%{status: :available, result: result}, mapper),
    do: %{"result" => mapper.(result), "status" => "available"}

  defp public_optional_result(%{status: status}, _mapper)
       when status in [:auth_restricted, :unavailable, :unsupported],
       do: %{"status" => atom_name(status)}

  defp public_optional_items(%{status: :available, items: items}, mapper),
    do: %{"items" => mapper.(items), "status" => "available"}

  defp public_optional_items(%{status: :unsupported}, _mapper),
    do: %{"status" => "unsupported"}

  defp public_optional_items(%{status: :unavailable}, _mapper),
    do: %{"status" => "unavailable"}

  defp public_usage(%{
         daily_bucket_count: daily_bucket_count,
         populated_summary_fields: populated_summary_fields
       }) do
    true = is_integer(daily_bucket_count) and daily_bucket_count >= 0

    %{
      "dailyBucketCount" => daily_bucket_count,
      "populatedSummaryFields" => sorted_strings(populated_summary_fields)
    }
  end

  defp public_features(features) do
    features
    |> Enum.map(fn %{
                     default_enabled: default_enabled,
                     enabled: enabled,
                     name: name,
                     stage: stage
                   } ->
      true = is_boolean(default_enabled)
      true = is_boolean(enabled)

      %{
        "defaultEnabled" => default_enabled,
        "enabled" => enabled,
        "name" => required_string(name),
        "stage" => required_string(stage)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp public_collaboration_modes(modes) do
    modes
    |> Enum.map(fn %{mode: mode, model: model, name: name, reasoning_effort: effort} ->
      %{
        "mode" => nullable_string(mode),
        "model" => nullable_string(model),
        "name" => required_string(name),
        "reasoningEffort" => nullable_string(effort)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp public_reference_profile(%{
         chatgpt_authentication: chatgpt_authentication,
         identity_binding: identity_binding,
         sol_available: sol_available,
         sol_review_effort: sol_review_effort,
         sol_ultra: sol_ultra,
         status: status,
         terra_available: terra_available,
         terra_high: terra_high,
         terra_medium: terra_medium
       }) do
    values = [
      chatgpt_authentication,
      identity_binding,
      sol_available,
      sol_review_effort,
      sol_ultra,
      terra_available,
      terra_high,
      terra_medium
    ]

    true = Enum.all?(values, &is_boolean/1)

    %{
      "chatgptAuthentication" => chatgpt_authentication,
      "identityBinding" => identity_binding,
      "solAvailable" => sol_available,
      "solReviewEffort" => sol_review_effort,
      "solUltra" => sol_ultra,
      "status" => atom_name(status),
      "terraAvailable" => terra_available,
      "terraHigh" => terra_high,
      "terraMedium" => terra_medium
    }
  end

  defp fast_service_tier_id(service_tiers) do
    matches =
      Enum.filter(service_tiers, fn %{id: id, name: name} ->
        _validated_id = required_string(id)
        String.downcase(String.trim(required_string(name))) == "fast"
      end)

    case matches do
      [%{id: id}] -> required_string(id)
      _none_or_ambiguous -> nil
    end
  end

  defp version_advertised?(user_agent, schema_version) do
    escaped_version = Regex.escape(schema_version)

    Regex.match?(
      ~r/(?<![A-Za-z0-9.])#{escaped_version}(?![A-Za-z0-9.])/,
      user_agent
    )
  end

  defp sorted_atoms(values) when is_list(values), do: values |> Enum.map(&atom_name/1) |> Enum.sort()
  defp sorted_strings(values) when is_list(values), do: values |> Enum.map(&required_string/1) |> Enum.sort()

  defp atom_name(value) when is_atom(value), do: Atom.to_string(value)

  defp required_string(value) when is_binary(value) and value != "", do: value
  defp nullable_string(nil), do: nil
  defp nullable_string(value) when is_atom(value), do: atom_name(value)
  defp nullable_string(value), do: required_string(value)

  defp sha256(value) when is_binary(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
