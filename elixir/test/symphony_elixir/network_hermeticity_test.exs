# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# R0-03 also covers deterministic startup without an interactive shell.

defmodule SymphonyElixir.NetworkHermeticityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, ErlexecRuntime, TestSupport, Tracker, Workflow, WorkflowStore}

  @network_hermetic_workflow_path Path.expand("../support/network_hermetic_workflow.md", __DIR__)
  @repo_workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @fixture_api_key "network-hermetic-test-token"
  @fixture_project_slug "network-hermetic-test-project"
  @fixture_assignee "network-hermetic-test-assignee"

  setup do
    previous_portexe = Application.fetch_env(:erlexec, :portexe)
    Application.delete_env(:erlexec, :portexe)

    on_exit(fn ->
      case previous_portexe do
        {:ok, value} -> Application.put_env(:erlexec, :portexe, value)
        :error -> Application.delete_env(:erlexec, :portexe)
      end
    end)

    :ok
  end

  test "MIX_ENV=test starts the application on the hermetic memory workflow" do
    assert Mix.env() == :test

    assert %{
             configured_workflow_path: @network_hermetic_workflow_path,
             repo_workflow_path: @repo_workflow_path,
             store_workflow_path: @network_hermetic_workflow_path,
             tracker_endpoint: "http://127.0.0.1:0/graphql",
             tracker_kind: "memory",
             tracker_fixture_values_pinned: true
           } = Application.fetch_env!(:symphony_elixir, :test_startup_network_guard)

    refute @network_hermetic_workflow_path == @repo_workflow_path
    assert Process.whereis(SymphonyElixir.Orchestrator)
    assert %{path: @network_hermetic_workflow_path} = :sys.get_state(WorkflowStore)
    assert Config.settings!().tracker.kind == "memory"
    assert Config.settings!().tracker.endpoint == "http://127.0.0.1:0/graphql"
    assert pinned_tracker_fixture_values?(Config.settings!())
    assert Tracker.adapter() == SymphonyElixir.Tracker.Memory
  end

  test "erlexec is included for packaging but starts only after Symphony prepares the environment" do
    applications = Application.spec(:symphony_elixir, :applications)
    included_applications = Application.spec(:symphony_elixir, :included_applications)

    refute :erlexec in applications
    assert :erlexec in included_applications
    assert Process.whereis(:exec_app)
    assert Process.whereis(:exec)

    assert {:erlexec, erlexec_supervisor, :supervisor, [:exec_app]} =
             Supervisor.which_children(SymphonyElixir.Supervisor)
             |> Enum.find(fn {id, _pid, _type, _modules} -> id == :erlexec end)

    assert erlexec_supervisor == Process.whereis(:exec_app)
  end

  test "erlexec startup supplies the fixed fallback for missing or blank SHELL" do
    previous_shell = System.get_env("SHELL")
    on_exit(fn -> restore_env("SHELL", previous_shell) end)

    for missing_or_blank <- [nil, "", "  \t"] do
      restore_env("SHELL", missing_or_blank)

      assert :ok = SymphonyElixir.Application.prepare_erlexec_environment()
      assert System.get_env("SHELL") == "/bin/sh"
    end
  end

  test "erlexec startup preserves an operator-provided nonblank SHELL" do
    previous_shell = System.get_env("SHELL")
    operator_shell = "/operator/provided-shell"
    on_exit(fn -> restore_env("SHELL", previous_shell) end)
    System.put_env("SHELL", operator_shell)

    assert :ok = SymphonyElixir.Application.prepare_erlexec_environment()
    assert System.get_env("SHELL") == operator_shell
  end

  test "escript extraction selects only the exact architecture entry in paths with spaces" do
    previous_shell = System.get_env("SHELL")
    on_exit(fn -> restore_env("SHELL", previous_shell) end)
    System.delete_env("SHELL")

    root = private_fixture_root!("archive path (safe)")
    on_exit(fn -> File.rm_rf(root) end)

    architecture = "fixture-arch"
    payload = "fixture-port-executable"
    script_path = Path.join(root, "Symphony fixture (safe path).escript")

    write_fixture_escript!(script_path, [
      {"erlexec/priv/#{architecture}/exec-port", payload},
      {"../../must-not-materialize", "hostile-entry"}
    ])

    assert {:ok, %ErlexecRuntime{} = runtime} =
             ErlexecRuntime.prepare(
               architecture: architecture,
               directory_suffixes: ["fixtureSafe123"],
               priv_dir: Path.join(root, "missing priv (archive mode)"),
               script_path: script_path,
               temporary_root: root
             )

    assert System.get_env("SHELL") == "/bin/sh"
    assert Application.get_env(:erlexec, :portexe) == runtime.executable
    assert File.read!(runtime.executable) == payload
    assert runtime.directory == Path.join(root, "symphony-erlexec-fixtureSafe123")
    refute File.exists?(Path.join(root, "must-not-materialize"))

    assert {:ok, %File.Stat{type: :directory, mode: directory_mode}} =
             File.lstat(runtime.directory)

    assert {:ok, %File.Stat{type: :regular, mode: executable_mode}} =
             File.lstat(runtime.executable)

    assert Bitwise.band(directory_mode, 0o777) == 0o700
    assert Bitwise.band(executable_mode, 0o777) == 0o700

    assert :ok = ErlexecRuntime.cleanup(runtime)
    refute File.exists?(runtime.executable)
    refute File.exists?(runtime.directory)
    assert Application.get_env(:erlexec, :portexe) == nil
  end

  test "escript extraction rejects traversal architecture and a traversal-only archive" do
    root = private_fixture_root!("hostile archive")
    on_exit(fn -> File.rm_rf(root) end)
    script_path = Path.join(root, "hostile (fixture).escript")
    write_fixture_escript!(script_path, [{"../../exec-port", "hostile-entry"}])

    assert {:error, :invalid_system_architecture} =
             ErlexecRuntime.prepare(
               architecture: "../escape",
               directory_suffixes: ["unusedSafe123"],
               priv_dir: Path.join(root, "missing-priv"),
               script_path: script_path,
               temporary_root: root
             )

    assert {:error, :embedded_port_executable_missing} =
             ErlexecRuntime.prepare(
               architecture: "fixture-arch",
               directory_suffixes: ["unusedSafe456"],
               priv_dir: Path.join(root, "missing-priv"),
               script_path: script_path,
               temporary_root: root
             )

    assert Path.wildcard(Path.join(root, "symphony-erlexec-*")) == []
    assert Application.get_env(:erlexec, :portexe) == nil
  end

  test "escript extraction never follows a pre-existing runtime-directory symlink" do
    root = private_fixture_root!("symlink collision")
    outside = private_fixture_root!("outside sentinel")
    on_exit(fn -> File.rm_rf(root) end)
    on_exit(fn -> File.rm_rf(outside) end)

    sentinel = Path.join(outside, "sentinel")
    File.write!(sentinel, "unchanged")

    suffix = "collisionSafe123"
    collision = Path.join(root, "symphony-erlexec-#{suffix}")
    File.ln_s!(outside, collision)

    architecture = "fixture-arch"
    script_path = Path.join(root, "valid-fixture.escript")

    write_fixture_escript!(script_path, [
      {"erlexec/priv/#{architecture}/exec-port", "fixture-port-executable"}
    ])

    assert {:error, :private_runtime_directory_unavailable} =
             ErlexecRuntime.prepare(
               architecture: architecture,
               directory_suffixes: [suffix],
               priv_dir: Path.join(root, "missing-priv"),
               script_path: script_path,
               temporary_root: root
             )

    assert File.read!(sentinel) == "unchanged"
    assert {:ok, %File.Stat{type: :symlink}} = File.lstat(collision)
    refute File.exists?(Path.join(outside, "exec-port"))
    assert Application.get_env(:erlexec, :portexe) == nil
  end

  test "hermetic workflow ignores ambient Linear credentials and routing" do
    previous_api_key = System.get_env("LINEAR_API_KEY")
    previous_assignee = System.get_env("LINEAR_ASSIGNEE")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_api_key)
      restore_env("LINEAR_ASSIGNEE", previous_assignee)
    end)

    System.put_env("LINEAR_API_KEY", "ambient-api-key-must-not-load")
    System.put_env("LINEAR_ASSIGNEE", "ambient-assignee-must-not-load")

    assert pinned_tracker_fixture_values?(Config.settings!())
    assert Tracker.adapter() == SymphonyElixir.Tracker.Memory
  end

  test "shared teardown restoration never falls back to the repository workflow" do
    temporary_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-hermetic-restore-#{System.unique_integer([:positive])}"
      )

    temporary_workflow = Path.join(temporary_root, "WORKFLOW.md")
    File.mkdir_p!(temporary_root)
    File.cp!(@network_hermetic_workflow_path, temporary_workflow)

    on_exit(fn ->
      TestSupport.restore_network_hermetic_workflow!()
      File.rm_rf(temporary_root)
    end)

    :ok = Workflow.set_workflow_file_path(temporary_workflow)
    assert Workflow.workflow_file_path() == temporary_workflow

    assert :ok = TestSupport.restore_network_hermetic_workflow!()
    assert Workflow.workflow_file_path() == @network_hermetic_workflow_path
    refute Workflow.workflow_file_path() == @repo_workflow_path
    assert %{path: @network_hermetic_workflow_path} = :sys.get_state(WorkflowStore)
    assert pinned_tracker_fixture_values?(Config.settings!())
    assert Tracker.adapter() == SymphonyElixir.Tracker.Memory
  end

  defp pinned_tracker_fixture_values?(settings) do
    settings.tracker.api_key == @fixture_api_key and
      settings.tracker.project_slug == @fixture_project_slug and
      settings.tracker.assignee == @fixture_assignee
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp private_fixture_root!(label) do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-erlexec-#{label}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  defp write_fixture_escript!(path, entries) do
    archive_entries =
      Enum.map(entries, fn {name, data} ->
        {String.to_charlist(name), data}
      end)

    :ok =
      :escript.create(String.to_charlist(path), [
        :shebang,
        {:archive, archive_entries, []}
      ])

    :ok
  end
end
