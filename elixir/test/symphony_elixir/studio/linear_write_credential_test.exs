# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteCredentialTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Studio.LinearWriteBroker.ProtectedCredential

  @pointer "SYMPHONY_LINEAR_WRITE_ENV_FILE"

  setup do
    previous_pointer = System.get_env(@pointer)
    previous_query_key = System.get_env("LINEAR_API_KEY")
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "symphony-linear-write-credential-#{unique}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)

    on_exit(fn ->
      restore_env(@pointer, previous_pointer)
      restore_env("LINEAR_API_KEY", previous_query_key)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "accepts exactly one owner-only assignment and reveals it only to the callback", ctx do
    path = protected_file(ctx.root, "SYMPHONY_LINEAR_WRITE_API_KEY=test-write-key\n")
    System.put_env(@pointer, path)

    assert :ok = ProtectedCredential.validate()

    assert :key_was_in_memory =
             ProtectedCredential.with_api_key(fn key ->
               assert key == "test-write-key"
               :key_was_in_memory
             end)
  end

  test "never falls back to the query-only environment key" do
    System.delete_env(@pointer)
    System.put_env("LINEAR_API_KEY", "query-only-key-must-not-load")

    assert {:error, :linear_write_credential_pointer_missing} = ProtectedCredential.validate()
  end

  test "rejects unsafe mode, symlink, hard link, repository location, and extra content", ctx do
    unsafe_mode = protected_file(ctx.root, "SYMPHONY_LINEAR_WRITE_API_KEY=mode-key\n")
    File.chmod!(unsafe_mode, 0o640)
    assert_rejected(unsafe_mode, :linear_write_credential_file_unsafe)

    target = protected_file(ctx.root, "SYMPHONY_LINEAR_WRITE_API_KEY=target-key\n", "target.env")
    symlink = Path.join(ctx.root, "symlink.env")
    File.ln_s!(target, symlink)
    assert_rejected(symlink, :linear_write_credential_path_unsafe)

    hard_target = protected_file(ctx.root, "SYMPHONY_LINEAR_WRITE_API_KEY=hard-key\n", "hard.env")
    hardlink = Path.join(ctx.root, "hard-copy.env")
    :ok = File.ln(hard_target, hardlink)
    assert_rejected(hard_target, :linear_write_credential_file_unsafe)

    repository = Path.join(ctx.root, "repository")
    File.mkdir_p!(Path.join(repository, ".git"))
    inside = protected_file(repository, "SYMPHONY_LINEAR_WRITE_API_KEY=repo-key\n")
    assert_rejected(inside, :linear_write_credential_inside_git)

    extra =
      protected_file(
        ctx.root,
        "SYMPHONY_LINEAR_WRITE_API_KEY=first\nSYMPHONY_LINEAR_WRITE_API_KEY=second\n",
        "extra.env"
      )

    assert_rejected(extra, :linear_write_credential_content_invalid)
  end

  test "rejects the R0 query-only assignment in the separate write file", ctx do
    path = protected_file(ctx.root, "LINEAR_API_KEY=query-only-key\n")
    assert_rejected(path, :linear_write_credential_content_invalid)
  end

  defp protected_file(root, body, name \\ "write.env") do
    path = Path.join(root, name)
    File.write!(path, body)
    File.chmod!(path, 0o600)
    path
  end

  defp assert_rejected(path, reason) do
    System.put_env(@pointer, path)
    assert {:error, ^reason} = ProtectedCredential.validate()
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
