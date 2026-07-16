# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio bounds symlink
# traversal and returns typed loop errors.

defmodule SymphonyElixir.PathSafety do
  @moduledoc false

  @max_symlink_traversals 40

  @spec canonicalize(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def canonicalize(path) when is_binary(path) do
    expanded_path = Path.expand(path)
    {root, segments} = split_absolute_path(expanded_path)

    case resolve_segments(root, [], segments, %{}, 0) do
      {:ok, canonical_path} ->
        {:ok, canonical_path}

      {:error, reason} ->
        {:error, {:path_canonicalize_failed, expanded_path, reason}}
    end
  end

  defp split_absolute_path(path) when is_binary(path) do
    [root | segments] = Path.split(path)
    {root, segments}
  end

  defp resolve_segments(root, resolved_segments, [], _visited_symlinks, _traversals),
    do: {:ok, join_path(root, resolved_segments)}

  defp resolve_segments(root, resolved_segments, [segment | rest], visited_symlinks, traversals) do
    candidate_path = join_path(root, resolved_segments ++ [segment])

    case File.lstat(candidate_path) do
      {:ok, %File.Stat{type: :symlink}} ->
        with :ok <- validate_symlink_traversal(candidate_path, visited_symlinks, traversals),
             {:ok, target} <- :file.read_link_all(String.to_charlist(candidate_path)) do
          resolved_target = Path.expand(IO.chardata_to_string(target), join_path(root, resolved_segments))
          {target_root, target_segments} = split_absolute_path(resolved_target)

          resolve_segments(
            target_root,
            [],
            target_segments ++ rest,
            Map.put(visited_symlinks, candidate_path, true),
            traversals + 1
          )
        end

      {:ok, _stat} ->
        resolve_segments(root, resolved_segments ++ [segment], rest, visited_symlinks, traversals)

      {:error, :enoent} ->
        {:ok, join_path(root, resolved_segments ++ [segment | rest])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_path(root, segments) when is_list(segments) do
    Enum.reduce(segments, root, fn segment, acc -> Path.join(acc, segment) end)
  end

  defp validate_symlink_traversal(candidate_path, visited_symlinks, traversals) do
    cond do
      Map.has_key?(visited_symlinks, candidate_path) ->
        {:error, {:symlink_loop, candidate_path}}

      traversals >= @max_symlink_traversals ->
        {:error, {:too_many_symlinks, @max_symlink_traversals}}

      true ->
        :ok
    end
  end
end
