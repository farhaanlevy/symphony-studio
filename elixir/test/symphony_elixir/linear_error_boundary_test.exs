# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.LinearErrorBoundaryTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  defmodule LeakingLinearClient do
    @moduledoc false

    def fetch_candidate_issues do
      Application.fetch_env!(:symphony_elixir, :linear_error_boundary_candidates)
    end

    def fetch_issues_by_states(_states) do
      Application.fetch_env!(:symphony_elixir, :linear_error_boundary_terminal)
    end

    def fetch_issue_states_by_ids(_issue_ids) do
      Application.fetch_env!(:symphony_elixir, :linear_error_boundary_refresh)
    end
  end

  test "orchestrator dispatch refresh blocked refresh retry and cleanup logs are content free" do
    previous_client = Application.get_env(:symphony_elixir, :linear_client_module)
    private_canary = "PRIVATE-LINEAR-ORCHESTRATOR-ERROR-CANARY"
    private_error = {:private_linear_error, %{"token" => private_canary}}
    orchestrator_name = Module.concat(__MODULE__, :ContentFreeOrchestrator)

    candidate = %Issue{
      id: "issue-candidate",
      identifier: "STUDIO-ERROR-BOUNDARY",
      title: "Exercise the tracker error boundary",
      state: "Todo"
    }

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "private-linear-api-key-canary",
      tracker_project_slug: "project",
      tracker_assignee: nil,
      poll_interval_ms: 60_000
    )

    Application.put_env(:symphony_elixir, :linear_client_module, LeakingLinearClient)
    Application.put_env(:symphony_elixir, :linear_error_boundary_candidates, {:ok, [candidate]})
    Application.put_env(:symphony_elixir, :linear_error_boundary_terminal, {:error, private_error})
    Application.put_env(:symphony_elixir, :linear_error_boundary_refresh, {:error, private_error})

    on_exit(fn ->
      restore_application_env(:linear_client_module, previous_client)
      Application.delete_env(:symphony_elixir, :linear_error_boundary_candidates)
      Application.delete_env(:symphony_elixir, :linear_error_boundary_terminal)
      Application.delete_env(:symphony_elixir, :linear_error_boundary_refresh)

      if Process.whereis(orchestrator_name) do
        GenServer.stop(orchestrator_name)
      end
    end)

    log =
      capture_log([level: :debug], fn ->
        assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)
        now = DateTime.utc_now()

        running_entry = %{
          identifier: "STUDIO-RUNNING",
          issue: %Issue{id: "issue-running", identifier: "STUDIO-RUNNING", state: "In Progress"},
          pid: self(),
          ref: nil,
          started_at: now
        }

        blocked_entry = %{
          identifier: "STUDIO-BLOCKED",
          issue: %Issue{id: "issue-blocked", identifier: "STUDIO-BLOCKED", state: "Todo"}
        }

        :sys.replace_state(pid, fn current ->
          %{
            current
            | blocked: %{"issue-blocked" => blocked_entry},
              claimed: MapSet.new(["issue-blocked", "issue-running"]),
              running: %{"issue-running" => running_entry}
          }
        end)

        send(pid, :run_poll_cycle)
        assert %Orchestrator.State{} = :sys.get_state(pid)

        Application.put_env(
          :symphony_elixir,
          :linear_error_boundary_candidates,
          {:error, private_error}
        )

        send(pid, :run_poll_cycle)
        assert %Orchestrator.State{} = :sys.get_state(pid)

        retry_token = make_ref()

        :sys.replace_state(pid, fn current ->
          retry_entry = %{
            attempt: 1,
            error: "bounded retry",
            identifier: "STUDIO-RETRY",
            retry_token: retry_token,
            timer_ref: nil
          }

          %{current | retry_attempts: %{"issue-retry" => retry_entry}}
        end)

        send(pid, {:retry_issue, "issue-retry", retry_token})
        assert %Orchestrator.State{} = :sys.get_state(pid)
        GenServer.stop(pid)
      end)

    assert log =~ "failure_kind=tracker_fetch_failed"
    assert log =~ "Failed to refresh running issue states failure_kind=tracker_refresh_failed"
    assert log =~ "Failed to refresh blocked issue states failure_kind=tracker_refresh_failed"
    assert log =~ "issue refresh failed"
    assert log =~ "failure_category=tracker_lookup_failed"
    refute log =~ private_canary
    refute log =~ "private_linear_error"
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:symphony_elixir, key)
  defp restore_application_env(key, value), do: Application.put_env(:symphony_elixir, key, value)
end
