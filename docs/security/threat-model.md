# Symphony Studio threat model

Status: baseline model opened in R0-01; controls and test evidence mature with
the packages that implement them.

## Scope and trust assumptions

Symphony Studio supports one trusted local operator on a supported local host.
It is not a multi-tenant service. Linear issues, repository content, tool output,
logs, App Server messages, browser input, and external documentation are
untrusted data. They cannot override authorization, sandbox, approval, quota,
completion, secret, release, or evidence policy.

The primary boundaries are GitHub publication, Codex App Server transport,
Linear access, child processes, issue workspaces, durable SQLite/artifact state,
the Phoenix endpoint/browser, backups/releases, and external submission media.

## Assets

- GitHub repository integrity, protected main, tags, releases, and provenance
- Codex and Linear credentials and safe account identity binding
- source worktrees and operator files outside managed workspace roots
- authoritative run/lifecycle state, evidence, review, and completion decisions
- quota capacity, reset credits, and protected validation/review reserve
- pairing/signing secret and authenticated operator session
- artifact, backup, package, and submission-media confidentiality/integrity

## Threat and control register

| Boundary / threat | Required invariant and mitigation | Required verification | Status / owner |
|---|---|---|---|
| Fork confusion or upstream push | Exact fork parent/remotes; upstream push disabled; protected main; exact-SHA PR merge only. | Remote/permission Doctor, branch-rule API proof, failed-bypass policy test, ancestry check. | Governance configured; R0-07 automation pending / release controller |
| Candidate code gains release credentials | Candidate jobs read-only and secret-free; no `pull_request_target`; publication only from protected merged main. | Workflow permission lint and adversarial PR inspection. | Pending R0-07 / release controller |
| Candidate self-spoofs `studio/release-gate` | Check-name and GitHub-Actions app binding alone are insufficient. Gate control must come from protected base state or an equivalently immutable attestation, bind exact head/base/manifest/workflow hashes, reject unauthorized gate-workflow changes, and never run candidate code with write credentials. | Adversarial duplicate-name and modified-workflow tests; verify check producer, event, workflow/ref/blob hash, head/base and sealed manifest. | Identified in R0-01; blocking R0-07 design and publication / release controller |
| Tag/release substitution | Immutable version, sealed head/base/tree manifests, build from merged main, downloaded-asset hash verification. | Idempotency, stale-head denial, remote tag/asset/provenance tests. | Pending R0-07 / release controller |
| App Server framing or stdout injection | Strict JSONL framing, bounded frame size, request correlation, stderr separation, deterministic timeout/overload policy. | Split/coalesced/malformed/oversize/stdout-noise/late-response contract tests. | Pending R0-03 / transport owner |
| Orphaned or escaped process | Dedicated process group, bounded teardown, no shell interpolation, verified descendant cleanup. | Interrupt/crash/timeout/orphan process tests. | Pending R0-03–05 / runtime owner |
| Secret leakage to child or durable state | Explicit child-env allowlist; redact before persist/broadcast; no secrets in SQLite, artifacts, logs, backups, releases or media. | Canary across process env, events, DB, API, UI, backup, archive and logs. | Pending R0-03 and R1 / security owner |
| Cross-account continuation | Safe hashed identity binding; identity changes invalidate waits, resumptions and cached quotas. | Account-change wait/resume and no-raw-email persistence tests. | Pending R0-06/R1-06 / quota owner |
| Linear prompt or GraphQL injection | Treat fields as data; mediated allowlisted operations; managed issue mutations require policy and idempotent outbox. | Prompt-injection, AST allowlist, alias/fragment/mutation bypass and replay tests. | Pending R0-05/R1-07 / tracker owner |
| Workspace traversal or symlink escape | Sanitized identifiers, canonical root containment, symlink rejection, bounded writable roots, safe cleanup, no Docker socket. | Property tests for traversal, Unicode/encoding, symlink swaps and cleanup denial. | Pending R0-05 / workspace owner |
| Network overreach | Required network only, policy-bound per role; remote UI mode unsupported in Build Week. | Sandbox/network denial and Doctor exposure tests. | Pending R0-05/R1 / runtime owner |
| Unauthenticated UI read or mutation | Loopback default, one-time pairing, `0600` signing secret, strict signed cookie, CSRF, Origin and Host checks, revocation. | Pair/replay/logout/restart, unauthenticated read, Host/Origin/CSRF and cookie tests. | Pending R1-13 / web owner |
| Showcase privilege escalation | Separate expiring read-only capability; no inherited operator mutations or secret-bearing data. | Route/action matrix and expired/forged capability tests. | Pending R1-19 / web owner |
| XSS or unsafe artifact delivery | Escaped templates, sanitized Markdown, no raw HTML, restrictive CSP/headers, authorized bounded download paths. | Stored/reflected XSS corpus, header checks, MIME/path/range/size authorization tests. | Pending R1-13–20 / web owner |
| Approval/input spoofing | Only typed App Server requests create blockers; deny forbidden autoapproval classes; fail closed on unknown/expired input. | Spoofed event, replay, timeout, ownership and policy-denial tests. | Pending R1-12 / lifecycle owner |
| False completion or stale evidence | Completion derives from persisted reducer, fresh evidence, detached review and tracker sync—not UI labels or agent prose. | Staleness, restart/replay, review/repair and terminal-outbox tests. | Pending R1-10–12 / quality owner |
| Quota exhaustion before validation | Dynamic bucket discovery, identity binding, protected reserve, priority lanes, durable waits, no spend/credit conflation. | Replacement bucket, reset/restart/account-change and validation-reserve tests. | Pending R0-06/R1-06 / quota owner |
| Backup/release/media leak | Authenticated local access, integrity hashes, exclusion scans; final media only under external submission root. | Secret/media canary scan, backup/restore, archive listing and external-root containment. | Pending R1/R1.1 / release owner |

## Network exposure policy

The supported default is loopback only. Binding to a non-loopback address is a
blocking Doctor failure for the Build Week releases unless an explicitly
documented reverse proxy, TLS and authentication boundary is configured; that
remote mode remains unsupported and must not be advertised as a release claim.

## Residual-risk acceptance

No release-blocking residual risk can be accepted by narrative. Any waiver must
have an identifier, owner, scope, expiry, evidence, rollback, and explicit
reference in the candidate and final release manifests. Security gates cannot
be weakened to publish a stage.
