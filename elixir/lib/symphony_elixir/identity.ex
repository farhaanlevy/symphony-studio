# Downstream modification notice (2026-07-16): Symphony Studio adds stable,
# RFC-compatible UUID identities for runs, attempts, operations, and events.
defmodule SymphonyElixir.Identity do
  @moduledoc """
  Generates and validates the UUID identities used by Symphony Studio.

  Runtime identities use UUIDv4. Deterministic identities use UUIDv5 so the
  namespace and name, rather than process-local state, define the result.
  """

  import Bitwise

  @type uuid :: String.t()
  @type random_bytes_fun :: (pos_integer() -> binary())

  @spec uuid4() :: uuid()
  def uuid4, do: uuid4(&:crypto.strong_rand_bytes/1)

  @spec uuid4(random_bytes_fun()) :: uuid()
  def uuid4(random_bytes_fun) when is_function(random_bytes_fun, 1) do
    case random_bytes_fun.(16) do
      bytes when is_binary(bytes) and byte_size(bytes) == 16 ->
        bytes
        |> set_version_and_variant(4)
        |> format_uuid()

      _other ->
        raise ArgumentError, "UUIDv4 random source must return exactly 16 bytes"
    end
  end

  def uuid4(_random_bytes_fun) do
    raise ArgumentError, "UUIDv4 random source must be a one-argument function"
  end

  @spec uuid5(uuid(), binary()) :: uuid()
  def uuid5(namespace, name) when is_binary(name) do
    case valid_uuid?(namespace) && decode_uuid(namespace) do
      {:ok, namespace_bytes} ->
        namespace_bytes
        |> then(&:crypto.hash(:sha, &1 <> name))
        |> binary_part(0, 16)
        |> set_version_and_variant(5)
        |> format_uuid()

      _invalid ->
        raise ArgumentError, "UUIDv5 namespace must be an RFC-compatible UUID"
    end
  end

  def uuid5(_namespace, _name) do
    raise ArgumentError, "UUIDv5 name must be a binary"
  end

  @spec valid_uuid?(term()) :: boolean()
  def valid_uuid?(uuid) do
    case decode_uuid(uuid) do
      {:ok, <<_::48, version::4, _::12, 2::2, _::62>>} -> version in 1..8
      _other -> false
    end
  end

  @spec valid_uuid4?(term()) :: boolean()
  def valid_uuid4?(uuid) do
    case decode_uuid(uuid) do
      {:ok, <<_::48, 4::4, _::12, 2::2, _::62>>} -> true
      _other -> false
    end
  end

  @spec valid_uuid5?(term()) :: boolean()
  def valid_uuid5?(uuid) do
    case decode_uuid(uuid) do
      {:ok, <<_::48, 5::4, _::12, 2::2, _::62>>} -> true
      _other -> false
    end
  end

  defp set_version_and_variant(
         <<prefix::binary-size(6), version_byte, middle::binary-size(1), variant_byte, suffix::binary-size(7)>>,
         version
       ) do
    version_byte = bor(band(version_byte, 0x0F), version <<< 4)
    variant_byte = bor(band(variant_byte, 0x3F), 0x80)
    <<prefix::binary, version_byte, middle::binary, variant_byte, suffix::binary>>
  end

  defp format_uuid(bytes) do
    hex = Base.encode16(bytes, case: :lower)
    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4), e::binary-size(12)>> = hex
    Enum.join([a, b, c, d, e], "-")
  end

  defp decode_uuid(uuid) when is_binary(uuid) do
    with [a, b, c, d, e] <- String.split(uuid, "-", trim: false),
         [8, 4, 4, 4, 12] <- Enum.map([a, b, c, d, e], &byte_size/1) do
      Base.decode16(a <> b <> c <> d <> e, case: :mixed)
    else
      _invalid -> :error
    end
  end

  defp decode_uuid(_uuid), do: :error
end
