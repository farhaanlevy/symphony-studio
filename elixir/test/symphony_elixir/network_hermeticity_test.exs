# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.NetworkHermeticityTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Config, TestSupport, Tracker, Workflow, WorkflowStore}

  @network_hermetic_workflow_path Path.expand("../support/network_hermetic_workflow.md", __DIR__)
  @repo_workflow_path Path.expand("../../WORKFLOW.md", __DIR__)
  @fixture_api_key "network-hermetic-test-token"
  @fixture_project_slug "network-hermetic-test-project"
  @fixture_assignee "network-hermetic-test-assignee"

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
end
