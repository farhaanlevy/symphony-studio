# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Command do
  @moduledoc """
  Typed, digest-bound command for the future least-privilege Linear write broker.

  Commands contain exact stable IDs and idempotency markers. They intentionally
  provide no title-search operation and no access to the existing query-only
  credential.
  """

  alias SymphonyElixir.Studio.Intent.Canonical

  @enforce_keys [
    :kind,
    :operation_id,
    :idempotency_key,
    :intent_id,
    :proposal_digest,
    :subject_id,
    :payload
  ]
  defstruct @enforce_keys

  @type kind :: :issue | :relation | :transition
  @type t :: %__MODULE__{
          kind: kind(),
          operation_id: String.t(),
          idempotency_key: String.t(),
          intent_id: String.t(),
          proposal_digest: String.t(),
          subject_id: String.t(),
          payload: map()
        }
  @type error :: {:invalid_linear_write_command, atom(), atom()}

  @doc "Builds and validates one exact write-broker command."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, error()}
  def new(%__MODULE__{} = command) do
    with :ok <- validate_kind(command.kind),
         :ok <- bounded(:operation_id, command.operation_id, 96),
         :ok <- bounded(:idempotency_key, command.idempotency_key, 512),
         :ok <- bounded(:intent_id, command.intent_id, 96),
         :ok <- digest(command.proposal_digest),
         :ok <- bounded(:subject_id, command.subject_id, 128) do
      validate_payload(command)
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keys?(attrs), do: attrs |> Map.new() |> new(), else: invalid(:attributes, :invalid)
  end

  def new(attrs) when is_map(attrs) do
    expected = @enforce_keys

    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected) do
      attrs
      |> then(&struct!(__MODULE__, &1))
      |> new()
    else
      invalid(:attributes, :invalid)
    end
  end

  def new(_attrs), do: invalid(:attributes, :invalid)

  @doc "Creates a deterministic issue-publication command."
  @spec issue(String.t(), String.t(), map()) :: {:ok, t()} | {:error, error()}
  def issue(intent_id, proposal_digest, task) when is_map(task) do
    task_id = Map.get(task, "id")
    key = issue_key(intent_id, proposal_digest, task_id)

    new(%{
      kind: :issue,
      operation_id: operation_id(key),
      idempotency_key: key,
      intent_id: intent_id,
      proposal_digest: proposal_digest,
      subject_id: task_id,
      payload: %{
        "description" => issue_description(intent_id, proposal_digest, task, key),
        "task_id" => task_id,
        "title" => Map.get(task, "title")
      }
    })
  end

  @doc "Creates a deterministic blocker-relation publication command."
  @spec relation(String.t(), String.t(), String.t(), map(), map()) ::
          {:ok, t()} | {:error, error()}
  def relation(intent_id, proposal_digest, dependent_task_id, prerequisite_mapping, dependent_mapping)
      when is_map(prerequisite_mapping) and is_map(dependent_mapping) do
    prerequisite_id = Map.get(prerequisite_mapping, "issue_id")
    dependent_id = Map.get(dependent_mapping, "issue_id")
    subject = dependent_task_id <> "<-" <> to_string(prerequisite_id)
    key = relation_key(intent_id, proposal_digest, dependent_task_id, prerequisite_id)

    new(%{
      kind: :relation,
      operation_id: operation_id(key),
      idempotency_key: key,
      intent_id: intent_id,
      proposal_digest: proposal_digest,
      subject_id: subject,
      payload: %{
        "dependent_issue_id" => dependent_id,
        "prerequisite_issue_id" => prerequisite_id,
        "relation" => "blocks"
      }
    })
  end

  @doc "Creates the one digest-bound transition command for the first ready issue."
  @spec transition(String.t(), String.t(), String.t(), map()) ::
          {:ok, t()} | {:error, error()}
  def transition(intent_id, proposal_digest, task_id, mapping) when is_map(mapping) do
    key = start_key(intent_id, proposal_digest, task_id)

    new(%{
      kind: :transition,
      operation_id: operation_id(key),
      idempotency_key: key,
      intent_id: intent_id,
      proposal_digest: proposal_digest,
      subject_id: task_id,
      payload: %{
        "issue_id" => Map.get(mapping, "issue_id"),
        "issue_identifier" => Map.get(mapping, "issue_identifier"),
        "state" => "Todo"
      }
    })
  end

  @doc "Returns the exact issue idempotency marker used for reconciliation."
  @spec issue_key(String.t(), String.t(), String.t()) :: String.t()
  def issue_key(intent_id, proposal_digest, task_id) do
    "symphony-intent:v1:#{intent_id}:#{proposal_digest}:issue:#{task_id}"
  end

  @doc "Returns the exact relation idempotency marker used for reconciliation."
  @spec relation_key(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def relation_key(intent_id, proposal_digest, task_id, prerequisite_issue_id) do
    "symphony-intent:v1:#{intent_id}:#{proposal_digest}:relation:#{task_id}:#{prerequisite_issue_id}"
  end

  @doc "Returns the exact first-ready transition idempotency marker."
  @spec start_key(String.t(), String.t(), String.t()) :: String.t()
  def start_key(intent_id, proposal_digest, task_id) do
    "symphony-intent:v1:#{intent_id}:#{proposal_digest}:start:#{task_id}:todo"
  end

  defp operation_id(key), do: Canonical.id("op_", key, 32)

  defp issue_description(intent_id, proposal_digest, task, key) do
    criteria =
      task
      |> Map.get("acceptance_criteria", [])
      |> Enum.map_join("\n", &"- #{&1}")

    dependencies =
      task
      |> Map.get("depends_on", [])
      |> Enum.join(", ")
      |> case do
        "" -> "none"
        value -> value
      end

    """
    #{Map.get(task, "description")}

    Acceptance criteria:
    #{criteria}

    Internal dependencies: #{dependencies}

    Intent: #{intent_id}
    Proposal digest: #{proposal_digest}
    Idempotency marker: #{key}
    """
    |> String.trim()
  end

  defp validate_kind(kind) when kind in [:issue, :relation, :transition], do: :ok
  defp validate_kind(_kind), do: invalid(:kind, :unsupported)

  defp validate_payload(%__MODULE__{kind: :issue, payload: payload} = command) do
    with :ok <- exact_payload(payload, ["description", "task_id", "title"]),
         :ok <- bounded(:payload_task_id, payload["task_id"], 128),
         :ok <- bounded(:payload_title, payload["title"], 512),
         :ok <- bounded(:payload_description, payload["description"], 32_768) do
      {:ok, command}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_payload(%__MODULE__{kind: :relation, payload: payload} = command) do
    with :ok <- exact_payload(payload, ["dependent_issue_id", "prerequisite_issue_id", "relation"]),
         :ok <- bounded(:dependent_issue_id, payload["dependent_issue_id"], 256),
         :ok <- bounded(:prerequisite_issue_id, payload["prerequisite_issue_id"], 256),
         true <- payload["relation"] == "blocks",
         true <- payload["dependent_issue_id"] != payload["prerequisite_issue_id"] do
      {:ok, command}
    else
      false -> invalid(:payload, :invalid_relation)
      {:error, _reason} = error -> error
    end
  end

  defp validate_payload(%__MODULE__{kind: :transition, payload: payload} = command) do
    with :ok <- exact_payload(payload, ["issue_id", "issue_identifier", "state"]),
         :ok <- bounded(:issue_id, payload["issue_id"], 256),
         :ok <- bounded(:issue_identifier, payload["issue_identifier"], 64),
         true <- payload["state"] == "Todo" do
      {:ok, command}
    else
      false -> invalid(:payload, :invalid_transition)
      {:error, _reason} = error -> error
    end
  end

  defp validate_payload(_command), do: invalid(:payload, :invalid)

  defp exact_payload(payload, keys) when is_map(payload) do
    if Enum.sort(Map.keys(payload)) == Enum.sort(keys), do: :ok, else: invalid(:payload, :invalid)
  end

  defp exact_payload(_payload, _keys), do: invalid(:payload, :invalid)

  defp bounded(field, value, max) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..max and String.trim(value) == value,
      do: :ok,
      else: invalid(field, :invalid)
  end

  defp bounded(field, _value, _max), do: invalid(field, :invalid)

  defp digest(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: invalid(:proposal_digest, :invalid)
  end

  defp digest(_value), do: invalid(:proposal_digest, :invalid)

  defp unique_keys?(keyword) do
    keys = Keyword.keys(keyword)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp invalid(field, reason), do: {:error, {:invalid_linear_write_command, field, reason}}
end
