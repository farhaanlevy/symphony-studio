# Downstream modification notice (2026-07-14): Symphony Studio loads strict,
# deterministic protocol fixtures and proves network-hermetic application boot.
startup_workflow_path = Path.expand("support/network_hermetic_workflow.md", __DIR__)
repo_workflow_path = Path.expand("../WORKFLOW.md", __DIR__)
configured_workflow_path = Application.fetch_env!(:symphony_elixir, :workflow_file_path)
workflow_store_state = :sys.get_state(SymphonyElixir.WorkflowStore)
startup_settings = SymphonyElixir.Config.settings!()

tracker_fixture_values_pinned =
  startup_settings.tracker.api_key == "network-hermetic-test-token" and
    startup_settings.tracker.project_slug == "network-hermetic-test-project" and
    startup_settings.tracker.assignee == "network-hermetic-test-assignee"

unless configured_workflow_path == startup_workflow_path do
  raise "test application booted with unexpected workflow: #{configured_workflow_path}"
end

unless workflow_store_state.path == startup_workflow_path do
  raise "WorkflowStore booted with unexpected workflow: #{workflow_store_state.path}"
end

unless configured_workflow_path != repo_workflow_path and
         startup_settings.tracker.kind == "memory" and
         startup_settings.tracker.endpoint == "http://127.0.0.1:0/graphql" and
         tracker_fixture_values_pinned and
         SymphonyElixir.Tracker.adapter() == SymphonyElixir.Tracker.Memory do
  raise "test application startup is not network-hermetic"
end

Application.put_env(:symphony_elixir, :test_startup_network_guard, %{
  configured_workflow_path: configured_workflow_path,
  repo_workflow_path: repo_workflow_path,
  store_workflow_path: workflow_store_state.path,
  tracker_endpoint: startup_settings.tracker.endpoint,
  tracker_kind: startup_settings.tracker.kind,
  tracker_fixture_values_pinned: tracker_fixture_values_pinned
})

ExUnit.start()
Code.require_file("support/snapshot_support.exs", __DIR__)
Code.require_file("support/fake_codex_app_server.exs", __DIR__)
Code.require_file("support/fake_responses.exs", __DIR__)
Code.require_file("support/fake_linear.exs", __DIR__)
Code.require_file("support/test_support.exs", __DIR__)
