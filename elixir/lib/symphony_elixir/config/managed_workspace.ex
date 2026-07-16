# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Config.ManagedWorkspace do
  @moduledoc """
  Validates the filesystem boundary for a managed workspace sandbox.

  This boundary intentionally rechecks both pathname shape and live filesystem
  identity. A same-UID pathname mutation between those checks remains a
  fail-closed TOCTOU defense outside deterministic line instrumentation.
  """

  alias SymphonyElixir.PathSafety

  @spec validate(Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, {:unsafe_turn_sandbox_policy, term()}}
  def validate(canonical_root, workspace)
      when is_binary(canonical_root) and is_binary(workspace) and workspace != "" do
    expanded_workspace = Path.expand(workspace)

    with true <- Path.type(workspace) == :absolute,
         true <- expanded_workspace == workspace,
         true <- Path.dirname(workspace) == canonical_root,
         :ok <- reject_symlink(workspace),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(workspace),
         true <- canonical_workspace == workspace,
         true <- File.dir?(workspace) do
      {:ok, canonical_workspace}
    else
      false ->
        {:error, {:unsafe_turn_sandbox_policy, {:invalid_managed_workspace, workspace}}}

      {:error, {:path_canonicalize_failed, _path, reason}} ->
        {:error, {:unsafe_turn_sandbox_policy, {:invalid_managed_workspace, reason}}}

      {:error, reason} ->
        {:error, {:unsafe_turn_sandbox_policy, reason}}
    end
  end

  def validate(_canonical_root, workspace) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_managed_workspace, workspace}}}
  end

  defp reject_symlink(workspace) do
    case File.lstat(workspace) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:managed_workspace_symlink, workspace}}
      {:ok, _stat} -> :ok
      {:error, reason} -> {:error, {:managed_workspace_unreadable, reason}}
    end
  end
end
