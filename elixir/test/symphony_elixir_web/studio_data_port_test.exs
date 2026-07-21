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

  defmodule WriteTrapIntentService do
    def approve_publication(_intent_id, _digest, _confirmation, _command_id, _opts) do
      send(self(), {:production_write_callback, :approve_publication})
      {:ok, %{}}
    end

    def publish_approved_plan(_intent_id, _command_id, _opts) do
      send(self(), {:production_write_callback, :publish_approved_plan})
      {:ok, %{}}
    end

    def start_first_ready(_intent_id, _confirmation, _command_id, _opts) do
      send(self(), {:production_write_callback, :start_first_ready})
      {:ok, %{}}
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
    revision = String.duplicate("c", 40)

    intent = %{
      "schema_version" => 1,
      "intent_id" => "intent_authoritative_run",
      "source" => %{"content" => "Fallback source objective"},
      "lifecycle_state" => "admitted",
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
      "publication" => %{
        "status" => "complete",
        "tasks" => %{
          "task-visible-change" => %{
            "issue_id" => "issue-authoritative",
            "issue_identifier" => "SYM-99",
            "status" => "confirmed"
          }
        }
      },
      "admission" => %{"run_id" => run_id, "attempt_id" => attempt_id}
    }

    assert {:ok, ^intent, :created} = Store.create_intent(store, intent)

    sink = start_supervised!({Memory, []})
    target = {Memory, sink}

    events = [
      event(run_id, attempt_id, 1, "codex.session.started", %{
        "model" => "gpt-5.6-sol",
        "reasoning_effort" => "ultra"
      }),
      event(run_id, attempt_id, 2, "quality.check.completed", %{
        "check_id" => "targeted",
        "command" => "mix test test/symphony_elixir_web/studio_data_port_test.exs",
        "status" => "passed",
        "source_revision" => revision
      }),
      event(run_id, attempt_id, 3, "review.completed", %{
        "status" => "passed",
        "detached" => true,
        "source_revision" => revision
      }),
      event(run_id, attempt_id, 4, "evidence.sealed", %{
        "manifest_hash" => "sha256:" <> String.duplicate("b", 64),
        "current" => true,
        "sealed" => true,
        "status" => "sealed",
        "source_revision" => revision
      }),
      event(run_id, attempt_id, 5, "delivery.recorded", %{
        "commit" => revision,
        "source_revision" => revision,
        "status" => "recorded"
      }),
      event(run_id, attempt_id, 6, "tracker.handoff.confirmed", %{
        "status" => "confirmed",
        "source_revision" => revision
      }),
      event(run_id, attempt_id, 7, "run.completed", %{
        "status" => "completed",
        "source_revision" => revision
      })
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
             source_revision: revision,
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
    assert probe.run.state == :completed
    assert probe.run.checks.required == "passed"
    assert probe.run.review.status == :passed
    assert probe.run.model == "gpt-5.6-sol"
    assert probe.run.reasoningEffort == "ultra"
    assert Map.has_key?(probe.run, :requestedModel)
    assert Map.has_key?(probe.run, :requestedReasoningEffort)
    assert probe.stateRunIds == %{"completed" => run_id}

    assert probe.intent.publication.linearIssues == [
             %{issue_id: "issue-authoritative", issue_identifier: "SYM-99", task_id: "task-visible-change"}
           ]

    assert probe.run.evidence == %{
             current: true,
             reference: "sha256:" <> String.duplicate("b", 64),
             sealed: true
           }

    assert probe.run.completion.status == "completed"
  end

  test "does not combine completion proof across attempts" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("d", 40)
        specs = completed_proof_specs(revision)

        prior_specs = Enum.take(specs, 4)
        current_specs = [List.first(specs) | Enum.drop(specs, 4)]

        events_from_specs(ids.run_id, ids.prior_attempt_id, prior_specs, 1) ++
          events_from_specs(ids.run_id, ids.current_attempt_id, current_specs, 5)
      end)

    assert projection.page.outcome.status == :incomplete
    assert projection.page.run.state == :active
    assert projection.page.outcome.reason =~ "does not include checks"
  end

  test "a later admitted retry invalidates an older completed attempt" do
    projection =
      projection_fixture(
        fn ids ->
          revision = String.duplicate("e", 40)

          events_from_specs(ids.run_id, ids.prior_attempt_id, completed_proof_specs(revision), 1) ++
            [event(ids.run_id, ids.current_attempt_id, 8, "worker.attempt.started", %{"retry_attempt" => 2})]
        end,
        runtime_attempt: :prior
      )

    assert projection.page.run.attempt_id == projection.current_attempt_id
    assert projection.page.run.state == :active
    assert projection.page.outcome.status == :incomplete
    refute projection.probe.run.completion.status == "completed"
  end

  test "rejects completion proof bound to mismatched revisions" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("f", 40)

        specs =
          completed_proof_specs(revision)
          |> List.update_at(2, fn {type, payload} ->
            {type, Map.put(payload, "source_revision", String.duplicate("a", 40))}
          end)

        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert projection.page.outcome.status == :incomplete
    assert projection.page.outcome.reason =~ "one immutable source revision"
  end

  test "missing and unknown proof statuses fail closed" do
    cases = [
      {:missing_check_status, 1, fn payload -> Map.delete(payload, "status") end},
      {:unknown_delivery_status, 4, &Map.put(&1, "status", "maybe")}
    ]

    Enum.each(cases, fn {_label, index, update_payload} ->
      projection =
        projection_fixture(fn ids ->
          revision = String.duplicate("b", 40)

          specs =
            completed_proof_specs(revision)
            |> List.update_at(index, fn {type, payload} -> {type, update_payload.(payload)} end)

          events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
        end)

      assert projection.page.outcome.status == :incomplete
      refute projection.probe.run.completion.status == "completed"
    end)
  end

  test "unresolved review findings prevent completion" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("9", 40)
        specs = completed_proof_specs(revision)

        specs =
          List.insert_at(specs, 3, {
            "review.finding",
            %{"severity" => "P2", "title" => "Acceptance gap", "disposition" => "Open"}
          })

        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert projection.page.review.findings == [
             %{severity: "P2", title: "Acceptance gap", disposition: "Open"}
           ]

    assert projection.page.outcome.status == :incomplete
    assert projection.page.outcome.reason =~ "without unresolved findings"
  end

  test "configured worker admission does not attest the actual model or reasoning effort" do
    projection =
      projection_fixture(fn ids ->
        [
          event(ids.run_id, ids.current_attempt_id, 1, "worker.attempt.started", %{
            "model" => "gpt-5.6-sol",
            "reasoning_effort" => "ultra"
          })
        ]
      end)

    assert projection.probe.run.model == nil
    assert projection.probe.run.reasoningEffort == nil
    assert Map.has_key?(projection.probe.run, :requestedModel)
    assert Map.has_key?(projection.probe.run, :requestedReasoningEffort)
    assert projection.page.outcome.status == :incomplete
    assert projection.page.outcome.reason =~ "does not attest GPT-5.6 Sol"
  end

  test "a current-attempt session attestation must name the exact model and reasoning effort" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("6", 40)

        specs =
          completed_proof_specs(revision)
          |> List.update_at(0, fn {type, payload} ->
            {type, Map.put(payload, "model", "gpt-5.6-terra")}
          end)

        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert projection.probe.run.model == "gpt-5.6-terra"
    assert projection.probe.run.reasoningEffort == "ultra"
    assert projection.page.outcome.status == :incomplete
    assert projection.page.outcome.reason =~ "does not attest GPT-5.6 Sol"
  end

  test "verification selects the same newest qualifying evidence as completion" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("5", 40)

        newest =
          {"evidence.sealed",
           %{
             "current" => true,
             "manifest_hash" => "sha256:" <> String.duplicate("7", 64),
             "sealed" => true,
             "source_revision" => revision,
             "status" => "sealed"
           }}

        specs = List.insert_at(completed_proof_specs(revision), 4, newest)
        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert projection.page.outcome.status == :complete

    assert projection.probe.run.evidence == %{
             current: true,
             reference: "sha256:" <> String.duplicate("7", 64),
             sealed: true
           }
  end

  test "accepts PR-only delivery only when it is bound to the immutable source revision" do
    projection =
      projection_fixture(fn ids ->
        revision = String.duplicate("4", 40)

        specs =
          completed_proof_specs(revision)
          |> List.update_at(4, fn {type, payload} ->
            {type,
             payload
             |> Map.delete("commit")
             |> Map.put("pull_request", "https://github.com/example/symphony-studio/pull/42")}
          end)

        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert projection.page.outcome.status == :complete
    assert projection.page.delivery.commit == nil
    assert projection.page.delivery.pull_request == "https://github.com/example/symphony-studio/pull/42"

    unbound =
      projection_fixture(fn ids ->
        revision = String.duplicate("3", 40)

        specs =
          completed_proof_specs(revision)
          |> List.update_at(4, fn {type, payload} ->
            {type,
             payload
             |> Map.delete("commit")
             |> Map.delete("source_revision")
             |> Map.put("pull_request", "https://github.com/example/symphony-studio/pull/43")}
          end)

        events_from_specs(ids.run_id, ids.current_attempt_id, specs, 1)
      end)

    assert unbound.page.outcome.status == :incomplete
    assert unbound.page.outcome.reason =~ "immutable"
  end

  test "keeps the latest EventSink sequence when an active run becomes intent-only" do
    projection =
      projection_fixture(
        fn ids ->
          [
            event(ids.run_id, ids.current_attempt_id, 1, "worker.attempt.started", %{}),
            event(ids.run_id, ids.current_attempt_id, 2, "codex.notification", %{"summary" => "Running"})
          ]
        end,
        runtime_last_event_sequence: 1
      )

    assert projection.page.run.last_event_sequence == 2
    assert projection.probe.sequence == 2

    orchestrator = unique_orchestrator(:IntentOnly)
    start_static_orchestrator!(orchestrator, runtime_snapshot([]))

    configure_endpoint(
      orchestrator: orchestrator,
      snapshot_timeout_ms: 100,
      studio_intent_data_root: projection.root,
      studio_event_sink: projection.target
    )

    assert {:ok, mission} = RuntimeStudioDataPort.load(:mission_control, %{})
    assert [intent_only] = mission.runs
    assert intent_only.id == projection.run_id
    assert intent_only.last_event_sequence == 2

    assert {:ok, probe} = RuntimeStudioDataPort.verification(%{"run_id" => projection.run_id})
    assert probe.sequence == 2
  end

  test "fails completion closed when retained replay has a sequence gap" do
    projection =
      projection_fixture(
        fn ids ->
          [
            event(ids.run_id, ids.current_attempt_id, 1, "worker.attempt.started", %{}),
            event(ids.run_id, ids.current_attempt_id, 2, "codex.notification", %{}),
            event(ids.run_id, ids.current_attempt_id, 3, "codex.notification", %{})
          ]
        end,
        sink_options: [max_events_per_run: 2],
        runtime_last_event_sequence: 3
      )

    assert projection.page.run.last_event_sequence == 3
    assert projection.page.outcome.status == :incomplete
    assert projection.page.outcome.reason =~ "sequence gap"
  end

  test "Setup binds a clean preview descendant to its accepted R0 foundation without claiming preview gates" do
    fixture = setup_readiness_fixture()

    assert {:ok, page} = RuntimeStudioDataPort.load(:setup, %{})
    assert page.kind == :setup
    assert page.verdict == :ready
    assert page.verdict_label == "Candidate preflight ready"
    assert page.current_revision == fixture.preview_revision
    assert page.source_revision == fixture.foundation_revision
    assert page.reason =~ "accepted R0 foundation is an ancestor"
    assert page.reason =~ "not attested by the foundation artifact"
    refute page.reason =~ "different source revision"

    compatibility = Enum.find(page.rows, &(&1.system == "Compatibility"))
    assert compatibility.state == :pass
    assert compatibility.value == "0.144.3"

    model = Enum.find(page.rows, &(&1.system == "Runtime selection"))
    assert model.state == :pass
    assert model.value == "Ultra reasoning verified"

    candidate = Enum.find(page.rows, &(&1.system == "Repository"))
    assert candidate.state == :pass
    assert candidate.label == "Preview candidate · exact committed checkout"

    foundation = Enum.find(page.rows, &(&1.system == "R0 foundation"))
    assert foundation.state == :pass
    assert foundation.label == "Accepted readiness ancestry"

    candidate_gates = Enum.find(page.rows, &(&1.system == "Readiness evidence"))
    assert candidate_gates.state == :warning
    assert candidate_gates.value == "Final gate and review pending"
    assert candidate_gates.remediation =~ "R0 artifact does not attest preview changes"
  end

  test "Setup rejects readiness evidence outside the preview candidate ancestry" do
    setup_readiness_fixture(manifest_revision: String.duplicate("f", 40))

    assert {:ok, page} = RuntimeStudioDataPort.load(:setup, %{})
    assert page.verdict == :not_ready
    assert page.reason =~ "not an ancestor of this preview candidate"

    candidate = Enum.find(page.rows, &(&1.system == "Repository"))
    assert candidate.state == :pass

    foundation = Enum.find(page.rows, &(&1.system == "R0 foundation"))
    assert foundation.state == :fail
    assert foundation.remediation =~ "descendant of the accepted foundation"
  end

  test "Setup fails a dirty preview checkout without invalidating its accepted foundation ancestry" do
    fixture = setup_readiness_fixture(dirty: true)

    assert {:ok, page} = RuntimeStudioDataPort.load(:setup, %{})
    assert page.verdict == :not_ready
    assert page.current_revision == "#{fixture.preview_revision}+changes"
    assert page.reason =~ "tracked or untracked changes"

    candidate = Enum.find(page.rows, &(&1.system == "Repository"))
    assert candidate.state == :fail
    assert candidate.remediation =~ "exact committed preview checkout"

    foundation = Enum.find(page.rows, &(&1.system == "R0 foundation"))
    assert foundation.state == :pass
  end

  test "Setup fails an untracked preview source instead of calling the checkout exact" do
    fixture = setup_readiness_fixture(untracked: true)

    assert {:ok, page} = RuntimeStudioDataPort.load(:setup, %{})
    assert page.verdict == :not_ready
    assert page.current_revision == "#{fixture.preview_revision}+changes"

    candidate = Enum.find(page.rows, &(&1.system == "Repository"))
    assert candidate.state == :fail
    assert candidate.label == "Preview candidate · exact committed checkout"

    foundation = Enum.find(page.rows, &(&1.system == "R0 foundation"))
    assert foundation.state == :pass
  end

  test "preserves canonical partial-publication and uncertain-start recovery receipts" do
    configure_endpoint(
      studio_intent_service: StaticIntentService,
      studio_linear_write_broker: {:candidate_in_process_broker, :must_not_be_injected}
    )

    assert {:ok, page} = RuntimeStudioDataPort.load(:new_work, %{"intent" => "intent-errors"})
    assert_receive {:static_intent_service_options, opts}
    refute Keyword.has_key?(opts, :broker)

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

  test "production web commands fail before any in-process write callback" do
    refute RuntimeStudioDataPort.external_write_actions_enabled?()

    configure_endpoint(
      studio_intent_service: WriteTrapIntentService,
      studio_linear_write_broker: {:candidate_in_process_broker, :must_not_be_injected}
    )

    context = %{
      command_id: "command-host-bound",
      intent_id: "intent-host-bound",
      proposal_digest: "sha256:proposal"
    }

    commands = [
      {:approve_publication, %{"proposal_digest" => "sha256:proposal"}},
      {:publish_approved_plan, %{}},
      {:start_first_ready, %{}}
    ]

    Enum.each(commands, fn {command, payload} ->
      assert {:error,
              %{
                code: "external_write_broker_required",
                details: %{},
                message: message
              }} = RuntimeStudioDataPort.command(command, payload, context)

      assert message =~ "trusted out-of-process preview-write broker"
      assert message =~ "disabled"
    end)

    refute_received {:production_write_callback, _command}
  end

  defp projection_fixture(event_builder, opts \\ []) do
    unique = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "studio-data-port-projection-#{unique}")
    on_exit(fn -> File.rm_rf!(root) end)

    run_id = Identity.uuid4()
    prior_attempt_id = Identity.uuid4()
    current_attempt_id = Identity.uuid4()

    ids = %{
      run_id: run_id,
      prior_attempt_id: prior_attempt_id,
      current_attempt_id: current_attempt_id
    }

    intent = %{
      "schema_version" => 1,
      "intent_id" => "intent_projection_#{unique}",
      "lifecycle_state" => "admitted",
      "source" => %{"content" => "Verify authoritative completion"},
      "proposal" => %{
        "tasks" => [
          %{
            "id" => "task-authoritative",
            "title" => "Verify authoritative completion",
            "acceptance_criteria" => ["Completion is fail closed"],
            "source_refs" => ["elixir/lib/symphony_elixir_web/studio_data_port.ex"]
          }
        ]
      },
      "start" => %{
        "task_id" => "task-authoritative",
        "issue_id" => "issue-authoritative",
        "issue_identifier" => "SYM-99"
      },
      "admission" => %{"run_id" => run_id, "attempt_id" => current_attempt_id}
    }

    {:ok, store} = Store.open(root: root)
    assert {:ok, ^intent, :created} = Store.create_intent(store, intent)

    sink_options = Keyword.get(opts, :sink_options, [])

    sink =
      start_supervised!(%{
        id: {:projection_memory, unique},
        start: {Memory, :start_link, [sink_options]}
      })

    target = {Memory, sink}
    events = event_builder.(ids)
    Enum.each(events, fn item -> assert {:ok, :appended} = EventSink.append(target, item) end)

    last_event_sequence =
      Keyword.get_lazy(opts, :runtime_last_event_sequence, fn ->
        events |> Enum.map(& &1.sequence) |> Enum.max(fn -> 0 end)
      end)

    runtime_attempt_id =
      case Keyword.get(opts, :runtime_attempt, :current) do
        :prior -> prior_attempt_id
        :current -> current_attempt_id
      end

    entry =
      running_entry()
      |> Map.merge(%{
        issue_id: "issue-authoritative",
        identifier: "SYM-99",
        run_id: run_id,
        attempt_id: runtime_attempt_id,
        last_event_sequence: last_event_sequence
      })

    orchestrator = unique_orchestrator(:Projection)
    start_static_orchestrator!(orchestrator, runtime_snapshot([entry]))

    configure_endpoint(
      orchestrator: orchestrator,
      snapshot_timeout_ms: 100,
      studio_intent_data_root: root,
      studio_event_sink: target
    )

    assert {:ok, page} = RuntimeStudioDataPort.load(:run_detail, %{"run_id" => run_id})
    assert {:ok, probe} = RuntimeStudioDataPort.verification(%{"run_id" => run_id})

    %{
      current_attempt_id: current_attempt_id,
      page: page,
      probe: probe,
      root: root,
      run_id: run_id,
      target: target
    }
  end

  defp completed_proof_specs(revision) do
    [
      {"codex.session.started", %{"model" => "gpt-5.6-sol", "reasoning_effort" => "ultra"}},
      {"quality.check.completed",
       %{
         "check_id" => "required",
         "command" => "mix test",
         "source_revision" => revision,
         "status" => "passed"
       }},
      {"review.completed",
       %{
         "detached" => true,
         "source_revision" => revision,
         "status" => "passed"
       }},
      {"evidence.sealed",
       %{
         "current" => true,
         "manifest_hash" => "sha256:" <> String.duplicate("8", 64),
         "sealed" => true,
         "source_revision" => revision,
         "status" => "sealed"
       }},
      {"delivery.recorded",
       %{
         "commit" => revision,
         "source_revision" => revision,
         "status" => "recorded"
       }},
      {"tracker.handoff.confirmed", %{"source_revision" => revision, "status" => "confirmed"}},
      {"run.completed", %{"source_revision" => revision, "status" => "completed"}}
    ]
  end

  defp events_from_specs(run_id, attempt_id, specs, start_sequence) do
    specs
    |> Enum.with_index(start_sequence)
    |> Enum.map(fn {{type, payload}, sequence} ->
      event(run_id, attempt_id, sequence, type, payload)
    end)
  end

  defp runtime_snapshot(running) do
    %{
      running: running,
      blocked: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  defp unique_orchestrator(suffix) do
    Module.concat(__MODULE__, "#{suffix}Orchestrator#{System.unique_integer([:positive])}")
  end

  defp start_static_orchestrator!(name, snapshot) do
    start_supervised!(%{
      id: {:static_orchestrator, name},
      start: {StaticOrchestrator, :start_link, [[name: name, snapshot: snapshot]]}
    })
  end

  defp configure_endpoint(overrides) do
    config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, config)
  end

  defp setup_readiness_fixture(options \\ []) do
    root = Path.join(System.tmp_dir!(), "studio-setup-readiness-#{System.unique_integer([:positive])}")
    repository = Path.join(root, "repository")
    readiness_path = Path.join(root, "implementation-readiness.json")
    workflow_path = Path.join(root, "WORKFLOW.md")
    original_workflow = SymphonyElixir.Workflow.workflow_file_path()

    File.mkdir_p!(repository)
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Symphony Studio Test"])
    git!(repository, ["config", "user.email", "symphony-studio-test@example.invalid"])

    File.write!(Path.join(repository, "foundation.txt"), "accepted foundation\n")
    git!(repository, ["add", "foundation.txt"])
    git!(repository, ["commit", "--quiet", "-m", "accepted foundation"])
    foundation_revision = git!(repository, ["rev-parse", "HEAD"])

    File.write!(Path.join(repository, "preview.txt"), "preview candidate\n")
    git!(repository, ["add", "preview.txt"])
    git!(repository, ["commit", "--quiet", "-m", "preview candidate"])
    preview_revision = git!(repository, ["rev-parse", "HEAD"])

    manifest_revision = Keyword.get(options, :manifest_revision, foundation_revision)
    write_setup_readiness!(readiness_path, manifest_revision)

    SymphonyElixir.TestSupport.write_workflow_file!(workflow_path,
      tracker_kind: "linear",
      tracker_project_slug: "symphony-studio-build-week-3f2698765546",
      tracker_api_token: "non-secret-test-token",
      codex_command: ~s(codex --config 'model="gpt-5.6-sol"' --config model_reasoning_effort=ultra app-server)
    )

    SymphonyElixir.Workflow.set_workflow_file_path(workflow_path)

    if Keyword.get(options, :dirty, false) do
      File.write!(Path.join(repository, "preview.txt"), "uncommitted preview change\n")
    end

    if Keyword.get(options, :untracked, false) do
      File.write!(Path.join(repository, "untracked_runtime.ex"), "defmodule UntrackedRuntime do\nend\n")
    end

    configure_endpoint(studio_project_root: repository, studio_readiness_path: readiness_path)

    on_exit(fn ->
      SymphonyElixir.Workflow.set_workflow_file_path(original_workflow)
      File.rm_rf(root)
    end)

    %{foundation_revision: foundation_revision, preview_revision: preview_revision}
  end

  defp write_setup_readiness!(path, foundation_revision) do
    manifest = %{
      "checkout" => %{"headCommit" => foundation_revision},
      "runtime" => %{"overall" => "pass"},
      "codex" => %{"version" => "0.144.3"},
      "capabilities" => %{
        "auth" => %{
          "mode" => "chatgpt",
          "referenceProfile" => %{"chatgptAuthentication" => true}
        },
        "linear" => %{
          "configuredProjectBinding" => "linear-project-v1-0123456789abcdef",
          "project" => %{"status" => "pass"}
        },
        "models" => [
          %{"id" => "gpt-5.6-sol", "reasoningEfforts" => ["high", "ultra"]}
        ]
      }
    }

    File.write!(path, Jason.encode_to_iodata!(manifest))
  end

  defp git!(repository, arguments) do
    case System.cmd("git", arguments, cd: repository, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(arguments, " ")} failed (#{status}): #{output}")
    end
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
