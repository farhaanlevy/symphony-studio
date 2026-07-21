# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.QuotaShape do
  @moduledoc """
  Validates dynamic Codex quota payload shapes without retaining quota values.

  Release 0 needs to prove full and sparse response compatibility. Durable
  quota snapshots, replacement/patch semantics, scheduling, and presentation
  remain owned by Release 1. Sparse summaries keep populated and explicit-null
  fields separate so a persisted conformance artifact does not collapse either
  state into omission.
  """

  alias SymphonyElixir.Codex.CapabilityError

  @full_method "account/rateLimits/read"
  @update_method "account/rateLimits/updated"
  @max_buckets 128
  @max_identifier_bytes 256
  @max_text_bytes 1_024
  @max_reset_credit_details 64

  @plan_types ~w(
    free go plus pro prolite team self_serve_business_usage_based business
    enterprise_cbp_usage_based enterprise edu unknown
  )
  @reached_types ~w(
    rate_limit_reached workspace_owner_credits_depleted
    workspace_member_credits_depleted workspace_owner_usage_limit_reached
    workspace_member_usage_limit_reached
  )
  @reset_statuses ~w(available redeeming redeemed unknown)
  @reset_types ~w(codexRateLimits unknown)
  @snapshot_fields [
    {"credits", :credits},
    {"individualLimit", :spend_control},
    {"limitId", :limit_id},
    {"limitName", :limit_name},
    {"planType", :plan_type},
    {"primary", :primary},
    {"rateLimitReachedType", :reached_type},
    {"secondary", :secondary}
  ]

  @type summary :: %{
          bucket_count: non_neg_integer(),
          bucket_source: :fallback | :multi,
          fields: [atom()],
          out_of_range_values: boolean(),
          reset_credits: map(),
          window_slot_count: non_neg_integer()
        }

  @spec full(term()) :: {:ok, summary()} | {:error, CapabilityError.t()}
  def full(response) do
    with {:ok, response} <- object(response, @full_method),
         {:ok, fallback} <- required_map(response, "rateLimits", @full_method),
         {:ok, bucket_source, snapshots} <- select_full_snapshots(response, fallback),
         {:ok, snapshot_summary} <- summarize_snapshots(snapshots, @full_method),
         {:ok, reset_credits, reset_out_of_range} <- decode_reset_credits(response) do
      {:ok,
       snapshot_summary
       |> Map.put(:bucket_source, bucket_source)
       |> Map.put(:reset_credits, reset_credits)
       |> Map.update!(:out_of_range_values, &(&1 or reset_out_of_range))}
    end
  end

  @spec sparse_update(term()) :: {:ok, map()} | {:error, CapabilityError.t()}
  def sparse_update(response) do
    with {:ok, response} <- object(response, @update_method),
         {:ok, snapshot} <- required_map(response, "rateLimits", @update_method),
         {:ok, summary} <- summarize_snapshots([snapshot], @update_method) do
      {:ok,
       summary
       |> Map.delete(:bucket_count)
       |> Map.put(:null_fields, null_snapshot_fields(snapshot))
       |> Map.put(:patch_semantics, :sparse)}
    end
  end

  defp null_snapshot_fields(snapshot) do
    @snapshot_fields
    |> Enum.filter(fn {source, _target} ->
      Map.has_key?(snapshot, source) and is_nil(Map.get(snapshot, source))
    end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
  end

  defp select_full_snapshots(response, fallback) do
    case Map.get(response, "rateLimitsByLimitId") do
      nil ->
        {:ok, :fallback, [fallback]}

      buckets when is_map(buckets) and map_size(buckets) <= @max_buckets ->
        with :ok <- validate_bucket_entries(buckets) do
          {:ok, :multi, Map.values(buckets)}
        end

      buckets when is_map(buckets) ->
        invalid(@full_method, :response_limit_exceeded)

      _other ->
        invalid(@full_method, :invalid_field_type)
    end
  end

  defp validate_bucket_entries(buckets) do
    Enum.reduce_while(buckets, :ok, fn
      {key, snapshot}, :ok when is_map(snapshot) ->
        cond do
          not valid_identifier?(key) ->
            {:halt, invalid(@full_method, :invalid_bucket_identifier)}

          is_binary(snapshot["limitId"]) and snapshot["limitId"] != key ->
            {:halt, invalid(@full_method, :bucket_identifier_mismatch)}

          true ->
            {:cont, :ok}
        end

      {key, _snapshot}, :ok ->
        if valid_identifier?(key),
          do: {:cont, :ok},
          else: {:halt, invalid(@full_method, :invalid_bucket_identifier)}
    end)
  end

  defp summarize_snapshots(snapshots, method) do
    snapshots
    |> Enum.reduce_while({:ok, empty_summary()}, fn snapshot, {:ok, summary} ->
      case decode_snapshot(snapshot, method) do
        {:ok, decoded} -> {:cont, {:ok, merge_snapshot_summary(summary, decoded)}}
        {:error, %CapabilityError{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, summary} ->
        {:ok,
         summary
         |> Map.put(:bucket_count, length(snapshots))
         |> Map.update!(:fields, &Enum.sort/1)}

      {:error, %CapabilityError{}} = error ->
        error
    end
  end

  defp empty_summary do
    %{
      fields: MapSet.new(),
      out_of_range_values: false,
      window_slot_count: 0
    }
  end

  defp merge_snapshot_summary(summary, decoded) do
    %{
      fields: MapSet.union(summary.fields, decoded.fields),
      out_of_range_values: summary.out_of_range_values or decoded.out_of_range_values,
      window_slot_count: summary.window_slot_count + decoded.window_slot_count
    }
  end

  defp decode_snapshot(snapshot, method) do
    with {:ok, snapshot} <- object(snapshot, method),
         :ok <- nullable_bounded_string(snapshot, "limitId", method, @max_identifier_bytes),
         :ok <- nullable_bounded_string(snapshot, "limitName", method, @max_text_bytes),
         :ok <- nullable_enum(snapshot, "planType", @plan_types, method),
         :ok <- nullable_enum(snapshot, "rateLimitReachedType", @reached_types, method),
         {:ok, primary} <- decode_window(Map.get(snapshot, "primary"), method),
         {:ok, secondary} <- decode_window(Map.get(snapshot, "secondary"), method),
         :ok <- decode_credits(Map.get(snapshot, "credits"), method),
         {:ok, spend_control_out_of_range} <-
           decode_spend_control(Map.get(snapshot, "individualLimit"), method) do
      fields =
        @snapshot_fields
        |> Enum.filter(fn {source, _target} ->
          Map.has_key?(snapshot, source) and not is_nil(Map.get(snapshot, source))
        end)
        |> Enum.map(&elem(&1, 1))
        |> MapSet.new()

      {:ok,
       %{
         fields: fields,
         out_of_range_values: primary.out_of_range or secondary.out_of_range or spend_control_out_of_range,
         window_slot_count: primary.count + secondary.count
       }}
    end
  end

  defp decode_window(nil, _method), do: {:ok, %{count: 0, out_of_range: false}}

  defp decode_window(window, method) do
    with {:ok, window} <- object(window, method),
         {:ok, used_percent} <- required_integer(window, "usedPercent", method),
         :ok <- nullable_integer(window, "windowDurationMins", method),
         :ok <- nullable_integer(window, "resetsAt", method) do
      {:ok, %{count: 1, out_of_range: used_percent < 0 or used_percent > 100}}
    end
  end

  defp decode_credits(nil, _method), do: :ok

  defp decode_credits(credits, method) do
    with {:ok, credits} <- object(credits, method),
         {:ok, _has_credits} <- required_boolean(credits, "hasCredits", method),
         {:ok, _unlimited} <- required_boolean(credits, "unlimited", method) do
      nullable_bounded_string(credits, "balance", method, @max_text_bytes)
    end
  end

  defp decode_spend_control(nil, _method), do: {:ok, false}

  defp decode_spend_control(spend_control, method) do
    with {:ok, spend_control} <- object(spend_control, method),
         {:ok, _limit} <- required_string(spend_control, "limit", method, @max_text_bytes),
         {:ok, _used} <- required_string(spend_control, "used", method, @max_text_bytes),
         {:ok, remaining_percent} <-
           required_integer(spend_control, "remainingPercent", method),
         {:ok, _resets_at} <- required_integer(spend_control, "resetsAt", method) do
      {:ok, remaining_percent < 0 or remaining_percent > 100}
    end
  end

  defp decode_reset_credits(response) do
    case Map.get(response, "rateLimitResetCredits") do
      nil ->
        {:ok, %{details: :unavailable, summary: :absent}, false}

      reset_credits when is_map(reset_credits) ->
        with {:ok, available_count} <-
               required_integer(reset_credits, "availableCount", @full_method),
             {:ok, detail_status} <- decode_reset_credit_details(reset_credits) do
          {:ok, %{details: detail_status, summary: :present}, available_count < 0}
        end

      _other ->
        invalid(@full_method, :invalid_field_type)
    end
  end

  defp decode_reset_credit_details(reset_credits) do
    case Map.get(reset_credits, "credits") do
      nil ->
        {:ok, :unavailable}

      credits when is_list(credits) and length(credits) <= @max_reset_credit_details ->
        with :ok <- validate_reset_credit_items(credits) do
          {:ok, if(credits == [], do: :empty, else: :present)}
        end

      credits when is_list(credits) ->
        invalid(@full_method, :response_limit_exceeded)

      _other ->
        invalid(@full_method, :invalid_field_type)
    end
  end

  defp validate_reset_credit_items(credits) do
    Enum.reduce_while(credits, :ok, fn credit, :ok ->
      case decode_reset_credit(credit) do
        :ok -> {:cont, :ok}
        {:error, %CapabilityError{}} = error -> {:halt, error}
      end
    end)
  end

  defp decode_reset_credit(credit) do
    with {:ok, credit} <- object(credit, @full_method),
         {:ok, _id} <-
           required_string(credit, "id", @full_method, @max_identifier_bytes),
         :ok <- required_enum(credit, "status", @reset_statuses, @full_method),
         :ok <- required_enum(credit, "resetType", @reset_types, @full_method),
         {:ok, _granted_at} <- required_integer(credit, "grantedAt", @full_method),
         :ok <- nullable_integer(credit, "expiresAt", @full_method),
         :ok <- nullable_bounded_string(credit, "title", @full_method, @max_text_bytes) do
      nullable_bounded_string(credit, "description", @full_method, @max_text_bytes)
    end
  end

  defp valid_identifier?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_identifier_bytes

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

  defp required_integer(map, key, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
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

  defp nullable_integer(map, key, method) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_integer(value) -> :ok
      _other -> invalid(method, :invalid_field_type)
    end
  end

  defp nullable_bounded_string(map, key, method, max_bytes) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_binary(value) and byte_size(value) <= max_bytes -> :ok
      value when is_binary(value) -> invalid(method, :response_limit_exceeded)
      _other -> invalid(method, :invalid_field_type)
    end
  end

  defp nullable_enum(map, key, values, method) do
    case Map.get(map, key) do
      nil -> :ok
      value when is_binary(value) -> if(value in values, do: :ok, else: invalid(method, :invalid_enum))
      _other -> invalid(method, :invalid_enum)
    end
  end

  defp required_enum(map, key, values, method) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) ->
        if value in values, do: :ok, else: invalid(method, :invalid_enum)

      :error ->
        invalid(method, :missing_required_field)

      {:ok, _other} ->
        invalid(method, :invalid_enum)
    end
  end

  defp invalid(method, reason),
    do: {:error, CapabilityError.new(:invalid_response_shape, method, reason)}
end
