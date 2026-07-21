# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Studio.LinearWriteBroker.Transport do
  @moduledoc """
  Credential-isolated GraphQL transport for the Studio Linear write adapter.

  The production target pins Linear's HTTPS endpoint and loads the separate
  write credential only for the bounded request. Tests inject a deterministic
  transport through the same callback contract.
  """

  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Studio.LinearWriteBroker.ProtectedCredential

  @endpoint "https://api.linear.app/graphql"
  @max_response_bytes 512 * 1_024

  @callback graphql(term(), String.t(), map()) :: {:ok, map()} | {:error, term()}

  @doc "Returns the production transport target."
  @spec target() :: {module(), :default}
  def target, do: {__MODULE__, :default}

  @doc "Executes one bounded GraphQL request with the separate protected key."
  @spec graphql(:default, String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def graphql(:default, query, variables) when is_binary(query) and is_map(variables) do
    ProtectedCredential.with_api_key(fn key ->
      Client.graphql(query, variables,
        tracker: %{api_key: key, endpoint: @endpoint},
        max_response_bytes: @max_response_bytes
      )
      |> sanitize_response()
    end)
    |> sanitize_credential_error()
  end

  def graphql(_server, _query, _variables), do: {:error, :linear_write_transport_failed}

  defp sanitize_response({:ok, %{"errors" => _private_errors}}),
    do: {:error, :linear_write_graphql_failed}

  defp sanitize_response({:ok, %{} = response}), do: {:ok, response}
  defp sanitize_response({:error, _private_reason}), do: {:error, :linear_write_transport_failed}
  defp sanitize_response(_invalid), do: {:error, :linear_write_transport_failed}

  defp sanitize_credential_error({:error, reason})
       when reason in [
              :linear_write_credential_pointer_missing,
              :linear_write_credential_pointer_invalid,
              :linear_write_credential_path_unsafe,
              :linear_write_credential_inside_git,
              :linear_write_credential_file_missing,
              :linear_write_credential_file_unsafe,
              :linear_write_credential_file_changed,
              :linear_write_credential_content_invalid
            ],
       do: {:error, :least_privilege_write_broker_unavailable}

  defp sanitize_credential_error(result), do: result
end
