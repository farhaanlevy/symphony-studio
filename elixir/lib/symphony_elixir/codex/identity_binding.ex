# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.IdentityBinding do
  @moduledoc """
  Derives a stable non-secret Codex account binding without persisting email.

  Codex 0.144.3 exposes a nullable ChatGPT email but no opaque stable account
  identifier. The email is therefore trimmed, its case-insensitive domain is
  canonicalized in memory, and the result is keyed with a local 256-bit secret
  stored outside the repository. The resulting binding is safe to persist;
  the input and key are not.
  """

  import Bitwise

  alias SymphonyElixir.Codex.CapabilityError
  alias SymphonyElixir.PathSafety

  @key_bytes 32
  @binding_domain "symphony-studio/codex-identity/v1\0"
  @key_filename "codex-identity-binding-v1.key"

  @type binding :: %{
          binding_id: String.t() | nil,
          evidence: :keyed_account_metadata | :unavailable,
          generation: pos_integer(),
          provider_identifier_available: boolean(),
          status: :confirmed | :unconfirmed
        }

  @spec default_key_path() :: Path.t()
  def default_key_path do
    state_home =
      case System.get_env("XDG_STATE_HOME") do
        value when is_binary(value) and value != "" ->
          if Path.type(value) == :absolute, do: Path.expand(value), else: Path.expand("~/.local/state")

        _other ->
          Path.expand("~/.local/state")
      end

    Path.join([state_home, "symphony-studio", @key_filename])
  end

  @doc false
  @spec owned_by_current_user?(non_neg_integer()) :: boolean()
  def owned_by_current_user?(uid) when is_integer(uid) and uid >= 0 do
    case File.stat("/proc/self") do
      {:ok, %File.Stat{type: :directory, uid: ^uid}} -> true
      _other -> false
    end
  end

  def owned_by_current_user?(_uid), do: false

  def load_or_create_key(path \\ default_key_path(), forbidden_roots \\ [])

  @spec load_or_create_key(Path.t(), [Path.t()]) ::
          {:ok, binary()} | {:error, CapabilityError.t()}
  def load_or_create_key(path, forbidden_roots)
      when is_binary(path) and is_list(forbidden_roots) do
    expanded = Path.expand(path)

    with {:ok, canonical_path} <- canonical_candidate(expanded),
         {:ok, canonical_roots} <- canonical_roots(forbidden_roots),
         :ok <- outside_forbidden_roots(canonical_path, canonical_roots),
         :ok <- ensure_private_parent(Path.dirname(canonical_path)),
         {:ok, ^canonical_path} <- canonical_candidate(expanded),
         :ok <- outside_forbidden_roots(canonical_path, canonical_roots) do
      case load_key(canonical_path) do
        {:ok, key} ->
          {:ok, key}

        {:error, :missing} ->
          create_key(canonical_path)

        {:error, reason} ->
          {:error, CapabilityError.new(:identity_key_unavailable, nil, reason)}
      end
    end
  end

  def derive(account, key, generation \\ 1)

  @spec derive(map() | nil, binary(), pos_integer()) ::
          {:ok, binding()} | {:error, CapabilityError.t()}
  def derive(%{"type" => "chatgpt", "email" => email}, key, generation)
      when is_binary(key) and byte_size(key) == @key_bytes and is_integer(generation) and
             generation > 0 do
    case normalize_email(email) do
      {:ok, normalized_email} ->
        digest =
          :crypto.mac(
            :hmac,
            :sha256,
            key,
            @binding_domain <> Integer.to_string(generation) <> "\0" <> normalized_email
          )

        {:ok,
         %{
           binding_id: "codex-binding-v1-" <> Base.encode16(digest, case: :lower),
           evidence: :keyed_account_metadata,
           generation: generation,
           provider_identifier_available: false,
           status: :confirmed
         }}

      :unavailable ->
        {:ok, unconfirmed(generation)}
    end
  end

  def derive(account, key, generation)
      when (is_map(account) or is_nil(account)) and is_binary(key) and
             byte_size(key) == @key_bytes and is_integer(generation) and generation > 0 do
    {:ok, unconfirmed(generation)}
  end

  def derive(_account, _key, _generation) do
    {:error, CapabilityError.new(:invalid_identity_binding_input)}
  end

  @spec unconfirmed(pos_integer()) :: binding()
  def unconfirmed(generation) when is_integer(generation) and generation > 0 do
    %{
      binding_id: nil,
      evidence: :unavailable,
      generation: generation,
      provider_identifier_available: false,
      status: :unconfirmed
    }
  end

  defp canonical_candidate(expanded) do
    case PathSafety.canonicalize(expanded) do
      {:ok, ^expanded} ->
        {:ok, expanded}

      {:ok, _symlinked_path} ->
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :unsafe_symlink_path)}

      {:error, _reason} ->
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :canonicalization_failed)}
    end
  end

  defp canonical_roots(roots) do
    roots
    |> Enum.reduce_while({:ok, []}, fn
      root, {:ok, acc} when is_binary(root) ->
        case PathSafety.canonicalize(root) do
          {:ok, canonical_root} ->
            {:cont, {:ok, [canonical_root | acc]}}

          {:error, _reason} ->
            {:halt, {:error, CapabilityError.new(:identity_key_unavailable, nil, :invalid_forbidden_root)}}
        end

      _invalid, {:ok, _acc} ->
        {:halt, {:error, CapabilityError.new(:identity_key_unavailable, nil, :invalid_forbidden_root)}}
    end)
    |> case do
      {:ok, canonical_roots} -> {:ok, Enum.reverse(canonical_roots)}
      {:error, %CapabilityError{}} = error -> error
    end
  end

  defp outside_forbidden_roots(path, roots) do
    if Enum.any?(roots, &within?(path, &1)),
      do: {:error, CapabilityError.new(:identity_key_unavailable, nil, :inside_forbidden_root)},
      else: :ok
  end

  defp within?(path, "/"), do: String.starts_with?(path, "/")
  defp within?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp ensure_private_parent(parent) do
    case File.lstat(parent) do
      {:ok, %File.Stat{type: :directory, mode: mode, uid: uid}} ->
        cond do
          (mode &&& 0o777) != 0o700 ->
            {:error, CapabilityError.new(:identity_key_unavailable, nil, :unsafe_parent_permissions)}

          not owned_by_current_user?(uid) ->
            {:error, CapabilityError.new(:identity_key_unavailable, nil, :unsafe_parent_owner)}

          true ->
            :ok
        end

      {:ok, _other} ->
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :unsafe_parent)}

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(parent),
             :ok <- File.chmod(parent, 0o700),
             :ok <- ensure_private_parent(parent) do
          :ok
        else
          _other -> {:error, CapabilityError.new(:identity_key_unavailable, nil, :create_failed)}
        end

      {:error, _reason} ->
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :inspect_failed)}
    end
  end

  defp load_key(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, uid: uid}} ->
        validate_and_read_key(path, mode, uid)

      {:ok, _other} ->
        {:error, :unsafe_file_type}

      {:error, :enoent} ->
        {:error, :missing}

      {:error, _reason} ->
        {:error, :inspect_failed}
    end
  end

  defp validate_and_read_key(path, mode, uid) do
    cond do
      (mode &&& 0o777) != 0o600 ->
        {:error, :unsafe_permissions}

      not owned_by_current_user?(uid) ->
        {:error, :unsafe_owner}

      true ->
        read_key(path)
    end
  end

  defp read_key(path) do
    case File.read(path) do
      {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
      {:ok, _invalid} -> {:error, :invalid_key}
      {:error, _reason} -> {:error, :read_failed}
    end
  end

  defp create_key(path) do
    key = :crypto.strong_rand_bytes(@key_bytes)
    temporary_path = temporary_key_path(path)

    case File.write(temporary_path, key, [:binary, :exclusive, :sync]) do
      :ok ->
        try do
          publish_key(temporary_path, path, key)
        after
          File.rm(temporary_path)
        end

      {:error, _reason} ->
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :create_failed)}
    end
  end

  defp publish_key(temporary_path, path, expected_key) do
    with :ok <- File.chmod(temporary_path, 0o600),
         {:ok, ^expected_key} <- load_key(temporary_path) do
      case File.ln(temporary_path, path) do
        :ok ->
          verify_published_key(path)

        {:error, :eexist} ->
          load_existing_key(path)

        {:error, _reason} ->
          {:error, CapabilityError.new(:identity_key_unavailable, nil, :create_failed)}
      end
    else
      _other -> {:error, CapabilityError.new(:identity_key_unavailable, nil, :create_failed)}
    end
  end

  defp verify_published_key(path) do
    case load_key(path) do
      {:ok, loaded} ->
        {:ok, loaded}

      {:error, _reason} ->
        File.rm(path)
        {:error, CapabilityError.new(:identity_key_unavailable, nil, :create_failed)}
    end
  end

  defp load_existing_key(path) do
    case load_key(path) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, CapabilityError.new(:identity_key_unavailable, nil, reason)}
    end
  end

  defp temporary_key_path(path) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-#{suffix}")
  end

  defp normalize_email(email) when is_binary(email) do
    normalized = String.trim(email)

    case String.split(normalized, "@", parts: 2) do
      [local, domain]
      when local != "" and domain != "" and byte_size(normalized) <= 320 ->
        {:ok, local <> "@" <> String.downcase(domain)}

      _invalid ->
        :unavailable
    end
  end

  defp normalize_email(_email), do: :unavailable
end
