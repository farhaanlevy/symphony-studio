# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.ProjectInspector do
  @moduledoc """
  Bounded read-only project inspection for intent grounding.

  Inspection never executes project code or Git commands, never follows
  symlinks, and never stores file bodies. It records a deterministic inventory,
  selected document headings, and hashes of bounded public project documents.
  """

  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Studio.Intent.Canonical

  @default_max_files 1_500
  @default_max_depth 10
  @default_max_document_bytes 256 * 1_024
  @excluded_directories MapSet.new(~w(.git .hg .svn _build deps node_modules coverage tmp log))
  @sensitive_names ~r/(^|[._-])(credential|credentials|secret|secrets|token|tokens|private[_-]?key)([._-]|$)/i

  @type error ::
          :invalid_inspection_options
          | :invalid_project_root
          | :project_unavailable

  @doc "Inspects an existing project directory without executing project code."
  @spec inspect(String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def inspect(project_root, opts \\ []) do
    with true <- is_binary(project_root),
         true <- is_list(opts),
         true <- Keyword.keyword?(opts),
         true <- unique_allowed_options?(opts, [:max_files, :max_depth]),
         {:ok, max_files} <- positive_option(opts, :max_files, @default_max_files),
         {:ok, max_depth} <- positive_option(opts, :max_depth, @default_max_depth),
         {:ok, canonical_root} <- canonical_directory(project_root),
         {:ok, inventory} <- walk(canonical_root, max_files, max_depth) do
      {:ok, summarize(canonical_root, inventory)}
    else
      false ->
        {:error, :invalid_inspection_options}

      {:error, reason} when reason in [:invalid_inspection_options, :invalid_project_root] ->
        {:error, reason}

      _error ->
        {:error, :project_unavailable}
    end
  end

  defp canonical_directory(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical) do
      {:ok, canonical}
    else
      _invalid -> {:error, :invalid_project_root}
    end
  end

  defp walk(root, max_files, max_depth) do
    initial = %{files: [], directory_count: 0, unreadable_count: 0, truncated: false}

    case walk_directory(root, "", 0, max_files, max_depth, initial) do
      {:ok, state} -> {:ok, %{state | files: Enum.reverse(state.files)}}
      {:error, _reason} -> {:error, :project_unavailable}
    end
  end

  defp walk_directory(_root, _relative, _depth, max_files, _max_depth, state)
       when length(state.files) >= max_files,
       do: {:ok, %{state | truncated: true}}

  defp walk_directory(_root, _relative, depth, _max_files, max_depth, state)
       when depth > max_depth,
       do: {:ok, %{state | truncated: true}}

  defp walk_directory(root, relative, depth, max_files, max_depth, state) do
    directory = if(relative == "", do: root, else: Path.join(root, relative))

    case File.ls(directory) do
      {:ok, names} ->
        state = %{state | directory_count: state.directory_count + 1}
        reduce_directory_entries(names, root, relative, depth, max_files, max_depth, state)

      {:error, _reason} ->
        {:ok, %{state | unreadable_count: state.unreadable_count + 1}}
    end
  end

  defp reduce_directory_entries(names, root, relative, depth, max_files, max_depth, state) do
    names
    |> Enum.sort()
    |> Enum.reduce_while({:ok, state}, fn name, {:ok, current} ->
      reduce_directory_entry(name, root, relative, depth, max_files, max_depth, current)
    end)
  end

  defp reduce_directory_entry(_name, _root, _relative, _depth, max_files, _max_depth, current)
       when length(current.files) >= max_files,
       do: {:halt, {:ok, %{current | truncated: true}}}

  defp reduce_directory_entry(name, root, relative, depth, max_files, max_depth, current) do
    child_relative = if(relative == "", do: name, else: Path.join(relative, name))

    case inspect_entry(root, child_relative, depth, max_files, max_depth, current) do
      {:ok, next} ->
        {:cont, {:ok, next}}

      {:error, _reason} ->
        {:cont, {:ok, %{current | unreadable_count: current.unreadable_count + 1}}}
    end
  end

  defp inspect_entry(root, relative, depth, max_files, max_depth, state) do
    absolute = Path.join(root, relative)

    case File.lstat(absolute) do
      {:ok, %File.Stat{type: :directory}} ->
        if excluded_directory?(Path.basename(relative)) do
          {:ok, state}
        else
          walk_directory(root, relative, depth + 1, max_files, max_depth, state)
        end

      {:ok, %File.Stat{type: :regular, size: size}} ->
        if excluded_file?(relative) do
          {:ok, state}
        else
          {:ok, %{state | files: [%{path: relative, bytes: size} | state.files]}}
        end

      {:ok, _other} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp summarize(root, inventory) do
    files = inventory.files
    paths = Enum.map(files, & &1.path)
    spec_paths = Enum.filter(paths, &spec_path?/1) |> Enum.take(32)
    architecture_paths = Enum.filter(paths, &architecture_path?/1) |> Enum.take(64)
    test_paths = Enum.filter(paths, &test_path?/1)
    headings = document_headings(root, spec_paths)
    fingerprints = document_fingerprints(root, files, spec_paths)

    summary = %{
      "architecture_paths" => architecture_paths,
      "directory_count" => inventory.directory_count,
      "extension_counts" => extension_counts(paths),
      "file_count" => length(files),
      "headings" => headings,
      "public_document_fingerprints" => fingerprints,
      "spec_paths" => spec_paths,
      "test_file_count" => length(test_paths),
      "test_paths" => Enum.take(test_paths, 64),
      "truncated" => inventory.truncated,
      "unreadable_count" => inventory.unreadable_count
    }

    Map.put(summary, "digest", Canonical.digest(summary))
  end

  defp document_headings(root, paths) do
    paths
    |> Enum.take(12)
    |> Enum.flat_map(fn path ->
      case bounded_read(Path.join(root, path)) do
        {:ok, contents} -> extract_headings(path, contents)
        {:error, _reason} -> []
      end
    end)
    |> Enum.take(96)
  end

  defp extract_headings(path, contents) do
    contents
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^([#]{1,6})\s+(.{1,200}?)\s*$/, line) do
        [_, marks, heading] ->
          [%{"heading" => heading, "level" => byte_size(marks), "path" => path}]

        _no_heading ->
          []
      end
    end)
    |> Enum.take(24)
  end

  defp document_fingerprints(root, files, paths) do
    by_path = Map.new(files, &{&1.path, &1.bytes})

    paths
    |> Enum.take(24)
    |> Enum.flat_map(fn path ->
      case bounded_read(Path.join(root, path)) do
        {:ok, contents} ->
          [
            %{
              "bytes" => Map.get(by_path, path),
              "path" => path,
              "sha256" => :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
            }
          ]

        {:error, _reason} ->
          []
      end
    end)
  end

  defp bounded_read(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @default_max_document_bytes <-
           File.stat(path),
         {:ok, contents} <- File.read(path),
         true <- String.valid?(contents) do
      {:ok, contents}
    else
      _invalid -> {:error, :unavailable}
    end
  end

  defp extension_counts(paths) do
    paths
    |> Enum.map(fn path ->
      case Path.extname(path) do
        "" -> "[none]"
        extension -> String.downcase(extension)
      end
    end)
    |> Enum.frequencies()
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp spec_path?(path) do
    base = path |> Path.basename() |> String.downcase()

    base in ["agents.md", "readme.md", "spec.md", "studio_spec.md", "contributing.md"] or
      String.ends_with?(base, "_spec.md") or String.ends_with?(base, "-spec.md")
  end

  defp architecture_path?(path) do
    segments = String.split(path, "/")

    Enum.any?(segments, &(&1 in ~w(lib src app apps config test tests spec))) or
      Path.basename(path) in ~w(mix.exs package.json pyproject.toml Cargo.toml go.mod)
  end

  defp test_path?(path) do
    segments = path |> String.downcase() |> String.split("/")
    base = path |> Path.basename() |> String.downcase()

    Enum.any?(segments, &(&1 in ~w(test tests spec specs))) or
      String.contains?(base, "_test.") or String.contains?(base, ".test.") or
      String.contains?(base, "_spec.") or String.contains?(base, ".spec.")
  end

  defp excluded_directory?(name),
    do: MapSet.member?(@excluded_directories, name) or String.starts_with?(name, ".")

  defp excluded_file?(relative) do
    base = Path.basename(relative)
    String.starts_with?(base, ".") or Regex.match?(@sensitive_names, base)
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, :invalid_inspection_options}
    end
  end

  defp unique_allowed_options?(opts, allowed) do
    keys = Keyword.keys(opts)
    Enum.all?(keys, &(&1 in allowed)) and length(keys) == MapSet.size(MapSet.new(keys))
  end
end
