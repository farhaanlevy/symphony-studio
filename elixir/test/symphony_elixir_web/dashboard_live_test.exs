defmodule SymphonyElixirWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule TestDataPort do
    @behaviour SymphonyElixirWeb.StudioDataPort

    @spec external_write_actions_enabled?() :: boolean()
    def external_write_actions_enabled? do
      Application.get_env(:symphony_elixir, :studio_web_test_write_actions_enabled, true)
    end

    @impl true
    def load(:mission_control, _params), do: {:ok, mission_page()}
    def load(:setup, _params), do: {:ok, setup_page()}

    def load(:new_work, %{"intent" => "intent-publication-recovery"}) do
      {:ok, proposal_page("approved") |> Map.put(:intent_id, "intent-publication-recovery")}
    end

    def load(:new_work, %{"intent" => "intent-proposed"}), do: {:ok, proposal_page("proposed")}
    def load(:new_work, %{"intent" => "intent-publication-blocked"}), do: {:ok, publication_recovery_page("blocked")}
    def load(:new_work, %{"intent" => "intent-publication-partial"}), do: {:ok, publication_recovery_page("partial")}
    def load(:new_work, %{"intent" => "intent-publication-uncertain"}), do: {:ok, publication_recovery_page("uncertain")}
    def load(:new_work, %{"intent" => "intent-start-blocked"}), do: {:ok, start_recovery_page("blocked")}
    def load(:new_work, %{"intent" => "intent-start-uncertain"}), do: {:ok, start_recovery_page("uncertain")}
    def load(:new_work, %{"intent" => _intent_id}), do: {:ok, proposal_page("presented")}
    def load(:new_work, _params), do: {:ok, empty_intent_page()}
    def load(:run_detail, _params), do: {:ok, run_page()}

    @impl true
    def command(command, payload, context) do
      if test_pid = Application.get_env(:symphony_elixir, :studio_web_test_pid) do
        send(test_pid, {:studio_command, command, payload, context})
      end

      command_result(command, payload, context)
    end

    defp command_result(command, _payload, _context)
         when command in [:submit_intent, :answer_clarifications, :use_recommended_defaults, :present_proposal],
         do: {:ok, proposal_page("presented")}

    defp command_result(:approve_publication, _payload, _context), do: {:ok, proposal_page("approved")}

    defp command_result(
           :publish_approved_plan,
           %{"attempt" => "initial"},
           %{intent_id: "intent-publication-recovery"}
         ),
         do: {:ok, publication_recovery_page("blocked")}

    defp command_result(:publish_approved_plan, _payload, _context), do: {:ok, published_page()}
    defp command_result(:start_first_ready, _payload, _context), do: {:ok, waiting_page()}

    defp command_result(_command, _payload, _context),
      do: {:error, %{code: "unsupported", message: "Unsupported", details: %{}}}

    defp mission_page do
      run = run_summary()

      %{
        kind: :mission_control,
        source: :runtime_projection,
        generated_at: "2026-07-21T12:30:00Z",
        freshness: :current,
        counts: %{running: 1, retrying: 1, blocked: 0},
        runs: [run, %{run | id: "run-queued", issue_identifier: "STUDIO-202", state: :queued, state_label: "Queued"}],
        active_run: run,
        usage: %{input_tokens: 1_200, output_tokens: 300, total_tokens: 1_500},
        rate_limits: %{"window" => "reported"},
        error: nil
      }
    end

    defp run_summary do
      %{
        id: "run-active",
        issue_identifier: "STUDIO-201",
        issue_url: "https://linear.app/example/issue/STUDIO-201",
        objective: "Make runtime truth legible without exposing raw model transcripts",
        state: :active,
        state_label: "Active",
        phase: :executing,
        phase_label: "Executing",
        conductor: "GPT-5.6 Sol Ultra",
        started_at: "2026-07-21T12:00:00Z",
        due_at: nil,
        elapsed_label: "30m",
        latest_activity: "Conductor updated the LiveView presentation layer",
        latest_activity_at: "2026-07-21T12:29:30Z",
        usage: %{input_tokens: 1_200, output_tokens: 300, total_tokens: 1_500},
        blocker: nil,
        next_action: "Inspect current activity and evidence.",
        check_summary: "3 passed · 1 running",
        review_summary: "Independent review pending",
        session_id: "thread-redacted-201",
        attempt: 1,
        raw_state: "In Progress"
      }
    end

    defp setup_page do
      %{
        kind: :setup,
        verdict: :ready,
        verdict_label: "Ready",
        reason: "Repository, Linear, Codex, and runtime evidence match this checkout.",
        checked_at: "2026-07-21T12:20:00Z",
        source_revision: "1234567890abcdef1234567890abcdef12345678",
        current_revision: "1234567890abcdef1234567890abcdef12345678",
        rows: [
          %{
            system: "Repository",
            state: :pass,
            state_label: "Pass",
            label: "Symphony Studio",
            value: "1234567890ab",
            checked_at: "2026-07-21T12:20:00Z",
            remediation: "No action needed.",
            evidence: %{}
          },
          %{
            system: "Runtime selection",
            state: :pass,
            state_label: "Pass",
            label: "GPT-5.6 Sol",
            value: "Ultra reasoning verified",
            checked_at: "2026-07-21T12:20:00Z",
            remediation: "No action needed.",
            evidence: %{}
          }
        ]
      }
    end

    defp empty_intent_page do
      %{
        kind: :new_work,
        service: :available,
        schema_version: nil,
        intent_id: nil,
        lifecycle_state: "new",
        project: %{project_id: nil, label: "Symphony Studio"},
        inspection: nil,
        clarifications: %{status: "not_required", questions: [], answers: %{}},
        proposal: nil,
        publication: %{status: "not_started", tasks: [], last_error: nil},
        start: %{status: "not_started", confirmation: nil},
        admission: nil,
        events: []
      }
    end

    defp proposal_page(status) do
      %{
        kind: :new_work,
        service: :available,
        schema_version: 1,
        intent_id: "intent-201",
        lifecycle_state: if(status == "approved", do: "approved", else: "presented"),
        project: %{project_id: "project-201", label: "Symphony Studio"},
        inspection: %{
          digest: "inspection-1234567890abcdef",
          file_count: 214,
          test_file_count: 52,
          architecture_paths: ["docs/architecture/fork-policy.md"],
          spec_paths: ["STUDIO_SPEC.md"],
          headings: []
        },
        clarifications: %{status: "not_required", questions: [], answers: %{}},
        proposal: %{
          version: 1,
          digest: "proposal-1234567890abcdef",
          status: status,
          tasks: [
            %{
              id: "task-1",
              position: 1,
              title: "Add the authoritative projection",
              description: "Project structured runtime events into the Studio web contract.",
              acceptance_criteria: ["Older events cannot replace newer run state"],
              depends_on: [],
              source_refs: ["STUDIO_SPEC.md"]
            },
            %{
              id: "task-2",
              position: 2,
              title: "Render the operational workbench",
              description: "Show state, next action, checks, review, and evidence.",
              acceptance_criteria: ["Mobile prioritizes current state and next action"],
              depends_on: ["task-1"],
              source_refs: ["planning/ui-design-brief.md"]
            },
            %{
              id: "task-3",
              position: 3,
              title: "Verify the complete flow",
              description: "Exercise proposal, publication, admission, and run evidence.",
              acceptance_criteria: ["No duplicate external mutation occurs"],
              depends_on: ["task-2"],
              source_refs: []
            }
          ]
        },
        publication: %{status: "not_started", proposal_digest: nil, tasks: [], relations: 0, last_error: nil},
        start: %{status: "not_started", task_id: nil, issue_id: nil, issue_identifier: nil, confirmation: nil},
        admission: nil,
        events: []
      }
    end

    defp published_page do
      page = proposal_page("approved")

      %{
        page
        | lifecycle_state: "published",
          publication: %{
            status: "complete",
            proposal_digest: page.proposal.digest,
            tasks: [
              %{task_id: "task-1", status: "confirmed", issue_id: "issue-1", issue_identifier: "STUDIO-301", provider: "linear"},
              %{task_id: "task-2", status: "confirmed", issue_id: "issue-2", issue_identifier: "STUDIO-302", provider: "linear"},
              %{task_id: "task-3", status: "confirmed", issue_id: "issue-3", issue_identifier: "STUDIO-303", provider: "linear"}
            ],
            relations: 2,
            last_error: nil
          }
      }
    end

    defp waiting_page do
      page = published_page()

      %{
        page
        | lifecycle_state: "waiting_for_admission",
          start: %{
            status: "waiting_for_admission",
            task_id: "task-1",
            issue_id: "issue-1",
            issue_identifier: "STUDIO-301",
            confirmation: "Todo transition confirmed"
          }
      }
    end

    defp publication_recovery_page(status) do
      page = proposal_page("approved")
      tasks = published_page().publication.tasks

      tasks =
        case status do
          "partial" -> [List.first(tasks) | Enum.map(Enum.drop(tasks, 1), &%{&1 | status: "blocked"})]
          _other -> Enum.map(tasks, &%{&1 | status: status, issue_id: nil, issue_identifier: nil})
        end

      error = %{code: "linear_write_broker_failed", message: "Linear did not confirm the operation.", resumable: true}
      event_type = if(status == "uncertain", do: "publication.uncertain", else: "publication.blocked")

      %{
        page
        | intent_id: "intent-publication-#{status}",
          lifecycle_state: "publication_#{status}",
          publication: %{
            status: status,
            proposal_digest: page.proposal.digest,
            tasks: tasks,
            relations: 0,
            relation_entries: [],
            last_error: error
          },
          events: [%{event_id: "event-#{status}-7", sequence: 7, type: event_type}]
      }
    end

    defp start_recovery_page(status) do
      page = published_page()
      error = %{code: "linear_write_broker_failed", message: "Todo transition was not confirmed.", resumable: true}

      %{
        page
        | intent_id: "intent-start-#{status}",
          lifecycle_state: "start_#{status}",
          start: %{
            status: status,
            task_id: "task-1",
            issue_id: "issue-1",
            issue_identifier: "STUDIO-301",
            confirmation: "start_first_ready",
            last_error: error
          },
          events: [%{event_id: "event-start-#{status}-9", sequence: 9, type: "start.#{status}"}]
      }
    end

    defp run_page do
      run =
        run_summary()
        |> Map.put(:state, :incomplete)
        |> Map.put(:state_label, "Incomplete")
        |> Map.put(:phase, :outcome)
        |> Map.put(:phase_label, "Outcome")
        |> Map.put(:phase_rail, [
          %{key: :admitted, label: "Admitted", status: :passed},
          %{key: :workspace, label: "Workspace", status: :passed},
          %{key: :executing, label: "Executing", status: :passed},
          %{key: :validating, label: "Validating", status: :failed},
          %{key: :reviewing, label: "Reviewing", status: :not_run},
          %{key: :outcome, label: "Outcome", status: :failed}
        ])

      %{
        kind: :run_detail,
        source: :runtime_projection,
        generated_at: "2026-07-21T12:30:00Z",
        freshness: :current,
        run: run,
        acceptance_criteria: ["No stale event can overwrite terminal state"],
        scope: [],
        plan: [
          %{label: "Project runtime events", status: :completed},
          %{label: "Run deterministic checks", status: :blocked}
        ],
        activity: [
          %{
            phase: :validating,
            label: "Tests failed: 1 failure",
            summary: "Focus return assertion failed",
            occurred_at: "2026-07-21T12:29:00Z",
            result: :failed,
            effect: :read
          }
        ],
        changes: [
          %{path: "elixir/lib/symphony_elixir_web/live/dashboard_live.ex", summary: "Added run evidence view", status: :changed}
        ],
        checks: [
          %{
            status: :failed,
            command: "mix test test/symphony_elixir_web/dashboard_live_test.exs",
            summary: "1 failure",
            completed_at: "2026-07-21T12:29:00Z"
          }
        ],
        review: %{status: :not_run, findings: [], source_revision: nil, completed_at: nil},
        evidence: [],
        outcome: %{status: :incomplete, reason: "A deterministic check failed and independent review did not run."}
      }
    end
  end

  setup do
    endpoint_config = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])
    Application.put_env(:symphony_elixir, :studio_web_test_pid, self())
    Application.put_env(:symphony_elixir, :studio_web_test_write_actions_enabled, true)

    config =
      endpoint_config
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:studio_data_port, TestDataPort)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
      Application.delete_env(:symphony_elixir, :studio_web_test_pid)
      Application.delete_env(:symphony_elixir, :studio_web_test_write_actions_enabled)
    end)

    :ok
  end

  test "Mission Control leads with the active operational object and genuine usage" do
    {:ok, _view, html} = live(build_conn(), "/mission-control")

    assert html =~ "Mission Control"
    assert html =~ "STUDIO-201"
    assert html =~ "GPT-5.6 Sol Ultra"
    assert html =~ "Conductor updated the LiveView presentation layer"
    assert html =~ "Tokens used"
    assert html =~ "1,500"
    assert html =~ "View run"
    assert html =~ ~s(aria-label="Open STUDIO-201 in the issue tracker")
    assert html =~ ~s(data-testid="connection-state")
    assert html =~ ~s(data-testid="mission-run")
    refute html =~ "hero-card"
    refute html =~ "% complete"
  end

  test "Setup renders exact compatibility and readiness truth" do
    {:ok, _view, html} = live(build_conn(), "/setup")

    assert html =~ "Golden-path readiness"
    assert html =~ "Ready"
    assert html =~ "GPT-5.6 Sol"
    assert html =~ "Ultra reasoning verified"
    assert html =~ "Credentials stay private"
    assert html =~ "R0 foundation evidence"
    assert html =~ ~s(data-testid="setup-readiness")
    assert html =~ ~s(data-testid="setup-repository")
    assert html =~ ~s(data-testid="setup-model-policy")
    refute html =~ "API key"
  end

  test "New Work binds approval to the presented digest and keeps publication separate" do
    {:ok, view, html} = live(build_conn(), "/work/new?intent=intent-201")

    assert html =~ "No Linear mutation has occurred."
    assert html =~ "Approve Backlog publication"
    assert html =~ "3 proposed tasks"
    assert html =~ ~s(data-testid="proposal-side-effects")
    assert html =~ ~s(data-testid="proposal-task")

    html =
      view
      |> form("form[phx-submit='approve_publication']", %{"proposal_digest" => "proposal-1234567890abcdef"})
      |> render_submit()

    assert html =~ "Proposal-bound approval recorded"
    assert html =~ "Publish approved tasks"

    assert_received {:studio_command, :approve_publication, %{"proposal_digest" => "proposal-1234567890abcdef"}, context}
    assert context.intent_id == "intent-201"
    assert context.command_id =~ "studio-web-"
  end

  test "write-disabled capability keeps planning usable and suppresses every external-action control" do
    Application.put_env(:symphony_elixir, :studio_web_test_write_actions_enabled, false)

    {:ok, planning_view, planning_html} = live(build_conn(), "/work/new?intent=intent-proposed")
    assert planning_html =~ "Review final proposal"

    presented_html = render_click(planning_view, "present_proposal")
    assert presented_html =~ "external_write_broker_required"
    assert presented_html =~ "Planning and proposal review remain read-only."
    refute presented_html =~ "Approve Backlog publication"
    assert_received {:studio_command, :present_proposal, %{}, _context}

    {:ok, _publication_view, publication_html} =
      live(build_conn(), "/work/new?intent=intent-publication-blocked")

    assert publication_html =~ "Linear publication and start are unavailable in this candidate."
    assert publication_html =~ "external_write_broker_required"
    assert publication_html =~ "Refresh stored state"
    refute publication_html =~ "Publish approved tasks"
    refute publication_html =~ "Resume publication safely"

    {:ok, _start_view, start_html} = live(build_conn(), "/work/new?intent=intent-start-blocked")
    assert start_html =~ "external_write_broker_required"
    refute start_html =~ "Start first ready task"
    refute start_html =~ "Resume Todo transition safely"
  end

  test "publication confirmation reveals a separate Start action and waiting is not admission" do
    {:ok, view, _html} = live(build_conn(), "/work/new?intent=intent-201")

    render_submit(view, "approve_publication", %{"proposal_digest" => "proposal-1234567890abcdef"})
    html = render_click(view, "publish_approved_plan")

    assert html =~ "Backlog publication confirmed"
    assert html =~ "Start first ready task"

    html = render_click(view, "start_first_ready")
    assert html =~ "Waiting for Symphony admission"
    assert html =~ "no Symphony admission event has been observed"
    refute html =~ "Open admitted run"
  end

  test "blocked publication exposes an explicit resume and sends a fresh durable command ID" do
    {:ok, view, _html} = live(build_conn(), "/work/new?intent=intent-publication-recovery")

    blocked_html = render_click(view, "publish_approved_plan")

    assert blocked_html =~ "Publication blocked"
    assert blocked_html =~ "Resume publication safely"
    assert blocked_html =~ "Refresh stored state"
    refute blocked_html =~ "Reconcile now"

    assert_received {:studio_command, :publish_approved_plan, %{"attempt" => "initial"}, initial_context}

    complete_html = render_click(view, "resume_publication")

    assert complete_html =~ "Backlog publication confirmed"
    assert_received {:studio_command, :publish_approved_plan, %{"attempt" => "resume"}, resume_context}
    assert initial_context.command_id != resume_context.command_id
    assert resume_context.intent_id == "intent-publication-blocked"
  end

  test "publication recovery command is stable across reload of the same durable receipt" do
    {:ok, first_view, first_html} = live(build_conn(), "/work/new?intent=intent-publication-blocked")
    assert first_html =~ "Resume publication safely"
    _html = render_click(first_view, "resume_publication")
    assert_received {:studio_command, :publish_approved_plan, %{"attempt" => "resume"}, first_context}

    {:ok, second_view, second_html} = live(build_conn(), "/work/new?intent=intent-publication-blocked")
    assert second_html =~ "Resume publication safely"
    _html = render_click(second_view, "resume_publication")
    assert_received {:studio_command, :publish_approved_plan, %{"attempt" => "resume"}, second_context}

    assert first_context.command_id == second_context.command_id
  end

  test "partial and uncertain publication states offer reconciliation-backed resume, not refresh-as-reconcile" do
    for status <- ["partial", "uncertain"] do
      {:ok, _view, html} = live(build_conn(), "/work/new?intent=intent-publication-#{status}")

      assert html =~ "Resume publication safely"
      assert html =~ "reconciles every unresolved idempotency key before any write"
      assert html =~ "Refresh stored state"
      refute html =~ "Reconcile now"
    end
  end

  test "blocked and uncertain starts expose a real resume action with the selected issue" do
    for status <- ["blocked", "uncertain"] do
      {:ok, view, html} = live(build_conn(), "/work/new?intent=intent-start-#{status}")

      assert html =~ "Resume Todo transition safely"
      assert html =~ "STUDIO-301"

      waiting_html = render_click(view, "resume_start")
      assert waiting_html =~ "Waiting for Symphony admission"

      assert_received {:studio_command, :start_first_ready, %{"attempt" => "resume"}, context}
      assert context.intent_id == "intent-start-#{status}"
    end
  end

  test "Run Detail puts an incomplete outcome before historical activity in the DOM" do
    {:ok, _view, html} = live(build_conn(), "/runs/run-active")

    assert html =~ "A deterministic check failed and independent review did not run."
    assert html =~ "Tests failed: 1 failure"
    assert html =~ "Independent review"
    assert html =~ "Not run"

    for test_id <- [
          "run-objective",
          "run-next-action",
          "run-truth-state",
          "run-acceptance",
          "run-plan",
          "run-phase",
          "run-commands",
          "run-changed-files",
          "run-checks",
          "run-independent-review",
          "run-evidence",
          "run-outcome",
          "run-completion-reason"
        ] do
      assert html =~ ~s(data-testid="#{test_id}")
    end

    {outcome_index, _} = :binary.match(html, "Evidence and outcome")
    {activity_index, _} = :binary.match(html, "Meaningful events")
    assert outcome_index < activity_index
  end

  test "intent validation is labeled and blocks an empty request" do
    {:ok, view, _html} = live(build_conn(), "/work/new")

    html = render_submit(view, "submit_intent", %{"intent" => %{"kind" => "prompt", "content" => ""}})
    assert html =~ "Enter a work request before inspection."
    refute_received {:studio_command, :submit_intent, _, _}
  end
end
