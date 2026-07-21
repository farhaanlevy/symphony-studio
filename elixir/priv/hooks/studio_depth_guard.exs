#!/usr/bin/env elixir
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyStudio.DepthGuard do
  @moduledoc false

  @max_input_bytes 65_536
  @blocked_reason "symphony_studio_recursive_spawn_denied"

  def main do
    case read_payload() do
      {:ok, payload} -> decide(payload)
      :error -> deny()
    end
  end

  defp read_payload do
    case IO.binread(:stdio, @max_input_bytes + 1) do
      payload when is_binary(payload) and byte_size(payload) <= @max_input_bytes ->
        decode_payload(payload)

      _oversized_or_missing ->
        :error
    end
  end

  defp decode_payload(payload) do
    case :json.decode(payload) do
      decoded when is_map(decoded) -> {:ok, decoded}
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp decide(%{"hook_event_name" => "PreToolUse", "tool_name" => tool_name} = payload)
       when is_binary(tool_name) do
    cond do
      tool_name not in ["spawn_agent", "collaborationspawn_agent"] -> deny()
      Map.has_key?(payload, "agent_type") -> deny()
      true -> System.halt(0)
    end
  end

  defp decide(_invalid), do: deny()

  defp deny do
    IO.binwrite(:stderr, @blocked_reason <> "\n")
    System.halt(2)
  end
end

SymphonyStudio.DepthGuard.main()
