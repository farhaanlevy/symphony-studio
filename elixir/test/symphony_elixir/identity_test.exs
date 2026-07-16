# Downstream modification notice (2026-07-16): Symphony Studio verifies its
# deterministic UUID identity contract independently of runtime randomness.
defmodule SymphonyElixir.IdentityTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Identity

  @dns_namespace "6ba7b810-9dad-11d1-80b4-00c04fd430c8"

  test "UUIDv4 generation is injectable and sets RFC version and variant bits" do
    parent = self()

    uuid =
      Identity.uuid4(fn requested_bytes ->
        send(parent, {:requested_bytes, requested_bytes})
        <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>
      end)

    assert_receive {:requested_bytes, 16}
    assert uuid == "00010203-0405-4607-8809-0a0b0c0d0e0f"
    assert Identity.valid_uuid?(uuid)
    assert Identity.valid_uuid4?(uuid)
    refute Identity.valid_uuid5?(uuid)

    runtime_uuid = Identity.uuid4()
    assert Identity.valid_uuid4?(runtime_uuid)
    assert runtime_uuid == String.downcase(runtime_uuid)
  end

  test "UUIDv4 generation fails closed on malformed random sources" do
    assert_raise ArgumentError, "UUIDv4 random source must return exactly 16 bytes", fn ->
      Identity.uuid4(fn _requested_bytes -> <<0::120>> end)
    end

    assert_raise ArgumentError, "UUIDv4 random source must return exactly 16 bytes", fn ->
      Identity.uuid4(fn _requested_bytes -> :not_binary end)
    end

    assert_raise ArgumentError, "UUIDv4 random source must be a one-argument function", fn ->
      Identity.uuid4(:not_a_function)
    end
  end

  test "UUIDv5 matches the RFC vector and is namespace and name deterministic" do
    expected = "21f7f8de-8051-5b89-8680-0195ef798b6a"

    assert Identity.uuid5(@dns_namespace, "www.widgets.com") == expected
    assert Identity.uuid5(String.upcase(@dns_namespace), "www.widgets.com") == expected
    assert Identity.uuid5(@dns_namespace, "www.widgets.com") == expected
    refute Identity.uuid5(@dns_namespace, "other.widgets.com") == expected
    assert Identity.valid_uuid?(expected)
    assert Identity.valid_uuid5?(expected)
    refute Identity.valid_uuid4?(expected)
  end

  test "UUIDv5 rejects malformed namespaces and non-binary names" do
    for namespace <- ["not-a-uuid", "00000000-0000-0000-0000-000000000000", nil] do
      assert_raise ArgumentError, "UUIDv5 namespace must be an RFC-compatible UUID", fn ->
        Identity.uuid5(namespace, "event")
      end
    end

    assert_raise ArgumentError, "UUIDv5 name must be a binary", fn ->
      Identity.uuid5(@dns_namespace, :event)
    end
  end

  test "validators reject malformed syntax, versions, and variants without raising" do
    assert Identity.valid_uuid?(@dns_namespace)
    assert Identity.valid_uuid?(String.upcase(@dns_namespace))

    for invalid <- [
          nil,
          123,
          "",
          "6ba7b8109dad11d180b400c04fd430c8",
          "6ba7b810-9dad-11d1-80b4-00c04fd430cg",
          "00000000-0000-0000-8000-000000000000",
          "00000000-0000-4000-0000-000000000000"
        ] do
      refute Identity.valid_uuid?(invalid)
      refute Identity.valid_uuid4?(invalid)
      refute Identity.valid_uuid5?(invalid)
    end
  end
end
