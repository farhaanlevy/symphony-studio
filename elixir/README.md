<!-- Downstream modification notice (2026-07-16): Symphony Studio documents
its pinned Codex contract, hardened process boundary, and additive runtime,
event, and operation correlation behavior. -->

# Symphony Elixir

This directory contains the current Elixir/OTP implementation of Symphony, based on
[`SPEC.md`](../SPEC.md) at the repository root.

> [!WARNING]
> Symphony Elixir is prototype software intended for evaluation only and is presented as-is.
> We recommend implementing your own hardened version based on `SPEC.md`.

## Screenshot

![Symphony Elixir screenshot](../.github/media/elixir-screenshot.png)

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Codex in [App Server mode](https://developers.openai.com/codex/app-server/) inside the
   workspace
4. Sends a workflow prompt to Codex
5. Keeps Codex working on the issue until the work is done

During app-server sessions, Symphony also serves a client-side `linear_graphql` tool so that repo
skills can make raw Linear GraphQL calls.

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

If Codex reports that operator input, approval, or MCP elicitation is required, Symphony keeps the
issue claimed and exposes it as blocked in the runtime state, JSON API, and dashboard. Blocked
entries are in memory only; restarting the orchestrator clears that blocked map, so any still-active
Linear issue can become a dispatch candidate again after restart.

### Runtime correlation and the Release 0 event boundary

Symphony assigns a `run_id` when an issue is admitted. That ID remains stable
across continuation and failure retries while the issue claim is retained. An
`attempt_id` is assigned only when a worker process is actually launched;
tracker, configuration, capacity, and timer deferrals do not create attempts.
Releasing the claim and later admitting the issue starts a new run.

Each prepared App Server or dynamic-tool operation receives a distinct logical
`operation_id` before transport. This is separate from the JSON-RPC request ID:
the logical ID remains stable when a bounded idempotent read receives a new wire
request ID, and it follows an uncertain outcome for reconciliation. Two
intentional calls receive different logical IDs even when their method and
parameters are identical.

Release 0 exposes an injectable normalized-event boundary. The default sink
retains nothing, preserving the ability to run the Symphony engine without
Studio persistence. The optional memory adapter is bounded and process-local;
it supports ordered cursor replay for tests and in-process consumers but is not
durable and does not survive restart. Durable persistence, restart replay, and
browser reconnect replay begin in Release 1.

## How to use it

1. Make sure your codebase is set up to work well with agents: see
   [Harness engineering](https://openai.com/index/harness-engineering/).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Copy this directory's `WORKFLOW.md` to your repo.
4. Optionally copy the `commit`, `push`, `pull`, `land`, and `linear` skills to your repo.
   - The `linear` skill expects Symphony's `linear_graphql` app-server tool for raw Linear GraphQL
     operations such as comment editing or upload flows.
5. Customize the copied `WORKFLOW.md` file for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
   - When creating a workflow based on this repo, note that it depends on non-standard Linear
     issue statuses: "Rework", "Human Review", and "Merging". You can customize them in
     Team Settings → Workflow in Linear.
6. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.
The complete quality gate also requires Python 3.10 or newer and the exact
Codex CLI version pinned by the repository (`0.144.3`).

The checked-in R0-02 Codex bundle is locked to Linux x86_64. Its fail-closed
schema and fixture gate also requires Linux procfs, `prctl` child-subreaper
support, pidfds and `waitid`, inotify, `renameat2(RENAME_EXCHANGE)`, no-follow
descriptor opens, and durable file/directory `fsync`. `make all` reports a
hard error when one of these containment or publication guarantees is absent;
it does not silently run a weaker verifier.

R0-03 local process containment additionally requires util-linux `unshare`,
unprivileged user namespaces, PID and mount namespaces, and a procfs mount
inside the new PID namespace. Startup probes the exact supported form:
`unshare --user --map-current-user --pid --fork` with
`--kill-child=SIGKILL --mount-proc`. Python must provide `os.pidfd_open`,
`signal.pidfd_send_signal`, and `ctypes` access to libc `prctl`. The validated
reference host is Debian 12 x86_64 with Linux 6.1, util-linux 2.38.1, and
Python 3.11.2. Other Linux distributions are supported only when the same
probe and the pinned live Codex conformance smoke pass. Disabled namespaces,
missing pidfds, or missing helpers fail closed before target code is released;
there is no weaker process-group-only fallback. Workloads that manipulate
supplementary group identities need separate compatibility proof even though
ordinary host filesystem permission checks remain effective.

```bash
mise install
mise exec -- elixir --version
python3 --version
npm install --global @openai/codex@0.144.3
codex --version
python3 ../scripts/codex_schema.py verify --installed
```

The final command checks the installed launcher and native executable against
[`CODEX_LOCK.json`](../CODEX_LOCK.json), not only the version string. The test
profile uses Xema 0.17.9 and its transitive `conv_case` 0.2.3 dependency; both
are MIT-licensed and are not runtime dependencies. Comprehensive SBOM and
third-party-notice packaging is a Release 0 R0-07 gate.

## Run

```bash
git clone https://github.com/farhaanlevy/symphony-studio.git
cd symphony-studio/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Codex session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  project_slug: "..."
workspace:
  root: ~/code/workspaces
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
agent:
  max_concurrent_agents: 10
  max_turns: 20
codex:
  command: codex app-server
---

You are working on a Linear issue {{ issue.identifier }}.

Title: {{ issue.title }} Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- `tracker.required_labels` is optional. When set, an issue must have every
  configured label to dispatch or continue running. Label matching ignores
  case and surrounding whitespace. A blank configured label matches no issue.
- Safer Codex defaults are used when policy fields are omitted:
  - `codex.approval_policy` defaults to `{"granular":{"sandbox_approval":false,"rules":false,"mcp_elicitations":false,"skill_approval":false,"request_permissions":false}}`
  - `codex.thread_sandbox` defaults to `workspace-write`
  - `codex.turn_sandbox_policy` defaults to a `workspaceWrite` policy rooted at the current issue workspace
- The pinned Codex `0.144.3` wire contract accepts `untrusted`, `on-request`,
  `never`, or object-form `granular`. For compatibility, Symphony accepts the
  legacy `on-failure` alias and sends `on-request`. It also accepts legacy
  object-form `reject`, inverts its three booleans to preserve their meaning,
  and sends `granular`; new skill and permission-request flags default to
  fail-closed. Unknown policy strings, keys, and non-boolean flags are rejected
  during configuration validation. `never` is never interpreted as permission
  to approve a callback; an unexpected approval or elicitation request fails
  closed.
- Supported `codex.thread_sandbox` values: `read-only`, `workspace-write`, `danger-full-access`.
- An explicit `codex.turn_sandbox_policy` must match one pinned tagged variant:
  `dangerFullAccess`; `readOnly` with optional boolean `networkAccess`;
  `externalSandbox` with optional `networkAccess` of `restricted` or `enabled`;
  or `workspaceWrite` with optional absolute normalized `writableRoots` and
  boolean `networkAccess`, `excludeTmpdirEnvVar`, and `excludeSlashTmp` flags.
  Unknown keys and invalid value types are rejected before App Server dispatch.
- Workflows that run package managers or other commands that resolve external hosts should set
  `networkAccess: true` in `codex.turn_sandbox_policy`; otherwise DNS/network access may be denied
  by the Codex turn sandbox.
- `agent.max_turns` caps how many back-to-back Codex turns Symphony will run in a single agent
  invocation when a turn completes normally but the issue is still in an active state. Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there, along with any other setup commands you need.
- If a hook needs `mise exec` inside a freshly cloned workspace, trust the repo config and fetch
  the project dependencies in `hooks.after_create` before invoking `mise` later from other hooks.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory. Relative `workspace.root` values resolve
  against the directory containing the selected `WORKFLOW.md`, not the service process's current
  directory. The resulting root is canonicalized once during configuration loading.
- For env-backed path values, use `$VAR`. `workspace.root` resolves `$VAR` before path handling.
  Per-issue leaf names preserve ordinary ASCII identifiers; unsafe or oversized identifiers gain a
  deterministic digest suffix so distinct tracker identifiers cannot collapse onto one workspace.
  Existing, sibling, broken, and outside-root issue-leaf symlinks are never accepted as workspaces.
  `codex.command` is parsed as a quoted argument vector and is never run through a shell. Only an
  exact first token of `$CODEX_BIN` is resolved from the environment; other `$VAR` text, command
  substitutions, backticks, and globs remain literal arguments. Shell control operators and
  redirections are rejected. The executable must resolve to an absolute executable path.
- App Server requests use absolute method deadlines: `initialize_timeout_ms` defaults to `15000`,
  `thread_start_timeout_ms` and `turn_start_timeout_ms` default to `30000`, and other synchronous
  reads use `read_timeout_ms` (`5000`). A late response cannot win a mailbox-ordering race.
- Protocol stdout is strict JSONL with `max_frame_bytes` defaulting to `16777216` (16 MiB). Stderr
  stays separate and is reduced to content-free diagnostics: whole-stream byte/chunk/line counts
  and UTF-8 validity plus allowlisted categories whose latest complete match remains inside the
  configured suffix. No raw stderr excerpt or hash is retained. `stderr_tail_bytes` controls that
  category window, defaults to `65536`, and cannot exceed `1048576` (1 MiB).
- Local App Server processes run in a dedicated user/PID/mount namespace behind
  an anchored outer process group. The candidate-controlled per-attempt
  containment launcher and target bootstrap start with an empty environment;
  Symphony captures the exact namespace root and blocked target PID before
  applying the target-only environment and releasing the executable. The
  long-lived vendored `exec-port` is a trusted upstream runtime boundary, not a
  user-job child. The target starts in a separate session, and forced cleanup
  independently pidfd-signals the exact namespace root before retiring the
  outer group.
  `process_kill_timeout_ms` defaults to `2000`; success requires the manager,
  outer group, and namespace root to be gone. Cleanup failure is a
  reconciliation blocker, not a retryable worker failure.
- Overload code `-32001` is retried only for classified idempotent reads, using bounded exponential
  jitter controlled by `overload_max_attempts`, `overload_backoff_base_ms`, and
  `overload_backoff_max_ms`. The logical `operation_id` is retained when the
  JSON-RPC request ID changes. Side-effecting `thread/start` and `turn/start`
  operations are never blindly retried; a post-send transport failure is
  surfaced as an uncertain external outcome with content-free operation
  correlation.
- Remote App Server workers are outside the supported Release 0/1 profile. A configured SSH worker
  or `worker_host` is rejected before launch and remains gated until Release 5.
- Local workspace hooks run in the same verified descendant-containment boundary as App Server
  children. They inherit only `HOME`, locale/user/terminal variables, `PATH`, `TMPDIR`, and the
  optional `SOURCE_REPO_URL`; tracker credentials and unrelated Studio secrets are absent. Hook
  execution stops at a 64 KiB aggregate output ceiling, and raw output is never copied into errors
  or logs. A fresh workspace is rolled back when bootstrap fails, while a reused workspace is never
  reset by a hook failure.
- The upstream runtime sandbox resolver remains available for non-Studio callers. Managed Studio
  callers opt into a narrower policy that binds `workspaceWrite.writableRoots` to the exact issue
  workspace, keeps network access off by default, preserves an explicit network opt-in, and rejects
  broad sandbox variants.

```yaml
tracker:
  api_key: $LINEAR_API_KEY
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  after_create: |
    git clone --depth 1 "$SOURCE_REPO_URL" .
codex:
  command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server"
  initialize_timeout_ms: 15000
  thread_start_timeout_ms: 30000
  turn_start_timeout_ms: 30000
  max_frame_bytes: 16777216
  stderr_tail_bytes: 65536
  process_kill_timeout_ms: 2000
```

- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.
  Existing response fields remain intact. Runtime entries add `run_id`,
  `attempt_id`, and the normalized stream-head event ID, sequence, and type;
  these are observability cursors and do not make the Release 0 sink durable.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap
- Tracker issue identifiers link to the tracker-provided URL when it uses `http` or `https`

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the real external end-to-end test only when you want Symphony to create disposable Linear
resources and launch a real `codex app-server` session:

```bash
cd elixir
export LINEAR_API_KEY=...
make e2e
```

Optional environment variables:

- `SYMPHONY_LIVE_LINEAR_TEAM_KEY` defaults to `SYME2E`

`make e2e` exercises only the local-worker scenario in the current Release 0/1 implementation
profile. It creates a temporary Linear project and issue, writes a temporary `WORKFLOW.md`, runs
a real agent turn, verifies the workspace side effect, requires Codex to comment on and close the
Linear issue, then marks the project completed so the run remains visible in Linear. The
preserved upstream SSH live harness is tagged and skipped until remote-worker execution is
implemented and accepted in Release 5; the current implementation rejects SSH worker
configuration before dispatch.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Launch `codex` in your repo, give it the URL to the Symphony repo, and ask it to set things up for
you.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
