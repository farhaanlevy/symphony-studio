defmodule SymphonyElixirWeb.StudioDataPort do
  @moduledoc """
  Narrow boundary between the Studio web surface and runtime-owned state.

  Implementations return presentation-safe maps. The web layer never calls
  Linear, starts a worker, or derives terminal truth from rendered copy.
  """

  @type page :: map()
  @type public_error :: %{
          required(:code) => String.t(),
          required(:message) => String.t(),
          required(:details) => map()
        }
  @type command_context :: %{
          required(:command_id) => String.t(),
          optional(:intent_id) => String.t(),
          optional(:proposal_digest) => String.t()
        }

  @callback load(:mission_control | :setup | :new_work | :run_detail, map()) ::
              {:ok, page()} | {:error, public_error()}
  @callback command(atom(), map(), command_context()) ::
              {:ok, page()} | {:error, public_error()} | {:uncertain, public_error()}
end

defmodule SymphonyElixirWeb.RuntimeStudioDataPort do
  @moduledoc """
  Production Studio web adapter.

  Mission Control and Run Detail preserve the original Symphony observability
  snapshot. New Work uses the canonical Intent Service through optional remote
  calls so this web package can land before the service package without a
  compile-time dependency.
  """

  @behaviour SymphonyElixirWeb.StudioDataPort

  alias SymphonyElixir.{Config, Event, EventSink}
  alias SymphonyElixir.Studio.Intent.Store
  alias SymphonyElixir.Studio.LinearWriteBroker.Linear
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @intent_service SymphonyElixir.Studio.IntentService
  @project_root Path.expand("../../..", __DIR__)
  @readiness_path Path.join(@project_root, "artifacts/readiness/implementation-readiness.json")
  @event_replay_limit 512
  @preview_project_slug "symphony-studio-build-week-3f2698765546"
  @preview_team_key "SYM"

  @impl true
  def load(:mission_control, _params), do: mission_control()

  def load(:setup, _params), do: {:ok, setup_page()}

  def load(:new_work, %{"intent" => intent_id}) when is_binary(intent_id) and intent_id != "" do
    with {:ok, snapshot} <- intent_call(:get_intent_status, [intent_id, []]) do
      {:ok, intent_page(snapshot)}
    end
  end

  def load(:new_work, _params), do: {:ok, empty_intent_page()}

  def load(:run_detail, %{"run_id" => run_id}) when is_binary(run_id) and run_id != "" do
    run_detail(run_id)
  end

  def load(:run_detail, _params), do: error("run_not_found", "Run not found.")

  @doc "Returns the bounded, read-only owner verification projection."
  @spec verification(map()) :: {:ok, map()} | {:error, SymphonyElixirWeb.StudioDataPort.public_error()}
  def verification(params \\ %{}) when is_map(params) do
    with {:ok, mission} <- mission_control() do
      intents = intent_documents()
      run = verification_run(mission, params)
      intent = verification_intent(intents, run, params)
      setup = setup_page()

      {:ok,
       %{
         authoritative: true,
         dependencies: verification_dependencies(setup),
         intent: intent && verification_intent_payload(intent),
         mode: "live",
         project: %{slugId: @preview_project_slug, teamKey: @preview_team_key},
         run: run && verification_run_payload(run, mission),
         schemaVersion: 1,
         sequence: verification_sequence(mission.runs),
         source: "symphony_runtime",
         stateRunIds: verification_state_run_ids(mission.runs)
       }}
    end
  end

  @impl true
  def command(:submit_intent, %{"kind" => kind, "content" => content}, context)
      when kind in ["prompt", "markdown"] and is_binary(content) do
    command_id = Map.fetch!(context, :command_id)
    project_root = web_config(:studio_project_root, @project_root)

    with {:ok, attached} <- intent_call(:attach_project, [project_root, "#{command_id}:project", []]),
         project_id when is_binary(project_id) <- string_path(attached, ["project", "project_id"]),
         {:ok, snapshot} <-
           intent_call(:submit_intent, [
             project_id,
             %{"kind" => kind, "content" => content},
             "#{command_id}:intent",
             []
           ]) do
      {:ok, intent_page(snapshot)}
    else
      nil -> error("project_attachment_invalid", "Repository inspection did not return a project binding.")
      {:error, _error} = result -> result
    end
  end

  def command(:answer_clarifications, %{"answers" => answers}, context) when is_map(answers) do
    intent_command(
      :answer_clarifications,
      [%{"answers" => answers}],
      context
    )
  end

  def command(:use_recommended_defaults, _payload, context) do
    intent_command(
      :answer_clarifications,
      [%{"use_recommended_defaults" => true}],
      context
    )
  end

  def command(:present_proposal, _payload, context) do
    intent_command(:present_proposal, [], context)
  end

  def command(:approve_publication, %{"proposal_digest" => digest}, context)
      when is_binary(digest) and digest != "" do
    intent_command(
      :approve_publication,
      [digest, "publish_linear_backlog"],
      context
    )
  end

  def command(:publish_approved_plan, _payload, context) do
    intent_command(:publish_approved_plan, [], context)
  end

  def command(:start_first_ready, _payload, context) do
    intent_command(:start_first_ready, ["start_first_ready"], context)
  end

  def command(_command, _payload, _context) do
    error("unsupported_web_command", "That action is not available.")
  end

  defp verification_run(mission, params) do
    run_id = Map.get(params, "run_id") || Map.get(params, :run_id)

    if is_binary(run_id) and run_id != "" do
      Enum.find(mission.runs, &(&1.id == run_id or &1.issue_identifier == run_id))
    else
      mission.active_run
    end
  end

  defp verification_intent(intents, run, params) do
    intent_id = Map.get(params, "intent") || Map.get(params, :intent)

    cond do
      is_binary(intent_id) and intent_id != "" -> Enum.find(intents, &(&1["intent_id"] == intent_id))
      is_map(run) -> Enum.find(intents, &(get_in(&1, ["admission", "run_id"]) == run.id))
      true -> List.last(intents)
    end
  end

  defp verification_intent_payload(document) do
    page = intent_page(document)
    publication = page.publication
    confirmed = publication.tasks |> Enum.take(8) |> Enum.filter(&(&1.status == "confirmed"))
    admission = page.admission

    %{
      intentId: page.intent_id,
      publication: %{
        confirmedWrites: length(confirmed),
        idempotencyStatus: verification_publication_status(publication.status),
        linearIssues: Enum.map(confirmed, &Map.take(&1, [:issue_id, :issue_identifier, :task_id])),
        status: verification_publication_status(publication.status)
      },
      start: %{
        issueIdentifier: page.start.issue_identifier,
        runId: admission && admission.run_id,
        status: if(admission, do: "admitted", else: page.start.status)
      },
      status: (page.proposal && page.proposal.status) || page.lifecycle_state
    }
  end

  defp verification_publication_status("complete"), do: "confirmed"
  defp verification_publication_status(status), do: status

  defp verification_run_payload(run, mission) do
    page = run_page(run, mission)
    evidence = Enum.find(page.evidence, &(&1.current and &1.sealed))

    %{
      checks: %{required: aggregate_check_status(page.checks), results: page.checks},
      completion: %{reason: page.outcome.reason, status: completion_status(page.outcome.status)},
      delivery: page.delivery || %{},
      evidence: %{
        current: not is_nil(evidence),
        reference: evidence && evidence.reference,
        sealed: not is_nil(evidence)
      },
      issueIdentifier: run.issue_identifier,
      model: verification_model(run.conductor),
      objective: run.objective,
      phase: run.phase,
      reasoningEffort: verification_reasoning_effort(run.conductor),
      review: page.review,
      runId: run.id,
      state: run.state,
      trackerHandoff: page.tracker_handoff,
      workspace: %{isolated: Map.get(run, :workspace_isolated, false)}
    }
  end

  defp aggregate_check_status([]), do: "not_reported"

  defp aggregate_check_status(checks) when is_list(checks) do
    cond do
      Enum.all?(checks, &(&1.status == :passed)) -> "passed"
      Enum.any?(checks, &(&1.status == :active)) -> "active"
      true -> "failed"
    end
  end

  defp completion_status(:complete), do: "completed"
  defp completion_status(_status), do: "incomplete"
  defp verification_model("GPT-5.6 Sol Ultra"), do: "gpt-5.6-sol"
  defp verification_model(_conductor), do: nil
  defp verification_reasoning_effort("GPT-5.6 Sol Ultra"), do: "ultra"
  defp verification_reasoning_effort(_conductor), do: nil

  defp verification_sequence(runs) do
    runs |> Enum.map(&Map.get(&1, :last_event_sequence, 0)) |> Enum.max(fn -> 0 end)
  end

  defp verification_state_run_ids(runs) do
    Map.new(runs, &{to_string(&1.state), &1.id})
  end

  defp verification_dependencies(setup) do
    %{
      codex: dependency_status(setup, ["Codex authentication", "Compatibility", "Runtime selection"]),
      linear: dependency_status(setup, ["Linear project"]),
      store: if(match?({:ok, _store}, intent_store()), do: "ready", else: "blocked")
    }
  end

  defp dependency_status(setup, systems) do
    rows = Enum.filter(setup.rows, &(&1.system in systems))
    if length(rows) == length(systems) and Enum.all?(rows, &(&1.state == :pass)), do: "ready", else: "blocked"
  end

  defp mission_control do
    case Presenter.state_payload(orchestrator(), snapshot_timeout_ms()) do
      %{error: %{code: code, message: message}} ->
        {:error, %{code: to_string(code), message: to_string(message), details: %{}}}

      payload when is_map(payload) ->
        {:ok, mission_page(payload)}
    end
  end

  defp run_detail(run_id) do
    with {:ok, mission} <- mission_control(),
         run when is_map(run) <- Enum.find(mission.runs, &(&1.id == run_id or &1.issue_identifier == run_id)) do
      {:ok, run_page(run, mission)}
    else
      nil -> error("run_not_found", "Run #{run_id} is not present in the current runtime snapshot.")
      {:error, _error} = result -> result
    end
  end

  defp mission_page(payload) do
    runtime_runs =
      Enum.map(payload.running, &runtime_run(&1, :active)) ++
        Enum.map(payload.blocked, &runtime_run(&1, :blocked)) ++
        Enum.map(payload.retrying, &runtime_run(&1, :queued))

    intents = intent_documents()

    runs =
      (runtime_runs ++ intent_only_runs(intents, runtime_runs))
      |> Enum.map(&enrich_runtime_run(&1, intents))

    %{
      kind: :mission_control,
      source: :runtime_projection,
      generated_at: payload.generated_at,
      freshness: :current,
      counts: payload.counts,
      runs: runs,
      active_run: Enum.find(runs, &(&1.state in [:active, :blocked, :validating, :reviewing])) || List.first(runs),
      usage: usage(payload.codex_totals),
      rate_limits: payload.rate_limits,
      error: nil
    }
  end

  defp runtime_run(entry, state) do
    %{
      id: entry.run_id || entry.issue_identifier,
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: entry.issue_identifier,
      issue_url: safe_external_url(entry.issue_url),
      objective: "Objective unavailable in the current runtime snapshot",
      state: state,
      state_label: state_label(state),
      phase: phase_for(state),
      phase_label: phase_label(phase_for(state)),
      conductor: configured_conductor(),
      started_at: Map.get(entry, :started_at),
      due_at: Map.get(entry, :due_at),
      elapsed_label: nil,
      latest_activity: runtime_activity(entry, state),
      latest_activity_at: Map.get(entry, :last_event_at) || Map.get(entry, :blocked_at),
      usage: usage(Map.get(entry, :tokens)),
      blocker: runtime_blocker(entry, state),
      next_action: runtime_next_action(entry, state),
      check_summary: "Checks not reported by the current runtime snapshot",
      review_summary: "Independent review not reported",
      session_id: Map.get(entry, :session_id),
      attempt: Map.get(entry, :attempt),
      attempt_id: Map.get(entry, :attempt_id),
      raw_state: Map.get(entry, :state),
      workspace_path: Map.get(entry, :workspace_path),
      last_event_sequence: Map.get(entry, :last_event_sequence, 0)
    }
  end

  defp run_page(run, mission) do
    proof = run.proof
    contract = run.contract

    %{
      kind: :run_detail,
      source: :runtime_projection,
      generated_at: mission.generated_at,
      freshness: mission.freshness,
      run:
        run
        |> Map.drop([:contract, :events, :proof])
        |> Map.put(:phase_rail, phase_rail(run.phase, run.state)),
      acceptance_criteria: contract.acceptance_criteria,
      scope: contract.scope,
      plan: contract.plan,
      activity: proof.activity,
      commands: proof.commands,
      changes: proof.changes,
      checks: proof.checks,
      review: proof.review,
      evidence: proof.evidence,
      outcome: proof.outcome,
      delivery: proof.delivery,
      tracker_handoff: proof.tracker_handoff
    }
  end

  defp intent_documents do
    case intent_store() do
      {:ok, store} ->
        case Store.list_intents(store) do
          {:ok, documents} -> Enum.take(documents, -50)
          {:error, _reason} -> []
        end

      {:error, _reason} ->
        []
    end
  end

  defp intent_only_runs(intents, runtime_runs) do
    runtime_ids = MapSet.new(runtime_runs, & &1.id)

    intents
    |> Enum.filter(&(is_binary(get_in(&1, ["admission", "run_id"])) and not MapSet.member?(runtime_ids, get_in(&1, ["admission", "run_id"]))))
    |> Enum.map(&intent_only_run/1)
  end

  defp intent_only_run(intent) do
    admission = string_map(intent["admission"])
    start = string_map(intent["start"])

    %{
      id: admission["run_id"],
      issue_id: start["issue_id"] || admission["issue_id"],
      issue_identifier: start["issue_identifier"] || "Unidentified issue",
      issue_url: nil,
      objective: "Objective unavailable",
      state: :incomplete,
      state_label: "Incomplete",
      phase: :outcome,
      phase_label: "Outcome",
      conductor: configured_conductor(),
      started_at: admission["observed_at"],
      due_at: nil,
      elapsed_label: nil,
      latest_activity: "The run is no longer active; retained proof is incomplete.",
      latest_activity_at: admission["observed_at"],
      usage: nil,
      blocker: "Current completion proof is unavailable.",
      next_action: "Inspect the retained event and evidence records.",
      check_summary: "Checks not reported",
      review_summary: "Independent review not reported",
      session_id: nil,
      attempt: nil,
      attempt_id: admission["attempt_id"],
      raw_state: nil,
      workspace_path: nil,
      last_event_sequence: 0
    }
  end

  defp enrich_runtime_run(run, intents) do
    intent = matching_intent(run, intents)
    contract = contract_from_intent(intent, run)
    events = replay_events(run.id)
    proof = proof_from_events(events)
    {state, phase} = projected_state(run.state, proof)
    latest = List.first(proof.activity)

    run
    |> Map.put(:contract, contract)
    |> Map.put(:events, events)
    |> Map.put(:proof, proof)
    |> Map.put(:objective, contract.objective)
    |> Map.put(:state, state)
    |> Map.put(:state_label, state_label(state))
    |> Map.put(:phase, phase)
    |> Map.put(:phase_label, phase_label(phase))
    |> Map.put(:latest_activity, latest_activity(latest, run.latest_activity))
    |> Map.put(:latest_activity_at, (latest && latest.occurred_at) || run.latest_activity_at)
    |> Map.put(:check_summary, check_summary(proof.checks))
    |> Map.put(:review_summary, review_summary(proof.review))
    |> Map.put(:blocker, projected_blocker(run, proof))
    |> Map.put(:next_action, projected_next_action(run, proof))
    |> Map.put(:workspace_isolated, isolated_workspace?(run.workspace_path))
  end

  defp matching_intent(run, intents) do
    Enum.find(intents, fn intent ->
      get_in(intent, ["admission", "run_id"]) == run.id or
        (is_binary(run.issue_id) and get_in(intent, ["start", "issue_id"]) == run.issue_id)
    end)
  end

  defp contract_from_intent(nil, run) do
    %{
      objective: run.objective,
      acceptance_criteria: [],
      plan: [],
      scope: [],
      intent_id: nil,
      task_id: nil
    }
  end

  defp contract_from_intent(intent, run) do
    proposal = string_map(intent["proposal"])
    tasks = list_of_maps(proposal["tasks"])
    selected_task_id = get_in(intent, ["start", "task_id"])
    selected = Enum.find(tasks, &(&1["id"] == selected_task_id)) || List.first(tasks) || %{}
    objective = selected["title"] || source_objective(intent) || run.objective

    %{
      objective: bounded_text(objective, 240, run.objective),
      acceptance_criteria: bounded_strings(selected["acceptance_criteria"], 12),
      plan: Enum.map(tasks, &plan_step(&1, selected_task_id, run.state)),
      scope: safe_paths(selected["source_refs"]),
      intent_id: intent["intent_id"],
      task_id: selected_task_id
    }
  end

  defp source_objective(intent) do
    intent
    |> get_in(["source", "content"])
    |> case do
      value when is_binary(value) -> value |> String.split(~r/\R/, parts: 2) |> List.first()
      _other -> nil
    end
  end

  defp plan_step(task, selected_task_id, state) do
    status =
      cond do
        task["id"] != selected_task_id -> :pending
        state == :blocked -> :blocked
        state in [:active, :validating, :reviewing] -> :active
        state == :completed -> :completed
        true -> :pending
      end

    %{id: task["id"], label: bounded_text(task["title"], 200, "Untitled task"), status: status}
  end

  defp replay_events(run_id) when is_binary(run_id) do
    case EventSink.replay(event_sink(), run_id, 0, @event_replay_limit) do
      {:ok, %{events: events}} -> events
      {:error, _reason} -> []
    end
  end

  defp replay_events(_run_id), do: []

  defp proof_from_events(events) do
    initial = %{
      activity: [],
      changes: [],
      checks: %{},
      commands: [],
      completion_event?: false,
      delivery: nil,
      evidence: [],
      review: %{status: :not_run, detached: false, findings: [], source_revision: nil, completed_at: nil},
      tracker_handoff: %{status: :not_confirmed, confirmed_at: nil}
    }

    reduced = Enum.reduce(events, initial, &reduce_event/2)
    checks = reduced.checks |> Map.values() |> Enum.sort_by(&{&1.completed_at || "", &1.command})
    review = Map.update!(reduced.review, :findings, &Enum.reverse/1)
    evidence = Enum.reverse(reduced.evidence)
    delivery = reduced.delivery
    tracker_handoff = reduced.tracker_handoff

    proof = %{
      reduced
      | activity: Enum.reverse(reduced.activity),
        changes: Enum.reverse(reduced.changes),
        checks: checks,
        commands: Enum.reverse(reduced.commands),
        evidence: evidence,
        review: review
    }

    Map.put(proof, :outcome, outcome(proof, delivery, tracker_handoff))
  end

  defp reduce_event(%Event{} = event, proof) do
    event = Event.to_map(event)
    type = event["type"]
    payload = string_map(event["payload"])
    proof = Map.update!(proof, :activity, &[activity_row(event, payload) | &1])

    proof
    |> maybe_record_command(type, payload, event)
    |> maybe_record_change(type, payload)
    |> maybe_record_check(type, payload, event)
    |> maybe_record_review(type, payload, event)
    |> maybe_record_evidence(type, payload)
    |> maybe_record_delivery(type, payload)
    |> maybe_record_handoff(type, payload, event)
    |> maybe_record_completion(type, payload)
  end

  defp activity_row(event, payload) do
    type = event["type"]

    %{
      phase: event_phase(type),
      label: event_label(type),
      summary: event_summary(type, payload),
      occurred_at: event["occurred_at"],
      result: event_result(type, event["severity"], payload),
      effect: event_effect(type)
    }
  end

  defp maybe_record_command(proof, type, payload, event)
       when type in ["operation.command.started", "operation.command.completed"] do
    command = bounded_text(payload["command"], 500, "Command text unavailable")

    Map.update!(proof, :commands, fn commands ->
      [
        %{
          command: command,
          status: event_result(type, event["severity"], payload),
          summary: bounded_text(payload["summary"], 500, event_label(type)),
          completed_at: event["occurred_at"]
        }
        | commands
      ]
    end)
  end

  defp maybe_record_command(proof, _type, _payload, _event), do: proof

  defp maybe_record_change(proof, type, payload)
       when type in ["repository.file.changed", "workspace.file.changed"] do
    case safe_event_path(payload["path"]) do
      nil ->
        proof

      path ->
        change = %{
          path: path,
          summary: bounded_text(payload["summary"], 300, "Changed during the run"),
          status: normalize_status(payload["status"], :changed)
        }

        Map.update!(proof, :changes, &[change | &1])
    end
  end

  defp maybe_record_change(proof, _type, _payload), do: proof

  defp maybe_record_check(proof, type, payload, event)
       when type in ["quality.check.started", "quality.check.completed"] do
    command = bounded_text(payload["command"], 500, "Deterministic check")
    key = bounded_text(payload["check_id"], 160, command)

    check = %{
      command: command,
      status: normalize_check_status(type, payload["status"], event["severity"]),
      summary: bounded_text(payload["summary"], 500, event_label(type)),
      completed_at: event["occurred_at"]
    }

    Map.update!(proof, :checks, &Map.put(&1, key, check))
  end

  defp maybe_record_check(proof, _type, _payload, _event), do: proof

  defp maybe_record_review(proof, "review.finding", payload, _event) do
    finding = %{
      severity: bounded_text(payload["severity"], 16, "P2"),
      title: bounded_text(payload["title"], 300, "Review finding"),
      disposition: bounded_text(payload["disposition"], 300, "Open")
    }

    update_in(proof, [:review, :findings], &[finding | &1])
  end

  defp maybe_record_review(proof, "review.started", payload, event) do
    put_in(proof, [:review], %{
      proof.review
      | status: :active,
        detached: payload["detached"] == true,
        source_revision: safe_reference(payload["source_revision"]),
        completed_at: event["occurred_at"]
    })
  end

  defp maybe_record_review(proof, "review.completed", payload, event) do
    put_in(proof, [:review], %{
      proof.review
      | status: normalize_review_status(payload["status"]),
        detached: payload["detached"] == true,
        source_revision: safe_reference(payload["source_revision"]),
        completed_at: event["occurred_at"]
    })
  end

  defp maybe_record_review(proof, _type, _payload, _event), do: proof

  defp maybe_record_evidence(proof, "evidence.sealed", payload) do
    reference = safe_reference(payload["manifest_hash"] || payload["manifest_id"])

    if reference do
      evidence = %{
        label: "Evidence manifest",
        summary: if(payload["current"] == true, do: "Current sealed evidence", else: "Historical evidence"),
        reference: reference,
        current: payload["current"] == true,
        sealed: payload["sealed"] == true
      }

      Map.update!(proof, :evidence, &[evidence | &1])
    else
      proof
    end
  end

  defp maybe_record_evidence(proof, _type, _payload), do: proof

  defp maybe_record_delivery(proof, "delivery.recorded", payload) do
    commit = safe_reference(payload["commit"])
    pull_request = safe_external_url(payload["pull_request"])

    if commit || pull_request do
      %{proof | delivery: %{commit: commit, pull_request: pull_request}}
    else
      proof
    end
  end

  defp maybe_record_delivery(proof, _type, _payload), do: proof

  defp maybe_record_handoff(proof, "tracker.handoff.confirmed", payload, event) do
    if payload["status"] in [nil, "confirmed", "pass", "passed"] do
      %{proof | tracker_handoff: %{status: :confirmed, confirmed_at: event["occurred_at"]}}
    else
      proof
    end
  end

  defp maybe_record_handoff(proof, _type, _payload, _event), do: proof

  defp maybe_record_completion(proof, "run.completed", payload) do
    %{proof | completion_event?: payload["status"] in [nil, "completed", "pass", "passed"]}
  end

  defp maybe_record_completion(proof, _type, _payload), do: proof

  defp outcome(proof, delivery, tracker_handoff) do
    checks_passed? = proof.checks != [] and Enum.all?(proof.checks, &(&1.status == :passed))
    review_passed? = proof.review.status == :passed and proof.review.detached
    evidence_current? = Enum.any?(proof.evidence, &(&1.current and &1.sealed))
    delivery_recorded? = is_map(delivery) and (is_binary(delivery.commit) or is_binary(delivery.pull_request))
    handoff_confirmed? = tracker_handoff.status == :confirmed

    conditions = [
      {checks_passed?, "runtime proof does not include checks that passed"},
      {review_passed?, "detached independent review has not passed"},
      {evidence_current?, "current sealed evidence is unavailable"},
      {delivery_recorded?, "commit or pull-request delivery is unavailable"},
      {handoff_confirmed?, "tracker handoff is unconfirmed"},
      {proof.completion_event?, "the completion reducer has not emitted run.completed"}
    ]

    case Enum.reject(conditions, &elem(&1, 0)) do
      [] ->
        %{
          status: :complete,
          reason: "Required checks passed, detached review passed, current evidence is sealed, delivery is recorded, and tracker handoff is confirmed."
        }

      missing ->
        reason = Enum.map_join(missing, "; ", &elem(&1, 1))
        %{status: :incomplete, reason: "Incomplete: " <> reason <> "."}
    end
  end

  defp projected_state(_runtime_state, %{outcome: %{status: :complete}}), do: {:completed, :outcome}

  defp projected_state(:blocked, _proof), do: {:blocked, :executing}

  defp projected_state(runtime_state, proof) do
    cond do
      proof.review.status == :active -> {:reviewing, :reviewing}
      Enum.any?(proof.checks, &(&1.status == :active)) -> {:validating, :validating}
      runtime_state == :incomplete -> {:incomplete, :outcome}
      true -> {runtime_state, phase_for(runtime_state)}
    end
  end

  defp projected_blocker(_run, %{outcome: %{status: :complete}}), do: nil
  defp projected_blocker(run, _proof), do: run.blocker

  defp projected_next_action(_run, %{outcome: %{status: :complete}}), do: "Inspect the sealed outcome and delivery evidence."
  defp projected_next_action(run, _proof), do: run.next_action

  defp latest_activity(nil, fallback), do: fallback
  defp latest_activity(activity, _fallback), do: activity.summary

  defp check_summary([]), do: "Checks not reported"

  defp check_summary(checks) do
    passed = Enum.count(checks, &(&1.status == :passed))
    active = Enum.count(checks, &(&1.status == :active))
    failed = length(checks) - passed - active
    "#{passed} passed · #{active} active · #{failed} failed"
  end

  defp review_summary(%{status: :not_run}), do: "Independent review not reported"
  defp review_summary(%{status: status, detached: true}), do: "Detached review #{human_status(status)}"
  defp review_summary(%{status: status}), do: "Review #{human_status(status)} · not detached"

  defp event_phase(type) when is_binary(type) do
    cond do
      String.starts_with?(type, "quality.") -> :validating
      String.starts_with?(type, "review.") -> :reviewing
      String.starts_with?(type, ["evidence.", "delivery.", "tracker.handoff", "run.completed"]) -> :outcome
      String.starts_with?(type, "worker.") -> :workspace
      true -> :executing
    end
  end

  defp event_phase(_type), do: :executing

  defp event_label("worker.attempt.started"), do: "Symphony admitted the issue"
  defp event_label("worker.attempt.exited"), do: "Worker attempt exited"
  defp event_label("quality.check.started"), do: "Deterministic check started"
  defp event_label("quality.check.completed"), do: "Deterministic check completed"
  defp event_label("review.started"), do: "Independent review started"
  defp event_label("review.completed"), do: "Independent review completed"
  defp event_label("review.finding"), do: "Review finding recorded"
  defp event_label("evidence.sealed"), do: "Evidence manifest sealed"
  defp event_label("delivery.recorded"), do: "Delivery recorded"
  defp event_label("tracker.handoff.confirmed"), do: "Tracker handoff confirmed"
  defp event_label("run.completed"), do: "Completion reducer accepted the run"

  defp event_label(type) when is_binary(type) do
    type |> String.replace(".", " ") |> String.capitalize()
  end

  defp event_label(_type), do: "Runtime event"

  defp event_summary(type, payload) do
    bounded_text(
      payload["summary"] || payload["command"] || payload["title"] || payload["path"],
      500,
      event_label(type)
    )
  end

  defp event_result(_type, "error", _payload), do: :failed
  defp event_result(_type, "critical", _payload), do: :failed

  defp event_result(type, _severity, payload) do
    normalize_status(payload["status"], if(String.ends_with?(type, ".completed"), do: :passed, else: :active))
  end

  defp event_effect(type) when type in ["delivery.recorded", "tracker.handoff.confirmed"], do: :external_write
  defp event_effect(type) when type in ["operation.command.started", "operation.command.completed"], do: :workspace
  defp event_effect(_type), do: :recorded

  defp normalize_check_status("quality.check.started", _status, _severity), do: :active
  defp normalize_check_status(_type, _status, severity) when severity in ["error", "critical"], do: :failed
  defp normalize_check_status(_type, status, _severity), do: normalize_status(status, :passed)

  defp normalize_review_status(status) when status in ["pass", "passed", "clean"], do: :passed
  defp normalize_review_status(status) when status in ["blocked", "fail", "failed", "rejected"], do: :failed
  defp normalize_review_status(_status), do: :incomplete

  defp normalize_status(status, _default) when status in ["pass", "passed", "complete", "completed", "success"], do: :passed
  defp normalize_status(status, _default) when status in ["active", "running", "started", "pending"], do: :active
  defp normalize_status(status, _default) when status in ["blocked", "fail", "failed", "error"], do: :failed
  defp normalize_status("changed", _default), do: :changed
  defp normalize_status(_status, default), do: default

  defp human_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp safe_event_path(path) when is_binary(path) and path != "" do
    path = if(Path.type(path) == :absolute, do: Path.basename(path), else: Path.expand(path, "/") |> Path.relative_to("/"))

    if String.starts_with?(path, "../") or path in [".", ".."], do: nil, else: bounded_text(path, 500, nil)
  end

  defp safe_event_path(_path), do: nil

  defp safe_reference(value) when is_binary(value) and value != "" do
    if String.valid?(value) and byte_size(value) <= 512 and not String.contains?(value, ["\n", "\r", <<0>>]),
      do: value,
      else: nil
  end

  defp safe_reference(_value), do: nil

  defp bounded_text(value, max, fallback) when is_binary(value) do
    if String.valid?(value) and String.trim(value) != "" do
      value |> String.trim() |> String.slice(0, max)
    else
      fallback
    end
  end

  defp bounded_text(_value, _max, fallback), do: fallback

  defp phase_rail(current_phase, run_state) do
    phases = [:admitted, :workspace, :executing, :validating, :reviewing, :outcome]
    current_index = Enum.find_index(phases, &(&1 == current_phase)) || 0

    Enum.with_index(phases, fn phase, index ->
      status =
        cond do
          index < current_index -> :passed
          index > current_index -> :pending
          run_state == :blocked -> :blocked
          run_state == :incomplete -> :failed
          run_state == :completed -> :passed
          true -> :active
        end

      %{key: phase, label: phase_label(phase), status: status}
    end)
  end

  defp setup_page do
    readiness_path = web_config(:studio_readiness_path, @readiness_path)
    current_revision = current_revision()

    case read_json(readiness_path) do
      {:ok, manifest} -> setup_from_manifest(manifest, readiness_path, current_revision)
      {:error, reason} -> setup_unavailable(reason, current_revision)
    end
  end

  defp setup_from_manifest(manifest, readiness_path, current_revision) do
    manifest_revision = string_path(manifest, ["checkout", "headCommit"])
    runtime_ready? = string_path(manifest, ["runtime", "overall"]) == "pass"
    revision_current? = is_binary(current_revision) and current_revision == manifest_revision
    linear_state = live_linear_state(manifest)
    model = manifest |> model_status() |> live_model_status()
    ready? = runtime_ready? and revision_current? and linear_state == :pass and model.status == :pass
    checked_at = file_timestamp(readiness_path)
    {verdict, verdict_label} = setup_verdict(ready?)

    %{
      kind: :setup,
      verdict: verdict,
      verdict_label: verdict_label,
      reason: setup_reason(runtime_ready?, revision_current?, linear_state, model.status),
      checked_at: checked_at,
      source_revision: manifest_revision,
      current_revision: current_revision,
      rows: setup_rows(manifest, current_revision, revision_current?, runtime_ready?, linear_state, model, checked_at)
    }
  end

  defp setup_rows(manifest, current_revision, revision_current?, runtime_ready?, linear_state, model, checked_at) do
    [
      setup_row(
        "Repository",
        readiness_state(revision_current?),
        repository_label(),
        short_revision(current_revision),
        checked_at,
        repository_remediation(revision_current?)
      ),
      setup_row(
        "Linear project",
        linear_state,
        "Dedicated project binding",
        short_binding(string_path(manifest, ["capabilities", "linear", "configuredProjectBinding"])),
        checked_at,
        "Run the protected readiness check when the project binding changes."
      ),
      setup_row(
        "Codex authentication",
        authentication_state(manifest),
        "ChatGPT authentication",
        auth_status(manifest),
        checked_at,
        "Authenticate the pinned Codex CLI and rerun readiness."
      ),
      setup_row(
        "Compatibility",
        compatibility_state(manifest),
        "Pinned Codex",
        string_path(manifest, ["codex", "version"]) || "Unavailable",
        checked_at,
        "Install codex-cli 0.144.3 and verify the generated schema bundle."
      ),
      setup_row(
        "Runtime selection",
        model.status,
        "GPT-5.6 Sol",
        model.value,
        checked_at,
        "Select GPT-5.6 Sol with Ultra reasoning and rerun capability discovery."
      ),
      setup_row(
        "Readiness evidence",
        readiness_state(runtime_ready?),
        "Deterministic readiness",
        readiness_value(runtime_ready?),
        checked_at,
        "Run the readiness publisher and use only its verified result."
      )
    ]
  end

  defp setup_verdict(true), do: {:ready, "Ready"}
  defp setup_verdict(false), do: {:not_ready, "Not ready"}
  defp readiness_state(true), do: :pass
  defp readiness_state(false), do: :fail
  defp readiness_value(true), do: "Passed"
  defp readiness_value(false), do: "Failed"
  defp repository_remediation(true), do: "No action needed."
  defp repository_remediation(false), do: "Regenerate readiness evidence for this checkout."

  defp authentication_state(manifest) do
    manifest
    |> string_path(["capabilities", "auth", "referenceProfile", "chatgptAuthentication"])
    |> then(&readiness_state(not is_nil(&1) and &1 != false))
  end

  defp compatibility_state(manifest) do
    readiness_state(string_path(manifest, ["codex", "version"]) == "0.144.3")
  end

  defp setup_unavailable(reason, current_revision) do
    checked_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      kind: :setup,
      verdict: :not_ready,
      verdict_label: "Not ready",
      reason: "Readiness evidence is unavailable.",
      checked_at: checked_at,
      source_revision: nil,
      current_revision: current_revision,
      rows: [
        setup_row(
          "Readiness evidence",
          :fail,
          "Implementation readiness",
          "Unavailable",
          checked_at,
          "Generate the machine-readable readiness artifact before starting managed work.",
          %{reason: to_string(reason)}
        )
      ]
    }
  end

  defp setup_row(system, state, label, value, checked_at, remediation, evidence \\ %{}) do
    %{
      system: system,
      state: state,
      state_label: setup_state_label(state),
      label: label,
      value: value,
      checked_at: checked_at,
      remediation: remediation,
      evidence: evidence
    }
  end

  defp empty_intent_page do
    %{
      kind: :new_work,
      service: if(intent_service_available?(), do: :available, else: :unavailable),
      schema_version: nil,
      intent_id: nil,
      lifecycle_state: "new",
      project: %{project_id: nil, label: repository_label()},
      inspection: nil,
      clarifications: %{status: "not_required", questions: [], answers: %{}},
      proposal: nil,
      publication: %{
        status: "not_started",
        proposal_digest: nil,
        tasks: [],
        relations: 0,
        relation_entries: [],
        last_error: nil
      },
      start: %{
        status: "not_started",
        task_id: nil,
        issue_id: nil,
        issue_identifier: nil,
        confirmation: nil,
        provider: nil,
        idempotency_key: nil,
        last_error: nil
      },
      admission: nil,
      events: []
    }
  end

  defp intent_page(snapshot) when is_map(snapshot) do
    project = string_map(snapshot["project"])
    inspection = normalize_inspection(snapshot["inspection"])
    clarifications = normalize_clarifications(snapshot["clarifications"])
    proposal = normalize_proposal(snapshot["proposal"])
    publication = normalize_publication(snapshot["publication"])

    %{
      kind: :new_work,
      service: :available,
      schema_version: snapshot["schema_version"],
      intent_id: snapshot["intent_id"],
      lifecycle_state: snapshot["lifecycle_state"] || "unknown",
      project: %{
        project_id: project["project_id"],
        label: project_label(project)
      },
      source: string_map(snapshot["source"]),
      inspection: inspection,
      clarifications: clarifications,
      proposal: proposal,
      publication: publication,
      start: normalize_start(snapshot["start"]),
      admission: normalize_admission(snapshot["admission"]),
      events: normalize_events(snapshot["events"])
    }
  end

  defp normalize_inspection(nil), do: nil

  defp normalize_inspection(value) do
    inspection = string_map(value)

    %{
      digest: inspection["digest"],
      file_count: inspection["file_count"],
      test_file_count: inspection["test_file_count"],
      architecture_paths: safe_paths(inspection["architecture_paths"]),
      spec_paths: safe_paths(inspection["spec_paths"]),
      headings: bounded_strings(inspection["headings"], 12)
    }
  end

  defp normalize_clarifications(value) do
    clarifications = string_map(value)

    questions =
      clarifications
      |> Map.get("questions", [])
      |> list_of_maps()
      |> Enum.take(2)
      |> Enum.map(fn question ->
        %{
          id: question["id"],
          prompt: question["prompt"],
          impact: question["impact"],
          options: bounded_strings(question["options"], 5),
          recommended_answer: question["recommended_answer"]
        }
      end)

    %{
      status: clarifications["status"] || "not_required",
      questions: questions,
      answers: string_map(clarifications["answers"])
    }
  end

  defp normalize_proposal(nil), do: nil

  defp normalize_proposal(value) do
    proposal = string_map(value)

    tasks =
      proposal
      |> Map.get("tasks", [])
      |> list_of_maps()
      |> Enum.take(8)
      |> Enum.map(fn task ->
        %{
          id: task["id"],
          position: task["position"],
          title: task["title"],
          description: task["description"],
          acceptance_criteria: bounded_strings(task["acceptance_criteria"], 12),
          depends_on: bounded_strings(task["depends_on"], 8),
          source_refs: safe_paths(task["source_refs"])
        }
      end)

    %{
      version: proposal["version"],
      digest: proposal["digest"],
      status: proposal["status"] || "proposed",
      tasks: tasks
    }
  end

  defp normalize_publication(value) do
    publication = string_map(value)

    tasks =
      publication
      |> Map.get("tasks", %{})
      |> string_map()
      |> Enum.map(fn {task_id, task_value} ->
        task = string_map(task_value)

        %{
          task_id: task_id,
          status: task["status"] || "not_started",
          idempotency_key: task["idempotency_key"],
          issue_id: task["issue_id"],
          issue_identifier: task["issue_identifier"],
          provider: task["provider"],
          last_error: normalize_public_error(task["last_error"])
        }
      end)
      |> Enum.sort_by(& &1.task_id)

    relations =
      publication
      |> Map.get("relations", %{})
      |> string_map()
      |> Enum.map(fn {relation_id, relation_value} ->
        relation = string_map(relation_value)

        %{
          relation_id: relation_id,
          dependent_task_id: relation["dependent_task_id"],
          prerequisite_task_id: relation["prerequisite_task_id"],
          external_id: relation["external_id"],
          provider: relation["provider"],
          status: relation["status"] || "pending",
          last_error: normalize_public_error(relation["last_error"])
        }
      end)
      |> Enum.sort_by(& &1.relation_id)

    %{
      status: publication["status"] || "not_started",
      proposal_digest: publication["proposal_digest"],
      tasks: tasks,
      relations: length(relations),
      relation_entries: relations,
      last_error: normalize_public_error(publication["last_error"])
    }
  end

  defp normalize_start(value) do
    start = string_map(value)

    %{
      status: start["status"] || "not_started",
      task_id: start["task_id"],
      issue_id: start["issue_id"],
      issue_identifier: start["issue_identifier"],
      confirmation: start["confirmation"],
      provider: start["provider"],
      idempotency_key: start["idempotency_key"],
      last_error: normalize_public_error(start["last_error"])
    }
  end

  defp normalize_admission(nil), do: nil

  defp normalize_admission(value) do
    admission = string_map(value)

    %{
      event_id: admission["event_id"],
      event_type: admission["event_type"],
      run_id: admission["run_id"],
      attempt_id: admission["attempt_id"],
      issue_id: admission["issue_id"],
      observed_at: admission["observed_at"]
    }
  end

  defp normalize_events(values) do
    values
    |> list_of_maps()
    |> Enum.take(-12)
    |> Enum.map(fn event ->
      %{
        sequence: event["sequence"],
        event_id: event["event_id"],
        type: event["type"],
        occurred_at: event["occurred_at"]
      }
    end)
  end

  defp intent_command(function, leading_args, context) do
    with intent_id when is_binary(intent_id) <- Map.get(context, :intent_id),
         command_id when is_binary(command_id) <- Map.get(context, :command_id),
         {:ok, snapshot} <-
           intent_call(function, [intent_id | leading_args] ++ [command_id, []]) do
      {:ok, intent_page(snapshot)}
    else
      nil -> error("intent_context_missing", "Reload New Work and try again.")
      {:error, _error} = result -> result
    end
  end

  defp intent_call(function, args) do
    service = intent_service()
    args = List.update_at(args, -1, &Keyword.merge(&1, intent_service_options()))

    if intent_service_available?() and function_exported?(service, function, length(args)) do
      service
      |> apply(function, args)
      |> normalize_intent_result()
    else
      error(
        "intent_service_unavailable",
        "Intent planning is not available in this build. Install the Intent Service package and retry."
      )
    end
  rescue
    error ->
      error(
        "intent_service_failed",
        "The Intent Service failed before a public result was available.",
        %{exception: error.__struct__ |> Module.split() |> List.last()}
      )
  catch
    :exit, _reason ->
      error(
        "intent_service_unavailable",
        "The Intent Service stopped before a public result was available."
      )
  end

  defp normalize_intent_result({:ok, snapshot}) when is_map(snapshot), do: {:ok, snapshot}

  defp normalize_intent_result({:error, error}) when is_map(error) do
    normalized = normalize_public_error(error)

    if normalized.code in ["publication_uncertain", "start_uncertain", "external_result_uncertain"] do
      {:uncertain, normalized}
    else
      {:error, normalized}
    end
  end

  defp normalize_intent_result(_result) do
    error("intent_service_invalid_result", "The Intent Service returned an invalid public result.")
  end

  defp normalize_public_error(nil), do: nil

  defp normalize_public_error(error) when is_map(error) do
    %{
      code: to_string(error[:code] || error["code"] || "unknown_error"),
      message: error[:message] || error["message"] || "The action could not be completed.",
      details: string_map(error[:details] || error["details"]),
      resumable: error[:resumable] || error["resumable"] || false
    }
  end

  defp normalize_public_error(_error) do
    %{code: "unknown_error", message: "The action could not be completed.", details: %{}, resumable: false}
  end

  defp error(code, message, details \\ %{}) do
    {:error, %{code: code, message: message, details: details}}
  end

  defp usage(nil), do: nil

  defp usage(values) when is_map(values) do
    input = Map.get(values, :input_tokens) || Map.get(values, "input_tokens")
    output = Map.get(values, :output_tokens) || Map.get(values, "output_tokens")
    total = Map.get(values, :total_tokens) || Map.get(values, "total_tokens")

    if Enum.any?([input, output, total], &(is_integer(&1) and &1 > 0)) do
      %{input_tokens: input, output_tokens: output, total_tokens: total}
    else
      nil
    end
  end

  defp usage(_values), do: nil

  defp runtime_activity(entry, state) do
    Map.get(entry, :last_message) ||
      case {state, Map.get(entry, :last_event)} do
        {:queued, _event} -> "Waiting for the retry window"
        {_state, event} when not is_nil(event) -> to_string(event)
        _ -> "No meaningful activity reported"
      end
  end

  defp runtime_blocker(entry, :blocked), do: Map.get(entry, :error) || "Operator input is required."
  defp runtime_blocker(_entry, _state), do: nil

  defp runtime_next_action(entry, :blocked), do: Map.get(entry, :error) || "Resolve the reported blocker."
  defp runtime_next_action(entry, :queued), do: "Symphony will retry at #{Map.get(entry, :due_at) || "the scheduled retry window"}."
  defp runtime_next_action(_entry, :active), do: "Inspect current activity and evidence."
  defp runtime_next_action(_entry, _state), do: "Open Run Detail."

  defp state_label(:active), do: "Active"
  defp state_label(:queued), do: "Queued"
  defp state_label(:blocked), do: "Blocked"
  defp state_label(:validating), do: "Validating"
  defp state_label(:reviewing), do: "Reviewing"
  defp state_label(:completed), do: "Completed"
  defp state_label(:incomplete), do: "Incomplete"
  defp state_label(state), do: state |> to_string() |> String.capitalize()

  defp phase_for(:active), do: :executing
  defp phase_for(:queued), do: :admitted
  defp phase_for(:blocked), do: :executing
  defp phase_for(:validating), do: :validating
  defp phase_for(:reviewing), do: :reviewing
  defp phase_for(_state), do: :outcome

  defp phase_label(:admitted), do: "Admitted"
  defp phase_label(:workspace), do: "Workspace"
  defp phase_label(:executing), do: "Executing"
  defp phase_label(:validating), do: "Validating"
  defp phase_label(:reviewing), do: "Reviewing"
  defp phase_label(:outcome), do: "Outcome"

  defp manifest_status(manifest, path) do
    if string_path(manifest, path) == "pass", do: :pass, else: :fail
  end

  defp auth_status(manifest) do
    case string_path(manifest, ["capabilities", "auth", "mode"]) do
      "chatgpt" -> "Available"
      _ -> "Unavailable"
    end
  end

  defp model_status(manifest) do
    sol =
      manifest
      |> string_path(["capabilities", "models"])
      |> case do
        models when is_list(models) -> Enum.find(models, &(&1["id"] == "gpt-5.6-sol"))
        _ -> nil
      end

    if is_map(sol) and "ultra" in List.wrap(sol["reasoningEfforts"]) do
      %{status: :pass, value: "Ultra reasoning verified"}
    else
      %{status: :fail, value: "Ultra reasoning unavailable"}
    end
  end

  defp live_linear_state(manifest) do
    manifest_state = manifest_status(manifest, ["capabilities", "linear", "project", "status"])

    with :pass <- manifest_state,
         settings <- Config.settings!(),
         "linear" <- settings.tracker.kind,
         @preview_project_slug <- settings.tracker.project_slug do
      :pass
    else
      _mismatch -> :fail
    end
  rescue
    _error -> :fail
  end

  defp live_model_status(%{status: :pass} = status) do
    if configured_conductor() == "GPT-5.6 Sol Ultra" do
      status
    else
      %{status: :fail, value: "Configured workflow is not GPT-5.6 Sol Ultra"}
    end
  end

  defp live_model_status(status), do: status

  defp setup_reason(true, true, :pass, :pass),
    do: "Repository, Linear, Codex, and runtime evidence match this checkout."

  defp setup_reason(true, false, _linear_state, _model_state),
    do: "Readiness passed for a different source revision."

  defp setup_reason(_runtime_ready?, _revision_current?, :fail, _model_state),
    do: "The active workflow is not bound to the verified dedicated Linear project."

  defp setup_reason(_runtime_ready?, _revision_current?, _linear_state, :fail),
    do: "The active workflow does not select GPT-5.6 Sol with Ultra reasoning."

  defp setup_reason(false, _revision_current?, _linear_state, _model_state),
    do: "At least one required readiness check failed."

  defp setup_state_label(:pass), do: "Pass"
  defp setup_state_label(:warning), do: "Warning"
  defp setup_state_label(:checking), do: "Checking"
  defp setup_state_label(_state), do: "Fail"

  defp read_json(path) do
    case File.read(path) do
      {:ok, body} -> Jason.decode(body)
      {:error, _reason} = error -> error
    end
  end

  defp file_timestamp(path) do
    with {:ok, stat} <- File.stat(path, time: :posix),
         {:ok, datetime} <- DateTime.from_unix(stat.mtime) do
      datetime |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end

  defp current_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: @project_root, stderr_to_stdout: true) do
      {revision, 0} ->
        revision = String.trim(revision)

        case System.cmd("git", ["status", "--porcelain", "--untracked-files=no"],
               cd: @project_root,
               stderr_to_stdout: true
             ) do
          {"", 0} -> revision
          {_changes, 0} -> "#{revision}+changes"
          _ -> revision
        end

      _ ->
        nil
    end
  rescue
    _error -> nil
  end

  defp repository_label do
    web_config(:studio_repository_label, "Symphony Studio")
  end

  defp project_label(project) do
    case project["root"] do
      root when is_binary(root) and root != "" -> Path.basename(root)
      _ -> repository_label()
    end
  end

  defp safe_paths(values) do
    values
    |> bounded_strings(12)
    |> Enum.map(fn value ->
      if Path.type(value) == :absolute, do: Path.basename(value), else: value
    end)
  end

  defp bounded_strings(values, limit) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.take(limit)
  end

  defp bounded_strings(_values, _limit), do: []

  defp list_of_maps(values) when is_list(values), do: Enum.filter(values, &is_map/1)
  defp list_of_maps(_values), do: []

  defp string_map(value) when is_map(value), do: value
  defp string_map(_value), do: %{}

  defp string_path(value, []), do: value

  defp string_path(value, [key | rest]) when is_map(value) do
    string_path(Map.get(value, key), rest)
  end

  defp string_path(_value, _path), do: nil

  defp short_revision(revision) when is_binary(revision) do
    case String.split(revision, "+changes", parts: 2) do
      [head, _changes] when byte_size(head) >= 12 -> "#{binary_part(head, 0, 12)} · changes"
      [head] when byte_size(head) >= 12 -> binary_part(head, 0, 12)
      _ -> "Unavailable"
    end
  end

  defp short_revision(_revision), do: "Unavailable"

  defp short_binding("linear-project-v1-" <> digest) when byte_size(digest) >= 10,
    do: "Verified · #{binary_part(digest, 0, 10)}"

  defp short_binding(_binding), do: "Unavailable"

  defp safe_external_url(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp safe_external_url(_url), do: nil

  defp configured_conductor do
    with settings <- Config.settings!(),
         argv when is_list(argv) <- OptionParser.split(settings.codex.command),
         "gpt-5.6-sol" <- command_config(argv, "model"),
         "ultra" <- command_config(argv, "model_reasoning_effort") do
      "GPT-5.6 Sol Ultra"
    else
      _other -> "Configured Codex conductor unavailable"
    end
  rescue
    _error -> "Configured Codex conductor unavailable"
  end

  defp command_config(argv, key) do
    argv
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--config", value] -> parse_command_config(value, key)
      _other -> nil
    end)
  end

  defp parse_command_config(value, key) do
    prefix = key <> "="

    if String.starts_with?(value, prefix) do
      value
      |> String.replace_prefix(prefix, "")
      |> String.trim(~s("))
    end
  end

  defp isolated_workspace?(path) when is_binary(path) do
    root = Config.settings!().workspace.root |> Path.expand()
    expanded = Path.expand(path)
    relative = Path.relative_to(expanded, root)
    relative not in [".", ".."] and not String.starts_with?(relative, "../")
  rescue
    _error -> false
  end

  defp isolated_workspace?(_path), do: false

  defp intent_store do
    case intent_data_root() do
      root when is_binary(root) -> Store.open(root: root)
      nil -> {:error, :preview_store_unconfigured}
    end
  end

  defp intent_service_options do
    data_options =
      case intent_data_root() do
        root when is_binary(root) -> [data_root: root]
        nil -> []
      end

    Keyword.put(data_options, :broker, web_config(:studio_linear_write_broker, Linear.target()))
  end

  defp intent_data_root do
    web_config(:studio_intent_data_root, preview_intent_data_root())
  end

  defp preview_intent_data_root do
    case System.get_env("SYMPHONY_STUDIO_DATA_ROOT") do
      root when is_binary(root) and root != "" ->
        if Path.type(root) == :absolute, do: Path.join(root, "intent")

      _unset ->
        nil
    end
  end

  defp intent_service, do: web_config(:studio_intent_service, @intent_service)
  defp intent_service_available?, do: Code.ensure_loaded?(intent_service())

  defp event_sink do
    web_config(:studio_event_sink, EventSink.default_target())
  end

  defp orchestrator, do: web_config(:orchestrator, SymphonyElixir.Orchestrator)
  defp snapshot_timeout_ms, do: web_config(:snapshot_timeout_ms, 15_000)

  defp web_config(key, default) do
    Endpoint.config(key, default)
  rescue
    ArgumentError ->
      :symphony_elixir
      |> Application.get_env(Endpoint, [])
      |> Keyword.get(key, default)
  end
end
