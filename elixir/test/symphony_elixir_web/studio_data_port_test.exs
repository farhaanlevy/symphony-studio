defmodule SymphonyElixirWeb.StudioDataPortTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Event, EventSink, Identity}
  alias SymphonyElixir.EventSink.Memory
  alias SymphonyElixir.Studio.Intent.Store
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
    def get_intent_status("intent-errors", opts) do
      send(self(), {:static_intent_service_options, opts})
      {:ok, snapshot()}
    end

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

  test "projects contract and completion only from the admitted intent and complete structured proof" do
    root = Path.join(System.tmp_dir!(), "studio-data-port-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, store} = Store.open(root: root)
    run_id = Identity.uuid4()
    attempt_id = Identity.uuid4()

    intent = %{
      "schema_version" => 1,
      "intent_id" => "intent_authoritative_run",
      "source" => %{"content" => "Fallback source objective"},
      "proposal" => %{
        "tasks" => [
          %{
            "id" => "task-visible-change",
            "title" => "Expose the truthful Run Detail outcome",
            "acceptance_criteria" => ["Checks, review, and evidence are visible"],
            "source_refs" => ["elixir/lib/symphony_elixir_web/studio_data_port.ex"]
          }
        ]
      },
      "start" => %{
        "task_id" => "task-visible-change",
        "issue_id" => "issue-authoritative",
        "issue_identifier" => "SYM-99"
      },
      "admission" => %{"run_id" => run_id, "attempt_id" => attempt_id}
    }

    assert {:ok, ^intent, :created} = Store.create_intent(store, intent)

    sink = start_supervised!({Memory, []})
    target = {Memory, sink}

    events = [
      event(run_id, attempt_id, 1, "quality.check.completed", %{
        "check_id" => "targeted",
        "command" => "mix test test/symphony_elixir_web/studio_data_port_test.exs",
        "status" => "passed"
      }),
      event(run_id, attempt_id, 2, "review.completed", %{
        "status" => "passed",
        "detached" => true,
        "source_revision" => String.duplicate("a", 40)
      }),
      event(run_id, attempt_id, 3, "evidence.sealed", %{
        "manifest_hash" => "sha256:" <> String.duplicate("b", 64),
        "current" => true,
        "sealed" => true
      }),
      event(run_id, attempt_id, 4, "delivery.recorded", %{"commit" => String.duplicate("c", 40)}),
      event(run_id, attempt_id, 5, "tracker.handoff.confirmed", %{"status" => "confirmed"}),
      event(run_id, attempt_id, 6, "run.completed", %{"status" => "completed"})
    ]

    Enum.each(events, fn item -> assert {:ok, :appended} = EventSink.append(target, item) end)

    orchestrator = Module.concat(__MODULE__, :AuthoritativeOrchestrator)

    start_supervised!(
      {StaticOrchestrator,
       name: orchestrator,
       snapshot: %{
         running: [
           running_entry()
           |> Map.merge(%{
             issue_id: "issue-authoritative",
             identifier: "SYM-99",
             run_id: run_id,
             attempt_id: attempt_id
           })
         ],
         blocked: [],
         retrying: [],
         codex_totals: %{input_tokens: 21, output_tokens: 13, total_tokens: 34, seconds_running: 60},
         rate_limits: nil
       }}
    )

    configure_endpoint(
      orchestrator: orchestrator,
      snapshot_timeout_ms: 100,
      studio_intent_data_root: root,
      studio_event_sink: target
    )

    assert {:ok, page} = RuntimeStudioDataPort.load(:run_detail, %{"run_id" => run_id})
    assert page.run.objective == "Expose the truthful Run Detail outcome"
    assert page.acceptance_criteria == ["Checks, review, and evidence are visible"]
    assert page.checks |> List.first() |> Map.fetch!(:status) == :passed

    assert page.review == %{
             status: :passed,
             detached: true,
             findings: [],
             source_revision: String.duplicate("a", 40),
             completed_at: "2026-07-21T12:00:00.000Z"
           }

    assert page.outcome.status == :complete
    assert page.run.state == :completed
    assert page.run.phase == :outcome

    assert {:ok, probe} = RuntimeStudioDataPort.verification(%{"run_id" => run_id})
    assert probe.authoritative
    assert probe.source == "symphony_runtime"
    assert probe.project == %{slugId: "symphony-studio-build-week-3f2698765546", teamKey: "SYM"}
    assert probe.run.runId == run_id
    assert probe.run.checks.required == "passed"
    assert probe.run.review.status == :passed

    assert probe.run.evidence == %{
             current: true,
             reference: "sha256:" <> String.duplicate("b", 64),
             sealed: true
           }

    assert probe.run.completion.status == "completed"
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
    assert model.state == :fail
    assert model.value == "Configured workflow is not GPT-5.6 Sol Ultra"

    repository = Enum.find(page.rows, &(&1.system == "Repository"))
    assert repository.state == :fail
    assert repository.remediation =~ "Regenerate readiness evidence"
  end

  test "preserves canonical partial-publication and uncertain-start recovery receipts" do
    configure_endpoint(studio_intent_service: StaticIntentService)

    assert {:ok, page} = RuntimeStudioDataPort.load(:new_work, %{"intent" => "intent-errors"})
    assert_receive {:static_intent_service_options, opts}

    assert {SymphonyElixir.Studio.LinearWriteBroker.Linear, %SymphonyElixir.Studio.LinearWriteBroker.Linear{}} = Keyword.fetch!(opts, :broker)

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

  defp event(run_id, attempt_id, sequence, type, payload) do
    Event.new!(%{
      sequence: sequence,
      occurred_at: ~U[2026-07-21 12:00:00.000Z],
      issue_id: "issue-authoritative",
      issue_identifier: "SYM-99",
      run_id: run_id,
      attempt_id: attempt_id,
      thread_id: "thread-authoritative",
      turn_id: "turn-authoritative",
      type: type,
      severity: "info",
      payload: payload
    })
  end
end
