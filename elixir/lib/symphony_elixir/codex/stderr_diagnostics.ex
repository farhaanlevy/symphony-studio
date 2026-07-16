# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.StderrDiagnostics do
  @moduledoc """
  Reduces the configured App Server stderr suffix to content-free categorical
  evidence.

  Input is streamed through fixed-size blocks. The accumulator stores only
  counters, latest allowlisted-category match offsets, integer KMP progress,
  and integer UTF-8 validation state. It never retains, returns, hashes, or
  redacts raw stderr. Public categories therefore describe only complete
  matches inside the configured tail window without making prompt or secret
  text durable.
  """

  @max_tail_bytes 1_048_576
  @scan_block_bytes 4_096
  @category_patterns [
    authentication: [
      "authentication failed",
      "login required",
      "not logged in",
      "unauthorized"
    ],
    permission: ["approval required", "operation not permitted", "permission denied"],
    configuration: [
      "configuration error",
      "failed to load configuration",
      "invalid configuration"
    ],
    executable_not_found: ["command not found", "executable not found", "no such file or directory"],
    network: [
      "connection refused",
      "connection reset",
      "dns error",
      "network error"
    ],
    tls: ["certificate verify failed", "tls error", "tls handshake"],
    rate_limit: ["rate limit", "too many requests"],
    resource_exhaustion: ["no space left", "out of memory", "resource exhausted", "too many open files"],
    crash: ["fatal runtime error", "panic:", "panicked at", "segmentation fault"]
  ]
  @category_order Keyword.keys(@category_patterns)
  @pattern_specs @category_patterns
                 |> Enum.flat_map(fn {category, patterns} ->
                   Enum.map(patterns, &{category, &1})
                 end)
                 |> Enum.map(fn {category, pattern} ->
                   pattern_bytes = :binary.bin_to_list(pattern)

                   failure_table =
                     pattern_bytes
                     |> Enum.with_index()
                     |> Enum.reduce([], fn
                       {_byte, 0}, [] ->
                         [0]

                       {byte, index}, table ->
                         fallback = fn fallback, candidate ->
                           cond do
                             candidate == 0 ->
                               0

                             Enum.at(pattern_bytes, candidate) == byte ->
                               candidate

                             true ->
                               fallback.(fallback, Enum.at(table, candidate - 1))
                           end
                         end

                         candidate = fallback.(fallback, Enum.at(table, index - 1))

                         next =
                           if Enum.at(pattern_bytes, candidate) == byte,
                             do: candidate + 1,
                             else: 0

                         table ++ [next]
                     end)

                   {category, pattern, List.to_tuple(failure_table)}
                 end)
  @pattern_specs_tuple List.to_tuple(@pattern_specs)
  @patterns_by_first_byte @pattern_specs
                          |> Enum.with_index()
                          |> Enum.group_by(
                            fn {{_category, pattern, _failure_table}, _index} ->
                              :binary.at(pattern, 0)
                            end,
                            fn {_spec, index} -> index end
                          )

  @type category ::
          :authentication
          | :permission
          | :configuration
          | :executable_not_found
          | :network
          | :tls
          | :rate_limit
          | :resource_exhaustion
          | :crash
          | :unclassified

  @type public_summary :: %{
          stderr_present: boolean(),
          stderr_bytes_seen: non_neg_integer(),
          stderr_chunks_seen: non_neg_integer(),
          stderr_bytes_retained: 0,
          stderr_tail_window_bytes: pos_integer(),
          stderr_tail_bytes_covered: non_neg_integer(),
          stderr_truncated: boolean(),
          stderr_invalid_utf8: boolean(),
          stderr_line_count: non_neg_integer(),
          stderr_categories: [category()]
        }

  @opaque t :: %__MODULE__{
            bytes_seen: non_neg_integer(),
            category_last_start: %{optional(category()) => non_neg_integer()},
            chunks_seen: non_neg_integer(),
            invalid_utf8: boolean(),
            last_byte_newline: boolean(),
            newline_count: non_neg_integer(),
            pattern_progress: %{optional(non_neg_integer()) => pos_integer()},
            tail_bytes: pos_integer(),
            utf8_expected: 0..3,
            utf8_next_max: 0..255,
            utf8_next_min: 0..255
          }

  defstruct bytes_seen: 0,
            category_last_start: %{},
            chunks_seen: 0,
            invalid_utf8: false,
            last_byte_newline: false,
            newline_count: 0,
            pattern_progress: %{},
            tail_bytes: 0,
            utf8_expected: 0,
            utf8_next_max: 0,
            utf8_next_min: 0

  @doc "The accepted upper bound for the content-free stderr tail window."
  @spec max_tail_bytes() :: pos_integer()
  def max_tail_bytes, do: @max_tail_bytes

  @spec new(pos_integer()) :: t()
  def new(tail_bytes)
      when is_integer(tail_bytes) and tail_bytes > 0 and tail_bytes <= @max_tail_bytes do
    %__MODULE__{tail_bytes: tail_bytes}
  end

  def new(_tail_bytes),
    do: raise(ArgumentError, "stderr tail bytes must be between 1 and #{@max_tail_bytes}")

  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = diagnostics, bytes) when is_binary(bytes) do
    diagnostics
    |> Map.update!(:chunks_seen, &(&1 + 1))
    |> consume_blocks(bytes)
  end

  @doc "Finalizes streaming UTF-8 validation after stderr reaches EOF."
  @spec finish(t()) :: t()
  def finish(%__MODULE__{utf8_expected: 0} = diagnostics), do: diagnostics

  def finish(%__MODULE__{} = diagnostics) do
    %{
      diagnostics
      | invalid_utf8: true,
        utf8_expected: 0,
        utf8_next_max: 0,
        utf8_next_min: 0
    }
  end

  @spec public_summary(t()) :: public_summary()
  def public_summary(%__MODULE__{} = diagnostics) do
    %{
      stderr_present: diagnostics.bytes_seen > 0,
      stderr_bytes_seen: diagnostics.bytes_seen,
      stderr_chunks_seen: diagnostics.chunks_seen,
      stderr_bytes_retained: 0,
      stderr_tail_window_bytes: diagnostics.tail_bytes,
      stderr_tail_bytes_covered: min(diagnostics.bytes_seen, diagnostics.tail_bytes),
      stderr_truncated: diagnostics.bytes_seen > diagnostics.tail_bytes,
      stderr_invalid_utf8: diagnostics.invalid_utf8,
      stderr_line_count: line_count(diagnostics),
      stderr_categories: public_categories(diagnostics)
    }
  end

  defp consume_blocks(diagnostics, <<>>), do: diagnostics

  defp consume_blocks(diagnostics, bytes) when byte_size(bytes) <= @scan_block_bytes do
    consume_block(diagnostics, bytes)
  end

  defp consume_blocks(diagnostics, <<block::binary-size(@scan_block_bytes), rest::binary>>) do
    diagnostics
    |> consume_block(block)
    |> consume_blocks(rest)
  end

  defp consume_block(diagnostics, bytes) do
    initial =
      {
        diagnostics.pattern_progress,
        diagnostics.category_last_start,
        diagnostics.invalid_utf8,
        diagnostics.utf8_expected,
        diagnostics.utf8_next_min,
        diagnostics.utf8_next_max,
        diagnostics.newline_count,
        diagnostics.last_byte_newline,
        diagnostics.bytes_seen
      }

    {
      progress,
      category_last_start,
      invalid_utf8,
      utf8_expected,
      utf8_next_min,
      utf8_next_max,
      newline_count,
      last_byte_newline,
      bytes_seen
    } =
      for <<byte <- bytes>>, reduce: initial do
        {
          progress,
          category_last_start,
          invalid_utf8,
          utf8_expected,
          utf8_next_min,
          utf8_next_max,
          newline_count,
          _last_byte_newline,
          offset
        } ->
          {next_progress, next_category_last_start} =
            classify_byte(progress, category_last_start, ascii_downcase(byte), offset)

          {next_invalid_utf8, next_utf8_expected, next_utf8_min, next_utf8_max} =
            validate_utf8_byte(
              invalid_utf8,
              utf8_expected,
              utf8_next_min,
              utf8_next_max,
              byte
            )

          {
            next_progress,
            next_category_last_start,
            next_invalid_utf8,
            next_utf8_expected,
            next_utf8_min,
            next_utf8_max,
            newline_count + if(byte == ?\n, do: 1, else: 0),
            byte == ?\n,
            offset + 1
          }
      end

    %{
      diagnostics
      | bytes_seen: bytes_seen,
        category_last_start: category_last_start,
        invalid_utf8: invalid_utf8,
        last_byte_newline: last_byte_newline,
        newline_count: newline_count,
        pattern_progress: progress,
        utf8_expected: utf8_expected,
        utf8_next_max: utf8_next_max,
        utf8_next_min: utf8_next_min
    }
  end

  defp classify_byte(progress, category_last_start, byte, offset) do
    {advanced, next_category_last_start} =
      Enum.reduce(progress, {%{}, category_last_start}, fn
        {pattern_id, matched_bytes}, {acc, category_acc} ->
          {category, pattern, failure_table} = pattern_spec(pattern_id)
          next_matched_bytes = advance_pattern(pattern_id, matched_bytes, byte)

          if next_matched_bytes == byte_size(pattern) do
            match_start = offset - byte_size(pattern) + 1
            fallback = elem(failure_table, byte_size(pattern) - 1)

            {
              maybe_put_progress(acc, pattern_id, fallback),
              Map.update(category_acc, category, match_start, &max(&1, match_start))
            }
          else
            {maybe_put_progress(acc, pattern_id, next_matched_bytes), category_acc}
          end
      end)

    @patterns_by_first_byte
    |> Map.get(byte, [])
    |> Enum.reduce({advanced, next_category_last_start}, fn pattern_id, {acc, category_acc} ->
      if Map.has_key?(acc, pattern_id) do
        {acc, category_acc}
      else
        {Map.put(acc, pattern_id, 1), category_acc}
      end
    end)
  end

  defp advance_pattern(pattern_id, matched_bytes, byte) do
    {_category, pattern, failure_table} = pattern_spec(pattern_id)

    cond do
      :binary.at(pattern, matched_bytes) == byte ->
        matched_bytes + 1

      matched_bytes > 0 ->
        advance_pattern(pattern_id, elem(failure_table, matched_bytes - 1), byte)

      true ->
        0
    end
  end

  defp pattern_spec(pattern_id), do: elem(@pattern_specs_tuple, pattern_id)

  defp maybe_put_progress(progress, _pattern_id, 0), do: progress
  defp maybe_put_progress(progress, pattern_id, matched_bytes), do: Map.put(progress, pattern_id, matched_bytes)

  defp ascii_downcase(byte) when byte in ?A..?Z, do: byte + 32
  defp ascii_downcase(byte), do: byte

  defp validate_utf8_byte(true, _expected, _minimum, _maximum, _byte),
    do: {true, 0, 0, 0}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, byte) when byte <= 0x7F,
    do: {false, 0, 0, 0}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, byte) when byte in 0xC2..0xDF,
    do: {false, 1, 0x80, 0xBF}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, 0xE0),
    do: {false, 2, 0xA0, 0xBF}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, byte)
       when byte in 0xE1..0xEC or byte in 0xEE..0xEF,
       do: {false, 2, 0x80, 0xBF}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, 0xED),
    do: {false, 2, 0x80, 0x9F}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, 0xF0),
    do: {false, 3, 0x90, 0xBF}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, byte) when byte in 0xF1..0xF3,
    do: {false, 3, 0x80, 0xBF}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, 0xF4),
    do: {false, 3, 0x80, 0x8F}

  defp validate_utf8_byte(false, 0, _minimum, _maximum, _byte),
    do: {true, 0, 0, 0}

  defp validate_utf8_byte(false, expected, minimum, maximum, byte)
       when byte >= minimum and byte <= maximum do
    remaining = expected - 1

    if remaining == 0,
      do: {false, 0, 0, 0},
      else: {false, remaining, 0x80, 0xBF}
  end

  defp validate_utf8_byte(false, _expected, _minimum, _maximum, _byte),
    do: {true, 0, 0, 0}

  defp line_count(%{bytes_seen: 0}), do: 0

  defp line_count(diagnostics) do
    diagnostics.newline_count + if(diagnostics.last_byte_newline, do: 0, else: 1)
  end

  defp public_categories(%{bytes_seen: 0}), do: []

  defp public_categories(diagnostics) do
    tail_start = max(diagnostics.bytes_seen - diagnostics.tail_bytes, 0)

    known =
      Enum.filter(@category_order, fn category ->
        case diagnostics.category_last_start do
          %{^category => match_start} -> match_start >= tail_start
          _other -> false
        end
      end)

    if known == [], do: [:unclassified], else: known
  end
end

defimpl Inspect, for: SymphonyElixir.Codex.StderrDiagnostics do
  import Inspect.Algebra

  @spec inspect(SymphonyElixir.Codex.StderrDiagnostics.t(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def inspect(diagnostics, opts) do
    concat([
      "#StderrDiagnostics<",
      to_doc(SymphonyElixir.Codex.StderrDiagnostics.public_summary(diagnostics), opts),
      ">"
    ])
  end
end
