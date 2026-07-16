# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.CompatibilityCircuit do
  @moduledoc """
  Persists the fail-closed App Server compatibility circuit for a pinned Codex
  identity.

  A protocol failure opens the circuit for the exact schema version and
  compatibility-manifest digest that observed it. The marker clears only when
  the manifest identity changes and the replacement manifest records green
  transport conformance. In the absence of a marker, development remains
  ungated even when a manifest is still under test.
  """

  alias SymphonyElixir.Codex.SchemaBundle
  alias SymphonyElixir.PathSafety

  @marker_version 1
  @marker_directory ".symphony-studio"
  @marker_file "app-server-compatibility-circuit-v1.json"
  @max_marker_bytes 4_096
  @required_marker_keys MapSet.new([
                          "codexVersion",
                          "compatibilityManifestSha256",
                          "kind",
                          "markerVersion",
                          "schemaVersion"
                        ])

  @type identity :: %{
          schema_version: String.t(),
          codex_version: String.t(),
          compatibility_manifest_sha256: String.t(),
          transport_conformance: String.t()
        }

  @type marker :: %{
          schema_version: String.t(),
          codex_version: String.t(),
          compatibility_manifest_sha256: String.t(),
          kind: :app_server_protocol_failure
        }

  @type status :: :clear | :cleared | {:open, marker() | %{kind: :invalid_or_unreadable_marker}}

  @doc "Returns the durable marker path beneath the configured workspace root."
  @spec marker_path(Path.t()) :: Path.t()
  def marker_path(workspace_root) when is_binary(workspace_root) do
    workspace_root
    |> Path.expand()
    |> Path.join(@marker_directory)
    |> Path.join(@marker_file)
  end

  @doc "Reads and reconciles the compatibility circuit for the current identity."
  @spec status(Path.t(), keyword()) :: status()
  def status(workspace_root, opts \\ []) when is_binary(workspace_root) and is_list(opts) do
    path = marker_path(workspace_root)

    case read_marker(path) do
      :missing ->
        :clear

      {:ok, marker} ->
        reconcile_marker(path, marker, opts)

      {:error, _category} ->
        {:open, %{kind: :invalid_or_unreadable_marker}}
    end
  end

  @doc "Opens the compatibility circuit for the current pinned identity."
  @spec trip(Path.t(), keyword()) :: {:ok, marker()} | {:error, atom()}
  def trip(workspace_root, opts \\ []) when is_binary(workspace_root) and is_list(opts) do
    with {:ok, identity} <- current_identity(opts),
         marker <- marker_from_identity(identity),
         :ok <- publish_marker(marker_path(workspace_root), marker) do
      {:ok, marker}
    end
  end

  @doc "Returns the schema and compatibility-manifest identity used by the circuit."
  @spec current_identity(keyword()) :: {:ok, identity()} | {:error, atom()}
  def current_identity(opts \\ []) when is_list(opts) do
    manifest_path = Keyword.get(opts, :manifest_path, default_manifest_path())
    schema_version = Keyword.get(opts, :schema_version, SchemaBundle.version())

    with true <- is_binary(manifest_path) and manifest_path != "",
         true <- is_binary(schema_version) and schema_version != "",
         {:ok, manifest_bytes} <- File.read(manifest_path),
         {:ok, manifest} when is_map(manifest) <- Jason.decode(manifest_bytes),
         codex_version when is_binary(codex_version) and codex_version != "" <-
           get_in(manifest, ["codex", "version"]),
         ^schema_version <- codex_version,
         transport when is_binary(transport) <-
           get_in(manifest, ["compatibility", "transportConformance"]) do
      {:ok,
       %{
         schema_version: schema_version,
         codex_version: codex_version,
         compatibility_manifest_sha256: sha256(manifest_bytes),
         transport_conformance: transport
       }}
    else
      _other -> {:error, :identity_unavailable}
    end
  end

  defp default_manifest_path do
    Path.join(SchemaBundle.bundle_path(), "manifest.json")
  end

  defp marker_from_identity(identity) do
    %{
      schema_version: identity.schema_version,
      codex_version: identity.codex_version,
      compatibility_manifest_sha256: identity.compatibility_manifest_sha256,
      kind: :app_server_protocol_failure
    }
  end

  defp reconcile_marker(path, marker, opts) do
    case current_identity(opts) do
      {:ok, identity} ->
        reconcile_current_identity(path, marker, identity)

      {:error, _category} ->
        {:open, marker}
    end
  end

  defp reconcile_current_identity(path, marker, %{transport_conformance: "pass"} = identity) do
    if identity_changed?(marker, identity) do
      remove_cleared_marker(path, marker)
    else
      {:open, marker}
    end
  end

  defp reconcile_current_identity(_path, marker, _identity), do: {:open, marker}

  defp remove_cleared_marker(path, marker) do
    case remove_marker(path) do
      :ok -> :cleared
      {:error, _category} -> {:open, marker}
    end
  end

  defp identity_changed?(marker, identity) do
    marker.schema_version != identity.schema_version or
      marker.codex_version != identity.codex_version or
      marker.compatibility_manifest_sha256 != identity.compatibility_manifest_sha256
  end

  defp read_marker(path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :missing

      {:ok, %File.Stat{type: :regular, size: size}}
      when is_integer(size) and size > 0 and size <= @max_marker_bytes ->
        with {:ok, contents} <- File.read(path),
             true <- byte_size(contents) <= @max_marker_bytes,
             {:ok, document} when is_map(document) <- Jason.decode(contents),
             {:ok, marker} <- decode_marker(document) do
          {:ok, marker}
        else
          _other -> {:error, :invalid_marker}
        end

      {:ok, _stat} ->
        {:error, :invalid_marker}

      {:error, _reason} ->
        {:error, :marker_unreadable}
    end
  end

  defp decode_marker(document) do
    with true <- MapSet.equal?(MapSet.new(Map.keys(document)), @required_marker_keys),
         @marker_version <- document["markerVersion"],
         "app_server_protocol_failure" <- document["kind"],
         schema_version when is_binary(schema_version) and schema_version != "" <-
           document["schemaVersion"],
         codex_version when is_binary(codex_version) and codex_version != "" <-
           document["codexVersion"],
         digest when is_binary(digest) <- document["compatibilityManifestSha256"],
         true <- valid_sha256?(digest) do
      {:ok,
       %{
         schema_version: schema_version,
         codex_version: codex_version,
         compatibility_manifest_sha256: digest,
         kind: :app_server_protocol_failure
       }}
    else
      _other -> {:error, :invalid_marker}
    end
  end

  defp publish_marker(path, marker) do
    directory = Path.dirname(path)

    with :ok <- ensure_safe_directory(directory),
         :ok <- ensure_regular_or_missing(path),
         {:ok, encoded} <- encode_marker(marker),
         :ok <- atomic_write(path, encoded) do
      ensure_regular_or_missing(path)
    end
  end

  defp ensure_safe_directory(directory) do
    with {:ok, canonical} <- PathSafety.canonicalize(directory),
         true <- canonical == Path.expand(directory),
         :ok <- mkdir_p(directory),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(directory) do
      :ok
    else
      _other -> {:error, :unsafe_marker_directory}
    end
  end

  defp mkdir_p(directory) do
    case File.mkdir_p(directory) do
      :ok -> :ok
      {:error, _reason} -> {:error, :marker_directory_unavailable}
    end
  end

  defp ensure_regular_or_missing(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:error, :enoent} -> :ok
      _other -> {:error, :unsafe_marker_path}
    end
  end

  defp encode_marker(marker) do
    Jason.encode(%{
      "markerVersion" => @marker_version,
      "kind" => "app_server_protocol_failure",
      "schemaVersion" => marker.schema_version,
      "codexVersion" => marker.codex_version,
      "compatibilityManifestSha256" => marker.compatibility_manifest_sha256
    })
  end

  defp atomic_write(path, contents) do
    temporary = path <> ".tmp-#{System.unique_integer([:positive, :monotonic])}"

    result =
      with :ok <- File.write(temporary, contents, [:write, :binary, :exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- ensure_regular_or_missing(path),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        _other -> {:error, :marker_publish_failed}
      end

    if result != :ok do
      File.rm(temporary)
    end

    result
  end

  defp remove_marker(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        case File.rm(path) do
          :ok -> :ok
          {:error, _reason} -> {:error, :marker_remove_failed}
        end

      {:error, :enoent} ->
        :ok

      _other ->
        {:error, :unsafe_marker_path}
    end
  end

  defp valid_sha256?(value) when byte_size(value) == 64 do
    String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_sha256?(_value), do: false

  defp sha256(contents) do
    :sha256
    |> :crypto.hash(contents)
    |> Base.encode16(case: :lower)
  end
end
