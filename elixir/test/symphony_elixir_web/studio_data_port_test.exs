defmodule SymphonyElixirWeb.StudioDataPortTest do
  use ExUnit.Case, async: false

  alias SymphonyElixirWeb.RuntimeStudioDataPort

  defmodule StaticOrchestrator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end
  end

  defmodule StaticIntentService do
    def get_intent_status("intent-errors", []), do: {:ok, snapshot()}

    defp snapshot do
      problem = %{"code" => "linear_timeout", "message" => "Linear confirmation timed out.", "resumable" => true}

      %{
        "schema_version" => "1",
        "intent_id" => "intent-errors",
        "lifecycle_state" => "publication_partial",
        "project" => %{"project_id" => "project-1", "root" => "/tmp/symphony-studio"},
        "source" => %{"kind" => "prompt"},
        "inspection" => nil,
        "clarifications" => %{"status" => "not_required", "questions" => [], "answers" => %{}},
        "proposal" => %{
          "version" => 1,
          "digest" => "sha256:proposal",
          "status" => "approved",
          "tasks" => []
        },
        "publication" => %{
          "status" => "partial",
          "proposal_digest" => "sha256:proposal",
          "tasks" => %{
            "task-1" => %{
              "idempotency_key" => "task-key",
              "status" => "uncertain",
              "provider" => "linear",
              "last_error" => problem
            }
          },
          "relations" => %{
            "relation-1" => %{
              "dependent_task_id" => "task-2",
              "prerequisite_task_id" => "task-1",
              "status" => "blocked",
              "last_error" => problem
            }
          },
          "last_error" => problem
        },
        "start" => %{
          "status" => "uncertain",
          "task_id" => "task-1",
          "provider" => "linear",
          "idempotency_key" => "start-key",
          "last_error" => problem
        },
        "admission" => nil,
        "events" => []
      }
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    end)

    :ok
  end

  test "preserves original running, blocked, retrying, and usage facts" do
    orchestrator = Module.concat(__MODULE__, :MissionOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator,
       snapshot: %{
         running: [running_entry()],
         blocked: [blocked_entry()],
         retrying: [retry_entry()],
         codex_totals: %{input_tokens: 21, output_tokens: 13, total_tokens: 34, seconds_running: 60},
         rate_limits: %{"limitId" => "reported-window"}
       }}
    )

    configure_endpoint(orchestrator: orchestrator, snapshot_timeout_ms: 100)

    assert {:ok, page} = RuntimeStudioDataPort.load(:mission_control, %{})
    assert page.counts == %{running: 1, blocked: 1, retrying: 1}
    assert page.usage == %{input_tokens: 21, output_tokens: 13, total_tokens: 34}
    assert page.rate_limits == %{"limitId" => "reported-window"}
    assert Enum.map(page.runs, & &1.state) == [:active, :blocked, :queued]

    active = Enum.find(page.runs, &(&1.state == :active))
    assert active.id == "run-1"
    assert active.issue_identifier == "STUDIO-1"
    assert active.issue_url == "https://linear.app/example/issue/STUDIO-1"
    assert active.latest_activity == "Conductor updated a file"
    assert active.usage.total_tokens == 34

    blocked = Enum.find(page.runs, &(&1.state == :blocked))
    assert blocked.blocker == "Approval required"

    queued = Enum.find(page.runs, &(&1.state == :queued))
    assert queued.next_action =~ "Symphony will retry"
  end

  test "rejects a non-http issue URL and marks missing completion proof incomplete" do
    orchestrator = Module.concat(__MODULE__, :RunOrchestrator)
    running = %{running_entry() | issue_url: "javascript:alert(1)"}

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator,
       snapshot: %{
         running: [running],
         blocked: [],
         retrying: [],
         codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
         rate_limits: nil
       }}
    )

    configure_endpoint(orchestrator: orchestrator, snapshot_timeout_ms: 100)

    assert {:ok, page} = RuntimeStudioDataPort.load(:run_detail, %{"run_id" => "run-1"})
    assert page.run.issue_url == nil
    assert page.run.phase_rail |> Enum.find(&(&1.key == :executing)) |> Map.fetch!(:status) == :active
    assert page.checks == []
    assert page.review.status == :not_run
    assert page.outcome.status == :incomplete
    assert page.outcome.reason =~ "does not include checks"
  end

  test "Setup reads the sealed readiness artifact and fails closed for changed source" do
    assert {:ok, page} = RuntimeStudioDataPort.load(:setup, %{})
    assert page.kind == :setup
    assert page.verdict == :not_ready
    assert page.reason =~ "different source revision"

    compatibility = Enum.find(page.rows, &(&1.system == "Compatibility"))
    assert compatibility.state == :pass
    assert compatibility.value == "0.144.3"

    model = Enum.find(page.rows, &(&1.system == "Runtime selection"))
    assert model.state == :pass
    assert model.value == "Ultra reasoning verified"

    repository = Enum.find(page.rows, &(&1.system == "Repository"))
    assert repository.state == :fail
    assert repository.remediation =~ "Regenerate readiness evidence"
  end

  test "preserves canonical partial-publication and uncertain-start recovery receipts" do
    configure_endpoint(studio_intent_service: StaticIntentService)

    assert {:ok, page} = RuntimeStudioDataPort.load(:new_work, %{"intent" => "intent-errors"})
    assert page.publication.status == "partial"

    assert [task] = page.publication.tasks
    assert task.idempotency_key == "task-key"

    assert task.last_error == %{
             code: "linear_timeout",
             details: %{},
             message: "Linear confirmation timed out.",
             resumable: true
           }

    assert [relation] = page.publication.relation_entries
    assert relation.prerequisite_task_id == "task-1"
    assert relation.dependent_task_id == "task-2"
    assert relation.last_error.resumable

    assert page.start.provider == "linear"
    assert page.start.idempotency_key == "start-key"
    assert page.start.last_error.code == "linear_timeout"
  end

  defp configure_endpoint(overrides) do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
  end

  defp running_entry do
    %{
      issue_id: "issue-1",
      identifier: "STUDIO-1",
      issue_url: "https://linear.app/example/issue/STUDIO-1",
      state: "In Progress",
      worker_host: nil,
      workspace_path: nil,
      run_id: "run-1",
      attempt_id: "attempt-1",
      session_id: "thread-1",
      turn_count: 2,
      last_event_id: "event-1",
      last_event_sequence: 3,
      last_event_type: "codex.notification",
      last_codex_event: :notification,
      last_codex_message: "Conductor updated a file",
      started_at: ~U[2026-07-21 12:00:00Z],
      last_codex_timestamp: ~U[2026-07-21 12:05:00Z],
      codex_input_tokens: 21,
      codex_output_tokens: 13,
      codex_total_tokens: 34
    }
  end

  defp blocked_entry do
    %{
      issue_id: "issue-2",
      identifier: "STUDIO-2",
      issue_url: nil,
      state: "Blocked",
      error: "Approval required",
      worker_host: nil,
      workspace_path: nil,
      run_id: "run-2",
      attempt_id: "attempt-2",
      session_id: "thread-2",
      blocked_at: ~U[2026-07-21 12:06:00Z],
      last_event_id: "event-2",
      last_event_sequence: 4,
      last_event_type: "codex.turn_blocked",
      last_codex_event: :turn_blocked,
      last_codex_message: "Waiting for approval",
      last_codex_timestamp: ~U[2026-07-21 12:06:00Z]
    }
  end

  defp retry_entry do
    %{
      issue_id: "issue-3",
      identifier: "STUDIO-3",
      issue_url: nil,
      attempt: 2,
      due_in_ms: 60_000,
      error: "Temporary transport failure",
      worker_host: nil,
      workspace_path: nil,
      run_id: "run-3",
      attempt_id: "attempt-3",
      last_event_id: "event-3",
      last_event_sequence: 2,
      last_event_type: "retry.scheduled"
    }
  end
end
