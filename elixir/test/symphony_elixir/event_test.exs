# Downstream modification notice (2026-07-16): Symphony Studio verifies the
# canonical public event envelope, identity, redaction, and payload bounds.
defmodule SymphonyElixir.EventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Event, Identity}

  @run_id "00010203-0405-4607-8809-0a0b0c0d0e0f"
  @attempt_id "10111213-1415-4617-9819-1a1b1c1d1e1f"
  @operation_id "20212223-2425-4627-a829-2a2b2c2d2e2f"
  @expected_event_id "9bb225cf-47f1-56e0-babe-7c9d8fee7d9c"
  @occurred_at ~U[2026-07-13 12:34:56.123Z]

  test "builds and serializes the exact version-one public envelope" do
    assert {:ok, event} = Event.new(valid_attributes())
    assert event.event_id == @expected_event_id
    assert event.schema_version == 1
    assert event.redacted
    assert Identity.valid_uuid5?(event.event_id)

    assert Event.to_map(event) == %{
             "schema_version" => 1,
             "event_id" => @expected_event_id,
             "sequence" => 1,
             "occurred_at" => "2026-07-13T12:34:56.123Z",
             "issue_id" => "linear-id",
             "issue_identifier" => "SYM-123",
             "run_id" => @run_id,
             "attempt_id" => @attempt_id,
             "thread_id" => nil,
             "turn_id" => nil,
             "type" => "quality.check.completed",
             "severity" => "info",
             "payload" => %{"check" => "unit", "passed" => true},
             "redacted" => true
           }

    assert {:ok, ^event} = Event.new(Map.put(valid_attributes(), :event_id, @expected_event_id))
    assert Event.validate(event) == :ok
  end

  test "serializes optional operation correlation only when present" do
    without_operation = Event.new!(valid_attributes(%{thread_id: "thr_123", turn_id: "turn_456"}))
    refute Map.has_key?(Event.to_map(without_operation), "operation_id")

    with_operation = Event.new!(valid_attributes(%{operation_id: @operation_id}))
    assert Event.to_map(with_operation)["operation_id"] == @operation_id
  end

  test "event identity is stable for exact replay and independent of mutable payload content" do
    first = Event.new!(valid_attributes())

    replay =
      Event.new!(
        valid_attributes(%{
          occurred_at: ~U[2026-07-13 12:35:00Z],
          payload: %{"check" => "different-public-content"}
        })
      )

    assert first.event_id == replay.event_id
    refute first == replay
    refute first.event_id == Event.new!(valid_attributes(%{sequence: 2})).event_id
    refute first.event_id == Event.new!(valid_attributes(%{type: "quality.check.started"})).event_id

    other_run = "30313233-3435-4637-b839-3a3b3c3d3e3f"
    refute first.event_id == Event.new!(valid_attributes(%{run_id: other_run})).event_id
  end

  test "requires canonical atom-key attributes and rejects ambiguous constructors" do
    assert {:ok, _event} = Event.new(Map.to_list(valid_attributes()))

    assert Event.new(%{"run_id" => @run_id}) ==
             {:error, {:attributes, :atom_keys_required}}

    assert Event.new(Map.put(valid_attributes(), :unknown, true)) ==
             {:error, {:attributes, {:unknown_keys, [:unknown]}}}

    assert Event.new([{:sequence, 1}, {:sequence, 2}]) ==
             {:error, {:attributes, :duplicate_keys}}

    assert Event.new([{"sequence", 1}]) ==
             {:error, {:attributes, :atom_keys_required}}

    assert Event.new(:invalid) == {:error, {:attributes, :must_be_map_or_keyword}}
  end

  test "requires every canonical caller-supplied field including nullable thread and turn IDs" do
    for field <- [
          :sequence,
          :occurred_at,
          :issue_id,
          :issue_identifier,
          :run_id,
          :attempt_id,
          :thread_id,
          :turn_id,
          :type,
          :severity,
          :payload
        ] do
      assert Event.new(Map.delete(valid_attributes(), field)) == {:error, {field, :required}}
    end
  end

  test "rejects fixed-field overrides and forged event identities" do
    assert_error(%{schema_version: 2}, {:schema_version, {:must_equal, 1}})
    assert_error(%{redacted: false}, {:redacted, {:must_equal, true}})

    assert Event.new(Map.put(valid_attributes(), :event_id, Identity.uuid4())) ==
             {:error, {:event_id, :does_not_match_identity}}

    event = Event.new!(valid_attributes())
    forged = %{event | event_id: Identity.uuid4()}
    assert Event.validate(forged) == {:error, {:event_id, :does_not_match_identity}}

    assert_raise ArgumentError, ~r/does_not_match_identity/, fn -> Event.to_map(forged) end
    assert_raise ArgumentError, ~r/must_equal/, fn -> Event.new!(valid_attributes(%{redacted: nil})) end
  end

  test "validates positive sequencing and UTC ISO timestamps" do
    for sequence <- [0, -1, 1.5, "1", nil] do
      assert_error(%{sequence: sequence}, {:sequence, :must_be_positive_integer})
    end

    assert_error(%{occurred_at: NaiveDateTime.utc_now()}, {:occurred_at, :must_be_utc_datetime})

    non_utc = %{@occurred_at | time_zone: "Africa/Johannesburg", utc_offset: 7_200}
    assert_error(%{occurred_at: non_utc}, {:occurred_at, :must_be_utc_datetime})

    invalid_date = %{@occurred_at | month: 13}
    assert_error(%{occurred_at: invalid_date}, {:occurred_at, :must_be_utc_datetime})

    forged = %{@occurred_at | year: nil}
    assert_error(%{occurred_at: forged}, {:occurred_at, :must_be_utc_datetime})
  end

  test "validates required identifiers and canonical UUIDv4 correlation IDs" do
    assert_error(%{issue_id: ""}, {:issue_id, :must_be_non_empty_string})
    assert_error(%{issue_identifier: nil}, {:issue_identifier, :must_be_non_empty_string})
    assert_error(%{issue_id: :id}, {:issue_id, :must_be_non_empty_string})
    assert_error(%{issue_id: :binary.copy("i", 513)}, {:issue_id, {:too_long, 512}})
    assert_error(%{issue_id: <<255>>}, {:issue_id, :invalid_utf8})

    assert_error(%{run_id: String.upcase(@run_id)}, {:run_id, :must_be_canonical_uuid4})
    assert_error(%{run_id: nil}, {:run_id, :must_be_canonical_uuid4})
    assert_error(%{attempt_id: Identity.uuid5(@run_id, "attempt")}, {:attempt_id, :must_be_canonical_uuid4})
    assert_error(%{operation_id: "invalid"}, {:operation_id, :must_be_canonical_uuid4})
    assert_error(%{operation_id: String.upcase(@operation_id)}, {:operation_id, :must_be_canonical_uuid4})

    assert Event.new!(valid_attributes(%{thread_id: nil, turn_id: nil})).thread_id == nil
    assert_error(%{thread_id: ""}, {:thread_id, :must_be_non_empty_string})
    assert_error(%{turn_id: :binary.copy("t", 513)}, {:turn_id, {:too_long, 512}})
    assert_error(%{turn_id: <<255>>}, {:turn_id, :invalid_utf8})
  end

  test "requires normalized dotted public event types and known severities" do
    for type <- ["quality", "Quality.check", "quality..check", "quality.check-ended", :quality, nil] do
      assert_error(%{type: type}, {:type, :must_be_normalized_dotted_type})
    end

    assert_error(%{type: <<255>>}, {:type, :must_be_normalized_dotted_type})

    assert_error(%{type: "quality." <> :binary.copy("x", 129)}, {:type, :must_be_normalized_dotted_type})

    for severity <- ["warn", "INFO", :info, nil] do
      assert_error(%{severity: severity}, {:severity, :unsupported})
    end

    for severity <- ["debug", "info", "warning", "error", "critical"] do
      assert Event.new!(valid_attributes(%{severity: severity})).severity == severity
    end
  end

  test "accepts nested JSON-safe public payload values" do
    payload = %{
      "array" => [nil, true, false, 1, -2, 1.5, "value"],
      "nested" => %{"empty" => %{}, "items" => []}
    }

    assert Event.new!(valid_attributes(%{payload: payload})).payload == payload

    assert Event.payload_limits() == %{
             encoded_bytes: 65_536,
             depth: 16,
             nodes: 4_096,
             key_bytes: 256,
             string_bytes: 16_384
           }
  end

  test "rejects non-object, non-JSON, atom-keyed, and invalid UTF-8 payloads" do
    assert_error(%{payload: []}, {:payload, :must_be_json_object})
    assert_error(%{payload: %{"unsafe" => {:tuple, 1}}}, {:payload, :not_json_safe})
    assert_error(%{payload: %{"unsafe" => [1 | 2]}}, {:payload, :not_json_safe})
    assert_error(%{payload: %{atom_key: "value"}}, {:payload, :string_keys_required})
    assert_error(%{payload: %{"value" => <<255>>}}, {:payload, :invalid_utf8})
    assert_error(%{payload: %{<<255>> => "value"}}, {:payload, :invalid_utf8})
  end

  test "enforces payload key, string, depth, node, raw-content, and encoded-size limits" do
    assert_error(
      %{payload: %{:binary.copy("k", 257) => "value"}},
      {:payload, {:key_too_long, 256}}
    )

    assert_error(
      %{payload: %{"value" => :binary.copy("x", 16_385)}},
      {:payload, {:string_too_long, 16_384}}
    )

    too_deep = Enum.reduce(1..17, "leaf", fn _index, nested -> [nested] end)
    assert_error(%{payload: %{"nested" => too_deep}}, {:payload, {:too_deep, 16}})

    too_many_nodes = %{"items" => List.duplicate(0, 4_096)}
    assert_error(%{payload: too_many_nodes}, {:payload, {:too_many_nodes, 4_096}})

    raw_too_large =
      1..5
      |> Map.new(fn index -> {Integer.to_string(index), :binary.copy("x", 16_000)} end)

    assert_error(
      %{payload: raw_too_large},
      {:payload, {:raw_content_too_large, 65_536}}
    )

    assert_error(
      %{payload: %{"escaped" => :binary.copy(<<0>>, 12_000)}},
      {:payload, {:encoded_too_large, 65_536}}
    )
  end

  test "public validation and identity helpers fail closed on wrong input shapes" do
    assert Event.validate(%{}) == {:error, {:event, :must_be_event_struct}}

    for arguments <- [
          {"invalid", 1, "quality.check.completed"},
          {@run_id, 0, "quality.check.completed"},
          {@run_id, 1, "quality"},
          {@run_id, 1, nil}
        ] do
      assert_raise ArgumentError, ~r/event identity requires/, fn ->
        apply(Event, :event_id, Tuple.to_list(arguments))
      end
    end
  end

  defp valid_attributes(overrides \\ %{}) do
    Map.merge(
      %{
        sequence: 1,
        occurred_at: @occurred_at,
        issue_id: "linear-id",
        issue_identifier: "SYM-123",
        run_id: @run_id,
        attempt_id: @attempt_id,
        thread_id: nil,
        turn_id: nil,
        type: "quality.check.completed",
        severity: "info",
        payload: %{"check" => "unit", "passed" => true}
      },
      overrides
    )
  end

  defp assert_error(overrides, expected) do
    assert Event.new(valid_attributes(overrides)) == {:error, expected}
  end
end
