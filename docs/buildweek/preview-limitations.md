# Build Week Preview limitations

This file is an honesty boundary for the Build Week prerelease. It must be
reviewed against the release candidate and shortened only when current evidence
proves an item resolved.

## Current verification-framework status

For the current source:

- the fail-closed owner CLI, browser oracle, golden-path specification, state
  matrix, safe demo intent, and public-artifact checks exist;
- the harness-contract and Python unit tests pass without external mutation;
- production New Work, Setup, Mission Control, and Run Detail routes are wired
  to the current Intent Service and authoritative process-local event
  projection;
- the loopback GET-only verification endpoint and credential-free desktop and
  mobile owner route checks pass without external mutation;
- the clean-launch gate mechanics pass against the committed R0 foundation:
  private exact-HEAD extraction, public-source audit, clean build, loopback
  runtime response, and an empty memory tracker with zero external mutation;
- local reset now binds the exact persisted Intent Store ID and selected issue,
  rejects ambiguous or corrupt state, removes only that local intent and its
  exact prior receipt, and publishes a strict zero-Linear-mutation receipt;
- no demonstration issue has been created, moved, edited, or reused;
- a real intent was submitted through the production New Work route, one
  clarification was resolved, and a five-task proposal rendered with zero
  confirmed Linear mutations;
- no live Linear write, demonstration issue, real Codex run, completed golden
  path, or integrated-preview clean-launch result is claimed yet;
- unavailable live dependencies and missing run evidence render blocked or
  incomplete; they never become a mock success.

The public branch may be owner-tested as an honestly labelled prerelease while
the live-write and end-to-end completion blockers remain visible. It must not
be described as a completed golden path or published as the final preview
release until its required candidate evidence passes.

## Deliberate preview scope

The preview is a prerelease, not complete v1.0.0 or v1.1.0. Its promised value
is one authoritative path from owner intent through approved Linear tasks,
Symphony/Codex execution, Mission Control, Run Detail, deterministic checks,
fresh independent review, and an evidence-backed outcome.

Deferred from the preview are History, analytics, optional filters and charts,
extra themes, non-essential motion, unsupported Fast/Turn-speed UI, broad
Planner and native todo/work-graph functionality, deployments, notifications,
collaboration, remote workers, Maintenance Autopilot, non-Codex providers,
administration, disabled coming-soon controls, and speculative abstractions.

## Operational limits

- Linux x86_64 is the only candidate platform. Publication requires the exact
  candidate's clean-launch evidence; other platforms are unverified.
- The server is local and loopback-only. Remote hosting and multi-user access
  are outside preview scope.
- One dedicated project and one safe demo journey are supported. `SYM-1` and
  `SYM-2` remain protected R0 read-only fixtures and are never demo/reset data.
- A separately scoped preview-write authority is required for approved task
  publication and the minimum lifecycle transitions. The R0 read-only
  credential is not broadened or replaced; it must be simultaneously available
  only so Studio can prove the two credential values differ before any write.
- The STDIO MCP surface is a non-mutating Intent Liaison. It can attach, submit,
  clarify, present, and query status. Approval, publication, and start are
  trusted-local-UI actions until a single-use human-attested host receipt exists.
- Read-only browser verification requires no credential or pairing and is
  limited to the loopback production server. Optional browser storage state,
  when supplied for a future authenticated surface, must be an owner-only
  mode-0600 regular file outside Git.
- Automated axe checks, keyboard tests, four responsive widths, screenshots,
  and a manual checklist cover preview-critical accessibility and presentation;
  they are not a claim of exhaustive assistive-technology certification.
- Usage is shown only when the runtime genuinely reports it. Missing usage is
  labelled unavailable rather than estimated.
- GPT-5.6 Sol Ultra and Ultra effort are shown as requested policy until an
  exact-current-attempt runtime event attests the effective selection. A
  configured command or worker admission alone is not execution proof.
- Completion remains fail-closed: required checks, detached review, current
  sealed evidence, delivery reference, tracker handoff, terminal status, and
  actual GPT-5.6 Sol Ultra/Ultra runtime attestation must agree for one current
  attempt and immutable source revision. Partial, stale, mixed-attempt, or
  configured-only state renders incomplete.
- Demo reset is local-only and must run while the preview process is stopped.
  It removes one exact local Intent Store record and its bound reset receipt;
  it does not reverse or delete Linear history, remove general evidence, or
  restore an externally modified issue.
- Raw recordings, narration, editor projects, final video, and thumbnails stay
  outside Git and GitHub Release assets.

## Remaining release blockers

Before the first preview release, resolve these items with current
commit/evidence references or retain each item as a blocker:

- live rehearsal of the exact-intent local reset against the integrated store;
- dedicated preview-write authority and one safe demonstration issue distinct
  from `SYM-1` and `SYM-2`;
- approved idempotent Backlog publication, dependency creation, and the single
  selected first-ready transition to Todo against the dedicated project;
- real Symphony admission, isolated GPT-5.6 Sol Ultra execution, deterministic
  validation, detached review, evidence sealing, delivery, and tracker handoff;
- production emission of the complete revision-bound validation, review,
  evidence, delivery, handoff, terminal, and model-attestation event sequence;
- real golden-path result, four-viewport state matrix, clean launch,
  public-artifact audit, fresh independent review, and checksum/provenance.

No screenshot, README statement, video narration, or Devpost copy may describe
one of these as working before its evidence is current for the release commit.
