defmodule SymphonyElixir.Codex.CompatibilityCircuitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.CompatibilityCircuit

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-compatibility-circuit-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(root, "workspaces")
    manifest_path = Path.join(root, "manifest.json")
    File.mkdir_p!(root)
    write_manifest!(manifest_path, "not_run", 1)

    on_exit(fn -> File.rm_rf(root) end)

    opts = [manifest_path: manifest_path, schema_version: "0.144.3"]
    {:ok, workspace_root: workspace_root, manifest_path: manifest_path, opts: opts}
  end

  test "does not gate an untested identity when no circuit marker exists", context do
    assert CompatibilityCircuit.status(context.workspace_root, context.opts) == :clear
    refute File.exists?(CompatibilityCircuit.marker_path(context.workspace_root))
  end

  test "same identity stays open and marker contains only bounded identity fields", context do
    assert {:ok, marker} = CompatibilityCircuit.trip(context.workspace_root, context.opts)
    assert {:open, ^marker} = CompatibilityCircuit.status(context.workspace_root, context.opts)

    marker_path = CompatibilityCircuit.marker_path(context.workspace_root)
    assert {:ok, document} = marker_path |> File.read!() |> Jason.decode()

    assert MapSet.new(Map.keys(document)) ==
             MapSet.new([
               "markerVersion",
               "kind",
               "schemaVersion",
               "codexVersion",
               "compatibilityManifestSha256"
             ])

    assert document["markerVersion"] == 1
    assert document["kind"] == "app_server_protocol_failure"
    assert document["schemaVersion"] == "0.144.3"
    assert document["codexVersion"] == "0.144.3"
    assert document["compatibilityManifestSha256"] =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "changed identity remains blocked until its transport conformance is green", context do
    assert {:ok, marker} = CompatibilityCircuit.trip(context.workspace_root, context.opts)

    write_manifest!(context.manifest_path, "under_test", 2)
    assert {:open, ^marker} = CompatibilityCircuit.status(context.workspace_root, context.opts)

    write_manifest!(context.manifest_path, "pass", 3)
    assert CompatibilityCircuit.status(context.workspace_root, context.opts) == :cleared
    refute File.exists?(CompatibilityCircuit.marker_path(context.workspace_root))
  end

  test "same already-green manifest cannot clear the failure it observed", context do
    write_manifest!(context.manifest_path, "pass", 1)
    assert {:ok, marker} = CompatibilityCircuit.trip(context.workspace_root, context.opts)
    assert {:open, ^marker} = CompatibilityCircuit.status(context.workspace_root, context.opts)
  end

  test "malformed or symlink marker fails closed without reading target content", context do
    marker_path = CompatibilityCircuit.marker_path(context.workspace_root)
    File.mkdir_p!(Path.dirname(marker_path))
    File.write!(marker_path, "not-json")

    assert CompatibilityCircuit.status(context.workspace_root, context.opts) ==
             {:open, %{kind: :invalid_or_unreadable_marker}}

    File.rm!(marker_path)
    File.ln_s!(context.manifest_path, marker_path)

    assert CompatibilityCircuit.status(context.workspace_root, context.opts) ==
             {:open, %{kind: :invalid_or_unreadable_marker}}
  end

  test "identity mismatch cannot publish a marker", context do
    assert CompatibilityCircuit.trip(
             context.workspace_root,
             Keyword.put(context.opts, :schema_version, "different-version")
           ) == {:error, :identity_unavailable}

    refute File.exists?(CompatibilityCircuit.marker_path(context.workspace_root))
  end

  defp write_manifest!(path, transport_conformance, revision) do
    File.write!(
      path,
      Jason.encode!(%{
        "codex" => %{"version" => "0.144.3"},
        "compatibility" => %{"transportConformance" => transport_conformance},
        "testRevision" => revision
      })
    )
  end
end
