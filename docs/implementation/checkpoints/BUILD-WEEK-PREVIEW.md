# Build Week Preview checkpoint

Status: owner-testable candidate in progress; not `v1.0.0`, `v1.1.0`, or a
completed golden-path release.

## Boundary

The emergency deadline override authorizes a clearly labelled
`v0.2.0-buildweek-preview.1` branch from the accepted Release 0 foundation. It
pulls forward only the narrow prompt/Markdown planning and Linear publication
journey needed for the demonstration. The stable `STUDIO_SPEC.md` release order
remains unchanged after the submission.

Integrated source commits:

- intent and MCP surface: `a314149e119d467c025f3b39a75ca6bfc19f56d1`;
- authoritative interface: `53654ed2c49fa80e4ea6046286b07a983f96b073`;
- verification and owner experience: `a68529917723db86cf101aa615bd0f5e91d4b75a`;
- accepted R0-06 foundation: `25f4d78e1eb3102dd8d1aa72413988b36b72fd71`.

## Implemented candidate

- One Intent Service backs both production LiveView and the local STDIO MCP
  server.
- New Work accepts bounded prompt or pasted Markdown, asks at most two
  clarifications, presents three to five proposed tasks and side effects, and
  requires explicit approval before publication.
- A fail-closed Linear broker permits only approved Backlog issue creation,
  required blocker relations, and one selected first-ready transition to Todo.
  It requires a distinct protected write credential and cannot reuse the R0
  read-only credential or mutate `SYM-1`/`SYM-2`.
- Symphony's existing poll/admission path remains scheduler authority.
- Runtime events project into production Mission Control and Run Detail.
  Completion requires deterministic checks, detached review, current sealed
  evidence, delivery, confirmed tracker handoff, and a terminal run event.
- Setup reports active repository, Linear, Codex, compatibility, model policy,
  and readiness truth. Missing live authority renders blocked.
- Launch, exact local reset, browser checks, public audit, and clean-launch
  tooling are committed; media and credentials remain outside Git.

## Current evidence

- integrated runtime/service/controller suite: 94 tests, zero failures;
- focused production-route suite: 8 tests, zero failures;
- preview CLI: 20 tests, zero failures;
- Playwright harness contract: 4 tests, zero failures;
- public specs and strict Credo: 152 source files, zero findings;
- public-artifact audit: 2,177 files, zero findings;
- rendered production routes: desktop and mobile HTTP success, no browser
  console/page errors, no Axe WCAG A/AA violations, visible keyboard focus;
- production New Work smoke: one clarification, five proposed tasks, explicit
  zero-mutation state, and no Linear request.

No live Linear mutation has been executed, no demonstration issue exists, and
neither protected fixture has changed.

## Remaining release evidence

- provision the separately scoped preview-write credential outside Git;
- create one new safe demonstration issue through the approved production path;
- complete real Backlog publication, blocker relations, selected Todo
  transition, Symphony admission, isolated GPT-5.6 Sol Ultra execution,
  deterministic validation, detached review, evidence, delivery, and tracker
  handoff;
- run the final state matrix, exact-commit clean launch, public audit, fresh
  independent review, checksum, and provenance record;
- resolve only verified P0/P1 or acceptance-impacting P2 findings.

R0-07 and protected `v0.1.0` publication remain a parallel release train and
are not represented as complete by this preview checkpoint.
