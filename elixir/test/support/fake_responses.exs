# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.TestSupport.FakeResponses do
  @moduledoc """
  Loopback-only Responses API fixture for installed-Codex conformance.

  Every completion reports zero tokens. The fixture never accepts a
  non-loopback listener and records only deterministic synthetic test input.
  """

  import ExUnit.Assertions

  alias SymphonyElixir.TestSupport.FakeResponses.{Plug, State}

  @type fixture :: %{
          base_url: String.t(),
          server: pid(),
          state: pid()
        }

  @spec start!() :: fixture()
  def start! do
    {:ok, state} = State.start_link([])

    {:ok, server} =
      Bandit.start_link(
        plug: {Plug, state: state},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(server)
    %{base_url: "http://127.0.0.1:#{port}/v1", server: server, state: state}
  end

  @spec stop(fixture()) :: :ok
  def stop(fixture) do
    _release_result = safe_release(fixture)
    safe_stop(fixture.server, &Supervisor.stop/1)
    safe_stop(fixture.state, &GenServer.stop/1)
    :ok
  end

  @spec expect!(fixture(), String.t(), map(), {:sse, [map()]} | {:hold, String.t(), [map()]}) :: :ok
  def expect!(fixture, label, matcher, action)
      when is_binary(label) and is_map(matcher) do
    assert label != "", "fake Responses expectation label must not be empty"
    assert matcher != %{}, "fake Responses matcher must not be empty"
    assert :ok = State.expect(fixture.state, label, matcher, action)
  end

  @spec expect_rejection!(fixture(), :invalid_request | :route_not_found | :unexpected_request) ::
          :ok
  def expect_rejection!(fixture, kind)
      when kind in [:invalid_request, :route_not_found, :unexpected_request] do
    assert :ok = State.expect_rejection(fixture.state, kind)
  end

  @spec requests(fixture()) :: [map()]
  def requests(fixture), do: State.requests(fixture.state)

  @spec attempts(fixture()) :: [map()]
  def attempts(fixture), do: State.attempts(fixture.state)

  @spec held_labels(fixture()) :: [String.t()]
  def held_labels(fixture), do: State.held_labels(fixture.state)

  @spec release_all(fixture()) :: :ok | {:error, :release_timeout}
  def release_all(fixture) do
    :ok = State.release_all(fixture.state)
    await_releases(fixture.state, 200)
  end

  @spec verify!(fixture()) :: :ok
  def verify!(fixture) do
    snapshot = State.snapshot(fixture.state)
    assert snapshot.expectations == [], "fake Responses has unconsumed expectations"
    assert snapshot.expected_rejections == [], "fake Responses has unconsumed rejection expectations"
    assert snapshot.holds == %{}, "fake Responses has unreleased streams"
    assert snapshot.failures == [], "fake Responses observed a stream failure"
    :ok
  end

  @spec response_created(String.t()) :: map()
  def response_created(id), do: %{"type" => "response.created", "response" => %{"id" => id}}

  @spec completed(String.t()) :: map()
  def completed(id) do
    %{
      "type" => "response.completed",
      "response" => %{
        "id" => id,
        "usage" => %{
          "input_tokens" => 0,
          "input_tokens_details" => nil,
          "output_tokens" => 0,
          "output_tokens_details" => nil,
          "total_tokens" => 0
        }
      }
    }
  end

  @spec assistant_message(String.t(), String.t()) :: map()
  def assistant_message(id, text) do
    %{
      "type" => "response.output_item.done",
      "item" => %{
        "content" => [%{"text" => text, "type" => "output_text"}],
        "id" => id,
        "role" => "assistant",
        "type" => "message"
      }
    }
  end

  @spec function_call(String.t(), String.t(), String.t(), map()) :: map()
  def function_call(call_id, namespace, name, arguments) when is_map(arguments) do
    %{
      "type" => "response.output_item.done",
      "item" => %{
        "arguments" => Jason.encode!(arguments),
        "call_id" => call_id,
        "name" => name,
        "namespace" => namespace,
        "type" => "function_call"
      }
    }
  end

  @spec sse([map()]) :: binary()
  def sse(events) when is_list(events) do
    Enum.map_join(events, fn event ->
      type = Map.fetch!(event, "type")
      "event: #{type}\ndata: #{Jason.encode!(event)}\n\n"
    end)
  end

  defp safe_stop(pid, stop_fun) do
    if Process.alive?(pid) do
      try do
        stop_fun.(pid)
      catch
        :exit, _reason -> :ok
      end
    end
  end

  defp safe_release(fixture) do
    if Process.alive?(fixture.state), do: release_all(fixture), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp await_releases(_state, 0), do: {:error, :release_timeout}

  defp await_releases(state, attempts) do
    if State.held_labels(state) == [] do
      :ok
    else
      Process.sleep(5)
      await_releases(state, attempts - 1)
    end
  end
end

defmodule SymphonyElixir.TestSupport.FakeResponses.State do
  @moduledoc false

  use GenServer

  alias SymphonyElixir.TestSupport.FakeResponses

  @max_response_bytes 4 * 1024 * 1024

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec expect(pid(), String.t(), map(), term()) :: :ok | {:error, atom()}
  def expect(server, label, matcher, action),
    do: GenServer.call(server, {:expect, label, matcher, action})

  @spec expect_rejection(pid(), atom()) :: :ok
  def expect_rejection(server, kind), do: GenServer.call(server, {:expect_rejection, kind})

  @spec dispatch(pid(), map()) ::
          {:sse, binary()}
          | {:hold, String.t(), binary(), String.t()}
          | {:error, atom()}
  def dispatch(server, body), do: GenServer.call(server, {:dispatch, body})

  @spec register_hold(pid(), String.t(), pid(), String.t()) :: :ok | {:error, atom()}
  def register_hold(server, label, process, response_id),
    do: GenServer.call(server, {:register_hold, label, process, response_id})

  @spec complete_hold(pid(), String.t(), :released | {:error, atom()}) ::
          :ok | {:error, atom()}
  def complete_hold(server, label, result),
    do: GenServer.call(server, {:complete_hold, label, result})

  @spec record_failure(pid(), String.t(), atom()) :: :ok
  def record_failure(server, label, kind),
    do: GenServer.call(server, {:record_failure, label, kind})

  @spec record_rejection(pid(), atom()) :: :ok
  def record_rejection(server, kind), do: GenServer.call(server, {:record_rejection, kind})

  @spec release_all(pid()) :: :ok
  def release_all(server), do: GenServer.call(server, :release_all)

  @spec requests(pid()) :: [map()]
  def requests(server), do: GenServer.call(server, :requests)

  @spec attempts(pid()) :: [map()]
  def attempts(server), do: GenServer.call(server, :attempts)

  @spec held_labels(pid()) :: [String.t()]
  def held_labels(server), do: GenServer.call(server, :held_labels)

  @spec snapshot(pid()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl GenServer
  def init(_opts) do
    {:ok,
     %{
       attempts: [],
       expectations: [],
       expected_rejections: [],
       failures: [],
       holds: %{},
       requests: [],
       used_labels: MapSet.new()
     }}
  end

  @impl GenServer
  def handle_call({:expect, label, matcher, action}, _from, state) do
    with false <- MapSet.member?(state.used_labels, label),
         {:ok, normalized_matcher} <- normalize_matcher(matcher),
         {:ok, normalized_action} <- normalize_action(action) do
      expectation = %{action: normalized_action, label: label, matcher: normalized_matcher}

      {:reply, :ok,
       %{
         state
         | expectations: state.expectations ++ [expectation],
           used_labels: MapSet.put(state.used_labels, label)
       }}
    else
      true -> {:reply, {:error, :duplicate_label}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:expect_rejection, kind}, _from, state) do
    {:reply, :ok, %{state | expected_rejections: state.expected_rejections ++ [kind]}}
  end

  def handle_call({:dispatch, body}, _from, state) do
    case pop_matching(state.expectations, body) do
      {:ok, expectation, remaining} ->
        request = request_receipt(expectation.label, body, state.requests)
        attempt = attempt_receipt(:decoded_post, state.attempts)

        next_state = %{
          state
          | attempts: state.attempts ++ [attempt],
            expectations: remaining,
            requests: state.requests ++ [request]
        }

        {:reply, render_action(expectation), next_state}

      :error ->
        request = request_receipt(:unexpected, body, state.requests)
        attempt = attempt_receipt(:unexpected_request, state.attempts)

        next_state =
          state
          |> Map.put(:attempts, state.attempts ++ [attempt])
          |> Map.put(:requests, state.requests ++ [request])
          |> consume_rejection(:unexpected_request)

        {:reply, {:error, :unexpected_request}, next_state}
    end
  end

  def handle_call({:register_hold, label, process, response_id}, _from, state) do
    if Map.has_key?(state.holds, label) do
      {:reply, {:error, :duplicate_hold}, state}
    else
      monitor = Process.monitor(process)
      hold = %{monitor: monitor, pid: process, response_id: response_id, release_sent: false}
      {:reply, :ok, %{state | holds: Map.put(state.holds, label, hold)}}
    end
  end

  def handle_call({:complete_hold, label, result}, _from, state) do
    case Map.pop(state.holds, label) do
      {nil, _holds} ->
        {:reply, {:error, :unknown_hold}, state}

      {hold, holds} ->
        Process.demonitor(hold.monitor, [:flush])
        failures = maybe_record_hold_failure(state.failures, label, result)
        {:reply, :ok, %{state | failures: failures, holds: holds}}
    end
  end

  def handle_call({:record_failure, label, kind}, _from, state) do
    failure = %{kind: kind, label: label}
    {:reply, :ok, %{state | failures: state.failures ++ [failure]}}
  end

  def handle_call({:record_rejection, kind}, _from, state) do
    attempt = attempt_receipt(kind, state.attempts)

    next_state =
      state
      |> Map.put(:attempts, state.attempts ++ [attempt])
      |> consume_rejection(kind)

    {:reply, :ok, next_state}
  end

  def handle_call(:release_all, _from, state) do
    holds =
      Map.new(state.holds, fn {label, hold} ->
        send(
          hold.pid,
          {:fake_responses_release, FakeResponses.sse([FakeResponses.completed(hold.response_id)])}
        )

        {label, %{hold | release_sent: true}}
      end)

    {:reply, :ok, %{state | holds: holds}}
  end

  def handle_call(:requests, _from, state), do: {:reply, state.requests, state}
  def handle_call(:attempts, _from, state), do: {:reply, state.attempts, state}
  def handle_call(:held_labels, _from, state), do: {:reply, state.holds |> Map.keys() |> Enum.sort(), state}
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.holds, fn {_label, hold} -> hold.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {label, _hold} ->
        holds = Map.delete(state.holds, label)
        failure = %{kind: :held_stream_process_exit, label: label, reason: exit_category(reason)}
        {:noreply, %{state | failures: state.failures ++ [failure], holds: holds}}
    end
  end

  defp request_receipt(label, body, prior_requests) do
    canonical_body = Jason.encode!(body)

    %{
      body_sha256: :crypto.hash(:sha256, canonical_body) |> Base.encode16(case: :lower),
      label: label,
      model: Map.get(body, "model"),
      sequence: length(prior_requests) + 1,
      transport: :loopback
    }
  end

  defp attempt_receipt(kind, prior_attempts) do
    %{kind: kind, sequence: length(prior_attempts) + 1, transport: :loopback}
  end

  defp consume_rejection(state, kind) do
    case Enum.split_while(state.expected_rejections, &(&1 != kind)) do
      {_prefix, []} ->
        failure = %{kind: :unexpected_http_attempt, outcome: kind}
        %{state | failures: state.failures ++ [failure]}

      {prefix, [_matched | suffix]} ->
        %{state | expected_rejections: prefix ++ suffix}
    end
  end

  defp pop_matching([], _body), do: :error

  defp pop_matching(expectations, body) do
    stage = expectations |> Enum.map(& &1.matcher.stage) |> Enum.min()

    case Enum.split_while(expectations, fn expectation ->
           expectation.matcher.stage != stage or not matches?(expectation.matcher, body)
         end) do
      {_prefix, []} -> :error
      {prefix, [matched | suffix]} -> {:ok, matched, prefix ++ suffix}
    end
  end

  defp matches?(matcher, body) do
    input_values = body |> Map.get("input") |> nested_string_values()
    model_matches = is_nil(matcher.model) or Map.get(body, "model") == matcher.model

    model_matches and
      Enum.all?(matcher.input_values, &(&1 in input_values)) and
      Enum.all?(matcher.input_excludes, &(&1 not in input_values))
  end

  defp normalize_matcher(matcher) do
    allowed_keys = [
      :input_values,
      :input_excludes,
      :model,
      :stage,
      "input_values",
      "input_excludes",
      "model",
      "stage"
    ]

    normalized = %{
      input_values: Map.get(matcher, :input_values, Map.get(matcher, "input_values", [])),
      input_excludes: Map.get(matcher, :input_excludes, Map.get(matcher, "input_excludes", [])),
      model: Map.get(matcher, :model, Map.get(matcher, "model")),
      stage: Map.get(matcher, :stage, Map.get(matcher, "stage"))
    }

    with true <- Enum.all?(Map.keys(matcher), &(&1 in allowed_keys)),
         true <- matcher_lists?(normalized),
         true <- normalized.input_values != [],
         true <- valid_matcher_stage?(normalized.stage),
         true <- valid_matcher_model?(normalized.model),
         true <- valid_matcher_values?(normalized) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_matcher}
    end
  end

  defp matcher_lists?(matcher),
    do: is_list(matcher.input_values) and is_list(matcher.input_excludes)

  defp valid_matcher_stage?(stage), do: is_integer(stage) and stage >= 1
  defp valid_matcher_model?(nil), do: true
  defp valid_matcher_model?(model), do: non_empty_binary?(model)

  defp valid_matcher_values?(matcher),
    do: Enum.all?(matcher.input_values ++ matcher.input_excludes, &non_empty_binary?/1)

  defp normalize_action({:sse, events}) do
    with {:ok, payload} <- render_events(events),
         true <- byte_size(payload) <= @max_response_bytes do
      {:ok, {:sse, payload}}
    else
      _invalid -> {:error, :invalid_action}
    end
  end

  defp normalize_action({:hold, response_id, events}) when is_binary(response_id) do
    with true <- response_id != "",
         {:ok, payload} <- render_events(events),
         true <- byte_size(payload) <= @max_response_bytes do
      {:ok, {:hold, response_id, payload}}
    else
      _invalid -> {:error, :invalid_action}
    end
  end

  defp normalize_action(_action), do: {:error, :invalid_action}

  defp render_events(events) when is_list(events) and events != [] do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, rendered} ->
      with true <- is_map(event),
           type when is_binary(type) and type != "" <- Map.get(event, "type"),
           false <- String.contains?(type, ["\r", "\n"]),
           {:ok, encoded} <- Jason.encode(event) do
        {:cont, {:ok, [["event: ", type, "\ndata: ", encoded, "\n\n"] | rendered]}}
      else
        _invalid -> {:halt, {:error, :invalid_event}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, rendered |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, _reason} = error -> error
    end
  end

  defp render_events(_events), do: {:error, :invalid_event}

  defp render_action(%{action: {:sse, payload}}), do: {:sse, payload}

  defp render_action(%{label: label, action: {:hold, response_id, payload}}),
    do: {:hold, label, payload, response_id}

  defp maybe_record_hold_failure(failures, _label, :released), do: failures

  defp maybe_record_hold_failure(failures, label, {:error, kind}) do
    failures ++ [%{kind: kind, label: label}]
  end

  defp exit_category(:normal), do: :normal
  defp exit_category(:shutdown), do: :shutdown
  defp exit_category({:shutdown, _detail}), do: :shutdown
  defp exit_category(_reason), do: :abnormal

  defp nested_string_values(value) when is_binary(value), do: [value]
  defp nested_string_values(value) when is_list(value), do: Enum.flat_map(value, &nested_string_values/1)
  defp nested_string_values(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&nested_string_values/1)
  defp nested_string_values(_value), do: []

  defp non_empty_binary?(value), do: is_binary(value) and value != ""
