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
  @client_params_schemas %{
    "initialize" => "json/v1/InitializeParams.json",
    "thread/start" => "experimental/json/v2/ThreadStartParams.json",
    "turn/start" => "experimental/json/v2/TurnStartParams.json"
  }

  @type fixture :: %{
          command: String.t(),
          root: String.t(),
          scenario_path: String.t(),
          trace_path: String.t()
        }

  @spec create!(String.t(), [map()]) :: fixture()
  def create!(root, steps) when is_binary(root) and is_list(steps) do
    validate_terminal_exit!(steps)

    fixture_root =
      Path.join(root, "fake-codex-app-server-#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(fixture_root)
    scenario_path = Path.join(fixture_root, "scenario.json")
    trace_path = Path.join(fixture_root, "trace.jsonl")
    File.write!(scenario_path, Jason.encode!(%{"schemaVersion" => 1, "steps" => steps}, pretty: true))

    elixir = System.find_executable("elixir") || raise "elixir executable not found"

    command =
      ([
         "export PATH=#{shell_quote(System.fetch_env!("PATH"))};",
         "exec",
         shell_quote(elixir)
       ] ++
         runner_code_path_arguments() ++
         [
           shell_quote(@runner),
           "--scenario",
           shell_quote(scenario_path),
           "--trace",
           shell_quote(trace_path)
         ])
      |> Enum.join(" ")

    %{
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
    _validated = validate_schema!(payload, "experimental/json/ClientNotification.json")
    assert Enum.sort(Map.keys(payload)) == ["method"]
    :ok
  end

  def assert_client_message_valid!(%{"id" => _id, "method" => method, "params" => params} = payload)
      when is_map(params) do
    params_schema = Map.fetch!(@client_params_schemas, method)
    _validated = validate_schema!(payload, "experimental/json/ClientRequest.json")
    schema = load_schema!(params_schema)
    allowed_params = schema |> Map.fetch!("properties") |> Map.keys()

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

  @spec stderr(binary()) :: map()
  def stderr(bytes) when is_binary(bytes), do: %{"type" => "stderr", "base64" => Base.encode64(bytes)}

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

  defp normalize_fragments(fragments) do
    Enum.map(fragments, fn
      :rest -> "rest"
      size when is_integer(size) and size > 0 -> size
    end)
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
    schema_contract("client_notification", "experimental/json/ClientNotification.json")
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
    |> Enum.flat_map(fn path -> ["-pa", shell_quote(path)] end)
  end

  defp validate_terminal_exit!(steps) do
    case Enum.find_index(steps, &match?(%{"type" => "exit"}, &1)) do
      nil ->
        :ok

      index when index == length(steps) - 1 ->
        :ok

      index ->
        raise ArgumentError,
              "fake App Server exit step at index #{index} must be the final scenario step"
    end
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
