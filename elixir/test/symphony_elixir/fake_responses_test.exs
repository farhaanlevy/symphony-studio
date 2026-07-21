# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.FakeResponsesTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.TestSupport.FakeResponses

  test "serves deterministic zero-token SSE and records only loopback requests" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    response_id = "resp-immediate"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "root",
               %{
                 input_excludes: ["forbidden-marker"],
                 input_values: ["synthetic-root"],
                 model: "fixture-model",
                 stage: 1
               },
               {:sse,
                [
                  FakeResponses.response_created(response_id),
                  FakeResponses.assistant_message("msg-root", "done"),
                  FakeResponses.completed(response_id)
                ]}
             )

    assert {:ok, response} =
             Req.post(fixture.base_url <> "/responses",
               json: %{"input" => "synthetic-root", "model" => "fixture-model"}
             )

    assert response.status == 200
    assert response.headers["content-type"] == ["text/event-stream; charset=utf-8"]
    assert response.body =~ "event: response.created"
    assert response.body =~ ~s("total_tokens":0)

    assert [request] = FakeResponses.requests(fixture)
    assert request.label == "root"
    assert request.model == "fixture-model"
    assert request.sequence == 1
    assert request.transport == :loopback
    assert request.body_sha256 =~ ~r/\A[0-9a-f]{64}\z/

    assert FakeResponses.attempts(fixture) == [
             %{kind: :decoded_post, sequence: 1, transport: :loopback}
           ]

    assert :ok = FakeResponses.verify!(fixture)
  end

  test "holds a stream until bounded release and reports no residual hold" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    response_id = "resp-held"

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "child-one",
               %{input_values: ["synthetic-child"], stage: 1},
               {:hold, response_id, [FakeResponses.response_created(response_id)]}
             )

    request =
      Task.async(fn ->
        Req.post(fixture.base_url <> "/responses",
          json: %{"input" => "synthetic-child", "model" => "fixture-model"},
          receive_timeout: 5_000
        )
      end)

    assert :ok = wait_until(fn -> FakeResponses.held_labels(fixture) == ["child-one"] end)
    assert :ok = FakeResponses.release_all(fixture)

    assert {:ok, response} = Task.await(request, 5_000)
    assert response.status == 200
    assert response.body =~ "event: response.created"
    assert response.body =~ "event: response.completed"
    assert response.body =~ ~s("total_tokens":0)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "rejects malformed and unexpected requests without consuming expectations" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    assert :ok = FakeResponses.expect_rejection!(fixture, :invalid_request)
    assert :ok = FakeResponses.expect_rejection!(fixture, :unexpected_request)
    assert :ok = FakeResponses.expect_rejection!(fixture, :route_not_found)

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "expected",
               %{input_values: ["must-match-exact"], stage: 1},
               {:sse,
                [
                  FakeResponses.response_created("resp-expected"),
                  FakeResponses.completed("resp-expected")
                ]}
             )

    assert {:ok, %{status: 400}} =
             Req.post(fixture.base_url <> "/responses",
               headers: [{"content-type", "application/json"}],
               body: "{not-json"
             )

    assert {:ok, %{status: 500}} =
             Req.post(fixture.base_url <> "/responses",
               json: %{"input" => "different-marker"}
             )

    assert {:ok, %{status: 404}} = Req.get(fixture.base_url <> "/responses")

    assert :ok =
             Req.post!(fixture.base_url <> "/responses",
               json: %{"input" => "must-match-exact"}
             )
             |> then(fn response -> if response.status == 200, do: :ok, else: {:error, response.status} end)

    assert Enum.map(FakeResponses.requests(fixture), & &1.label) == [:unexpected, "expected"]

    assert Enum.map(FakeResponses.attempts(fixture), & &1.kind) == [
             :invalid_request,
             :unexpected_request,
             :route_not_found,
             :decoded_post
           ]

    assert :ok = FakeResponses.verify!(fixture)
  end

  test "fails verification for an unanticipated HTTP attempt" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    assert {:ok, %{status: 404}} = Req.get(fixture.base_url <> "/responses")

    assert FakeResponses.attempts(fixture) == [
             %{kind: :route_not_found, sequence: 1, transport: :loopback}
           ]

    assert_raise ExUnit.AssertionError, ~r/stream failure/, fn ->
      FakeResponses.verify!(fixture)
    end
  end

  test "rejects weak matchers and non-encodable events without killing fixture state" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    assert_raise ExUnit.AssertionError, fn ->
      FakeResponses.expect!(
        fixture,
        "empty-marker",
        %{input_values: [""], stage: 1},
        {:sse, [FakeResponses.completed("resp-empty")]}
      )
    end

    assert_raise ExUnit.AssertionError, fn ->
      FakeResponses.expect!(
        fixture,
        "bad-event",
        %{input_values: ["bad-event"], stage: 1},
        {:sse, [%{"type" => "response.completed", "pid" => self()}]}
      )
    end

    assert Process.alive?(fixture.state)
    assert FakeResponses.requests(fixture) == []
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "enforces expectation stages while allowing same-stage concurrency" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)
    assert :ok = FakeResponses.expect_rejection!(fixture, :unexpected_request)

    for {label, value, stage} <- [
          {"first", "first-value", 1},
          {"second-a", "second-a-value", 2},
          {"second-b", "second-b-value", 2}
        ] do
      assert :ok =
               FakeResponses.expect!(
                 fixture,
                 label,
                 %{input_values: [value], stage: stage},
                 {:sse, [FakeResponses.completed("resp-#{label}")]}
               )
    end

    assert {:ok, %{status: 500}} =
             Req.post(fixture.base_url <> "/responses", json: %{"input" => "second-b-value"})

    for value <- ["first-value", "second-b-value", "second-a-value"] do
      assert {:ok, %{status: 200}} =
               Req.post(fixture.base_url <> "/responses", json: %{"input" => value})
    end

    assert Enum.map(FakeResponses.requests(fixture), & &1.label) == [
             :unexpected,
             "first",
             "second-b",
             "second-a"
           ]

    assert :ok = FakeResponses.verify!(fixture)
  end

  test "rejects label reuse while an acknowledged hold is active" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    assert :ok =
             FakeResponses.expect!(
               fixture,
               "unique-hold",
               %{input_values: ["first-hold"], stage: 1},
               {:hold, "resp-first-hold", [FakeResponses.response_created("resp-first-hold")]}
             )

    request =
      Task.async(fn ->
        Req.post(fixture.base_url <> "/responses",
          json: %{"input" => "first-hold"},
          receive_timeout: 5_000
        )
      end)

    assert :ok = wait_until(fn -> FakeResponses.held_labels(fixture) == ["unique-hold"] end)

    assert_raise ExUnit.AssertionError, fn ->
      FakeResponses.expect!(
        fixture,
        "unique-hold",
        %{input_values: ["second-hold"], stage: 2},
        {:sse, [FakeResponses.completed("resp-second-hold")]}
      )
    end

    assert :ok = FakeResponses.release_all(fixture)
    assert {:ok, %{status: 200}} = Task.await(request, 5_000)
    assert :ok = FakeResponses.verify!(fixture)
  end

  test "fails verification when a held stream handler exits before acknowledgement" do
    fixture = FakeResponses.start!()
    on_exit(fn -> FakeResponses.stop(fixture) end)

    handler = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             FakeResponses.State.register_hold(
               fixture.state,
               "abandoned-handler",
               handler,
               "resp-abandoned-handler"
             )

    Process.exit(handler, :kill)
    assert :ok = wait_until(fn -> FakeResponses.held_labels(fixture) == [] end)

    assert_raise ExUnit.AssertionError, ~r/stream failure/, fn ->
      FakeResponses.verify!(fixture)
    end
  end

  defp wait_until(predicate, attempts \\ 100)

  defp wait_until(_predicate, 0), do: {:error, :timeout}

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(10)
      wait_until(predicate, attempts - 1)
    end
  end
end
