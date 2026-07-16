# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.JSONLFramer do
  @moduledoc """
  Incrementally frames a byte stream on line-feed boundaries.

  Framing is byte-oriented, so chunks may split UTF-8 code points. Completed
  frames are emitted without the line feed and with one optional trailing
  carriage return removed.
  """

  @enforce_keys [:max_frame_bytes]
  defstruct max_frame_bytes: nil, chunks: [], frame_bytes: 0

  @opaque t :: %__MODULE__{
            max_frame_bytes: pos_integer(),
            chunks: [binary()],
            frame_bytes: non_neg_integer()
          }

  @type error ::
          {:frame_too_large, %{limit: pos_integer(), observed: pos_integer()}}
          | {:truncated_frame, %{observed: pos_integer()}}

  @spec new(pos_integer()) :: t()
  def new(max_frame_bytes) when is_integer(max_frame_bytes) and max_frame_bytes > 0 do
    %__MODULE__{max_frame_bytes: max_frame_bytes}
  end

  def new(max_frame_bytes) do
    raise ArgumentError,
          "JSONL maximum frame size must be a positive integer, got: #{inspect(max_frame_bytes)}"
  end

  @spec push(t(), binary()) :: {:ok, [binary()], t()} | {:error, error()}
  def push(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    consume(bytes, state, [])
  end

  @spec finish(t()) :: :ok | {:error, error()}
  def finish(%__MODULE__{frame_bytes: 0}), do: :ok

  def finish(%__MODULE__{frame_bytes: observed}) do
    {:error, {:truncated_frame, %{observed: observed}}}
  end

  @doc "Discards a partial frame while preserving the configured byte limit."
  @spec discard(t()) :: t()
  def discard(%__MODULE__{} = state), do: %{state | chunks: [], frame_bytes: 0}

  @doc "Returns content-free framing state suitable for process status output."
  @spec public_summary(t()) :: %{frame_bytes: non_neg_integer(), max_frame_bytes: pos_integer()}
  def public_summary(%__MODULE__{} = state) do
    %{frame_bytes: state.frame_bytes, max_frame_bytes: state.max_frame_bytes}
  end

  defp consume(bytes, state, frames) do
    case :binary.match(bytes, "\n") do
      :nomatch ->
        case append_chunk(state, bytes) do
          {:ok, next_state} -> {:ok, Enum.reverse(frames), next_state}
          {:error, reason} -> {:error, reason}
        end

      {line_feed_offset, 1} ->
        frame_part = binary_part(bytes, 0, line_feed_offset)
        remaining_offset = line_feed_offset + 1
        remaining_size = byte_size(bytes) - remaining_offset
        remaining = binary_part(bytes, remaining_offset, remaining_size)

        case append_chunk(state, frame_part) do
          {:ok, completed_state} ->
            frame = materialize_frame(completed_state)
            consume(remaining, reset_frame(completed_state), [frame | frames])

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp append_chunk(state, <<>>), do: {:ok, state}

  defp append_chunk(%__MODULE__{} = state, chunk) do
    observed = state.frame_bytes + byte_size(chunk)

    if observed <= state.max_frame_bytes do
      {:ok, %{state | chunks: [chunk | state.chunks], frame_bytes: observed}}
    else
      {:error,
       {:frame_too_large,
        %{
          limit: state.max_frame_bytes,
          observed: observed
        }}}
    end
  end

  defp materialize_frame(%__MODULE__{chunks: chunks}) do
    chunks
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> strip_optional_carriage_return()
  end

  defp strip_optional_carriage_return(<<>>), do: <<>>

  defp strip_optional_carriage_return(frame) do
    size = byte_size(frame)

    if :binary.last(frame) == ?\r do
      binary_part(frame, 0, size - 1)
    else
      frame
    end
  end

  defp reset_frame(%__MODULE__{} = state), do: %{state | chunks: [], frame_bytes: 0}
end
