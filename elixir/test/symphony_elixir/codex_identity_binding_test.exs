# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.IdentityBindingTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias SymphonyElixir.Codex.{CapabilityError, IdentityBinding}

  test "derives a stable redacted binding and binds the local generation" do
    key = :crypto.strong_rand_bytes(32)
    other_key = :crypto.strong_rand_bytes(32)
    account = %{"type" => "chatgpt", "email" => "  Operator@Example.COM  "}

    assert {:ok, first} = IdentityBinding.derive(account, key, 1)

    assert {:ok, normalized} =
             IdentityBinding.derive(%{"type" => "chatgpt", "email" => "Operator@example.com"}, key, 1)

    assert first == normalized
    assert first.status == :confirmed
    assert first.evidence == :keyed_account_metadata
    assert first.generation == 1
    refute first.provider_identifier_available
    assert first.binding_id =~ ~r/\Acodex-binding-v1-[0-9a-f]{64}\z/

    assert {:ok, next_generation} = IdentityBinding.derive(account, key, 2)
    assert {:ok, other_secret} = IdentityBinding.derive(account, other_key, 1)

    assert {:ok, different_local_case} =
             IdentityBinding.derive(%{"type" => "chatgpt", "email" => "operator@example.com"}, key, 1)

    refute next_generation.binding_id == first.binding_id
    refute other_secret.binding_id == first.binding_id
    refute different_local_case.binding_id == first.binding_id

    rendered = inspect(first)
    refute rendered =~ "Operator@Example.COM"
    refute rendered =~ "operator@example.com"
  end

  test "fails closed when stable account metadata is unavailable" do
    key = :crypto.strong_rand_bytes(32)

    for account <- [
          nil,
          %{"type" => "chatgpt", "email" => nil},
          %{"type" => "chatgpt", "email" => "   "},
          %{"type" => "chatgpt", "email" => "not-an-address"},
          %{"type" => "apiKey"},
          %{"type" => "unknown", "email" => "operator@example.com"}
        ] do
      assert {:ok,
              %{
                binding_id: nil,
                evidence: :unavailable,
                generation: 7,
                provider_identifier_available: false,
                status: :unconfirmed
              }} = IdentityBinding.derive(account, key, 7)
    end
  end

  test "rejects invalid binding inputs with content-free diagnostics" do
    assert {:error, %CapabilityError{kind: :invalid_identity_binding_input}} =
             IdentityBinding.derive(%{"type" => "chatgpt", "email" => "operator@example.com"}, <<0>>, 1)

    assert {:error, %CapabilityError{kind: :invalid_identity_binding_input}} =
             IdentityBinding.derive(
               %{"type" => "chatgpt", "email" => "operator@example.com"},
               :crypto.strong_rand_bytes(33),
               1
             )

    assert {:error, %CapabilityError{kind: :invalid_identity_binding_input}} =
             IdentityBinding.derive(:not_an_account, :not_a_key, 0)
  end

  test "creates and reloads a protected 256-bit local key" do
    root = private_root!()
    path = Path.join([root, "state", "binding.key"])

    assert {:ok, first} = IdentityBinding.load_or_create_key(path)
    assert byte_size(first) == 32
    assert {:ok, ^first} = IdentityBinding.load_or_create_key(path)

    assert {:ok, %File.Stat{type: :directory, mode: parent_mode}} =
             File.lstat(Path.dirname(path))

    assert {:ok, %File.Stat{type: :regular, mode: file_mode}} = File.lstat(path)
    assert (parent_mode &&& 0o777) == 0o700
    assert (file_mode &&& 0o777) == 0o600
    assert File.read!(path) == first
    assert Path.wildcard(Path.join(Path.dirname(path), ".binding.key.tmp-*")) == []
  end

  test "publishes one complete key under concurrent creation" do
    root = private_root!()
    path = Path.join([root, "concurrent", "binding.key"])

    results =
      1..8
      |> Task.async_stream(
        fn _index -> IdentityBinding.load_or_create_key(path) end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, key}} -> key end)

    assert length(Enum.uniq(results)) == 1
    assert byte_size(hd(results)) == 32
    assert File.read!(path) == hd(results)
    assert Path.wildcard(Path.join(Path.dirname(path), ".binding.key.tmp-*")) == []
  end

  test "ignores a relative XDG state override instead of resolving it in the checkout" do
    previous = System.get_env("XDG_STATE_HOME")
    on_exit(fn -> restore_env("XDG_STATE_HOME", previous) end)
    System.put_env("XDG_STATE_HOME", "relative-state")

    refute String.contains?(IdentityBinding.default_key_path(), "/relative-state/")
    assert Path.type(IdentityBinding.default_key_path()) == :absolute
  end

  test "rejects unsafe permissions, file types, key lengths, and parent symlinks" do
    root = private_root!()
    current_uid = File.stat!("/proc/self").uid
    assert IdentityBinding.owned_by_current_user?(current_uid)
    refute IdentityBinding.owned_by_current_user?(current_uid + 1)

    unsafe_permissions = Path.join([root, "permissions", "binding.key"])
    File.mkdir_p!(Path.dirname(unsafe_permissions))
    File.chmod!(Path.dirname(unsafe_permissions), 0o700)
    File.write!(unsafe_permissions, :crypto.strong_rand_bytes(32))
    File.chmod!(unsafe_permissions, 0o644)

    assert_key_error(unsafe_permissions, :unsafe_permissions)

    invalid_key = Path.join([root, "invalid", "binding.key"])
    File.mkdir_p!(Path.dirname(invalid_key))
    File.chmod!(Path.dirname(invalid_key), 0o700)
    File.write!(invalid_key, :crypto.strong_rand_bytes(31))
    File.chmod!(invalid_key, 0o600)

    assert_key_error(invalid_key, :invalid_key)

    directory_path = Path.join([root, "directory", "binding.key"])
    File.mkdir_p!(directory_path)
    File.chmod!(Path.dirname(directory_path), 0o700)

    assert_key_error(directory_path, :unsafe_file_type)

    symlink_parent = Path.join(root, "symlink")
    File.mkdir_p!(symlink_parent)
    File.chmod!(symlink_parent, 0o700)
    target = Path.join(symlink_parent, "target.key")
    link = Path.join(symlink_parent, "binding.key")
    File.write!(target, :crypto.strong_rand_bytes(32))
    File.chmod!(target, 0o600)
    File.ln_s!(target, link)

    assert_key_error(link, :unsafe_symlink_path)

    real_parent = Path.join(root, "real-parent")
    linked_parent = Path.join(root, "linked-parent")
    File.mkdir_p!(real_parent)
    File.ln_s!(real_parent, linked_parent)

    assert_key_error(Path.join(linked_parent, "binding.key"), :unsafe_symlink_path)

    broad_parent = Path.join(root, "broad-parent")
    File.mkdir_p!(broad_parent)
    File.chmod!(broad_parent, 0o755)

    assert_key_error(
      Path.join(broad_parent, "binding.key"),
      :unsafe_parent_permissions
    )
  end

  test "rejects key locations inside an explicitly forbidden worktree" do
    root = private_root!()
    path = Path.join([root, "repository", ".state", "binding.key"])

    assert_key_error(path, :inside_forbidden_root, [Path.join(root, "repository")])
    refute File.exists?(Path.dirname(path))
  end

  test "rejects an ancestor-symlink escape into a forbidden worktree" do
    root = private_root!()
    repository = Path.join(root, "repository")
    outside = Path.join(root, "outside")
    linked_repository = Path.join(outside, "linked-repository")

    File.mkdir_p!(repository)
    File.mkdir_p!(outside)
    File.chmod!(repository, 0o700)
    File.chmod!(outside, 0o700)
    File.ln_s!(repository, linked_repository)

    path = Path.join([linked_repository, "state", "binding.key"])

    assert_key_error(path, :unsafe_symlink_path, [repository])
    refute File.exists?(Path.join(repository, "state"))
  end

  defp assert_key_error(path, reason, forbidden_roots \\ []) do
    assert {:error,
            %CapabilityError{
              kind: :identity_key_unavailable,
              method: nil,
              reason: ^reason
            }} = IdentityBinding.load_or_create_key(path, forbidden_roots)
  end

  defp private_root! do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-identity-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
