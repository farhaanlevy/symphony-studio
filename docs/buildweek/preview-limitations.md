# Build Week Preview limitations

This file is an honesty boundary for the Build Week prerelease. It must be
reviewed against the release candidate and shortened only when current evidence
proves an item resolved.

## Current verification-framework status

For the current source:

- the fail-closed owner CLI, browser oracle, golden-path specification, state
  matrix, safe demo intent, and public-artifact checks exist;
- the harness-contract and Python unit tests pass without external mutation;
- the clean-launch gate mechanics pass against the committed R0 foundation:
  private exact-HEAD extraction, public-source audit, clean build, loopback
  runtime response, and an empty memory tracker with zero external mutation;
- local reset now binds the exact persisted Intent Store ID and selected issue,
  rejects ambiguous or corrupt state, removes only that local intent and its
  exact prior receipt, and publishes a strict zero-Linear-mutation receipt;
- no demonstration issue has been created, moved, edited, or reused;
- no live Linear write, real Codex run, authoritative Studio browser route,
  screenshot, integrated-preview clean-launch pass, or golden-path pass is
  claimed by this verification-only workstream;
- missing production UI/service integration produces an explicit `BLOCKED`
  result; skips are counted as blocked by the evidence reporter.

The preview release must not ship while those integration blockers remain.

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
  credential is not broadened or replaced.
- Browser verification requires application-issued pairing state stored as an
  owner-only mode-0600 file outside Git. The harness has no bypass.
- Automated axe checks, keyboard tests, four responsive widths, screenshots,
  and a manual checklist cover preview-critical accessibility and presentation;
  they are not a claim of exhaustive assistive-technology certification.
- Usage is shown only when the runtime genuinely reports it. Missing usage is
  labelled unavailable rather than estimated.
- Completion remains fail-closed: required checks, detached review, current
  sealed evidence, delivery reference, and tracker handoff must agree. Partial
  or stale state renders incomplete.
- Demo reset is local-only and must run while the preview process is stopped.
  It removes one exact local Intent Store record and its bound reset receipt;
  it does not reverse or delete Linear history, remove general evidence, or
  restore an externally modified issue.
- Raw recordings, narration, editor projects, final video, and thumbnails stay
  outside Git and GitHub Release assets.

## Known release-blocking integrations

Before the first preview release, replace this section with the exact resolved
commit/evidence references or retain each item as a blocker:

- production Intent Service and approved idempotent Backlog publication;
- authoritative Studio persistence/projection and paired verification endpoint;
- production New Work, Setup, Mission Control, and Run Detail routes;
- live rehearsal of the exact-intent local reset against the integrated store;
- dedicated demo write authority and safe application-produced pairing state;
- real golden-path result, four-viewport state matrix, clean launch,
  public-artifact audit, fresh independent review, and checksum/provenance.

No screenshot, README statement, video narration, or Devpost copy may describe
one of these as working before its evidence is current for the release commit.
