# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
# Downstream modification notice (2026-07-16): prove the validated managed
# mutation envelope and exactly-once, non-durable injected outbox seam.

defmodule SymphonyElixir.Tracker.OutboxTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Identity
  alias SymphonyElixir.Tracker.{ManagedMutation, Outbox}

  defmodule RecordingSink do
    @moduledoc false
    @behaviour Outbox

    @impl true
    def enqueue(operation) do
      Process.put({__MODULE__, :calls}, Process.get({__MODULE__, :calls}, 0) + 1)
      send(Process.get({__MODULE__, :recipient}), {:managed_mutation, operation})

      case Process.get({__MODULE__, :result}, {:ok, :accepted}) do
        :raise -> raise "sink secret"
        :exit -> exit(:sink_secret)
        result -> result
      end
    end
  end

  setup do
    Process.put({RecordingSink, :recipient}, self())
    Process.put({RecordingSink, :calls}, 0)
    Process.put({RecordingSink, :result}, {:ok, :accepted})
    :ok
  end

  test "normalizes and validates an immutable handoff-comment command" do
    attrs = valid_attrs()

    assert {:ok, %ManagedMutation{} = mutation} = ManagedMutation.new(attrs)
    assert Map.from_struct(mutation) == attrs
    assert :ok = ManagedMutation.validate(mutation)
    assert {:ok, ^mutation} = ManagedMutation.new(mutation)
    assert {:ok, ^mutation} = attrs |> Map.to_list() |> ManagedMutation.new()
  end

  test "normalizes and validates a state-transition command" do
    attrs =
      valid_attrs()
      |> Map.merge(%{
        action: :state_transition,
        payload: %{state: "Human Review"},
        reconciliation: %{kind: :issue_state, state: "Human Review"},
        expected_revision: 42
      })

    assert {:ok, %ManagedMutation{} = mutation} = ManagedMutation.new(attrs)
    assert mutation.action == :state_transition
    assert mutation.expected_revision == 42
    assert :ok = ManagedMutation.validate(mutation)
  end

  test "requires the exact normalized envelope keys" do
    attrs = valid_attrs()

    assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
             attrs |> Map.delete(:operation_id) |> ManagedMutation.new()

    assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
             attrs |> Map.put(:retry_count, 1) |> ManagedMutation.new()

    duplicate_keyword = Map.to_list(attrs) ++ [operation_id: Identity.uuid4()]

    assert {:error, {:invalid_managed_mutation, :attributes, :must_be_unique_atom_key_map}} =
             ManagedMutation.new(duplicate_keyword)

    assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
             attrs
             |> Enum.map(fn {key, value} -> {Atom.to_string(key), value} end)
             |> Map.new()
             |> ManagedMutation.new()

    assert {:error, {:invalid_managed_mutation, :attributes, :must_be_unique_atom_key_map}} =
             ManagedMutation.new(:not_attributes)

    assert {:error, {:invalid_managed_mutation, :mutation, :must_be_managed_mutation_struct}} =
             ManagedMutation.validate(%{})

    {:ok, canonical} = ManagedMutation.new(attrs)

    for malformed <- [
          Map.put(canonical, :extra, "DO_NOT_DELEGATE"),
          Map.delete(canonical, :operation_id),
          %{__struct__: ManagedMutation}
        ] do
      assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
               ManagedMutation.new(malformed)

      assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
               ManagedMutation.validate(malformed)

      assert {:error, {:invalid_managed_mutation, :attributes, :must_have_exact_required_keys}} =
               Outbox.submit(malformed, sink: RecordingSink, source: :studio)
    end

    assert Process.get({RecordingSink, :calls}) == 0
    refute_received {:managed_mutation, _operation}
  end

  test "validates operation identity, idempotency, issue, and expected revision" do
    cases = [
      field_case(:operation_id, "not-a-uuid", :must_be_canonical_uuid4),
      field_case(:operation_id, nil, :must_be_canonical_uuid4),
      field_case(:operation_id, String.upcase(Identity.uuid4()), :must_be_canonical_uuid4),
      field_case(:idempotency_key, "", :must_be_bounded_non_empty_string),
      field_case(:idempotency_key, nil, :must_be_bounded_non_empty_string),
      field_case(
        :idempotency_key,
        String.duplicate("x", 513),
        :must_be_bounded_non_empty_string
      ),
      field_case(:issue_id, " issue-123", :must_be_bounded_non_empty_string),
      field_case(:issue_id, <<255>>, :must_be_bounded_non_empty_string),
      field_case(
        :expected_revision,
        -1,
        :must_be_uint63_or_bounded_string
      ),
      field_case(
        :expected_revision,
        9_223_372_036_854_775_808,
        :must_be_uint63_or_bounded_string
      ),
      field_case(
        :expected_revision,
        %{},
        :must_be_uint63_or_bounded_string
      )
    ]

    for {field, value, expected_error} <- cases do
      assert {:error, ^expected_error} =
               valid_attrs()
               |> Map.put(field, value)
               |> ManagedMutation.new()
    end
  end

  test "validates action payload and matching reconciliation predicate" do
    cases = [
      update_case(%{action: :unknown}, :action, :unsupported),
      update_case(
        %{payload: %{body: "handoff", marker: "marker", extra: true}},
        :payload,
        :must_have_exact_required_keys
      ),
      update_case(
        %{payload: %{body: "   ", marker: "marker"}},
        :payload_body,
        :must_be_bounded_non_empty_string
      ),
      update_case(
        %{payload: %{body: nil, marker: "marker"}},
        :payload_body,
        :must_be_bounded_non_empty_string
      ),
      update_case(
        %{payload: %{body: <<255>>, marker: "marker"}},
        :payload_body,
        :must_be_bounded_non_empty_string
      ),
      update_case(%{payload: nil}, :payload, :must_have_exact_required_keys),
      update_case(
        %{payload: %{body: "handoff", marker: ""}},
        :operation_marker,
        :must_be_bounded_non_empty_string
      ),
      update_case(
        %{reconciliation: %{kind: :comment_marker, marker: "different"}},
        :reconciliation,
        :must_match_comment_marker
      ),
      update_case(
        %{
          action: :state_transition,
          payload: %{state: "Human Review"},
          reconciliation: %{kind: :issue_state, state: "Done"}
        },
        :reconciliation,
        :must_match_issue_state
      ),
      update_case(
        %{
          action: :state_transition,
          payload: %{state: ""},
          reconciliation: %{kind: :issue_state, state: ""}
        },
        :payload_state,
        :must_be_bounded_non_empty_string
      )
    ]

    for {updates, expected_error} <- cases do
      assert {:error, ^expected_error} =
               valid_attrs()
               |> Map.merge(updates)
               |> ManagedMutation.new()
    end
  end

  test "validates exact causation identities without exposing values" do
    attrs = valid_attrs()

    cases = [
      update_case(
        %{run_id: Identity.uuid4(), attempt_id: Identity.uuid4()},
        :causation,
        :must_have_exact_required_keys
      ),
      update_case(
        %{
          run_id: "not-a-uuid",
          attempt_id: Identity.uuid4(),
          evidence_manifest_id: "manifest-1"
        },
        :causation_run_id,
        :must_be_canonical_uuid4
      ),
      update_case(
        %{
          run_id: Identity.uuid4(),
          attempt_id: "not-a-uuid",
          evidence_manifest_id: "manifest-1"
        },
        :causation_attempt_id,
        :must_be_canonical_uuid4
      ),
      update_case(
        %{
          run_id: Identity.uuid4(),
          attempt_id: Identity.uuid4(),
          evidence_manifest_id: ""
        },
        :causation_evidence_manifest_id,
        :must_be_bounded_non_empty_string
      )
    ]

    for {causation, expected_error} <- cases do
      assert {:error, ^expected_error} =
               attrs
               |> Map.put(:causation, causation)
               |> ManagedMutation.new()
    end
  end

  test "denies model-originated lifecycle commands before any sink call" do
    attrs = Map.put(valid_attrs(), :origin, :model)

    assert {:error, :model_lifecycle_mutation_denied} = ManagedMutation.new(attrs)

    assert {:error, :model_lifecycle_mutation_denied} =
             Outbox.submit(attrs, sink: RecordingSink, source: :studio)

    assert {:error, :model_lifecycle_mutation_denied} =
             valid_attrs()
             |> Outbox.submit(sink: RecordingSink, source: :model)

    assert Process.get({RecordingSink, :calls}) == 0
    refute_received {:managed_mutation, _operation}

    assert {:error, {:invalid_managed_mutation, :origin, :must_be_studio}} =
             valid_attrs()
             |> Map.put(:origin, :human)
             |> ManagedMutation.new()
  end

  test "fails closed when the sink is missing or does not implement the port" do
    attrs = valid_attrs()

    assert {:error, :managed_tracker_source_required} = Outbox.submit(attrs)

    assert {:error, :managed_tracker_source_required} =
             Outbox.submit(attrs, sink: RecordingSink)

    assert {:error, :managed_tracker_outbox_unavailable} =
             Outbox.submit(attrs, source: :studio)

    assert {:error, :managed_tracker_outbox_unavailable} =
             Outbox.submit(attrs, sink: String, source: :studio)

    assert Process.get({RecordingSink, :calls}) == 0
  end

  test "rejects malformed sink options without delegation" do
    attrs = valid_attrs()

    for opts <- [
          [sink: RecordingSink, sink: RecordingSink, source: :studio],
          [sink: RecordingSink, source: :studio, retry: 3],
          [sink: RecordingSink, source: :studio, source: :studio],
          [sink: RecordingSink, source: :human],
          [:not_keyword],
          %{sink: RecordingSink}
        ] do
      assert {:error, :invalid_managed_tracker_outbox_options} = Outbox.submit(attrs, opts)
    end

    assert Process.get({RecordingSink, :calls}) == 0
  end

  test "delegates the exact validated operation once and returns the receipt" do
    attrs = valid_attrs()

    assert {:ok, %{delivery: "receipt-1"}} =
             put_sink_result({:ok, %{delivery: "receipt-1"}}, fn ->
               Outbox.submit(attrs, sink: RecordingSink, source: :studio)
             end)

    assert_received {:managed_mutation, %ManagedMutation{} = operation}
    assert Map.from_struct(operation) == attrs
    assert Process.get({RecordingSink, :calls}) == 1
    refute_received {:managed_mutation, _duplicate}
  end

  test "normalizes sink rejection, invalid responses, exceptions, and exits without retry" do
    cases = [
      {{:error, {:tracker_secret, "DO_NOT_EXPOSE"}}, :managed_tracker_outbox_rejected},
      {:invalid_response, :managed_tracker_outbox_invalid_response},
      {:raise, :managed_tracker_outbox_failed},
      {:exit, :managed_tracker_outbox_failed}
    ]

    for {sink_result, expected_error} <- cases do
      Process.put({RecordingSink, :calls}, 0)

      response =
        put_sink_result(sink_result, fn ->
          Outbox.submit(valid_attrs(), sink: RecordingSink, source: :studio)
        end)

      assert response == {:error, expected_error}
      assert Process.get({RecordingSink, :calls}) == 1
      assert_received {:managed_mutation, %ManagedMutation{}}
      refute_received {:managed_mutation, _retry}
      refute inspect(response) =~ "DO_NOT_EXPOSE"
    end
  end

  test "invalid commands fail before sink delegation" do
    invalid = Map.put(valid_attrs(), :idempotency_key, "")

    assert {:error, {:invalid_managed_mutation, :idempotency_key, :must_be_bounded_non_empty_string}} =
             Outbox.submit(invalid, sink: RecordingSink, source: :studio)

    assert Process.get({RecordingSink, :calls}) == 0
    refute_received {:managed_mutation, _operation}
  end

  defp valid_attrs do
    %{
      operation_id: Identity.uuid4(),
      idempotency_key: "handoff:issue-123:contract-rev-7",
      issue_id: "issue-123",
      expected_revision: "contract-rev-7/eligibility-rev-9",
      action: :handoff_comment,
      payload: %{body: "Evidence verified; ready for human review.", marker: "studio-op:123"},
      reconciliation: %{kind: :comment_marker, marker: "studio-op:123"},
      causation: %{
        run_id: Identity.uuid4(),
        attempt_id: Identity.uuid4(),
        evidence_manifest_id: "manifest-123"
      },
      origin: :studio
    }
  end

  defp put_sink_result(result, callback) do
    Process.put({RecordingSink, :result}, result)
    callback.()
  end

  defp mutation_error(field, reason), do: {:invalid_managed_mutation, field, reason}

  defp field_case(field, value, reason), do: {field, value, mutation_error(field, reason)}

  defp update_case(updates, field, reason), do: {updates, mutation_error(field, reason)}
end
