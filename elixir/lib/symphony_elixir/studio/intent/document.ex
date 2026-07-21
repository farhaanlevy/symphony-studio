# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.Document do
  @moduledoc false

  alias SymphonyElixir.Studio.Intent.Canonical

  @spec new(map()) :: map()
  def new(attrs) when is_map(attrs) do
    timestamp = Map.fetch!(attrs, "created_at")
    questions = Map.fetch!(attrs, "questions")
    proposal = Map.get(attrs, "proposal")

    %{
      "admission" => nil,
      "approval" => nil,
      "clarifications" => %{
        "answers" => %{},
        "questions" => questions,
        "status" => clarification_status(questions)
      },
      "commands" => %{},
      "created_at" => timestamp,
      "events" => [],
      "inspection" => Map.fetch!(attrs, "inspection"),
      "intent_id" => Map.fetch!(attrs, "intent_id"),
      "presentation" => nil,
      "project" => Map.fetch!(attrs, "project"),
      "proposal" => proposal,
      "publication" => empty_publication(),
      "schema_version" => 1,
      "source" => Map.fetch!(attrs, "source"),
      "start" => empty_start(),
      "updated_at" => timestamp
    }
  end

  @spec empty_publication() :: map()
  def empty_publication do
    %{
      "last_error" => nil,
      "proposal_digest" => nil,
      "relations" => %{},
      "status" => "not_started",
      "tasks" => %{}
    }
  end

  @spec empty_start() :: map()
  def empty_start do
    %{
      "confirmation" => nil,
      "issue_id" => nil,
      "issue_identifier" => nil,
      "last_error" => nil,
      "status" => "not_started",
      "task_id" => nil
    }
  end

  @spec append_event(map(), String.t(), map(), String.t()) :: map()
  def append_event(document, type, data, occurred_at)
      when is_map(document) and is_binary(type) and is_map(data) and is_binary(occurred_at) do
    sequence = length(Map.get(document, "events", [])) + 1

    event = %{
      "data" => data,
      "event_id" =>
        Canonical.id(
          "ievt_",
          [Map.get(document, "intent_id"), sequence, type, data],
          32
        ),
      "occurred_at" => occurred_at,
      "sequence" => sequence,
      "type" => type
    }

    document
    |> Map.update!("events", &(&1 ++ [event]))
    |> Map.put("updated_at", occurred_at)
  end

  @spec command_state(map(), String.t(), String.t(), term()) ::
          :new | :replay | {:conflict, map()}
  def command_state(document, tool, command_id, request) do
    request_digest = Canonical.digest(request)

    case get_in(document, ["commands", command_id]) do
      nil ->
        :new

      %{"tool" => ^tool, "request_digest" => ^request_digest} ->
        :replay

      existing when is_map(existing) ->
        {:conflict,
         %{
           "existing_request_digest" => Map.get(existing, "request_digest"),
           "existing_tool" => Map.get(existing, "tool")
         }}
    end
  end

  @spec record_command(map(), String.t(), String.t(), term(), String.t()) :: map()
  def record_command(document, tool, command_id, request, recorded_at) do
    entry = %{
      "event_sequence" => length(Map.get(document, "events", [])),
      "recorded_at" => recorded_at,
      "request_digest" => Canonical.digest(request),
      "tool" => tool
    }

    document
    |> put_in(["commands", command_id], entry)
    |> Map.put("updated_at", recorded_at)
  end

  @spec public_snapshot(map()) :: map()
  def public_snapshot(document) when is_map(document) do
    source = Map.get(document, "source", %{})
    proposal = Map.get(document, "proposal")

    %{
      "admission" => Map.get(document, "admission"),
      "clarifications" => Map.get(document, "clarifications"),
      "events" => Map.get(document, "events", []),
      "inspection" => Map.get(document, "inspection"),
      "intent_id" => Map.get(document, "intent_id"),
      "lifecycle_state" => lifecycle_state(document),
      "project" => Map.get(document, "project"),
      "proposal" => proposal,
      "publication" => Map.get(document, "publication"),
      "schema_version" => Map.get(document, "schema_version"),
      "source" => %{"digest" => Map.get(source, "digest"), "kind" => Map.get(source, "kind")},
      "start" => Map.get(document, "start"),
      "updated_at" => Map.get(document, "updated_at")
    }
  end

  @spec lifecycle_state(map()) :: String.t()
  def lifecycle_state(document) when is_map(document) do
    case Map.get(document, "admission") do
      nil -> lifecycle_without_admission(document)
      _admission -> "admitted"
    end
  end

  defp lifecycle_without_admission(document) do
    case get_in(document, ["start", "status"]) do
      "waiting_for_admission" -> "waiting_for_admission"
      status when status in ["blocked", "uncertain"] -> "start_#{status}"
      _other -> lifecycle_without_start(document)
    end
  end

  defp lifecycle_without_start(document) do
    case get_in(document, ["publication", "status"]) do
      "complete" -> "published"
      status when status in ["blocked", "partial", "uncertain"] -> "publication_#{status}"
      _other -> lifecycle_before_publication(document)
    end
  end

  defp lifecycle_before_publication(document) do
    cond do
      not is_nil(Map.get(document, "approval")) -> "approved"
      not is_nil(Map.get(document, "presentation")) -> "presented"
      get_in(document, ["clarifications", "status"]) == "required" -> "clarification_required"
      is_map(Map.get(document, "proposal")) -> "proposal_ready"
      true -> "submitted"
    end
  end

  defp clarification_status([]), do: "not_required"
  defp clarification_status(_questions), do: "required"
end
