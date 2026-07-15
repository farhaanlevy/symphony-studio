# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.FakeCodexAppServer.Runner do
  @moduledoc false

  @request_mismatch_exit 64
  @malformed_client_json_exit 65
  @unexpected_eof_exit 66

  def main(argv) do
    {options, [], []} =
      OptionParser.parse(argv, strict: [scenario: :string, trace: :string])

    scenario_path = Keyword.fetch!(options, :scenario)
    trace_path = Keyword.fetch!(options, :trace)
    File.rm(trace_path)

    scenario = scenario_path |> File.read!() |> :json.decode()

    if scenario["schemaVersion"] != 1 do
      fail!(trace_path, 0, "unsupported_scenario", %{"schemaVersion" => scenario["schemaVersion"]}, 64)
    end

    state = %{seq: 0, trace_path: trace_path}
    final_state = run_steps(scenario["steps"], state)
    trace(final_state, "complete", %{})
    System.halt(0)
  end

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
    |> trace_bytes("sent_json", bytes)
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
    write_stdout(bytes, step)
    trace_bytes(state, "sent_json", bytes)
  end

  defp run_step(%{"type" => "stdout", "base64" => encoded} = step, state) do
    bytes = Base.decode64!(encoded)
    write_stdout(bytes, step)
    trace_bytes(state, "sent_stdout", bytes)
  end

  defp run_step(%{"type" => "stderr", "base64" => encoded}, state) do
    bytes = Base.decode64!(encoded)
    IO.binwrite(:stderr, bytes)
    trace_bytes(state, "sent_stderr", bytes)
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

  defp write_stdout(bytes, step) do
    delay_ms = step["delayMs"] || 0
    fragments = step["fragments"] || []

    {remaining, _offset} =
      Enum.reduce(fragments, {bytes, 0}, fn fragment, {pending, offset} ->
        size = if fragment == "rest", do: byte_size(pending), else: min(fragment, byte_size(pending))
        <<part::binary-size(size), rest::binary>> = pending
        IO.binwrite(:stdio, part)
        if delay_ms > 0, do: Process.sleep(delay_ms)
        {rest, offset + size}
      end)

    IO.binwrite(:stdio, remaining)
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

  defp trace_bytes(state, kind, bytes) do
    trace(state, kind, %{
      "bytes" => byte_size(bytes),
      "preview" => bounded_preview(bytes),
      "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    })
  end

  defp bounded_preview(bytes) do
    if byte_size(bytes) > 256, do: binary_part(bytes, 0, 256) <> "...<truncated>", else: bytes
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
    state = %{seq: sequence, trace_path: trace_path}
    trace(state, "failure", %{"failureKind" => kind, "details" => details, "status" => status})
    IO.puts(:stderr, "fake-codex-app-server: #{kind}")
    System.halt(status)
  end
end

SymphonyElixir.TestSupport.FakeCodexAppServer.Runner.main(System.argv())
