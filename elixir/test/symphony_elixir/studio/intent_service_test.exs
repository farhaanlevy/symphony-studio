# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.IntentServiceTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.{Event, EventSink, Identity}
  alias SymphonyElixir.EventSink.Memory
  alias SymphonyElixir.Studio.Intent.{AdmissionSink, Store}
  alias SymphonyElixir.Studio.IntentService
  alias SymphonyElixir.Studio.LinearWriteBroker
  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Fake, Result}

  setup do
    unique = System.unique_integer([:positive, :monotonic])
    root = Path.join(System.tmp_dir!(), "symphony-intent-project-#{unique}")
    data_root = Path.join(System.tmp_dir!(), "symphony-intent-data-#{unique}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "README.md"), "# Example project\n\n## Architecture\n")
    File.write!(Path.join(root, "lib/widget.ex"), "defmodule Widget do\nend\n")
    File.write!(Path.join(root, "test/widget_test.exs"), "defmodule WidgetTest do\nend\n")

    {:ok, store} = Store.open(root: data_root)
    {:ok, broker} = Fake.start_link()

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(data_root)
    end)

    %{broker: broker, data_root: data_root, project_root: root, store: store}
  end

  test "runs clarification, digest-bound publication, first-ready transition, and actual admission", ctx do
    opts = [store: ctx.store, broker: {Fake, ctx.broker}]

    {:ok, attached} = IntentService.attach_project(ctx.project_root, "attach-1", opts)
    project_id = attached["project"]["project_id"]

    {:ok, submitted} =
      IntentService.submit_intent(
        project_id,
        %{"kind" => "prompt", "content" => "Build a reliable widget search workflow."},
        "submit-1",
        opts
      )

    assert submitted["lifecycle_state"] == "clarification_required"
    assert length(submitted["clarifications"]["questions"]) in 1..3
    intent_id = submitted["intent_id"]

    {:ok, proposed} =
      IntentService.answer_clarifications(
        intent_id,
        %{"use_recommended_defaults" => true},
        "answers-1",
        opts
      )

    assert proposed["lifecycle_state"] == "proposal_ready"
    assert length(proposed["proposal"]["tasks"]) in 3..8
    assert_acyclic(proposed["proposal"]["tasks"])

    {:ok, presented} = IntentService.present_proposal(intent_id, "present-1", opts)
    digest = presented["proposal"]["digest"]
    assert presented["lifecycle_state"] == "presented"

    assert {:error, %{code: :confirmation_mismatch}} =
             IntentService.approve_publication(
               intent_id,
               digest,
               "yes",
               "approve-wrong",
               opts
             )

    assert {:error, %{code: :stale_proposal_digest}} =
             IntentService.approve_publication(
               intent_id,
               String.duplicate("0", 64),
               "publish_linear_backlog",
               "approve-stale",
               opts
             )

    {:ok, approved} =
      IntentService.approve_publication(
        intent_id,
        digest,
        "publish_linear_backlog",
        "approve-1",
        opts
      )

    assert approved["lifecycle_state"] == "approved"

    {:ok, published} = IntentService.publish_approved_plan(intent_id, "publish-1", opts)
    assert published["publication"]["status"] == "complete"
    assert published["lifecycle_state"] == "published"
    assert Enum.all?(published["publication"]["tasks"], fn {_id, entry} -> entry["status"] == "confirmed" end)

    calls_after_publish = Fake.calls(ctx.broker)
    {:ok, replayed} = IntentService.publish_approved_plan(intent_id, "publish-1", opts)
    assert replayed["publication"]["status"] == "complete"
    assert Fake.calls(ctx.broker) == calls_after_publish

    assert {:error, %{code: :confirmation_mismatch}} =
             IntentService.start_first_ready(intent_id, "yes", "start-wrong", opts)

    {:ok, waiting} =
      IntentService.start_first_ready(
        intent_id,
        "start_first_ready",
        "start-1",
        opts
      )

    assert waiting["start"]["status"] == "waiting_for_admission"
    assert waiting["lifecycle_state"] == "waiting_for_admission"
    assert waiting["admission"] == nil

    event = admission_event(waiting)
    assert {:ok, 1} = IntentService.observe_admission_event(event, opts)

    {:ok, admitted} = IntentService.get_intent_status(intent_id, opts)
    assert admitted["lifecycle_state"] == "admitted"
    assert admitted["start"]["status"] == "admitted"
    assert admitted["admission"]["event_id"] == event.event_id
    assert admitted["admission"]["run_id"] == event.run_id

    non_admission = %{event | type: "worker.attempt.exited"}
    assert {:error, _reason} = Event.validate(non_admission)
  end

  test "surfaces uncertain publication and resumes only by exact reconciliation", ctx do
    opts = [store: ctx.store, broker: {Fake, ctx.broker}]
    ready = approved_intent(ctx, opts, "uncertain")
    [first | _rest] = ready["proposal"]["tasks"]

    issue_key = Command.issue_key(ready["intent_id"], ready["proposal"]["digest"], first["id"])

    :ok =
      Fake.set_responses(ctx.broker, :reconcile, issue_key, [
        {:ok, Result.uncertain("fake", %{"reason" => "lost response"})}
      ])

    {:ok, uncertain} =
      IntentService.publish_approved_plan(ready["intent_id"], "publish-uncertain-1", opts)

    assert uncertain["publication"]["status"] == "uncertain"
    assert uncertain["publication"]["tasks"][first["id"]]["status"] == "uncertain"
    refute Enum.any?(Fake.calls(ctx.broker), &(&1.phase == :execute and &1.idempotency_key == issue_key))

    {:ok, complete} =
      IntentService.publish_approved_plan(ready["intent_id"], "publish-uncertain-2", opts)

    assert complete["publication"]["status"] == "complete"

    exact_calls = Enum.filter(Fake.calls(ctx.broker), &(&1.idempotency_key == issue_key))
    assert Enum.map(exact_calls, & &1.phase) == [:reconcile, :reconcile, :execute]
  end

  test "preserves confirmed mappings when a later publication action is blocked", ctx do
    opts = [store: ctx.store, broker: {Fake, ctx.broker}]
    ready = approved_intent(ctx, opts, "partial")
    [first, second | _rest] = ready["proposal"]["tasks"]

    second_key =
      Command.issue_key(ready["intent_id"], ready["proposal"]["digest"], second["id"])

    :ok = Fake.set_responses(ctx.broker, :reconcile, second_key, [{:error, :simulated_failure}])

    {:ok, partial} =
      IntentService.publish_approved_plan(ready["intent_id"], "publish-partial", opts)

    assert partial["publication"]["status"] == "partial"
    assert partial["lifecycle_state"] == "publication_partial"
    assert partial["publication"]["tasks"][first["id"]]["status"] == "confirmed"
    assert partial["publication"]["tasks"][second["id"]]["status"] == "blocked"
    assert partial["publication"]["last_error"]["resumable"]
  end

  test "default broker fails closed and leaves publication visibly resumable", ctx do
    opts = [store: ctx.store]
    ready = approved_intent(ctx, opts, "blocked")

    {:ok, blocked} =
      IntentService.publish_approved_plan(ready["intent_id"], "publish-blocked", opts)

    assert blocked["publication"]["status"] == "blocked"
    assert blocked["lifecycle_state"] == "publication_blocked"

    assert blocked["publication"]["last_error"]["code"] ==
             "least_privilege_write_broker_unavailable"

    assert Enum.all?(blocked["publication"]["tasks"], fn {_id, entry} ->
             is_nil(entry["issue_id"])
           end)
  end

  test "broker permanently denies SYM-1 and SYM-2 before transition delegation", ctx do
    digest = String.duplicate("a", 64)

    {:ok, command} =
      Command.transition("intent_12345678", digest, "task_12345678", %{
        "issue_id" => "linear-1",
        "issue_identifier" => "sym-1",
        "provider" => "fake",
        "status" => "confirmed"
      })

    assert {:error, :protected_linear_issue_denied} =
             LinearWriteBroker.execute({Fake, ctx.broker}, command)

    assert Fake.calls(ctx.broker) == []
  end

  test "broker rejects a confirmed transition receipt for a different issue", ctx do
    digest = String.duplicate("b", 64)

    {:ok, command} =
      Command.transition("intent_12345678", digest, "task_12345678", %{
        "issue_id" => "linear-expected",
        "issue_identifier" => "SYM-999",
        "provider" => "fake",
        "status" => "confirmed"
      })

    mismatched = %Result{
      status: :confirmed,
      provider: "fake",
      external_id: "linear-other",
      issue_identifier: "SYM-998",
      details: %{"outcome" => "transitioned"}
    }

    :ok = Fake.set_responses(ctx.broker, :execute, command.idempotency_key, [{:ok, mismatched}])

    assert {:error, :linear_write_broker_invalid_response} =
             LinearWriteBroker.execute({Fake, ctx.broker}, command)
  end

  test "composite event sink admits only from an exact persisted Symphony start event", ctx do
    opts = [store: ctx.store, broker: {Fake, ctx.broker}]
    ready = approved_intent(ctx, opts, "sink")
    {:ok, published} = IntentService.publish_approved_plan(ready["intent_id"], "publish-sink", opts)

    {:ok, waiting} =
      IntentService.start_first_ready(
        ready["intent_id"],
        "start_first_ready",
        "start-sink",
        opts
      )

    {:ok, downstream} = Memory.start_link()
    target = AdmissionSink.target(ctx.store, {Memory, downstream})
    event_snapshot = Map.put(waiting, "test_run_id", Identity.uuid4())
    exited = lifecycle_event(event_snapshot, "worker.attempt.exited", 1)

    assert {:ok, :appended} = EventSink.append(target, exited)
    {:ok, still_waiting} = IntentService.get_intent_status(ready["intent_id"], opts)
    assert still_waiting["lifecycle_state"] == "waiting_for_admission"

    started = lifecycle_event(event_snapshot, "worker.attempt.started", 2)
    assert {:ok, :appended} = EventSink.append(target, started)

    {:ok, admitted} = IntentService.get_intent_status(ready["intent_id"], opts)
    assert admitted["admission"]["event_id"] == started.event_id

    assert {:ok, %{events: [^exited, ^started]}} =
             EventSink.replay({Memory, downstream}, started.run_id, 0, 10)

    assert published["publication"]["status"] == "complete"
  end

  test "intent survives store reopen with immutable event sequence", ctx do
    opts = [store: ctx.store, broker: {Fake, ctx.broker}]
    ready = approved_intent(ctx, opts, "reopen")

    {:ok, reopened} = Store.open(root: ctx.data_root)
    {:ok, snapshot} = IntentService.get_intent_status(ready["intent_id"], store: reopened)

    assert snapshot["proposal"]["digest"] == ready["proposal"]["digest"]
    assert Enum.map(snapshot["events"], & &1["sequence"]) == Enum.to_list(1..length(snapshot["events"]))
    assert Enum.uniq_by(snapshot["events"], & &1["event_id"]) == snapshot["events"]
  end

  test "composite sink surfaces admission-link failure after downstream persistence", ctx do
    {:ok, downstream} = Memory.start_link()
    target = AdmissionSink.target(ctx.store, {Memory, downstream})

    event =
      lifecycle_event(
        %{
          "start" => %{
            "issue_id" => "linear-unlinked",
            "issue_identifier" => "SYM-999"
          }
        },
        "worker.attempt.started",
        1
      )

    File.rm_rf!(Path.join(ctx.data_root, "intents"))
    File.write!(Path.join(ctx.data_root, "intents"), "unavailable")

    assert {:error, {:intent_admission_link_failed, %{code: :store_unavailable}}} =
             EventSink.append(target, event)

    assert {:ok, %{events: [^event]}} = EventSink.replay({Memory, downstream}, event.run_id, 0, 10)
  end

  defp approved_intent(ctx, opts, suffix) do
    {:ok, attached} = IntentService.attach_project(ctx.project_root, "attach-#{suffix}", opts)

    {:ok, submitted} =
      IntentService.submit_intent(
        attached["project"]["project_id"],
        %{
          "kind" => "markdown",
          "content" => """
          # Operator workflow
          - Persist deterministic intent state
          - Publish through a typed broker
          - Verify retries with tests
          - Exclude deployment changes
          """
        },
        "submit-#{suffix}",
        opts
      )

    proposed =
      if submitted["lifecycle_state"] == "clarification_required" do
        {:ok, answered} =
          IntentService.answer_clarifications(
            submitted["intent_id"],
            %{"use_recommended_defaults" => true},
            "answers-#{suffix}",
            opts
          )

        answered
      else
        submitted
      end

    {:ok, presented} =
      IntentService.present_proposal(proposed["intent_id"], "present-#{suffix}", opts)

    {:ok, approved} =
      IntentService.approve_publication(
        proposed["intent_id"],
        presented["proposal"]["digest"],
        "publish_linear_backlog",
        "approve-#{suffix}",
        opts
      )

    approved
  end

  defp admission_event(snapshot) do
    lifecycle_event(snapshot, "worker.attempt.started", 1)
  end

  defp lifecycle_event(snapshot, type, sequence) do
    run_id = Map.get(snapshot, "test_run_id", Identity.uuid4())

    Event.new!(%{
      sequence: sequence,
      occurred_at: DateTime.utc_now(),
      issue_id: snapshot["start"]["issue_id"],
      issue_identifier: snapshot["start"]["issue_identifier"],
      run_id: run_id,
      attempt_id: Identity.uuid4(),
      thread_id: nil,
      turn_id: nil,
      type: type,
      severity: "info",
      payload: %{"retry_attempt" => 0}
    })
  end

  defp assert_acyclic(tasks) do
    ids = MapSet.new(tasks, & &1["id"])

    assert Enum.all?(tasks, fn task ->
             Enum.all?(task["depends_on"], &MapSet.member?(ids, &1)) and
               task["id"] not in task["depends_on"]
           end)

    assert Enum.any?(tasks, &(&1["depends_on"] == []))
  end
end
