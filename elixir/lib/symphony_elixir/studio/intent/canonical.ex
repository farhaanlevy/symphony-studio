# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.Canonical do
  @moduledoc false

  @spec json(term()) :: String.t()
  def json(value), do: encode(value)

  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec id(String.t(), term(), pos_integer()) :: String.t()
  def id(prefix, value, hex_length \\ 24)
      when is_binary(prefix) and is_integer(hex_length) and hex_length > 0 and hex_length <= 64 do
    prefix <> String.slice(digest(value), 0, hex_length)
  end

  @spec timestamp((-> DateTime.t())) :: String.t()
  def timestamp(clock \\ &DateTime.utc_now/0) when is_function(clock, 0) do
    clock.()
    |> DateTime.truncate(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp encode(value) when is_map(value) do
    encoded =
      value
      |> Enum.map(fn {key, nested} -> {key_string(key), nested} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, nested} ->
        Jason.encode!(key) <> ":" <> encode(nested)
      end)

    "{" <> encoded <> "}"
  end

  defp encode(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode/1) <> "]"
  end

  defp encode(value) when is_atom(value) and value not in [true, false, nil],
    do: Jason.encode!(Atom.to_string(value))

  defp encode(value), do: Jason.encode!(value)

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: to_string(key)
end
