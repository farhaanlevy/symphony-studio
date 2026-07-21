# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule Mix.Tasks.Studio.IntentMcp do
  @moduledoc """
  Development wrapper for the local Symphony Studio Intent MCP server.

  The executable `scripts/studio_intent_mcp` is the protocol-clean integration
  entrypoint. It avoids Mix and dependency compiler output on standard output.

      mise exec -- mix compile
      scripts/studio_intent_mcp --data-root /absolute/owner-local/path
  """

  use Mix.Task

  alias SymphonyElixir.Studio.Intent.MCPServer

  @requirements []
  @shortdoc "Run the fail-closed local Intent MCP server over STDIO"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [data_root: :string, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      options[:help] ->
        Mix.shell().info(@moduledoc)
        :ok

      positional != [] or invalid != [] ->
        Mix.raise("studio.intent_mcp: invalid arguments")

      data_root = options[:data_root] ->
        if Path.type(data_root) == :absolute do
          MCPServer.run(data_root: Path.expand(data_root))
        else
          Mix.raise("studio.intent_mcp: --data-root must be absolute")
        end

      true ->
        MCPServer.run()
    end
  end
end
