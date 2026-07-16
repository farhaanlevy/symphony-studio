# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

defmodule SymphonyElixir.Codex.ProcessAdapter.IdentityTracker do
  @moduledoc false

  use GenServer

  @default_poll_interval_ms 1_000
  @call_timeout_ms 250
  @max_consecutive_read_errors 3
  @active 0
  @verified_gone 1
  @exhausted 2

  @typedoc "A Linux process identity that is stable across PID reuse."
  @type identity :: %{
          pid: pos_integer(),
          state: String.t(),
          process_group_id: pos_integer(),
          session_id: pos_integer(),
          start_time: non_neg_integer()
        }

  @typedoc "A stable identity for the trusted init of a captured PID namespace."
  @type namespace_identity :: %{
          pid: pos_integer(),
          state: String.t(),
          process_group_id: pos_integer(),
          session_id: pos_integer(),
          start_time: non_neg_integer(),
          pid_namespace: String.t()
        }

  @typedoc "A process-group identity tracker handle."
  @type t :: %__MODULE__{
          pid: pid(),
          status: reference(),
          process_group_id: pos_integer(),
          leader: identity(),
          anchor: identity() | nil
        }

  @typedoc "Options used by the identity tracker."
  @type option ::
          {:anchor, identity()}
          | {:poll_interval_ms, pos_integer()}
          | {:proc_reader, (pos_integer() -> {:ok, [identity()]} | {:error, term()})}

  @enforce_keys [:pid, :status, :process_group_id, :leader]
  defstruct [:pid, :status, :process_group_id, :leader, :anchor]

  @doc "Reads the current Linux identity of a process-group leader."
  @spec capture_leader(pos_integer()) :: {:ok, identity()} | {:error, atom()}
  def capture_leader(pid) when is_integer(pid) and pid > 0 do
    case read_process_stat("/proc/#{pid}/stat") do
      {:ok,
       %{
         pid: ^pid,
         process_group_id: ^pid,
         state: state
       } = identity}
      when state in ["T", "t"] ->
        {:ok, identity}

      {:ok, _identity} ->
        {:error, :unexpected_process_group}

      {:error, :enoent} ->
        {:error, :leader_not_found}

      {:error, _reason} ->
        {:error, :process_identity_unavailable}
    end
  end

  @doc "Reads the pre-exec containment anchor forked by a captured leader."
  @spec capture_anchor(identity()) :: {:ok, identity()} | {:error, atom()}
  def capture_anchor(%{} = leader) do
    children_path = "/proc/#{leader.pid}/task/#{leader.pid}/children"

    with {:ok, contents} <- File.read(children_path),
         [anchor_pid_binary] <- String.split(contents, ~r/\s+/, trim: true),
         {anchor_pid, ""} <- Integer.parse(anchor_pid_binary),
         {:ok,
          %{
            pid: ^anchor_pid,
            process_group_id: process_group_id,
            session_id: session_id
          } = anchor} <- read_process_stat("/proc/#{anchor_pid}/stat"),
         true <- process_group_id == leader.process_group_id,
         true <- session_id == leader.session_id do
      {:ok, anchor}
    else
      {:error, :enoent} -> {:error, :anchor_not_found}
      _other -> {:error, :anchor_identity_unavailable}
    end
  end

  @doc "Captures the startup-blocked trusted init for a newly-created PID namespace."
  @spec capture_namespace_init(identity(), identity()) ::
          {:ok, namespace_identity()} | {:error, atom()}
  def capture_namespace_init(%{} = leader, %{} = anchor) do
    children_path = "/proc/#{leader.pid}/task/#{leader.pid}/children"

    with {:ok, contents} <- File.read(children_path),
         child_pids when is_list(child_pids) <- parse_child_pids(contents),
         [namespace_pid] <- Enum.reject(child_pids, &(&1 == anchor.pid)),
         {:ok,
          %{
            pid: ^namespace_pid,
            state: state,
            process_group_id: process_group_id,
            session_id: session_id
          } = identity} <- read_process_stat("/proc/#{namespace_pid}/stat"),
         true <- state != "Z",
         true <- process_group_id == leader.process_group_id,
         true <- session_id == leader.session_id,
         {:ok, namespace_status} <- File.read("/proc/#{namespace_pid}/status"),
         {:ok, namespace_pids} <- parse_namespace_pids(namespace_status),
         true <- length(namespace_pids) >= 2,
         true <- hd(namespace_pids) == namespace_pid,
         true <- List.last(namespace_pids) == 1,
         {:ok, pid_namespace} <- File.read_link("/proc/#{namespace_pid}/ns/pid"),
         {:ok, leader_namespace} <- File.read_link("/proc/#{leader.pid}/ns/pid"),
         true <- pid_namespace != leader_namespace do
      {:ok, Map.put(identity, :pid_namespace, pid_namespace)}
    else
      {:error, :enoent} -> {:error, :namespace_init_not_found}
      _other -> {:error, :namespace_init_identity_unavailable}
    end
  end

  @doc "Captures the blocked direct target child of the trusted namespace init."
  @spec capture_namespace_target(namespace_identity()) ::
          {:ok, namespace_identity()} | {:error, atom()}
  def capture_namespace_target(%{} = namespace_root) do
    children_path =
      "/proc/#{namespace_root.pid}/task/#{namespace_root.pid}/children"

    with {:active,
          %{
            process_group_id: process_group_id,
            session_id: session_id
          }} <- exact_identity_state(namespace_root),
         true <- process_group_id == namespace_root.pid,
         true <- session_id == namespace_root.pid,
         {:ok, contents} <- File.read(children_path),
         [target_pid] <- parse_child_pids(contents),
         {:ok,
          %{
            pid: ^target_pid,
            state: state,
            process_group_id: ^process_group_id,
            session_id: ^session_id
          } = identity} <- read_process_stat("/proc/#{target_pid}/stat"),
         true <- state != "Z",
         {:ok, target_status} <- File.read("/proc/#{target_pid}/status"),
         {:ok, namespace_pids} <- parse_namespace_pids(target_status),
         true <- length(namespace_pids) >= 2,
         true <- hd(namespace_pids) == target_pid,
         true <- List.last(namespace_pids) == 2,
         {:ok, pid_namespace} <- File.read_link("/proc/#{target_pid}/ns/pid"),
         true <- pid_namespace == namespace_root.pid_namespace do
      {:ok, Map.put(identity, :pid_namespace, pid_namespace)}
    else
      :retired -> {:error, :namespace_root_retired}
      {:error, :enoent} -> {:error, :namespace_target_not_found}
      _other -> {:error, :namespace_target_identity_unavailable}
    end
  end

  @doc "Returns the exact captured identity state without trusting a reused numeric PID."
  @spec exact_identity_state(identity() | namespace_identity()) ::
          {:active, identity()} | :retired | {:error, atom()}
  def exact_identity_state(%{} = expected) do
    case read_process_stat("/proc/#{expected.pid}/stat") do
      {:ok, %{start_time: start_time} = identity} when start_time == expected.start_time ->
        {:active, identity}

      {:ok, _reused_identity} ->
        :retired

      {:error, :enoent} ->
        :retired

      {:error, _reason} ->
        {:error, :process_identity_unavailable}
    end
  end

  @doc "Returns true only when a numeric group has a complete, confirmed empty snapshot."
  @spec untracked_group_empty?(pos_integer()) :: boolean()
  def untracked_group_empty?(process_group_id)
      when is_integer(process_group_id) and process_group_id > 0 do
    case read_process_group(process_group_id) do
      {:ok, []} -> true
      {:ok, _members} -> false
      {:error, _reason} -> false
    end
  end

  @doc "Starts an unlinked tracker for an already-captured process-group leader."
  @spec start(identity(), [option()]) :: {:ok, t()} | {:error, atom()}
  def start(%{} = leader, opts \\ []) when is_list(opts) do
    with :ok <- validate_identity(leader),
         {:ok, anchor} <- anchor(opts, leader),
         {:ok, poll_interval_ms} <- poll_interval(opts),
         {:ok, proc_reader} <- proc_reader(opts) do
      status = :atomics.new(1, [])
      :ok = :atomics.put(status, 1, @active)

      initial_state = %{
        process_group_id: leader.process_group_id,
        session_id: leader.session_id,
        leader: leader,
        anchor: anchor,
        known: initial_known_identities(leader, anchor),
        proc_reader: proc_reader,
        poll_interval_ms: poll_interval_ms,
        consecutive_read_errors: 0,
        status: status
      }

      case GenServer.start(__MODULE__, initial_state) do
        {:ok, pid} ->
          {:ok,
           %__MODULE__{
             pid: pid,
             status: status,
             process_group_id: leader.process_group_id,
             leader: leader,
             anchor: anchor
           }}

        {:error, _reason} ->
          {:error, :identity_tracker_start_failed}
      end
    end
  end

  @doc "Returns the current original-group state without trusting a reused numeric PGID."
  @spec group_state(t(), timeout()) :: {:active, [identity()]} | :retired | {:error, atom()}
  def group_state(%__MODULE__{} = tracker, timeout \\ @call_timeout_ms) do
    case tracker_status(tracker) do
      :retired -> :retired
      :active -> call_tracker(tracker, :group_state, timeout)
      :exhausted -> {:error, :identity_tracking_exhausted}
    end
  end

  @doc "Returns whether the captured leader identity, rather than only its PID, is alive."
  @spec leader_alive?(t(), timeout()) :: boolean()
  def leader_alive?(%__MODULE__{} = tracker, timeout \\ @call_timeout_ms) do
    case group_state(tracker, timeout) do
      {:active, members} ->
        leader_key = identity_key(tracker.leader)
        Enum.any?(members, &(identity_key(&1) == leader_key and &1.state != "Z"))

      :retired ->
        false

      {:error, _reason} ->
        false
    end
  end

  @doc "Runs a signal callback only while a known original group member still exists."
  @spec with_current_group(t(), timeout(), (pos_integer() -> result)) ::
          result | :retired | {:error, atom()}
        when result: term()
  def with_current_group(%__MODULE__{} = tracker, timeout, callback)
      when is_function(callback, 1) do
    case group_state(tracker, timeout) do
      {:active, _members} -> callback.(tracker.process_group_id)
      :retired -> :retired
      {:error, _reason} = error -> error
    end
  end

  @doc "Marks cleanup verified and stops a tracker that has not already retired."
  @spec stop_verified(t()) :: :ok
  def stop_verified(%__MODULE__{} = tracker) do
    :ok = :atomics.put(tracker.status, 1, @verified_gone)
    stop_tracker(tracker)
  end

  @doc "Stops tracking after an unverified startup failure without claiming cleanup."
  @spec stop_unverified(t()) :: :ok
  def stop_unverified(%__MODULE__{} = tracker) do
    :ok = :atomics.put(tracker.status, 1, @exhausted)
    stop_tracker(tracker)
  end

  defp stop_tracker(tracker) do
    if Process.alive?(tracker.pid) do
      try do
        GenServer.stop(tracker.pid, :normal, @call_timeout_ms)
      catch
        :exit, _reason -> Process.exit(tracker.pid, :kill)
      end
    end

    :ok
  end

  @impl true
  def init(state) do
    schedule_poll(state.poll_interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:group_state, _from, state) do
    case refresh(state) do
      {:active, members, next_state} ->
        {:reply, {:active, members}, next_state}

      :retired ->
        retire(state)
        {:stop, :normal, :retired, state}

      {:error, :process_group_identity_discontinuity} = error ->
        {:reply, error, state}

      {:error, reason} ->
        handle_read_error(reason, state, :call)
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case refresh(state) do
      {:active, _members, next_state} ->
        schedule_poll(next_state.poll_interval_ms)
        {:noreply, next_state}

      :retired ->
        retire(state)
        {:stop, :normal, state}

      {:error, :process_group_identity_discontinuity} ->
        schedule_poll(state.poll_interval_ms)
        {:noreply, state}

      {:error, _reason} ->
        handle_read_error(:proc_read_failed, state, :poll)
    end
  end

  defp refresh(state) do
    case safe_read_group(state.proc_reader, state.process_group_id) do
      {:ok, members} -> classify_group_members(members, state)
      {:error, _reason} = error -> error
    end
  end

  defp classify_group_members(members, state) do
    same_session_members = Enum.filter(members, &same_session_member?(&1, state))

    cond do
      known_member_present?(same_session_members, state.known) ->
        known =
          Enum.reduce(same_session_members, state.known, fn identity, identities ->
            MapSet.put(identities, identity_key(identity))
          end)

        {:active, same_session_members, %{state | known: known, consecutive_read_errors: 0}}

      members == [] or reused_group_leader?(members, state) ->
        :retired

      true ->
        {:error, :process_group_identity_discontinuity}
    end
  end

  defp same_session_member?(identity, state) do
    valid_identity?(identity) and identity.process_group_id == state.process_group_id and
      identity.session_id == state.session_id
  end

  defp known_member_present?(members, known) do
    Enum.any?(members, &MapSet.member?(known, identity_key(&1)))
  end

  defp safe_read_group(proc_reader, process_group_id) do
    case proc_reader.(process_group_id) do
      {:ok, members} when is_list(members) -> {:ok, members}
      {:error, _reason} -> {:error, :proc_read_failed}
      _other -> {:error, :proc_read_failed}
    end
  rescue
    _exception -> {:error, :proc_read_failed}
  catch
    _kind, _reason -> {:error, :proc_read_failed}
  end

  defp call_tracker(tracker, request, timeout) do
    if Process.alive?(tracker.pid) do
      try do
        GenServer.call(tracker.pid, request, timeout)
      catch
        :exit, {:timeout, _details} -> {:error, :timeout}
        :exit, _reason -> tracker_exit_state(tracker)
      end
    else
      tracker_exit_state(tracker)
    end
  end

  defp tracker_exit_state(tracker) do
    case tracker_status(tracker) do
      :retired -> :retired
      :active -> {:error, :identity_tracker_unavailable}
      :exhausted -> {:error, :identity_tracking_exhausted}
    end
  end

  defp tracker_status(tracker) do
    case :atomics.get(tracker.status, 1) do
      @verified_gone -> :retired
      @exhausted -> :exhausted
      _other -> :active
    end
  end

  defp retire(state), do: :atomics.put(state.status, 1, @verified_gone)

  defp handle_read_error(reason, state, mode) do
    next_state = %{state | consecutive_read_errors: state.consecutive_read_errors + 1}

    if next_state.consecutive_read_errors >= @max_consecutive_read_errors do
      :ok = :atomics.put(state.status, 1, @exhausted)

      case mode do
        :call -> {:stop, :normal, {:error, :identity_tracking_exhausted}, next_state}
        :poll -> {:stop, :normal, next_state}
      end
    else
      case mode do
        :call ->
          {:reply, {:error, reason}, next_state}

        :poll ->
          schedule_poll(state.poll_interval_ms)
          {:noreply, next_state}
      end
    end
  end

  defp schedule_poll(interval_ms), do: Process.send_after(self(), :poll, interval_ms)

  defp poll_interval(opts) do
    case Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _other -> {:error, :invalid_poll_interval}
    end
  end

  defp anchor(opts, leader) do
    case Keyword.get(opts, :anchor) do
      nil ->
        {:ok, nil}

      anchor ->
        if valid_identity?(anchor) and anchor.process_group_id == leader.process_group_id and
             anchor.session_id == leader.session_id do
          {:ok, anchor}
        else
          {:error, :invalid_anchor_identity}
        end
    end
  end

  defp proc_reader(opts) do
    case Keyword.get(opts, :proc_reader, &read_process_group/1) do
      reader when is_function(reader, 1) -> {:ok, reader}
      _other -> {:error, :invalid_proc_reader}
    end
  end

  defp validate_identity(identity) do
    if valid_identity?(identity), do: :ok, else: {:error, :invalid_process_identity}
  end

  defp valid_identity?(%{} = identity) do
    positive_integer?(identity[:pid]) and is_binary(identity[:state]) and
      positive_integer?(identity[:process_group_id]) and
      positive_integer?(identity[:session_id]) and non_negative_integer?(identity[:start_time])
  end

  defp valid_identity?(_identity), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp identity_key(identity), do: {identity.pid, identity.start_time}

  defp initial_known_identities(leader, nil), do: MapSet.new([identity_key(leader)])

  defp initial_known_identities(leader, anchor) do
    MapSet.new([identity_key(leader), identity_key(anchor)])
  end

  defp reused_group_leader?(members, state) do
    Enum.any?(members, fn identity ->
      valid_identity?(identity) and identity.pid == state.process_group_id and
        not MapSet.member?(state.known, identity_key(identity))
    end)
  end

  defp read_process_group(process_group_id) do
    "/proc/[0-9]*/stat"
    |> Path.wildcard()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, members} ->
      case read_process_stat(path) do
        {:ok, %{process_group_id: ^process_group_id} = identity} ->
          {:cont, {:ok, [identity | members]}}

        {:ok, _other_group} ->
          {:cont, {:ok, members}}

        {:error, :enoent} ->
          {:cont, {:ok, members}}

        {:error, _reason} ->
          {:halt, {:error, :incomplete_proc_scan}}
      end
    end)
  end

  defp read_process_stat(path) do
    with {:ok, contents} <- File.read(path),
         [{closing_index, 2} | _rest] <-
           contents |> :binary.matches(") ") |> Enum.reverse(),
         {pid, ""} <-
           contents
           |> binary_part(0, opening_parenthesis_index(contents) - 1)
           |> Integer.parse(),
         trailing <- binary_part(contents, closing_index + 2, byte_size(contents) - closing_index - 2),
         fields when length(fields) > 19 <- :binary.split(trailing, " ", [:global]),
         state when is_binary(state) <- Enum.at(fields, 0),
         {process_group_id, ""} <- fields |> Enum.at(2) |> Integer.parse(),
         {session_id, ""} <- fields |> Enum.at(3) |> Integer.parse(),
         {start_time, ""} <- fields |> Enum.at(19) |> Integer.parse() do
      {:ok,
       %{
         pid: pid,
         state: state,
         process_group_id: process_group_id,
         session_id: session_id,
         start_time: start_time
       }}
    else
      {:error, reason} -> {:error, reason}
      _error -> {:error, :invalid_stat}
    end
  end

  defp parse_child_pids(contents) do
    contents
    |> String.split(~r/\s+/, trim: true)
    |> Enum.reduce_while([], fn value, pids ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 -> {:cont, [pid | pids]}
        _other -> {:halt, :invalid}
      end
    end)
    |> case do
      pids when is_list(pids) -> Enum.reverse(pids)
      :invalid -> :invalid
    end
  end

  defp parse_namespace_pids(status) do
    case Enum.find(String.split(status, "\n"), &String.starts_with?(&1, "NSpid:")) do
      nil -> {:error, :namespace_pid_unavailable}
      line -> parse_namespace_pid_line(line)
    end
  end

  defp parse_namespace_pid_line(line) do
    identifiers =
      line
      |> String.replace_prefix("NSpid:", "")
      |> String.split()

    case parse_positive_integers(identifiers) do
      :invalid -> {:error, :namespace_pid_unavailable}
      pids -> {:ok, pids}
    end
  end

  defp parse_positive_integers(identifiers) do
    Enum.reduce_while(identifiers, [], fn value, pids ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 -> {:cont, [pid | pids]}
        _other -> {:halt, :invalid}
      end
    end)
    |> case do
      :invalid -> :invalid
      pids -> Enum.reverse(pids)
    end
  end

  defp opening_parenthesis_index(contents) do
    case :binary.match(contents, " (") do
      {index, 2} -> index + 1
      :nomatch -> 0
    end
  end