end

defmodule SymphonyElixir.TestSupport.FakeResponses.Plug do
  @moduledoc false

  import Plug.Conn

  alias SymphonyElixir.TestSupport.FakeResponses.State

  @max_request_bytes 4 * 1024 * 1024
  @hold_timeout_ms 30_000

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{method: "POST", request_path: "/v1/responses"} = conn, opts) do
    state = Keyword.fetch!(opts, :state)

    with {:ok, body, conn} <- read_complete_body(conn, ""),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      respond(conn, state, State.dispatch(state, decoded))
    else
      _error ->
        :ok = State.record_rejection(state, :invalid_request)
        send_resp(conn, 400, "invalid synthetic request")
    end
  end

  def call(conn, opts) do
    state = Keyword.fetch!(opts, :state)
    :ok = State.record_rejection(state, :route_not_found)
    send_resp(conn, 404, "not found")
  end

  defp respond(conn, _state, {:sse, payload}) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, payload)
  end

  defp respond(conn, state, {:hold, label, initial_payload, response_id}) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case chunk(conn, initial_payload) do
      {:ok, conn} ->
        case State.register_hold(state, label, self(), response_id) do
          :ok ->
            await_release(conn, state, label)

          {:error, reason} ->
            :ok = State.record_failure(state, label, reason)
            conn
        end

      {:error, _reason} ->
        :ok = State.record_failure(state, label, :initial_chunk_failed)
        conn
    end
  end

  defp respond(conn, _state, {:error, :unexpected_request}),
    do: send_resp(conn, 500, "unexpected synthetic request")

  defp await_release(conn, state, label) do
    receive do
      {:fake_responses_release, final_payload} ->
        case chunk(conn, final_payload) do
          {:ok, released} ->
            :ok = State.complete_hold(state, label, :released)
            released

          {:error, _reason} ->
            :ok = State.complete_hold(state, label, {:error, :release_chunk_failed})
            conn
        end
    after
      @hold_timeout_ms ->
        :ok = State.complete_hold(state, label, {:error, :hold_timeout})
        conn
    end
  end

  defp read_complete_body(conn, acc) when byte_size(acc) <= @max_request_bytes do
    case read_body(conn, length: @max_request_bytes, read_length: 64 * 1024) do
      {:ok, body, conn} -> bounded_body(acc, body, conn)
      {:more, body, conn} -> continue_body(acc, body, conn)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_complete_body(_conn, _acc), do: {:error, :request_too_large}

  defp bounded_body(acc, body, conn) do
    complete = acc <> body
    if byte_size(complete) <= @max_request_bytes, do: {:ok, complete, conn}, else: {:error, :request_too_large}
  end

  defp continue_body(acc, body, conn) do
    next = acc <> body
    if byte_size(next) <= @max_request_bytes, do: read_complete_body(conn, next), else: {:error, :request_too_large}
  end
end
