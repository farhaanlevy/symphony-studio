# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.RequestPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.{RequestPolicy, TransportError}

  test "classifies the pinned request surface conservatively" do
    assert RequestPolicy.classify("initialize") == :handshake

    for method <- [
          "account/read",
          "account/rateLimits/read",
          "account/usage/read",
          "collaborationMode/list",
          "experimentalFeature/list",
          "model/list",
          "thread/list",
          "thread/read"
        ] do
      assert RequestPolicy.classify(method) == :idempotent
      assert RequestPolicy.retry_overload?(method)
      refute RequestPolicy.uncertain_after_send?(method)
    end

    for method <- [
          "account/rateLimitResetCredit/consume",
          "review/start",
          "thread/start",
          "turn/start"
        ] do
      assert RequestPolicy.classify(method) == :side_effecting
      refute RequestPolicy.retry_overload?(method)
      assert RequestPolicy.uncertain_after_send?(method)
    end

    assert RequestPolicy.classify("future/method") == :conservative
    refute RequestPolicy.retry_overload?("future/method")
    assert RequestPolicy.uncertain_after_send?("future/method")
    refute RequestPolicy.retry_overload?("initialize")
    refute RequestPolicy.uncertain_after_send?("initialize")
  end

  test "canonical request hashes are deterministic across map order and retain value distinctions" do
    left = %{
      "nested" => %{"b" => 2, "a" => 1},
      "sequence" => [1, {2, :three}]
    }

    right = %{
      "sequence" => [1, {2, :three}],
      "nested" => %{"a" => 1, "b" => 2}
    }

    left_hash = RequestPolicy.canonical_hash("thread/read", left)
    right_hash = RequestPolicy.canonical_hash("thread/read", right)

    assert left_hash == right_hash
    assert byte_size(left_hash) == 64
    assert left_hash =~ ~r/\A[0-9a-f]{64}\z/
    refute left_hash == RequestPolicy.canonical_hash("thread/read", Map.put(right, "extra", true))
    refute left_hash == RequestPolicy.canonical_hash("thread/list", right)
  end

  test "transport errors have stable operator-safe messages for every typed kind" do
    expected = %{
      connection_closed: "Codex App Server connection is closed",
      duplicate_response_id: "Codex App Server sent a duplicate response ID",
      frame_too_large: "Codex App Server stdout frame exceeds the configured limit",
      inbound_state_overflow: "Codex App Server exceeded a bounded inbound state limit",
      invalid_json_rpc_frame: "Codex App Server sent an invalid JSON-RPC frame",
      malformed_json: "Codex App Server sent malformed JSON on stdout",
      overload_exhausted: "Codex App Server remained overloaded after bounded retries",
      overloaded: "Codex App Server rejected a request because it is overloaded",
      process_cleanup_failed: "Codex App Server process containment unit did not terminate cleanly",
      process_exit: "Codex App Server process exited",
      process_start_failed: "Codex App Server process could not be started",
      request_timeout: "Codex App Server request exceeded its absolute deadline",
      response_error: "Codex App Server returned a JSON-RPC error",
      stdout_contamination: "Codex App Server stdout contained non-protocol output",
      truncated_frame: "Codex App Server stdout ended with a partial JSONL frame",
      unexpected_response_id: "Codex App Server sent an unexpected response ID",
      uncertain_external_outcome: "Codex App Server outcome is uncertain",
      write_failed: "Codex App Server stdin write failed"
    }

    Enum.each(expected, fn {kind, message} ->
      error = TransportError.new(kind, %{marker: true})

      assert %TransportError{kind: ^kind, message: ^message, details: %{marker: true}} = error
      assert Exception.message(error) == message
    end)

    assert TransportError.new(:connection_closed).details == %{}

    assert %TransportError{details: %{}} =
             TransportError.exception(kind: :connection_closed, message: "safe")
  end
end
