# Downstream modification notice (2026-07-16): Symphony Studio adds the
# canonical, redacted event envelope used by its structured event sinks.
defmodule SymphonyElixir.Event do
  @moduledoc """
  The version-one public event envelope defined by `STUDIO_SPEC.md`.

  Event values are immutable Elixir structs. `event_id` is a UUIDv5 derived
  from the event namespace plus `run_id`, `sequence`, and `type`; replaying the
  same logical event therefore produces the same identity. Public payloads are
  string-keyed JSON objects with explicit depth, node, string, and encoded-size
  limits. Provider-native payloads do not belong in this envelope.
  """

  alias SymphonyElixir.Identity

  @schema_version 1
  @event_namespace "e74f97e2-b537-5c35-981e-5d7cbfbda974"
  @max_identifier_bytes 512
  @max_type_bytes 128
  @max_payload_bytes 65_536
  @max_payload_depth 16
  @max_payload_nodes 4_096
  @max_payload_key_bytes 256
  @max_payload_string_bytes 16_384
  @type_pattern ~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
  @severities MapSet.new(["debug", "info", "warning", "error", "critical"])

  @enforce_keys [
    :schema_version,
    :event_id,
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
    :payload,
    :redacted
  ]
  defstruct @enforce_keys ++ [operation_id: nil]

  @type severity :: String.t()
  @type payload :: %{optional(String.t()) => term()}
  @type validation_error :: {atom(), term()}
  @type t :: %__MODULE__{
          schema_version: 1,
          event_id: Identity.uuid(),
          sequence: pos_integer(),
          occurred_at: DateTime.t(),
          issue_id: String.t(),
          issue_identifier: String.t(),
          run_id: Identity.uuid(),
          attempt_id: Identity.uuid(),
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          type: String.t(),
          severity: severity(),
          payload: payload(),
          redacted: true,
          operation_id: Identity.uuid() | nil
        }

  @required_attributes [
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
  ]
  @allowed_attributes MapSet.new(
                        @required_attributes ++
                          [:schema_version, :event_id, :redacted, :operation_id]
                      )

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, validation_error()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         :ok <- require_attributes(attributes),
         event = build_unidentified_event(attributes),
         :ok <- validate_content(event),
         expected_event_id = event_id(event.run_id, event.sequence, event.type),
         :ok <- validate_supplied_event_id(attributes, expected_event_id),
         event = %{event | event_id: expected_event_id},
         :ok <- validate(event) do
      {:ok, event}
    end
  end

  @spec new!(map() | keyword()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, event} -> event
      {:error, reason} -> raise ArgumentError, "invalid Symphony event: #{inspect(reason)}"
    end
  end

  @spec validate(term()) :: :ok | {:error, validation_error()}
  def validate(%__MODULE__{} = event) do
    with :ok <- validate_content(event) do
      expected_event_id = event_id(event.run_id, event.sequence, event.type)
      validate_exact_event_id(event.event_id, expected_event_id)
    end
  end

  def validate(_event), do: {:error, {:event, :must_be_event_struct}}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    case validate(event) do
      :ok -> serialize(event)
      {:error, reason} -> raise ArgumentError, "invalid Symphony event: #{inspect(reason)}"
    end
  end

  @spec event_id(Identity.uuid(), pos_integer(), String.t()) :: Identity.uuid()
  def event_id(run_id, sequence, type) do
    unless canonical_uuid4?(run_id) and is_integer(sequence) and sequence > 0 and
             normalized_type?(type) do
      raise ArgumentError, "event identity requires a canonical run UUID, positive sequence, and dotted type"
    end

    name =
      ["symphony-studio-event-v1", run_id, Integer.to_string(sequence), type]
      |> Enum.join(<<0>>)

    Identity.uuid5(@event_namespace, name)
  end

  @spec payload_limits() :: %{
          encoded_bytes: pos_integer(),
          depth: pos_integer(),
          nodes: pos_integer(),
          key_bytes: pos_integer(),
          string_bytes: pos_integer()
        }
  def payload_limits do
    %{
      encoded_bytes: @max_payload_bytes,
      depth: @max_payload_depth,
      nodes: @max_payload_nodes,
      key_bytes: @max_payload_key_bytes,
      string_bytes: @max_payload_string_bytes
    }
  end

  defp normalize_attributes(attributes) when is_map(attributes) do
    keys = Map.keys(attributes)

    if Enum.all?(keys, &is_atom/1) do
      unknown_keys = Enum.reject(keys, &MapSet.member?(@allowed_attributes, &1))

      case unknown_keys do
        [] -> {:ok, attributes}
        _other -> {:error, {:attributes, {:unknown_keys, Enum.sort(unknown_keys)}}}
      end
    else
      {:error, {:attributes, :atom_keys_required}}
    end
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    cond do
      not Keyword.keyword?(attributes) ->
        {:error, {:attributes, :atom_keys_required}}

      length(attributes) != attributes |> Keyword.keys() |> MapSet.new() |> MapSet.size() ->
        {:error, {:attributes, :duplicate_keys}}

      true ->
        attributes |> Map.new() |> normalize_attributes()
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:attributes, :must_be_map_or_keyword}}

  defp require_attributes(attributes) do
    case Enum.find(@required_attributes, &(not Map.has_key?(attributes, &1))) do
      nil -> :ok
      missing -> {:error, {missing, :required}}
    end
  end

  defp build_unidentified_event(attributes) do
    defaults = %{schema_version: @schema_version, event_id: nil, redacted: true, operation_id: nil}
    struct!(__MODULE__, Map.merge(defaults, attributes))
  end

  defp validate_supplied_event_id(attributes, expected_event_id) do
    case Map.fetch(attributes, :event_id) do
      :error -> :ok
      {:ok, ^expected_event_id} -> :ok
      {:ok, _other} -> {:error, {:event_id, :does_not_match_identity}}
    end
  end

  defp validate_content(event) do
    with :ok <- exact(event.schema_version, @schema_version, :schema_version),
         :ok <- positive_integer(event.sequence, :sequence),
         :ok <- utc_datetime(event.occurred_at),
         :ok <- non_empty_string(event.issue_id, :issue_id, @max_identifier_bytes),
         :ok <- non_empty_string(event.issue_identifier, :issue_identifier, @max_identifier_bytes),
         :ok <- uuid4(event.run_id, :run_id),
         :ok <- uuid4(event.attempt_id, :attempt_id),
         :ok <- nullable_string(event.thread_id, :thread_id, @max_identifier_bytes),
         :ok <- nullable_string(event.turn_id, :turn_id, @max_identifier_bytes),
         :ok <- normalized_type(event.type),
         :ok <- severity(event.severity),
         :ok <- public_payload(event.payload),
         :ok <- exact(event.redacted, true, :redacted) do
      nullable_uuid4(event.operation_id, :operation_id)
    end
  end

  defp validate_exact_event_id(event_id, expected_event_id) do
    if event_id == expected_event_id do
      :ok
    else
      {:error, {:event_id, :does_not_match_identity}}
    end
  end

  defp exact(value, value, _field), do: :ok
  defp exact(_actual, expected, field), do: {:error, {field, {:must_equal, expected}}}

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, field), do: {:error, {field, :must_be_positive_integer}}

  defp utc_datetime(
         %DateTime{
           calendar: Calendar.ISO,
           time_zone: time_zone,
           utc_offset: 0,
           std_offset: 0
         } = value
       )
       when time_zone in ["Etc/UTC", "UTC"] do
    case value |> DateTime.to_iso8601() |> DateTime.from_iso8601() do
      {:ok, %DateTime{}, 0} -> :ok
      _invalid -> {:error, {:occurred_at, :must_be_utc_datetime}}
    end
  rescue
    _error -> {:error, {:occurred_at, :must_be_utc_datetime}}
  end

  defp utc_datetime(_value), do: {:error, {:occurred_at, :must_be_utc_datetime}}

  defp non_empty_string(value, field, max_bytes)
       when is_binary(value) and value != "" and byte_size(value) <= max_bytes do
    if String.valid?(value), do: :ok, else: {:error, {field, :invalid_utf8}}
  end

  defp non_empty_string(value, field, max_bytes) when is_binary(value) and byte_size(value) > max_bytes,
    do: {:error, {field, {:too_long, max_bytes}}}

  defp non_empty_string(_value, field, _max_bytes),
    do: {:error, {field, :must_be_non_empty_string}}

  defp nullable_string(nil, _field, _max_bytes), do: :ok
  defp nullable_string(value, field, max_bytes), do: non_empty_string(value, field, max_bytes)

  defp uuid4(value, field) do
    if canonical_uuid4?(value), do: :ok, else: {:error, {field, :must_be_canonical_uuid4}}
  end

  defp nullable_uuid4(nil, _field), do: :ok
  defp nullable_uuid4(value, field), do: uuid4(value, field)

  defp canonical_uuid4?(value) when is_binary(value),
    do: value == String.downcase(value) and Identity.valid_uuid4?(value)

  defp canonical_uuid4?(_value), do: false

  defp normalized_type(value) do
    if normalized_type?(value), do: :ok, else: {:error, {:type, :must_be_normalized_dotted_type}}
  end

  defp normalized_type?(value) when is_binary(value),
    do: byte_size(value) <= @max_type_bytes and Regex.match?(@type_pattern, value)

  defp normalized_type?(_value), do: false

  defp severity(value) do
    if MapSet.member?(@severities, value),
      do: :ok,
      else: {:error, {:severity, :unsupported}}
  end

  defp public_payload(payload) when is_map(payload) do
    limits = %{nodes: @max_payload_nodes, bytes: @max_payload_bytes}

    with {:ok, _remaining} <- json_value(payload, 0, limits),
         {:ok, encoded} <- Jason.encode(payload),
         true <- byte_size(encoded) <= @max_payload_bytes do
      :ok
    else
      {:error, reason} -> {:error, {:payload, reason}}
      false -> {:error, {:payload, {:encoded_too_large, @max_payload_bytes}}}
    end
  end

  defp public_payload(_payload), do: {:error, {:payload, :must_be_json_object}}

  defp json_value(_value, depth, _limits) when depth > @max_payload_depth,
    do: {:error, {:too_deep, @max_payload_depth}}

  defp json_value(_value, _depth, %{nodes: 0}), do: {:error, {:too_many_nodes, @max_payload_nodes}}

  defp json_value(value, _depth, limits) when is_binary(value) do
    cond do
      not String.valid?(value) -> {:error, :invalid_utf8}
      byte_size(value) > @max_payload_string_bytes -> {:error, {:string_too_long, @max_payload_string_bytes}}
      true -> consume(limits, byte_size(value))
    end
  end

  defp json_value(value, _depth, limits)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: consume(limits, scalar_bytes(value))

  defp json_value(value, depth, limits) when is_list(value) do
    with {:ok, limits} <- consume(limits, 2) do
      reduce_json_list(value, depth, limits)
    end
  end

  defp json_value(value, depth, limits) when is_map(value) do
    with {:ok, limits} <- consume(limits, 2) do
      reduce_json_map(value, depth, limits)
    end
  end

  defp json_value(_value, _depth, _limits), do: {:error, :not_json_safe}

  defp reduce_json_list([], _depth, limits), do: {:ok, limits}

  defp reduce_json_list([item | rest], depth, limits) do
    with {:ok, next} <- json_value(item, depth + 1, limits) do
      reduce_json_list(rest, depth, next)
    end
  end

  defp reduce_json_list(_improper_tail, _depth, _limits), do: {:error, :not_json_safe}

  defp reduce_json_map(value, depth, limits) do
    Enum.reduce_while(value, {:ok, limits}, fn entry, {:ok, remaining} ->
      case validate_json_entry(entry, depth, remaining) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_json_entry({key, nested}, depth, remaining) when is_binary(key) do
    with :ok <- validate_payload_key(key),
         {:ok, remaining} <- consume_bytes(remaining, byte_size(key)) do
      json_value(nested, depth + 1, remaining)
    end
  end

  defp validate_json_entry({_key, _nested}, _depth, _remaining),
    do: {:error, :string_keys_required}

  defp validate_payload_key(key) do
    cond do
      not String.valid?(key) -> {:error, :invalid_utf8}
      byte_size(key) > @max_payload_key_bytes -> {:error, {:key_too_long, @max_payload_key_bytes}}
      true -> :ok
    end
  end

  defp consume(%{nodes: nodes} = limits, observed_bytes) do
    with {:ok, limits} <- consume_bytes(limits, observed_bytes) do
      {:ok, %{limits | nodes: nodes - 1}}
    end
  end

  defp consume_bytes(%{bytes: bytes}, observed_bytes) when observed_bytes > bytes,
    do: {:error, {:raw_content_too_large, @max_payload_bytes}}

  defp consume_bytes(%{bytes: bytes} = limits, observed_bytes),
    do: {:ok, %{limits | bytes: bytes - observed_bytes}}

  defp scalar_bytes(nil), do: 4
  defp scalar_bytes(true), do: 4
  defp scalar_bytes(false), do: 5
  defp scalar_bytes(value) when is_integer(value), do: value |> Integer.to_string() |> byte_size()
  defp scalar_bytes(value) when is_float(value), do: value |> :erlang.float_to_binary([:compact]) |> byte_size()

  defp serialize(event) do
    %{
      "schema_version" => event.schema_version,
      "event_id" => event.event_id,
      "sequence" => event.sequence,
      "occurred_at" => DateTime.to_iso8601(event.occurred_at),
      "issue_id" => event.issue_id,
      "issue_identifier" => event.issue_identifier,
      "run_id" => event.run_id,
      "attempt_id" => event.attempt_id,
      "thread_id" => event.thread_id,
      "turn_id" => event.turn_id,
      "type" => event.type,
      "severity" => event.severity,
      "payload" => event.payload,
      "redacted" => event.redacted
    }
    |> maybe_put_operation_id(event.operation_id)
  end

  defp maybe_put_operation_id(payload, nil), do: payload
  defp maybe_put_operation_id(payload, operation_id), do: Map.put(payload, "operation_id", operation_id)
end
