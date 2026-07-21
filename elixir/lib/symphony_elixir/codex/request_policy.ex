# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.RequestPolicy do
  @moduledoc false

  @idempotent_methods MapSet.new([
                        "account/read",
                        "account/rateLimits/read",
                        "account/usage/read",
                        "collaborationMode/list",
                        "experimentalFeature/list",
                        "hooks/list",
                        "model/list",
                        "thread/list",
                        "thread/read"
                      ])

  @side_effecting_methods MapSet.new([
                            "account/rateLimitResetCredit/consume",
                            "config/batchWrite",
                            "review/start",
                            "thread/start",
                            "turn/interrupt",
                            "turn/start"
                          ])

  @type classification :: :handshake | :idempotent | :side_effecting | :conservative

  @spec classify(String.t()) :: classification()
  def classify("initialize"), do: :handshake

  def classify(method) when is_binary(method) do
    cond do
      MapSet.member?(@idempotent_methods, method) -> :idempotent
      MapSet.member?(@side_effecting_methods, method) -> :side_effecting
      true -> :conservative
    end
  end

  @spec retry_overload?(String.t()) :: boolean()
  def retry_overload?(method), do: classify(method) == :idempotent

  @spec uncertain_after_send?(String.t()) :: boolean()
  def uncertain_after_send?(method), do: classify(method) in [:side_effecting, :conservative]

  @type request_params :: map() | :omitted

  @spec canonical_hash(String.t(), request_params()) :: String.t()
  def canonical_hash(method, params)
      when is_binary(method) and (is_map(params) or params == :omitted) do
    canonical = canonicalize(request_payload(method, params))

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonical, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp request_payload(method, :omitted), do: %{"method" => method}
  defp request_payload(method, %{} = params), do: %{"method" => method, "params" => params}

  defp canonicalize(value) when is_map(value) do
    entries =
      value
      |> Enum.map(fn {key, nested} -> {canonicalize(key), canonicalize(nested)} end)
      |> Enum.sort()

    {:map, entries}
  end

  defp canonicalize(value) when is_list(value), do: {:list, Enum.map(value, &canonicalize/1)}
  defp canonicalize(value) when is_tuple(value), do: {:tuple, value |> Tuple.to_list() |> Enum.map(&canonicalize/1)}
  defp canonicalize(value), do: value
end
