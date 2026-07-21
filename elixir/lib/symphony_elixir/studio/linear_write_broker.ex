# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker do
  @moduledoc """
  Least-privilege boundary for Symphony Studio Linear backlog writes.

  The existing Symphony credential remains query-only. The boundary defaults
  to `Unavailable`; production entrypoints explicitly inject the protected
  `Linear` adapter, which requires a separate least-privilege key and performs
  exact idempotency-marker reconciliation. SYM-1 and SYM-2 are denied both
  before delegation and on adapter responses.
  """

  alias SymphonyElixir.Studio.LinearWriteBroker.{Command, Result, Unavailable}

  @type target :: module() | {module(), term()}
  @type error ::
          Command.error()
          | Result.error()
          | :protected_linear_issue_denied
          | :least_privilege_write_broker_unavailable
          | :linear_write_broker_unavailable
          | :linear_write_broker_rejected
          | :linear_write_broker_failed
          | :linear_write_broker_invalid_response

  @callback reconcile(term(), Command.t()) :: {:ok, Result.t()} | {:error, term()}
  @callback execute(term(), Command.t()) :: {:ok, Result.t()} | {:error, term()}

  @doc "Returns the fail-closed default target; it never uses the query credential."
  @spec default_target() :: target()
  def default_target, do: Unavailable

  @doc "Reconciles an exact idempotency marker through the fail-closed default target."
  @spec reconcile(Command.t() | map() | keyword()) :: {:ok, Result.t()} | {:error, error()}
  def reconcile(command), do: reconcile(default_target(), command)

  @doc "Reconciles an exact idempotency marker before any possible execution."
  @spec reconcile(target(), Command.t() | map() | keyword()) ::
          {:ok, Result.t()} | {:error, error()}
  def reconcile(target, command), do: call(target, :reconcile, command)

  @doc "Executes one previously reconciled digest-bound command."
  @spec execute(Command.t() | map() | keyword()) :: {:ok, Result.t()} | {:error, error()}
  def execute(command), do: execute(default_target(), command)

  @doc "Executes one command through an explicitly injected write target."
  @spec execute(target(), Command.t() | map() | keyword()) ::
          {:ok, Result.t()} | {:error, error()}
  def execute(target, command), do: call(target, :execute, command)

  @doc "Returns true only for the permanently protected bootstrap issues."
  @spec protected_identifier?(term()) :: boolean()
  def protected_identifier?(identifier) when is_binary(identifier) do
    String.upcase(String.trim(identifier)) in ["SYM-1", "SYM-2"]
  end

  def protected_identifier?(_identifier), do: false

  defp call(target, operation, command) do
    with {:ok, command} <- Command.new(command),
         :ok <- deny_protected_command(command),
         {:ok, {adapter, server}} <- normalize_target(target),
         :ok <- ensure_adapter(adapter, operation),
         {:ok, result} <- safe_adapter_call(adapter, server, operation, command),
         {:ok, result} <- Result.new(result),
         :ok <- validate_result_contract(command, result),
         :ok <- deny_protected_result(result) do
      {:ok, result}
    end
  end

  defp deny_protected_command(%Command{kind: :transition, payload: payload}) do
    if protected_identifier?(payload["issue_identifier"]),
      do: {:error, :protected_linear_issue_denied},
      else: :ok
  end

  defp deny_protected_command(_command), do: :ok

  defp deny_protected_result(%Result{issue_identifier: identifier}) do
    if protected_identifier?(identifier),
      do: {:error, :protected_linear_issue_denied},
      else: :ok
  end

  defp validate_result_contract(%Command{kind: :issue}, %Result{
         status: :confirmed,
         issue_identifier: identifier
       })
       when is_binary(identifier),
       do: :ok

  defp validate_result_contract(%Command{kind: :issue}, %Result{status: :confirmed}),
    do: {:error, :linear_write_broker_invalid_response}

  defp validate_result_contract(
         %Command{kind: :transition, payload: payload},
         %Result{status: :confirmed, external_id: external_id, issue_identifier: identifier}
       ) do
    if external_id == payload["issue_id"] and identifier == payload["issue_identifier"],
      do: :ok,
      else: {:error, :linear_write_broker_invalid_response}
  end

  defp validate_result_contract(_command, _result), do: :ok

  defp normalize_target({adapter, server}) when is_atom(adapter), do: {:ok, {adapter, server}}
  defp normalize_target(adapter) when is_atom(adapter), do: {:ok, {adapter, adapter}}
  defp normalize_target(_target), do: {:error, :linear_write_broker_unavailable}

  defp ensure_adapter(adapter, operation) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, operation, 2),
      do: :ok,
      else: {:error, :linear_write_broker_unavailable}
  end

  defp safe_adapter_call(adapter, server, operation, command) do
    case apply(adapter, operation, [server, command]) do
      {:ok, result} ->
        {:ok, result}

      {:error, :least_privilege_write_broker_unavailable} ->
        {:error, :least_privilege_write_broker_unavailable}

      {:error, :protected_linear_issue_denied} ->
        {:error, :protected_linear_issue_denied}

      {:error, :rejected} ->
        {:error, :linear_write_broker_rejected}

      {:error, _reason} ->
        {:error, :linear_write_broker_failed}

      _invalid ->
        {:error, :linear_write_broker_invalid_response}
    end
  rescue
    _error -> {:error, :linear_write_broker_failed}
  catch
    _kind, _reason -> {:error, :linear_write_broker_failed}
  end
end
