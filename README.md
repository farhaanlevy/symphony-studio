# Symphony Studio

## Build Week Preview

> **Downstream Build Week project.** This is the clearly labelled, local-only
> `v0.2.0-buildweek-preview.1` source preview built on
> [OpenAI Symphony](https://github.com/openai/symphony). It is not complete
> `v1.0.0` or `v1.1.0`, and protected `v0.1.0` publication remains pending.

The owner-testable candidate provides production Phoenix LiveView routes for
New Work, Setup, Mission Control, and Run Detail; one canonical Intent Service
shared with an owner-local STDIO MCP liaison; and an authoritative runtime-event
projection. The working submission story is deliberately read-only: prompt or
pasted Markdown becomes repository inspection, at most two clarification
questions, and a three-to-five-task proposal. Missing write authority or run
evidence stays visibly blocked or incomplete.

### Fresh Linux x86_64 judge path

Prerequisites are `git`, `mise`, Python 3.10 or newer, and Codex CLI `0.144.3`.
Node.js 18 or newer is needed only for the optional browser check.

```bash
git clone --branch release/v0.2.0-buildweek-preview.1 \
  https://github.com/farhaanlevy/symphony-studio.git
cd symphony-studio
mise trust
mise install
cd elixir
mise trust
mise install
mise exec -- mix setup
cd ..
./scripts/preview/run preflight --live --json
./scripts/preview/run launch --live-preflight --port 4000
```

Open `http://127.0.0.1:4000/setup`. The supported launcher also performs the
locked Elixir setup before building, so the explicit `mix setup` step above is
safe to repeat and makes the clean-clone dependency boundary visible. After one
successful build, a local repeat may use `launch --no-build`; there is currently
no published binary, hosted sandbox, demo account, or no-build artifact for a
fresh machine. That source-build limitation is part of this preview's public
boundary.

For the optional credential-free route check:

```bash
npm --prefix tests/preview/browser ci
npm --prefix tests/preview/browser run install-browser
SYMPHONY_PREVIEW_BASE_URL=http://127.0.0.1:4000 \
  npm --prefix tests/preview/browser run test:owner-readonly
```

### What Symphony Studio adds

- hardened, pinned Codex `0.144.3` compatibility and accepted Release 0
  credential/process/workspace boundaries;
- bounded intent inspection, clarification, and task-proposal state shared by
  the production web UI and local MCP liaison;
- Setup, Mission Control, and Run Detail surfaces driven by current Store and
  runtime-event state rather than a mock-success route;
- fail-closed completion rules that require one current attempt, explicit
  deterministic checks, detached review, sealed evidence, delivery, tracker
  handoff, terminal state, and actual runtime model attestation; and
- deterministic launch/reset/browser/public-artifact tooling plus fork and
  release provenance.

### How Codex and GPT-5.6 were used

Codex was the implementation conductor and supported bounded code work,
targeted tests, browser verification, release audits, and independent reviews.
Deterministic scripts—not model assertions—decide build, schema, test, browser,
security, and evidence claims. The committed worker policy requests GPT-5.6 Sol
Ultra with Ultra reasoning, but this read-only preview has not admitted a demo
issue or executed that model end to end. Setup therefore distinguishes the
requested policy from actual current-attempt runtime attestation.

### Security and honest limitations

- The server binds to loopback and is intended for one trusted local operator.
- The supported launcher strips credential-shaped parent environment from all
  helper, build, browser, and runtime children.
- The accepted R0 Linear credential remains read-only and is never broadened.
  Production approval, Linear publication, and Start are hard-disabled until a
  distinct trusted out-of-process write broker exists. Do not provide a Linear
  credential to this preview.
- `SYM-1` and `SYM-2` remain protected fixtures. No demo issue or live Linear
  mutation exists for this candidate.
- No real preview Symphony/Codex run, completed golden path, demo-result review,
  or evidence-backed completed outcome is claimed.
- Linux x86_64 is the only candidate platform; final exact-commit clean-launch
  evidence remains required before calling it verified. Runtime projection is
  process-local, and a fresh machine must build from source once.

The exact five-minute checklist, deterministic local reset template, evidence,
and limitations are in
[`docs/buildweek/owner-testing.md`](docs/buildweek/owner-testing.md) and
[`docs/buildweek/preview-limitations.md`](docs/buildweek/preview-limitations.md).

## Upstream Symphony baseline

OpenAI Symphony remains the core runner. It turns project work into isolated,
autonomous implementation runs so teams can manage work instead of supervising
coding agents.

The following Vimeo video and poster are **the upstream OpenAI Symphony demo,
not a Symphony Studio Build Week Preview recording**:

[![Upstream OpenAI Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In the [upstream demo](https://player.vimeo.com/video/1186371009?h=5626e4b899),
Symphony monitors a Linear board, spawns agents, and presents proof of work. The
current Studio preview does not claim to reproduce that complete path._

> [!WARNING]
> OpenAI Symphony and this downstream Studio build are engineering previews for
> testing in trusted environments.

## Specification and provenance

> **Downstream modification notice (2026-07-14):** Symphony Studio adds this
> fork-specific attribution, specification routing, and staged-release context
> to the upstream README.

Two specifications are intentionally preserved:

- [`SPEC.md`](SPEC.md) is OpenAI Symphony's upstream engine contract.
- [`STUDIO_SPEC.md`](STUDIO_SPEC.md) is Symphony Studio's product, security,
  quality, and staged-release contract.

The exact upstream base and downstream change classification are recorded in
[`UPSTREAM_BASE`](UPSTREAM_BASE),
[`docs/architecture/fork-policy.md`](docs/architecture/fork-policy.md), and
[`docs/architecture/patch-ledger.md`](docs/architecture/patch-ledger.md).

## Running Symphony

### Requirements

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/). Symphony is the next step --
moving from managing coding agents to managing work that needs to get done.

### Option 1. Make your own

Tell your favorite coding agent to build Symphony in a programming language of your choice:

> Implement Symphony according to the following spec:
> https://github.com/openai/symphony/blob/main/SPEC.md

### Option 2. Use our experimental reference implementation

Check out [elixir/README.md](elixir/README.md) for instructions on how to set up your environment
and run the Elixir-based Symphony implementation. You can also ask your favorite coding agent to
help with the setup:

> Set up Symphony for my repository based on
> https://github.com/openai/symphony/blob/main/elixir/README.md

---

## License

This project is licensed under the [Apache License 2.0](LICENSE).
