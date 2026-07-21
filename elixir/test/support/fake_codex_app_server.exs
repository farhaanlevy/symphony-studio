# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.FakeCodexAppServer do
  @moduledoc """
  Builds deterministic, strictly ordered Codex App Server stdio scenarios.

  The standalone runner keeps protocol stdout separate from fixture
  diagnostics and validates known client messages against the generated schema
  bundle pinned by the test process. Scenarios and traces contain no clock time
  or shared environment variables, so multiple fixtures can run independently.
  """

  import ExUnit.Assertions

  alias SymphonyElixir.Codex.SchemaBundle

  @runner Path.expand("fake_codex_app_server/runner.exs", __DIR__)
  @default_codex_home "/tmp/symphony-fake-codex-home"
  @default_cwd "/tmp/symphony-fake-codex-workspace"
  @default_wait_timeout_ms 5_000
  @wait_poll_interval_ms 5
  @max_generated_bytes 64 * 1024 * 1024
  @client_params_schemas %{
    "account/read" => "json/v2/GetAccountParams.json",
    "collaborationMode/list" => "experimental/json/v2/CollaborationModeListParams.json",
    "experimentalFeature/list" => "json/v2/ExperimentalFeatureListParams.json",
    "initialize" => "json/v1/InitializeParams.json",
    "model/list" => "json/v2/ModelListParams.json",
    "thread/start" => "experimental/json/v2/ThreadStartParams.json",
    "turn/start" => "json/v2/TurnStartParams.json"
  }
  @client_paramless_methods ~w(account/rateLimits/read account/usage/read)
  @response_schemas %{
    "account/rateLimits/read" => "json/v2/GetAccountRateLimitsResponse.json",
    "account/read" => "json/v2/GetAccountResponse.json",
    "account/usage/read" => "json/v2/GetAccountTokenUsageResponse.json",
    "collaborationMode/list" => "experimental/json/v2/CollaborationModeListResponse.json",
    "experimentalFeature/list" => "json/v2/ExperimentalFeatureListResponse.json",
    "model/list" => "json/v2/ModelListResponse.json"
  }

  @type fixture :: %{
          argv: [String.t()],
          command: String.t(),
          root: String.t(),
          scenario_path: String.t(),
          trace_path: String.t()
        }

  @spec create!(String.t(), [map()]) :: fixture()
  def create!(root, steps) when is_binary(root) and is_list(steps) do
    validate_steps!(steps)
    validate_terminal_exit!(steps)
    validate_named_steps_unique!(steps, "barrier")

    fixture_root =
      Path.join(root, "fake-codex-app-server-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(fixture_root)
    scenario_path = Path.join(fixture_root, "scenario.json")
    trace_path = Path.join(fixture_root, "trace.jsonl")
    File.write!(scenario_path, Jason.encode!(%{"schemaVersion" => 1, "steps" => steps}, pretty: true))

    elixir = System.find_executable("elixir") || raise "elixir executable not found"
    env = System.find_executable("env") || raise "env executable not found"

    argv =
      [env, "PATH=#{System.fetch_env!("PATH")}", elixir] ++
        runner_code_path_arguments() ++
        [@runner, "--scenario", scenario_path, "--trace", trace_path]

    command = Enum.map_join(argv, " ", &shell_quote/1)

    %{
      argv: argv,
      command: command,
      root: fixture_root,
      scenario_path: scenario_path,
      trace_path: trace_path
    }
  end

  @spec session_prelude(keyword()) :: [map()]
  def session_prelude(opts \\ []) do
    thread_id = Keyword.get(opts, :thread_id, "thread-fixture")
    turn_id = Keyword.get(opts, :turn_id, "turn-fixture")
    cwd = Keyword.get(opts, :cwd, @default_cwd)

    [
      expect(%{"id" => 1, "method" => "initialize"}, match: :subset),
      response(1, initialize_response()),
      expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
      expect(%{"id" => 2, "method" => "thread/start"}, match: :subset),
      response(2, thread_start_response(thread_id, cwd: cwd)),
      expect(
        %{"id" => 3, "method" => "turn/start", "params" => %{"threadId" => thread_id}},
        match: :subset
      ),
      response(3, turn_start_response(turn_id))
    ]
  end

  @spec initialize_response(keyword()) :: map()
  def initialize_response(opts \\ []) do
    %{
      "codexHome" => Keyword.get(opts, :codex_home, @default_codex_home),
      "platformFamily" => Keyword.get(opts, :platform_family, "unix"),
      "platformOs" => Keyword.get(opts, :platform_os, "linux"),
      "userAgent" => Keyword.get(opts, :user_agent, "symphony-studio-fixture/#{SchemaBundle.version()}")
    }
    |> validate_schema!("json/v1/InitializeResponse.json")
  end

  @spec thread_start_response(String.t(), keyword()) :: map()
  def thread_start_response(thread_id, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    cwd = Keyword.get(opts, :cwd, @default_cwd)

    %{
      "approvalPolicy" => Keyword.get(opts, :approval_policy, "never"),
      "approvalsReviewer" => Keyword.get(opts, :approvals_reviewer, "user"),
      "cwd" => cwd,
      "model" => Keyword.get(opts, :model, "gpt-fixture"),
      "modelProvider" => Keyword.get(opts, :model_provider, "openai"),
      "sandbox" => Keyword.get(opts, :sandbox, %{"type" => "dangerFullAccess"}),
      "thread" => thread(thread_id, cwd: cwd)
    }
    |> validate_schema!("json/v2/ThreadStartResponse.json")
  end

  @spec turn_start_response(String.t()) :: map()
  def turn_start_response(turn_id) when is_binary(turn_id) do
    %{"turn" => turn(turn_id, "inProgress")}
    |> validate_schema!("json/v2/TurnStartResponse.json")
  end

  @spec no_grant_permissions_response() :: map()
  def no_grant_permissions_response,
    do: fail_closed_callback_response("item/permissions/requestApproval")

  @spec fail_closed_callback_response(String.t()) :: map()
  def fail_closed_callback_response(method) when is_binary(method) do
    {result, schema_path} =
      case method do
        "item/commandExecution/requestApproval" ->
          {%{"decision" => "decline"}, "json/CommandExecutionRequestApprovalResponse.json"}

        "item/fileChange/requestApproval" ->
          {%{"decision" => "decline"}, "json/FileChangeRequestApprovalResponse.json"}

        "execCommandApproval" ->
          {%{"decision" => "denied"}, "json/ExecCommandApprovalResponse.json"}

        "applyPatchApproval" ->
          {%{"decision" => "denied"}, "json/ApplyPatchApprovalResponse.json"}

        "mcpServer/elicitation/request" ->
          {%{"action" => "decline"}, "json/McpServerElicitationRequestResponse.json"}

        "item/permissions/requestApproval" ->
          {%{"permissions" => %{}, "scope" => "turn"}, "json/PermissionsRequestApprovalResponse.json"}
      end

    validate_schema!(result, schema_path)
  end

  @spec turn_completed_notification(String.t(), String.t()) :: map()
  def turn_completed_notification(thread_id, turn_id)
      when is_binary(thread_id) and is_binary(turn_id) do
    payload =
      %{
        "method" => "turn/completed",
        "params" => %{
          "threadId" => thread_id,
          "turn" => turn(turn_id, "completed")
        }
      }
      |> validate_schema!("json/ServerNotification.json")

    send_json(payload)
  end

  @spec assert_client_message_valid!(map()) :: :ok
  def assert_client_message_valid!(%{"method" => "initialized"} = payload) do
    _validated = validate_schema!(payload, "json/ClientNotification.json")
    assert Enum.sort(Map.keys(payload)) == ["method"]
    :ok
  end

  def assert_client_message_valid!(%{"id" => _id, "method" => method} = payload)
      when method in @client_paramless_methods do
    _validated = validate_schema!(payload, client_request_schema(method))
    assert Enum.sort(Map.keys(payload)) == ["id", "method"]
    :ok
  end

  def assert_client_message_valid!(%{"id" => _id, "method" => method, "params" => params} = payload)
      when is_map(params) do
    params_schema = Map.fetch!(@client_params_schemas, method)
    _validated = validate_schema!(payload, client_request_schema(method))
    schema = load_schema!(params_schema)
    allowed_params = schema |> Map.get("properties", %{}) |> Map.keys()

    assert Map.keys(payload) -- ["id", "method", "params"] == [],
           "client request contains unadvertised envelope fields"

    assert Map.keys(params) -- allowed_params == [],
           "#{method} contains fields absent from #{params_schema}"

    if method == "turn/start" do
      params
      |> Map.fetch!("sandboxPolicy")
      |> assert_turn_sandbox_policy_valid!()
    end

    :ok
  end

  def assert_client_message_valid!(%{"id" => _id, "result" => %{"success" => _success} = result} = payload) do
    assert Enum.sort(Map.keys(payload)) == ["id", "result"],
           "dynamic-tool response contains unadvertised envelope fields"

    assert_dynamic_tool_response_valid!(result)
  end

  @spec assert_dynamic_tool_response_valid!(map()) :: :ok
  def assert_dynamic_tool_response_valid!(result) when is_map(result) do
    _validated = validate_schema!(result, "json/DynamicToolCallResponse.json")

    assert Enum.sort(Map.keys(result)) == ["contentItems", "success"],
           "dynamic-tool result must contain only success and contentItems"

    assert is_boolean(result["success"]), "dynamic-tool success must be a boolean"
    assert is_list(result["contentItems"]), "dynamic-tool contentItems must be a list"
    Enum.each(result["contentItems"], &assert_dynamic_tool_content_item_valid!/1)
    :ok
  end

  @spec expect(map(), keyword()) :: map()
  def expect(expected, opts \\ []) when is_map(expected) and is_list(opts) do
    match = normalize_match!(Keyword.get(opts, :match, :exact))

    %{
      "type" => "expect",
      "expected" => expected,
      "absent" => Keyword.get(opts, :absent, []),
      "match" => match
    }
    |> maybe_put_validation(expected)
  end

  @spec response(integer() | String.t(), map(), keyword()) :: map()
  def response(id, result, opts \\ []) when is_map(result) do
    payload = %{"id" => id, "result" => result}
    _validated = validate_schema!(payload, "json/JSONRPCResponse.json")
    assert_exact_keys!(payload, ~w(id result), "server response envelope")
    send_json(payload, opts)
  end

  @spec response_for(integer() | String.t(), String.t(), map(), keyword()) :: map()
  def response_for(id, method, result, opts \\ [])
      when is_binary(method) and is_map(result) and is_list(opts) do
    schema_path = Map.fetch!(@response_schemas, method)
    _validated = validate_schema!(result, schema_path)
    response(id, result, opts)
  end

  @spec response_error(integer() | String.t(), integer(), String.t(), term(), keyword()) :: map()
  def response_error(id, code, message, data \\ nil, opts \\ [])
      when is_integer(code) and is_binary(message) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    payload = %{"id" => id, "error" => error}
    _validated = validate_schema!(payload, "json/JSONRPCError.json")
    assert_exact_keys!(payload, ~w(error id), "server error envelope")
    assert_exact_keys!(error, ~w(code data message), "server error object")
    send_json(payload, opts)
  end

  @spec request(integer() | String.t(), String.t(), map(), keyword()) :: map()
  def request(id, method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) do
    payload = %{"id" => id, "method" => method, "params" => params}
    _validated = validate_schema!(payload, "json/ServerRequest.json")
    assert_exact_keys!(payload, ~w(id method params), "server request envelope")
    send_json(payload, opts)
  end

  @spec notification(String.t(), map(), keyword()) :: map()
  def notification(method, params \\ %{}, opts \\ [])
      when is_binary(method) and is_map(params) do
    payload = %{"method" => method, "params" => params}
    _validated = validate_schema!(payload, "json/ServerNotification.json")
    assert_exact_keys!(payload, ~w(method params), "server notification envelope")
    send_json(payload, opts)
  end

  @doc "Build an intentionally unvalidated frame for negative transport tests."
  @spec raw_send_json(map(), keyword()) :: map()
  def raw_send_json(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    send_json(payload, opts)
  end

  defp send_json(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    %{
      "type" => "send_json",
      "payload" => payload,
      "fragments" => normalize_fragments(Keyword.get(opts, :fragments, [])),
      "delayMs" => Keyword.get(opts, :delay_ms, 0)
    }
  end

  @spec raw_stdout(binary(), keyword()) :: map()
  def raw_stdout(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    %{
      "type" => "stdout",
      "base64" => Base.encode64(bytes),
      "fragments" => normalize_fragments(Keyword.get(opts, :fragments, [])),
      "delayMs" => Keyword.get(opts, :delay_ms, 0)
    }
  end

  @doc "Build compact deterministic stdout by repeating a byte pattern without expanding scenario.json."
  @spec generated_stdout(binary(), non_neg_integer(), keyword()) :: map()
  def generated_stdout(repeated_bytes, repeat_count, opts \\ [])
      when is_binary(repeated_bytes) and is_integer(repeat_count) and repeat_count >= 0 and is_list(opts) do
    generated_stream("stdout", repeated_bytes, repeat_count, opts)
  end

  @doc "Build compact deterministic stderr by repeating a byte pattern without expanding scenario.json."
  @spec generated_stderr(binary(), non_neg_integer(), keyword()) :: map()
  def generated_stderr(repeated_bytes, repeat_count, opts \\ [])
      when is_binary(repeated_bytes) and is_integer(repeat_count) and repeat_count >= 0 and is_list(opts) do
    generated_stream("stderr", repeated_bytes, repeat_count, opts)
  end

  @spec stderr(binary(), keyword()) :: map()
  def stderr(bytes, opts \\ []) when is_binary(bytes) and is_list(opts) do
    %{
      "type" => "stderr",
      "base64" => Base.encode64(bytes),
      "fragments" => normalize_fragments(Keyword.get(opts, :fragments, [])),
      "delayMs" => Keyword.get(opts, :delay_ms, 0)
    }
  end

  @doc "Pause the runner at a file-backed named barrier until release!/3 is called."
  @spec barrier(String.t(), keyword()) :: map()
  def barrier(name, opts \\ []) when is_binary(name) and is_list(opts) do
    validate_name!(name)

    %{
      "type" => "barrier",
      "name" => name,
      "timeoutMs" => Keyword.get(opts, :timeout_ms, @default_wait_timeout_ms)
    }
  end

  @doc "Release a reached named barrier atomically, waiting for its readiness marker first."
  @spec release!(fixture(), String.t(), pos_integer()) :: :ok
  def release!(fixture, name, timeout_ms \\ @default_wait_timeout_ms)
      when is_map(fixture) and is_binary(name) and is_integer(timeout_ms) and timeout_ms > 0 do
    validate_name!(name)
    barrier_root = Path.join(fixture.root, "barriers")
    waiting_path = Path.join(barrier_root, "#{name}.waiting")
    release_path = Path.join(barrier_root, "#{name}.release")
    released_path = Path.join(barrier_root, "#{name}.released")
    timed_out_path = Path.join(barrier_root, "#{name}.timed_out")
    wait_for_file!(waiting_path, timeout_ms, "barrier #{inspect(name)} was not reached")

    cond do
      File.regular?(released_path) ->
        :ok

      File.regular?(timed_out_path) ->
        raise ExUnit.AssertionError, message: "barrier #{inspect(name)} already timed out"

      true ->
        atomic_write_once!(release_path, "release\n")
        wait_for_barrier_outcome!(released_path, timed_out_path, name, timeout_ms)
    end
  end

  @spec sleep(non_neg_integer()) :: map()
  def sleep(milliseconds) when is_integer(milliseconds) and milliseconds >= 0,
    do: %{"type" => "sleep", "milliseconds" => milliseconds}

  @spec exit(non_neg_integer()) :: map()
  def exit(status) when is_integer(status) and status >= 0,
    do: %{"type" => "exit", "status" => status}

  @spec trace!(fixture()) :: [map()]
  def trace!(fixture) do
    fixture.trace_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  @spec received!(fixture()) :: [map()]
  def received!(fixture) do
    fixture
    |> trace!()
    |> Enum.filter(&(&1["kind"] == "received"))
    |> Enum.map(& &1["payload"])
  end

  @spec assert_complete!(fixture()) :: :ok
  def assert_complete!(fixture) do
    trace = trace!(fixture)
    assert List.last(trace)["kind"] == "complete", "fake App Server scenario did not complete"
    :ok
  end

  @spec assert_received!(fixture(), map()) :: :ok
  def assert_received!(fixture, expected) when is_map(expected) do
    assert Enum.any?(received!(fixture), &subset?(expected, &1)),
           "fake App Server did not receive expected subset #{inspect(expected)}"

    :ok
  end

  defp generated_stream(stream, repeated_bytes, repeat_count, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    suffix = Keyword.get(opts, :suffix, "")

    unless is_binary(prefix) and is_binary(suffix) do
      raise ArgumentError, "generated stream prefix and suffix must be binaries"
    end

    generated_bytes = byte_size(prefix) + byte_size(repeated_bytes) * repeat_count + byte_size(suffix)

    if generated_bytes > @max_generated_bytes do
      raise ArgumentError,
            "generated stream exceeds #{@max_generated_bytes} byte fixture limit: #{generated_bytes}"
    end

    %{
      "type" => "generated",
      "stream" => stream,
      "prefixBase64" => Base.encode64(prefix),
      "repeatBase64" => Base.encode64(repeated_bytes),
      "repeatCount" => repeat_count,
      "suffixBase64" => Base.encode64(suffix),
      "fragments" => normalize_fragments(Keyword.get(opts, :fragments, [])),
      "delayMs" => Keyword.get(opts, :delay_ms, 0)
    }
  end

  defp normalize_fragments(fragments) do
    normalized =
      Enum.map(fragments, fn
        :rest -> "rest"
        size when is_integer(size) and size > 0 -> size
        other -> raise ArgumentError, "invalid fake App Server fragment size: #{inspect(other)}"
      end)

    validate_fragments!(normalized)
    normalized
  end

  defp wait_for_file!(path, timeout_ms, timeout_message) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_file!(path, deadline, timeout_message)
  end

  defp do_wait_for_file!(path, deadline, timeout_message) do
    cond do
      File.regular?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise ExUnit.AssertionError, message: timeout_message

      true ->
        Process.sleep(@wait_poll_interval_ms)
        do_wait_for_file!(path, deadline, timeout_message)
    end
  end

  defp atomic_write_once!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, bytes, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  defp wait_for_barrier_outcome!(released_path, timed_out_path, name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_barrier_outcome!(released_path, timed_out_path, name, deadline)
  end

  defp do_wait_for_barrier_outcome!(released_path, timed_out_path, name, deadline) do
    cond do
      File.regular?(released_path) ->
        :ok

      File.regular?(timed_out_path) ->
        raise ExUnit.AssertionError, message: "barrier #{inspect(name)} timed out before release"

      System.monotonic_time(:millisecond) >= deadline ->
        raise ExUnit.AssertionError,
          message: "barrier #{inspect(name)} did not acknowledge release"

      true ->
        Process.sleep(@wait_poll_interval_ms)
        do_wait_for_barrier_outcome!(released_path, timed_out_path, name, deadline)
    end
  end

  defp subset?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} -> Map.has_key?(actual, key) and subset?(value, actual[key]) end)
  end

  defp subset?(expected, actual) when is_list(expected) and is_list(actual) do
    length(expected) == length(actual) and
      Enum.zip(expected, actual) |> Enum.all?(fn {left, right} -> subset?(left, right) end)
  end

  defp subset?(expected, actual), do: expected == actual

  defp thread(thread_id, opts) do
    cwd = Keyword.fetch!(opts, :cwd)

    %{
      "cliVersion" => SchemaBundle.version(),
      "createdAt" => 0,
      "cwd" => cwd,
      "ephemeral" => false,
      "id" => thread_id,
      "modelProvider" => "openai",
      "preview" => "",
      "sessionId" => "session-#{thread_id}",
      "source" => "appServer",
      "status" => %{"type" => "idle"},
      "turns" => [],
      "updatedAt" => 0
    }
  end

  defp turn(turn_id, status) do
    %{
      "id" => turn_id,
      "items" => [],
      "status" => status
    }
  end

  defp assert_turn_sandbox_policy_valid!(%{"type" => "dangerFullAccess"} = policy) do
    assert_exact_keys!(policy, ~w(type), "dangerFullAccess sandbox policy")
  end

  defp assert_turn_sandbox_policy_valid!(%{"type" => "readOnly"} = policy) do
    assert_exact_keys!(policy, ~w(type networkAccess), "readOnly sandbox policy")
    assert_optional_boolean!(policy, "networkAccess")
  end

  defp assert_turn_sandbox_policy_valid!(%{"type" => "externalSandbox"} = policy) do
    assert_exact_keys!(policy, ~w(type networkAccess), "externalSandbox sandbox policy")

    case Map.fetch(policy, "networkAccess") do
      :error -> :ok
      {:ok, value} -> assert value in ~w(restricted enabled), "invalid externalSandbox networkAccess"
    end
  end

  defp assert_turn_sandbox_policy_valid!(%{"type" => "workspaceWrite"} = policy) do
    assert_exact_keys!(
      policy,
      ~w(type writableRoots networkAccess excludeTmpdirEnvVar excludeSlashTmp),
      "workspaceWrite sandbox policy"
    )

    Enum.each(~w(networkAccess excludeTmpdirEnvVar excludeSlashTmp), fn key ->
      assert_optional_boolean!(policy, key)
    end)

    case Map.fetch(policy, "writableRoots") do
      :error ->
        :ok

      {:ok, roots} ->
        assert is_list(roots), "workspaceWrite writableRoots must be a list"

        Enum.each(roots, fn root ->
          assert is_binary(root) and root != "", "workspaceWrite writableRoots must contain paths"
          assert Path.type(root) == :absolute, "workspaceWrite writableRoots must be absolute"
          assert Path.expand(root) == root, "workspaceWrite writableRoots must be normalized"
        end)
    end
  end

  defp assert_turn_sandbox_policy_valid!(policy) do
    flunk("invalid pinned turn sandbox policy: #{inspect(policy)}")
  end

  defp assert_dynamic_tool_content_item_valid!(%{"type" => "inputText", "text" => text} = item) do
    assert_exact_keys!(item, ~w(type text), "inputText dynamic-tool content item")
    assert is_binary(text), "inputText dynamic-tool content must be text"
  end

  defp assert_dynamic_tool_content_item_valid!(%{"type" => "inputImage", "imageUrl" => image_url} = item) do
    assert_exact_keys!(item, ~w(type imageUrl), "inputImage dynamic-tool content item")
    assert is_binary(image_url), "inputImage dynamic-tool content must be a URL string"
  end

  defp assert_dynamic_tool_content_item_valid!(item) do
    flunk("invalid pinned dynamic-tool content item: #{inspect(item)}")
  end

  defp assert_exact_keys!(value, allowed_keys, label) do
    assert Map.keys(value) -- allowed_keys == [], "#{label} contains unsupported fields"
  end

  defp assert_optional_boolean!(value, key) do
    case Map.fetch(value, key) do
      :error -> :ok
      {:ok, nested} -> assert is_boolean(nested), "#{key} must be a boolean"
    end
  end

  defp validate_schema!(payload, relative_path) do
    schema = load_schema!(relative_path)

    case schema |> Xema.from_json_schema() |> Xema.validate(payload) do
      :ok ->
        payload

      {:error, error} ->
        raise ArgumentError,
              "fixture payload violates pinned schema #{relative_path}: #{Exception.message(error)}"
    end
  end

  defp load_schema!(relative_path) do
    case SchemaBundle.schema(relative_path) do
      {:ok, value} -> value
      {:error, reason} -> raise "failed to load pinned schema #{relative_path}: #{inspect(reason)}"
    end
  end

  defp maybe_put_validation(step, expected) do
    case validation_contract(expected) do
      nil -> step
      validation -> Map.put(step, "validation", validation)
    end
  end

  defp validation_contract(%{"method" => "initialized"}) do
    schema_contract("client_notification", "json/ClientNotification.json")
  end

  defp validation_contract(%{"method" => method}) when method in @client_paramless_methods do
    schema_contract("client_request_paramless", client_request_schema(method))
    |> Map.put("method", method)
  end

  defp validation_contract(%{"method" => method}) when is_map_key(@client_params_schemas, method) do
    schema_contract("client_request", Map.fetch!(@client_params_schemas, method))
    |> Map.put("method", method)
  end

  defp validation_contract(%{"result" => result}) when is_map(result) do
    case callback_response_schema(result) do
      nil -> nil
      relative_path -> schema_contract("client_response", relative_path)
    end
  end

  defp validation_contract(_expected), do: nil

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

  defp client_request_schema(method) when method in ~w(collaborationMode/list thread/start),
    do: "experimental/json/ClientRequest.json"

  defp client_request_schema(_method), do: "json/ClientRequest.json"

  defp schema_contract(kind, relative_path) do
    %{
      "kind" => kind,
      "schema" => load_schema!(relative_path),
      "schemaPath" => relative_path
    }
  end

  defp normalize_match!(:exact), do: "exact"
  defp normalize_match!(:subset), do: "subset"

  defp normalize_match!(other) do
    raise ArgumentError,
          "fake App Server expectation match must be :exact or :subset, got: #{inspect(other)}"
  end

  defp runner_code_path_arguments do
    :code.get_path()
    |> Enum.map(&(&1 |> to_string() |> Path.expand()))
    |> Enum.filter(&File.dir?/1)
    |> Enum.uniq()
    |> Enum.flat_map(fn path -> ["-pa", path] end)
  end

  defp validate_steps!(steps) do
    Enum.with_index(steps)
    |> Enum.each(fn {step, index} -> validate_step!(step, index) end)
  end

  defp validate_step!(%{"type" => "expect"} = step, index) do
    validate_step_keys!(step, ~w(type expected absent match), ["validation"], index)
    require_map!(step["expected"], "expect.expected", index)

    unless is_list(step["absent"]) and
             Enum.all?(step["absent"], fn path ->
               is_list(path) and path != [] and Enum.all?(path, &is_binary/1)
             end) do
      invalid_step!(index, "expect.absent must contain non-empty string paths")
    end

    unless step["match"] in ~w(exact subset) do
      invalid_step!(index, "expect.match must be exact or subset")
    end

    validate_expect_contract!(step, index)
  end

  defp validate_step!(%{"type" => "send_json"} = step, index) do
    validate_step_keys!(step, ~w(type payload fragments delayMs), [], index)
    require_map!(step["payload"], "send_json.payload", index)
    validate_output_options!(step, index)
  end

  defp validate_step!(%{"type" => "stdout"} = step, index) do
    validate_step_keys!(step, ~w(type base64 fragments delayMs), [], index)
    decode_base64!(step["base64"], "stdout.base64", index)
    validate_output_options!(step, index)
  end

  # schemaVersion 1 originally encoded stderr with only type/base64. Keep that
  # representation valid while new builders add deterministic output options.
  defp validate_step!(%{"type" => "stderr"} = step, index) do
    validate_step_keys!(step, ~w(type base64), ~w(fragments delayMs), index)
    decode_base64!(step["base64"], "stderr.base64", index)
    validate_output_options!(step, index)
  end

  defp validate_step!(%{"type" => "generated"} = step, index) do
    validate_step_keys!(
      step,
      ~w(type stream prefixBase64 repeatBase64 repeatCount suffixBase64 fragments delayMs),
      [],
      index
    )

    unless step["stream"] in ~w(stdout stderr) do
      invalid_step!(index, "generated.stream must be stdout or stderr")
    end

    prefix = decode_base64!(step["prefixBase64"], "generated.prefixBase64", index)
    repeated = decode_base64!(step["repeatBase64"], "generated.repeatBase64", index)
    suffix = decode_base64!(step["suffixBase64"], "generated.suffixBase64", index)
    repeat_count = step["repeatCount"]

    unless is_integer(repeat_count) and repeat_count >= 0 do
      invalid_step!(index, "generated.repeatCount must be a non-negative integer")
    end

    if repeated == "" and repeat_count > 0 do
      invalid_step!(index, "generated.repeatBase64 must decode to bytes when repeatCount is positive")
    end

    generated_bytes = byte_size(prefix) + byte_size(repeated) * repeat_count + byte_size(suffix)

    if generated_bytes > @max_generated_bytes do
      invalid_step!(index, "generated output exceeds #{@max_generated_bytes} bytes")
    end

    validate_output_options!(step, index)
  end

  defp validate_step!(%{"type" => "barrier"} = step, index) do
    validate_step_keys!(step, ~w(type name timeoutMs), [], index)
    validate_name!(step["name"])

    unless is_integer(step["timeoutMs"]) and step["timeoutMs"] > 0 do
      invalid_step!(index, "barrier.timeoutMs must be a positive integer")
    end
  end

  defp validate_step!(%{"type" => "sleep"} = step, index) do
    validate_step_keys!(step, ~w(type milliseconds), [], index)

    unless is_integer(step["milliseconds"]) and step["milliseconds"] >= 0 do
      invalid_step!(index, "sleep.milliseconds must be a non-negative integer")
    end
  end

  defp validate_step!(%{"type" => "exit"} = step, index) do
    validate_step_keys!(step, ~w(type status), [], index)

    unless is_integer(step["status"]) and step["status"] >= 0 do
      invalid_step!(index, "exit.status must be a non-negative integer")
    end
  end

  defp validate_step!(step, index) do
    invalid_step!(index, "unknown or malformed step #{inspect(step)}")
  end

  defp validate_step_keys!(step, required, optional, index) do
    keys = Map.keys(step)

    case required -- keys do
      [] -> :ok
      missing -> invalid_step!(index, "missing fields #{inspect(missing)}")
    end

    case keys -- (required ++ optional) do
      [] -> :ok
      extra -> invalid_step!(index, "unexpected fields #{inspect(extra)}")
    end
  end

  defp validate_output_options!(step, index) do
    validate_fragments!(Map.get(step, "fragments", []))

    delay_ms = Map.get(step, "delayMs", 0)

    unless is_integer(delay_ms) and delay_ms >= 0 do
      invalid_step!(index, "delayMs must be a non-negative integer")
    end
  end

  defp validate_expect_contract!(step, index) do
    expected_contract = validation_contract(step["expected"])

    case {expected_contract, Map.fetch(step, "validation")} do
      {nil, :error} ->
        :ok

      {nil, {:ok, _unexpected}} ->
        invalid_step!(index, "expect.validation is not supported for this expectation")

      {_expected, :error} ->
        invalid_step!(index, "expect.validation is required for this pinned expectation")

      {expected, {:ok, actual}} when expected == actual ->
        :ok

      {_expected, {:ok, _actual}} ->
        invalid_step!(index, "expect.validation does not match the pinned validation contract")
    end
  end

  defp validate_fragments!(fragments) when is_list(fragments) do
    unless Enum.all?(fragments, &((is_integer(&1) and &1 > 0) or &1 == "rest")) do
      raise ArgumentError, "fake App Server fragments must be positive integers or a final :rest"
    end

    rest_indexes =
      fragments
      |> Enum.with_index()
      |> Enum.filter(fn {fragment, _index} -> fragment == "rest" end)
      |> Enum.map(&elem(&1, 1))

    case rest_indexes do
      [] -> :ok
      [index] when index == length(fragments) - 1 -> :ok
      _ -> raise ArgumentError, "fake App Server :rest fragment must appear at most once and be final"
    end
  end

  defp validate_fragments!(_fragments) do
    raise ArgumentError, "fake App Server fragments must be a list"
  end

  defp decode_base64!(encoded, label, index) when is_binary(encoded) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> bytes
      :error -> invalid_step!(index, "#{label} is not canonical base64")
    end
  end

  defp decode_base64!(_encoded, label, index), do: invalid_step!(index, "#{label} must be a string")

  defp require_map!(value, _label, _index) when is_map(value), do: :ok
  defp require_map!(_value, label, index), do: invalid_step!(index, "#{label} must be an object")

  defp validate_name!(name) when is_binary(name) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/, name) do
      :ok
    else
      raise ArgumentError,
            "fake App Server names must use 1-64 ASCII letters, digits, dot, underscore, or hyphen"
    end
  end

  defp validate_name!(_name) do
    raise ArgumentError, "fake App Server name must be a string"
  end

  defp validate_named_steps_unique!(steps, type) do
    names = for %{"type" => ^type, "name" => name} <- steps, do: name

    if Enum.uniq(names) != names do
      raise ArgumentError, "fake App Server #{type} names must be unique within a scenario"
    end
  end

  defp invalid_step!(index, message) do
    raise ArgumentError, "invalid fake App Server step at index #{index}: #{message}"
  end

  defp validate_terminal_exit!(steps) do
    exit_indexes =
      steps
      |> Enum.with_index()
      |> Enum.filter(fn {step, _index} -> match?(%{"type" => "exit"}, step) end)
      |> Enum.map(&elem(&1, 1))

    case exit_indexes do
      [] ->
        :ok

      [index] when index == length(steps) - 1 ->
        :ok

      [index] ->
        raise ArgumentError,
              "fake App Server exit step at index #{index} must be the final scenario step"

      indexes ->
        raise ArgumentError,
              "fake App Server scenario must contain at most one exit step, got indexes #{inspect(indexes)}"
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
