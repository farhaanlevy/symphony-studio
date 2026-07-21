# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.Planner do
  @moduledoc """
  Deterministic preview planner for the canonical intent lifecycle.

  This is deliberately a thin plan constructor, not a model substitute. It
  exposes ambiguity, grounds the proposal in the bounded repository inventory,
  and produces a valid 3-5 task DAG that a future Planner Conductor can replace
  without changing approval, publication, or admission contracts.
  """

  alias SymphonyElixir.Studio.Intent.Canonical

  @max_questions 2
  @max_tasks 5

  @doc "Builds one batched set of at most two high-value clarification questions."
  @spec questions(map(), map()) :: [map()]
  def questions(%{"content" => content}, inspection)
      when is_binary(content) and is_map(inspection) do
    normalized = String.downcase(content)

    []
    |> maybe_add(outcome_ambiguous?(normalized), outcome_question())
    |> maybe_add(acceptance_ambiguous?(normalized, inspection), acceptance_question(inspection))
    |> maybe_add(scope_ambiguous?(normalized), scope_question())
    |> Enum.take(@max_questions)
  end

  def questions(_source, _inspection), do: []

  @doc "Returns the recommended answers for an exact pending question batch."
  @spec recommended_answers([map()]) :: map()
  def recommended_answers(questions) when is_list(questions) do
    Map.new(questions, fn question ->
      {Map.fetch!(question, "id"), Map.fetch!(question, "recommended_answer")}
    end)
  end

  @doc "Builds a deterministic 3-5 task proposal and its content digest."
  @spec propose(map(), map(), map()) :: map()
  def propose(%{"content" => content} = source, inspection, answers)
      when is_binary(content) and is_map(inspection) and is_map(answers) do
    source_digest = Canonical.digest(source)
    requirements = extract_requirements(content)
    focus = focus_summary(content)
    contract_task = contract_task(focus, inspection)
    implementation_tasks = implementation_tasks(requirements, focus, contract_task["id"])

    validation_task =
      validation_task(
        focus,
        Enum.map(implementation_tasks, & &1["id"]),
        inspection,
        answers
      )

    tasks =
      [contract_task | implementation_tasks]
      |> Kernel.++([validation_task])
      |> Enum.take(@max_tasks)
      |> Enum.with_index(1)
      |> Enum.map(fn {task, position} -> Map.put(task, "position", position) end)

    proposal = %{
      "answers_digest" => Canonical.digest(answers),
      "inspection_digest" => Map.get(inspection, "digest"),
      "source_digest" => source_digest,
      "status" => "proposed",
      "tasks" => tasks,
      "version" => 1
    }

    Map.put(proposal, "digest", Canonical.digest(Map.delete(proposal, "status")))
  end

  defp outcome_ambiguous?(content) do
    not Regex.match?(~r/\b(user|operator|developer|customer|team|maintainer|admin)\b/, content)
  end

  defp acceptance_ambiguous?(content, inspection) do
    not Regex.match?(~r/\b(acceptance|test|tests|verify|verified|check|checks|prove|evidence|passes)\b/, content) and
      Map.get(inspection, "test_file_count", 0) > 0
  end

  defp scope_ambiguous?(content) do
    not Regex.match?(~r/\b(scope|only|exclude|excluded|non-goal|must not|do not|without)\b/, content)
  end

  defp outcome_question do
    %{
      "id" => "q_primary_outcome",
      "impact" => "The answer determines the workflow boundary and issue acceptance language.",
      "options" => [
        %{
          "id" => "recommended",
          "label" => "Infer from the named workflow",
          "description" => "Use the source's first concrete action as the primary user outcome."
        },
        %{
          "id" => "custom",
          "label" => "Provide a specific outcome",
          "description" => "Name the actor and observable result explicitly."
        }
      ],
      "prompt" => "Who is the primary user, and what single observable outcome should this plan optimize?",
      "recommended_answer" => "Infer the primary actor and outcome from the first concrete workflow in the submitted intent."
    }
  end

  defp acceptance_question(inspection) do
    tests = Map.get(inspection, "test_file_count", 0)

    %{
      "id" => "q_acceptance_evidence",
      "impact" => "The answer controls whether generated issues can be closed with objective evidence.",
      "options" => [
        %{
          "id" => "recommended",
          "label" => "Use repository checks",
          "description" => "Require targeted tests plus the repository's existing broader gate."
        },
        %{
          "id" => "custom",
          "label" => "Provide exact evidence",
          "description" => "Name additional commands or observations required for acceptance."
        }
      ],
      "prompt" => "Which deterministic evidence must prove this work is complete?",
      "recommended_answer" => "Use targeted tests and the repository's established quality gate; inspection found #{tests} test files."
    }
  end

  defp scope_question do
    %{
      "id" => "q_scope_boundary",
      "impact" => "The answer prevents adjacent cleanup from silently expanding the published backlog.",
      "options" => [
        %{
          "id" => "recommended",
          "label" => "Narrow requested workflow",
          "description" => "Include only the requested outcome and safety or verification work it requires."
        },
        %{
          "id" => "custom",
          "label" => "Name additional scope",
          "description" => "List any adjacent behavior that is intentionally included."
        }
      ],
      "prompt" => "What is explicitly out of scope for this plan?",
      "recommended_answer" => "Exclude unrelated refactors, provider abstractions, deployment changes, and unrequested product surface."
    }
  end

  defp maybe_add(items, true, item), do: items ++ [item]
  defp maybe_add(items, false, _item), do: items

  defp extract_requirements(content) do
    content
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      line = String.trim(line)

      case Regex.run(~r/^(?:[-*+]\s+|\d+[.)]\s+|[#]{1,6}\s+)(.+)$/, line) do
        [_, requirement] -> maybe_requirement(requirement, line_number)
        _no_marker -> []
      end
    end)
    |> Enum.uniq_by(fn requirement -> String.downcase(requirement.text) end)
    |> Enum.take(5)
  end

  defp maybe_requirement(requirement, line_number) do
    requirement = requirement |> String.trim() |> String.replace(~r/[.:]+$/, "")

    if String.length(requirement) in 8..180 do
      [%{text: requirement, source_ref: "source:line:#{line_number}"}]
    else
      []
    end
  end

  defp focus_summary(content) do
    content
    |> String.split(~r/[\n.!?]/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find("submitted intent", &(String.length(&1) >= 8))
    |> truncate(90)
  end

  defp contract_task(focus, inspection) do
    title = "Define the #{sentence_fragment(focus)} contract"
    id = task_id(1, title)

    %{
      "acceptance_criteria" => [
        "Required behavior, non-goals, authority boundaries, and objective evidence are explicit.",
        "The contract cites the inspected project surfaces that constrain implementation."
      ],
      "depends_on" => [],
      "description" => "Turn the accepted intent and clarification answers into a bounded implementation contract before code changes begin.",
      "id" => id,
      "source_refs" => Enum.take(Map.get(inspection, "spec_paths", []), 4),
      "title" => title
    }
  end

  defp implementation_tasks([], focus, contract_id) do
    [implementation_task(2, focus, "source:intent", contract_id)]
  end

  defp implementation_tasks(requirements, _focus, contract_id) do
    requirements
    |> Enum.with_index(2)
    |> Enum.map(fn {%{text: text, source_ref: source_ref}, position} ->
      implementation_task(position, text, source_ref, contract_id)
    end)
  end

  defp implementation_task(position, requirement, source_ref, contract_id) do
    fragment = sentence_fragment(requirement)
    title = "Implement #{fragment}"

    %{
      "acceptance_criteria" => [
        "The requested behavior is implemented through the repository's existing architecture.",
        "Failure, retry, and idempotency behavior are observable where this slice mutates state."
      ],
      "depends_on" => [contract_id],
      "description" => "Deliver the bounded implementation slice for: #{truncate(requirement, 220)}.",
      "id" => task_id(position, title),
      "source_refs" => [source_ref],
      "title" => title
    }
  end

  defp validation_task(focus, dependency_ids, inspection, answers) do
    position = length(dependency_ids) + 2
    title = "Verify #{sentence_fragment(focus)} end to end"
    answer_summary = answers |> Map.values() |> Enum.join(" ") |> truncate(280)

    criteria = [
      "Targeted tests cover the normal path, denial path, duplicate command, and partial-failure recovery.",
      "The repository's established broader quality gate is run or its exact blocker is recorded.",
      "Published evidence maps every accepted requirement to a passing oracle."
    ]

    description =
      if answer_summary == "" do
        "Prove the complete workflow with deterministic checks and preserve the evidence."
      else
        "Prove the complete workflow with deterministic checks. Clarification basis: #{answer_summary}"
      end

    %{
      "acceptance_criteria" => criteria,
      "depends_on" => dependency_ids,
      "description" => description,
      "id" => task_id(position, title),
      "source_refs" => Enum.take(Map.get(inspection, "test_paths", []), 4),
      "title" => title
    }
  end

  defp task_id(position, title), do: Canonical.id("task_", [position, title], 16)

  defp sentence_fragment(value) do
    value
    |> String.trim()
    |> String.replace(~r/[.:;]+$/, "")
    |> downcase_first()
    |> truncate(100)
  end

  defp downcase_first(<<first::utf8, rest::binary>>) do
    String.downcase(<<first::utf8>>) <> rest
  end

  defp downcase_first(value), do: value

  defp truncate(value, max) when is_binary(value) and byte_size(value) <= max, do: value

  defp truncate(value, max) when is_binary(value) do
    value
    |> String.slice(0, max - 1)
    |> Kernel.<>("…")
  end
end
