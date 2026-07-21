# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.CodexHookFailOpenFixture do
  @moduledoc false

  @max_input_bytes 65_536

  def main do
    with [receipt_path] <- System.argv(),
         true <- Path.type(receipt_path) == :absolute do
      case IO.binread(:stdio, @max_input_bytes + 1) do
        payload when is_binary(payload) and byte_size(payload) <= @max_input_bytes ->
          decide(payload, receipt_path)

        _invalid ->
          halt_with_receipt(receipt_path, "invalid:7", 7)
      end
    else
      _invalid -> System.halt(7)
    end
  end

  defp decide(payload, receipt_path) do
    case :json.decode(payload) do
      %{"agent_type" => agent_type} when is_binary(agent_type) and agent_type != "" ->
        halt_with_receipt(receipt_path, "child:7", 7)

      decoded when is_map(decoded) ->
        halt_with_receipt(receipt_path, "root:7", 7)

      _invalid ->
        halt_with_receipt(receipt_path, "invalid:7", 7)
    end
  rescue
    _error -> halt_with_receipt(receipt_path, "invalid:7", 7)
  catch
    _kind, _reason -> halt_with_receipt(receipt_path, "invalid:7", 7)
  end

  defp halt_with_receipt(receipt_path, receipt, status) do
    File.write!(receipt_path, receipt <> "\n", [:append])
    System.halt(status)
  end
end

SymphonyElixir.TestSupport.CodexHookFailOpenFixture.main()
