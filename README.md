# Symphony

Symphony turns project work into isolated, autonomous implementation runs, allowing teams to manage
work instead of supervising coding agents.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](https://player.vimeo.com/video/1186371009?h=5626e4b899)

_In this [demo video](https://player.vimeo.com/video/1186371009?h=5626e4b899), Symphony monitors a Linear board for work and spawns agents to handle the tasks. The agents complete the tasks and provide proof of work: CI status, PR review feedback, complexity analysis, and walkthrough videos. When accepted, the agents land the PR safely. Engineers do not need to supervise Codex; they can manage the work at a higher level._

> [!WARNING]
> Symphony is a low-key engineering preview for testing in trusted environments.

## Symphony Studio fork

> **Downstream modification notice (2026-07-14):** Symphony Studio adds this
> fork-specific attribution, specification routing, and staged-release context
> to the upstream README.

This repository is the Build Week downstream fork **Symphony Studio**, built on
[OpenAI Symphony](https://github.com/openai/symphony). Symphony remains the core
runner; Studio adds a hardened compatibility foundation, durable evidence and
operations, a local Phoenix LiveView control surface, and a protected release
train in staged releases. Work that has not passed its release gate remains on
its release branch and is not represented as stable functionality on `main`.

Two specifications are intentionally preserved:

- [`SPEC.md`](SPEC.md) is OpenAI Symphony's upstream engine contract.
- [`STUDIO_SPEC.md`](STUDIO_SPEC.md) is Symphony Studio's product, security,
  quality, and staged-release contract.

The exact upstream base and downstream change classification are recorded in
[`UPSTREAM_BASE`](UPSTREAM_BASE),
[`docs/architecture/fork-policy.md`](docs/architecture/fork-policy.md), and
[`docs/architecture/patch-ledger.md`](docs/architecture/patch-ledger.md).

## Build Week Preview

The public branch `release/v0.2.0-buildweek-preview.1` is an owner-testable,
local-only prerelease. It is not complete `v1.0.0` or `v1.1.0`. The current
candidate provides the production New Work, Setup, Mission Control, and Run
Detail routes; a canonical intent service shared with a non-mutating local
STDIO MCP liaison; a fail-closed Linear write boundary owned by the trusted
local UI; and an authoritative runtime-event projection. Without both the
separately scoped preview-write credential and protected R0 read authority for
the required distinctness check, the UI remains read-only and shows that
blocker instead of fabricating a successful run. The MCP liaison can attach,
submit, clarify, present, and report status, but cannot approve, publish, or
start work.

On Linux x86_64 with `git`, `mise`, Python 3.10+, Node.js 18+, and Codex CLI
0.144.3:

```bash
git clone --branch release/v0.2.0-buildweek-preview.1 \
  https://github.com/farhaanlevy/symphony-studio.git
cd symphony-studio
mise trust
mise install
./scripts/preview/run preflight --live --json
./scripts/preview/run launch --live-preflight --port 4000
```

Open `http://127.0.0.1:4000/setup`. For the optional read-only browser check,
install the locked test dependencies once and run:

```bash
npm --prefix tests/preview/browser ci
npm --prefix tests/preview/browser run install-browser
SYMPHONY_PREVIEW_BASE_URL=http://127.0.0.1:4000 \
  npm --prefix tests/preview/browser run test:owner-readonly
```

The exact owner checklist, deterministic local reset, supported boundary, and
honest remaining blockers are in
[`docs/buildweek/owner-testing.md`](docs/buildweek/owner-testing.md) and
[`docs/buildweek/preview-limitations.md`](docs/buildweek/preview-limitations.md).

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
