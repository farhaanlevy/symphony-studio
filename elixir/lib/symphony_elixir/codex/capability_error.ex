# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CapabilityError do
  @moduledoc """
  Content-free failure returned by exact-version capability discovery.

  Raw App Server payloads, account metadata, and provider error messages are
  deliberately excluded so readiness diagnostics remain safe to persist.
  """

  defexception [:kind, :method, :reason]

  @type t :: %__MODULE__{
          kind: atom(),
          method: String.t() | nil,
          reason: atom() | nil
        }

  @spec new(atom(), String.t() | nil, atom() | nil) :: t()
  def new(kind, method \\ nil, reason \\ nil)
      when is_atom(kind) and (is_binary(method) or is_nil(method)) and
             (is_atom(reason) or is_nil(reason)) do
    %__MODULE__{kind: kind, method: method, reason: reason}
  end

  @impl Exception
  def message(%__MODULE__{kind: kind, method: method}) do
    case method do
      value when is_binary(value) -> "Codex capability discovery failed for #{value}: #{kind}"
      nil -> "Codex capability discovery failed: #{kind}"
    end
  end
end
