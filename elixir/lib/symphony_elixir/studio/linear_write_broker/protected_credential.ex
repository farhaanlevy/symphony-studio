# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.ProtectedCredential do
  @moduledoc """
  Loads the separate Studio Linear write credential through a protected file.

  The pointer is intentionally command-scoped and the key is passed only to the
  supplied in-memory callback. Before that callback, the module requires the R0
  query credential through its protected pointer or supported environment and
  proves the two values differ with a fixed-size constant-time comparison.
  Neither pointer nor key is returned in an error, logged, hashed, persisted, or
  copied into application configuration.
  """

  import Bitwise

  alias SymphonyElixir.Codex.IdentityBinding
  alias SymphonyElixir.PathSafety

  @pointer_name "SYMPHONY_LINEAR_WRITE_ENV_FILE"
  @assignment_name "SYMPHONY_LINEAR_WRITE_API_KEY"
  @query_pointer_name "SYMPHONY_LINEAR_ENV_FILE"
  @query_assignment_name "LINEAR_API_KEY"
  @max_file_bytes 4 * 1_024
  @max_key_bytes 1_024

  @type error ::
          :linear_write_credential_pointer_missing
          | :linear_write_credential_pointer_invalid
          | :linear_write_credential_path_unsafe
          | :linear_write_credential_inside_git
          | :linear_write_credential_file_missing
          | :linear_write_credential_file_unsafe
          | :linear_write_credential_file_changed
          | :linear_write_credential_content_invalid
          | :linear_write_credential_comparison_unavailable
          | :linear_write_credential_not_distinct

  @doc "Validates the protected write-credential file without returning its key or path."
  @spec validate() :: :ok | {:error, error()}
  def validate do
    with_api_key(fn _key -> :ok end)
  end

  @doc "Runs one callback with the protected key in memory after all file checks pass."
  @spec with_api_key((String.t() -> result)) :: result | {:error, error()} when result: term()
  def with_api_key(fun) when is_function(fun, 1) do
    with {:ok, path} <- pointer_path(),
         {:ok, key} <- read_key(path, @assignment_name),
         {:ok, query_key} <- query_key(),
         false <- constant_time_equal?(key, query_key) do
      fun.(key)
    else
      true -> {:error, :linear_write_credential_not_distinct}
      {:error, _reason} = error -> error
    end
  end

  def with_api_key(_invalid), do: {:error, :linear_write_credential_pointer_invalid}

  defp pointer_path do
    case System.get_env(@pointer_name) do
      value when is_binary(value) -> validate_pointer(value)
      _missing -> {:error, :linear_write_credential_pointer_missing}
    end
  end

  defp validate_pointer(value) do
    cond do
      value == "" or value != String.trim(value) or not String.valid?(value) ->
        {:error, :linear_write_credential_pointer_invalid}

      Path.type(value) != :absolute ->
        {:error, :linear_write_credential_pointer_invalid}

      true ->
        expanded = Path.expand(value)

        case PathSafety.canonicalize(expanded) do
          {:ok, ^expanded} -> {:ok, expanded}
          {:ok, _different} -> {:error, :linear_write_credential_path_unsafe}
          {:error, _reason} -> {:error, :linear_write_credential_file_missing}
        end
    end
  end

  defp safe_file_stat(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode, links: 1, uid: uid, size: size} = stat}
      when is_integer(size) and size in 1..@max_file_bytes ->
        cond do
          (mode &&& 0o777) != 0o600 ->
            {:error, :linear_write_credential_file_unsafe}

          not IdentityBinding.owned_by_current_user?(uid) ->
            {:error, :linear_write_credential_file_unsafe}

          true ->
            {:ok, stat}
        end

      {:ok, %File.Stat{}} ->
        {:error, :linear_write_credential_file_unsafe}

      {:error, :enoent} ->
        {:error, :linear_write_credential_file_missing}

      {:error, _reason} ->
        {:error, :linear_write_credential_file_unsafe}
    end
  end

  defp bounded_read(path, expected_size) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @max_file_bytes + 1) do
            body when is_binary(body) and byte_size(body) == expected_size -> {:ok, body}
            _invalid -> {:error, :linear_write_credential_file_changed}
          end
        after
          File.close(io)
        end

      {:error, _reason} ->
        {:error, :linear_write_credential_file_unsafe}
    end
  end

  defp same_file?(left, right) do
    fields = [:type, :mode, :links, :major_device, :minor_device, :inode, :uid, :size, :mtime, :ctime]
    Enum.all?(fields, &(Map.fetch!(left, &1) == Map.fetch!(right, &1)))
  end

  defp read_key(path, assignment_name) do
    with :ok <- outside_git(path),
         {:ok, before_stat} <- safe_file_stat(path),
         {:ok, body} <- bounded_read(path, before_stat.size),
         {:ok, after_stat} <- safe_file_stat(path),
         true <- same_file?(before_stat, after_stat),
         {:ok, key} <- parse_assignment(body, assignment_name) do
      {:ok, key}
    else
      false -> {:error, :linear_write_credential_file_changed}
      {:error, _reason} = error -> error
    end
  end

  defp parse_assignment(body, assignment_name) do
    prefix = assignment_name <> "="

    case body do
      <<^prefix::binary, key::binary>> -> validate_key(strip_single_trailing_newline(key))
      _invalid -> {:error, :linear_write_credential_content_invalid}
    end
  end

  defp strip_single_trailing_newline(value) do
    if String.ends_with?(value, "\n"),
      do: binary_part(value, 0, byte_size(value) - 1),
      else: value
  end

  defp validate_key(key) do
    if String.valid?(key) and byte_size(key) in 1..@max_key_bytes and key == String.trim(key) and
         not String.contains?(key, ["\n", "\r", "\0"]) do
      {:ok, key}
    else
      {:error, :linear_write_credential_content_invalid}
    end
  end

  defp query_key do
    case System.get_env(@query_pointer_name) do
      value when is_binary(value) -> query_key_from_pointer(value)
      _missing -> query_key_from_environment()
    end
  end

  defp query_key_from_pointer(value) do
    with {:ok, path} <- validate_pointer(value),
         {:ok, key} <- read_key(path, @query_assignment_name) do
      {:ok, key}
    else
      _unavailable -> {:error, :linear_write_credential_comparison_unavailable}
    end
  end

  defp query_key_from_environment do
    case System.get_env(@query_assignment_name) do
      value when is_binary(value) ->
        case validate_key(value) do
          {:ok, key} -> {:ok, key}
          {:error, _reason} -> {:error, :linear_write_credential_comparison_unavailable}
        end

      _missing ->
        {:error, :linear_write_credential_comparison_unavailable}
    end
  end

  defp constant_time_equal?(left, right) do
    Plug.Crypto.secure_compare(comparison_frame(left), comparison_frame(right))
  end

  defp comparison_frame(value) do
    length = byte_size(value)
    padding = @max_key_bytes - length
    <<length::unsigned-integer-size(16), value::binary, 0::size(padding * 8)>>
  end

  defp outside_git(path) do
    if inside_git_tree?(Path.dirname(path)),
      do: {:error, :linear_write_credential_inside_git},
      else: :ok
  end

  defp inside_git_tree?("/"), do: git_marker?("/")

  defp inside_git_tree?(directory) do
    git_marker?(directory) or inside_git_tree?(Path.dirname(directory))
  end

  defp git_marker?(directory) do
    Path.basename(directory) == ".git" or
      File.exists?(Path.join(directory, ".git")) or
      bare_git_directory?(directory)
  end

  defp bare_git_directory?(directory) do
    File.regular?(Path.join(directory, "HEAD")) and
      File.dir?(Path.join(directory, "objects")) and
      File.dir?(Path.join(directory, "refs"))
  end
end