end

defmodule SymphonyElixir.Codex.ProcessAdapter.CleanupEvidence do
  @moduledoc false

  @doc false
  @spec complete?(boolean(), term(), term()) :: boolean()
  def complete?(false, [], :retired), do: true
  def complete?(_manager_alive?, _group_members, _namespace_root), do: false
end

defmodule SymphonyElixir.Codex.ProcessAdapter do
  @moduledoc """
  Owns a directly-executed OS process through `erlexec` and a private PID
  namespace.

  The process is linked to the caller of `start/2`. Standard output and standard
  error are delivered to that caller as the unmodified `erlexec` messages
  `{:stdout, os_pid, data}` and `{:stderr, os_pid, data}`. Callers that need to
  observe non-zero exits instead of exiting with the linked process must trap
  exits.

  Trusted launch helpers start with an empty environment. The target receives
  only the explicit environment pairs supplied to `start/2`, after its exact
  namespace identity has been captured. Commands are always passed as an
  executable-and-arguments list and are never interpreted by a shell.
  """

  @default_kill_timeout_ms 2_000
  @default_start_timeout_ms 5_000
  @max_kill_timeout_ms 30_000
  @max_start_timeout_ms 30_000
  @max_env_pairs 4_096
  @max_env_name_bytes 1_024
  @max_env_value_bytes 131_069
  @max_env_entry_bytes 131_071
  @max_env_bytes 1_048_576
  @max_argv_entry_bytes 131_072
  @max_exec_payload_bytes 1_048_576
  @stop_request_timeout_ms 250
  @cleanup_poll_ms 20
  @containment_handshake_poll_ms 5
  @force_kill_reserve_ms 150
  @startup_rollback_extra_ms 1_500
  @clear_env_executables ["/usr/bin/env", "/bin/env"]
  @pidfd_signal_executables ["/usr/bin/python3", "/bin/python3"]
  @namespace_executables ["/usr/bin/unshare", "/bin/unshare"]
  @namespace_release_token "symphony-namespace-release-v1"
  @target_release_token "symphony-target-release-v1"
  @namespace_init_script """
  import ctypes
  import os
  import sys

  def read_exact(length):
      chunks = []
      remaining = length
      while remaining:
          try:
              chunk = os.read(0, remaining)
          except InterruptedError:
              continue
          if not chunk:
              raise EOFError("startup frame ended early")
          chunks.append(chunk)
          remaining -= len(chunk)
      return b"".join(chunks)

  def read_u32():
      return int.from_bytes(read_exact(4), "big")

  def read_u64():
      return int.from_bytes(read_exact(8), "big")

  def main():
      release_token = sys.argv[1].encode("ascii")
      target_release_token = sys.argv[2].encode("ascii")
      executable = sys.argv[3]
      target_argv = sys.argv[3:]
      try:
          received = read_exact(len(release_token))
          environment_count = read_u32()
          if environment_count > 4096:
              return 74
          target_environment = {}
          aggregate_environment_bytes = 0
          for _index in range(environment_count):
              name_length = read_u32()
              value_length = read_u64()
              entry_bytes = name_length + value_length + 2
              aggregate_environment_bytes += entry_bytes
              if (
                  name_length > 1024
                  or value_length > 131069
                  or entry_bytes > 131071
                  or aggregate_environment_bytes > 1048576
              ):
                  return 74
              name = read_exact(name_length)
              value = read_exact(value_length)
              target_environment[name] = value
      except (EOFError, OSError):
          return 71
      if received != release_token:
          return 72
      os.environb.clear()
      os.setsid()
      libc = ctypes.CDLL(None, use_errno=True)
      if libc.prctl(4, 0, 0, 0, 0) != 0:
          return 73
      target_pid = os.fork()
      if target_pid == 0:
          if libc.prctl(4, 1, 0, 0, 0) != 0:
              os._exit(76)
          try:
              received_target_release = read_exact(len(target_release_token))
          except (EOFError, OSError):
              os._exit(71)
          if received_target_release != target_release_token:
              os._exit(75)
          os.environb.update(target_environment)
          target_environment.clear()
          os.execve(executable, target_argv, os.environ)
      target_environment.clear()

      while True:
          try:
              _pid, status = os.waitpid(target_pid, 0)
              break
          except InterruptedError:
              continue

      if os.WIFEXITED(status):
          return os.WEXITSTATUS(status)
      if os.WIFSIGNALED(status):
          return 128 + os.WTERMSIG(status)
      return 70

  sys.exit(main())
  """
  @containment_launcher_script """
  import os
  import signal
  import sys
  import time

  def read_identity(pid):
      with open(f"/proc/{pid}/stat", "rb") as stat_file:
          stat = stat_file.read()
      closing_index = stat.rfind(b") ")
      if closing_index < 0:
          raise ValueError("invalid stat")
      fields = stat[closing_index + 2:].split()
      return {
          "pid": pid,
          "state": fields[0],
          "pgrp": int(fields[2]),
          "session": int(fields[3]),
          "start_time": int(fields[19]),
      }

  def group_members(process_group_id):
      members = []
      for entry in os.listdir("/proc"):
          if not entry.isdigit():
              continue
          try:
              identity = read_identity(int(entry))
          except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
              continue
          if identity["pgrp"] == process_group_id:
              members.append(identity)
      return members

  def same_identity(pid, start_time):
      try:
          return read_identity(pid)["start_time"] == start_time
      except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError, IndexError):
          return False

  def close_standard_streams():
      devnull = os.open("/dev/null", os.O_RDWR)
      for descriptor in (0, 1, 2):
          os.dup2(devnull, descriptor)
      if devnull > 2:
          os.close(devnull)

  def close_nonessential_descriptors(keep):
      for entry in os.listdir("/proc/self/fd"):
          if not entry.isdigit():
              continue
          descriptor = int(entry)
          if descriptor > 2 and descriptor not in keep:
              try:
                  os.close(descriptor)
              except OSError:
                  pass

  def anchor_main(leader_pid, leader_start_time, process_group_id, kill_timeout_seconds, ready_fd):
      requested = [0]
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      signal.signal(signal.SIGHUP, signal.SIG_IGN)
      signal.signal(signal.SIGINT, signal.SIG_IGN)
      signal.signal(signal.SIGQUIT, signal.SIG_IGN)
      signal.signal(
          signal.SIGUSR1,
          lambda _signal, _frame: requested.__setitem__(0, max(requested[0], 1)),
      )
      signal.signal(signal.SIGUSR2, lambda _signal, _frame: requested.__setitem__(0, 2))
      os.environ.clear()
      close_nonessential_descriptors({ready_fd})
      os.write(ready_fd, b"1")
      os.close(ready_fd)
      close_standard_streams()

      while requested[0] == 0 and same_identity(leader_pid, leader_start_time):
          time.sleep(0.02)

      if requested[0] < 2:
          try:
              os.killpg(process_group_id, signal.SIGTERM)
          except ProcessLookupError:
              return 0

      deadline = time.monotonic() + kill_timeout_seconds
      while True:
          others = [
              member
              for member in group_members(process_group_id)
              if member["pid"] != os.getpid()
          ]
          if not others:
              os.killpg(process_group_id, signal.SIGKILL)
          if requested[0] >= 2 or time.monotonic() >= deadline:
              os.killpg(process_group_id, signal.SIGKILL)
          time.sleep(0.02)

  def main():
      kill_timeout_seconds = max(int(sys.argv[1]), 0) / 1000.0
      namespace_executable = sys.argv[2]
      namespace_init_script = sys.argv[3]
      namespace_release_token = sys.argv[4]
      target_release_token = sys.argv[5]
      target_argv = sys.argv[6:]
      os.environ.clear()

      leader_pid = os.getpid()
      leader_start_time = read_identity(leader_pid)["start_time"]
      ready_read, ready_write = os.pipe()
      anchor_pid = os.fork()
      if anchor_pid == 0:
          os.close(ready_read)
          return anchor_main(
              leader_pid,
              leader_start_time,
              leader_pid,
              kill_timeout_seconds,
              ready_write,
          )

      os.close(ready_write)
      if os.read(ready_read, 1) != b"1":
          return 70
      os.close(ready_read)
      os.kill(leader_pid, signal.SIGSTOP)
      namespace_argv = [
          namespace_executable,
          "--user",
          "--map-current-user",
          "--pid",
          "--fork",
          "--kill-child=SIGKILL",
          "--mount-proc",
          "--",
          sys.executable,
          "-I",
          "-S",
          "-c",
          namespace_init_script,
          namespace_release_token,
          target_release_token,
      ] + target_argv
      os.execve(namespace_executable, namespace_argv, os.environ)

  sys.exit(main())
  """
  @pidfd_signal_script """
  import os
  import signal
  import sys
  import time

  def identity(pid):
      with open(f"/proc/{pid}/stat", "rb") as stat_file:
          stat = stat_file.read()
      closing_index = stat.rfind(b") ")
      if closing_index < 0:
          raise ValueError("invalid stat")
      fields = stat[closing_index + 2:].split()
      return (fields[0], int(fields[19]), int(fields[2]), int(fields[3]))

  def expected_identity(pid, start_time, process_group, session):
      state, actual_start_time, actual_process_group, actual_session = identity(pid)
      return (
          state,
          (actual_start_time, actual_process_group, actual_session)
          == (start_time, process_group, session),
      )

  def open_verified_pidfd(pid, start_time, process_group, session):
      pidfd = os.pidfd_open(pid, 0)
      _state, matches = expected_identity(pid, start_time, process_group, session)
      if not matches:
          os.close(pidfd)
          return None
      return pidfd

  def open_exact_pidfd(pid, start_time):
      pidfd = os.pidfd_open(pid, 0)
      _state, actual_start_time, _process_group, _session = identity(pid)
      if actual_start_time != start_time:
          os.close(pidfd)
          return None
      return pidfd

  def signal_reserved_group(signal_number, identity_fields):
      if len(identity_fields) != 4:
          return 6
      pid, start_time, process_group, session_id = map(int, identity_fields)
      pidfd = None
      stopped = False
      try:
          pidfd = open_verified_pidfd(pid, start_time, process_group, session_id)
          if pidfd is None:
              return 8
          signal.pidfd_send_signal(pidfd, signal.SIGSTOP, None, 0)
          for _attempt in range(100):
              state, matches = expected_identity(pid, start_time, process_group, session_id)
              if not matches:
                  return 8
              if state in (b"T", b"t"):
                  stopped = True
                  break
              time.sleep(0.001)
          if not stopped:
              return 8
          os.killpg(process_group, signal_number)
          if signal_number == signal.SIGKILL:
              stopped = False
          return 0
      except (FileNotFoundError, ProcessLookupError):
          return 8
      except (OSError, ValueError):
          return 4
      finally:
          if stopped and pidfd is not None:
              try:
                  signal.pidfd_send_signal(pidfd, signal.SIGCONT, None, 0)
              except (OSError, ProcessLookupError):
                  pass
          if pidfd is not None:
              os.close(pidfd)

  def signal_members(signal_number, identity_fields):
      if len(identity_fields) % 4:
          return 6
      failed = False
      for index in range(0, len(identity_fields), 4):
          pid = int(identity_fields[index])
          expected_start_time = int(identity_fields[index + 1])
          expected_process_group = int(identity_fields[index + 2])
          expected_session = int(identity_fields[index + 3])
          try:
              pidfd = open_verified_pidfd(
                  pid,
                  expected_start_time,
                  expected_process_group,
                  expected_session,
              )
          except ProcessLookupError:
              continue
          except (OSError, ValueError):
              failed = True
              continue
          if pidfd is None:
              continue
          try:
              signal.pidfd_send_signal(pidfd, signal_number, None, 0)
          except ProcessLookupError:
              pass
          except (OSError, ValueError):
              failed = True
          finally:
              os.close(pidfd)
      return 4 if failed else 0

  def signal_exact(signal_number, identity_fields):
      if len(identity_fields) != 4:
          return 6
      pid = int(identity_fields[0])
      expected_start_time = int(identity_fields[1])
      try:
          pidfd = open_exact_pidfd(pid, expected_start_time)
      except ProcessLookupError:
          return 0
      except (OSError, ValueError):
          return 4
      if pidfd is None:
          return 8
      try:
          signal.pidfd_send_signal(pidfd, signal_number, None, 0)
          return 0
      except ProcessLookupError:
          return 0
      except (OSError, ValueError):
          return 4
      finally:
          os.close(pidfd)

  def main():
      if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
          return 5
      if any(name != "LC_CTYPE" for name in os.environ):
          return 7
      mode = sys.argv[1]
      signal_number = int(sys.argv[2])
      identity_fields = sys.argv[3:]
      if mode == "group":
          return signal_reserved_group(signal_number, identity_fields)
      if mode == "members":
          return signal_members(signal_number, identity_fields)
      if mode == "exact":
          return signal_exact(signal_number, identity_fields)
      return 6

  sys.exit(main())
  """

  alias SymphonyElixir.Codex.ProcessAdapter.CleanupEvidence
  alias SymphonyElixir.Codex.ProcessAdapter.IdentityTracker

  @enforce_keys [
    :pid,
    :os_pid,
    :owner,
    :kill_timeout_ms,
    :started_at_ms,
    :identity_tracker,
    :namespace_root,
    :target_identity
  ]

  defstruct [
    :pid,
    :os_pid,
    :owner,
    :kill_timeout_ms,
    :started_at_ms,
    :identity_tracker,
    :namespace_root,
    :target_identity
  ]

  @typedoc "A child environment entry. Values are intentionally absent from metadata."
  @type env_pair :: {String.t(), String.t()}

  @typedoc "Options accepted by `start/2`."
  @type option ::
          {:cd, Path.t()}
          | {:env, [env_pair()]}
          | {:kill_timeout_ms, non_neg_integer()}
          | {:start_timeout_ms, pos_integer()}

  @opaque t :: %__MODULE__{
            pid: pid(),
            os_pid: pos_integer(),
            owner: pid(),
            kill_timeout_ms: non_neg_integer(),
            started_at_ms: integer(),
            identity_tracker: IdentityTracker.t(),
            namespace_root: IdentityTracker.namespace_identity(),
            target_identity: IdentityTracker.namespace_identity()
          }

  @typedoc "Non-secret process identity and lifecycle metadata."
  @type metadata :: %{
          pid: pid(),
          os_pid: pos_integer(),
          owner: pid(),
          process_group_id: pos_integer(),
          process_session_id: pos_integer(),
          process_start_time: non_neg_integer(),
          namespace_root_pid: pos_integer(),
          namespace_root_start_time: non_neg_integer(),
          target_pid: pos_integer(),
          target_start_time: non_neg_integer(),
          pid_namespace: String.t(),
          kill_timeout_ms: non_neg_integer(),
          started_at_ms: integer()
        }

  @doc """
  Starts `argv` without a shell and links the managed process to the caller.

  The first argument must be an absolute executable path. `:env` is an explicit
  allowlist of name/value pairs; all other inherited variables are removed.
  """
  @spec start([String.t()], [option()]) :: {:ok, t()} | {:error, term()}
  def start(argv, opts \\ []) do
    with {:ok, config} <- validate_start(argv, opts) do
      start_tracked_process(config)
    end
  end

  @doc "Sends binary data, or `:eof`, to the managed process's standard input."
  @spec send(t(), binary() | :eof) :: :ok | {:error, term()}
  def send(%__MODULE__{} = adapter, data) when is_binary(data) or data == :eof do
    safe_exec_call(fn -> :exec.send(adapter.pid, data) end)
  end

  @doc """
  Stops the complete containment unit and verifies cleanup.

  `timeout_ms` is the signaling and cleanup-wait budget. One final cleanup
  verification follows that budget and includes an identity-tracker call capped
  at 250 milliseconds.

  A stopped pre-exec launcher establishes an unlinked anchor in the child
  process group before a trusted PID namespace root and target are captured.
  Cleanup reaches the anchor and, independently, the exact namespace root
  through pidfds. Success is returned only after the linked Erlang process, the
  anchored outer group, and the namespace root have all disappeared.
  """
  @spec stop(t(), non_neg_integer()) :: :ok | {:error, term()}
  def stop(%__MODULE__{} = adapter, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline_ms = monotonic_ms() + timeout_ms
    manager_monitor = Process.monitor(adapter.pid)

    try do
      if cleaned_up?(adapter, deadline_ms) do
        complete_cleanup(adapter)
      else
        stop_request = request_stop(adapter, deadline_ms)
        grace_deadline_ms = grace_deadline(adapter, deadline_ms)

        case wait_for_cleanup(adapter, grace_deadline_ms, manager_monitor) do
          :ok ->
            complete_cleanup(adapter)

          {:error, :timeout} ->
            force_kill_and_wait(adapter, deadline_ms, stop_request, manager_monitor)
        end
      end
    after
      Process.demonitor(manager_monitor, [:flush])
    end
  end

  @doc "Returns non-secret identity and lifecycle metadata for the managed process."
  @spec metadata(t()) :: metadata()
  def metadata(%__MODULE__{} = adapter) do
    %{
      pid: adapter.pid,
      os_pid: adapter.os_pid,
      owner: adapter.owner,
      process_group_id: adapter.os_pid,
      process_session_id: adapter.identity_tracker.leader.session_id,
      process_start_time: adapter.identity_tracker.leader.start_time,
      namespace_root_pid: adapter.namespace_root.pid,
      namespace_root_start_time: adapter.namespace_root.start_time,
      target_pid: adapter.target_identity.pid,
      target_start_time: adapter.target_identity.start_time,
      pid_namespace: adapter.namespace_root.pid_namespace,
      kill_timeout_ms: adapter.kill_timeout_ms,
      started_at_ms: adapter.started_at_ms
    }
  end

  @doc "Returns whether the OS process represented by the adapter is still running."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{} = adapter) do
    case IdentityTracker.group_state(adapter.identity_tracker) do
      {:active, members} ->
        leader = adapter.identity_tracker.leader

        Enum.any?(members, fn identity ->
          identity.pid == leader.pid and identity.start_time == leader.start_time and
            identity.state != "Z"
        end)

      :retired ->
        false

      {:error, _reason} ->
        Process.alive?(adapter.pid)
    end
  end

  defp start_tracked_process(config) do
    case run_link(config) do
      {:ok, pid, os_pid} ->
        handshake_deadline_ms = monotonic_ms() + config.start_timeout_ms
        start_tracked_identity(pid, os_pid, config, handshake_deadline_ms)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_tracked_identity(pid, os_pid, config, deadline_ms) do
    case start_identity_tracker(os_pid, deadline_ms) do
      {:ok, identity_tracker} ->
        resume_tracked_identity(pid, os_pid, config, identity_tracker, deadline_ms)

      {:error, reason} ->
        rollback_start(pid, os_pid, config, reason)
    end
  end

  defp resume_tracked_identity(pid, os_pid, config, identity_tracker, deadline_ms) do
    case resume_tracked_process(pid, deadline_ms) do
      :ok ->
        start_namespace_process(pid, os_pid, config, identity_tracker, deadline_ms)

      {:error, reason} ->
        IdentityTracker.stop_unverified(identity_tracker)
        rollback_start(pid, os_pid, config, {:containment_resume_failed, reason})
    end
  end

  defp start_namespace_process(pid, os_pid, config, identity_tracker, deadline_ms) do
    case capture_namespace_root(identity_tracker, deadline_ms) do
      {:ok, namespace_root} ->
        case release_namespace_root(pid, namespace_root, config.env, deadline_ms) do
          :ok ->
            start_target_process(
              pid,
              os_pid,
              config,
              identity_tracker,
              namespace_root,
              deadline_ms
            )

          {:error, reason} ->
            IdentityTracker.stop_unverified(identity_tracker)

            rollback_start(
              pid,
              os_pid,
              config,
              {:namespace_release_failed, reason},
              namespace_root
            )
        end

      {:error, reason} ->
        IdentityTracker.stop_unverified(identity_tracker)
        rollback_start(pid, os_pid, config, reason)
    end
  end

  defp start_target_process(
         pid,
         os_pid,
         config,
         identity_tracker,
         namespace_root,
         deadline_ms
       ) do
    with {:ok, target_identity} <- capture_namespace_target(namespace_root, deadline_ms),
         :ok <- release_namespace_target(pid, namespace_root, target_identity, deadline_ms) do
      {:ok,
       build_adapter(
         pid,
         os_pid,
         config,
         identity_tracker,
         namespace_root,
         target_identity
       )}
    else
      {:error, reason} ->
        IdentityTracker.stop_unverified(identity_tracker)

        rollback_start(
          pid,
          os_pid,
          config,
          {:namespace_target_handshake_failed, reason},
          namespace_root
        )
    end
  end

  defp capture_namespace_target(namespace_root, deadline_ms) do
    case IdentityTracker.capture_namespace_target(namespace_root) do
      {:ok, target_identity} ->
        {:ok, target_identity}

      {:error, reason} ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(min(@containment_handshake_poll_ms, max(deadline_ms - monotonic_ms(), 1)))
          capture_namespace_target(namespace_root, deadline_ms)
        else
          {:error, {:target_capture_failed, reason}}
        end
    end
  end

  defp release_namespace_target(pid, namespace_root, target_identity, deadline_ms) do
    with {:active, _root} <- IdentityTracker.exact_identity_state(namespace_root),
         {:active, _target} <- IdentityTracker.exact_identity_state(target_identity) do
      case bounded_exec_send(pid, @target_release_token, deadline_ms) do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, {:target_release_rejected, reason}}
        {:error, :timeout} -> {:error, :target_release_timeout}
        {:error, reason} -> {:error, {:target_release_failed, reason}}
      end
    else
      :retired -> {:error, :target_or_namespace_root_retired}
      {:error, reason} -> {:error, {:target_release_identity_failed, reason}}
    end
  end

  defp capture_namespace_root(identity_tracker, deadline_ms) do
    case IdentityTracker.capture_namespace_init(
           identity_tracker.leader,
           identity_tracker.anchor
         ) do
      {:ok, namespace_root} ->
        {:ok, namespace_root}

      {:error, reason} ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(min(@containment_handshake_poll_ms, max(deadline_ms - monotonic_ms(), 1)))
          capture_namespace_root(identity_tracker, deadline_ms)
        else
          {:error, {:namespace_handshake_failed, reason}}
        end
    end
  end

  defp release_namespace_root(pid, namespace_root, env, deadline_ms) do
    case IdentityTracker.exact_identity_state(namespace_root) do
      {:active, _identity} ->
        send_namespace_release(pid, env, deadline_ms)

      :retired ->
        {:error, :namespace_root_retired}

      {:error, reason} ->
        {:error, {:namespace_root_identity_failed, reason}}
    end
  end

  defp send_namespace_release(pid, env, deadline_ms) do
    case bounded_exec_send(pid, namespace_release_payload(env), deadline_ms) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:release_rejected, reason}}
      {:error, :timeout} -> {:error, :release_timeout}
      {:error, reason} -> {:error, {:release_failed, reason}}
    end
  end

  defp bounded_exec_send(pid, payload, deadline_ms) do
    run_bounded(fn -> safe_exec_call(fn -> :exec.send(pid, payload) end) end, deadline_ms)
  end

  defp namespace_release_payload(env) do
    encoded_environment =
      Enum.map(env, fn {name, value} ->
        [
          <<byte_size(name)::unsigned-big-integer-size(32)>>,
          <<byte_size(value)::unsigned-big-integer-size(64)>>,
          name,
          value
        ]
      end)

    IO.iodata_to_binary([
      @namespace_release_token,
      <<length(env)::unsigned-big-integer-size(32)>>,
      encoded_environment
    ])
  end

  defp start_identity_tracker(os_pid, deadline_ms) do
    case capture_containment(os_pid) do
      {:ok, leader, anchor} ->
        start_captured_identity_tracker(leader, anchor)

      {:error, reason} ->
        if monotonic_ms() < deadline_ms do
          Process.sleep(min(@containment_handshake_poll_ms, max(deadline_ms - monotonic_ms(), 1)))

          start_identity_tracker(os_pid, deadline_ms)
        else
          {:error, {:containment_handshake_failed, reason}}
        end
    end
  end

  defp capture_containment(os_pid) do
    with {:ok, leader} <- IdentityTracker.capture_leader(os_pid),
         {:ok, anchor} <- IdentityTracker.capture_anchor(leader) do
      {:ok, leader, anchor}
    end
  end

  defp start_captured_identity_tracker(leader, anchor) do
    with {:ok, tracker} <- IdentityTracker.start(leader, anchor: anchor) do
      case IdentityTracker.group_state(tracker) do
        {:active, _members} ->
          {:ok, tracker}

        :retired ->
          IdentityTracker.stop_unverified(tracker)
          {:error, :containment_retired_before_resume}

        {:error, _reason} = error ->
          IdentityTracker.stop_unverified(tracker)
          error
      end
    end
  end

  defp resume_tracked_process(pid, deadline_ms) do
    case run_bounded(fn -> :exec.kill(pid, :sigcont) end, deadline_ms) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _reason}} -> {:error, :resume_rejected}
      {:error, :timeout} -> {:error, :resume_timeout}
      {:error, _reason} -> {:error, :resume_failed}
    end
  end

  defp rollback_start(pid, os_pid, config, reason, namespace_root \\ nil) do
    case rollback_untracked_start(pid, os_pid, config.kill_timeout_ms, namespace_root) do
      :ok ->
        {:error, {:process_identity_unavailable, reason}}

      {:error, rollback_reason} ->
        {:error, {:process_identity_unavailable, reason, rollback_reason}}
    end
  end

  defp build_adapter(
         pid,
         os_pid,
         config,
         identity_tracker,
         namespace_root,
         target_identity
       ) do
    %__MODULE__{
      pid: pid,
      os_pid: os_pid,
      owner: self(),
      kill_timeout_ms: config.kill_timeout_ms,
      started_at_ms: monotonic_ms(),
      identity_tracker: identity_tracker,
      namespace_root: namespace_root,
      target_identity: target_identity
    }
  end

  # Identity capture happens immediately after erlexec creates the group. If it
  # cannot be established, this startup transaction is never published as an
  # adapter. erlexec performs the bounded rollback while the returned manager
  # still owns that just-created OS process.
  defp rollback_untracked_start(pid, process_group_id, kill_timeout_ms, namespace_root) do
    deadline_ms = monotonic_ms() + kill_timeout_ms + @startup_rollback_extra_ms
    stop_deadline_ms = min(deadline_ms, monotonic_ms() + @stop_request_timeout_ms)
    stop_result = run_bounded(fn -> :exec.stop(pid) end, stop_deadline_ms)

    result =
      wait_for_startup_cleanup(
        pid,
        process_group_id,
        namespace_root,
        deadline_ms,
        stop_result
      )

    if not Process.alive?(pid) do
      Process.unlink(pid)
    end

    result
  end

  defp wait_for_startup_cleanup(
         pid,
         process_group_id,
         namespace_root,
         deadline_ms,
         stop_result
       ) do
    cond do
      not Process.alive?(pid) and IdentityTracker.untracked_group_empty?(process_group_id) and
          namespace_root_gone?(namespace_root) ->
        :ok

      monotonic_ms() >= deadline_ms ->
        {:error,
         {:startup_rollback_unverified,
          %{
            stop_request: safe_stop_category(stop_result),
            manager_alive: Process.alive?(pid),
            group_empty: IdentityTracker.untracked_group_empty?(process_group_id),
            namespace_root: namespace_root_diagnostic(namespace_root)
          }}}

      true ->
        Process.sleep(min(@cleanup_poll_ms, max(deadline_ms - monotonic_ms(), 1)))

        wait_for_startup_cleanup(
          pid,
          process_group_id,
          namespace_root,
          deadline_ms,
          stop_result
        )
    end
  end

  defp safe_stop_category({:ok, :ok}), do: :manager_still_alive
  defp safe_stop_category({:ok, {:error, _reason}}), do: :erlexec_error
  defp safe_stop_category({:error, :timeout}), do: :stop_timeout
  defp safe_stop_category({:error, _reason}), do: :stop_failed

  defp validate_start(argv, opts) do
    with :ok <- validate_argv(argv),
         {:ok, options} <- validate_options(opts),
         {:ok, env} <- validate_env(options[:env]),
         :ok <- validate_exec_payload(argv, env),
         :ok <- validate_cd(options[:cd]) do
      {:ok,
       %{
         argv: argv,
         cd: options[:cd],
         env: env,
         kill_timeout_ms: options[:kill_timeout_ms],
         start_timeout_ms: options[:start_timeout_ms]
       }}
    end
  end

  defp validate_argv([executable | arguments] = argv)
       when is_binary(executable) and is_list(arguments) do
    cond do
      Path.type(executable) != :absolute ->
        {:error, {:invalid_argv, :executable_must_be_absolute}}

      Enum.any?(argv, &(not is_binary(&1))) ->
        {:error, {:invalid_argv, :arguments_must_be_strings}}

      Enum.any?(argv, &contains_nul?/1) ->
        {:error, {:invalid_argv, :nul_byte}}

      Enum.any?(argv, &(byte_size(&1) + 1 > @max_argv_entry_bytes)) ->
        {:error, {:invalid_argv, :argument_too_large}}

      true ->
        :ok
    end
  end

  defp validate_argv(_argv), do: {:error, {:invalid_argv, :non_empty_list_required}}

  defp validate_options(opts) when is_list(opts) do
    defaults = [
      cd: nil,
      env: [],
      kill_timeout_ms: @default_kill_timeout_ms,
      start_timeout_ms: @default_start_timeout_ms
    ]

    with true <- Keyword.keyword?(opts),
         {:ok, options} <- Keyword.validate(opts, defaults),
         :ok <- validate_bounded_integer(options[:kill_timeout_ms], 0, @max_kill_timeout_ms),
         :ok <- validate_bounded_integer(options[:start_timeout_ms], 1, @max_start_timeout_ms) do
      {:ok, options}
    else
      false -> {:error, {:invalid_options, :keyword_list_required}}
      {:error, {:invalid_options, _reason}} = error -> error
      {:error, keys} -> {:error, {:invalid_options, {:unknown, keys}}}
    end
  end

  defp validate_options(_opts), do: {:error, {:invalid_options, :keyword_list_required}}

  defp validate_bounded_integer(value, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: :ok

  defp validate_bounded_integer(value, minimum, maximum),
    do: {:error, {:invalid_options, {:out_of_range, value, minimum, maximum}}}

  defp validate_env(env) when is_list(env) do
    with :ok <- validate_env_size(env),
         :ok <- validate_env_pairs(env),
         :ok <- validate_unique_env_names(env) do
      {:ok, env}
    end
  end

  defp validate_env(_env), do: {:error, {:invalid_env, :list_required}}

  defp validate_exec_payload(argv, env) do
    argv_bytes = Enum.reduce(argv, 0, &(byte_size(&1) + 1 + &2))

    env_bytes =
      Enum.reduce(env, 0, fn {name, value}, total ->
        total + byte_size(name) + byte_size(value) + 2
      end)

    if argv_bytes + env_bytes <= @max_exec_payload_bytes do
      :ok
    else
      {:error, {:invalid_process_payload, :too_large}}
    end
  end

  defp validate_env_size(env) do
    cond do
      length(env) > @max_env_pairs ->
        {:error, {:invalid_env, :too_many_pairs}}

      Enum.any?(env, &oversized_env_component?/1) ->
        {:error, {:invalid_env, :pair_too_large}}

      env_size(env) > @max_env_bytes ->
        {:error, {:invalid_env, :aggregate_too_large}}

      Enum.any?(env, &oversized_env_entry?/1) ->
        {:error, {:invalid_env, :pair_too_large}}

      true ->
        :ok
    end
  end

  defp oversized_env_component?({name, value}) when is_binary(name) and is_binary(value) do
    byte_size(name) > @max_env_name_bytes or byte_size(value) > @max_env_value_bytes
  end

  defp oversized_env_component?(_other), do: false

  defp oversized_env_entry?({name, value}) when is_binary(name) and is_binary(value) do
    byte_size(name) + byte_size(value) + 2 > @max_env_entry_bytes
  end

  defp oversized_env_entry?(_other), do: false

  defp env_size(env) do
    Enum.reduce(env, 0, fn
      {name, value}, total when is_binary(name) and is_binary(value) ->
        total + byte_size(name) + byte_size(value) + 2

      _other, total ->
        total
    end)
  end

  defp validate_env_pairs(env) do
    case Enum.find(env, fn
           {name, value} -> not valid_env_name?(name) or not valid_env_value?(value)
           _other -> true
         end) do
      nil -> :ok
      _invalid -> {:error, {:invalid_env, :invalid_pair}}
    end
  end

  defp validate_unique_env_names(env) do
    names = Enum.map(env, &elem(&1, 0))

    if length(names) == MapSet.size(MapSet.new(names)) do
      :ok
    else
      {:error, {:invalid_env, :duplicate_name}}
    end
  end

  defp valid_env_name?(name) when is_binary(name) do
    not contains_nul?(name) and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
  end

  defp valid_env_name?(_name), do: false

  defp valid_env_value?(value) when is_binary(value), do: not contains_nul?(value)
  defp valid_env_value?(_value), do: false

  defp validate_cd(nil), do: :ok

  defp validate_cd(cd) when is_binary(cd) do
    cond do
      contains_nul?(cd) -> {:error, {:invalid_cd, :nul_byte}}
      not File.dir?(cd) -> {:error, {:invalid_cd, :not_a_directory}}
      true -> :ok
    end
  end

  defp validate_cd(_cd), do: {:error, {:invalid_cd, :path_required}}

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch

  defp run_link(config) do
    deadline_ms = monotonic_ms() + config.start_timeout_ms

    case find_containment_executables() do
      {env_executable, python_executable, namespace_executable} ->
        run_containment_link(
          config,
          env_executable,
          python_executable,
          namespace_executable,
          deadline_ms
        )

      nil ->
        {:error, :containment_launcher_not_found}
    end
  end

  defp run_containment_link(
         config,
         env_executable,
         python_executable,
         namespace_executable,
         deadline_ms
       ) do
    case verify_namespace_support(env_executable, namespace_executable, deadline_ms) do
      :ok ->
        run_erlexec_link(
          containment_launcher_argv(config, python_executable, namespace_executable),
          containment_erlexec_options(config),
          deadline_ms
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp containment_launcher_argv(config, python_executable, namespace_executable) do
    [
      python_executable,
      "-I",
      "-S",
      "-c",
      @containment_launcher_script,
      Integer.to_string(config.kill_timeout_ms),
      namespace_executable,
      @namespace_init_script,
      @namespace_release_token,
      @target_release_token
    ] ++ config.argv
  end

  defp containment_erlexec_options(config) do
    [
      :stdin,
      :stdout,
      :stderr,
      {:env, [:clear]},
      {:group, 0},
      :kill_group,
      {:kill_timeout, milliseconds_to_seconds(config.kill_timeout_ms)}
    ]
    |> maybe_put_cd(config.cd)
  end

  defp run_erlexec_link(launcher_argv, erlexec_options, deadline_ms) do
    remaining_ms = max(deadline_ms - monotonic_ms(), 1)

    safe_exec_call(fn ->
      :exec.run_link(launcher_argv, erlexec_options, remaining_ms)
    end)
  end

  defp verify_namespace_support(env_executable, namespace_executable, deadline_ms) do
    arguments =
      [
        "-i",
        namespace_executable,
        "--user",
        "--map-current-user",
        "--pid",
        "--fork",
        "--kill-child=SIGKILL",
        "--mount-proc",
        "--",
        "/bin/true"
      ]

    case run_bounded(
           fn -> System.cmd(env_executable, arguments, cd: "/", stderr_to_stdout: true) end,
           deadline_ms
         ) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, _status}} -> {:error, :pid_namespace_unavailable}
      {:error, _reason} -> {:error, :pid_namespace_unavailable}
    end
  end

  defp maybe_put_cd(options, nil), do: options
  defp maybe_put_cd(options, cd), do: [{:cd, cd} | options]

  defp milliseconds_to_seconds(0), do: 0
  defp milliseconds_to_seconds(milliseconds), do: div(milliseconds + 999, 1_000)

  defp request_stop(adapter, deadline_ms) do
    request_deadline_ms = min(deadline_ms, monotonic_ms() + @stop_request_timeout_ms)
    request_anchor_cleanup(adapter, :term, request_deadline_ms)
  end

  defp force_kill_and_wait(adapter, deadline_ms, stop_request, manager_monitor) do
    namespace_kill_request = request_namespace_root_kill(adapter, deadline_ms)
    kill_request = request_anchor_cleanup(adapter, :kill, deadline_ms)

    case wait_for_cleanup(adapter, deadline_ms, manager_monitor) do
      :ok ->
        complete_cleanup(adapter)

      {:error, :timeout} ->
        complete_or_cleanup_timeout(
          adapter,
          stop_request,
          kill_request,
          namespace_kill_request
        )
    end
  end

  defp complete_or_cleanup_timeout(adapter, stop_request, kill_request, namespace_kill_request) do
    {leader_alive?, group_members} = original_group_diagnostic(adapter)
    namespace_root = namespace_root_diagnostic(adapter.namespace_root)
    manager_alive? = Process.alive?(adapter.pid)

    if CleanupEvidence.complete?(manager_alive?, group_members, namespace_root) do
      complete_cleanup(adapter)
    else
      cleanup_timeout(
        stop_request,
        kill_request,
        namespace_kill_request,
        manager_alive?,
        leader_alive?,
        group_members,
        namespace_root
      )
    end
  end

  defp cleanup_timeout(
         stop_request,
         kill_request,
         namespace_kill_request,
         manager_alive?,
         leader_alive?,
         group_members,
         namespace_root
       ) do
    {:error,
     {:cleanup_timeout,
      %{
        stop_request: stop_request,
        kill_request: kill_request,
        namespace_kill_request: namespace_kill_request,
        manager_alive: manager_alive?,
        leader_alive: leader_alive?,
        group_members: group_members,
        namespace_root: namespace_root
      }}}
  end

  defp request_namespace_root_kill(adapter, deadline_ms) do
    case IdentityTracker.exact_identity_state(adapter.namespace_root) do
      {:active, _identity} ->
        run_pidfd_signal_helper("exact", [adapter.namespace_root], 9, deadline_ms)

      :retired ->
        :ok

      {:error, reason} ->
        {:error, {:namespace_root_identity_failed, reason}}
    end
  end

  defp grace_deadline(adapter, deadline_ms) do
    now_ms = monotonic_ms()
    remaining_ms = max(deadline_ms - now_ms, 0)
    verification_reserve_ms = min(@force_kill_reserve_ms, remaining_ms)
    grace_ms = min(adapter.kill_timeout_ms, remaining_ms - verification_reserve_ms)
    now_ms + max(grace_ms, 0)
  end

  defp request_anchor_cleanup(adapter, mode, deadline_ms) do
    case original_group_state(adapter, deadline_ms) do
      {:active, members} ->
        case signal_current_anchor(adapter.identity_tracker, members, mode, deadline_ms) do
          {:error, :containment_anchor_unavailable} ->
            signal_verified_group_fallback(adapter.identity_tracker, members, mode, deadline_ms)

          result ->
            result
        end

      :retired ->
        :ok

      {:error, reason} ->
        {:error, {:identity_check_failed, reason}}
    end
  end

  defp signal_current_anchor(%IdentityTracker{anchor: nil}, _members, _mode, _deadline_ms) do
    {:error, :containment_anchor_unavailable}
  end

  defp signal_current_anchor(tracker, members, mode, deadline_ms) do
    anchor = tracker.anchor
    anchor_key = {anchor.pid, anchor.start_time}

    if Enum.any?(members, &({&1.pid, &1.start_time} == anchor_key and &1.state != "Z")) do
      run_identity_signal_batch([anchor], signal_number(mode), deadline_ms)
    else
      {:error, :containment_anchor_unavailable}
    end
  end

  defp signal_verified_group_fallback(tracker, members, mode, deadline_ms) do
    live_members = Enum.reject(members, &(&1.state == "Z"))
    leader_key = {tracker.leader.pid, tracker.leader.start_time}

    case Enum.find(live_members, &({&1.pid, &1.start_time} == leader_key)) do
      nil ->
        run_identity_signal_batch(live_members, fallback_signal_number(mode), deadline_ms)

      leader ->
        case run_reserved_group_signal(leader, fallback_signal_number(mode), deadline_ms) do
          :ok ->
            :ok

          {:error, _reason} ->
            run_identity_signal_batch(live_members, fallback_signal_number(mode), deadline_ms)
        end
    end
  end

  defp run_reserved_group_signal(identity, signal_number, deadline_ms) do
    run_pidfd_signal_helper("group", [identity], signal_number, deadline_ms)
  end

  defp run_identity_signal_batch(identities, signal_number, deadline_ms) do
    run_pidfd_signal_helper("members", identities, signal_number, deadline_ms)
  end

  defp run_pidfd_signal_helper(mode, identities, signal_number, deadline_ms) do
    with {env_executable, python_executable}
         when is_binary(env_executable) and is_binary(python_executable) <-
           find_pidfd_signal_executables(),
         arguments <-
           [
             "-i",
             python_executable,
             "-I",
             "-S",
             "-c",
             @pidfd_signal_script,
             mode,
             Integer.to_string(signal_number)
           ] ++
             Enum.flat_map(identities, fn identity ->
               [
                 Integer.to_string(identity.pid),
                 Integer.to_string(identity.start_time),
                 Integer.to_string(identity.process_group_id),
                 Integer.to_string(identity.session_id)
               ]
             end),
         {:ok, {_output, status}} <-
           run_bounded(
             fn -> System.cmd(env_executable, arguments, cd: "/", stderr_to_stdout: true) end,
             deadline_ms
           ) do
      case status do
        0 -> :ok
        5 -> {:error, :pidfd_signaling_unavailable}
        7 -> {:error, :pidfd_helper_environment_not_cleared}
        _other -> {:error, {:pidfd_signal_failed, status}}
      end
    else
      nil -> {:error, :pidfd_signal_executable_not_found}
      {:error, reason} -> {:error, {:pidfd_signal_failed, reason}}
    end
  end

  defp find_pidfd_signal_executables do
    with env_executable when is_binary(env_executable) <-
           Enum.find(@clear_env_executables, &File.regular?/1),
         python_executable when is_binary(python_executable) <-
           Enum.find(@pidfd_signal_executables, &File.regular?/1) do
      {env_executable, python_executable}
    else
      nil -> nil
    end
  end

  defp find_containment_executables do
    with {env_executable, python_executable} <- find_pidfd_signal_executables(),
         namespace_executable when is_binary(namespace_executable) <-
           Enum.find(@namespace_executables, &File.regular?/1) do
      {env_executable, python_executable, namespace_executable}
    else
      nil -> nil
    end
  end

  defp signal_number(:term), do: 10
  defp signal_number(:kill), do: 12
  defp fallback_signal_number(:term), do: 15
  defp fallback_signal_number(:kill), do: 9

  defp run_bounded(function, deadline_ms) do
    remaining_ms = max(deadline_ms - monotonic_ms(), 0)

    if remaining_ms == 0 do
      {:error, :timeout}
    else
      caller = self()
      reply_ref = make_ref()

      {worker, monitor_ref} =
        spawn_monitor(fn ->
          result = safe_call(function)
          Kernel.send(caller, {reply_ref, result})
        end)

      receive do
        {^reply_ref, result} ->
          Process.demonitor(monitor_ref, [:flush])
          result

        {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
          {:error, {:worker_exit, reason}}
      after
        remaining_ms ->
          Process.exit(worker, :kill)
          Process.demonitor(monitor_ref, [:flush])
          {:error, :timeout}
      end
    end
  end

  defp safe_call(function) do
    {:ok, function.()}
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_exec_call(function) do
    case safe_call(function) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp wait_for_cleanup(adapter, deadline_ms, manager_monitor) do
    manager_alive? = Process.alive?(adapter.pid)

    cond do
      cleaned_up?(adapter, deadline_ms, manager_alive?) ->
        :ok

      monotonic_ms() >= deadline_ms ->
        {:error, :timeout}

      manager_alive? ->
        remaining_ms = max(deadline_ms - monotonic_ms(), 0)

        receive do
          {:DOWN, ^manager_monitor, :process, _pid, _reason} ->
            wait_for_cleanup(adapter, deadline_ms, manager_monitor)
        after
          remaining_ms -> wait_for_cleanup(adapter, deadline_ms, manager_monitor)
        end

      true ->
        Process.sleep(min(@cleanup_poll_ms, max(deadline_ms - monotonic_ms(), 1)))
        wait_for_cleanup(adapter, deadline_ms, manager_monitor)
    end
  end

  defp cleaned_up?(adapter, deadline_ms) do
    cleaned_up?(adapter, deadline_ms, Process.alive?(adapter.pid))
  end

  defp cleaned_up?(_adapter, _deadline_ms, true), do: false

  defp cleaned_up?(adapter, deadline_ms, false) do
    original_group_gone?(adapter, deadline_ms) and
      namespace_root_gone?(adapter.namespace_root)
  end

  defp namespace_root_gone?(nil), do: true

  defp namespace_root_gone?(namespace_root) do
    case IdentityTracker.exact_identity_state(namespace_root) do
      :retired -> true
      {:active, _identity} -> false
      {:error, _reason} -> false
    end
  end

  defp namespace_root_diagnostic(nil), do: :not_captured

  defp namespace_root_diagnostic(namespace_root) do
    case IdentityTracker.exact_identity_state(namespace_root) do
      :retired ->
        :retired

      {:active, identity} ->
        Map.take(identity, [:pid, :state, :start_time])

      {:error, reason} ->
        {:identity_check_failed, reason}
    end
  end

  defp original_group_gone?(adapter, deadline_ms) do
    case original_group_state(adapter, deadline_ms) do
      :retired -> true
      {:active, _members} -> false
      {:error, _reason} -> false
    end
  end

  defp original_group_state(adapter, deadline_ms) do
    timeout_ms =
      deadline_ms
      |> Kernel.-(monotonic_ms())
      |> max(0)
      |> min(@stop_request_timeout_ms)

    IdentityTracker.group_state(adapter.identity_tracker, timeout_ms)
  end

  defp original_group_diagnostic(adapter) do
    case IdentityTracker.group_state(adapter.identity_tracker, @stop_request_timeout_ms) do
      {:active, members} ->
        leader_key = {adapter.identity_tracker.leader.pid, adapter.identity_tracker.leader.start_time}

        leader_alive? =
          Enum.any?(members, fn member ->
            {member.pid, member.start_time} == leader_key and member.state != "Z"
          end)

        {leader_alive?, Enum.map(members, &Map.take(&1, [:pid, :state, :start_time]))}

      :retired ->
        {false, []}

      {:error, _reason} ->
        {false, :unavailable}
    end
  end

  defp complete_cleanup(adapter) do
    IdentityTracker.stop_verified(adapter.identity_tracker)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
