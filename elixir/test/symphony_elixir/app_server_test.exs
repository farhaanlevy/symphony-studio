# Downstream modification notice (2026-07-16): Symphony Studio proves exact
# pinned wire behavior, operation correlation, and isolated event callbacks.
defmodule SymphonyElixir.AppServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.{DynamicTool, TransportError}

  test "App Server publishes each started connection exactly once" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-connection-lifecycle-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-CONNECTION-LIFECYCLE")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    fixture =
      FakeCodex.create!(
        test_root,
        FakeCodex.session_prelude(
          thread_id: "thread-connection-lifecycle",
          cwd: workspace
        )
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: fixture.command
    )

    test_pid = self()

    assert {:ok, session} =
             AppServer.start_session(workspace,
               on_connection_started: fn connection ->
                 send(test_pid, {:connection_started_once, connection})
               end
             )

    assert_receive {:connection_started_once, connection}, 1_000
    assert connection == session.connection
    refute_receive {:connection_started_once, _duplicate}, 100

    connection_ref = Process.monitor(connection)
    _stop_result = AppServer.stop_session(session)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, _reason}, 1_000
  end

  test "subagent terminal notifications cannot complete the root turn" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-child-terminal-#{System.unique_integer([:positive, :monotonic])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-CHILD-TERMINAL")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(test_root) end)

    fixture =
      FakeCodex.create!(
        test_root,
        FakeCodex.session_prelude(
          thread_id: "thread-root",
          turn_id: "turn-root",
          cwd: workspace
        ) ++
          [
            FakeCodex.turn_completed_notification("thread-child", "turn-child"),
            FakeCodex.turn_completed_notification("thread-root", "turn-root"),
            FakeCodex.exit(0)
          ]
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      codex_command: fixture.command
    )

    issue = %Issue{
      id: "issue-child-terminal",
      identifier: "MT-CHILD-TERMINAL",
      title: "Keep the root completion authoritative",
      description: "A child terminal is not the root terminal",
      state: "In Progress",
      url: "https://example.org/issues/MT-CHILD-TERMINAL",
      labels: ["runtime"]
    }

    parent = self()
    on_message = fn message -> send(parent, {:child_terminal_message, message}) end

    assert {:ok, _result} =
             AppServer.run(workspace, "Wait for the correlated root terminal", issue, on_message: on_message)

    assert_receive {:child_terminal_message, %{event: :turn_completed}}, 1_000
    refute_receive {:child_terminal_message, %{event: :turn_completed}}, 100
    assert :ok = FakeCodex.assert_complete!(fixture)
  end

  test "event callback failures are isolated without logging callback content" do
    canary = "PRIVATE-CALLBACK-FAILURE-CANARY"

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 AppServer.emit_message_for_test(
                   fn _message -> raise canary end,
                   :notification,
                   %{method_category: :turn},
                   %{}
                 )
      end)

    assert log =~ "failure_kind=exception"
    refute log =~ canary
  end

  test "stop_session preserves a typed cleanup failure when the connection is already dead" do
    connection = spawn(fn -> :ok end)
    connection_ref = Process.monitor(connection)
    assert_receive {:DOWN, ^connection_ref, :process, ^connection, :normal}, 1_000

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{cleanup_verified: false, reason: :connection_unavailable}
            }} = AppServer.stop_session(%{connection: connection})

    operation = %{
      classification: :conservative,
      method: "item/tool/call",
      request_hash: String.duplicate("b", 64),
      send_state: :sent
    }

    uncertainty =
      TransportError.new(:uncertain_external_outcome, %{
        cause: %{kind: :request_timeout, message: "bounded timeout"},
        operation: operation,
        reconciliation_required: true
      })

    assert {:error,
            %TransportError{
              kind: :process_cleanup_failed,
              details: %{
                cause: %{kind: :uncertain_external_outcome},
                operation: ^operation
              }
            }} = AppServer.stop_session(%{connection: connection}, {:error, uncertainty})
  end

  test "app server rejects the workspace root and paths outside workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-guard",
        identifier: "MT-999",
        title: "Validate workspace guard",
        description: "Ensure app-server refuses invalid cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-999",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
               AppServer.run(workspace_root, "guard", issue)

      assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
               AppServer.run(outside_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects symlink escape cwd paths under the workspace root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-symlink-cwd-guard-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_workspace = Path.join(test_root, "outside")
      symlink_workspace = Path.join(workspace_root, "MT-1000")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_workspace)
      File.ln_s!(outside_workspace, symlink_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root
      )

      issue = %Issue{
        id: "issue-workspace-symlink-guard",
        identifier: "MT-1000",
        title: "Validate symlink workspace guard",
        description: "Ensure app-server refuses symlink escape cwd targets",
        state: "In Progress",
        url: "https://example.org/issues/MT-1000",
        labels: ["backend"]
      }

      assert {:error, {:invalid_workspace_cwd, :symlink_escape, ^symlink_workspace, _root}} =
               AppServer.run(symlink_workspace, "guard", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "remote sessions are release-gated before workspace validation" do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: "/remote/workspaces",
      codex_turn_sandbox_policy: %{"type" => "readOnly"}
    )

    assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} =
             AppServer.start_session("~", worker_host: "worker.invalid")

    assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} =
             AppServer.start_session("/remote/workspaces/../escape",
               worker_host: "worker.invalid"
             )
  end

  test "configured remote workers gate direct local sessions before process launch" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-configured-remote-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-REMOTE-CONFIG")
      launch_marker = Path.join(test_root, "local-process-launched")
      File.mkdir_p!(workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        worker_ssh_hosts: ["worker-01:2200"],
        codex_command: "\"/usr/bin/touch\" \"#{launch_marker}\""
      )

      assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} =
               AppServer.start_session(workspace)

      refute File.exists?(launch_marker)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server child environment excludes tracker and ambient API credentials" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-env-#{System.unique_integer([:positive])}"
      )

    tracked_environment = ["CODEX_API_KEY", "CODEX_HOME", "LINEAR_API_KEY", "OPENAI_API_KEY"]
    previous_environment = Map.new(tracked_environment, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous_environment, fn {name, value} -> restore_env(name, value) end)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-ENV")
      codex_binary = Path.join(test_root, "fake-codex")
      env_trace = Path.join(test_root, "child.env")
      File.mkdir_p!(workspace)

      System.put_env("CODEX_API_KEY", "must-not-reach-app-server")
      System.put_env("CODEX_HOME", Path.join(test_root, "codex-home"))
      System.put_env("LINEAR_API_KEY", "linear-secret-must-not-reach-app-server")
      System.put_env("OPENAI_API_KEY", "openai-secret-must-not-reach-app-server")

      File.write!(codex_binary, """
      #!/bin/sh
      /usr/bin/env > #{env_trace}
      count=0

      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-env"}}}'
            ;;
          4)
            printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-env"}}}'
            printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thread-env","turn":{"id":"turn-env"}}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-env",
        identifier: "MT-ENV",
        title: "Verify child environment",
        description: "Do not leak tracker or ambient API credentials",
        state: "In Progress",
        url: "https://example.org/issues/MT-ENV",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Check child environment", issue)

      environment = env_trace |> File.read!() |> String.split("\n", trim: true)
      assert "CODEX_HOME=#{Path.join(test_root, "codex-home")}" in environment
      refute Enum.any?(environment, &String.starts_with?(&1, "CODEX_API_KEY="))
      refute Enum.any?(environment, &String.starts_with?(&1, "LINEAR_API_KEY="))
      refute Enum.any?(environment, &String.starts_with?(&1, "OPENAI_API_KEY="))
      refute Enum.any?(environment, &String.contains?(&1, "must-not-reach-app-server"))
    after
      File.rm_rf(test_root)
    end
  end

  test "local launch passes quoted substitution and glob syntax as literal argv" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-direct-argv-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DIRECT-ARGV")
      wrapper = Path.join(test_root, "direct-codex-wrapper")
      argv_trace = Path.join(test_root, "argv.trace")
      substitution_target = Path.join(test_root, "substitution-ran")
      backtick_target = Path.join(test_root, "backtick-ran")
      glob_match = Path.join(workspace, "match.literal-glob")
      File.mkdir_p!(workspace)
      File.write!(glob_match, "must not be expanded")

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-direct-argv",
            turn_id: "turn-direct-argv",
            cwd: workspace
          ) ++
            [
              FakeCodex.turn_completed_notification("thread-direct-argv", "turn-direct-argv"),
              FakeCodex.exit(0)
            ]
        )

      File.write!(wrapper, """
      #!/bin/sh
      : > #{argv_trace}
      for arg in "$@"; do
        printf '%s\n' "$arg" >> #{argv_trace}
      done
      exec #{fixture.command}
      """)

      File.chmod!(wrapper, 0o755)

      command =
        "#{wrapper} 'two words' '$(touch #{substitution_target})' " <>
          "'`touch #{backtick_target}`' '*.literal-glob' '$HOME'"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: command
      )

      issue = %Issue{
        id: "issue-direct-argv",
        identifier: "MT-DIRECT-ARGV",
        title: "Launch Codex without a shell",
        description: "Keep legacy command arguments literal",
        state: "In Progress",
        url: "https://example.org/issues/MT-DIRECT-ARGV",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Verify direct argv", issue)
      assert :ok = FakeCodex.assert_complete!(fixture)

      assert File.read!(argv_trace) |> String.split("\n", trim: true) == [
               "two words",
               "$(touch #{substitution_target})",
               "`touch #{backtick_target}`",
               "*.literal-glob",
               "$HOME"
             ]

      refute File.exists?(substitution_target)
      refute File.exists?(backtick_target)
      assert File.exists?(glob_match)
    after
      File.rm_rf(test_root)
    end
  end

  test "local launch needs no bash and accepts an executable path containing spaces" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony app server direct launch #{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    on_exit(fn -> restore_env("PATH", previous_path) end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-DIRECT-PATH")
      executable = Path.join(test_root, "codex fixture with spaces")
      path_without_bash = Path.join(test_root, "empty-path")
      File.mkdir_p!(workspace)
      File.mkdir_p!(path_without_bash)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-direct-path",
            turn_id: "turn-direct-path",
            cwd: workspace
          ) ++
            [
              FakeCodex.turn_completed_notification("thread-direct-path", "turn-direct-path"),
              FakeCodex.exit(0)
            ]
        )

      File.write!(executable, "#!/bin/sh\nexec #{fixture.command}\n")
      File.chmod!(executable, 0o755)
      System.put_env("PATH", path_without_bash)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "\"#{executable}\""
      )

      issue = %Issue{
        id: "issue-direct-path",
        identifier: "MT-DIRECT-PATH",
        title: "Prove shell-free production launch",
        description: "The configured executable path contains spaces and PATH has no Bash",
        state: "In Progress",
        url: "https://example.org/issues/MT-DIRECT-PATH",
        labels: ["security"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Verify absolute argv launch", issue)
      assert :ok = FakeCodex.assert_complete!(fixture)
      refute File.exists?(Path.join(path_without_bash, "bash"))
    after
      File.rm_rf(test_root)
    end
  end

  test "local launch rejects blank malformed and missing command executables" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-invalid-command-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INVALID-COMMAND")
      File.mkdir_p!(workspace)

      for {command, expected_error} <- [
            {"   ", {:invalid_codex_command, :blank}},
            {"codex 'unterminated", {:invalid_codex_command, :malformed}},
            {"missing-codex-executable app-server", {:invalid_codex_command, :executable_not_found}}
          ] do
        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: command
        )

        assert {:error, ^expected_error} = AppServer.start_session(workspace)
      end
    after
      File.rm_rf(test_root)
    end
  end

  test "initialize thread start and turn start use their configured method deadlines" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-method-timeouts-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-METHOD-TIMEOUTS")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset),
          FakeCodex.response(1, FakeCodex.initialize_response(), delay_ms: 25),
          FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
          FakeCodex.expect(%{"id" => 2, "method" => "thread/start"}, match: :subset),
          FakeCodex.response(
            2,
            FakeCodex.thread_start_response("thread-method-timeouts", cwd: workspace),
            delay_ms: 25
          ),
          FakeCodex.expect(
            %{
              "id" => 3,
              "method" => "turn/start",
              "params" => %{"threadId" => "thread-method-timeouts"}
            },
            match: :subset
          ),
          FakeCodex.response(3, FakeCodex.turn_start_response("turn-method-timeouts"), delay_ms: 25),
          FakeCodex.turn_completed_notification("thread-method-timeouts", "turn-method-timeouts"),
          FakeCodex.exit(0)
        ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_read_timeout_ms: 1,
        codex_initialize_timeout_ms: 5_000,
        codex_thread_start_timeout_ms: 5_000,
        codex_turn_start_timeout_ms: 5_000,
        codex_turn_timeout_ms: 1_000
      )

      issue = %Issue{
        id: "issue-method-timeouts",
        identifier: "MT-METHOD-TIMEOUTS",
        title: "Use method-specific App Server deadlines",
        description: "Do not apply ordinary read timeout to startup methods",
        state: "In Progress",
        url: "https://example.org/issues/MT-METHOD-TIMEOUTS",
        labels: ["transport"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Verify startup deadlines", issue)
      assert :ok = FakeCodex.assert_complete!(fixture)
    after
      File.rm_rf(test_root)
    end
  end

  test "acknowledged malformed thread result is a prompt-free uncertain outcome" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-invalid-thread-result-#{System.unique_integer([:positive])}"
      )

    canary = "thread-result-secret-#{System.unique_integer([:positive])}"

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INVALID-THREAD-RESULT")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset),
          FakeCodex.response(1, FakeCodex.initialize_response()),
          FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
          FakeCodex.expect(%{"id" => 2, "method" => "thread/start"}, match: :subset),
          FakeCodex.raw_send_json(%{
            "id" => 2,
            "result" => %{"thread" => %{"invalid" => canary}}
          }),
          FakeCodex.sleep(5_000),
          FakeCodex.exit(0)
        ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:invalid_thread_result, AppServer.start_session(workspace)})
        end)

      assert_received {:invalid_thread_result,
                       {:error,
                        %TransportError{
                          kind: :uncertain_external_outcome,
                          details: %{
                            reconciliation_required: true,
                            operation: %{method: "thread/start", send_state: :sent}
                          }
                        } = error}}

      refute inspect(error) =~ canary
      refute log =~ canary
    after
      File.rm_rf(test_root)
    end
  end

  test "acknowledged malformed turn result blocks without replaying prompt content" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-invalid-turn-result-#{System.unique_integer([:positive])}"
      )

    result_canary = "turn-result-secret-#{System.unique_integer([:positive])}"
    prompt_canary = "turn-prompt-secret-#{System.unique_integer([:positive])}"

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-INVALID-TURN-RESULT")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(test_root, [
          FakeCodex.expect(%{"id" => 1, "method" => "initialize"}, match: :subset),
          FakeCodex.response(1, FakeCodex.initialize_response()),
          FakeCodex.expect(%{"method" => "initialized"}, absent: [["id"], ["params"]]),
          FakeCodex.expect(%{"id" => 2, "method" => "thread/start"}, match: :subset),
          FakeCodex.response(
            2,
            FakeCodex.thread_start_response("thread-invalid-turn", cwd: workspace)
          ),
          FakeCodex.expect(%{"id" => 3, "method" => "turn/start"}, match: :subset),
          FakeCodex.raw_send_json(%{
            "id" => 3,
            "result" => %{"turn" => %{"invalid" => result_canary}}
          }),
          FakeCodex.sleep(5_000),
          FakeCodex.exit(0)
        ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command
      )

      issue = %Issue{
        id: "issue-invalid-turn-result",
        identifier: "MT-INVALID-TURN-RESULT",
        title: "Reject malformed acknowledged turn result",
        description: prompt_canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-INVALID-TURN-RESULT",
        labels: ["security"]
      }

      on_message = fn message -> send(self(), {:invalid_turn_message, message}) end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:invalid_turn_result, AppServer.run(workspace, prompt_canary, issue, on_message: on_message)}
          )
        end)

      assert_received {:invalid_turn_result,
                       {:error,
                        %TransportError{
                          kind: :uncertain_external_outcome,
                          details: %{
                            reconciliation_required: true,
                            operation: %{method: "turn/start", send_state: :sent}
                          }
                        } = error}}

      assert_received {:invalid_turn_message,
                       %{
                         event: :uncertain_external_outcome,
                         reason: %{
                           kind: :uncertain_external_outcome,
                           details: %{operation: %{method: "turn/start"}}
                         }
                       }}

      assert_received {:invalid_turn_message,
                       %{
                         event: :startup_failed,
                         reason: %{
                           kind: :uncertain_external_outcome,
                           details: %{
                             cause: %{kind: :invalid_side_effect_response}
                           }
                         }
                       }}

      refute inspect(error) =~ result_canary
      refute inspect(error) =~ prompt_canary
      refute log =~ result_canary
      refute log =~ prompt_canary
    after
      File.rm_rf(test_root)
    end
  end

  test "app server forwards only normalized pinned turn sandbox policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-turn-policies-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-1001")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-turn-policies.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-turn-policies.trace}"
      count=0

      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' "$line" >> "$trace_file"

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-1001"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-1001"}}}'
            sleep 0.1
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-1001","turn":{"id":"turn-1001"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      issue = %Issue{
        id: "issue-supported-turn-policies",
        identifier: "MT-1001",
        title: "Validate explicit turn sandbox policy normalization",
        description: "Ensure runtime startup forwards only normalized pinned turn sandbox policies",
        state: "In Progress",
        url: "https://example.org/issues/MT-1001",
        labels: ["backend"]
      }

      policy_cases = [
        {%{"type" => "dangerFullAccess"}, %{"type" => "dangerFullAccess"}},
        {%{"type" => "readOnly", "networkAccess" => true}, %{"type" => "readOnly", "networkAccess" => true}},
        {%{"type" => "externalSandbox", "networkAccess" => "enabled"}, %{"type" => "externalSandbox", "networkAccess" => "enabled"}},
        {%{
           "type" => "workspaceWrite",
           "writableRoots" => [workspace <> "/cache/../cache"],
           "networkAccess" => true
         },
         %{
           "type" => "workspaceWrite",
           "writableRoots" => [Path.join(workspace, "cache")],
           "networkAccess" => true
         }}
      ]

      Enum.each(policy_cases, fn {configured_policy, expected_policy} ->
        File.rm(trace_file)

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: "#{codex_binary} app-server",
          codex_turn_sandbox_policy: configured_policy
        )

        assert {:ok, _result} = AppServer.run(workspace, "Validate supported turn policy", issue)

        trace = File.read!(trace_file)
        lines = String.split(trace, "\n", trim: true)

        assert Enum.any?(lines, fn line ->
                 if String.starts_with?(line, "JSON:") do
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()
                   |> then(fn payload ->
                     payload["method"] == "turn/start" &&
                       get_in(payload, ["params", "sandboxPolicy"]) == expected_policy
                   end)
                 else
                   false
                 end
               end)
      end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server marks request-for-input events as a hard failure" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-input-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-88")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-input.trace")
      canary = "PRIVATE-INPUT-CANARY"
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-input.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-88\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-88\"}}}'
            printf '%s\\n' '{\"method\":\"turn/input_required\",\"id\":\"#{canary}\",\"params\":{\"requiresInput\":true,\"reason\":\"#{canary}\"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-input",
        identifier: "MT-88",
        title: "Input needed",
        description: canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-88",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:input_required_message, message}) end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:input_required_result, AppServer.run(workspace, "Needs input #{canary}", issue, on_message: on_message)}
          )
        end)

      assert_received {:input_required_result, {:error, {:turn_input_required, payload}}}
      assert payload == %{request_id_type: :string, request_kind: :turn_request}
      refute inspect(payload) =~ canary
      refute log =~ canary

      assert_received {:input_required_message,
                       event = %{
                         event: :turn_input_required,
                         request_id_type: :string,
                         request_kind: :turn_request
                       }}

      refute inspect(event) =~ canary
    after
      File.rm_rf(test_root)
    end
  end

  test "app server treats MCP elicitation requests as hard input blockers" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-mcp-elicitation-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-188")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-188"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-188"}}}'
            printf '%s\\n' '{"method":"mcpServer/elicitation/request","params":{"message":"Need operator input"}}'
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-mcp-elicitation",
        identifier: "MT-188",
        title: "MCP elicitation",
        description: "Cannot satisfy MCP input",
        state: "In Progress",
        url: "https://example.org/issues/MT-188",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Needs MCP input", issue)

      assert payload == %{request_id_type: :absent, request_kind: :mcp_elicitation}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server fails when command execution approval is required under safer defaults" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-approval-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      canary = "PRIVATE-APPROVAL-CANARY"
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-89"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-89"}}}'
            printf '%s\\n' '{"id":"#{canary}","method":"item/commandExecution/requestApproval","params":{"command":"#{canary}","cwd":"/tmp","reason":"#{canary}"}}'
            ;;
          *)
            sleep 1
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-approval-required",
        identifier: "MT-89",
        title: "Approval required",
        description: canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:approval_required_message, message}) end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:approval_required_result, AppServer.run(workspace, "Handle approval request #{canary}", issue, on_message: on_message)}
          )
        end)

      assert_received {:approval_required_result, {:error, {:approval_required, payload}}}
      assert payload == %{request_id_type: :string, request_kind: :other_request}
      refute inspect(payload) =~ canary
      refute log =~ canary

      assert_received {:approval_required_message,
                       event = %{
                         event: :approval_required,
                         request_id_type: :string,
                         request_kind: :other_request
                       }}

      refute inspect(event) =~ canary
    after
      File.rm_rf(test_root)
    end
  end

  test "arbitrary notification content is reduced before logs and live events" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-notification-redaction-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-NOTIFICATION-REDACTION")
      canary = "PRIVATE-NOTIFICATION-CANARY"
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-notification-redaction",
            turn_id: "turn-notification-redaction",
            cwd: workspace
          ) ++
            [
              FakeCodex.raw_send_json(%{
                "method" => "private/#{canary}",
                "params" => %{"private" => canary}
              }),
              FakeCodex.turn_completed_notification(
                "thread-notification-redaction",
                "turn-notification-redaction"
              ),
              FakeCodex.exit(0)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command
      )

      issue = %Issue{
        id: "issue-notification-redaction",
        identifier: "MT-NOTIFICATION-REDACTION",
        title: "Reduce arbitrary notification content",
        description: canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-NOTIFICATION-REDACTION",
        labels: ["security"]
      }

      on_message = fn message -> send(self(), {:notification_redaction_message, message}) end

      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          send(
            self(),
            {:notification_redaction_result, AppServer.run(workspace, "Handle #{canary}", issue, on_message: on_message)}
          )
        end)

      assert_received {:notification_redaction_result, {:ok, _result}}

      assert_received {:notification_redaction_message, event = %{event: :notification, method_category: :other}}

      refute inspect(event) =~ canary
      refute log =~ canary
    after
      File.rm_rf(test_root)
    end
  end

  test "failed and cancelled terminal payloads are reduced before logs and live events" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    for {method, event, result_kind} <- [
          {"turn/failed", :turn_failed, :turn_failed},
          {"turn/cancelled", :turn_cancelled, :turn_cancelled}
        ] do
      test_root =
        Path.join(
          System.tmp_dir!(),
          "symphony-terminal-redaction-#{event}-#{System.unique_integer([:positive])}"
        )

      try do
        workspace_root = Path.join(test_root, "workspaces")
        workspace = Path.join(workspace_root, "MT-TERMINAL-#{event}")
        thread_id = "thread-terminal-#{event}"
        turn_id = "turn-terminal-#{event}"
        canary = "PRIVATE-TERMINAL-CANARY-#{event}"
        File.mkdir_p!(workspace)

        fixture =
          FakeCodex.create!(
            test_root,
            FakeCodex.session_prelude(
              thread_id: thread_id,
              turn_id: turn_id,
              cwd: workspace
            ) ++
              [
                FakeCodex.raw_send_json(%{
                  "method" => method,
                  "params" => %{
                    "error" => %{"message" => canary},
                    "private" => canary,
                    "threadId" => thread_id,
                    "turn" => %{"id" => turn_id}
                  }
                }),
                FakeCodex.exit(0)
              ]
          )

        write_workflow_file!(Workflow.workflow_file_path(),
          workspace_root: workspace_root,
          codex_command: fixture.command
        )

        issue = %Issue{
          id: "issue-terminal-#{event}",
          identifier: "MT-TERMINAL-#{event}",
          title: "Reduce terminal content",
          description: canary,
          state: "In Progress",
          url: "https://example.org/issues/MT-TERMINAL-#{event}",
          labels: ["security"]
        }

        on_message = fn message -> send(self(), {:terminal_redaction_message, event, message}) end

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            result = AppServer.run(workspace, "Handle #{canary}", issue, on_message: on_message)
            send(self(), {:terminal_redaction_result, event, result})
          end)

        assert_received {:terminal_redaction_result, ^event, {:error, {^result_kind, %{terminal: true}}}}

        assert_received {:terminal_redaction_message, ^event, terminal_event = %{event: ^event, terminal: ^event}}

        refute inspect(terminal_event) =~ canary
        refute log =~ canary
      after
        File.rm_rf(test_root)
      end
    end
  end

  test "app server declines command execution callbacks when approval policy is never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-89")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODex_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODex_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODex_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODex_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODex_TRACE:-/tmp/codex-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-89\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-89\"}}}'
            printf '%s\\n' '{\"id\":99,\"method\":\"item/commandExecution/requestApproval\",\"params\":{\"command\":\"gh pr view\",\"cwd\":\"/tmp\",\"reason\":\"need approval\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-89\",\"turn\":{\"id\":\"turn-89\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-auto-approve",
        identifier: "MT-89",
        title: "Decline unexpected request",
        description: "Ensure never-ask policy fails closed on approval callbacks",
        state: "In Progress",
        url: "https://example.org/issues/MT-89",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Handle approval request", issue)

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 1 and
                   get_in(payload, ["params", "capabilities", "experimentalApi"]) == true
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 2 and
                   case get_in(payload, ["params", "dynamicTools"]) do
                     [
                       %{
                         "description" => description,
                         "inputSchema" => %{"required" => ["query"]},
                         "name" => "linear_graphql"
                       }
                     ] ->
                       description =~ "Linear"

                     _ ->
                       false
                   end
               else
                 false
               end
             end)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 99 and get_in(payload, ["result", "decision"]) == "decline"
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks MCP tool input prompts without fabricating a response under never" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-auto-approve-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-717")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-auto-approve.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-auto-approve.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-717\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-717\"}}}'
            printf '%s\\n' '{\"id\":110,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-717\",\"questions\":[{\"header\":\"Approve app tool call?\",\"id\":\"mcp_tool_call_approval_call-717\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Run the tool and continue.\",\"label\":\"Approve Once\"},{\"description\":\"Run the tool and remember this choice for this session.\",\"label\":\"Approve this Session\"},{\"description\":\"Decline this tool call and continue.\",\"label\":\"Deny\"},{\"description\":\"Cancel this tool call\",\"label\":\"Cancel\"}],\"question\":\"The linear MCP server wants to run the tool \\\"Save issue\\\", which may modify or delete data. Allow this action?\"}],\"threadId\":\"thread-717\",\"turnId\":\"turn-717\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-717\",\"turn\":{\"id\":\"turn-717\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-auto-approve",
        identifier: "MT-717",
        title: "Deny MCP tool request user input",
        description: "Ensure app tool approval prompts fail closed automatically",
        state: "In Progress",
        url: "https://example.org/issues/MT-717",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle tool approval prompt", issue)

      assert payload == %{request_id_type: :integer, request_kind: :tool_user_input}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 110
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "never policy fails closed across file, legacy, permissions, and MCP callbacks" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-fail-closed-callbacks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-720")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(thread_id: "thread-720", turn_id: "turn-720", cwd: workspace) ++
            [
              FakeCodex.request(201, "item/fileChange/requestApproval", %{
                "itemId" => "file-change-720",
                "startedAtMs" => 0,
                "threadId" => "thread-720",
                "turnId" => "turn-720"
              }),
              FakeCodex.expect(%{
                "id" => 201,
                "result" => FakeCodex.fail_closed_callback_response("item/fileChange/requestApproval")
              }),
              FakeCodex.request(202, "execCommandApproval", %{
                "callId" => "exec-720",
                "command" => ["true"],
                "conversationId" => "thread-720",
                "cwd" => workspace,
                "parsedCmd" => []
              }),
              FakeCodex.expect(%{
                "id" => 202,
                "result" => FakeCodex.fail_closed_callback_response("execCommandApproval")
              }),
              FakeCodex.request(203, "applyPatchApproval", %{
                "callId" => "patch-720",
                "conversationId" => "thread-720",
                "fileChanges" => %{}
              }),
              FakeCodex.expect(%{
                "id" => 203,
                "result" => FakeCodex.fail_closed_callback_response("applyPatchApproval")
              }),
              FakeCodex.request(204, "item/permissions/requestApproval", %{
                "cwd" => workspace,
                "itemId" => "permissions-720",
                "permissions" => %{},
                "startedAtMs" => 0,
                "threadId" => "thread-720",
                "turnId" => "turn-720"
              }),
              FakeCodex.expect(%{
                "id" => 204,
                "result" => FakeCodex.no_grant_permissions_response()
              }),
              FakeCodex.request(205, "mcpServer/elicitation/request", %{
                "message" => "Approve access?",
                "mode" => "openai/form",
                "requestedSchema" => %{},
                "serverName" => "fixture-mcp",
                "threadId" => "thread-720",
                "turnId" => "turn-720"
              }),
              FakeCodex.expect(%{
                "id" => 205,
                "result" => FakeCodex.fail_closed_callback_response("mcpServer/elicitation/request")
              }),
              FakeCodex.turn_completed_notification("thread-720", "turn-720"),
              FakeCodex.exit(0)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-fail-closed-callbacks",
        identifier: "MT-720",
        title: "Fail closed on callbacks",
        description: "Never ask is not permission to approve",
        state: "In Progress",
        url: "https://example.org/issues/MT-720",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Deny unexpected callbacks", issue)
      assert :ok = FakeCodex.assert_complete!(fixture)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks freeform tool input prompts without fabricating an answer" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-required-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-718")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r _line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-718"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-718"}}}'
            printf '%s\\n' '{"id":111,"method":"item/tool/requestUserInput","params":{"itemId":"call-718","questions":[{"header":"Provide context","id":"freeform-718","isOther":false,"isSecret":false,"options":null,"question":"What comment should I post back to the issue?"}],"threadId":"thread-718","turnId":"turn-718"}}'
            ;;
          5)
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-718","turn":{"id":"turn-718"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server",
        codex_approval_policy: "never"
      )

      issue = %Issue{
        id: "issue-tool-user-input-required",
        identifier: "MT-718",
        title: "Non interactive tool input answer",
        description: "Ensure arbitrary tool prompts block without a fabricated answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-718",
        labels: ["backend"]
      }

      on_message = fn message -> send(self(), {:app_server_message, message}) end

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle generic tool input", issue, on_message: on_message)

      assert payload == %{request_id_type: :integer, request_kind: :tool_user_input}

      assert_received {:app_server_message,
                       %{
                         event: :turn_input_required,
                         request_id_type: :integer,
                         request_kind: :tool_user_input
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "app server blocks option-based tool input prompts without fabricating an answer" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-user-input-options-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-719")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-user-input-options.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-user-input-options.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-719\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-719\"}}}'
            printf '%s\\n' '{\"id\":112,\"method\":\"item/tool/requestUserInput\",\"params\":{\"itemId\":\"call-719\",\"questions\":[{\"header\":\"Choose an action\",\"id\":\"options-719\",\"isOther\":false,\"isSecret\":false,\"options\":[{\"description\":\"Use the default behavior.\",\"label\":\"Use default\"},{\"description\":\"Skip this step.\",\"label\":\"Skip\"}],\"question\":\"How should I proceed?\"}],\"threadId\":\"thread-719\",\"turnId\":\"turn-719\"}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-719\",\"turn\":{\"id\":\"turn-719\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-user-input-options",
        identifier: "MT-719",
        title: "Option based tool input answer",
        description: "Ensure option prompts block without a fabricated answer",
        state: "In Progress",
        url: "https://example.org/issues/MT-719",
        labels: ["backend"]
      }

      assert {:error, {:turn_input_required, payload}} =
               AppServer.run(workspace, "Handle option based tool input", issue)

      assert payload == %{request_id_type: :integer, request_kind: :tool_user_input}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      refute Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 112
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server rejects unsupported dynamic tool calls without stalling" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90\"}}}'
            printf '%s\\n' '{\"id\":101,\"method\":\"item/tool/call\",\"params\":{\"tool\":\" linear_graphql \",\"callId\":\"call-90\",\"threadId\":\"thread-90\",\"turnId\":\"turn-90\",\"arguments\":{}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-90\",\"turn\":{\"id\":\"turn-90\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call",
        identifier: "MT-90",
        title: "Unsupported tool call",
        description: "Ensure unsupported tool calls do not stall a turn",
        state: "In Progress",
        url: "https://example.org/issues/MT-90",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        case tool do
          "linear_graphql" -> %{"success" => true, "contentItems" => []}
          other -> DynamicTool.execute(other, arguments)
        end
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Reject unsupported tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, " linear_graphql ", %{}}

      assert_received {:app_server_message,
                       %{
                         event: :unsupported_tool_call,
                         request_id_type: :integer,
                         request_kind: :other_request,
                         tool_kind: :unsupported
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 101 and
                   get_in(payload, ["result", "success"]) == false and
                   Enum.sort(Map.keys(payload["result"])) == ["contentItems", "success"] and
                   String.contains?(
                     get_in(payload, ["result", "contentItems", Access.at(0), "text"]),
                     "Unsupported dynamic tool"
                   )
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server executes supported dynamic tool calls and returns the tool result" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-supported-tool-call-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90A")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-supported-tool-call.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-supported-tool-call.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90a\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90a\"}}}'
            printf '%s\\n' '{\"id\":102,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90a\",\"threadId\":\"thread-90a\",\"turnId\":\"turn-90a\",\"arguments\":{\"query\":\"query Viewer { viewer { id } }\",\"variables\":{\"includeTeams\":false}}}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-90a\",\"turn\":{\"id\":\"turn-90a\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-supported-tool-call",
        identifier: "MT-90A",
        title: "Supported tool call",
        description: "Ensure supported tool calls return tool output",
        state: "In Progress",
        url: "https://example.org/issues/MT-90A",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          success: true,
          output: ~s({"data":{"viewer":{"id":"usr_123"}}}),
          contentItems: [
            %{
              type: "inputText",
              text: ~s({"data":{"viewer":{"id":"usr_123"}}})
            }
          ]
        }
      end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle supported tool calls", issue, tool_executor: tool_executor)

      assert_received {:tool_called, "linear_graphql",
                       %{
                         "query" => "query Viewer { viewer { id } }",
                         "variables" => %{"includeTeams" => false}
                       }}

      trace = File.read!(trace_file)
      lines = String.split(trace, "\n", trim: true)

      assert Enum.any?(lines, fn line ->
               if String.starts_with?(line, "JSON:") do
                 payload =
                   line
                   |> String.trim_leading("JSON:")
                   |> Jason.decode!()

                 payload["id"] == 102 and
                   get_in(payload, ["result", "success"]) == true and
                   Enum.sort(Map.keys(payload["result"])) == ["contentItems", "success"] and
                   get_in(payload, ["result", "contentItems", Access.at(0), "text"]) ==
                     ~s({"data":{"viewer":{"id":"usr_123"}}})
               else
                 false
               end
             end)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server emits tool_call_failed for supported tool failures" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-call-failed-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90B")
      codex_binary = Path.join(test_root, "fake-codex")
      trace_file = Path.join(test_root, "codex-tool-call-failed.trace")
      previous_trace = System.get_env("SYMP_TEST_CODEx_TRACE")

      on_exit(fn ->
        if is_binary(previous_trace) do
          System.put_env("SYMP_TEST_CODEx_TRACE", previous_trace)
        else
          System.delete_env("SYMP_TEST_CODEx_TRACE")
        end
      end)

      System.put_env("SYMP_TEST_CODEx_TRACE", trace_file)
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      trace_file="${SYMP_TEST_CODEx_TRACE:-/tmp/codex-tool-call-failed.trace}"
      count=0
      while IFS= read -r line; do
        count=$((count + 1))
        printf 'JSON:%s\\n' \"$line\" >> \"$trace_file\"

        case \"$count\" in
          1)
            printf '%s\\n' '{\"id\":1,\"result\":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-90b\"}}}'
            ;;
          4)
            printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-90b\"}}}'
            printf '%s\\n' '{\"id\":103,\"method\":\"item/tool/call\",\"params\":{\"tool\":\"linear_graphql\",\"callId\":\"call-90b\",\"threadId\":\"thread-90b\",\"turnId\":\"turn-90b\",\"arguments\":false}}'
            ;;
          5)
            printf '%s\\n' '{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-90b\",\"turn\":{\"id\":\"turn-90b\"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-tool-call-failed",
        identifier: "MT-90B",
        title: "Tool call failed",
        description: "Ensure supported tool failures emit a distinct event",
        state: "In Progress",
        url: "https://example.org/issues/MT-90B",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:tool_called, tool, arguments})

        %{
          "success" => false,
          "contentItems" => [
            %{
              "type" => "inputText",
              "text" => ~s({"error":{"message":"boom"}})
            }
          ]
        }
      end

      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Handle failed tool calls", issue,
                 on_message: on_message,
                 tool_executor: tool_executor
               )

      assert_received {:tool_called, "linear_graphql", false}

      assert_received {:app_server_message,
                       %{
                         event: :tool_call_failed,
                         request_id_type: :integer,
                         request_kind: :other_request,
                         tool_kind: :supported
                       }}
    after
      File.rm_rf(test_root)
    end
  end

  test "dynamic tool execution is bounded by the turn deadline and returns uncertainty" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-tool-deadline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-90C")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-tool-deadline",
            turn_id: "turn-tool-deadline",
            cwd: workspace
          ) ++
            [
              FakeCodex.request(104, "item/tool/call", %{
                "arguments" => %{"query" => "query Viewer { viewer { id } }"},
                "callId" => "call-tool-deadline",
                "threadId" => "thread-tool-deadline",
                "tool" => "linear_graphql",
                "turnId" => "turn-tool-deadline"
              }),
              FakeCodex.barrier("no-tool-response", timeout_ms: 30_000)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_turn_timeout_ms: 80
      )

      canary = "PRIVATE-TOOL-PROMPT-CANARY"

      issue = %Issue{
        id: "issue-tool-deadline",
        identifier: "MT-90C",
        title: "Bound dynamic tool execution",
        description: canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-90C",
        labels: ["backend"]
      }

      test_pid = self()

      tool_executor = fn tool, arguments ->
        send(test_pid, {:deadline_tool_started, tool, arguments})
        Process.sleep(5_000)
        %{"success" => true, "contentItems" => []}
      end

      run_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      attempt_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

      assert {:ok, session} =
               AppServer.start_session(workspace,
                 correlation: %{run_id: run_id, attempt_id: attempt_id}
               )

      connection_state = :sys.get_state(session.connection)
      target_pid = connection_state.adapter.target_identity.pid

      assert session.metadata.cleanup_scope == :local_pid_namespace
      assert session.metadata.codex_app_server_pid == Integer.to_string(target_pid)
      refute session.metadata.codex_app_server_pid == Integer.to_string(connection_state.adapter.os_pid)

      on_exit(fn ->
        if Process.alive?(session.connection), do: AppServer.stop_session(session)
      end)

      started_ms = System.monotonic_time(:millisecond)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            AppServer.run_turn(session, "Execute tool for #{canary}", issue, tool_executor: tool_executor)

          send(test_pid, {:tool_deadline_result, result})
        end)

      elapsed_ms = System.monotonic_time(:millisecond) - started_ms

      assert_received {:deadline_tool_started, "linear_graphql", %{"query" => _query}}

      assert_received {:tool_deadline_result, result = {:error, error}}

      assert %TransportError{
               kind: :uncertain_external_outcome,
               details: %{
                 operation: %{
                   method: "item/tool/call",
                   send_state: :sent,
                   run_id: ^run_id,
                   attempt_id: ^attempt_id,
                   operation_id: operation_id
                 },
                 reconciliation_required: true
               }
             } = error

      assert SymphonyElixir.Identity.valid_uuid4?(operation_id)

      assert elapsed_ms < 500
      refute log =~ canary
      refute Enum.any?(FakeCodex.received!(fixture), &(&1["id"] == 104))

      assert {:error, %TransportError{kind: :uncertain_external_outcome}} =
               AppServer.stop_session(session, result)
    after
      File.rm_rf(test_root)
    end
  end

  test "a successful tool result observed after the deadline retains tool uncertainty" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-tool-result-deadline-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TOOL-RESULT-DEADLINE")
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-tool-result-deadline",
            turn_id: "turn-tool-result-deadline",
            cwd: workspace
          ) ++
            [
              FakeCodex.request(106, "item/tool/call", %{
                "arguments" => %{"query" => "mutation Completed"},
                "callId" => "call-tool-result-deadline",
                "threadId" => "thread-tool-result-deadline",
                "tool" => "linear_graphql",
                "turnId" => "turn-tool-result-deadline"
              }),
              FakeCodex.barrier("no-late-tool-response", timeout_ms: 30_000)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_turn_timeout_ms: 100
      )

      issue = %Issue{
        id: "issue-tool-result-deadline",
        identifier: "MT-TOOL-RESULT-DEADLINE",
        title: "Preserve a late successful tool operation",
        description: "Bound the response deadline",
        state: "In Progress"
      }

      test_pid = self()
      release_ref = make_ref()

      tool_executor = fn _tool, _arguments ->
        send(test_pid, {:late_tool_ready, self()})

        receive do
          {:return_late_tool_result, ^release_ref} ->
            %{"success" => true, "contentItems" => []}
        end
      end

      assert {:ok, session} = AppServer.start_session(workspace)

      on_exit(fn ->
        if Process.alive?(session.connection), do: AppServer.stop_session(session)
      end)

      task =
        Task.async(fn ->
          AppServer.run_turn(session, "Execute the late tool", issue, tool_executor: tool_executor)
        end)

      on_exit(fn ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      assert_receive {:late_tool_ready, tool_worker}, 1_000
      assert :erlang.suspend_process(task.pid)

      try do
        send(tool_worker, {:return_late_tool_result, release_ref})
        Process.sleep(150)
      after
        if Process.alive?(task.pid), do: :erlang.resume_process(task.pid)
      end

      assert {:error,
              %TransportError{
                kind: :uncertain_external_outcome,
                details: %{
                  cause: %{kind: :request_timeout},
                  operation: %{method: "item/tool/call", send_state: :sent},
                  reconciliation_required: true
                }
              } = error} = Task.await(task, 1_000)

      refute inspect(error) =~ "mutation Completed"
      refute Enum.any?(FakeCodex.received!(fixture), &(&1["id"] == 106))

      assert {:error, %TransportError{kind: :uncertain_external_outcome}} =
               AppServer.stop_session(session, {:error, error})
    after
      File.rm_rf(test_root)
    end
  end

  test "post-dispatch dynamic tool exceptions preserve operation uncertainty without content" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-tool-exception-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TOOL-EXCEPTION")
      canary = "PRIVATE-TOOL-EXCEPTION-CANARY"
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-tool-exception",
            turn_id: "turn-tool-exception",
            cwd: workspace
          ) ++
            [
              FakeCodex.request(105, "item/tool/call", %{
                "arguments" => %{"private" => canary},
                "callId" => "call-tool-exception",
                "threadId" => "thread-tool-exception",
                "tool" => "linear_graphql",
                "turnId" => "turn-tool-exception"
              }),
              FakeCodex.barrier("no-exception-response", timeout_ms: 30_000)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_turn_timeout_ms: 1_000
      )

      issue = %Issue{
        id: "issue-tool-exception",
        identifier: "MT-TOOL-EXCEPTION",
        title: "Conservatively classify tool exceptions",
        description: canary,
        state: "In Progress",
        url: "https://example.org/issues/MT-TOOL-EXCEPTION",
        labels: ["security"]
      }

      test_pid = self()

      tool_executor = fn _tool, _arguments ->
        send(test_pid, :simulated_tool_mutation_completed)
        raise "post-mutation #{canary}"
      end

      on_message = fn message -> send(test_pid, {:tool_exception_message, message}) end
      assert {:ok, session} = AppServer.start_session(workspace)

      on_exit(fn ->
        if Process.alive?(session.connection), do: AppServer.stop_session(session)
      end)

      started_ms = System.monotonic_time(:millisecond)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            AppServer.run_turn(session, "Execute #{canary}", issue,
              on_message: on_message,
              tool_executor: tool_executor
            )

          send(test_pid, {:tool_exception_result, result})
        end)

      elapsed_ms = System.monotonic_time(:millisecond) - started_ms
      assert_received :simulated_tool_mutation_completed
      assert_received {:tool_exception_result, result = {:error, error}}

      assert %TransportError{
               kind: :uncertain_external_outcome,
               details: %{
                 cause: %{kind: :response_error},
                 operation: %{
                   method: "item/tool/call",
                   operation_id: tool_operation_id,
                   send_state: :sent
                 },
                 reconciliation_required: true
               }
             } = error

      assert SymphonyElixir.Identity.valid_uuid4?(tool_operation_id)
      assert elapsed_ms < 500
      refute inspect(error) =~ canary
      refute log =~ canary
      refute Enum.any?(FakeCodex.received!(fixture), &(&1["id"] == 105))

      assert_received {:tool_exception_message, %{event: :session_started, operation_id: turn_operation_id}}

      assert_received {:tool_exception_message,
                       event = %{
                         event: :uncertain_external_outcome,
                         operation_id: ^tool_operation_id,
                         operation: %{
                           method: "item/tool/call",
                           operation_id: ^tool_operation_id
                         },
                         reason: %{kind: :uncertain_external_outcome}
                       }}

      assert SymphonyElixir.Identity.valid_uuid4?(turn_operation_id)
      refute turn_operation_id == tool_operation_id
      refute inspect(event) =~ canary

      assert {:error, %TransportError{kind: :uncertain_external_outcome}} =
               AppServer.stop_session(session, result)
    after
      File.rm_rf(test_root)
    end
  end

  test "tool response write failure retains the completed tool operation" do
    alias SymphonyElixir.TestSupport.FakeCodexAppServer, as: FakeCodex

    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-tool-response-failure-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-TOOL-RESPONSE-FAILURE")
      canary = "PRIVATE-TOOL-RESPONSE-FAILURE-CANARY"
      File.mkdir_p!(workspace)

      fixture =
        FakeCodex.create!(
          test_root,
          FakeCodex.session_prelude(
            thread_id: "thread-tool-response-failure",
            turn_id: "turn-tool-response-failure",
            cwd: workspace
          ) ++
            [
              FakeCodex.request(107, "item/tool/call", %{
                "arguments" => %{"private" => canary},
                "callId" => "call-tool-response-failure",
                "threadId" => "thread-tool-response-failure",
                "tool" => "linear_graphql",
                "turnId" => "turn-tool-response-failure"
              }),
              FakeCodex.barrier("exit-before-tool-response", timeout_ms: 5_000),
              FakeCodex.exit(0)
            ]
        )

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: fixture.command,
        codex_turn_timeout_ms: 2_000
      )

      issue = %Issue{
        id: "issue-tool-response-failure",
        identifier: "MT-TOOL-RESPONSE-FAILURE",
        title: "Preserve tool operation after response failure",
        description: canary,
        state: "In Progress"
      }

      test_pid = self()
      release_ref = make_ref()
      on_message = fn message -> send(test_pid, {:tool_response_failure_message, message}) end

      tool_executor = fn _tool, _arguments ->
        send(test_pid, {:tool_mutation_completed, self()})

        receive do
          {:return_tool_result, ^release_ref} ->
            %{"success" => true, "contentItems" => []}
        end
      end

      assert {:ok, session} = AppServer.start_session(workspace)

      on_exit(fn ->
        if Process.alive?(session.connection), do: AppServer.stop_session(session)
      end)

      task =
        Task.async(fn ->
          AppServer.run_turn(session, "Execute #{canary}", issue,
            on_message: on_message,
            tool_executor: tool_executor
          )
        end)

      on_exit(fn ->
        if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
      end)

      assert_receive {:tool_mutation_completed, tool_worker}, 1_000
      FakeCodex.release!(fixture, "exit-before-tool-response")
      assert %TransportError{} = wait_for_connection_failure(session.connection)
      send(tool_worker, {:return_tool_result, release_ref})

      assert {:error,
              %TransportError{
                kind: :uncertain_external_outcome,
                details: %{
                  cause: %{kind: :process_exit},
                  operation: %{method: "item/tool/call", send_state: :sent},
                  reconciliation_required: true
                }
              } = error} = Task.await(task, 1_000)

      refute inspect(error) =~ canary
      refute Enum.any?(FakeCodex.received!(fixture), &(&1["id"] == 107))

      assert_received {:tool_response_failure_message,
                       event = %{
                         event: :uncertain_external_outcome,
                         operation: %{method: "item/tool/call"}
                       }}

      refute inspect(event) =~ canary

      assert {:error, %TransportError{kind: :uncertain_external_outcome}} =
               AppServer.stop_session(session, {:error, error})
    after
      File.rm_rf(test_root)
    end
  end

  test "app server buffers partial JSON lines until newline terminator" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-partial-line-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-91")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            padding=$(printf '%*s' 1100000 '' | tr ' ' a)
            printf '{"id":1,"result":{"padding":"%s"}}\\n' "$padding"
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-91"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-91"}}}'
            sleep 0.1
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-91","turn":{"id":"turn-91"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-partial-line",
        identifier: "MT-91",
        title: "Partial line decode",
        description: "Ensure JSON parsing waits for newline-delimited messages",
        state: "In Progress",
        url: "https://example.org/issues/MT-91",
        labels: ["backend"]
      }

      assert {:ok, _result} = AppServer.run(workspace, "Validate newline-delimited buffering", issue)
    after
      File.rm_rf(test_root)
    end
  end

  test "app server isolates stderr from protocol stdout and permits a successful turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-stderr-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-92")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-92"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-92"}}}'
            printf '%s\\n' 'warning: this is stderr noise' >&2
            sleep 0.1
            printf '%s\\n' '{"method":"turn/completed","params":{"threadId":"thread-92","turn":{"id":"turn-92"}}}'
            exit 0
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-stderr",
        identifier: "MT-92",
        title: "Capture stderr",
        description: "Ensure codex stderr is captured and logged",
        state: "In Progress",
        url: "https://example.org/issues/MT-92",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:ok, _result} =
               AppServer.run(workspace, "Capture stderr log", issue, on_message: on_message)

      assert_received {:app_server_message, %{event: :turn_completed}}
      refute_received {:app_server_message, %{event: :malformed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "malformed protocol stdout is a terminal uncertain outcome for an active turn" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-malformed-protocol-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      workspace = Path.join(workspace_root, "MT-93")
      codex_binary = Path.join(test_root, "fake-codex")
      File.mkdir_p!(workspace)

      File.write!(codex_binary, """
      #!/bin/sh
      count=0
      while IFS= read -r line; do
        count=$((count + 1))

        case "$count" in
          1)
            printf '%s\\n' '{"id":1,"result":{}}'
            ;;
          2)
            ;;
          3)
            printf '%s\\n' '{"id":2,"result":{"thread":{"id":"thread-93"}}}'
            ;;
          4)
            printf '%s\\n' '{"id":3,"result":{"turn":{"id":"turn-93"}}}'
            sleep 0.1
            printf '%s\\n' '{"method":"turn/completed"'
            sleep 1
            ;;
          *)
            exit 0
            ;;
        esac
      done
      """)

      File.chmod!(codex_binary, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_command: "#{codex_binary} app-server"
      )

      issue = %Issue{
        id: "issue-malformed-protocol",
        identifier: "MT-93",
        title: "Malformed protocol frame",
        description: "Ensure malformed JSON-like frames are surfaced to the orchestrator",
        state: "In Progress",
        url: "https://example.org/issues/MT-93",
        labels: ["backend"]
      }

      test_pid = self()
      on_message = fn message -> send(test_pid, {:app_server_message, message}) end

      assert {:error,
              %TransportError{
                kind: :uncertain_external_outcome,
                details: %{
                  cause: %{
                    kind: :malformed_json,
                    message: "Codex App Server sent malformed JSON on stdout"
                  },
                  operation: %{method: "turn/start", send_state: :sent},
                  reconciliation_required: true
                }
              }} =
               AppServer.run(workspace, "Capture malformed protocol line", issue, on_message: on_message)

      assert_received {:app_server_message,
                       %{
                         event: :uncertain_external_outcome,
                         reason: %{
                           kind: :uncertain_external_outcome,
                           details: %{cause: %{kind: :malformed_json}}
                         }
                       }}

      assert_received {:app_server_message,
                       %{
                         event: :turn_ended_with_error,
                         reason: %{
                           kind: :uncertain_external_outcome,
                           details: %{cause: %{kind: :malformed_json}}
                         }
                       }}

      refute_received {:app_server_message, %{event: :turn_completed}}
    after
      File.rm_rf(test_root)
    end
  end

  test "remote App Server requests fail before any SSH executable is launched" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-app-server-remote-gate-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")

    on_exit(fn ->
      restore_env("PATH", previous_path)
    end)

    try do
      launch_marker = Path.join(test_root, "ssh-launched")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      touch #{launch_marker}
      exit 99
      """)

      File.chmod!(fake_ssh, 0o755)

      assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} =
               AppServer.start_session("/remote/workspaces/MT-REMOTE",
                 worker_host: "worker-01:2200"
               )

      refute File.exists?(launch_marker)
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_for_connection_failure(connection, attempts \\ 200)

  defp wait_for_connection_failure(connection, attempts) when attempts > 0 do
    case :sys.get_state(connection).failure do
      %TransportError{} = error ->
        error

      nil ->
        Process.sleep(5)
        wait_for_connection_failure(connection, attempts - 1)
    end
  end

  defp wait_for_connection_failure(_connection, 0),
    do: flunk("connection did not record the injected process exit")
end
