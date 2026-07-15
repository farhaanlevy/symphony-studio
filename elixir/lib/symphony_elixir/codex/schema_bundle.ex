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

  @type json_object :: %{optional(String.t()) => term()}

  @spec version() :: String.t()
  def version, do: @version

  @spec bundle_path() :: String.t()
  def bundle_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("codex_schema/#{@version}")
  end

  @spec manifest() :: {:ok, json_object()} | {:error, term()}
  def manifest, do: load_json("manifest.json")

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
    with {:ok, path} <- safe_path(relative_path),
         {:ok, contents} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(contents) do
      {:ok, value}
    else
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
end
