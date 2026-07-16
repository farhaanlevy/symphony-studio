# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.TransportError do
  @moduledoc """
  A bounded, prompt-free App Server transport failure.

  `details` may contain identifiers, byte counts, request hashes, the pinned
  schema version, and fixed-shape categorical stderr evidence. Arbitrary or
  regex-redacted stderr, stderr hashes, JSON-RPC error messages, request
  parameters, and prompt bodies must never be attached.
  """

  @type kind ::
          :connection_closed
          | :duplicate_response_id
          | :frame_too_large
          | :inbound_state_overflow
          | :invalid_json_rpc_frame
          | :malformed_json
          | :overload_exhausted
          | :overloaded
          | :process_cleanup_failed
          | :process_exit
          | :process_start_failed
          | :request_timeout
          | :response_error
          | :stdout_contamination
          | :truncated_frame
          | :unexpected_response_id
          | :uncertain_external_outcome
          | :write_failed

  @type t :: %__MODULE__{
          kind: kind(),
          message: String.t(),
          details: map()
        }

  defexception [:kind, :message, details: %{}]

  @spec new(kind(), map()) :: t()
  def new(kind, details \\ %{}) when is_atom(kind) and is_map(details) do
    %__MODULE__{
      kind: kind,
      message: message_for_kind(kind),
      details: details
    }
  end

  defp message_for_kind(:connection_closed), do: "Codex App Server connection is closed"

  defp message_for_kind(:duplicate_response_id),
    do: "Codex App Server sent a duplicate response ID"

  defp message_for_kind(:frame_too_large),
    do: "Codex App Server stdout frame exceeds the configured limit"

  defp message_for_kind(:inbound_state_overflow),
    do: "Codex App Server exceeded a bounded inbound state limit"

  defp message_for_kind(:invalid_json_rpc_frame),
    do: "Codex App Server sent an invalid JSON-RPC frame"

  defp message_for_kind(:malformed_json), do: "Codex App Server sent malformed JSON on stdout"

  defp message_for_kind(:overload_exhausted),
    do: "Codex App Server remained overloaded after bounded retries"

  defp message_for_kind(:overloaded),
    do: "Codex App Server rejected a request because it is overloaded"

  defp message_for_kind(:process_cleanup_failed),
    do: "Codex App Server process containment unit did not terminate cleanly"

  defp message_for_kind(:process_exit), do: "Codex App Server process exited"

  defp message_for_kind(:process_start_failed),
    do: "Codex App Server process could not be started"

  defp message_for_kind(:request_timeout),
    do: "Codex App Server request exceeded its absolute deadline"

  defp message_for_kind(:response_error), do: "Codex App Server returned a JSON-RPC error"

  defp message_for_kind(:stdout_contamination),
    do: "Codex App Server stdout contained non-protocol output"

  defp message_for_kind(:truncated_frame),
    do: "Codex App Server stdout ended with a partial JSONL frame"

  defp message_for_kind(:unexpected_response_id),
    do: "Codex App Server sent an unexpected response ID"

  defp message_for_kind(:uncertain_external_outcome),
    do: "Codex App Server outcome is uncertain"

  defp message_for_kind(:write_failed), do: "Codex App Server stdin write failed"
end
