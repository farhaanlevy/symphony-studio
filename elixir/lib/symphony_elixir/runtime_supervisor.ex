# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.RuntimeSupervisor do
  @moduledoc """
  Couples the in-memory orchestrator with every AgentRunner and workspace-hook
  task it owns.

  A fresh orchestrator must never coexist with work admitted by a crashed
  predecessor. A cleanup registry and the Cleanup and Connection supervisors
  start before hook and agent task supervisors, so reverse shutdown leaves
  cleanup authority available until every Connection, hook, and AgentRunner
  has retired. The registry monitors both durable cleanup handles and those
  runtime-member lifetimes; the member supervisors and CleanupSupervisor form
  reciprocal barriers if any nested supervisor or the registry crashes.
  `:one_for_all` waits for the complete runtime containment domain before any
  child restarts. Workflow and UI supervisors remain outside this failure
  domain.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec(SymphonyElixir.Codex.CleanupBarrier, shutdown: :infinity),
      Supervisor.child_spec(
        {Task.Supervisor, name: SymphonyElixir.CleanupSupervisor},
        shutdown: :infinity
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, name: SymphonyElixir.ConnectionSupervisor, strategy: :one_for_one},
        shutdown: :infinity
      ),
      Supervisor.child_spec(
        {Task.Supervisor, name: SymphonyElixir.WorkspaceHookSupervisor},
        shutdown: :infinity
      ),
      Supervisor.child_spec(
        {Task.Supervisor, name: SymphonyElixir.TaskSupervisor},
        shutdown: :infinity
      ),
      SymphonyElixir.Orchestrator
    ]

    Supervisor.init(children,
      strategy: :one_for_all,
      max_restarts: 10,
      max_seconds: 5
    )
  end
end
