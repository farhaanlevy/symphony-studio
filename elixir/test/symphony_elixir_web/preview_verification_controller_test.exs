defmodule SymphonyElixirWeb.PreviewVerificationControllerTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule TestDataPort do
    def verification(params) do
      {:ok,
       %{
         authoritative: true,
         mode: "live",
         requestedRun: params["run_id"],
         schemaVersion: 1,
         source: "symphony_runtime"
       }}
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, [])

    next =
      previous
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.put(:studio_data_port, TestDataPort)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, next)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, previous)
    end)

    :ok
  end

  test "GET exposes only the bounded read-only verification projection" do
    response = get(build_conn(), "/api/preview/v1/verification?run_id=run-123")

    assert json_response(response, 200) == %{
             "authoritative" => true,
             "mode" => "live",
             "requestedRun" => "run-123",
             "schemaVersion" => 1,
             "source" => "symphony_runtime"
           }
  end

  test "non-GET methods remain disabled" do
    response = post(build_conn(), "/api/preview/v1/verification", %{})
    assert %{"error" => %{"code" => "method_not_allowed"}} = json_response(response, 405)
  end
end
