# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Result do
  @moduledoc """
  Validated reconciliation or execution result from a Linear write broker.

  `confirmed` is the only externally successful state. `uncertain` must retain
  the same idempotency key and reconcile before another execution attempt.
  """

  @enforce_keys [:status, :provider, :external_id, :issue_identifier, :details]
  defstruct @enforce_keys

  @type status :: :absent | :confirmed | :uncertain | :rejected
  @type t :: %__MODULE__{
          status: status(),
          provider: String.t(),
          external_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          details: map()
        }
  @type error :: {:invalid_linear_write_result, atom()}

  @doc "Builds and validates one broker result."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, error()}
  def new(%__MODULE__{} = result) do
    with true <- result.status in [:absent, :confirmed, :uncertain, :rejected],
         true <- bounded_provider?(result.provider),
         true <- optional_identifier?(result.external_id, 256),
         true <- optional_identifier?(result.issue_identifier, 64),
         true <- is_map(result.details),
         :ok <- validate_status_fields(result) do
      {:ok, result}
    else
      false -> {:error, {:invalid_linear_write_result, :invalid_field}}
      {:error, _reason} = error -> error
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keys?(attrs), do: attrs |> Map.new() |> new(), else: invalid(:attributes)
  end

  def new(attrs) when is_map(attrs) do
    expected = [:status, :provider, :external_id, :issue_identifier, :details]

    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected) do
      attrs |> then(&struct!(__MODULE__, &1)) |> new()
    else
      invalid(:attributes)
    end
  end

  def new(_attrs), do: invalid(:attributes)

  @doc "Builds an exact reconciliation miss."
  @spec absent(String.t()) :: t()
  def absent(provider) do
    %__MODULE__{
      status: :absent,
      provider: provider,
      external_id: nil,
      issue_identifier: nil,
      details: %{}
    }
  end

  @doc "Builds a result whose external outcome is not yet known."
  @spec uncertain(String.t(), map()) :: t()
  def uncertain(provider, details \\ %{}) do
    %__MODULE__{
      status: :uncertain,
      provider: provider,
      external_id: nil,
      issue_identifier: nil,
      details: details
    }
  end

  defp validate_status_fields(%__MODULE__{status: :absent, external_id: nil, issue_identifier: nil}),
    do: :ok

  defp validate_status_fields(%__MODULE__{status: status})
       when status in [:uncertain, :rejected],
       do: :ok

  defp validate_status_fields(%__MODULE__{status: :confirmed, external_id: id})
       when is_binary(id),
       do: :ok

  defp validate_status_fields(_result), do: invalid(:status_contract)

  defp bounded_provider?(value), do: optional_identifier?(value, 64) and not is_nil(value)

  defp optional_identifier?(nil, _max), do: true

  defp optional_identifier?(value, max) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..max and String.trim(value) == value
  end

  defp optional_identifier?(_value, _max), do: false

  defp unique_keys?(keyword) do
    keys = Keyword.keys(keyword)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp invalid(reason), do: {:error, {:invalid_linear_write_result, reason}}
end
