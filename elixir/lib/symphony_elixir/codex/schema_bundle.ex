# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.SchemaBundle do
  @moduledoc """
  Loads the exact generated Codex App Server contract pinned by Studio.

  Static schema presence is deliberately distinct from the live compatibility
  probes and account capability record produced by R0-06.
  """

  @version_file Path.expand("../../../priv/codex_schema/CODEX_VERSION", __DIR__)
  @external_resource @version_file
  @version @version_file |> File.read!() |> String.trim()
  @max_json_bytes 1_048_576

  alias SymphonyElixir.PathSafety

  @type json_object :: %{optional(String.t()) => term()}

  @spec version() :: String.t()
  def version, do: @version

  @spec bundle_path() :: String.t()
  def bundle_path do
    code_bundle = code_bundle_path()

    if safe_bundle_directory?(code_bundle) do
      code_bundle
    else
      package_bundle_path() || code_bundle
    end
  end

  @spec manifest_bytes() :: {:ok, binary()} | {:error, term()}
  def manifest_bytes, do: load_bytes("manifest.json")

  @spec manifest() :: {:ok, json_object()} | {:error, term()}
  def manifest do
    with {:ok, contents} <- manifest_bytes(), do: decode_json(contents)
  end

  @spec matrix() :: {:ok, json_object()} | {:error, term()}
  def matrix, do: load_json("method-field-matrix.json")

  @spec schema(String.t()) :: {:ok, json_object()} | {:error, term()}
  def schema(relative_path) when is_binary(relative_path), do: load_json(relative_path)

  @spec compatibility_status() :: {:ok, json_object()} | {:error, term()}
  def compatibility_status do
    with {:ok, manifest} <- manifest(),
         compatibility when is_map(compatibility) <- Map.get(manifest, "compatibility") do
      {:ok, compatibility}
    else
      nil -> {:error, :missing_compatibility_status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_json(relative_path) do
    with {:ok, contents} <- load_bytes(relative_path), do: decode_json(contents)
  end

  defp load_bytes(relative_path) do
    with {:ok, path} <- safe_path(relative_path),
         {:ok, %File.Stat{type: :regular, size: size}}
         when is_integer(size) and size > 0 and size <= @max_json_bytes <- File.lstat(path),
         {:ok, contents} when byte_size(contents) == size <- File.read(path) do
      {:ok, contents}
    else
      {:ok, %File.Stat{}} -> {:error, :unsafe_schema_file}
      {:ok, _contents} -> {:error, :schema_file_changed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_json(contents) do
    case Jason.decode(contents) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _other} -> {:error, :expected_json_object}
      {:error, reason} -> {:error, reason}
    end
  end

  defp safe_path(relative_path) do
    bundle = bundle_path()
    expanded = Path.expand(relative_path, bundle)
    relative = Path.relative_to(expanded, bundle)

    cond do
      Path.type(relative_path) != :relative ->
        {:error, :absolute_schema_path}

      Path.type(relative) == :absolute or relative == ".." or String.starts_with?(relative, "../") ->
        {:error, :schema_path_escape}

      true ->
        {:ok, expanded}
    end
  end

  defp code_bundle_path do
    case :code.priv_dir(:symphony_elixir) do
      path when is_list(path) ->
        path
        |> IO.chardata_to_string()
        |> Path.join("codex_schema/#{@version}")

      _other ->
        Path.join(["priv", "codex_schema", @version])
    end
  end

  defp package_bundle_path do
    script =
      :escript.script_name()
      |> IO.chardata_to_string()
      |> Path.expand()

    bin_directory = Path.dirname(script)
    package_root = Path.dirname(bin_directory)
    candidate = Path.join(package_root, "priv/codex_schema/#{@version}")

    with "bin" <- Path.basename(bin_directory),
         {:ok, %File.Stat{type: :regular}} <- File.lstat(script),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(package_root),
         true <- safe_bundle_directory?(candidate) do
      candidate
    else
      _other -> nil
    end
  end

  defp safe_bundle_directory?(path) do
    with {:ok, canonical} <- PathSafety.canonicalize(path),
         true <- canonical == Path.expand(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      true
    else
      _other -> false
    end
  end
end
