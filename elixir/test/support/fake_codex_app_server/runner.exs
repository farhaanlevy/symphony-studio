# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.FakeCodexAppServer.Runner do
  @moduledoc false

  alias SymphonyElixir.Codex.SchemaBundle

  @request_mismatch_exit 64
  @malformed_client_json_exit 65
  @unexpected_eof_exit 66
  @barrier_timeout_exit 67
  @wait_poll_interval_ms 5
  @max_generated_bytes 64 * 1024 * 1024
  @client_params_schemas %{
    "initialize" => "json/v1/InitializeParams.json",
    "thread/start" => "experimental/json/v2/ThreadStartParams.json",
    "turn/start" => "experimental/json/v2/TurnStartParams.json"
  }
  @step_keys %{
    "expect" => {~w(type expected absent match), ["validation"]},
    "send_json" => {~w(type payload fragments delayMs), []},
    "stdout" => {~w(type base64 fragments delayMs), []},
    "stderr" => {~w(type base64), ~w(fragments delayMs)},
    "generated" => {~w(type stream prefixBase64 repeatBase64 repeatCount suffixBase64 fragments delayMs), []},
    "barrier" => {~w(type name timeoutMs), []},
    "sleep" => {~w(type milliseconds), []},
    "exit" => {~w(type status), []}
  }

  def main(argv) do
    {options, [], []} =
      OptionParser.parse(argv, strict: [scenario: :string, trace: :string])

    scenario_path = Keyword.fetch!(options, :scenario)
    trace_path = Keyword.fetch!(options, :trace)
    File.rm(trace_path)

    scenario = scenario_path |> File.read!() |> :json.decode()
    validate_scenario!(scenario, trace_path)

    fixture_root = Path.dirname(scenario_path)
    File.mkdir_p!(Path.join(fixture_root, "barriers"))

    state = %{fixture_root: fixture_root, seq: 0, trace_path: trace_path}
    final_state = run_steps(scenario["steps"], state)
    trace(final_state, "complete", %{})
    System.halt(0)
  end

  defp validate_scenario!(scenario, trace_path) do
    case validate_scenario(scenario) do
      :ok ->
        :ok

      {:error, reason} ->
        fail!(trace_path, 0, "invalid_scenario", reason, @request_mismatch_exit)
    end
  end

  defp validate_scenario(%{"schemaVersion" => 1, "steps" => steps} = scenario)
       when is_list(steps) do
    with :ok <- exact_scenario_keys(scenario, ["schemaVersion", "steps"], "scenario"),
         :ok <- validate_scenario_steps(steps),
         :ok <- validate_unique_names(steps, "barrier") do
      validate_exit_position(steps)
    end
  end

  defp validate_scenario(%{} = scenario) do
    {:error,
     %{
       "kind" => "unsupported_scenario",
       "schemaVersion" => scenario["schemaVersion"]
     }}
  end

  defp validate_scenario(_scenario), do: scenario_error("invalid_root", "scenario must be an object")

  defp validate_scenario_steps(steps) do
    steps
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {step, index}, :ok ->
      case validate_scenario_step(step) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, Map.put(reason, "stepIndex", index)}}
      end
    end)
  end

  defp validate_scenario_step(%{"type" => type} = step) when is_map_key(@step_keys, type) do
    {required, optional} = Map.fetch!(@step_keys, type)

    with :ok <- required_scenario_keys(step, required, "#{type} step"),
         :ok <- exact_scenario_keys(step, required ++ optional, "#{type} step") do
      validate_step_values(type, step)
    end
  end

  defp validate_scenario_step(%{} = step) do
    scenario_error("unknown_step", "unknown step type #{inspect(step["type"])}")
  end

  defp validate_scenario_step(_step), do: scenario_error("invalid_step", "scenario step must be an object")

  defp validate_step_values("expect", step) do
    validation_valid = not Map.has_key?(step, "validation") or is_map(step["validation"])

    with true <-
           is_map(step["expected"]) and valid_absent_paths?(step["absent"]) and
             step["match"] in ["exact", "subset"] and validation_valid,
         :ok <- validate_expect_contract(step) do
      :ok
    else
      false -> scenario_error("invalid_expect", "expect step fields have invalid types or values")
      {:error, _reason} = error -> error
    end
  end

  defp validate_step_values("send_json", step) do
    if is_map(step["payload"]),
      do: validate_output_values(step),
      else: scenario_error("invalid_payload", "send_json payload must be an object")
  end

  defp validate_step_values(type, step) when type in ["stdout", "stderr"] do
    with {:ok, _bytes} <- decode_scenario_base64(step["base64"], "#{type}.base64") do
      validate_output_values(step)
    end
  end

  defp validate_step_values("generated", step) do
    with true <- step["stream"] in ["stdout", "stderr"],
         {:ok, prefix} <- decode_scenario_base64(step["prefixBase64"], "generated.prefixBase64"),
         {:ok, repeated} <- decode_scenario_base64(step["repeatBase64"], "generated.repeatBase64"),
         {:ok, suffix} <- decode_scenario_base64(step["suffixBase64"], "generated.suffixBase64"),
         count when is_integer(count) and count >= 0 <- step["repeatCount"],
         true <- repeated != "" or count == 0,
         true <- byte_size(prefix) + byte_size(repeated) * count + byte_size(suffix) <= @max_generated_bytes,
         :ok <- validate_output_values(step) do
      :ok
    else
      false -> scenario_error("invalid_generated", "generated step fields are invalid")
      {:error, _reason} = error -> error
      _other -> scenario_error("invalid_generated", "generated step fields are invalid")
    end
  end

  defp validate_step_values("barrier", step) do
    if valid_name?(step["name"]) and is_integer(step["timeoutMs"]) and step["timeoutMs"] > 0,
      do: :ok,
      else: scenario_error("invalid_barrier", "barrier name or timeout is invalid")
  end

  defp validate_step_values("sleep", step) do
    if is_integer(step["milliseconds"]) and step["milliseconds"] >= 0,
      do: :ok,
      else: scenario_error("invalid_sleep", "sleep milliseconds must be a non-negative integer")
  end

  defp validate_step_values("exit", step) do
    if is_integer(step["status"]) and step["status"] >= 0,
      do: :ok,
      else: scenario_error("invalid_exit", "exit status must be a non-negative integer")
  end

  defp validate_output_values(step) do
    fragments = Map.get(step, "fragments", [])
    delay_ms = Map.get(step, "delayMs", 0)

    if valid_fragments?(fragments) and is_integer(delay_ms) and delay_ms >= 0,
      do: :ok,
      else: scenario_error("invalid_output_options", "fragments or delayMs are invalid")
  end

  defp validate_expect_contract(step) do
    expected_contract = expected_validation_contract(step["expected"])

    case {expected_contract, Map.fetch(step, "validation")} do
      {nil, :error} ->
        :ok

      {nil, {:ok, _unexpected}} ->
        scenario_error("unexpected_validation", "expect.validation is not supported")

      {_expected, :error} ->
        scenario_error("missing_validation", "expect.validation is required")

      {expected, {:ok, actual}} when expected == actual ->
        :ok

      {_expected, {:ok, _actual}} ->
        scenario_error("invalid_validation", "expect.validation does not match the pinned contract")
    end
  end

  defp expected_validation_contract(%{"method" => "initialized"}) do
    schema_contract("client_notification", "experimental/json/ClientNotification.json")
  end

  defp expected_validation_contract(%{"method" => method})
       when is_map_key(@client_params_schemas, method) do
    schema_contract("client_request", Map.fetch!(@client_params_schemas, method))
    |> Map.put("method", method)
  end

  defp expected_validation_contract(%{"result" => result}) when is_map(result) do
    case callback_response_schema(result) do
      nil -> nil
      schema_path -> schema_contract("client_response", schema_path)
    end
  end

  defp expected_validation_contract(_expected), do: nil

  defp callback_response_schema(%{"success" => _success}),
    do: "json/DynamicToolCallResponse.json"

  defp callback_response_schema(%{"permissions" => _permissions}),
    do: "json/PermissionsRequestApprovalResponse.json"

  defp callback_response_schema(%{"action" => _action}),
    do: "json/McpServerElicitationRequestResponse.json"

  defp callback_response_schema(%{"decision" => "decline"}),
    do: "json/CommandExecutionRequestApprovalResponse.json"

  defp callback_response_schema(%{"decision" => "denied"}),
    do: "json/ExecCommandApprovalResponse.json"

  defp callback_response_schema(_result), do: nil

  defp schema_contract(kind, schema_path) do
    {:ok, schema} = SchemaBundle.schema(schema_path)

    canonical_schema =
      schema
      |> Jason.encode!()
      |> :json.decode()

    %{"kind" => kind, "schema" => canonical_schema, "schemaPath" => schema_path}
  end

  defp valid_fragments?(fragments) when is_list(fragments) do
    valid_values = Enum.all?(fragments, &((is_integer(&1) and &1 > 0) or &1 == "rest"))
    rest_indexes = for {"rest", index} <- Enum.with_index(fragments), do: index
    valid_rest = rest_indexes == [] or rest_indexes == [length(fragments) - 1]
    valid_values and valid_rest
  end

  defp valid_fragments?(_fragments), do: false

  defp valid_absent_paths?(paths) when is_list(paths) do
    Enum.all?(paths, fn path ->
      is_list(path) and path != [] and Enum.all?(path, &is_binary/1)
    end)
  end

  defp valid_absent_paths?(_paths), do: false

  defp valid_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, name)

  defp valid_name?(_name), do: false

  defp decode_scenario_base64(encoded, label) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> scenario_error("invalid_base64", "#{label} is not valid base64")
    end
  end

  defp decode_scenario_base64(_encoded, label),
    do: scenario_error("invalid_base64", "#{label} must be a string")

  defp exact_scenario_keys(value, allowed, label) do
    case Map.keys(value) -- allowed do
      [] -> :ok
      extra -> scenario_error("unexpected_fields", "#{label} contains #{inspect(extra)}")
    end
  end

  defp required_scenario_keys(value, required, label) do
    case required -- Map.keys(value) do
      [] -> :ok
      missing -> scenario_error("missing_fields", "#{label} is missing #{inspect(missing)}")
    end
  end

  defp validate_unique_names(steps, type) do
    names = for %{"type" => ^type, "name" => name} <- steps, do: name

    if Enum.uniq(names) == names,
      do: :ok,
      else: scenario_error("duplicate_name", "#{type} names must be unique")
  end

  defp validate_exit_position(steps) do
    indexes =
      steps
      |> Enum.with_index()
      |> Enum.filter(fn {step, _index} -> match?(%{"type" => "exit"}, step) end)
      |> Enum.map(&elem(&1, 1))

    case indexes do
      [] -> :ok
      [index] when index == length(steps) - 1 -> :ok
      [index] -> scenario_error("non_terminal_exit", "exit at index #{index} must be final")
      _ -> scenario_error("multiple_exits", "scenario may contain at most one exit")
    end
  end

  defp scenario_error(kind, message), do: {:error, %{"kind" => kind, "message" => message}}

  # The production client intentionally closes its stdio port as soon as it
  # receives turn/completed. Commit a final JSON frame and successful exit to
  # the trace before emitting that frame so the client cannot race the
  # fixture's completion evidence. All preceding expectations have already
  # been consumed at this point, and create!/2 requires exit to be terminal.
  defp run_steps(
         [
           %{"type" => "send_json", "payload" => payload} = step,
           %{"type" => "exit", "status" => 0}
         ],
         state
       ) do
    bytes = IO.iodata_to_binary(:json.encode(payload)) <> "\n"

    state
    |> trace_stream_bytes("sent_json", bytes, step, planned_fragment_count(bytes, step))
    |> trace("exit", %{"status" => 0})
    |> trace("complete", %{})

    write_stdout(bytes, step)
    System.halt(0)
  end

  defp run_steps([step | rest], state), do: run_steps(rest, run_step(step, state))
  defp run_steps([], state), do: state

  defp run_step(%{"type" => "expect"} = step, state) do
    case IO.read(:stdio, :line) do
      :eof ->
        fail!(state.trace_path, state.seq, "unexpected_eof", step, @unexpected_eof_exit)

      {:error, reason} ->
        fail!(state.trace_path, state.seq, "stdin_error", inspect(reason), @unexpected_eof_exit)

      line when is_binary(line) ->
        handle_expected_line(line, step, state)
    end
  end

  defp run_step(%{"type" => "send_json", "payload" => payload} = step, state) do
    bytes = IO.iodata_to_binary(:json.encode(payload)) <> "\n"
    fragment_count = write_stdout(bytes, step)
    trace_stream_bytes(state, "sent_json", bytes, step, fragment_count)
  end

  defp run_step(%{"type" => "stdout", "base64" => encoded} = step, state) do
    bytes = Base.decode64!(encoded)
    fragment_count = write_stdout(bytes, step)
    trace_stream_bytes(state, "sent_stdout", bytes, step, fragment_count)
  end

  defp run_step(%{"type" => "stderr", "base64" => encoded} = step, state) do
    bytes = Base.decode64!(encoded)
    fragment_count = write_stderr(bytes, step)
    trace_stream_bytes(state, "sent_stderr", bytes, step, fragment_count)
  end

  defp run_step(%{"type" => "generated"} = step, state) do
    bytes = generated_bytes(step)

    {kind, fragment_count} =
      case step["stream"] do
        "stdout" -> {"sent_stdout", write_stdout(bytes, step)}
        "stderr" -> {"sent_stderr", write_stderr(bytes, step)}
      end

    trace_stream_bytes(state, kind, bytes, step, fragment_count)
  end

  defp run_step(%{"type" => "barrier", "name" => name, "timeoutMs" => timeout_ms}, state) do
    wait_path = Path.join([state.fixture_root, "barriers", "#{name}.waiting"])
    release_path = Path.join([state.fixture_root, "barriers", "#{name}.release"])
    released_path = Path.join([state.fixture_root, "barriers", "#{name}.released"])
    timed_out_path = Path.join([state.fixture_root, "barriers", "#{name}.timed_out"])
    waiting_state = trace(state, "barrier_waiting", %{"name" => name})
    File.write!(wait_path, "waiting\n", [:exclusive])

    if wait_for_file(release_path, timeout_ms) do
      released_state = trace(waiting_state, "barrier_released", %{"name" => name})
      File.write!(released_path, "released\n", [:exclusive])
      released_state
    else
      fail_with_marker!(
        waiting_state.trace_path,
        waiting_state.seq,
        "barrier_timeout",
        %{"name" => name, "timeoutMs" => timeout_ms},
        @barrier_timeout_exit,
        timed_out_path
      )
    end
  end

  defp run_step(%{"type" => "sleep", "milliseconds" => milliseconds}, state) do
    Process.sleep(milliseconds)
    trace(state, "slept", %{"milliseconds" => milliseconds})
  end

  defp run_step(%{"type" => "exit", "status" => status}, state) do
    exit_state = trace(state, "exit", %{"status" => status})
    if status == 0, do: trace(exit_state, "complete", %{})
    System.halt(status)
  end

  defp run_step(step, state) do
    fail!(state.trace_path, state.seq, "unknown_step", step, @request_mismatch_exit)
  end

  defp handle_expected_line(line, step, state) do
    case decode_json(line) do
      {:ok, payload} when is_map(payload) ->
        handle_expected_payload(payload, step, state)

      _ ->
        fail!(
          state.trace_path,
          state.seq,
          "malformed_client_json",
          %{"bytes" => byte_size(line), "preview" => bounded_preview(line)},
          @malformed_client_json_exit
        )
    end
  end

  defp handle_expected_payload(payload, step, state) do
    received_state = trace(state, "received", %{"payload" => payload})

    if selector_matches?(step["expected"], payload) do
      validate_expected_payload(payload, step, received_state)
    else
      request_mismatch!(payload, step, received_state)
    end
  end

  defp validate_expected_payload(payload, step, state) do
    case validate_known_payload(payload, step["validation"]) do
      :ok ->
        accept_expected_payload(payload, step, state)

      {:error, reason} ->
        rejected_state =
          trace(state, "rejected", %{
            "expected" => step["expected"],
            "reason" => reason
          })

        fail!(
          rejected_state.trace_path,
          rejected_state.seq,
          "invalid_client_payload",
          %{
            "actual" => payload,
            "expected" => step["expected"],
            "reason" => reason
          },
          @request_mismatch_exit
        )
    end
  end

  defp accept_expected_payload(payload, step, state) do
    if matches?(step["match"], step["expected"], payload) and
         absent?(step["absent"], payload) do
      state
    else
      request_mismatch!(payload, step, state)
    end
  end

  defp request_mismatch!(payload, step, state) do
    fail!(
      state.trace_path,
      state.seq,
      "request_mismatch",
      %{
        "actual" => payload,
        "expected" => step["expected"],
        "absent" => step["absent"],
        "match" => step["match"] || "exact"
      },
      @request_mismatch_exit
    )
  end

  defp selector_matches?(expected, actual) do
    Enum.all?(["id", "method"], fn key ->
      not Map.has_key?(expected, key) or Map.get(expected, key) == Map.get(actual, key)
    end)
  end

  defp matches?("subset", expected, actual), do: subset?(expected, actual)
  defp matches?(nil, expected, actual), do: expected == actual
  defp matches?("exact", expected, actual), do: expected == actual
  defp matches?(_unknown, _expected, _actual), do: false

  defp validate_known_payload(_payload, nil), do: :ok

  defp validate_known_payload(
         payload,
         %{"kind" => "client_notification", "schema" => schema, "schemaPath" => schema_path}
       ) do
    with :ok <- exact_keys(payload, ["method"], "client notification envelope") do
      validate_schema(payload, schema, schema_path)
    end
  end

  defp validate_known_payload(
         payload,
         %{
           "kind" => "client_request",
           "method" => method,
           "schema" => schema,
           "schemaPath" => schema_path
         }
       ) do
    with :ok <- required_keys(payload, ["id", "method", "params"], "client request envelope"),
         :ok <- exact_keys(payload, ["id", "method", "params"], "client request envelope"),
         :ok <- request_id(payload["id"]),
         :ok <- exact_method(payload["method"], method),
         :ok <- require_map(payload["params"], "client request params"),
         :ok <- validate_schema(payload["params"], schema, schema_path),
         :ok <- exact_schema_properties(payload["params"], schema, "#{method} params") do
      validate_turn_sandbox_policy(method, payload["params"])
    end
  end

  defp validate_known_payload(
         payload,
         %{"kind" => "client_response", "schema" => schema, "schemaPath" => schema_path}
       ) do
    with :ok <- required_keys(payload, ["id", "result"], "client response envelope"),
         :ok <- exact_keys(payload, ["id", "result"], "client response envelope"),
         :ok <- request_id(payload["id"]),
         :ok <- require_map(payload["result"], "client response result"),
         :ok <- validate_schema(payload["result"], schema, schema_path),
         :ok <- exact_schema_properties(payload["result"], schema, "client response result") do
      validate_dynamic_tool_content(payload["result"], schema_path)
    end
  end

  defp validate_known_payload(_payload, validation) do
    {:error,
     %{
       "kind" => "unsupported_validation_contract",
       "validationKind" => validation["kind"]
     }}
  end

  defp validate_schema(payload, schema, schema_path) do
    case schema |> Xema.from_json_schema() |> Xema.validate(payload) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         %{
           "kind" => "schema_violation",
           "schemaPath" => schema_path,
           "message" => Exception.message(error)
         }}
    end
  rescue
    error ->
      {:error,
       %{
         "kind" => "schema_validation_error",
         "schemaPath" => schema_path,
         "message" => Exception.message(error)
       }}
  end

  defp exact_schema_properties(payload, %{"properties" => properties}, label)
       when is_map(payload) and is_map(properties) do
    exact_keys(payload, Map.keys(properties), label)
  end

  defp exact_schema_properties(_payload, _schema, label) do
    validation_error("invalid_schema_contract", "#{label} schema does not advertise properties")
  end

  defp required_keys(payload, required, label) when is_map(payload) do
    case required -- Map.keys(payload) do
      [] -> :ok
      missing -> validation_error("missing_fields", "#{label} is missing #{inspect(missing)}")
    end
  end

  defp exact_keys(payload, allowed, label) when is_map(payload) do
    case Map.keys(payload) -- allowed do
      [] -> :ok
      unexpected -> validation_error("unexpected_fields", "#{label} contains #{inspect(unexpected)}")
    end
  end

  defp request_id(id) when is_integer(id) or is_binary(id), do: :ok
  defp request_id(_id), do: validation_error("invalid_request_id", "request id must be an integer or string")

  defp exact_method(method, method), do: :ok

  defp exact_method(actual, expected) do
    validation_error("unexpected_method", "expected #{inspect(expected)}, got #{inspect(actual)}")
  end

  defp require_map(value, _label) when is_map(value), do: :ok
  defp require_map(_value, label), do: validation_error("invalid_object", "#{label} must be an object")

  defp validate_turn_sandbox_policy("turn/start", params) do
    case Map.fetch(params, "sandboxPolicy") do
      :error -> :ok
      {:ok, policy} -> turn_sandbox_policy(policy)
    end
  end

  defp validate_turn_sandbox_policy(_method, _params), do: :ok

  defp turn_sandbox_policy(%{"type" => "dangerFullAccess"} = policy) do
    exact_keys(policy, ["type"], "dangerFullAccess sandbox policy")
  end

  defp turn_sandbox_policy(%{"type" => "readOnly"} = policy) do
    with :ok <- exact_keys(policy, ["type", "networkAccess"], "readOnly sandbox policy") do
      optional_boolean(policy, "networkAccess")
    end
  end

  defp turn_sandbox_policy(%{"type" => "externalSandbox"} = policy) do
    with :ok <- exact_keys(policy, ["type", "networkAccess"], "externalSandbox sandbox policy") do
      optional_enum(policy, "networkAccess", ["restricted", "enabled"])
    end
  end

  defp turn_sandbox_policy(%{"type" => "workspaceWrite"} = policy) do
    allowed = ["type", "writableRoots", "networkAccess", "excludeTmpdirEnvVar", "excludeSlashTmp"]

    with :ok <- exact_keys(policy, allowed, "workspaceWrite sandbox policy"),
         :ok <- optional_boolean(policy, "networkAccess"),
         :ok <- optional_boolean(policy, "excludeTmpdirEnvVar"),
         :ok <- optional_boolean(policy, "excludeSlashTmp") do
      optional_absolute_paths(policy, "writableRoots")
    end
  end

  defp turn_sandbox_policy(_policy) do
    validation_error("invalid_sandbox_policy", "sandboxPolicy is not a pinned policy variant")
  end

  defp optional_boolean(value, key) do
    case Map.fetch(value, key) do
      :error -> :ok
      {:ok, nested} when is_boolean(nested) -> :ok
      {:ok, _nested} -> validation_error("invalid_boolean", "#{key} must be a boolean")
    end
  end

  defp optional_enum(value, key, allowed) do
    case Map.fetch(value, key) do
      :error ->
        :ok

      {:ok, nested} ->
        if nested in allowed do
          :ok
        else
          validation_error("invalid_enum", "#{key} has unsupported value #{inspect(nested)}")
        end
    end
  end

  defp optional_absolute_paths(value, key) do
    case Map.fetch(value, key) do
      :error ->
        :ok

      {:ok, roots} when is_list(roots) ->
        if Enum.all?(roots, &normalized_absolute_path?/1) do
          :ok
        else
          validation_error("invalid_paths", "#{key} must contain normalized absolute paths")
        end

      {:ok, _roots} ->
        validation_error("invalid_paths", "#{key} must be a list")
    end
  end

  defp normalized_absolute_path?(path) when is_binary(path) and path != "" do
    Path.type(path) == :absolute and Path.expand(path) == path
  end

  defp normalized_absolute_path?(_path), do: false

  defp validate_dynamic_tool_content(result, "json/DynamicToolCallResponse.json") do
    result
    |> Map.get("contentItems", [])
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case dynamic_tool_content_item(item) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_dynamic_tool_content(_result, _schema_path), do: :ok

  defp dynamic_tool_content_item(%{"type" => "inputText", "text" => text} = item)
       when is_binary(text) do
    exact_keys(item, ["type", "text"], "inputText dynamic-tool content item")
  end

  defp dynamic_tool_content_item(%{"type" => "inputImage", "imageUrl" => image_url} = item)
       when is_binary(image_url) do
    exact_keys(item, ["type", "imageUrl"], "inputImage dynamic-tool content item")
  end

  defp dynamic_tool_content_item(_item) do
    validation_error("invalid_content_item", "dynamic-tool content item is not a pinned variant")
  end

  defp validation_error(kind, message), do: {:error, %{"kind" => kind, "message" => message}}

  defp write_stdout(bytes, step), do: write_stream(:stdio, bytes, step)
  defp write_stderr(bytes, step), do: write_stream(:stderr, bytes, step)

  defp write_stream(device, bytes, step) do
    delay_ms = step["delayMs"] || 0
    fragments = step["fragments"] || []

    with_binary_encoding(device, fn ->
      {remaining, fragment_count} =
        Enum.reduce(fragments, {bytes, 0}, &write_fragment(device, &1, &2, delay_ms))

      if remaining != "", do: IO.binwrite(device, remaining)
      fragment_count + if(remaining == "", do: 0, else: 1)
    end)
  end

  defp write_fragment(device, fragment, {pending, count}, delay_ms) do
    size = if fragment == "rest", do: byte_size(pending), else: min(fragment, byte_size(pending))
    <<part::binary-size(size), rest::binary>> = pending
    IO.binwrite(device, part)
    maybe_delay(delay_ms)
    {rest, count + 1}
  end

  defp maybe_delay(delay_ms) when delay_ms > 0, do: Process.sleep(delay_ms)
  defp maybe_delay(_delay_ms), do: :ok

  defp with_binary_encoding(device, write) do
    io_device = if device == :stdio, do: :standard_io, else: :standard_error
    :ok = :io.setopts(io_device, encoding: :latin1)

    try do
      write.()
    after
      :ok = :io.setopts(io_device, encoding: :unicode)
    end
  end

  defp planned_fragment_count(bytes, step) do
    remaining_bytes =
      Enum.reduce(step["fragments"] || [], byte_size(bytes), fn fragment, remaining ->
        if fragment == "rest", do: 0, else: max(remaining - fragment, 0)
      end)

    length(step["fragments"] || []) + if(remaining_bytes == 0, do: 0, else: 1)
  end

  defp generated_bytes(step) do
    prefix = Base.decode64!(step["prefixBase64"])
    repeated = Base.decode64!(step["repeatBase64"])
    suffix = Base.decode64!(step["suffixBase64"])
    prefix <> :binary.copy(repeated, step["repeatCount"]) <> suffix
  end

  defp wait_for_file(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_file(path, deadline)
  end

  defp do_wait_for_file(path, deadline) do
    cond do
      File.regular?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@wait_poll_interval_ms)
        do_wait_for_file(path, deadline)
    end
  end

  defp decode_json(line) do
    {:ok, :json.decode(line)}
  rescue
    _error -> {:error, :malformed_json}
  end

  defp subset?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} -> Map.has_key?(actual, key) and subset?(value, actual[key]) end)
  end

  defp subset?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      Enum.zip(expected, actual) |> Enum.all?(fn {left, right} -> subset?(left, right) end)
  end

  defp subset?(expected, actual), do: expected == actual

  defp absent?(paths, payload) when is_list(paths) do
    Enum.all?(paths, fn path -> get_in_path(payload, path) == :missing end)
  end

  defp get_in_path(value, []), do: value

  defp get_in_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, nested} -> get_in_path(nested, rest)
      :error -> :missing
    end
  end

  defp get_in_path(_value, _path), do: :missing

  defp trace_stream_bytes(state, kind, bytes, step, fragment_count) do
    trace(state, kind, %{
      "bytes" => byte_size(bytes),
      "delayMs" => step["delayMs"] || 0,
      "fragmentCount" => fragment_count,
      "fragments" => step["fragments"] || [],
      "preview" => bounded_preview(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    })
  end

  defp bounded_preview(bytes) do
    {preview, suffix} =
      if byte_size(bytes) > 256,
        do: {binary_part(bytes, 0, 256), "...<truncated>"},
        else: {bytes, ""}

    String.replace_invalid(preview) <> suffix
  end

  defp trace(state, kind, details) do
    next_state = %{state | seq: state.seq + 1}

    record =
      details
      |> Map.merge(%{"kind" => kind, "schemaVersion" => 1, "seq" => next_state.seq})
      |> :json.encode()
      |> IO.iodata_to_binary()

    File.write!(state.trace_path, record <> "\n", [:append])
    next_state
  end

  defp fail!(trace_path, sequence, kind, details, status) do
    record_failure(trace_path, sequence, kind, details, status)
    halt_failure!(kind, status)
  end

  defp fail_with_marker!(trace_path, sequence, kind, details, status, marker_path) do
    record_failure(trace_path, sequence, kind, details, status)
    File.write!(marker_path, "timed_out\n", [:exclusive])
    halt_failure!(kind, status)
  end

  defp record_failure(trace_path, sequence, kind, details, status) do
    state = %{seq: sequence, trace_path: trace_path}
    trace(state, "failure", %{"failureKind" => kind, "details" => details, "status" => status})
  end

  defp halt_failure!(kind, status) do
    IO.puts(:stderr, "fake-codex-app-server: #{kind}")
    System.halt(status)
  end
end

SymphonyElixir.TestSupport.FakeCodexAppServer.Runner.main(System.argv())
