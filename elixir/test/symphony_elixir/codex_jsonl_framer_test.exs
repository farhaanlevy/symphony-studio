# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.JSONLFramerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.JSONLFramer

  test "accepts an exact-size frame and rejects the next byte before a delimiter" do
    state = JSONLFramer.new(4)

    assert {:ok, [], state} = JSONLFramer.push(state, "abcd")
    assert {:error, {:frame_too_large, %{limit: 4, observed: 5}}} = JSONLFramer.push(state, "e")

    state = JSONLFramer.new(4)
    assert {:ok, ["abcd"], state} = JSONLFramer.push(state, "abcd\n")
    assert :ok = JSONLFramer.finish(state)
  end

  test "frames payloads larger than one MiB across arbitrary byte boundaries" do
    frame = :binary.copy("a", 1_048_577)
    <<first::binary-size(1), second::binary-size(1_048_575), last::binary>> = frame
    state = JSONLFramer.new(2 * 1_048_576)

    assert {:ok, [], state} = JSONLFramer.push(state, first)
    assert {:ok, [], state} = JSONLFramer.push(state, second)
    assert {:ok, [^frame], state} = JSONLFramer.push(state, last <> "\n")
    assert :ok = JSONLFramer.finish(state)
  end

  test "preserves split UTF-8 bytes and emits coalesced frames in order" do
    unicode_frame = "a€𐌍"
    <<first::binary-size(2), remaining::binary>> = unicode_frame
    state = JSONLFramer.new(64)

    assert {:ok, [], state} = JSONLFramer.push(state, first)

    assert {:ok, [^unicode_frame, "next"], state} =
             JSONLFramer.push(state, remaining <> "\nnext\n")

    assert :ok = JSONLFramer.finish(state)
  end

  test "delivers empty frames and strips one optional carriage return" do
    state = JSONLFramer.new(8)

    assert {:ok, ["", "", "value", "kept\r"], state} =
             JSONLFramer.push(state, "\n\r\nvalue\r\nkept\r\r\n")

    assert :ok = JSONLFramer.finish(state)
  end

  test "reports a truncated frame when EOF arrives with pending bytes" do
    state = JSONLFramer.new(32)
    assert {:ok, [], state} = JSONLFramer.push(state, "partial")

    assert {:error, {:truncated_frame, %{observed: 7}}} = JSONLFramer.finish(state)
  end

  test "rejects invalid maximum frame sizes" do
    for invalid <- [0, -1, 1.5, nil] do
      assert_raise ArgumentError, fn -> JSONLFramer.new(invalid) end
    end
  end
end
