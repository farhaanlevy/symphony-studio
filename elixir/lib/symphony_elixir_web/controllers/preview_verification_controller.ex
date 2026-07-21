defmodule SymphonyElixirWeb.PreviewVerificationController do
  @moduledoc "Read-only verification endpoint for the owner browser harness."

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixirWeb.{Endpoint, RuntimeStudioDataPort}

  @spec show(Conn.t(), map()) :: Conn.t()
  def show(conn, params) do
    port = data_port()

    if function_exported?(port, :verification, 1) do
      case port.verification(params) do
        {:ok, payload} ->
          json(conn, payload)

        {:error, error} ->
          unavailable(conn, error)
      end
    else
      unavailable(conn, %{code: "verification_unavailable", message: "Live verification is unavailable.", details: %{}})
    end
  end

  defp data_port, do: Endpoint.config(:studio_data_port) || RuntimeStudioDataPort

  defp unavailable(conn, error) do
    conn
    |> put_status(503)
    |> json(%{error: error})
  end
end
