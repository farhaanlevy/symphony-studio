# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio supplies a
# retaining-nothing event sink so the upstream-compatible runner stays usable.

defmodule SymphonyElixir.EventSink.Noop do
  @moduledoc """
  Default event sink that accepts events without retaining history.

  It is intentionally unsupervised and makes no persistence or replay claim.
  """

  @behaviour SymphonyElixir.EventSink

  alias SymphonyElixir.Event

  @impl true
  def append(_server, %Event{}), do: {:ok, :appended}

  @impl true
  def replay(_server, run_id, after_sequence, _limit) do
    {:error,
     {:replay_unavailable,
      %{
        reason: :not_retained,
        run_id: run_id,
        requested_after: after_sequence
      }}}
  end
end
