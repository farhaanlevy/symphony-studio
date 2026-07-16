# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.StderrDiagnosticsTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.StderrDiagnostics

  test "publishes one fixed evidence shape without stderr" do
    summary = StderrDiagnostics.new(64) |> StderrDiagnostics.public_summary()
    empty_append = StderrDiagnostics.new(64) |> StderrDiagnostics.append("")

    assert summary == %{
             stderr_present: false,
             stderr_bytes_seen: 0,
             stderr_chunks_seen: 0,
             stderr_bytes_retained: 0,
             stderr_tail_window_bytes: 64,
             stderr_tail_bytes_covered: 0,
             stderr_truncated: false,
             stderr_invalid_utf8: false,
             stderr_line_count: 0,
             stderr_categories: []
           }

    assert StderrDiagnostics.public_summary(empty_append).stderr_chunks_seen == 1
    refute StderrDiagnostics.public_summary(empty_append).stderr_present
  end

  test "recognizes allowlisted categories across chunks with an unclassified fallback" do
    diagnostics =
      StderrDiagnostics.new(128)
      |> StderrDiagnostics.append("Authenti")
      |> StderrDiagnostics.append("cation failed\n")

    assert %{
             stderr_categories: [:authentication],
             stderr_chunks_seen: 2,
             stderr_line_count: 1
           } = StderrDiagnostics.public_summary(diagnostics)

    fallback =
      StderrDiagnostics.new(128)
      |> StderrDiagnostics.append("arbitrary diagnostic\n")
      |> StderrDiagnostics.public_summary()

    assert fallback.stderr_categories == [:unclassified]
  end

  test "keeps the complete category vocabulary fixed and content-free" do
    examples = [
      authentication: "authentication failed",
      permission: "permission denied",
      configuration: "configuration error",
      executable_not_found: "command not found",
      network: "connection refused",
      tls: "tls handshake",
      rate_limit: "rate limit",
      resource_exhaustion: "resource exhausted",
      crash: "segmentation fault"
    ]

    for {category, stderr} <- examples do
      summary =
        StderrDiagnostics.new(128)
        |> StderrDiagnostics.append(stderr)
        |> StderrDiagnostics.public_summary()

      assert summary.stderr_categories == [category]
      refute inspect(summary) =~ "private value"
    end
  end

  test "tracks invalid UTF-8 without misclassifying a valid split codepoint" do
    valid_split =
      StderrDiagnostics.new(128)
      |> StderrDiagnostics.append(<<226>>)
      |> StderrDiagnostics.append(<<130, 172, ?\n>>)
      |> StderrDiagnostics.public_summary()

    refute valid_split.stderr_invalid_utf8

    invalid =
      StderrDiagnostics.new(128)
      |> StderrDiagnostics.append(<<255, ?\n>>)
      |> StderrDiagnostics.public_summary()

    assert invalid.stderr_invalid_utf8
    assert invalid.stderr_line_count == 1

    incomplete =
      StderrDiagnostics.new(128)
      |> StderrDiagnostics.append(<<226>>)

    refute StderrDiagnostics.public_summary(incomplete).stderr_invalid_utf8

    assert incomplete
           |> StderrDiagnostics.finish()
           |> StderrDiagnostics.public_summary()
           |> Map.fetch!(:stderr_invalid_utf8)

    valid_boundary_sequences = [
      <<0xC2, 0x80>>,
      <<0xE0, 0xA0, 0x80>>,
      <<0xED, 0x80, 0x80>>,
      <<0xF0, 0x90, 0x80, 0x80>>,
      <<0xF1, 0x80, 0x80, 0x80>>,
      <<0xF4, 0x80, 0x80, 0x80>>
    ]

    Enum.each(valid_boundary_sequences, fn sequence ->
      refute sequence
             |> then(&StderrDiagnostics.append(StderrDiagnostics.new(128), &1))
             |> StderrDiagnostics.public_summary()
             |> Map.fetch!(:stderr_invalid_utf8)
    end)

    assert <<0xC2, ?A>>
           |> then(&StderrDiagnostics.append(StderrDiagnostics.new(128), &1))
           |> StderrDiagnostics.public_summary()
           |> Map.fetch!(:stderr_invalid_utf8)
  end

  test "streams one large chunk without retaining its raw content" do
    canary = "PRIVATE-STDERR-CANARY"
    max_tail_bytes = StderrDiagnostics.max_tail_bytes()
    payload = :binary.copy("x", max_tail_bytes + 1) <> canary

    diagnostics =
      StderrDiagnostics.new(max_tail_bytes)
      |> StderrDiagnostics.append(payload)

    summary = StderrDiagnostics.public_summary(diagnostics)

    assert summary.stderr_bytes_seen == byte_size(payload)
    assert summary.stderr_bytes_retained == 0
    assert summary.stderr_tail_window_bytes == max_tail_bytes
    assert summary.stderr_tail_bytes_covered == max_tail_bytes
    assert summary.stderr_truncated
    assert summary.stderr_categories == [:unclassified]
    assert :erlang.external_size(diagnostics) < 10_000
    refute term_contains_binary?(diagnostics, canary)
    refute inspect(summary) =~ canary
    refute inspect(diagnostics) =~ canary

    assert_raise ArgumentError, ~r/stderr tail bytes must be between/, fn ->
      StderrDiagnostics.new(max_tail_bytes + 1)
    end
  end

  test "reports only complete allowlisted matches inside the configured suffix" do
    tail_bytes = 64

    diagnostics =
      StderrDiagnostics.new(tail_bytes)
      |> StderrDiagnostics.append("permission denied")
      |> StderrDiagnostics.append(:binary.copy("x", 2 * tail_bytes))
      |> StderrDiagnostics.append("Authenti")
      |> StderrDiagnostics.append("cation failed")

    summary = StderrDiagnostics.public_summary(diagnostics)

    assert summary.stderr_tail_window_bytes == tail_bytes
    assert summary.stderr_tail_bytes_covered == tail_bytes
    assert summary.stderr_truncated
    assert summary.stderr_categories == [:authentication]
    assert summary.stderr_chunks_seen == 4
    assert :erlang.external_size(diagnostics) < 10_000

    pattern = "rate limit"
    included = StderrDiagnostics.new(byte_size(pattern)) |> StderrDiagnostics.append("prefix" <> pattern)
    crossing = StderrDiagnostics.new(byte_size(pattern) - 1) |> StderrDiagnostics.append("prefix" <> pattern)

    assert StderrDiagnostics.public_summary(included).stderr_categories == [:rate_limit]
    assert StderrDiagnostics.public_summary(crossing).stderr_categories == [:unclassified]

    repeated =
      StderrDiagnostics.new(64)
      |> StderrDiagnostics.append("rate limit then rate limit")
      |> StderrDiagnostics.public_summary()

    assert repeated.stderr_categories == [:rate_limit]

    rolled =
      StderrDiagnostics.new(8)
      |> StderrDiagnostics.append("rate limit\n")
      |> StderrDiagnostics.append(<<255, ?\n>>)
      |> StderrDiagnostics.append(:binary.copy("x", 32))
      |> StderrDiagnostics.finish()
      |> StderrDiagnostics.public_summary()

    assert rolled.stderr_categories == [:unclassified]
    assert rolled.stderr_invalid_utf8
    assert rolled.stderr_line_count == 3
  end

  defp term_contains_binary?(term, needle) when is_binary(term),
    do: :binary.match(term, needle) != :nomatch

  defp term_contains_binary?(term, needle) when is_struct(term),
    do: term |> Map.from_struct() |> term_contains_binary?(needle)

  defp term_contains_binary?(term, needle) when is_map(term),
    do: Enum.any?(term, fn {key, value} -> term_contains_binary?(key, needle) or term_contains_binary?(value, needle) end)

  defp term_contains_binary?(term, needle) when is_tuple(term),
    do: term |> Tuple.to_list() |> term_contains_binary?(needle)

  defp term_contains_binary?(term, needle) when is_list(term),
    do: Enum.any?(term, &term_contains_binary?(&1, needle))

  defp term_contains_binary?(_term, _needle), do: false
end
