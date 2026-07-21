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

  alias SymphonyElixirWeb.{Endpoint, Presenter}

  @intent_service SymphonyElixir.Studio.IntentService
  @project_root Path.expand("../../..", __DIR__)
  @readiness_path Path.join(@project_root, "artifacts/readiness/implementation-readiness.json")

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
    runs =
      Enum.map(payload.running, &runtime_run(&1, :active)) ++
        Enum.map(payload.blocked, &runtime_run(&1, :blocked)) ++
        Enum.map(payload.retrying, &runtime_run(&1, :queued))

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
      issue_identifier: entry.issue_identifier,
      issue_url: safe_external_url(entry.issue_url),
      objective: "Objective unavailable in the current runtime snapshot",
      state: state,
      state_label: state_label(state),
      phase: phase_for(state),
      phase_label: phase_label(phase_for(state)),
      conductor: "Conductor receipt unavailable",
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
      raw_state: Map.get(entry, :state)
    }
  end

  defp run_page(run, mission) do
    %{
      kind: :run_detail,
      source: :runtime_projection,
      generated_at: mission.generated_at,
      freshness: mission.freshness,
      run: Map.put(run, :phase_rail, phase_rail(run.phase, run.state)),
      acceptance_criteria: [],
      scope: [],
      plan: [],
      activity: runtime_activity_rows(run),
      changes: [],
      checks: [],
      review: %{status: :not_run, findings: [], source_revision: nil, completed_at: nil},
      evidence: [],
      outcome: %{
        status: :incomplete,
        reason: "The current runtime snapshot does not include checks, independent review, and terminal evidence."
      }
    }
  end

  defp runtime_activity_rows(run) do
    if run.latest_activity in [nil, "", "No meaningful activity reported"] do
      []
    else
      [
        %{
          phase: run.phase,
          label: "Codex update",
          summary: run.latest_activity,
          occurred_at: run.latest_activity_at,
          result: run.state,
          effect: :read
        }
      ]
    end
  end

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
    ready? = runtime_ready? and revision_current?
    model = model_status(manifest)
    checked_at = file_timestamp(readiness_path)
    {verdict, verdict_label} = setup_verdict(ready?)

    %{
      kind: :setup,
      verdict: verdict,
      verdict_label: verdict_label,
      reason: setup_reason(runtime_ready?, revision_current?),
      checked_at: checked_at,
      source_revision: manifest_revision,
      current_revision: current_revision,
      rows: setup_rows(manifest, current_revision, revision_current?, runtime_ready?, model, checked_at)
    }
  end

  defp setup_rows(manifest, current_revision, revision_current?, runtime_ready?, model, checked_at) do
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
        manifest_status(manifest, ["capabilities", "linear", "project", "status"]),
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

  defp setup_reason(true, true), do: "Repository, Linear, Codex, and runtime evidence match this checkout."
  defp setup_reason(true, false), do: "Readiness passed for a different source revision."
  defp setup_reason(false, _revision_current?), do: "At least one required readiness check failed."

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

  defp intent_service, do: web_config(:studio_intent_service, @intent_service)
  defp intent_service_available?, do: Code.ensure_loaded?(intent_service())

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
