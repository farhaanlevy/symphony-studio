# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.Intent.MCPServer do
  @moduledoc """
  Local newline-delimited JSON-RPC STDIO server for the canonical Intent Service.

  Standard output contains protocol messages only. The server supports the MCP
  initialization lifecycle and the eight public intent tools; it performs no
  model calls. The precompiled CLI binds the dedicated least-privilege Linear
  adapter, while direct `run/1` and test exchanges remain fail-closed unless a
  broker is explicitly injected.
  """

  alias SymphonyElixir.Studio.Intent.Canonical
  alias SymphonyElixir.Studio.IntentService
  alias SymphonyElixir.Studio.LinearWriteBroker.Linear

  @protocol_version "2025-11-25"
  @supported_versions ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
  @max_message_bytes 1 * 1_024 * 1_024
  @max_source_bytes 256 * 1_024
  @max_answer_bytes 4 * 1_024

  @doc "Runs the precompiled STDIO entrypoint and returns a process exit status."
  @spec main([String.t()]) :: non_neg_integer()
  def main(args) when is_list(args) do
    case production_cli_options(args) do
      {:ok, opts} ->
        run(opts)
        0

      :help ->
        IO.puts(cli_help())
        0

      {:error, message} ->
        IO.puts(:stderr, "studio_intent_mcp: #{message}")
        64
    end
  end

  @doc false
  @spec production_options_for_test([String.t()]) :: {:ok, keyword()} | :help | {:error, String.t()}
  def production_options_for_test(args) when is_list(args), do: production_cli_options(args)

  @doc "Runs the local MCP server until its standard input closes."
  @spec run(keyword()) :: :ok
  def run(opts \\ []) when is_list(opts) do
    case service_options(opts) do
      {:ok, service_opts} ->
        loop(%{phase: :new, service_opts: service_opts})

      {:error, reason} ->
        IO.puts(:stderr, "studio.intent_mcp: #{reason}")
        :ok
    end
  end

  @doc false
  @spec exchange_for_test([map()], keyword()) :: [map()]
  def exchange_for_test(messages, opts \\ []) when is_list(messages) and is_list(opts) do
    {:ok, service_opts} = service_options(opts)

    {responses, _state} =
      Enum.reduce(messages, {[], %{phase: :new, service_opts: service_opts}}, fn message, {responses, state} ->
        case handle_message(message, state) do
          {:reply, response, next} -> {responses ++ [response], next}
          {:noreply, next} -> {responses, next}
        end
      end)

    responses
  end

  defp loop(state) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, _reason} ->
        :ok

      line when is_binary(line) ->
        {response, next_state} = decode_and_handle(line, state)
        if response, do: write_response(response)
        loop(next_state)
    end
  end

  defp decode_and_handle(line, state) when byte_size(line) > @max_message_bytes do
    {json_error(nil, -32_700, "Parse error"), state}
  end

  defp decode_and_handle(line, state) do
    case Jason.decode(line) do
      {:ok, message} when is_map(message) ->
        case handle_message(message, state) do
          {:reply, response, next} -> {response, next}
          {:noreply, next} -> {nil, next}
        end

      _invalid ->
        {json_error(nil, -32_700, "Parse error"), state}
    end
  end

  defp handle_message(%{"jsonrpc" => "2.0", "id" => id, "method" => "initialize", "params" => params}, state)
       when is_map(params) do
    requested = Map.get(params, "protocolVersion")
    negotiated = if(requested in @supported_versions, do: requested, else: @protocol_version)

    result = %{
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "instructions" => server_instructions(),
      "protocolVersion" => negotiated,
      "serverInfo" => %{
        "description" => "Local fail-closed Symphony Studio intent orchestration",
        "name" => "symphony-studio-intent",
        "title" => "Symphony Studio Intent",
        "version" => "0.1.0-preview"
      }
    }

    {:reply, json_result(id, result), %{state | phase: :initialized_response}}
  end

  defp handle_message(
         %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
         %{phase: phase} = state
       )
       when phase in [:initialized_response, :ready],
       do: {:noreply, %{state | phase: :ready}}

  defp handle_message(%{"jsonrpc" => "2.0", "method" => method}, state)
       when method in ["notifications/cancelled", "notifications/progress"],
       do: {:noreply, state}

  defp handle_message(%{"jsonrpc" => "2.0", "id" => id, "method" => "ping"}, state),
    do: {:reply, json_result(id, %{}), state}

  defp handle_message(
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/list"},
         %{phase: :ready} = state
       ),
       do: {:reply, json_result(id, %{"tools" => tools()}), state}

  defp handle_message(
         %{
           "jsonrpc" => "2.0",
           "id" => id,
           "method" => "tools/call",
           "params" => %{"name" => name, "arguments" => arguments}
         },
         %{phase: :ready} = state
       )
       when is_binary(name) and is_map(arguments) do
    case validate_tool_call(name, arguments) do
      :ok ->
        dispatch_tool_call(id, name, arguments, state)

      :unknown ->
        {:reply, json_error(id, -32_602, "Unknown tool: #{name}"), state}

      :invalid ->
        {:reply, json_error(id, -32_602, "Invalid tools/call parameters"), state}
    end
  end

  defp handle_message(
         %{"jsonrpc" => "2.0", "id" => id, "method" => "tools/call"},
         %{phase: :ready} = state
       ),
       do: {:reply, json_error(id, -32_602, "Invalid tools/call parameters"), state}

  defp handle_message(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, state)
       when is_binary(method) do
    error =
      if state.phase == :ready,
        do: json_error(id, -32_601, "Method not found"),
        else: json_error(id, -32_600, "Server is not initialized")

    {:reply, error, state}
  end

  defp handle_message(%{"jsonrpc" => "2.0", "method" => _method}, state),
    do: {:noreply, state}

  defp handle_message(message, state) do
    id = if(is_map(message), do: Map.get(message, "id"), else: nil)
    {:reply, json_error(id, -32_600, "Invalid Request"), state}
  end

  defp dispatch_tool_call(id, name, arguments, state) do
    case dispatch_tool(name, arguments, state.service_opts) do
      {:ok, snapshot} ->
        {:reply, json_result(id, tool_result(snapshot, false)), state}

      {:error, error} ->
        {:reply, json_result(id, tool_result(%{"error" => json_safe_error(error)}, true)), state}
    end
  end

  defp validate_tool_call(name, arguments) do
    cond do
      not known_tool?(name) -> :unknown
      valid_tool_arguments?(name, arguments) -> :ok
      true -> :invalid
    end
  end

  defp valid_tool_arguments?("studio_attach_project", arguments),
    do: exact_keys?(arguments, ["command_id", "project_root"])

  defp valid_tool_arguments?("studio_submit_intent", arguments),
    do: exact_keys?(arguments, ["command_id", "project_id", "source"])

  defp valid_tool_arguments?("studio_answer_clarifications", arguments) do
    exact_keys?(arguments, ["answers", "command_id", "intent_id"]) or
      exact_keys?(arguments, ["command_id", "intent_id", "use_recommended_defaults"])
  end

  defp valid_tool_arguments?(name, arguments)
       when name in ["studio_present_proposal", "studio_publish_approved_plan"],
       do: exact_keys?(arguments, ["command_id", "intent_id"])

  defp valid_tool_arguments?("studio_approve_publication", arguments),
    do: exact_keys?(arguments, ["command_id", "confirmation", "intent_id", "proposal_digest"])

  defp valid_tool_arguments?("studio_start_first_ready", arguments),
    do: exact_keys?(arguments, ["command_id", "confirmation", "intent_id"])

  defp valid_tool_arguments?("studio_get_intent_status", arguments),
    do: exact_keys?(arguments, ["intent_id"])

  defp valid_tool_arguments?(_name, _arguments), do: false

  defp exact_keys?(arguments, expected) do
    arguments
    |> Map.keys()
    |> Enum.sort()
    |> Kernel.==(Enum.sort(expected))
  end

  defp dispatch_tool("studio_attach_project", arguments, opts) do
    IntentService.attach_project(arguments["project_root"], arguments["command_id"], opts)
  end

  defp dispatch_tool("studio_submit_intent", arguments, opts) do
    IntentService.submit_intent(
      arguments["project_id"],
      arguments["source"],
      arguments["command_id"],
      opts
    )
  end

  defp dispatch_tool("studio_answer_clarifications", arguments, opts) do
    answer_input = Map.take(arguments, ["answers", "use_recommended_defaults"])

    IntentService.answer_clarifications(
      arguments["intent_id"],
      answer_input,
      arguments["command_id"],
      opts
    )
  end

  defp dispatch_tool("studio_present_proposal", arguments, opts) do
    IntentService.present_proposal(arguments["intent_id"], arguments["command_id"], opts)
  end

  defp dispatch_tool("studio_approve_publication", arguments, opts) do
    IntentService.approve_publication(
      arguments["intent_id"],
      arguments["proposal_digest"],
      arguments["confirmation"],
      arguments["command_id"],
      opts
    )
  end

  defp dispatch_tool("studio_publish_approved_plan", arguments, opts) do
    IntentService.publish_approved_plan(arguments["intent_id"], arguments["command_id"], opts)
  end

  defp dispatch_tool("studio_start_first_ready", arguments, opts) do
    IntentService.start_first_ready(
      arguments["intent_id"],
      arguments["confirmation"],
      arguments["command_id"],
      opts
    )
  end

  defp dispatch_tool("studio_get_intent_status", arguments, opts) do
    IntentService.get_intent_status(arguments["intent_id"], opts)
  end

  defp dispatch_tool(_unknown, _arguments, _opts) do
    {:error, %{code: :unknown_tool, details: %{}, message: "Unknown Intent Service tool."}}
  end

  defp tools do
    [
      tool(
        "studio_attach_project",
        "Attach Project",
        "Attach an existing absolute project directory. This writes only owner-local Intent Service metadata and never executes project code.",
        object_schema(
          %{
            "command_id" => command_id_schema(),
            "project_root" => %{"type" => "string", "minLength" => 1}
          },
          ["project_root", "command_id"]
        ),
        local_annotations()
      ),
      tool(
        "studio_submit_intent",
        "Submit Intent",
        "Submit a prompt or Markdown specification, then run bounded read-only project inspection. Returns one clarification batch or a proposed task DAG.",
        object_schema(
          %{
            "command_id" => command_id_schema(),
            "project_id" => id_schema("project_"),
            "source" =>
              object_schema(
                %{
                  "content" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_source_bytes},
                  "kind" => %{"type" => "string", "enum" => ["prompt", "markdown"]}
                },
                ["kind", "content"]
              )
          },
          ["project_id", "source", "command_id"]
        ),
        local_annotations()
      ),
      tool(
        "studio_answer_clarifications",
        "Answer Clarifications",
        "Answer every pending clarification in one batch, or choose all recommended defaults. This creates the digestable proposal.",
        %{
          "additionalProperties" => false,
          "oneOf" => [
            object_schema(
              %{
                "answers" => %{
                  "additionalProperties" => %{"type" => "string", "minLength" => 1, "maxLength" => @max_answer_bytes},
                  "type" => "object"
                },
                "command_id" => command_id_schema(),
                "intent_id" => id_schema("intent_")
              },
              ["intent_id", "answers", "command_id"]
            ),
            object_schema(
              %{
                "command_id" => command_id_schema(),
                "intent_id" => id_schema("intent_"),
                "use_recommended_defaults" => %{"const" => true}
              },
              ["intent_id", "use_recommended_defaults", "command_id"]
            )
          ],
          "type" => "object"
        },
        local_annotations()
      ),
      tool(
        "studio_present_proposal",
        "Present Proposal",
        "Explicitly present the current 3-5 task DAG and immutable proposal digest before any publication approval.",
        intent_command_schema(),
        local_annotations()
      ),
      tool(
        "studio_approve_publication",
        "Approve Backlog Publication",
        "Record approval only when the human supplies exact confirmation publish_linear_backlog and the exact presented proposal digest.",
        object_schema(
          %{
            "command_id" => command_id_schema(),
            "confirmation" => %{"const" => "publish_linear_backlog"},
            "intent_id" => id_schema("intent_"),
            "proposal_digest" => %{"pattern" => "^[0-9a-f]{64}$", "type" => "string"}
          },
          ["intent_id", "proposal_digest", "confirmation", "command_id"]
        ),
        local_annotations()
      ),
      tool(
        "studio_publish_approved_plan",
        "Publish Approved Plan",
        "Reconcile exact idempotency markers and publish through the dedicated least-privilege broker. Partial, blocked, or uncertain outcomes remain visible and resumable.",
        intent_command_schema(),
        external_annotations()
      ),
      tool(
        "studio_start_first_ready",
        "Start First Ready",
        "After complete publication, transition exactly one deterministic ready issue to Todo only with exact confirmation start_first_ready, then wait for a real Symphony admission event.",
        object_schema(
          %{
            "command_id" => command_id_schema(),
            "confirmation" => %{"const" => "start_first_ready"},
            "intent_id" => id_schema("intent_")
          },
          ["intent_id", "confirmation", "command_id"]
        ),
        external_annotations()
      ),
      tool(
        "studio_get_intent_status",
        "Get Intent Status",
        "Read the durable intent projection, including clarification, proposal, approval, publication uncertainty, start, and Symphony admission linkage.",
        object_schema(%{"intent_id" => id_schema("intent_")}, ["intent_id"]),
        %{
          "destructiveHint" => false,
          "idempotentHint" => true,
          "openWorldHint" => false,
          "readOnlyHint" => true
        }
      )
    ]
  end

  defp tool(name, title, description, schema, annotations) do
    %{
      "annotations" => Map.put(annotations, "title", title),
      "description" => description,
      "execution" => %{"taskSupport" => "forbidden"},
      "inputSchema" => schema,
      "name" => name,
      "title" => title
    }
  end

  defp object_schema(properties, required) do
    %{
      "additionalProperties" => false,
      "properties" => properties,
      "required" => required,
      "type" => "object"
    }
  end

  defp intent_command_schema do
    object_schema(
      %{"command_id" => command_id_schema(), "intent_id" => id_schema("intent_")},
      ["intent_id", "command_id"]
    )
  end

  defp command_id_schema do
    %{
      "maxLength" => 160,
      "minLength" => 1,
      "pattern" => "^[A-Za-z0-9][A-Za-z0-9._:-]*$",
      "type" => "string"
    }
  end

  defp id_schema(prefix),
    do: %{"pattern" => "^#{prefix}[a-z0-9_]+$", "type" => "string"}

  defp local_annotations do
    %{
      "destructiveHint" => false,
      "idempotentHint" => true,
      "openWorldHint" => false,
      "readOnlyHint" => false
    }
  end

  defp external_annotations do
    %{
      "destructiveHint" => true,
      "idempotentHint" => true,
      "openWorldHint" => true,
      "readOnlyHint" => false
    }
  end

  defp known_tool?(name), do: Enum.any?(tools(), &(&1["name"] == name))

  defp tool_result(structured, is_error) do
    %{
      "content" => [%{"text" => Canonical.json(structured), "type" => "text"}],
      "isError" => is_error,
      "structuredContent" => structured
    }
  end

  defp json_safe_error(%{code: code, details: details, message: message}) do
    %{"code" => to_string(code), "details" => details, "message" => message}
  end

  defp json_safe_error(_error) do
    %{"code" => "intent_service_failed", "details" => %{}, "message" => "Intent Service operation failed safely."}
  end

  defp json_result(id, result), do: %{"id" => id, "jsonrpc" => "2.0", "result" => result}

  defp json_error(id, code, message),
    do: %{"error" => %{"code" => code, "message" => message}, "id" => id, "jsonrpc" => "2.0"}

  defp write_response(response) do
    response
    |> Jason.encode!()
    |> IO.puts()
  end

  defp server_instructions do
    "Inspect and clarify before planning. Present the full proposal and digest before approval. Never infer publication consent: studio_approve_publication requires the human's exact publish_linear_backlog confirmation. Publication may remain blocked, partial, or uncertain. Never infer start consent: studio_start_first_ready separately requires start_first_ready. After transition, wait for a real Symphony worker.attempt.started admission event. SYM-1 and SYM-2 are permanently denied."
  end

  defp service_options(opts) do
    allowed = [:broker, :data_root, :store]
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and Enum.all?(keys, &(&1 in allowed)) and
         length(keys) == MapSet.size(MapSet.new(keys)) do
      {:ok, opts}
    else
      {:error, "invalid options"}
    end
  end

  defp production_cli_options(args) do
    case cli_options(args) do
      {:ok, opts} -> {:ok, Keyword.put(opts, :broker, Linear.target())}
      other -> other
    end
  end

  defp cli_options(args) do
    args
    |> OptionParser.parse(
      strict: [data_root: :string, help: :boolean],
      aliases: [h: :help]
    )
    |> validate_cli_parse()
  end

  defp validate_cli_parse({options, [], []}) do
    if duplicate_options?(options), do: {:error, "invalid arguments"}, else: resolve_cli_options(options)
  end

  defp validate_cli_parse({_options, _positional, _invalid}), do: {:error, "invalid arguments"}

  defp resolve_cli_options([]), do: {:ok, []}
  defp resolve_cli_options(help: true), do: :help

  defp resolve_cli_options(data_root: data_root) do
    if Path.type(data_root) == :absolute,
      do: {:ok, [data_root: Path.expand(data_root)]},
      else: {:error, "--data-root must be absolute"}
  end

  defp resolve_cli_options(_options), do: {:error, "invalid arguments"}

  defp duplicate_options?(options) do
    keys = Keyword.keys(options)
    length(keys) != MapSet.size(MapSet.new(keys))
  end

  defp cli_help do
    """
    Run the precompiled Symphony Studio Intent MCP server over STDIO with the
    dedicated least-privilege Linear adapter.

      studio_intent_mcp [--data-root /absolute/owner-local/path]

    Compile the Elixir project before launching. Standard output is reserved
    for newline-delimited MCP JSON-RPC messages while the server is running.
    The separate protected Linear credential is read only during a bounded
    broker request; missing or invalid credential configuration fails closed.
    """
    |> String.trim()
  end
end
