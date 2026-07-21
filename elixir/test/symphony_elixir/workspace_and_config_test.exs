# Downstream modification notice (2026-07-14): Symphony Studio makes optional
# defaults explicit and proves pinned Codex approval-policy normalization.
defmodule SymphonyElixir.WorkspaceAndConfigTest do
  use SymphonyElixir.TestSupport
  alias Ecto.Changeset
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Codex, StringOrMap}
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.WorkspaceHookRunner

  test "workspace bootstrap can be implemented in after_create hook" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-bootstrap-#{System.unique_integer([:positive])}"
      )

    try do
      template_repo = Path.join(test_root, "source")
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(template_repo)
      File.mkdir_p!(Path.join(template_repo, "keep"))
      File.write!(Path.join([template_repo, "keep", "file.txt"]), "keep me")
      File.write!(Path.join(template_repo, "README.md"), "hook clone\n")
      System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
      System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
      System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
      System.cmd("git", ["-C", template_repo, "add", "README.md", "keep/file.txt"])
      System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "git clone --depth 1 #{template_repo} ."
      )

      assert {:ok, workspace} = Workspace.create_for_issue("S-1")
      assert File.exists?(Path.join(workspace, ".git"))
      assert File.read!(Path.join(workspace, "README.md")) == "hook clone\n"
      assert File.read!(Path.join([workspace, "keep", "file.txt"])) == "keep me"
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace path is deterministic per issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-deterministic-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

    assert {:ok, first_workspace} = Workspace.create_for_issue("MT/Det")
    assert {:ok, second_workspace} = Workspace.create_for_issue("MT/Det")

    assert first_workspace == second_workspace
    assert Path.basename(first_workspace) =~ ~r/^MT_Det--[0-9a-f]{32}$/
  end

  test "workspace identifiers preserve ordinary IDs and separate colliding unsafe inputs" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-identifiers-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, ordinary_workspace} = Workspace.create_for_issue("MT-123")
      assert Path.basename(ordinary_workspace) == "MT-123"

      assert {:ok, slash_workspace} = Workspace.create_for_issue("MT/A")
      assert {:ok, question_workspace} = Workspace.create_for_issue("MT?A")
      refute slash_workspace == question_workspace
      assert Path.basename(slash_workspace) =~ ~r/^MT_A--[0-9a-f]{32}$/
      assert Path.basename(question_workspace) =~ ~r/^MT_A--[0-9a-f]{32}$/

      assert {:ok, invalid_utf8_workspace} = Workspace.create_for_issue(<<255, 0, 47>>)
      assert String.valid?(Path.basename(invalid_utf8_workspace))
      assert byte_size(Path.basename(invalid_utf8_workspace)) <= 180

      assert {:ok, long_workspace} = Workspace.create_for_issue(String.duplicate("A", 500))
      assert byte_size(Path.basename(long_workspace)) == 180
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace reuses existing issue directory without deleting local changes" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reuse-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo first > README.md"
      )

      assert {:ok, first_workspace} = Workspace.create_for_issue("MT-REUSE")

      File.write!(Path.join(first_workspace, "README.md"), "changed\n")
      File.write!(Path.join(first_workspace, "local-progress.txt"), "in progress\n")
      File.mkdir_p!(Path.join(first_workspace, "deps"))
      File.mkdir_p!(Path.join(first_workspace, "_build"))
      File.mkdir_p!(Path.join(first_workspace, "tmp"))
      File.write!(Path.join([first_workspace, "deps", "cache.txt"]), "cached deps\n")
      File.write!(Path.join([first_workspace, "_build", "artifact.txt"]), "compiled artifact\n")
      File.write!(Path.join([first_workspace, "tmp", "scratch.txt"]), "remove me\n")

      assert {:ok, second_workspace} = Workspace.create_for_issue("MT-REUSE")
      assert second_workspace == first_workspace
      assert File.read!(Path.join(second_workspace, "README.md")) == "changed\n"
      assert File.read!(Path.join(second_workspace, "local-progress.txt")) == "in progress\n"
      assert File.read!(Path.join([second_workspace, "deps", "cache.txt"])) == "cached deps\n"
      assert File.read!(Path.join([second_workspace, "_build", "artifact.txt"])) == "compiled artifact\n"
      assert File.read!(Path.join([second_workspace, "tmp", "scratch.txt"])) == "remove me\n"
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace replaces stale non-directory paths" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-stale-path-#{System.unique_integer([:positive])}"
      )

    try do
      stale_workspace = Path.join(workspace_root, "MT-STALE")
      File.mkdir_p!(workspace_root)
      File.write!(stale_workspace, "old state\n")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(stale_workspace)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-STALE")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace rejects symlink escapes under the configured root" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      outside_root = Path.join(test_root, "outside")
      symlink_path = Path.join(workspace_root, "MT-SYM")

      File.mkdir_p!(workspace_root)
      File.mkdir_p!(outside_root)
      File.ln_s!(outside_root, symlink_path)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_issue_symlink, ^symlink_path}} =
               Workspace.create_for_issue("MT-SYM")
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace rejects sibling and broken issue-leaf symlinks without following either" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-leaf-symlinks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      sibling_workspace = Path.join(workspace_root, "MT-SIBLING")
      sibling_target = Path.join(workspace_root, "OTHER")
      broken_workspace = Path.join(workspace_root, "MT-BROKEN")

      File.mkdir_p!(sibling_target)
      File.ln_s!(sibling_target, sibling_workspace)
      File.ln_s!(Path.join(test_root, "missing-target"), broken_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:error, {:workspace_issue_symlink, ^sibling_workspace}} =
               Workspace.create_for_issue("MT-SIBLING")

      assert {:error, {:workspace_issue_symlink, ^broken_workspace}} =
               Workspace.create_for_issue("MT-BROKEN")

      assert File.dir?(sibling_target)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(broken_workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "path canonicalization detects symlink loops and bounds acyclic traversal" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-path-symlink-loop-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(test_root)
      first = Path.join(test_root, "first")
      second = Path.join(test_root, "second")
      File.ln_s!(second, first)
      File.ln_s!(first, second)

      assert {:error, {:path_canonicalize_failed, ^first, {:symlink_loop, loop_path}}} =
               SymphonyElixir.PathSafety.canonicalize(first)

      assert loop_path in [first, second]

      chain_root = Path.join(test_root, "chain")
      File.mkdir_p!(chain_root)

      for index <- 0..40 do
        target = if index == 40, do: "target", else: "link-#{index + 1}"
        File.ln_s!(target, Path.join(chain_root, "link-#{index}"))
      end

      assert {:error, {:path_canonicalize_failed, _chain_path, {:too_many_symlinks, 40}}} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(chain_root, "link-0"))
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace canonicalizes symlinked workspace roots before creating issue directories" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-symlink-#{System.unique_integer([:positive])}"
      )

    try do
      actual_root = Path.join(test_root, "actual-workspaces")
      linked_root = Path.join(test_root, "linked-workspaces")

      File.mkdir_p!(actual_root)
      File.ln_s!(actual_root, linked_root)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: linked_root)

      assert {:ok, canonical_workspace} =
               SymphonyElixir.PathSafety.canonicalize(Path.join(actual_root, "MT-LINK"))

      assert {:ok, workspace} = Workspace.create_for_issue("MT-LINK")
      assert workspace == canonical_workspace
      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove rejects the workspace root itself with a distinct error" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-remove-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(workspace_root)
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:error, {:workspace_equals_root, ^canonical_workspace_root, ^canonical_workspace_root}, ""} =
               Workspace.remove(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook failures" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo nope && exit 17"
      )

      assert {:error,
              {:workspace_hook_failed, "after_create", 17,
               %{
                 stdout_bytes: _stdout_bytes,
                 stderr_bytes: _stderr_bytes,
                 truncated: false
               }}} =
               Workspace.create_for_issue("MT-FAIL")

      assert {:ok, []} = File.ls(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace surfaces after_create hook timeouts" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_after_create: "sleep 1"
      )

      assert {:error, {:workspace_hook_timeout, "after_create", 10}} =
               Workspace.create_for_issue("MT-TIMEOUT")

      assert {:ok, []} = File.ls(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace hooks receive only the explicit environment allowlist" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-env-#{System.unique_integer([:positive])}"
      )

    previous_linear_key = System.get_env("LINEAR_API_KEY")
    previous_source_repo = System.get_env("SOURCE_REPO_URL")

    on_exit(fn ->
      restore_env("LINEAR_API_KEY", previous_linear_key)
      restore_env("SOURCE_REPO_URL", previous_source_repo)
    end)

    try do
      workspace_root = Path.join(test_root, "workspaces")
      System.put_env("LINEAR_API_KEY", "HOOK-SECRET-CANARY")
      System.put_env("SOURCE_REPO_URL", "https://example.invalid/source.git")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "/usr/bin/env > hook-env.txt"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOK-ENV")
      hook_environment = File.read!(Path.join(workspace, "hook-env.txt"))

      assert hook_environment =~ "SOURCE_REPO_URL=https://example.invalid/source.git"
      refute hook_environment =~ "LINEAR_API_KEY"
      refute hook_environment =~ "HOOK-SECRET-CANARY"
    after
      File.rm_rf(test_root)
    end
  end

  test "hook failure metadata and logs never contain raw bounded output" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hook-output-#{System.unique_integer([:positive])}"
      )

    canary = "RAW-HOOK-OUTPUT-CANARY"

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "printf '#{canary}'; i=0; while [ $i -lt 70000 ]; do printf x; i=$((i+1)); done; exit 23"
      )

      {result, log} =
        with_log(fn ->
          Workspace.create_for_issue("MT-HOOK-OUTPUT")
        end)

      assert {:error, {:workspace_hook_output_limit, "after_create", 65_536, output_summary} = reason} =
               result

      assert output_summary == %{stdout_bytes: 65_536, stderr_bytes: 0, truncated: true}

      refute inspect(reason) =~ canary
      refute log =~ canary
      assert {:ok, []} = File.ls(workspace_root)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "a reused workspace survives a failed before_run hook unchanged" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-reused-hook-failure-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      assert {:ok, workspace} = Workspace.create_for_issue("MT-REUSED-HOOK")
      progress_path = Path.join(workspace, "progress.txt")
      File.write!(progress_path, "preserve me")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_run: "printf 'failed'; exit 31"
      )

      assert {:error, {:workspace_hook_failed, "before_run", 31, _summary}} =
               Workspace.run_before_run_hook(workspace, "MT-REUSED-HOOK")

      assert File.read!(progress_path) == "preserve me"
      assert File.dir?(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "hook runner verifies descendant cleanup before exiting after owner death" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-hook-owner-death-#{System.unique_integer([:positive])}"
      )

    try do
      workspace = Path.join(test_root, "workspace")
      ready_path = Path.join(test_root, "ready")
      leaked_path = Path.join(test_root, "leaked")
      File.mkdir_p!(workspace)
      observer = self()

      owner =
        spawn(fn ->
          WorkspaceHookRunner.run(
            "printf ready > '#{ready_path}'; (sleep 1; printf leaked > '#{leaked_path}') & wait",
            workspace,
            "owner_death",
            60_000,
            observer: observer
          )
        end)

      owner_monitor = Process.monitor(owner)
      assert_receive {:workspace_hook_runner_started, runner}, 1_000
      runner_monitor = Process.monitor(runner)
      assert wait_for_path(ready_path, 2_000)

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :killed}, 1_000

      assert_receive {:workspace_hook_runner_stopped, ^runner, {:error, {:workspace_hook_owner_exited, "owner_death"}}},
                     3_000

      assert_receive {:DOWN, ^runner_monitor, :process, ^runner, :normal}, 1_000
      Process.sleep(1_100)
      refute File.exists?(leaked_path)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace creates an empty directory when no bootstrap hook is configured" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-empty-#{System.unique_integer([:positive])}"
      )

    try do
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      workspace = Path.join(workspace_root, "MT-608")
      assert {:ok, canonical_workspace} = SymphonyElixir.PathSafety.canonicalize(workspace)

      assert {:ok, ^canonical_workspace} = Workspace.create_for_issue("MT-608")
      assert File.dir?(workspace)
      assert {:ok, []} = File.ls(workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace removes all workspaces for a closed issue identifier" do
    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-issue-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      target_workspace = Path.join(workspace_root, "S_1")
      untouched_workspace = Path.join(workspace_root, "OTHER-#{System.unique_integer([:positive])}")

      File.mkdir_p!(target_workspace)
      File.mkdir_p!(untouched_workspace)
      File.write!(Path.join(target_workspace, "marker.txt"), "stale")
      File.write!(Path.join(untouched_workspace, "marker.txt"), "keep")

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert :ok = Workspace.remove_issue_workspaces("S_1")
      refute File.exists?(target_workspace)
      assert File.exists?(untouched_workspace)
    after
      File.rm_rf(workspace_root)
    end
  end

  test "workspace cleanup handles missing workspace root" do
    missing_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-missing-workspaces-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: missing_root)

    assert :ok = Workspace.remove_issue_workspaces("S-2")
  end

  test "workspace cleanup ignores non-binary identifier" do
    assert :ok = Workspace.remove_issue_workspaces(nil)
  end

  test "linear issue helpers" do
    issue = %Issue{
      id: "abc",
      labels: ["frontend", "infra"],
      assigned_to_worker: false
    }

    assert Issue.label_names(issue) == ["frontend", "infra"]
    assert issue.labels == ["frontend", "infra"]
    refute issue.assigned_to_worker
  end

  test "linear issue routing requires every configured label" do
    issue = %Issue{labels: [" Symphony ", "JavaScript"], assigned_to_worker: true}

    assert Issue.routable?(issue, [])
    assert Issue.routable?(issue, ["symphony"])
    assert Issue.routable?(issue, ["SYMPHONY", "javascript"])
    refute Issue.routable?(issue, ["symph"])
    refute Issue.routable?(issue, [" "])
    refute Issue.routable?(issue, ["symphony", "security"])
    refute Issue.routable?(%{issue | assigned_to_worker: false}, ["symphony"])
  end

  test "linear client normalizes blockers from inverse relations" do
    raw_issue = %{
      "id" => "issue-1",
      "identifier" => "MT-1",
      "title" => "Blocked todo",
      "description" => "Needs dependency",
      "priority" => 2,
      "state" => %{"name" => "Todo"},
      "branchName" => "mt-1",
      "url" => "https://example.org/issues/MT-1",
      "assignee" => %{
        "id" => "user-1"
      },
      "labels" => %{"nodes" => [%{"name" => "Backend"}]},
      "inverseRelations" => %{
        "nodes" => [
          %{
            "type" => "blocks",
            "issue" => %{
              "id" => "issue-2",
              "identifier" => "MT-2",
              "state" => %{"name" => "In Progress"}
            }
          },
          %{
            "type" => "relatesTo",
            "issue" => %{
              "id" => "issue-3",
              "identifier" => "MT-3",
              "state" => %{"name" => "Done"}
            }
          }
        ]
      },
      "createdAt" => "2026-01-01T00:00:00Z",
      "updatedAt" => "2026-01-02T00:00:00Z"
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    assert issue.blocked_by == [%{id: "issue-2", identifier: "MT-2", state: "In Progress"}]
    assert issue.labels == ["backend"]
    assert issue.priority == 2
    assert issue.state == "Todo"
    assert issue.assignee_id == "user-1"
    assert issue.assigned_to_worker
  end

  test "linear client marks explicitly unassigned issues as not routed to worker" do
    raw_issue = %{
      "id" => "issue-99",
      "identifier" => "MT-99",
      "title" => "Someone else's task",
      "state" => %{"name" => "Todo"},
      "assignee" => %{
        "id" => "user-2"
      }
    }

    issue = Client.normalize_issue_for_test(raw_issue, "user-1")

    refute issue.assigned_to_worker
  end

  test "linear client pagination merge helper preserves issue ordering" do
    issue_page_1 = [
      %Issue{id: "issue-1", identifier: "MT-1"},
      %Issue{id: "issue-2", identifier: "MT-2"}
    ]

    issue_page_2 = [
      %Issue{id: "issue-3", identifier: "MT-3"}
    ]

    merged = Client.merge_issue_pages_for_test([issue_page_1, issue_page_2])

    assert Enum.map(merged, & &1.identifier) == ["MT-1", "MT-2", "MT-3"]
  end

  test "linear client paginates issue state fetches by id beyond one page" do
    issue_ids = Enum.map(1..55, &"issue-#{&1}")
    first_batch_ids = Enum.take(issue_ids, 50)
    second_batch_ids = Enum.drop(issue_ids, 50)

    raw_issue = fn issue_id ->
      suffix = String.replace_prefix(issue_id, "issue-", "")

      %{
        "id" => issue_id,
        "identifier" => "MT-#{suffix}",
        "title" => "Issue #{suffix}",
        "description" => "Description #{suffix}",
        "state" => %{"name" => "In Progress"},
        "labels" => %{"nodes" => []},
        "inverseRelations" => %{"nodes" => []}
      }
    end

    graphql_fun = fn query, variables ->
      send(self(), {:fetch_issue_states_page, query, variables})

      body = %{
        "data" => %{
          "issues" => %{
            "nodes" => Enum.map(variables.ids, raw_issue)
          }
        }
      }

      {:ok, body}
    end

    assert {:ok, issues} = Client.fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)

    assert Enum.map(issues, & &1.id) == issue_ids

    assert_receive {:fetch_issue_states_page, query, %{ids: ^first_batch_ids, first: 50, relationFirst: 50}}
    assert query =~ "SymphonyLinearIssuesById"

    assert_receive {:fetch_issue_states_page, ^query, %{ids: ^second_batch_ids, first: 5, relationFirst: 50}}
  end

  test "linear client logs only content-free failure metadata" do
    status_body_canary = "private-linear-response-body-canary"
    operation_canary = "PrivateLinearOperationCanary"
    tracker = %{api_key: "private-linear-api-key-canary", endpoint: "https://api.linear.app/graphql"}

    status_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_status, 400}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   operation_name: operation_canary,
                   tracker: tracker,
                   request_fun: fn _payload, _headers ->
                     {:ok, %{status: 400, body: %{"errors" => [status_body_canary]}}}
                   end
                 )
      end)

    assert status_log =~ "Linear GraphQL request failed class=api_status status=400"
    refute status_log =~ status_body_canary
    refute status_log =~ operation_canary

    request_reason = {:private_transport_reason, "private-linear-request-reason-canary"}

    request_log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:linear_api_request, ^request_reason}} =
                 Client.graphql(
                   "query Viewer { viewer { id } }",
                   %{},
                   tracker: tracker,
                   request_fun: fn _payload, _headers -> {:error, request_reason} end
                 )
      end)

    assert request_log =~ "Linear GraphQL request failed class=request_error"
    refute request_log =~ "private-linear-request-reason-canary"
    refute request_log =~ "private_transport_reason"
  end

  test "linear endpoint trust policy rejects workflow-controlled credential sinks before authorization" do
    api_key = "PRIVATE-LINEAR-ENDPOINT-KEY-CANARY"

    untrusted_endpoints = [
      "http://api.linear.app/graphql",
      "https://attacker.invalid/graphql",
      "https://api.linear.app.attacker.invalid/graphql",
      "https://user@api.linear.app/graphql",
      "https://api.linear.app:444/graphql",
      "https://api.linear.app/graphql?redirect=attacker",
      "https://api.linear.app/graphql#fragment",
      "https://api.linear.app/not-graphql",
      "not a url"
    ]

    for endpoint <- untrusted_endpoints do
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{
                 tracker: %{
                   api_key: api_key,
                   endpoint: endpoint,
                   kind: "linear",
                   project_slug: "project"
                 }
               })

      assert message == "tracker.endpoint must be the canonical Linear GraphQL endpoint"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :untrusted_linear_endpoint} =
                   Client.graphql("query Viewer { viewer { id } }", %{},
                     tracker: %{api_key: api_key, endpoint: endpoint},
                     request_fun: fn _payload, _headers ->
                       send(self(), {:untrusted_endpoint_requested, endpoint})
                       {:ok, %{status: 200, body: %{"data" => %{}}}}
                     end
                   )
        end)

      refute_received {:untrusted_endpoint_requested, ^endpoint}
      refute log =~ api_key
      refute log =~ endpoint
    end

    for endpoint <- ["https://api.linear.app/graphql", "https://api.linear.app:443/graphql"] do
      assert {:ok, settings} =
               Schema.parse(%{
                 tracker: %{
                   api_key: api_key,
                   endpoint: endpoint,
                   kind: "linear",
                   project_slug: "project"
                 }
               })

      assert settings.tracker.endpoint == endpoint

      assert {:ok, %{"data" => %{"viewer" => %{"id" => "viewer"}}}} =
               Client.graphql("query Viewer { viewer { id } }", %{},
                 tracker: %{api_key: api_key, endpoint: endpoint},
                 request_fun: fn _payload, headers ->
                   send(self(), {:trusted_endpoint_requested, endpoint, headers})
                   {:ok, %{status: 200, body: %{"data" => %{"viewer" => %{"id" => "viewer"}}}}}
                 end
               )

      assert_received {:trusted_endpoint_requested, ^endpoint, headers}
      assert {"Authorization", api_key} in headers
    end
  end

  test "ordinary Linear tracker reads sanitize private transport and GraphQL errors" do
    transport_canary = "PRIVATE-LINEAR-TRANSPORT-CANARY"
    graphql_canary = "PRIVATE-LINEAR-GRAPHQL-CANARY"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "private-linear-api-key-canary",
      tracker_project_slug: "project",
      tracker_assignee: nil
    )

    transport_log =
      ExUnit.CaptureLog.capture_log(fn ->
        Client.with_request_fun_for_test(
          fn _payload, _headers ->
            {:error, {:private_transport, transport_canary}}
          end,
          fn ->
            assert {:error, :linear_transport_failed} = Client.fetch_candidate_issues()
            assert {:error, :linear_transport_failed} = Client.fetch_issues_by_states(["Todo"])
            assert {:error, :linear_transport_failed} = Client.fetch_issue_states_by_ids(["issue-1"])
          end
        )
      end)

    refute transport_log =~ transport_canary
    refute transport_log =~ "private_transport"

    graphql_log =
      ExUnit.CaptureLog.capture_log(fn ->
        Client.with_request_fun_for_test(
          fn _payload, _headers ->
            {:ok,
             %{
               status: 200,
               body: %{"errors" => [%{"extensions" => %{"token" => graphql_canary}}]}
             }}
          end,
          fn ->
            assert {:error, :linear_graphql_failed} = Client.fetch_candidate_issues()
            assert {:error, :linear_graphql_failed} = Client.fetch_issues_by_states(["Todo"])
            assert {:error, :linear_graphql_failed} = Client.fetch_issue_states_by_ids(["issue-1"])

            assert {:ok, %{"errors" => [%{"extensions" => %{"token" => ^graphql_canary}}]}} =
                     Client.graphql("query RawTool { viewer { id } }", %{})
          end
        )
      end)

    refute graphql_log =~ graphql_canary

    assert {:error, :linear_tracker_failed} =
             Client.fetch_issue_states_by_ids_for_test(["issue-1"], fn _query, _variables ->
               {:error, {:private_adapter_error, transport_canary}}
             end)
  end

  test "candidate pagination rejects partial GraphQL data with top-level errors" do
    graphql_canary = "PRIVATE-LINEAR-PARTIAL-CANDIDATE-CANARY"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "private-linear-api-key-canary",
      tracker_project_slug: "project",
      tracker_assignee: nil
    )

    partial_body = %{
      "data" => %{
        "issues" => %{
          "nodes" => [linear_issue_payload("candidate-partial")],
          "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
        }
      },
      "errors" => [%{"extensions" => %{"token" => graphql_canary}}]
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Client.with_request_fun_for_test(
          fn payload, _headers ->
            send(self(), {:partial_candidate_request, payload})
            {:ok, %{status: 200, body: partial_body}}
          end,
          fn ->
            assert {:error, :linear_graphql_failed} = Client.fetch_candidate_issues()
          end
        )
      end)

    assert_received {:partial_candidate_request, %{"query" => query}}
    assert query =~ "SymphonyLinearPoll"
    refute log =~ graphql_canary
  end

  test "issue state refresh rejects partial GraphQL data and preserves raw tool responses" do
    graphql_canary = "PRIVATE-LINEAR-PARTIAL-REFRESH-CANARY"

    partial_body = %{
      "data" => %{"issues" => %{"nodes" => [linear_issue_payload("refresh-partial")]}},
      "errors" => [%{"extensions" => %{"token" => graphql_canary}}]
    }

    assert {:error, :linear_graphql_failed} =
             Client.fetch_issue_states_by_ids_for_test(["refresh-partial"], fn query, variables ->
               assert query =~ "SymphonyLinearIssuesById"
               assert variables.ids == ["refresh-partial"]
               {:ok, partial_body}
             end)

    assert {:ok, ^partial_body} =
             Client.graphql("query RawTool { viewer { id } }", %{},
               tracker: %{
                 api_key: "private-linear-api-key-canary",
                 endpoint: "https://api.linear.app/graphql"
               },
               request_fun: fn _payload, _headers ->
                 {:ok, %{status: 200, body: partial_body}}
               end
             )
  end

  test "viewer assignee resolution rejects partial GraphQL data before polling issues" do
    graphql_canary = "PRIVATE-LINEAR-PARTIAL-VIEWER-CANARY"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_endpoint: "https://api.linear.app/graphql",
      tracker_api_token: "private-linear-api-key-canary",
      tracker_project_slug: "project",
      tracker_assignee: "me"
    )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        Client.with_request_fun_for_test(
          fn payload, _headers ->
            send(self(), {:partial_viewer_request, payload})

            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{"viewer" => %{"id" => "viewer-1"}},
                 "errors" => [%{"extensions" => %{"token" => graphql_canary}}]
               }
             }}
          end,
          fn ->
            assert {:error, :linear_graphql_failed} = Client.fetch_candidate_issues()
          end
        )
      end)

    assert_received {:partial_viewer_request, %{"query" => query}}
    assert query =~ "SymphonyLinearViewer"
    refute_received {:partial_viewer_request, _second_payload}
    refute log =~ graphql_canary
  end

  test "dispatch revalidation propagates a sanitized partial GraphQL failure" do
    stale_issue = %Issue{
      id: "dispatch-partial",
      identifier: "MT-PARTIAL",
      title: "Must not dispatch from partial data",
      state: "Todo",
      blocked_by: []
    }

    partial_body = %{
      "data" => %{"issues" => %{"nodes" => [linear_issue_payload("dispatch-partial")]}},
      "errors" => [%{"message" => "PRIVATE-LINEAR-PARTIAL-DISPATCH-CANARY"}]
    }

    fetcher = fn ["dispatch-partial"] ->
      Client.fetch_issue_states_by_ids_for_test(["dispatch-partial"], fn _query, _variables ->
        {:ok, partial_body}
      end)
    end

    assert {:error, :linear_graphql_failed} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "orchestrator sorts dispatch by priority then oldest created_at" do
    issue_same_priority_older = %Issue{
      id: "issue-old-high",
      identifier: "MT-200",
      title: "Old high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-01 00:00:00Z]
    }

    issue_same_priority_newer = %Issue{
      id: "issue-new-high",
      identifier: "MT-201",
      title: "New high priority",
      state: "Todo",
      priority: 1,
      created_at: ~U[2026-01-02 00:00:00Z]
    }

    issue_lower_priority_older = %Issue{
      id: "issue-old-low",
      identifier: "MT-199",
      title: "Old lower priority",
      state: "Todo",
      priority: 2,
      created_at: ~U[2025-12-01 00:00:00Z]
    }

    sorted =
      Orchestrator.sort_issues_for_dispatch_for_test([
        issue_lower_priority_older,
        issue_same_priority_newer,
        issue_same_priority_older
      ])

    assert Enum.map(sorted, & &1.identifier) == ["MT-200", "MT-201", "MT-199"]
  end

  test "todo issue with non-terminal blocker is not dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "blocked-1",
      identifier: "MT-1001",
      title: "Blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-1", identifier: "MT-1002", state: "In Progress"}]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue assigned to another worker is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_assignee: "dev@example.com")

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "assigned-away-1",
      identifier: "MT-1007",
      title: "Owned elsewhere",
      state: "Todo",
      assigned_to_worker: false
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "issue without every required label is not dispatch-eligible" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: ["symphony", "javascript"]
    )

    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "unlabeled-1",
      identifier: "MT-1008",
      title: "Not opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refute Orchestrator.should_dispatch_issue_for_test(issue, state)
    assert Orchestrator.should_dispatch_issue_for_test(%{issue | labels: ["Symphony", "JavaScript"]}, state)
  end

  test "todo issue with terminal blockers remains dispatch-eligible" do
    state = %Orchestrator.State{
      max_concurrent_agents: 3,
      running: %{},
      claimed: MapSet.new(),
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      retry_attempts: %{}
    }

    issue = %Issue{
      id: "ready-1",
      identifier: "MT-1003",
      title: "Ready work",
      state: "Todo",
      blocked_by: [%{id: "blocker-2", identifier: "MT-1004", state: "Closed"}]
    }

    assert Orchestrator.should_dispatch_issue_for_test(issue, state)
  end

  test "dispatch revalidation skips stale todo issue once a non-terminal blocker appears" do
    stale_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: []
    }

    refreshed_issue = %Issue{
      id: "blocked-2",
      identifier: "MT-1005",
      title: "Stale blocked work",
      state: "Todo",
      blocked_by: [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
    }

    fetcher = fn ["blocked-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, %Issue{} = skipped_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)

    assert skipped_issue.identifier == "MT-1005"
    assert skipped_issue.blocked_by == [%{id: "blocker-3", identifier: "MT-1006", state: "In Progress"}]
  end

  test "dispatch revalidation skips an issue after a required label is removed" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: ["symphony"])

    stale_issue = %Issue{
      id: "unlabeled-2",
      identifier: "MT-1009",
      title: "Initially opted in",
      state: "Todo",
      labels: ["symphony"]
    }

    refreshed_issue = %{stale_issue | labels: []}
    fetcher = fn ["unlabeled-2"] -> {:ok, [refreshed_issue]} end

    assert {:skip, ^refreshed_issue} =
             Orchestrator.revalidate_issue_for_dispatch_for_test(stale_issue, fetcher)
  end

  test "workspace remove returns error information for missing directory" do
    random_path = Path.join(Config.settings!().workspace.root, "MT-MISSING")

    assert {:ok, []} = Workspace.remove(random_path)
  end

  test "bound removal uses the captured canonical root after workflow root reload" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-bound-removal-#{System.unique_integer([:positive])}"
      )

    try do
      first_root = Path.join(test_root, "first")
      second_root = Path.join(test_root, "second")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: first_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-BOUND")
      canonical_first_root = Config.settings!().workspace.root

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: second_root)

      assert {:error, {:workspace_outside_root, ^workspace, _current_root}, ""} =
               Workspace.remove(workspace)

      assert {:ok, [_removed]} = Workspace.remove_bound(workspace, canonical_first_root)
      refute File.exists?(workspace)

      assert {:error, {:workspace_outside_root, _, ^canonical_first_root}, ""} =
               Workspace.remove_bound(Path.join(test_root, "outside"), canonical_first_root)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace hooks support multiline YAML scripts and run at lifecycle boundaries" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      before_remove_marker = Path.join(test_root, "before_remove.log")
      after_create_counter = Path.join(test_root, "after_create.count")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_after_create: "echo after_create > after_create.log\necho call >> \"#{after_create_counter}\"",
        hook_before_remove: "echo before_remove > \"#{before_remove_marker}\""
      )

      config = Config.settings!()
      assert config.hooks.after_create =~ "echo after_create > after_create.log"
      assert config.hooks.before_remove =~ "echo before_remove >"

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert File.read!(Path.join(workspace, "after_create.log")) == "after_create\n"

      assert {:ok, _workspace} = Workspace.create_for_issue("MT-HOOKS")
      assert length(String.split(String.trim(File.read!(after_create_counter)), "\n")) == 1

      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS")
      assert File.read!(before_remove_marker) == "before_remove\n"
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "echo failure && exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook fails with large output" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-large-fail-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "i=0; while [ $i -lt 3000 ]; do printf a; i=$((i+1)); done; exit 17"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-LARGE-FAIL")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-LARGE-FAIL")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "workspace remove continues when before_remove hook times out" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-hooks-timeout-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")

      File.mkdir_p!(workspace_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10,
        hook_before_remove: "sleep 1"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-HOOKS-TIMEOUT")
      assert :ok = Workspace.remove_issue_workspaces("MT-HOOKS-TIMEOUT")
      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "bound workspace removal preserves the workspace when its before_remove runner dies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-remove-runner-death-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      ready_path = Path.join(test_root, "before-remove.ready")

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_timeout_ms: 10_000,
        hook_before_remove: "printf ready > '#{ready_path}'; sleep 30"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-BEFORE-REMOVE-RUNNER-DEATH")
      hooks = Config.settings!().hooks

      removal =
        Task.async(fn ->
          Process.flag(:trap_exit, true)
          Workspace.remove_bound(workspace, workspace_root, hooks)
        end)

      assert wait_for_path(ready_path, 3_000)

      runner =
        await_supervised_child_linked_to(
          SymphonyElixir.WorkspaceHookSupervisor,
          removal.pid,
          1_000
        )

      Process.exit(runner, :kill)

      assert {:error, {:workspace_before_remove_hook_cleanup_failed, {:workspace_hook_runner_failed, "before_remove"}}, ""} =
               Task.await(removal, 5_000)

      assert File.dir?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "bound workspace removal preserves the workspace when hook supervision is unavailable" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-before-remove-supervisor-#{System.unique_integer([:positive])}"
      )

    workspace_root = Path.join(test_root, "workspaces")
    supervisor_name = SymphonyElixir.WorkspaceHookSupervisor
    supervisor = Process.whereis(supervisor_name)

    restore_supervisor_name = fn ->
      if is_pid(supervisor) and Process.alive?(supervisor) and
           is_nil(Process.whereis(supervisor_name)) do
        Process.register(supervisor, supervisor_name)
      end
    end

    on_exit(restore_supervisor_name)

    try do
      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        hook_before_remove: "printf should-not-run"
      )

      assert {:ok, workspace} = Workspace.create_for_issue("MT-BEFORE-REMOVE-NO-SUPERVISOR")
      hooks = Config.settings!().hooks
      assert is_pid(supervisor)
      assert true = Process.unregister(supervisor_name)

      expected_error =
        {:workspace_before_remove_hook_cleanup_failed, {:workspace_hook_supervisor_unavailable, "before_remove"}}

      assert {:error, ^expected_error, ""} =
               Workspace.remove_bound(workspace, workspace_root, hooks)

      assert File.dir?(workspace)
    after
      restore_supervisor_name.()
      File.rm_rf(test_root)
    end
  end

  test "codex transport settings use bounded defaults" do
    assert {:ok, settings} = Schema.parse(%{})

    assert %Codex{
             initialize_timeout_ms: 15_000,
             thread_start_timeout_ms: 30_000,
             turn_start_timeout_ms: 30_000,
             max_frame_bytes: 16_777_216,
             stderr_tail_bytes: 65_536,
             process_kill_timeout_ms: 2_000,
             overload_max_attempts: 3,
             overload_backoff_base_ms: 100,
             overload_backoff_max_ms: 2_000
           } = settings.codex
  end

  test "codex transport settings accept positive overrides" do
    assert {:ok, settings} =
             Schema.parse(%{
               codex: %{
                 max_frame_bytes: 33_554_432,
                 stderr_tail_bytes: 131_072,
                 process_kill_timeout_ms: 4_000,
                 initialize_timeout_ms: 20_000,
                 thread_start_timeout_ms: 40_000,
                 turn_start_timeout_ms: 45_000,
                 overload_max_attempts: 5,
                 overload_backoff_base_ms: 250,
                 overload_backoff_max_ms: 8_000
               }
             })

    assert %Codex{
             initialize_timeout_ms: 20_000,
             thread_start_timeout_ms: 40_000,
             turn_start_timeout_ms: 45_000,
             max_frame_bytes: 33_554_432,
             stderr_tail_bytes: 131_072,
             process_kill_timeout_ms: 4_000,
             overload_max_attempts: 5,
             overload_backoff_base_ms: 250,
             overload_backoff_max_ms: 8_000
           } = settings.codex
  end

  test "codex transport settings reject values above adapter bounds" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{codex: %{stderr_tail_bytes: 1_048_577}})

    assert message == "codex.stderr_tail_bytes must be less than or equal to 1048576"

    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{codex: %{process_kill_timeout_ms: 30_001}})

    assert message == "codex.process_kill_timeout_ms must be less than or equal to 30000"
  end

  test "codex transport settings reject every nonpositive value" do
    positive_fields = [
      :max_frame_bytes,
      :stderr_tail_bytes,
      :process_kill_timeout_ms,
      :initialize_timeout_ms,
      :thread_start_timeout_ms,
      :turn_start_timeout_ms,
      :overload_max_attempts,
      :overload_backoff_base_ms
    ]

    for field <- positive_fields, value <- [0, -1] do
      expected_error = "codex.#{field} must be greater than 0"

      assert {:error, {:invalid_workflow_config, ^expected_error}} =
               Schema.parse(%{codex: %{field => value}})
    end

    for value <- [0, -1] do
      assert {:error,
              {:invalid_workflow_config,
               "codex.overload_backoff_max_ms must be greater than or equal to " <>
                 "overload_backoff_base_ms, codex.overload_backoff_max_ms must be greater than 0"}} =
               Schema.parse(%{codex: %{overload_backoff_max_ms: value}})
    end
  end

  test "codex overload backoff base cannot exceed its maximum" do
    assert {:error,
            {:invalid_workflow_config,
             "codex.overload_backoff_max_ms must be greater than or equal to " <>
               "overload_backoff_base_ms"}} =
             Schema.parse(%{
               codex: %{
                 overload_backoff_base_ms: 501,
                 overload_backoff_max_ms: 500
               }
             })
  end

  test "codex command parsing preserves literal argv and rejects shell command forms" do
    previous_codex_bin = System.get_env("CODEX_BIN")
    on_exit(fn -> restore_env("CODEX_BIN", previous_codex_bin) end)

    executable = System.find_executable("codex")
    System.put_env("CODEX_BIN", executable)

    assert {:ok, [^executable, "--config", "model=gpt fixture", "$(touch /tmp/not-run)", "*.beam", "app-server"]} =
             Config.codex_command_argv("$CODEX_BIN --config 'model=gpt fixture' '$(touch /tmp/not-run)' '*.beam' app-server")

    for {command, reason} <- [
          {"   ", :blank},
          {"codex 'unterminated", :malformed},
          {"codex\napp-server", :forbidden_character},
          {"CODEX_HOME=/tmp codex app-server", :environment_assignment}
        ] do
      assert {:error, {:invalid_codex_command, ^reason}} = Config.codex_command_argv(command)
    end

    for operator <- [";", "&&", "||", "|", "&", ">", "2>/tmp/log", "<"] do
      assert {:error, {:invalid_codex_command, {:control_operator, 2}}} =
               Config.codex_command_argv("codex app-server #{operator}")
    end

    System.delete_env("CODEX_BIN")

    assert {:error, {:invalid_codex_command, :missing_codex_bin}} =
             Config.codex_command_argv("$CODEX_BIN app-server")

    assert {:error, {:invalid_codex_command, :executable_not_found}} =
             Config.codex_command_argv("missing-codex-executable app-server")
  end

  test "codex command limits fail closed without reflecting command content" do
    canary = "PRIVATE-CODEX-COMMAND-CANARY"

    exact_command =
      Enum.join(
        ["/bin/true", :binary.copy("a", 16_381), :binary.copy("b", 16_381), :binary.copy("c", 16_381), :binary.copy("d", 16_380)],
        " "
      )

    assert byte_size(exact_command) == 65_536
    assert {:ok, exact_argv} = Config.codex_command_argv(exact_command)
    assert length(exact_argv) == 5

    command_too_long = exact_command <> canary

    assert {:error, {:invalid_codex_command, :command_too_long} = long_error} =
             Config.codex_command_argv(command_too_long)

    refute inspect(long_error) =~ canary

    exact_argument_count = Enum.join(["/bin/true" | List.duplicate("x", 255)], " ")
    assert {:ok, exact_argv} = Config.codex_command_argv(exact_argument_count)
    assert length(exact_argv) == 256

    too_many_arguments = Enum.join(["/bin/true" | List.duplicate("x", 256)], " ")

    assert {:error, {:invalid_codex_command, :too_many_arguments}} =
             Config.codex_command_argv(too_many_arguments)

    maximum_argument = :binary.copy("x", 16_384)

    assert {:ok, [_executable, ^maximum_argument]} =
             Config.codex_command_argv("/bin/true #{maximum_argument}")

    oversized_argument = maximum_argument <> "x"

    assert {:error, {:invalid_codex_command, {:argument_too_long, 1}}} =
             Config.codex_command_argv("/bin/true #{oversized_argument}")
  end

  test "App Server request timeouts are method-specific with read timeout as the default" do
    write_workflow_file!(Workflow.workflow_file_path(),
      codex_read_timeout_ms: 101,
      codex_initialize_timeout_ms: 202,
      codex_thread_start_timeout_ms: 303,
      codex_turn_start_timeout_ms: 404
    )

    assert Config.codex_request_timeout("initialize") == 202
    assert Config.codex_request_timeout("thread/start") == 303
    assert Config.codex_request_timeout("turn/start") == 404
    assert Config.codex_request_timeout("account/read") == 101
    assert Config.codex_request_timeout("future/idempotent/read") == 101
  end

  test "Release 0 validation rejects configured remote workers until Release 5" do
    write_workflow_file!(Workflow.workflow_file_path(), worker_ssh_hosts: ["worker-01:2200"])

    assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} = Config.validate!()
  end

  test "orchestrator startup cleanup cannot cross the Release 5 remote worker gate" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup-remote-gate-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      printf 'SSH_INVOKED\n' >> "$SYMP_TEST_SSH_TRACE"
      exit 99
      """)

      File.chmod!(fake_ssh, 0o755)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %SymphonyElixir.Linear.Issue{
          id: "terminal-remote-gate",
          identifier: "MT-REMOTE-GATE",
          state: "Done"
        }
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-01:2200"]
      )

      assert {:error, {:unsupported_release_feature, :remote_workers, :release_5}} =
               Config.validate!()

      orchestrator_name = Module.concat(__MODULE__, :RemoteGateOrchestrator)
      assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator startup cleanup still removes terminal local workspaces after validation" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-startup-local-cleanup-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      assert {:ok, workspace} = Workspace.create_for_issue("MT-VALID-CLEANUP")
      assert File.dir?(workspace)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %SymphonyElixir.Linear.Issue{
          id: "terminal-valid-cleanup",
          identifier: "MT-VALID-CLEANUP",
          state: "Done"
        }
      ])

      orchestrator_name = Module.concat(__MODULE__, :ValidStartupCleanupOrchestrator)
      assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      refute File.exists?(workspace)
    after
      File.rm_rf(test_root)
    end
  end

  test "orchestrator hot reload validates the remote gate before cleanup and retry side effects" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-hot-reload-remote-gate-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      local_workspace_root = Path.join(test_root, "local-workspaces")

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      printf 'SSH_INVOKED\n' >> "$SYMP_TEST_SSH_TRACE"
      exit 99
      """)

      File.chmod!(fake_ssh, 0o755)
      Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: local_workspace_root)

      orchestrator_name = Module.concat(__MODULE__, :HotReloadRemoteGateOrchestrator)
      assert {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      end)

      blocked_issue = %SymphonyElixir.Linear.Issue{
        id: "blocked-remote-gate",
        identifier: "MT-BLOCKED-REMOTE-GATE",
        state: "In Progress"
      }

      retry_issue = %SymphonyElixir.Linear.Issue{
        id: "retry-remote-gate",
        identifier: "MT-RETRY-REMOTE-GATE",
        state: "In Progress"
      }

      retry_token = make_ref()
      initial_state = :sys.get_state(pid)

      :sys.replace_state(pid, fn _state ->
        %{
          initial_state
          | blocked: %{
              blocked_issue.id => %{
                identifier: blocked_issue.identifier,
                issue: blocked_issue,
                worker_host: nil
              }
            },
            claimed: MapSet.new([blocked_issue.id, retry_issue.id]),
            retry_attempts: %{
              retry_issue.id => %{
                attempt: 1,
                due_at_ms: System.monotonic_time(:millisecond),
                error: "pending retry",
                identifier: retry_issue.identifier,
                issue_url: nil,
                retry_token: retry_token,
                timer_ref: nil,
                worker_host: nil,
                workspace_path: nil
              }
            }
        }
      end)

      Application.put_env(:symphony_elixir, :memory_tracker_issues, [
        %{blocked_issue | state: "Done"},
        %{retry_issue | state: "Done"}
      ])

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-01:2200"]
      )

      log =
        capture_log(fn ->
          send(pid, :run_poll_cycle)
          assert is_map(Orchestrator.snapshot(orchestrator_name, 1_000))
        end)

      state_after_poll = :sys.get_state(pid)

      assert log =~ "WORKFLOW.md validation failed failure_kind=unsupported_release_feature"
      refute log =~ "Failed to fetch from tracker"
      refute log =~ "remote_workers"
      refute log =~ "release_5"
      assert Map.has_key?(state_after_poll.blocked, blocked_issue.id)
      refute File.exists?(trace_file)

      send(pid, {:retry_issue, retry_issue.id, retry_token})
      state_after_retry = :sys.get_state(pid)

      assert Map.has_key?(state_after_retry.retry_attempts, retry_issue.id)
      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  test "config reads defaults for optional settings" do
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", previous_linear_api_key) end)
    System.delete_env("LINEAR_API_KEY")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_endpoint: nil,
      workspace_root: nil,
      max_concurrent_agents: nil,
      codex_approval_policy: nil,
      codex_thread_sandbox: nil,
      codex_turn_sandbox_policy: nil,
      codex_turn_timeout_ms: nil,
      codex_read_timeout_ms: nil,
      codex_initialize_timeout_ms: nil,
      codex_thread_start_timeout_ms: nil,
      codex_turn_start_timeout_ms: nil,
      codex_stall_timeout_ms: nil,
      tracker_api_token: nil,
      tracker_project_slug: nil
    )

    config = Config.settings!()
    assert config.tracker.endpoint == "https://api.linear.app/graphql"
    assert config.tracker.api_key == nil
    assert config.tracker.project_slug == nil
    assert config.tracker.required_labels == []
    assert config.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
    assert config.worker.max_concurrent_agents_per_host == nil
    assert config.agent.max_concurrent_agents == 10
    assert config.codex.command == "codex app-server"

    assert config.codex.approval_policy == %{
             "granular" => %{
               "sandbox_approval" => false,
               "rules" => false,
               "mcp_elicitations" => false,
               "skill_approval" => false,
               "request_permissions" => false
             }
           }

    assert config.codex.thread_sandbox == "workspace-write"

    assert {:ok, canonical_default_workspace_root} =
             SymphonyElixir.PathSafety.canonicalize(Path.join(System.tmp_dir!(), "symphony_workspaces"))

    assert Config.codex_turn_sandbox_policy() == %{
             "type" => "workspaceWrite",
             "writableRoots" => [canonical_default_workspace_root],
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert config.codex.turn_timeout_ms == 3_600_000
    assert config.codex.read_timeout_ms == 5_000
    assert config.codex.initialize_timeout_ms == 15_000
    assert config.codex.thread_start_timeout_ms == 30_000
    assert config.codex.turn_start_timeout_ms == 30_000
    assert config.codex.stall_timeout_ms == 300_000

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_required_labels: [" Symphony ", "SYMPHONY", "JavaScript"]
    )

    assert Config.settings!().tracker.required_labels == ["symphony", "javascript"]

    write_workflow_file!(Workflow.workflow_file_path(), tracker_required_labels: [" "])
    assert Config.settings!().tracker.required_labels == [""]

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_command: "codex --config 'model=\"gpt-5.5\"' app-server"
    )

    assert Config.settings!().codex.command ==
             "codex --config 'model=\"gpt-5.5\"' app-server"

    explicit_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-explicit-sandbox-root-#{System.unique_integer([:positive])}"
      )

    explicit_workspace = Path.join(explicit_root, "MT-EXPLICIT")
    explicit_cache = Path.join(explicit_workspace, "cache")
    File.mkdir_p!(explicit_cache)

    on_exit(fn -> File.rm_rf(explicit_root) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: explicit_root,
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "workspace-write",
      codex_turn_sandbox_policy: %{
        type: "workspaceWrite",
        writableRoots: [explicit_workspace, explicit_cache]
      }
    )

    config = Config.settings!()
    assert config.codex.approval_policy == "on-request"
    assert config.codex.thread_sandbox == "workspace-write"

    assert Config.codex_turn_sandbox_policy(explicit_workspace) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [explicit_workspace, explicit_cache]
           }

    write_workflow_file!(Workflow.workflow_file_path(), tracker_active_states: ",")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "tracker.active_states"

    write_workflow_file!(Workflow.workflow_file_path(), max_concurrent_agents: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "agent.max_concurrent_agents"

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 0)
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "worker.max_concurrent_agents_per_host"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_read_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.read_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_initialize_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.initialize_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_start_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_start_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_start_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_start_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(), codex_stall_timeout_ms: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.stall_timeout_ms"

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_active_states: %{todo: true},
      tracker_terminal_states: %{done: true},
      poll_interval_ms: %{bad: true},
      workspace_root: 123,
      max_retry_backoff_ms: 0,
      max_concurrent_agents_by_state: %{"Todo" => "1", "Review" => 0, "Done" => "bad"},
      hook_timeout_ms: 0,
      observability_enabled: "maybe",
      observability_refresh_ms: %{bad: true},
      observability_render_interval_ms: %{bad: true},
      server_port: -1,
      server_host: 123
    )

    assert {:error, {:invalid_workflow_config, _message}} = Config.validate!()

    write_workflow_file!(Workflow.workflow_file_path(), codex_approval_policy: "")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.approval_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_thread_sandbox: "")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"

    write_workflow_file!(Workflow.workflow_file_path(), codex_turn_sandbox_policy: "bad")
    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(),
      codex_approval_policy: "on-request",
      codex_thread_sandbox: "future-sandbox",
      codex_turn_sandbox_policy: %{type: "futureSandbox"}
    )

    assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
    assert message =~ "codex.thread_sandbox"
    assert message =~ "codex.turn_sandbox_policy"

    write_workflow_file!(Workflow.workflow_file_path(), codex_command: "codex app-server")
    assert Config.settings!().codex.command == "codex app-server"
  end

  test "config resolves $VAR references for env-backed secret and path values" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"
    codex_bin = Path.join(["~", "bin", "codex"])

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "$#{api_key_env_var}",
      workspace_root: "$#{workspace_env_var}",
      codex_command: "#{codex_bin} app-server"
    )

    config = Config.settings!()
    assert config.tracker.api_key == api_key
    assert config.workspace.root == Path.expand(workspace_root)
    assert config.codex.command == "#{codex_bin} app-server"
  end

  test "config no longer resolves legacy env: references" do
    workspace_env_var = "SYMP_WORKSPACE_ROOT_#{System.unique_integer([:positive])}"
    api_key_env_var = "SYMP_LINEAR_API_KEY_#{System.unique_integer([:positive])}"
    workspace_root = Path.join("/tmp", "symphony-workspace-root")
    api_key = "resolved-secret"

    previous_workspace_root = System.get_env(workspace_env_var)
    previous_api_key = System.get_env(api_key_env_var)

    System.put_env(workspace_env_var, workspace_root)
    System.put_env(api_key_env_var, api_key)

    on_exit(fn ->
      restore_env(workspace_env_var, previous_workspace_root)
      restore_env(api_key_env_var, previous_api_key)
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_api_token: "env:#{api_key_env_var}",
      workspace_root: "env:#{workspace_env_var}"
    )

    config = Config.settings!()
    assert config.tracker.api_key == "env:#{api_key_env_var}"

    assert config.workspace.root ==
             Path.join(Workflow.workflow_directory(), "env:#{workspace_env_var}")
  end

  test "relative workspace roots resolve against the selected WORKFLOW.md directory" do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: "state/workspaces")

    assert Config.settings!().workspace.root ==
             Path.join(Workflow.workflow_directory(), "state/workspaces")

    changed_cwd = Path.join(System.tmp_dir!(), "symphony-unrelated-cwd")
    File.mkdir_p!(changed_cwd)
    original_cwd = File.cwd!()

    try do
      File.cd!(changed_cwd)

      assert Config.settings!().workspace.root ==
               Path.join(Workflow.workflow_directory(), "state/workspaces")
    after
      File.cd!(original_cwd)
      File.rm_rf(changed_cwd)
    end
  end

  test "config supports per-state max concurrent agent overrides" do
    workflow = """
    ---
    agent:
      max_concurrent_agents: 10
      max_concurrent_agents_by_state:
        todo: 1
        "In Progress": 4
        "In Review": 2
    ---
    """

    File.write!(Workflow.workflow_file_path(), workflow)

    assert Config.settings!().agent.max_concurrent_agents == 10
    assert Config.max_concurrent_agents_for_state("Todo") == 1
    assert Config.max_concurrent_agents_for_state("In Progress") == 4
    assert Config.max_concurrent_agents_for_state("In Review") == 2
    assert Config.max_concurrent_agents_for_state("Closed") == 10
    assert Config.max_concurrent_agents_for_state(:not_a_string) == 10

    write_workflow_file!(Workflow.workflow_file_path(), worker_max_concurrent_agents_per_host: 2)
    assert :ok = Config.validate!()
    assert Config.settings!().worker.max_concurrent_agents_per_host == 2
  end

  test "schema helpers cover custom type and state limit validation" do
    assert StringOrMap.type() == :map
    assert StringOrMap.embed_as(:json) == :self
    assert StringOrMap.equal?(%{"a" => 1}, %{"a" => 1})
    refute StringOrMap.equal?(%{"a" => 1}, %{"a" => 2})

    assert {:ok, "value"} = StringOrMap.cast("value")
    assert {:ok, %{"a" => 1}} = StringOrMap.cast(%{"a" => 1})
    assert :error = StringOrMap.cast(123)

    assert {:ok, "value"} = StringOrMap.load("value")
    assert :error = StringOrMap.load(123)

    assert {:ok, %{"a" => 1}} = StringOrMap.dump(%{"a" => 1})
    assert :error = StringOrMap.dump(123)

    assert Schema.normalize_state_limits(nil) == %{}

    assert Schema.normalize_state_limits(%{"In Progress" => 2, todo: 1}) == %{
             "todo" => 1,
             "in progress" => 2
           }

    changeset =
      {%{}, %{limits: :map}}
      |> Changeset.cast(%{limits: %{"" => 1, "todo" => 0}}, [:limits])
      |> Schema.validate_state_limits(:limits)

    assert MapSet.new(changeset.errors) ==
             MapSet.new(
               limits: {"state names must not be blank", []},
               limits: {"limits must be positive integers", []}
             )
  end

  test "schema parse normalizes policy keys and env-backed fallbacks" do
    missing_workspace_env = "SYMP_MISSING_WORKSPACE_#{System.unique_integer([:positive])}"
    empty_secret_env = "SYMP_EMPTY_SECRET_#{System.unique_integer([:positive])}"
    missing_secret_env = "SYMP_MISSING_SECRET_#{System.unique_integer([:positive])}"

    previous_missing_workspace_env = System.get_env(missing_workspace_env)
    previous_empty_secret_env = System.get_env(empty_secret_env)
    previous_missing_secret_env = System.get_env(missing_secret_env)
    previous_linear_api_key = System.get_env("LINEAR_API_KEY")

    System.delete_env(missing_workspace_env)
    System.put_env(empty_secret_env, "")
    System.delete_env(missing_secret_env)
    System.put_env("LINEAR_API_KEY", "fallback-linear-token")

    on_exit(fn ->
      restore_env(missing_workspace_env, previous_missing_workspace_env)
      restore_env(empty_secret_env, previous_empty_secret_env)
      restore_env(missing_secret_env, previous_missing_secret_env)
      restore_env("LINEAR_API_KEY", previous_linear_api_key)
    end)

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{empty_secret_env}"},
               workspace: %{root: "$#{missing_workspace_env}"},
               codex: %{approval_policy: %{reject: %{sandbox_approval: true}}}
             })

    assert settings.tracker.api_key == nil
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")

    assert settings.codex.approval_policy == %{
             "granular" => %{
               "sandbox_approval" => false,
               "rules" => true,
               "mcp_elicitations" => true,
               "skill_approval" => false,
               "request_permissions" => false
             }
           }

    assert {:ok, alias_settings} =
             Schema.parse(%{codex: %{approval_policy: "on-failure"}})

    assert alias_settings.codex.approval_policy == "on-request"

    assert {:ok, settings} =
             Schema.parse(%{
               tracker: %{api_key: "$#{missing_secret_env}"},
               workspace: %{root: ""}
             })

    assert settings.tracker.api_key == "fallback-linear-token"
    assert settings.workspace.root == Path.join(System.tmp_dir!(), "symphony_workspaces")
  end

  test "schema resolves sandbox policies from explicit and default workspaces" do
    explicit_policy = %{"type" => "workspaceWrite", "writableRoots" => ["/tmp/explicit"]}

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: explicit_policy},
             workspace: %Schema.Workspace{root: "/tmp/ignored"}
           }) == explicit_policy

    assert Schema.resolve_turn_sandbox_policy(%Schema{
             codex: %Codex{turn_sandbox_policy: nil},
             workspace: %Schema.Workspace{root: ""}
           }) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))],
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert Schema.resolve_turn_sandbox_policy(
             %Schema{
               codex: %Codex{turn_sandbox_policy: nil},
               workspace: %Schema.Workspace{root: "/tmp/ignored"}
             },
             "/tmp/workspace"
           ) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("/tmp/workspace")],
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    invalid_settings = %Schema{
      codex: %Codex{turn_sandbox_policy: %{"type" => "futureSandbox"}},
      workspace: %Schema.Workspace{root: "/tmp/ignored"}
    }

    assert_raise ArgumentError, ~r/invalid explicit Codex turn sandbox policy/, fn ->
      Schema.resolve_turn_sandbox_policy(invalid_settings)
    end
  end

  test "schema canonicalizes workspace roots before sandbox resolution" do
    assert {:ok, settings} =
             Schema.parse(%{
               workspace: %{root: "~/.symphony-workspaces"},
               codex: %{}
             })

    assert settings.workspace.root == Path.expand("~/.symphony-workspaces")

    assert Schema.resolve_turn_sandbox_policy(settings) == %{
             "type" => "workspaceWrite",
             "writableRoots" => [Path.expand("~/.symphony-workspaces")],
             "networkAccess" => false,
             "excludeTmpdirEnvVar" => false,
             "excludeSlashTmp" => false
           }

    assert {:ok, remote_policy} =
             Schema.resolve_runtime_turn_sandbox_policy(settings, nil, remote: true)

    assert remote_policy["writableRoots"] == [Path.expand("~/.symphony-workspaces")]
  end

  test "runtime sandbox policy resolution normalizes valid explicit policies and rejects invented ones" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-100")
      unnormalized_cache = issue_workspace <> "/cache/../cache"
      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [unnormalized_cache],
          networkAccess: true
        }
      )

      assert {:ok, runtime_settings} = Config.codex_runtime_settings(issue_workspace)

      assert runtime_settings.turn_sandbox_policy == %{
               "type" => "workspaceWrite",
               "writableRoots" => [Path.expand(unnormalized_cache)],
               "networkAccess" => true
             }

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{type: "futureSandbox"}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "codex.turn_sandbox_policy"

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{type: "workspaceWrite", writableRoots: ["relative/path"]}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "writableRoots"
    after
      File.rm_rf(test_root)
    end
  end

  test "managed runtime sandbox narrows writable roots and preserves explicit network opt-in" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-sandbox-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-MANAGED")
      unrelated_root = Path.join(test_root, "unrelated")
      File.mkdir_p!(issue_workspace)
      File.mkdir_p!(unrelated_root)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: workspace_root,
        codex_turn_sandbox_policy: %{
          type: "workspaceWrite",
          writableRoots: [workspace_root, unrelated_root],
          networkAccess: true
        }
      )

      settings = Config.settings!()

      assert {:ok, upstream_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, issue_workspace)

      assert upstream_policy["writableRoots"] == [workspace_root, unrelated_root]

      assert {:ok, managed_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, issue_workspace, managed: true)

      assert managed_policy["writableRoots"] == [issue_workspace]
      assert managed_policy["networkAccess"] == true

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      default_settings = Config.settings!()

      assert {:ok, default_managed_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(default_settings, issue_workspace, managed: true)

      assert default_managed_policy["writableRoots"] == [issue_workspace]
      assert default_managed_policy["networkAccess"] == false
    after
      File.rm_rf(test_root)
    end
  end

  test "managed runtime sandbox rejects broad variants and issue-leaf symlinks" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-sandbox-denial-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-LINK")
      target_workspace = Path.join(workspace_root, "TARGET")
      File.mkdir_p!(target_workspace)
      File.ln_s!(target_workspace, issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      assert {:error, {:unsafe_turn_sandbox_policy, {:managed_workspace_symlink, ^issue_workspace}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, issue_workspace, managed: true)

      broad_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "dangerFullAccess"}}
      }

      assert {:error, {:unsafe_turn_sandbox_policy, {:managed_policy_type, "dangerFullAccess"}}} =
               Schema.resolve_runtime_turn_sandbox_policy(broad_settings, target_workspace, managed: true)

      assert {:error, {:unsafe_turn_sandbox_policy, :managed_remote_workspace_unsupported}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, issue_workspace,
                 managed: true,
                 remote: true
               )
    after
      File.rm_rf(test_root)
    end
  end

  test "managed runtime sandbox handles read-only and invalid workspace shapes fail closed" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-managed-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      missing_workspace = Path.join(workspace_root, "MT-MISSING")
      nested_workspace = Path.join([workspace_root, "nested", "MT-NESTED"])
      File.mkdir_p!(nested_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
      settings = Config.settings!()

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly"}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => false}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 read_only_settings,
                 missing_workspace,
                 managed: true
               )

      assert {:error, {:unsafe_turn_sandbox_policy, {:managed_workspace_unreadable, :enoent}}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 settings,
                 missing_workspace,
                 managed: true
               )

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_managed_workspace, ^nested_workspace}}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 settings,
                 nested_workspace,
                 managed: true
               )

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_managed_workspace, nil}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, nil, managed: true)
    after
      File.rm_rf(test_root)
    end
  end

  test "schema reports atom and classified workspace canonicalization errors" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-workspace-root-errors-#{System.unique_integer([:positive])}"
      )

    try do
      File.mkdir_p!(test_root)
      overlong_root = Path.join(test_root, String.duplicate("a", 300))

      assert {:error, {:invalid_workflow_config, overlong_message}} =
               Schema.parse(%{workspace: %{root: overlong_root}})

      assert overlong_message =~
               "workspace.root could not be canonicalized: enametoolong"

      first = Path.join(test_root, "first")
      second = Path.join(test_root, "second")
      File.ln_s!(second, first)
      File.ln_s!(first, second)

      assert {:error, {:invalid_workflow_config, loop_message}} =
               Schema.parse(%{workspace: %{root: first}})

      assert loop_message =~
               "workspace.root could not be canonicalized: symlink_loop"
    after
      File.rm_rf(test_root)
    end
  end

  test "granular approval policy validation accepts boolean maps and rejects other shapes" do
    assert Schema.validate_approval_policy(
             :approval_policy,
             %{
               "granular" => %{
                 "sandbox_approval" => false,
                 "rules" => true,
                 "mcp_elicitations" => false,
                 "skill_approval" => true,
                 "request_permissions" => false
               }
             }
           ) == []

    assert Schema.validate_approval_policy(
             :approval_policy,
             %{"granular" => "never"}
           ) ==
             [approval_policy: "approval policy flags must be a map"]
  end

  test "path safety returns errors for invalid path segments" do
    invalid_segment = String.duplicate("a", 300)
    path = Path.join(System.tmp_dir!(), invalid_segment)
    expanded_path = Path.expand(path)

    assert {:error, {:path_canonicalize_failed, ^expanded_path, :enametoolong}} =
             SymphonyElixir.PathSafety.canonicalize(path)
  end

  test "runtime sandbox policy resolution defaults when omitted and ignores workspace for explicit policies" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-runtime-sandbox-branches-#{System.unique_integer([:positive])}"
      )

    try do
      workspace_root = Path.join(test_root, "workspaces")
      issue_workspace = Path.join(workspace_root, "MT-101")

      File.mkdir_p!(issue_workspace)

      write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)

      settings = Config.settings!()

      assert {:ok, canonical_workspace_root} =
               SymphonyElixir.PathSafety.canonicalize(workspace_root)

      assert {:ok, default_policy} = Schema.resolve_runtime_turn_sandbox_policy(settings)
      assert default_policy["type"] == "workspaceWrite"
      assert default_policy["writableRoots"] == [canonical_workspace_root]

      assert {:ok, blank_workspace_policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, "")

      assert blank_workspace_policy == default_policy

      read_only_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "readOnly", "networkAccess" => true}}
      }

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, "~", "must contain only non-empty absolute paths"}}} =
               Schema.resolve_runtime_turn_sandbox_policy(read_only_settings, "~", remote: true)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, "/tmp/work/../escape", "must be normalized"}}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 read_only_settings,
                 "/tmp/work/../escape",
                 remote: true
               )

      assert {:ok, %{"type" => "readOnly", "networkAccess" => true}} =
               Schema.resolve_runtime_turn_sandbox_policy(
                 read_only_settings,
                 "/tmp/remote-workspace",
                 remote: true
               )

      future_settings = %{
        settings
        | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "futureSandbox", "nested" => %{"flag" => true}}}
      }

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_explicit_policy, _reason}}} =
               Schema.resolve_runtime_turn_sandbox_policy(future_settings, 123)

      assert {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, 123}}} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, 123)
    after
      File.rm_rf(test_root)
    end
  end

  test "pinned sandbox variants accept exact atom or string keyed shapes" do
    assert {:error, "must match the pinned Codex turn sandbox policy contract"} =
             Schema.normalize_turn_sandbox_policy("readOnly")

    assert {:ok, danger} = Schema.parse(%{codex: %{thread_sandbox: "danger-full-access", turn_sandbox_policy: %{type: "dangerFullAccess"}}})
    assert danger.codex.turn_sandbox_policy == %{"type" => "dangerFullAccess"}

    assert {:ok, read_only} =
             Schema.parse(%{
               "codex" => %{
                 "thread_sandbox" => "read-only",
                 "turn_sandbox_policy" => %{"type" => "readOnly", "networkAccess" => true}
               }
             })

    assert read_only.codex.turn_sandbox_policy == %{"type" => "readOnly", "networkAccess" => true}

    assert {:ok, external} =
             Schema.parse(%{
               codex: %{
                 thread_sandbox: "workspace-write",
                 turn_sandbox_policy: %{type: "externalSandbox", networkAccess: "restricted"}
               }
             })

    assert external.codex.turn_sandbox_policy == %{
             "type" => "externalSandbox",
             "networkAccess" => "restricted"
           }

    assert {:ok, %{"type" => "externalSandbox"}} =
             Schema.normalize_turn_sandbox_policy(%{"type" => "externalSandbox"})

    assert {:ok, %{"type" => "workspaceWrite"}} =
             Schema.normalize_turn_sandbox_policy(%{"type" => "workspaceWrite"})

    invalid_policies = [
      %{"type" => "dangerFullAccess", "networkAccess" => false},
      %{"type" => "readOnly", "networkAccess" => "enabled"},
      %{"type" => "externalSandbox", "networkAccess" => "open"},
      %{"type" => "workspaceWrite", "writableRoots" => ["relative"]},
      %{"type" => "workspaceWrite", "writableRoots" => [123]},
      %{"type" => "workspaceWrite", "writableRoots" => "/tmp"},
      %{"type" => "workspaceWrite", "excludeSlashTmp" => "false"},
      %{"type" => "workspaceWrite", "invented" => true}
    ]

    Enum.each(invalid_policies, fn policy ->
      assert {:error, {:invalid_workflow_config, message}} =
               Schema.parse(%{codex: %{turn_sandbox_policy: policy}})

      assert message =~ "codex.turn_sandbox_policy"
    end)
  end

  test "workflow prompt is used when building base prompt" do
    workflow_prompt = "Workflow prompt body used as codex instruction."

    write_workflow_file!(Workflow.workflow_file_path(), prompt: workflow_prompt)
    assert Config.workflow_prompt() == workflow_prompt
  end

  test "every remote workspace API fails at the Release 5 gate before SSH" do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-elixir-remote-workspace-#{System.unique_integer([:positive])}"
      )

    previous_path = System.get_env("PATH")
    previous_trace = System.get_env("SYMP_TEST_SSH_TRACE")

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_SSH_TRACE", previous_trace)
    end)

    try do
      trace_file = Path.join(test_root, "ssh.trace")
      fake_ssh = Path.join(test_root, "ssh")
      workspace_path = "/remote/home/.symphony-remote-workspaces/MT-SSH-WS"
      release_error = {:unsupported_release_feature, :remote_workers, :release_5}

      File.mkdir_p!(test_root)
      System.put_env("SYMP_TEST_SSH_TRACE", trace_file)
      System.put_env("PATH", test_root <> ":" <> (previous_path || ""))

      File.write!(fake_ssh, """
      #!/bin/sh
      printf 'SSH_INVOKED\\n' >> "$SYMP_TEST_SSH_TRACE"
      exit 99
      """)

      File.chmod!(fake_ssh, 0o755)

      write_workflow_file!(Workflow.workflow_file_path(),
        workspace_root: "~/.symphony-remote-workspaces",
        worker_ssh_hosts: ["worker-01:2200"],
        hook_before_run: "echo before-run",
        hook_after_run: "echo after-run",
        hook_before_remove: "echo before-remove"
      )

      assert Config.settings!().worker.ssh_hosts == ["worker-01:2200"]

      assert {:error, ^release_error} =
               Workspace.create_for_issue("MT-SSH-WS", "worker-01:2200")

      assert {:error, ^release_error} =
               Workspace.run_before_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")

      assert {:error, ^release_error} =
               Workspace.run_after_run_hook(workspace_path, "MT-SSH-WS", "worker-01:2200")

      assert {:error, ^release_error, ""} = Workspace.remove(workspace_path, "worker-01:2200")

      assert {:error, ^release_error} =
               Workspace.remove_issue_workspaces("MT-SSH-WS", "worker-01:2200")

      refute File.exists?(trace_file)
    after
      File.rm_rf(test_root)
    end
  end

  defp wait_for_path(path, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    wait_for_path_until(path, deadline_ms)
  end

  defp linear_issue_payload(issue_id) do
    %{
      "id" => issue_id,
      "identifier" => "MT-PARTIAL",
      "title" => "Partial GraphQL issue",
      "description" => "Must be rejected when top-level errors are present",
      "priority" => 1,
      "state" => %{"name" => "Todo"},
      "labels" => %{"nodes" => [%{"name" => "symphony"}]},
      "inverseRelations" => %{"nodes" => []},
      "createdAt" => "2026-07-17T00:00:00Z",
      "updatedAt" => "2026-07-17T00:00:00Z"
    }
  end

  defp await_supervised_child_linked_to(supervisor, owner, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    do_await_supervised_child_linked_to(supervisor, owner, deadline_ms)
  end

  defp do_await_supervised_child_linked_to(supervisor, owner, deadline_ms) do
    child =
      supervisor
      |> Task.Supervisor.children()
      |> Enum.find(fn child ->
        case Process.info(child, :links) do
          {:links, links} -> owner in links
          nil -> false
        end
      end)

    cond do
      is_pid(child) ->
        child

      System.monotonic_time(:millisecond) >= deadline_ms ->
        flunk("timed out waiting for supervised child linked to #{inspect(owner)}")

      true ->
        Process.sleep(10)
        do_await_supervised_child_linked_to(supervisor, owner, deadline_ms)
    end
  end

  defp wait_for_path_until(path, deadline_ms) do
    cond do
      File.exists?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline_ms ->
        false

      true ->
        Process.sleep(20)
        wait_for_path_until(path, deadline_ms)
    end
  end
end
