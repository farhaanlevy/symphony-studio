# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): Symphony Studio adds a
# validated, non-durable command envelope for deterministic tracker writes.

defmodule SymphonyElixir.Tracker.ManagedMutation do
  @moduledoc """
  Immutable command envelope for deterministic, Studio-originated tracker writes.

  This module validates the future durable outbox boundary without implementing
  persistence, retries, or reconciliation. A caller owns the operation and
  idempotency identities. Model-originated lifecycle commands are denied before
  an outbox sink can observe them.
  """

  alias SymphonyElixir.Identity

  @max_idempotency_key_bytes 512
  @max_issue_id_bytes 256
  @max_revision_bytes 512
  @max_integer_revision 9_223_372_036_854_775_807
  @max_comment_body_bytes 16_384
  @max_marker_bytes 512
  @max_state_bytes 256
  @max_evidence_manifest_id_bytes 256

  @required_keys [
    :operation_id,
    :idempotency_key,
    :issue_id,
    :expected_revision,
    :action,
    :payload,
    :reconciliation,
    :causation,
    :origin
  ]

  @enforce_keys @required_keys
  defstruct @required_keys

  @type action :: :handoff_comment | :state_transition
  @type expected_revision :: non_neg_integer() | String.t()
  @type comment_payload :: %{body: String.t(), marker: String.t()}
  @type state_payload :: %{state: String.t()}
  @type reconciliation ::
          %{kind: :comment_marker, marker: String.t()}
          | %{kind: :issue_state, state: String.t()}
  @type causation :: %{
          run_id: Identity.uuid(),
          attempt_id: Identity.uuid(),
          evidence_manifest_id: String.t()
        }
  @type error ::
          :model_lifecycle_mutation_denied
          | {:invalid_managed_mutation, atom(), atom()}

  @type t :: %__MODULE__{
          operation_id: Identity.uuid(),
          idempotency_key: String.t(),
          issue_id: String.t(),
          expected_revision: expected_revision(),
          action: action(),
          payload: comment_payload() | state_payload(),
          reconciliation: reconciliation(),
          causation: causation(),
          origin: :studio
        }

  @doc "Builds and validates an immutable managed tracker mutation."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(%__MODULE__{} = mutation) do
    with {:ok, canonical} <- canonical_mutation(mutation),
         :ok <- validate_fields(canonical) do
      {:ok, canonical}
    end
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword_keys?(attrs) do
      attrs
      |> Map.new()
      |> new()
    else
      invalid(:attributes, :must_be_unique_atom_key_map)
    end
  end

  def new(attrs) when is_map(attrs) do
    if exact_keys?(attrs, @required_keys) do
      attrs
      |> then(&struct!(__MODULE__, &1))
      |> new()
    else
      invalid(:attributes, :must_have_exact_required_keys)
    end
  end

  def new(_attrs), do: invalid(:attributes, :must_be_unique_atom_key_map)

  @doc "Validates a managed tracker mutation without executing it."
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = mutation) do
    with {:ok, canonical} <- canonical_mutation(mutation) do
      validate_fields(canonical)
    end
  end

  def validate(_mutation), do: invalid(:mutation, :must_be_managed_mutation_struct)

  defp canonical_mutation(mutation) do
    attrs = Map.delete(mutation, :__struct__)

    if exact_keys?(attrs, @required_keys),
      do: {:ok, struct!(__MODULE__, attrs)},
      else: invalid(:attributes, :must_have_exact_required_keys)
  end

  defp validate_fields(%__MODULE__{} = mutation) do
    with :ok <- validate_origin(mutation.origin),
         :ok <- validate_uuid4(:operation_id, mutation.operation_id),
         :ok <- validate_identifier(:idempotency_key, mutation.idempotency_key, @max_idempotency_key_bytes),
         :ok <- validate_identifier(:issue_id, mutation.issue_id, @max_issue_id_bytes),
         :ok <- validate_expected_revision(mutation.expected_revision),
         :ok <- validate_action_contract(mutation.action, mutation.payload, mutation.reconciliation) do
      validate_causation(mutation.causation)
    end
  end

  defp validate_origin(:studio), do: :ok
  defp validate_origin(:model), do: {:error, :model_lifecycle_mutation_denied}
  defp validate_origin(_origin), do: invalid(:origin, :must_be_studio)

  defp validate_uuid4(field, value) when is_binary(value) do
    if String.valid?(value) and value == String.downcase(value) and Identity.valid_uuid4?(value),
      do: :ok,
      else: invalid(field, :must_be_canonical_uuid4)
  end

  defp validate_uuid4(field, _value), do: invalid(field, :must_be_canonical_uuid4)

  defp validate_identifier(field, value, max_bytes) when is_binary(value) do
    if String.valid?(value) and byte_size(value) in 1..max_bytes and value == String.trim(value),
      do: :ok,
      else: invalid(field, :must_be_bounded_non_empty_string)
  end

  defp validate_identifier(field, _value, _max_bytes),
    do: invalid(field, :must_be_bounded_non_empty_string)

  defp validate_expected_revision(revision)
       when is_integer(revision) and revision in 0..@max_integer_revision,
       do: :ok

  defp validate_expected_revision(revision) when is_binary(revision) do
    validate_identifier(:expected_revision, revision, @max_revision_bytes)
  end

  defp validate_expected_revision(_revision),
    do: invalid(:expected_revision, :must_be_uint63_or_bounded_string)

  defp validate_action_contract(:handoff_comment, payload, reconciliation) do
    with :ok <- require_exact_keys(:payload, payload, [:body, :marker]),
         :ok <- require_exact_keys(:reconciliation, reconciliation, [:kind, :marker]),
         :ok <- validate_non_empty_text(:payload_body, payload.body, @max_comment_body_bytes),
         :ok <- validate_identifier(:operation_marker, payload.marker, @max_marker_bytes),
         true <- reconciliation.kind == :comment_marker,
         true <- reconciliation.marker == payload.marker do
      :ok
    else
      false -> invalid(:reconciliation, :must_match_comment_marker)
      {:error, _reason} = error -> error
    end
  end

  defp validate_action_contract(:state_transition, payload, reconciliation) do
    with :ok <- require_exact_keys(:payload, payload, [:state]),
         :ok <- require_exact_keys(:reconciliation, reconciliation, [:kind, :state]),
         :ok <- validate_identifier(:payload_state, payload.state, @max_state_bytes),
         true <- reconciliation.kind == :issue_state,
         true <- reconciliation.state == payload.state do
      :ok
    else
      false -> invalid(:reconciliation, :must_match_issue_state)
      {:error, _reason} = error -> error
    end
  end

  defp validate_action_contract(_action, _payload, _reconciliation),
    do: invalid(:action, :unsupported)

  defp validate_non_empty_text(field, value, max_bytes) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= max_bytes and String.trim(value) != "",
      do: :ok,
      else: invalid(field, :must_be_bounded_non_empty_string)
  end

  defp validate_non_empty_text(field, _value, _max_bytes),
    do: invalid(field, :must_be_bounded_non_empty_string)

  defp validate_causation(causation) do
    with :ok <-
           require_exact_keys(
             :causation,
             causation,
             [:run_id, :attempt_id, :evidence_manifest_id]
           ),
         :ok <- validate_uuid4(:causation_run_id, causation.run_id),
         :ok <- validate_uuid4(:causation_attempt_id, causation.attempt_id),
         :ok <-
           validate_identifier(
             :causation_evidence_manifest_id,
             causation.evidence_manifest_id,
             @max_evidence_manifest_id_bytes
           ) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp require_exact_keys(field, value, expected) do
    if exact_keys?(value, expected),
      do: :ok,
      else: invalid(field, :must_have_exact_required_keys)
  end

  defp exact_keys?(value, expected) when is_map(value) do
    value
    |> Map.keys()
    |> Enum.sort()
    |> Kernel.==(Enum.sort(expected))
  end

  defp exact_keys?(_value, _expected), do: false

  defp unique_keyword_keys?(keyword) do
    keys = Keyword.keys(keyword)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp invalid(field, reason), do: {:error, {:invalid_managed_mutation, field, reason}}
end
