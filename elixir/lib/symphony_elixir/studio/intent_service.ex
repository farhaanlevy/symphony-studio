# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.IntentService do
  @moduledoc """
  Canonical Intent Service shared by future Studio UI and local STDIO MCP.

  The service owns read-only project grounding, one clarification batch,
  deterministic proposal presentation, host-bound approval, resumable brokered
  publication, first-ready start, and linkage to an actual Symphony admission
  event. External mutations are available only to the trusted local host
  boundary; the user-facing MCP liaison is explicitly denied. The service never
  uses the existing query-only Linear credential.
  """

  alias SymphonyElixir.Event
  alias SymphonyElixir.PathSafety
  alias SymphonyElixir.Studio.Intent.{Canonical, Document, Planner, ProjectInspector, Store}
  alias SymphonyElixir.Studio.LinearWriteBroker
  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Result}

  @publish_confirmation "publish_linear_backlog"
  @start_confirmation "start_first_ready"
  @max_source_bytes 256 * 1_024
  @max_answer_bytes 4 * 1_024
  @max_command_id_bytes 160

  @type public_error :: %{
          required(:code) => atom(),
          required(:message) => String.t(),
          required(:details) => map()
        }
  @type result :: {:ok, map()} | {:error, public_error()}

  @doc "Attaches one existing project root without executing project code."
  @spec attach_project(String.t(), String.t(), keyword()) :: result()
  def attach_project(project_root, command_id, opts \\ []) do
    request = %{"command_id" => command_id, "project_root" => project_root}

    with :ok <- validate_command_id(command_id),
         {:ok, context} <- context(opts),
         {:ok, canonical_root} <- canonical_project_root(project_root),
         project_id <- Canonical.id("project_", canonical_root, 24),
         project <- %{
           "project_id" => project_id,
           "root" => canonical_root,
           "schema_version" => 1
         },
         {:ok, stored, _status} <- Store.put_project(context.store, project) do
      {:ok,
       %{
         "command_id" => command_id,
         "lifecycle_state" => "project_attached",
         "project" => stored,
         "request_digest" => Canonical.digest(request),
         "schema_version" => 1
       }}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Submits prompt or Markdown intent, inspects the project, and creates questions or a proposal."
  @spec submit_intent(String.t(), map(), String.t(), keyword()) :: result()
  def submit_intent(project_id, source, command_id, opts \\ []) do
    request = %{"command_id" => command_id, "project_id" => project_id, "source" => source}

    with :ok <- validate_command_id(command_id),
         {:ok, normalized_source} <- normalize_source(source),
         {:ok, context} <- context(opts),
         {:ok, project} <- Store.read_project(context.store, project_id) do
      intent_id = Canonical.id("intent_", [project_id, command_id], 24)

      case Store.read_intent(context.store, intent_id) do
        {:ok, existing} ->
          replay_or_conflict(existing, "studio_submit_intent", command_id, request)

        {:error, :not_found} ->
          create_submitted_intent(context, project, intent_id, normalized_source, command_id, request)

        {:error, reason} ->
          {:error, translate_error(reason)}
      end
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Answers the complete pending clarification batch or accepts every recommended default."
  @spec answer_clarifications(String.t(), map(), String.t(), keyword()) :: result()
  def answer_clarifications(intent_id, answer_input, command_id, opts \\ []) do
    request = %{"answer_input" => answer_input, "command_id" => command_id, "intent_id" => intent_id}

    with :ok <- validate_command_id(command_id),
         {:ok, context} <- context(opts) do
      atomic_command(
        context,
        intent_id,
        "studio_answer_clarifications",
        command_id,
        request,
        fn document, timestamp -> answer_reducer(document, answer_input, timestamp) end
      )
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Explicitly presents the current proposal and its approval-bound digest."
  @spec present_proposal(String.t(), String.t(), keyword()) :: result()
  def present_proposal(intent_id, command_id, opts \\ []) do
    request = %{"command_id" => command_id, "intent_id" => intent_id}

    with :ok <- validate_command_id(command_id),
         {:ok, context} <- context(opts) do
      atomic_command(
        context,
        intent_id,
        "studio_present_proposal",
        command_id,
        request,
        &present_reducer/2
      )
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Records proposal-bound approval from the trusted local host boundary."
  @spec approve_publication(String.t(), String.t(), String.t(), String.t(), keyword()) :: result()
  def approve_publication(intent_id, proposal_digest, confirmation, command_id, opts \\ []) do
    request = %{
      "command_id" => command_id,
      "confirmation" => confirmation,
      "intent_id" => intent_id,
      "proposal_digest" => proposal_digest
    }

    with :ok <- validate_command_id(command_id),
         true <- confirmation == @publish_confirmation,
         true <- valid_digest?(proposal_digest),
         {:ok, context} <- context(opts),
         :ok <- require_trusted_host(context) do
      atomic_command(
        context,
        intent_id,
        "studio_approve_publication",
        command_id,
        request,
        fn document, timestamp -> approve_reducer(document, proposal_digest, confirmation, timestamp) end
      )
    else
      false ->
        {:error,
         error(
           :confirmation_mismatch,
           "Publication requires the exact confirmation publish_linear_backlog."
         )}

      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  @doc "Publishes a host-approved plan idempotently through the injected typed broker."
  @spec publish_approved_plan(String.t(), String.t(), keyword()) :: result()
  def publish_approved_plan(intent_id, command_id, opts \\ []) do
    request = %{"command_id" => command_id, "intent_id" => intent_id}
    tool = "studio_publish_approved_plan"

    with :ok <- validate_command_id(command_id),
         {:ok, context} <- context(opts),
         :ok <- require_trusted_host(context) do
      with_external_operation_lock(context, intent_id, "publication", fn ->
        run_publication_command(context, intent_id, tool, command_id, request)
      end)
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Transitions one ready task to Todo after separate trusted-host confirmation."
  @spec start_first_ready(String.t(), String.t(), String.t(), keyword()) :: result()
  def start_first_ready(intent_id, confirmation, command_id, opts \\ []) do
    request = %{
      "command_id" => command_id,
      "confirmation" => confirmation,
      "intent_id" => intent_id
    }

    tool = "studio_start_first_ready"

    with :ok <- validate_command_id(command_id),
         true <- confirmation == @start_confirmation,
         {:ok, context} <- context(opts),
         :ok <- require_trusted_host(context) do
      with_external_operation_lock(context, intent_id, "start", fn ->
        run_start_command(context, intent_id, confirmation, tool, command_id, request)
      end)
    else
      false ->
        {:error, error(:confirmation_mismatch, "Starting work requires the exact confirmation start_first_ready.")}

      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  @doc "Returns the current durable public projection for one intent."
  @spec get_intent_status(String.t(), keyword()) :: result()
  def get_intent_status(intent_id, opts \\ []) do
    with {:ok, context} <- context(opts),
         {:ok, document} <- Store.read_intent(context.store, intent_id) do
      {:ok, Document.public_snapshot(document)}
    else
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  @doc "Links exact worker.attempt.started events to intents waiting on the same issue ID."
  @spec observe_admission_event(Event.t()) :: {:ok, non_neg_integer()} | {:error, public_error()}
  def observe_admission_event(event), do: observe_admission_event(event, [])

  @spec observe_admission_event(Event.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, public_error()}
  def observe_admission_event(%Event{} = event, opts) do
    case Event.validate(event) do
      :ok -> observe_valid_admission_event(event, opts)
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  def observe_admission_event(_event, _opts),
    do: {:error, error(:invalid_admission_event, "Admission linkage requires a validated Symphony event.")}

  defp create_submitted_intent(context, project, intent_id, source, command_id, request) do
    case ProjectInspector.inspect(project["root"], context.inspector_opts) do
      {:ok, inspection} ->
        persist_submitted_intent(context, project, intent_id, source, command_id, request, inspection)

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  defp persist_submitted_intent(context, project, intent_id, source, command_id, request, inspection) do
    timestamp = now(context)
    questions = Planner.questions(source, inspection)
    proposal = if(questions == [], do: Planner.propose(source, inspection, %{}), else: nil)

    document =
      Document.new(%{
        "created_at" => timestamp,
        "inspection" => inspection,
        "intent_id" => intent_id,
        "project" => project,
        "proposal" => proposal,
        "questions" => questions,
        "source" => source
      })
      |> Document.append_event(
        "intent.submitted",
        %{"source_digest" => source["digest"], "source_kind" => source["kind"]},
        timestamp
      )
      |> Document.append_event(
        "repository.inspected",
        %{
          "file_count" => inspection["file_count"],
          "inspection_digest" => inspection["digest"],
          "test_file_count" => inspection["test_file_count"]
        },
        timestamp
      )
      |> append_initial_planning_event(questions, proposal, timestamp)
      |> Document.record_command("studio_submit_intent", command_id, request, timestamp)

    case Store.create_intent(context.store, document) do
      {:ok, stored, :created} -> {:ok, Document.public_snapshot(stored)}
      {:ok, stored, :existing} -> replay_or_conflict(stored, "studio_submit_intent", command_id, request)
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp append_initial_planning_event(document, [], proposal, timestamp) do
    Document.append_event(
      document,
      "proposal.created",
      %{"proposal_digest" => proposal["digest"], "task_count" => length(proposal["tasks"])},
      timestamp
    )
  end

  defp append_initial_planning_event(document, questions, _proposal, timestamp) do
    Document.append_event(
      document,
      "clarifications.requested",
      %{"question_ids" => Enum.map(questions, & &1["id"])},
      timestamp
    )
  end

  defp replay_or_conflict(document, tool, command_id, request) do
    case Document.command_state(document, tool, command_id, request) do
      :replay -> {:ok, Document.public_snapshot(document)}
      :new -> {:error, error(:command_conflict, "The intent identity already belongs to another command.")}
      {:conflict, details} -> {:error, error(:command_conflict, "Command ID was already used with different input.", details)}
    end
  end

  defp atomic_command(context, intent_id, tool, command_id, request, reducer) do
    timestamp = now(context)

    updater = fn document ->
      apply_atomic_command(document, tool, command_id, request, reducer, timestamp)
    end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp apply_atomic_command(document, tool, command_id, request, reducer, timestamp) do
    case Document.command_state(document, tool, command_id, request) do
      :replay ->
        {:ok, document, Document.public_snapshot(document)}

      {:conflict, details} ->
        {:error, error(:command_conflict, "Command ID was already used with different input.", details)}

      :new ->
        apply_atomic_reducer(document, tool, command_id, request, reducer, timestamp)
    end
  end

  defp apply_atomic_reducer(document, tool, command_id, request, reducer, timestamp) do
    case reducer.(document, timestamp) do
      {:ok, next} ->
        recorded = Document.record_command(next, tool, command_id, request, timestamp)
        {:ok, recorded, Document.public_snapshot(recorded)}

      {:error, _reason} = error ->
        error
    end
  end

  defp answer_reducer(document, answer_input, timestamp) do
    case normalize_answers(document, answer_input) do
      {:ok, answers} -> {:ok, document_with_answers(document, answers, timestamp)}
      {:error, _reason} = error -> error
    end
  end

  defp document_with_answers(document, answers, timestamp) do
    proposal = Planner.propose(document["source"], document["inspection"], answers)

    document
    |> put_in(["clarifications", "answers"], answers)
    |> put_in(["clarifications", "status"], "answered")
    |> Map.put("proposal", proposal)
    |> Document.append_event(
      "clarifications.answered",
      %{"answer_ids" => answers |> Map.keys() |> Enum.sort()},
      timestamp
    )
    |> Document.append_event(
      "proposal.created",
      %{
        "proposal_digest" => proposal["digest"],
        "task_count" => length(proposal["tasks"])
      },
      timestamp
    )
  end

  defp normalize_answers(document, answer_input) do
    questions = get_in(document, ["clarifications", "questions"]) || []

    if get_in(document, ["clarifications", "status"]) != "required" do
      {:error, error(:invalid_lifecycle_state, "This intent has no pending clarification batch.")}
    else
      do_normalize_answers(questions, answer_input)
    end
  end

  defp do_normalize_answers(questions, %{"use_recommended_defaults" => true} = input)
       when map_size(input) == 1,
       do: {:ok, Planner.recommended_answers(questions)}

  defp do_normalize_answers(questions, %{"answers" => answers} = input)
       when map_size(input) == 1 and is_map(answers) do
    expected_ids = questions |> Enum.map(& &1["id"]) |> Enum.sort()
    answer_ids = answers |> Map.keys() |> Enum.sort()

    cond do
      expected_ids != answer_ids ->
        {:error,
         error(
           :incomplete_clarification_batch,
           "All pending clarification questions must be answered in one batch.",
           %{"expected_question_ids" => expected_ids}
         )}

      not Enum.all?(answers, fn {key, value} ->
        is_binary(key) and valid_bounded_text?(value, @max_answer_bytes)
      end) ->
        {:error, error(:invalid_clarification_answers, "Clarification answers must be bounded non-empty text.")}

      true ->
        {:ok, answers}
    end
  end

  defp do_normalize_answers(_questions, _input),
    do: {:error, error(:invalid_clarification_answers, "Provide answers or use_recommended_defaults.")}

  defp present_reducer(document, timestamp) do
    proposal = document["proposal"]

    cond do
      not is_map(proposal) ->
        {:error, error(:proposal_unavailable, "Answer the clarification batch before presenting a proposal.")}

      get_in(document, ["clarifications", "status"]) == "required" ->
        {:error, error(:clarification_required, "Answer the complete clarification batch first.")}

      get_in(document, ["presentation", "proposal_digest"]) == proposal["digest"] ->
        {:ok, document}

      true ->
        presentation = %{
          "approval_confirmation" => @publish_confirmation,
          "presented_at" => timestamp,
          "proposal_digest" => proposal["digest"]
        }

        next =
          document
          |> Map.put("presentation", presentation)
          |> put_in(["proposal", "status"], "presented")
          |> Document.append_event(
            "proposal.presented",
            %{
              "approval_confirmation" => @publish_confirmation,
              "proposal_digest" => proposal["digest"]
            },
            timestamp
          )

        {:ok, next}
    end
  end

  defp approve_reducer(document, proposal_digest, confirmation, timestamp) do
    current_digest = get_in(document, ["proposal", "digest"])
    presented_digest = get_in(document, ["presentation", "proposal_digest"])

    cond do
      is_nil(presented_digest) ->
        {:error, error(:proposal_not_presented, "Present the proposal before approving publication.")}

      current_digest != proposal_digest or presented_digest != proposal_digest ->
        {:error, error(:stale_proposal_digest, "Approval must name the exact currently presented proposal digest.")}

      get_in(document, ["approval", "proposal_digest"]) == proposal_digest ->
        {:ok, document}

      true ->
        approval = %{
          "approved_at" => timestamp,
          "confirmation" => confirmation,
          "proposal_digest" => proposal_digest
        }

        next =
          document
          |> Map.put("approval", approval)
          |> put_in(["proposal", "status"], "approved")
          |> Document.append_event(
            "publication.approved",
            %{"confirmation" => confirmation, "proposal_digest" => proposal_digest},
            timestamp
          )

        {:ok, next}
    end
  end

  defp run_publication_command(context, intent_id, tool, command_id, request) do
    case claim_publication_command(context, intent_id, tool, command_id, request) do
      {:ok, {:replay, snapshot}} ->
        {:ok, snapshot}

      {:ok, :claimed} ->
        finish_publication_attempt(context, intent_id, tool, command_id, request)

      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  defp claim_publication_command(context, intent_id, tool, command_id, request) do
    timestamp = now(context)

    updater = fn document ->
      claim_publication_document(document, intent_id, tool, command_id, request, timestamp)
    end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, result} -> {:ok, result}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp claim_publication_document(document, intent_id, tool, command_id, request, timestamp) do
    case Document.command_state(document, tool, command_id, request) do
      :replay ->
        {:ok, document, {:replay, Document.public_snapshot(document)}}

      {:conflict, details} ->
        {:error, error(:command_conflict, "Command ID was already used with different input.", details)}

      :new ->
        claim_new_publication(document, intent_id, tool, command_id, request, timestamp)
    end
  end

  defp claim_new_publication(document, intent_id, tool, command_id, request, timestamp) do
    with {:ok, proposal} <- approved_proposal(document),
         {:ok, initialized, :ok} <-
           initialize_approved_publication(document, proposal, intent_id, timestamp) do
      claimed =
        initialized
        |> put_in(["publication", "active_command_id"], command_id)
        |> put_in(["publication", "attempt_id"], command_id)
        |> Document.record_command(tool, command_id, request, timestamp)

      {:ok, claimed, :claimed}
    end
  end

  defp finish_publication_attempt(context, intent_id, tool, command_id, request) do
    case publication_loop(context, intent_id, 0) do
      :ok ->
        finish_external_command(context, intent_id, "publication", tool, command_id, request)

      {:error, _reason} = error ->
        release_external_command(context, intent_id, "publication", command_id)
        error
    end
  end

  defp initialize_approved_publication(document, proposal, intent_id, timestamp) do
    publication = document["publication"] || Document.empty_publication()

    cond do
      publication["status"] == "complete" and publication["proposal_digest"] == proposal["digest"] ->
        {:ok, document, :ok}

      publication["proposal_digest"] not in [nil, proposal["digest"]] ->
        {:error, error(:stale_publication, "Publication state belongs to a different proposal digest.")}

      true ->
        {:ok, start_publication(document, publication, proposal, intent_id, timestamp), :ok}
    end
  end

  defp start_publication(document, publication, proposal, intent_id, timestamp) do
    initialized = initialize_publication_entries(publication, proposal, intent_id)
    first_start? = publication["status"] == "not_started"

    document
    |> Map.put("publication", %{initialized | "status" => "in_progress", "last_error" => nil})
    |> maybe_append_event(
      first_start?,
      "publication.started",
      %{"proposal_digest" => proposal["digest"]},
      timestamp
    )
  end

  defp approved_proposal(document) do
    proposal = document["proposal"]
    approval_digest = get_in(document, ["approval", "proposal_digest"])

    cond do
      not is_map(proposal) ->
        {:error, error(:proposal_unavailable, "No proposal is available for publication.")}

      approval_digest != proposal["digest"] ->
        {:error, error(:publication_not_approved, "Approve the currently presented proposal first.")}

      true ->
        {:ok, proposal}
    end
  end

  defp initialize_publication_entries(publication, proposal, intent_id) do
    task_entries =
      Map.new(proposal["tasks"], fn task ->
        existing = get_in(publication, ["tasks", task["id"]])

        entry =
          existing ||
            %{
              "idempotency_key" => Command.issue_key(intent_id, proposal["digest"], task["id"]),
              "issue_id" => nil,
              "issue_identifier" => nil,
              "last_error" => nil,
              "provider" => nil,
              "status" => "pending"
            }

        {task["id"], entry}
      end)

    relation_entries =
      proposal["tasks"]
      |> Enum.flat_map(fn task ->
        Enum.map(task["depends_on"], fn prerequisite_task_id ->
          relation_id = relation_id(task["id"], prerequisite_task_id)
          existing = get_in(publication, ["relations", relation_id])

          entry =
            existing ||
              %{
                "dependent_task_id" => task["id"],
                "external_id" => nil,
                "last_error" => nil,
                "prerequisite_task_id" => prerequisite_task_id,
                "provider" => nil,
                "status" => "pending"
              }

          {relation_id, entry}
        end)
      end)
      |> Map.new()

    publication
    |> Map.put("proposal_digest", proposal["digest"])
    |> Map.put("tasks", task_entries)
    |> Map.put("relations", relation_entries)
  end

  defp publication_loop(_context, _intent_id, actions) when actions >= 64, do: :ok

  defp publication_loop(context, intent_id, actions) do
    case Store.read_intent(context.store, intent_id) do
      {:ok, document} -> publication_step(context, intent_id, actions, document)
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp publication_step(context, intent_id, actions, document) do
    case next_publication_action(document) do
      :complete ->
        complete_publication(context, intent_id)

      {:issue, task} ->
        publication_issue_step(context, intent_id, actions, document, task)

      {:relation, relation_id, entry} ->
        publication_relation_step(context, intent_id, actions, document, relation_id, entry)
    end
  end

  defp publication_issue_step(context, intent_id, actions, document, task) do
    case Command.issue(intent_id, document["proposal"]["digest"], task) do
      {:ok, command} ->
        publication_run_step(context, intent_id, actions, {:issue, task["id"]}, command)

      {:error, _reason} = error ->
        error
    end
  end

  defp publication_relation_step(context, intent_id, actions, document, relation_id, entry) do
    case relation_command(document, relation_id, entry) do
      {:ok, command} ->
        publication_run_step(context, intent_id, actions, {:relation, relation_id}, command)

      {:error, _reason} = error ->
        error
    end
  end

  defp publication_run_step(context, intent_id, actions, action, command) do
    case run_publication_action(context, intent_id, action, command) do
      :ok -> continue_publication(context, intent_id, actions)
      {:error, _reason} = error -> error
    end
  end

  defp continue_publication(context, intent_id, actions) do
    if publication_continuable?(context.store, intent_id),
      do: publication_loop(context, intent_id, actions + 1),
      else: :ok
  end

  defp next_publication_action(document) do
    publication = document["publication"]

    pending_task =
      document["proposal"]["tasks"]
      |> Enum.sort_by(&{&1["position"], &1["id"]})
      |> Enum.find(fn task -> get_in(publication, ["tasks", task["id"], "status"]) != "confirmed" end)

    if pending_task do
      {:issue, pending_task}
    else
      publication["relations"]
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find(fn {_id, entry} -> entry["status"] != "confirmed" end)
      |> case do
        nil -> :complete
        {relation_id, entry} -> {:relation, relation_id, entry}
      end
    end
  end

  defp relation_command(document, _relation_id, entry) do
    task_mappings = document["publication"]["tasks"]
    prerequisite = task_mappings[entry["prerequisite_task_id"]]
    dependent = task_mappings[entry["dependent_task_id"]]

    Command.relation(
      document["intent_id"],
      document["proposal"]["digest"],
      entry["dependent_task_id"],
      prerequisite,
      dependent
    )
  end

  defp run_publication_action(context, intent_id, action, command) do
    case LinearWriteBroker.reconcile(context.broker, command) do
      {:ok, %Result{status: :confirmed} = result} ->
        store_publication_outcome(context, intent_id, action, "confirmed", result, nil, "publication.reconciled")

      {:ok, %Result{status: :absent}} ->
        execute_publication_action(context, intent_id, action, command)

      {:ok, %Result{status: :uncertain} = result} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "uncertain",
          result,
          broker_error(:uncertain_external_outcome),
          "publication.uncertain"
        )

      {:ok, %Result{status: :rejected} = result} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "blocked",
          result,
          broker_error(:broker_rejected),
          "publication.blocked"
        )

      {:error, reason} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "blocked",
          nil,
          broker_error(reason),
          "publication.blocked"
        )
    end
  end

  defp execute_publication_action(context, intent_id, action, command) do
    case LinearWriteBroker.execute(context.broker, command) do
      {:ok, %Result{status: :confirmed} = result} ->
        store_publication_outcome(context, intent_id, action, "confirmed", result, nil, "publication.confirmed")

      {:ok, %Result{status: :uncertain} = result} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "uncertain",
          result,
          broker_error(:uncertain_external_outcome),
          "publication.uncertain"
        )

      {:ok, %Result{} = result} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "blocked",
          result,
          broker_error(:invalid_execution_outcome),
          "publication.blocked"
        )

      {:error, reason} ->
        store_publication_outcome(
          context,
          intent_id,
          action,
          "blocked",
          nil,
          broker_error(reason),
          "publication.blocked"
        )
    end
  end

  defp store_publication_outcome(context, intent_id, action, entry_status, result, failure, event_type) do
    outcome = %{
      action: action,
      entry_status: entry_status,
      event_type: event_type,
      failure: failure,
      result: result,
      timestamp: now(context)
    }

    updater = fn document -> publication_outcome_document(document, outcome) end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, :ok} -> :ok
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp publication_outcome_document(document, outcome) do
    path = publication_path(outcome.action)
    current = get_in(document, path)

    if current["status"] == "confirmed" do
      {:ok, document, :ok}
    else
      {:ok, updated_publication_document(document, path, current, outcome), :ok}
    end
  end

  defp updated_publication_document(document, path, current, outcome) do
    updated_entry =
      publication_entry(current, outcome.action, outcome.entry_status, outcome.result, outcome.failure)

    next = put_in(document, path, updated_entry)
    overall = publication_overall_status(next, outcome.entry_status)

    next
    |> put_in(["publication", "status"], overall)
    |> put_in(["publication", "last_error"], outcome.failure)
    |> Document.append_event(
      outcome.event_type,
      publication_event_data(outcome.action, outcome.entry_status, outcome.result, outcome.failure),
      outcome.timestamp
    )
  end

  defp publication_entry(current, {:issue, _task_id}, "confirmed", result, _failure) do
    current
    |> Map.put("issue_id", result.external_id)
    |> Map.put("issue_identifier", result.issue_identifier)
    |> Map.put("provider", result.provider)
    |> Map.put("status", "confirmed")
    |> Map.put("last_error", nil)
  end

  defp publication_entry(current, {:relation, _relation_id}, "confirmed", result, _failure) do
    current
    |> Map.put("external_id", result.external_id)
    |> Map.put("provider", result.provider)
    |> Map.put("status", "confirmed")
    |> Map.put("last_error", nil)
  end

  defp publication_entry(current, _action, status, result, failure) do
    current
    |> Map.put("provider", if(result, do: result.provider, else: Map.get(current, "provider")))
    |> Map.put("status", status)
    |> Map.put("last_error", failure)
  end

  defp publication_overall_status(_document, "uncertain"), do: "uncertain"

  defp publication_overall_status(document, "blocked") do
    if confirmed_publication_count(document) > 0, do: "partial", else: "blocked"
  end

  defp publication_overall_status(_document, "confirmed"), do: "in_progress"

  defp confirmed_publication_count(document) do
    publication = document["publication"]

    Enum.count(publication["tasks"], fn {_id, entry} -> entry["status"] == "confirmed" end) +
      Enum.count(publication["relations"], fn {_id, entry} -> entry["status"] == "confirmed" end)
  end

  defp publication_path({:issue, task_id}), do: ["publication", "tasks", task_id]
  defp publication_path({:relation, relation_id}), do: ["publication", "relations", relation_id]

  defp publication_event_data(action, status, result, failure) do
    %{
      "action_id" => elem(action, 1),
      "action_kind" => action |> elem(0) |> Atom.to_string(),
      "external_id" => if(result, do: result.external_id, else: nil),
      "issue_identifier" => if(result, do: result.issue_identifier, else: nil),
      "problem" => failure,
      "provider" => if(result, do: result.provider, else: nil),
      "status" => status
    }
  end

  defp publication_continuable?(store, intent_id) do
    case Store.read_intent(store, intent_id) do
      {:ok, document} -> get_in(document, ["publication", "status"]) == "in_progress"
      {:error, _reason} -> false
    end
  end

  defp complete_publication(context, intent_id) do
    timestamp = now(context)

    updater = fn document -> complete_publication_document(document, timestamp) end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, :ok} -> :ok
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp complete_publication_document(document, timestamp) do
    if get_in(document, ["publication", "status"]) == "complete" do
      {:ok, document, :ok}
    else
      {:ok, publication_completed(document, timestamp), :ok}
    end
  end

  defp publication_completed(document, timestamp) do
    document
    |> put_in(["publication", "status"], "complete")
    |> put_in(["publication", "last_error"], nil)
    |> Document.append_event(
      "publication.completed",
      %{
        "proposal_digest" => get_in(document, ["publication", "proposal_digest"]),
        "relation_count" => map_size(get_in(document, ["publication", "relations"])),
        "task_count" => map_size(get_in(document, ["publication", "tasks"]))
      },
      timestamp
    )
  end

  defp run_start_command(context, intent_id, confirmation, tool, command_id, request) do
    case claim_start_command(context, intent_id, confirmation, tool, command_id, request) do
      {:ok, {:replay, snapshot}} ->
        {:ok, snapshot}

      {:ok, {:complete, snapshot}} ->
        {:ok, snapshot}

      {:ok, {:claimed, selection}} ->
        finish_start_attempt(context, intent_id, selection, tool, command_id, request)

      {:error, %{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, translate_error(reason)}
    end
  end

  defp claim_start_command(context, intent_id, confirmation, tool, command_id, request) do
    timestamp = now(context)

    updater = fn document ->
      claim_start_document(document, confirmation, tool, command_id, request, timestamp)
    end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, result} -> {:ok, result}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp claim_start_document(document, confirmation, tool, command_id, request, timestamp) do
    case Document.command_state(document, tool, command_id, request) do
      :replay ->
        {:ok, document, {:replay, Document.public_snapshot(document)}}

      {:conflict, details} ->
        {:error, error(:command_conflict, "Command ID was already used with different input.", details)}

      :new ->
        claim_new_start(document, confirmation, tool, command_id, request, timestamp)
    end
  end

  defp claim_new_start(document, confirmation, tool, command_id, request, timestamp) do
    with previous_status <- get_in(document, ["start", "status"]),
         {:ok, initialized, {:ok, task, mapping}} <-
           initialize_start_document(document, confirmation, timestamp) do
      claim_initialized_start(
        initialized,
        {task, mapping},
        previous_status,
        tool,
        command_id,
        request,
        timestamp
      )
    end
  end

  defp claim_initialized_start(document, _selection, status, tool, command_id, request, timestamp)
       when status in ["waiting_for_admission", "admitted"] do
    recorded = Document.record_command(document, tool, command_id, request, timestamp)
    {:ok, recorded, {:complete, Document.public_snapshot(recorded)}}
  end

  defp claim_initialized_start(document, selection, _status, tool, command_id, request, timestamp) do
    claimed =
      document
      |> put_in(["start", "active_command_id"], command_id)
      |> put_in(["start", "attempt_id"], command_id)
      |> put_in(["start", "last_error"], nil)
      |> put_in(["start", "status"], "in_progress")
      |> Document.record_command(tool, command_id, request, timestamp)

    {:ok, claimed, {:claimed, selection}}
  end

  defp finish_start_attempt(context, intent_id, selection, tool, command_id, request) do
    case run_start_transition(context, intent_id, selection) do
      :ok ->
        finish_external_command(context, intent_id, "start", tool, command_id, request)

      {:error, _reason} = error ->
        release_external_command(context, intent_id, "start", command_id)
        error
    end
  end

  defp initialize_start_document(document, confirmation, timestamp) do
    cond do
      get_in(document, ["publication", "status"]) != "complete" ->
        {:error, error(:publication_incomplete, "The complete approved backlog must be confirmed first.")}

      get_in(document, ["start", "status"]) in ["in_progress", "blocked", "uncertain", "waiting_for_admission", "admitted"] ->
        case start_selection(document) do
          {:ok, _task, _mapping} = selection -> {:ok, document, selection}
          {:error, %{} = error} -> {:error, error}
        end

      true ->
        select_new_start(document, confirmation, timestamp)
    end
  end

  defp select_new_start(document, confirmation, timestamp) do
    case first_ready_task(document) do
      {:ok, task, mapping} -> initialize_selected_start(document, task, mapping, confirmation, timestamp)
      {:error, %{} = error} -> {:error, error}
    end
  end

  defp initialize_selected_start(document, task, mapping, confirmation, timestamp) do
    if LinearWriteBroker.protected_identifier?(mapping["issue_identifier"]) do
      {:error, error(:protected_linear_issue_denied, "SYM-1 and SYM-2 are permanently denied.")}
    else
      start = start_record(document, task, mapping, confirmation)

      next =
        document
        |> Map.put("start", start)
        |> Document.append_event(
          "start.selected",
          %{
            "issue_id" => mapping["issue_id"],
            "issue_identifier" => mapping["issue_identifier"],
            "task_id" => task["id"]
          },
          timestamp
        )

      {:ok, next, {:ok, task, mapping}}
    end
  end

  defp start_record(document, task, mapping, confirmation) do
    %{
      "confirmation" => confirmation,
      "idempotency_key" => Command.start_key(document["intent_id"], document["proposal"]["digest"], task["id"]),
      "issue_id" => mapping["issue_id"],
      "issue_identifier" => mapping["issue_identifier"],
      "last_error" => nil,
      "provider" => mapping["provider"],
      "status" => "in_progress",
      "task_id" => task["id"]
    }
  end

  defp start_selection(document) do
    task_id = get_in(document, ["start", "task_id"])
    task = Enum.find(document["proposal"]["tasks"], &(&1["id"] == task_id))
    mapping = get_in(document, ["publication", "tasks", task_id])

    with true <- is_map(task) and is_map(mapping),
         true <- task["depends_on"] == [],
         true <- mapping["status"] == "confirmed",
         true <- mapping["issue_id"] == get_in(document, ["start", "issue_id"]),
         true <- mapping["issue_identifier"] == get_in(document, ["start", "issue_identifier"]),
         false <- LinearWriteBroker.protected_identifier?(mapping["issue_identifier"]),
         expected_key <- Command.start_key(document["intent_id"], document["proposal"]["digest"], task_id),
         true <- expected_key == get_in(document, ["start", "idempotency_key"]) do
      {:ok, task, mapping}
    else
      false -> {:error, error(:stale_start_selection, "The recorded start identity no longer matches publication receipts.")}
      true -> {:error, error(:protected_linear_issue_denied, "SYM-1 and SYM-2 are permanently denied.")}
    end
  end

  defp first_ready_task(document) do
    task =
      document["proposal"]["tasks"]
      |> Enum.filter(&(&1["depends_on"] == []))
      |> Enum.sort_by(&{&1["position"], &1["id"]})
      |> List.first()

    mapping = if(task, do: get_in(document, ["publication", "tasks", task["id"]]), else: nil)

    if task && is_map(mapping) && mapping["status"] == "confirmed" && is_binary(mapping["issue_id"]) do
      {:ok, task, mapping}
    else
      {:error, error(:no_ready_task, "No deterministically ready published task is available.")}
    end
  end

  defp run_start_transition(context, intent_id, {task, mapping}) do
    digest = get_proposal_digest(context.store, intent_id)

    case Command.transition(intent_id, digest, task["id"], mapping) do
      {:ok, command} -> reconcile_start_transition(context, intent_id, command)
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp reconcile_start_transition(context, intent_id, command) do
    case LinearWriteBroker.reconcile(context.broker, command) do
      {:ok, %Result{status: :confirmed} = result} ->
        store_start_outcome(context, intent_id, "waiting_for_admission", result, nil)

      {:ok, %Result{status: :absent}} ->
        execute_start_transition(context, intent_id, command)

      {:ok, %Result{status: :uncertain} = result} ->
        store_start_outcome(
          context,
          intent_id,
          "uncertain",
          result,
          broker_error(:uncertain_external_outcome)
        )

      {:ok, %Result{status: :rejected} = result} ->
        store_start_outcome(context, intent_id, "blocked", result, broker_error(:broker_rejected))

      {:error, reason} ->
        store_start_outcome(context, intent_id, "blocked", nil, broker_error(reason))
    end
  end

  defp execute_start_transition(context, intent_id, command) do
    case LinearWriteBroker.execute(context.broker, command) do
      {:ok, %Result{status: :confirmed} = result} ->
        store_start_outcome(context, intent_id, "waiting_for_admission", result, nil)

      {:ok, %Result{status: :uncertain} = result} ->
        store_start_outcome(
          context,
          intent_id,
          "uncertain",
          result,
          broker_error(:uncertain_external_outcome)
        )

      {:ok, %Result{} = result} ->
        store_start_outcome(context, intent_id, "blocked", result, broker_error(:invalid_execution_outcome))

      {:error, reason} ->
        store_start_outcome(context, intent_id, "blocked", nil, broker_error(reason))
    end
  end

  defp store_start_outcome(context, intent_id, status, result, failure) do
    timestamp = now(context)
    updater = fn document -> start_outcome_document(document, status, result, failure, timestamp) end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, :ok} -> :ok
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp start_outcome_document(document, status, result, failure, timestamp) do
    if get_in(document, ["start", "status"]) in ["waiting_for_admission", "admitted"] do
      {:ok, document, :ok}
    else
      {:ok, updated_start_document(document, status, result, failure, timestamp), :ok}
    end
  end

  defp updated_start_document(document, status, result, failure, timestamp) do
    provider = if(result, do: result.provider, else: get_in(document, ["start", "provider"]))

    document
    |> put_in(["start", "status"], status)
    |> put_in(["start", "last_error"], failure)
    |> put_in(["start", "provider"], provider)
    |> Document.append_event(
      start_event_type(status),
      %{
        "issue_id" => get_in(document, ["start", "issue_id"]),
        "issue_identifier" => get_in(document, ["start", "issue_identifier"]),
        "problem" => failure,
        "provider" => if(result, do: result.provider, else: nil),
        "task_id" => get_in(document, ["start", "task_id"])
      },
      timestamp
    )
  end

  defp start_event_type("waiting_for_admission"), do: "start.waiting_for_admission"
  defp start_event_type("uncertain"), do: "start.uncertain"
  defp start_event_type(_status), do: "start.blocked"

  defp get_proposal_digest(store, intent_id) do
    case Store.read_intent(store, intent_id) do
      {:ok, document} -> get_in(document, ["proposal", "digest"])
      {:error, _reason} -> nil
    end
  end

  defp with_external_operation_lock(context, intent_id, surface, callback) do
    resource = {__MODULE__, :external_operation, context.store.root, intent_id, surface}
    lock = {resource, self()}

    case :global.trans(lock, callback, [node()]) do
      {:aborted, _reason} ->
        {:error,
         error(
           :external_operation_lock_unavailable,
           "The trusted-host operation lock could not be acquired safely."
         )}

      result ->
        result
    end
  end

  defp finish_external_command(context, intent_id, surface, tool, command_id, request) do
    timestamp = now(context)
    updater = &finish_external_document(&1, surface, tool, command_id, request, timestamp)

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp finish_external_document(document, surface, tool, command_id, request, timestamp) do
    if get_in(document, [surface, "active_command_id"]) == command_id do
      recorded =
        document
        |> put_in([surface, "active_command_id"], nil)
        |> Document.record_command(tool, command_id, request, timestamp)

      {:ok, recorded, Document.public_snapshot(recorded)}
    else
      {:error,
       error(
         :external_operation_claim_lost,
         "The durable trusted-host attempt no longer owns this operation."
       )}
    end
  end

  defp release_external_command(context, intent_id, surface, command_id) do
    Store.update_intent(context.store, intent_id, fn document ->
      if get_in(document, [surface, "active_command_id"]) == command_id do
        {:ok, put_in(document, [surface, "active_command_id"], nil), :ok}
      else
        {:ok, document, :ok}
      end
    end)
  end

  defp observe_valid_admission_event(event, opts) do
    case context(opts) do
      {:ok, context} -> dispatch_admission_event(context, event)
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp dispatch_admission_event(context, %Event{type: "worker.attempt.started"} = event),
    do: observe_waiting_intents(context, event)

  defp dispatch_admission_event(_context, _event), do: {:ok, 0}

  defp observe_waiting_intents(context, event) do
    case Store.waiting_intents_for_issue(context.store, event.issue_id) do
      {:ok, documents} -> reduce_waiting_intents(documents, context, event)
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp reduce_waiting_intents(documents, context, event) do
    Enum.reduce_while(documents, {:ok, 0}, fn document, accumulator ->
      record_waiting_intent(document, accumulator, context, event)
    end)
  end

  defp record_waiting_intent(document, {:ok, count}, context, event) do
    case record_admission(context, document["intent_id"], event) do
      :ok -> {:cont, {:ok, count + 1}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp record_admission(context, intent_id, event) do
    timestamp = now(context)
    updater = fn document -> admission_document(document, event, timestamp) end

    case Store.update_intent(context.store, intent_id, updater) do
      {:ok, _status} -> :ok
      {:error, %{} = error} -> {:error, error}
      {:error, reason} -> {:error, translate_error(reason)}
    end
  end

  defp admission_document(document, event, timestamp) do
    cond do
      get_in(document, ["start", "issue_id"]) != event.issue_id ->
        {:ok, document, :ignored}

      get_in(document, ["admission", "event_id"]) == event.event_id ->
        {:ok, document, :duplicate}

      not is_nil(document["admission"]) ->
        {:ok, document, :ignored}

      true ->
        {:ok, document_with_admission(document, event, timestamp), :recorded}
    end
  end

  defp document_with_admission(document, event, timestamp) do
    admission = %{
      "attempt_id" => event.attempt_id,
      "event_id" => event.event_id,
      "event_type" => event.type,
      "issue_id" => event.issue_id,
      "observed_at" => timestamp,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "run_id" => event.run_id
    }

    document
    |> Map.put("admission", admission)
    |> put_in(["start", "status"], "admitted")
    |> put_in(["start", "last_error"], nil)
    |> Document.append_event(
      "symphony.admission.observed",
      Map.take(admission, ["attempt_id", "event_id", "event_type", "issue_id", "run_id"]),
      timestamp
    )
  end

  defp normalize_source(%{"kind" => kind, "content" => content} = source)
       when map_size(source) == 2 and kind in ["prompt", "markdown"] and is_binary(content) do
    if valid_bounded_text?(content, @max_source_bytes) do
      {:ok, %{"content" => content, "digest" => Canonical.digest(content), "kind" => kind}}
    else
      {:error, error(:invalid_intent_source, "Intent content must be bounded non-empty UTF-8 text.")}
    end
  end

  defp normalize_source(_source),
    do: {:error, error(:invalid_intent_source, "Source must contain exactly kind and content.")}

  defp canonical_project_root(path) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, canonical} <- PathSafety.canonicalize(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(canonical) do
      {:ok, canonical}
    else
      _invalid -> {:error, :invalid_project_root}
    end
  end

  defp canonical_project_root(_path), do: {:error, :invalid_project_root}

  defp context(opts) when is_list(opts) do
    allowed = [:broker, :clock, :data_root, :inspector_opts, :origin, :store]

    with true <- Keyword.keyword?(opts),
         true <- unique_allowed_options?(opts, allowed),
         {:ok, store} <- resolve_store(opts),
         broker <- Keyword.get(opts, :broker, LinearWriteBroker.default_target()),
         origin <- Keyword.get(opts, :origin, :trusted_host),
         true <- origin in [:mcp, :trusted_host],
         clock <- Keyword.get(opts, :clock, &DateTime.utc_now/0),
         true <- is_function(clock, 0),
         inspector_opts <- Keyword.get(opts, :inspector_opts, []),
         true <- is_list(inspector_opts) and Keyword.keyword?(inspector_opts) do
      {:ok, %{broker: broker, clock: clock, inspector_opts: inspector_opts, origin: origin, store: store}}
    else
      false -> {:error, :invalid_intent_service_options}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_intent_service_options}
    end
  end

  defp context(_opts), do: {:error, :invalid_intent_service_options}

  defp require_trusted_host(%{origin: :trusted_host}), do: :ok

  defp require_trusted_host(_context) do
    {:error,
     error(
       :trusted_host_authorization_required,
       "Approval, publication, and start are available only through the trusted local Studio interface."
     )}
  end

  defp resolve_store(opts) do
    case {Keyword.get(opts, :store), Keyword.get(opts, :data_root)} do
      {%Store{} = store, nil} -> {:ok, store}
      {nil, nil} -> Store.open()
      {nil, root} when is_binary(root) -> Store.open(root: root)
      _invalid -> {:error, :invalid_intent_service_options}
    end
  end

  defp now(context), do: Canonical.timestamp(context.clock)

  defp validate_command_id(command_id) when is_binary(command_id) do
    if valid_bounded_text?(command_id, @max_command_id_bytes) and
         Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/, command_id) do
      :ok
    else
      {:error, error(:invalid_command_id, "Command ID must be bounded stable ASCII without whitespace.")}
    end
  end

  defp validate_command_id(_command_id),
    do: {:error, error(:invalid_command_id, "Command ID must be bounded stable ASCII without whitespace.")}

  defp valid_bounded_text?(value, max) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..max and String.trim(value) != ""
  end

  defp valid_bounded_text?(_value, _max), do: false

  defp valid_digest?(value) when is_binary(value), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp valid_digest?(_value), do: false

  defp relation_id(dependent_task_id, prerequisite_task_id),
    do: Canonical.id("relation_", [dependent_task_id, prerequisite_task_id], 20)

  defp maybe_append_event(document, true, type, data, timestamp),
    do: Document.append_event(document, type, data, timestamp)

  defp maybe_append_event(document, false, _type, _data, _timestamp), do: document

  defp broker_error(reason) do
    %{
      "code" => broker_error_code(reason),
      "message" => broker_error_message(reason),
      "resumable" => true
    }
  end

  defp broker_error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp broker_error_code(_reason), do: "linear_write_broker_failed"

  defp broker_error_message(:least_privilege_write_broker_unavailable),
    do: "A separate least-privilege Linear write broker is not configured."

  defp broker_error_message(:protected_linear_issue_denied),
    do: "SYM-1 and SYM-2 are permanently denied."

  defp broker_error_message(:uncertain_external_outcome),
    do: "The external outcome is uncertain; retry must reconcile the same idempotency key."

  defp broker_error_message(_reason), do: "The typed Linear write broker did not confirm the operation."

  defp translate_error(%{} = error), do: error
  defp translate_error(:not_found), do: error(:not_found, "The requested Intent Service document does not exist.")
  defp translate_error(:invalid_project_root), do: error(:invalid_project_root, "Project root must be an existing absolute directory.")
  defp translate_error(:document_conflict), do: error(:document_conflict, "A different durable document already owns this identity.")
  defp translate_error(:protected_linear_issue_denied), do: error(:protected_linear_issue_denied, "SYM-1 and SYM-2 are permanently denied.")
  defp translate_error(reason) when is_atom(reason), do: error(reason, "Intent Service operation failed safely.")
  defp translate_error(_reason), do: error(:intent_service_failed, "Intent Service operation failed safely.")

  defp error(code, message, details \\ %{}) do
    %{code: code, details: details, message: message}
  end

  defp unique_allowed_options?(opts, allowed) do
    keys = Keyword.keys(opts)
    Enum.all?(keys, &(&1 in allowed)) and length(keys) == MapSet.size(MapSet.new(keys))
  end
end
