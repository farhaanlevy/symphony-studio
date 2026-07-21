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

R0-05 separates guardian-start ambiguity from later barrier-registration loss.
A missing TaskSupervisor observed before starter invocation, or otherwise
positively observed child absence, may transfer cleanup authority. Any error or
exit after invoking the starter is ambiguous: the caller waits for and adopts
only the exact-token ready guardian, and a missing acknowledgement holds fail
closed indefinitely rather than authorizing inline cleanup. The complementary
regressions prove ready-child adoption with maximum stop-call concurrency one
and the no-child/no-acknowledgement permanent hold with zero stop calls or
inline fallback. The final runtime subset contains 15 tests, the complete
source-bound fixture contains 411 tests, and the 535-test upstream gate passes.

Final review additionally requires a failed or timed-out cooperative
cancellation to return a typed safety block without synchronously terminating
an infinite-shutdown controller. A live retained controller continues to
consume global, immutable admitted-state, and worker-host capacity after
tracker refresh until it exits. Established Connection cleanup publishes its
guardian handle before readiness and marks that handle durably verified before
any success reply; dead Connection PIDs alone are not retirement proof.
Terminal turn events clear the active interrupt target.

R0-05 keeps a 100% measured-module coverage threshold but does not mislabel
process-scheduler or same-UID filesystem-race lines as deterministic coverage.
`CleanupGuardian`, `Config.ManagedWorkspace`, and `WorkspaceHookRunner` are
explicit structural line-instrumentation exclusions backed by direct
adversarial guardian, hook, workspace, and runtime tests. `RuntimeSupervisor`,
`CleanupBarrier`, and `Config.Schema` remain measured at 100.00%. The accepted
seal, installed-pin verification, clean regeneration, quota-free real AppServer
smoke, hygiene audit, reproducible package construction, and independent
exact-tree reviews pass. Live runtime capability discovery remains R0-06.

R0-06 private build inspection never follows compiler-created links. It admits
only exact Mix app-source, Phoenix colocated, and internal Rebar profile-plugin
path forms whose raw text equals the compiler-derived target and whose
normalized target identity is bound to a separately fingerprinted private
root. Only the exact Phoenix `assets/node_modules` target may be absent.
Dependency, source, tool, arbitrary build, absolute Mix, external Rebar,
symlink-component, oversized, and crafted second-link-plus-`..` cases fail
closed. This remains scoped to the Release 0 one-trusted-operator,
non-hostile-same-UID boundary recorded below.

R0-06 authenticated capability execution does not enter through project-task
discovery. Mix discovers a project-defined task before it can apply that task's
requirements, and even its deny flags still load dependency metadata, evaluate
Rebar scripts, and permit a project `run` alias after credential installation.
The generic gate and network-enabled staged-publisher namespaces are therefore
credential- and raw-response-blind. Their build remains a local integrity
oracle but authorizes no credential-bearing runtime. Before publisher launch,
the external trusted supervisor reconstructs the exact staged tree and
independently performs locked dependency acquisition plus networkless replay,
dependency compilation, and application compilation under fixed lexical paths
without a credential, publisher path, or control socket. It projects every app
`ebin` and the exact native port into a second private root only after the
builder process group is dead. The publisher then sends only public source,
tree, tool, installed-Codex, and opaque seal-ID bindings over an owner-only
fixed Unix socket. The supervisor revalidates the staged snapshot, its own
compiled code roots, pinned runtime tools, and installed Codex bytes before
launching either project-independent runner. Only the Codex child receives a disposable writable copy of the minimum
validated authentication and identity inputs plus the verified native
executable. Only the separately networkless Linear child receives the fixed raw
broker socket. The publisher sees neither credential, no credential selector,
no secret path/file descriptor, no raw broker socket, and no raw provider body.
Credential-free dependency bootstrap retains its required network. Before
reading the Linear key or issuing a query, the broker binds its sole peer to the
supervisor-launched process lineage, exact BEAM executable bytes, exact compiled
code-root bytes, fixed entrypoint/environment, distinct PID/mount/network
namespaces, loopback-only interfaces, empty route table, and fixed socket inode.
That Linear runner sends only an operation enum and bounded variables over
length-bounded frames, never query text, URL, method, headers, auth, or an
arbitrary operation name. The broker alone owns the key, fixed TLS
host/port/path, six exact query documents, project/team/fixture variable policy,
learned team binding, exact nine-query initial/final replay, and chained
zero-mutation receipt. Both runners use the absolute pinned Elixir runner from
an empty private cwd, finite fingerprint-bound code roots, and a static
`run_sealed/1` entrypoint. Their environments contain no Mix, Hex, mise, Rebar,
or erlexec build selector. Direct-child output, deadlines, process groups,
credential cleanup, public projections, source, build, code-root, runtime-tool,
socket-inode, and transcript checks fail closed. Command-local pointer injection
is confined to the external supervisor because the parent tool environment
filters it; the selector and protected pathname are never recorded.

Revision 44 is explicitly rejected and superseded: its fresh reviews found that
the outer gate namespace exposed authentication inputs while candidate-aware
build steps still ran, that the Linear key shared a process with Mix compilation,
and that the readiness projection could discard or misstate the hidden reference
profile. Two later mandatory reviews rejected Revision 48 because the strict
checkout/OID/source and private build-byte/link validators remained test-only,
protected key ownership was not enforced, and checkpoint revision provenance
was contradictory. Revision 54 retained those validators and passed every
deterministic gate, but its final Reviewer A found that the raw Linear key still
entered staged publisher/BEAM code with direct egress. Revision 55 rejects that
evidence and adds the trusted fixed-query broker plus an attested networkless
sealed peer. Its first green publisher is also rejected because the trusted
outer child command still contained the exact protected pathname and the public
record overstated the outer network boundary. Revision 56 masks the whole
credential parent, keeps the exact pathname out of child arguments, remounts
only a private verified Codex-auth copy, and corrects the record. Its first
publisher exposed a separate full-report fallback defect: a blocked no-model
row received the `not_run` reference default and failed status validation before
the truthful blocked pair could be built. Revision 57 derives the absent-live
profile from visible model/auth/identity truth, producing `fail` and preserving
the blocked row. Its repaired publisher then produced that truthful pair and
isolated the sole blocked row to the trusted outer launcher: the fresh tmpfs
masking the credential parent defaulted to mode `0755`, so the sealed verifier
correctly rejected the remounted auth input. Revision 58 changes only that
fresh tmpfs to owner-only `0700`; the identical exact outer-namespace Codex
probe then exits zero. Revision 59 repaired later compiled-runtime, transactional
copy, and ledger-provenance findings, but its security review found two further
P1s: the staged publisher could still read the Codex auth copy, and lexical
BEAM shape checks could admit a forged raw-response peer. Revision 60 removes
both sensitive surfaces from the publisher and adds the exact external
supervisor binding described above. Its readiness suite passes 56/56; its
external adversarial suite passes 14/14; its targeted protected Linear replay
records nine queries and zero mutations; and its targeted no-model Codex replay
records eight read-only receipts with no thread or turn. These pre-freeze
results do not replace the final exact-tree gate or both fresh independent
reviews.

Every register status below that names an earlier revision is retained as
rejected predecessor context and is superseded by Revision 66. The repaired
control requires complete checkout inventory/mode/blob-OID/source inspection
before and after execution, a supervisor-built publisher-invisible runtime,
strict compiled/native projection, and current-user ownership for protected
inputs and parents. Its final external adversarial suite passes 47/47, and an
independent real credential-free exact-tree build projects 36 sorted runtime
applications and removes its builder before sealing. The capability deadline
releases only after timely successful cleanup and an independent cleanup check;
post-join acceptance rejects missing or late cleanup timestamps. A targeted
review returns GO with no remaining P0/P1/criterion-impacting P2 in this repair
scope. The first protected Linear attempt stops before child/key/provider when
its nested AF_UNIX socket exceeds the kernel pathname bound. The repaired
supervisor-private short socket is type/owner/mode/device/inode-bound, invisible
to the publisher, and removed only after worker/child teardown; its targeted
review also returns GO. The protected replays remain valid targeted evidence;
the later documentation-frozen gate and reviews are rejected below.
Normal query-broker shutdown owns only its internal stop and resource closure;
it cannot set the caller-owned transaction cancellation event. Supervisor
shutdown explicitly sets that event first, while the EOF watcher retains
disconnect ownership. Targeted cancellation-ownership tests and review pass.
The repaired protected replay then verifies the dedicated project/team, states,
labels, fixture stability, comment, blocker, and schema-only mutation evidence
with exactly nine fixed queries and zero mutations. Neither fixture changes;
only the content-free public receipt and categorical projection leave the
supervisor boundary.
The protected Codex replay verifies installed `0.144.3`, eight ordered read-
only receipts, a complete passing reference profile, and `noModelWork=true`.
No thread, turn, or model work starts; raw account data, email, exact quota
values, credentials, and private paths remain outside repository evidence.
The first coherent pre-freeze publisher passes all 13 rows; pair/installed
verification, no-model smoke, hygiene, and two-pass archive reproduction also
pass. The documentation-frozen Revision 63 publisher then produces an
internally consistent but release-blocked pair on tree
`1faeb93318a9714963fca79a2e6142e73cc9120e`: 11/13 required rows pass,
`installed_codex_verify` and `upstream_make_all` are blocked, runtime is
`blocked`/`blocked_r0_06`, and 351 blockers are derived. The publisher
incorrectly stages the pair and reports success because semantic consistency
was treated as acceptance. Both fresh reviewers independently return NO-GO
with the same P1. Revision 64 separates source-bound prepublication
source/schema/installed-Codex verification from canonical pair verification
and requires a truly green pair before compiler return, before and under
publication, and during final canonical verification. Reseal, one repaired
publisher, affected post-gates, and two fresh reviews remain mandatory.
The Revision 64 repaired publisher was resealed at exact staged tree
`77baaf6bdc182c148b180afee81946e4a34f3ad8` and passed its 549-case
source oracle, dedicated installed-Codex verifier, exact 157-test harness,
deterministic regeneration, and private runtime construction before failing
closed on the final semantic Git-metadata fingerprint. It published no
candidate pair and accepted no protected capability result. Concurrent
read-only audits issued Git reads in the canonical worktree during the sealed
interval, but the aggregate failure does not identify the changed component
and a later status-refresh experiment did not reproduce semantic drift; no
narrower cause is asserted. No Linear mutation occurred and neither fixture
changed. Revision 65 therefore changes evidence only and requires the one
freshly resealed publisher to own an exclusive canonical-worktree interval:
no agents, Git readers, or parallel worktree commands may run before it exits.
The Revision 65 retry preserved that metadata fence and passed every earlier
required row, but its final `upstream_make_all` child exhausted the audited
1,800-second deadline while parallel external agents and host workloads were
active. It prepared no transaction, published no pair, accepted no protected
result, executed no Linear mutation, and changed neither fixture. A
credential-free diagnostic reconstructed the exact staged snapshot and private
sandbox and passed only that row in 1,248.048 seconds with 660 tests, 100%
measured coverage, clean Credo, zero Dialyzer errors, no error marker, complete
metadata-safe and version-consistent PLTs, a 15.422-second byte-stable offline
replay, complete generated outputs, and every remaining integrity oracle. The
audited bound remains valid under exclusive release resources; no source repair
or bound inflation is justified. Revision 66 changes evidence only and requires
the final publisher to own the host-resource window: no agents, diagnostics,
Git readers, or parallel host workloads may run until it exits.

## Threat and control register

| Boundary / threat | Required invariant and mitigation | Required verification | Status / owner |
|---|---|---|---|
| Fork confusion or upstream push | Exact fork parent/remotes; upstream push disabled; protected main; exact-SHA PR merge only. | Remote/permission Doctor, branch-rule API proof, failed-bypass policy test, ancestry check. | Governance configured; R0-07 automation pending / release controller |
| Candidate code gains release credentials | Candidate jobs read-only and secret-free; no `pull_request_target`; publication only from protected merged main. | Workflow permission lint and adversarial PR inspection. | Pending R0-07 / release controller |
| Candidate self-spoofs `studio/release-gate` | Check-name and GitHub-Actions app binding alone are insufficient. Gate control must come from protected base state or an equivalently immutable attestation, bind exact head/base/manifest/workflow hashes, reject unauthorized gate-workflow changes, and never run candidate code with write credentials. | Adversarial duplicate-name and modified-workflow tests; verify check producer, event, workflow/ref/blob hash, head/base and sealed manifest. | Identified in R0-01; blocking R0-07 design and publication / release controller |
| Tag/release substitution | Immutable version, sealed head/base/tree manifests, build from merged main, downloaded-asset hash verification. | Idempotency, stale-head denial, remote tag/asset/provenance tests. | Pending R0-07 / release controller |
| App Server framing, stdout injection, operation confusion, or diagnostic disclosure | Strict JSONL framing, 16 MiB decoded-frame default, request/response correlation, stderr separation, absolute deadlines, idempotency-classified bounded overload retry, and content-free bounded stderr classification. A UUIDv4 logical operation ID is assigned before transport, remains stable when an idempotent retry receives a new wire request ID and through uncertainty, and differs for intentional repeated calls; private parameters are excluded. Raw stderr and its content hash are not retained or projected. Unsupported workflow features emit only `failure_kind=unsupported_release_feature`; Orchestrator neither raw-inspects the feature/release tuple nor mislabels it as a tracker-fetch failure. A source-identity-bound `0600` compatibility circuit blocks dispatch after protocol corruption until a replacement manifest is green. R0-04 correlation is in memory; the durable ledger and crash reconciliation remain R1-07. | Split/coalesced/malformed/oversize/stdout-noise/duplicate-ID/unexpected-ID/late-response, overload, distinct-operation, stable-retry-ID, tool-uncertainty, parameter-canary, circuit persistence/staleness, and source-bound conformance tests. The remote hot-reload log oracle requires the exact safe workflow-validation line, rejects `Failed to fetch from tracker`, `remote_workers`, and `release_5`, retains blocked state, and proves no SSH dispatch. | R0-03 transport, R0-04 in-process operation correlation, and the repaired R0-05 unsupported-feature classification accepted and independently reviewed; durable reconciliation remains R1-07 / transport owner |
| Capability-probe poisoning, invented compatibility, or quota spend | Capability discovery uses the exact generated 0.144.3 schema, one initialize/initialized connection, bounded model pagination and response fields, strict required/optional result types, provider-supplied opaque IDs, and content-free diagnostics. The no-model probe may call account, quota, model, feature, and collaboration-mode metadata reads only; it never starts a thread/turn, consumes a reset credit, or treats absent optional data as support. Public report `status=available` remains descriptive, while its successful request receipt is normalized to outcome `pass`; unsupported, unavailable, auth-restricted, and transient transport outcomes remain distinct and fail closed. Static schema, deterministic fixture, and live evidence remain distinct. Hidden reference-model observations are excluded from the public model list but retained as a complete `referenceProfile`; its status must equal its component truth values and those values must agree with the visible model, effort, authentication-mode, and identity-binding projection. All candidate-aware setup, compilation, and staged publication is credential-free and fingerprinted before the external supervisor launches the exact direct no-model runner with only a disposable credential copy. | Param omission, required/optional truth tables, malformed/oversized/repeated-cursor pages, full/sparse quota, account/auth variants, tier/effort/model matrices, hidden/reference-profile omission and contradiction, one-connection cleanup, available-success/unsupported receipt mapping, credential-blind build/publisher canaries, private-output and child-output-bound canaries, blocked-live full-report fallback, transient optional-read blocked-pair plus source-identical recovery, public-history protected-selector scan, private-runtime seal/tamper canaries, and a live request receipt proving no `thread/start` or `turn/start`. | Revision 44, Revision 59, Revision 61, and Revision 62 are rejected after fresh review. Revision 63 protected no-model evidence remains valid, but its documentation-frozen pair and both reviews are rejected P1. Revision 66 publication and fresh reviews remain / capability owner |
| Orphaned or escaped local process | Shell-free App Server argv and per-attempt containment chain; empty-env containment launcher/target bootstrap; user/PID/mount namespace; exact blocked PID 1 and PID 2 capture; target `setsid`; non-dumpable trusted init; pidfd-bound root and outer-group teardown; success only after manager absence, empty anchored-group membership, and exact namespace-root retirement. R0-05 reuses that boundary for local hooks and places registered `CleanupBarrier`, `CleanupSupervisor`, direct `ConnectionSupervisor`, hook/agent supervisors, and Orchestrator in one ordered `:one_for_all` domain with restart intensity bounded to 10 in 5 seconds. Every guardian acknowledges only after trapping exits and monitoring its owner; its handle carries durable verification state. CleanupBarrier and CleanupSupervisor are reciprocal restart barriers if either one crashes. CleanupBarrier also registers and monitors every established Connection, AgentRunner, and WorkspaceHookRunner lifetime, preventing a killed nested Connection/Task/WorkspaceHook supervisor from admitting replacements around a trapped predecessor member. A Connection traps supervisor exit and cannot retire without verified cleanup or a detached guardian handoff. It delegates even its first ordinary physical stop to `CleanupGuardian.request_cleanup_once/2`; only guardian workers invoke `adapter.stop`, and a failed result commits guardian authority before any later close, owner-down, supervisor-exit, child-exit, or terminate path. Barrier-registration loss keeps one cleanup actor: the acknowledged guardian remains authoritative while CleanupSupervisor survives; if both runtime authorities are absent, startup waits for durable guardian proof before raising into inline cleanup. AgentRunner and WorkspaceHookRunner retain startup-cleanup handles, accept late exit only when durable status is verified, and hold indefinitely after unverified authority loss. Active-turn interruption and verified connection/worker/hook retirement remain prerequisites to lifecycle progress. The long-lived vendored `exec-port` is a trusted upstream runtime boundary. Remote workers remain release-gated. | Owner crash, timeout, anchor loss, ptrace, inner-group signal, PID reuse, TERM resistance, detached `setsid` descendant, cleanup-evidence truth table, 100-iteration hostile cleanup replays, hook timeout/output/owner-death cleanup, active-turn cancellation order, direct-Connection shutdown, guardian-only failed-close-plus-owner-death maximum-concurrency-one handoff, pre-ready guardian death, real partial-startup handoff, late handoff/authority-loss status, held-guardian restart, reciprocal CleanupBarrier/CleanupSupervisor crash barriers, barrier-registration single-owner/max-concurrency, ConnectionSupervisor-crash maximum-concurrency-one cleanup, killed Task/WorkspaceHookSupervisor predecessor-retirement barriers, and no-orphan-at-return tests. | App Server containment accepted in R0-03; R0-05 cleanup authority, hooks, cancellation, and runtime barriers accepted and independently reviewed; remote cleanup remains unsupported / runtime owner |
| Forged, conflicting, cross-run, stale-attempt, or unbounded event delivery | Canonical UUID validation; deterministic UUIDv5 event identity; positive monotonic per-run sequences; exact-duplicate convergence; typed conflict, gap, and eviction results; an append attempt before live projection; stale-attempt isolation; bounded process-local retention; and a retaining-nothing default that preserves runner independence. A successful append to an available sink precedes projection. Sink unavailability or lost process-local history produces a sanitized diagnostic and is fail-open, while invalid producer correlation or conflicting history cannot advance the projection. | Identity/envelope bounds, duplicate/conflict/gap/eviction/replay, cross-run, malformed-correlation, stale-attempt projection, configured-sink, sink-failure logging/redaction, and fail-open history-loss tests. | R0-04 in-process boundary accepted and independently reviewed; durable/restart/browser replay remains R1-01/R1-02 / event owner |
| Secret leakage to child, hook, probe, event, or durable state | Target-only, bounded binary environment frame after exact capture; empty per-attempt containment-launcher and target-bootstrap environments; bounded/redacted transport diagnostics; and allowlisted, bounded, JSON-safe normalized event payloads. R0-05 local hooks receive only an explicit environment allowlist and report content-free byte/truncation metadata under one aggregate output ceiling; raw hook output is not copied into errors or logs. For R0-06, every generic gate, build, and network-enabled staged-publisher namespace is credential- and raw-response-blind. The publisher's credential-free runtime fingerprint remains an integrity oracle but authorizes no credential-bearing byte. Protocol v4 seal request/response frames carry only the original tree and an opaque transient seal ID. Before publisher launch, the external supervisor independently reconstructs that tree and builds the complete dev runtime under fixed lexical paths: locked dependency acquisition is credentialless, and locked replay, dependency/application compilation, and erlexec construction are separately networkless. After the builder process group is dead, all sorted app `ebin` roots plus exact native `exec-port` are descriptor-projected into a second private root and revalidated. No publisher work root, build, dependency, erlexec byte, digest, or temporary name participates. Later capability requests carry the seal ID and public source/tool/installed-Codex hashes over an owner-only socket. The supervisor requires every request to match the startup tree, pins the exact publisher process identity, and finishes private construction before any credential preparation, key-content read, provider access, or child launch. Only supervisor-private roots are mounted into children. It independently checks staged source, runtime, tools, and installed Codex, and Linear peer attestation derives from the private code roots. Only the exact Codex child receives a disposable writable copy of minimum auth/identity inputs; installation and cleanup are transactional. The Linear key and raw responses remain solely in the trusted supervisor-side broker; only the exact supervisor-launched, byte-attested, separately networkless Linear child sees its fixed socket. Neither runner invokes Mix, Hex, mise, Rebar, erlexec, project aliases, runtime configuration, or task discovery after sealing. One absolute 600-second supervisor deadline covers build, credential operations, post-validation, response, zeroization, non-daemon broker/process-group reaping, and verified root removal before the protected descriptor closes; the client waits 660 seconds. Direct-child output, temporary state, and crash dumps are bounded/private. Prompt/issue bodies, raw provider frames, stderr, hook output, credentials, private errors, raw email, reasoning, selectors, and protected paths are excluded from durable/public surfaces. No secrets or host paths may enter SQLite, artifacts, logs, backups, releases, or media. | Exact target/hook/probe environment and loader-control canaries; original/startup-tree mismatch and transient-index substitution denial; four-key seal/request-shape and wrong-seal denial; poisoned publisher path non-use; exact publisher-process replacement denial; tool/lock/checksum/build-network-phase drift; pre-auth compiled/native-runtime replacement denial; shared tamper/restore and private-seal race canaries; transactional partial-install cleanup; hostile networked-publisher absence across paths/env/argv/fds/mounts; key file owner/mode/link checks; supervisor socket/root metadata checks; exact peer lineage/executable/code-root/namespace/route/socket attestation before key read; absolute-session-deadline, disconnect, builder/child process-group and non-daemon reaping, key-zeroization, cleanup-order, and root-removal tests; strict public projections; fixed-query broker request/variable/order/framing/redirect/size tests; hook and partial-response canaries; readiness/archive scans; later DB/API/UI/media canaries. | Earlier accepted R0-03/R0-05 controls remain valid. Revision 54, 55, 58, 59, 61, and 62 evidence is rejected for the documented credential/path/runtime/publisher/peer/shared-runtime/provenance/deadline findings. Revision 63 external validation and protected replays remain valid targeted evidence; its documentation-frozen pair and both fresh reviews are rejected P1. Revision 66 final publication and reviews remain / security owner |
| Cross-account continuation | Safe domain-separated keyed identity binding plus local generation; no raw email or undocumented token parsing. Missing or changed identity evidence invalidates resumptions and cached quotas and requires explicit confirmation. R0-06 discovers and reports the binding only; durable generations and resume decisions remain later work. | Protected-key path/mode/owner/symlink tests, auth-mode/account-change variants, no-raw-email report/artifact canaries, and later durable wait/resume tests. | Revision 63 protected discovery remains valid targeted evidence; its frozen pair and reviews are rejected. Revision 66 final publication/reviews and R1-06 durable continuation remain pending / quota owner |
| Recursive delegation or ineffective cap | The manifest distinguishes raw V1/V2 root-count semantics from native depth behavior. Codex 0.144.3 V2 does not enforce `agents.max_depth`; it must be reported false. A bounded trusted Studio hook permits the root and denies a child's recursive spawn when executed, but hook execution failure is explicitly fail-open. The hook is defense in depth, not sole authorization; R1-05 must also enforce deterministic admission and interrupt excess starts. | Raw `1/2/3` cap tests for zero/one/two optional children, native depth-two regression, hook allow/deny/malformed/oversize tests, exact trust flow, blocked grandchild, and fail-open hook-failure grandchild. | Revision 63 source-bound evidence remains valid targeted evidence; its frozen pair and reviews are rejected. Revision 66 final publication/reviews and R1-05 admission/interruption remain pending / runtime owner |
| Linear prompt, credential, partial-response, or GraphQL injection | Treat fields as data. Ordinary runtime authorization may reach only the canonical Linear endpoint; redirects, content encoding, oversized bodies, mutable snapshots, and top-level GraphQL errors fail closed before data can clear blockers, admit dispatch, resolve state, or claim mutation success. Upstream raw access still permits exactly one parsed query or mutation and preserves its envelope; managed access keeps its bounded read-only AST and trusted issue/run binding. R0-06 sealed discovery gives candidate code and the staged publisher no key or raw provider body. Only the exact supervisor-launched peer may access the broker, and that peer has no network. Its lineage, BEAM executable bytes, every private code-root byte, fixed entrypoint/environment, namespaces, route table, and socket inode are attested before key read or provider request. Both its `-pa` paths and expected peer fingerprints must derive from the completed publisher-invisible supervisor seal, never publisher-writable shared build paths or a publisher-authored digest. Its trusted broker accepts only six fixed query enums in the exact nine-request initial/final transcript, owns the canonical TLS host/port/path and Authorization header, binds project/team/fixture variables, rejects arbitrary query/URL/method/header/auth/mutation/replay/extra requests before transmission, and records `mutations=0`. Raw bodies remain supervisor-side; the public projection retains categorical capability/schema evidence only. Schema introspection remains a fixed query and public mutation evidence remains `schema_only`. | Ordinary endpoint/redirect/encoding/size/snapshot and partial-envelope tests; raw-envelope preservation; malformed/multi-operation and managed-policy denial; exact query-to-enum mapping; unknown/mutation query denial; credential-runtime drift and wrong-seal denial; broker duplicate/oversize/order/variable/redirect/fixed-host tests; forged-BEAM and pre-key-read denial; shared-runtime tamper/restore and private-peer-root canaries; hostile networked-publisher and inner no-network canaries; public-projection strictness; capability project/team/state/label/comment/blocker stability and schema-only evidence; final broker receipt with nine queries and zero mutations. | R0-05 parser/managed seam accepted. Revision 54, 55, 58, 59, 61, and 62 evidence is rejected for the documented credential/provenance/peer/shared-runtime/runtime-authorization gaps. Revision 63 protected query-only evidence remains valid with nine queries and zero mutations; its documentation-frozen pair and reviews are rejected. Revision 66 final publication and reviews remain / tracker owner |
| Cancellation, retry, or cleanup race releases unsafe work | Active cancellation must interrupt the known turn, retire the App Server connection, attempt worker, hook runner, and hook descendant, run `after_run` once, then run `before_remove` and delete only the attempt-bound workspace. Any missing binding, unverified retirement, lost cleanup authority, or cleanup failure must preserve the workspace and safety claim without retry. A restarted orchestrator cannot coexist with predecessor Connections, agents, hooks, or startup-cleanup guardians, including after a nested supervisor is killed. Neither an ordinary Connection teardown race nor cleanup-barrier failure may create concurrent guardian and direct/inline stop callers: CleanupGuardian is the only physical-stop authority for an established Connection, and a failed delegated request makes guardian ownership permanent. Every retry-entry removal cancels its timer before state deletion. | Active-turn lifecycle-order oracle using process identity; explicit `after_create`/`before_run`/`after_run` cleanup-failure propagation with bound-workspace preservation; suspended TERM-resistant hook cancellation and runtime-restart barriers; same-sender hook lifecycle ordering; durable verified-versus-lost guardian status; guardian-only failed-close-plus-owner-death maximum-concurrency-one handoff; reciprocal cleanup-barrier crashes; barrier-registration single-owner/max-concurrency; ConnectionSupervisor-crash maximum-concurrency-one cleanup; Task/WorkspaceHookSupervisor crash predecessor-retirement barriers; duplicate terminal/late message and cleanup-failure convergence; hot-root-reload exact-bound cleanup; stale retry-token/timer removal; and Orchestrator-crash connection/task/guardian retirement tests. | R0-05 cancellation, supervised hook containment, and cleanup-authority barriers accepted after final-tree replay, complete gate, and independent package review / orchestration owner |
| Workspace traversal or symlink escape | Resolve relative roots against the selected `WORKFLOW.md`, canonicalize the root once, map unsafe/oversized identifiers with a collision-resistant suffix, require every local issue leaf to be a direct non-symlink child, bind active cleanup to its captured path/root, and revalidate around `before_remove`. Fresh bootstrap failure may roll back only the newly created workspace; a reused workspace is never reset. Managed writable roots equal the exact issue workspace. No Docker socket is mounted. | Deterministic adversarial identifier corpus; same-root/sibling/out-of-root/broken/loop/long-chain symlinks; root reload; direct-child and cleanup denial; fresh rollback versus reused preservation; managed sandbox root/type/network tests. Userspace pathname revalidation is accepted only inside the declared one-trusted-local-operator, non-hostile-same-UID Release 0 boundary; all untrusted candidate/hook processes must retire first. | R0-05 local controls accepted and independently reviewed; multi-user or hostile same-UID operation remains unsupported and team expansion begins in Release 5 / workspace owner |
| Network overreach | The upstream sandbox resolver remains compatible. Opt-in managed mode allows only pinned read-only or exact-workspace-write variants, binds the writable root to the canonical issue workspace, defaults network off, preserves only explicit network opt-in, rejects broad variants and managed remote work, and keeps remote UI mode unsupported in Build Week. | Managed sandbox root/type/network and remote-denial tests; R1 role-policy and Doctor exposure tests. | R0-05 managed narrowing accepted and independently reviewed; broader R1 runtime/Doctor policy remains pending / runtime owner |
| Unauthenticated UI read or mutation | Loopback default, one-time pairing, `0600` signing secret, strict signed cookie, CSRF, Origin and Host checks, revocation. | Pair/replay/logout/restart, unauthenticated read, Host/Origin/CSRF and cookie tests. | Pending R1-13 / web owner |
| Showcase privilege escalation | Separate expiring read-only capability; no inherited operator mutations or secret-bearing data. | Route/action matrix and expired/forged capability tests. | Pending R1-19 / web owner |
| XSS or unsafe artifact delivery | Escaped templates, sanitized Markdown, no raw HTML, restrictive CSP/headers, authorized bounded download paths. | Stored/reflected XSS corpus, header checks, MIME/path/range/size authorization tests. | Pending R1-13–20 / web owner |
| Approval/input spoofing | Only typed App Server requests create blockers; deny forbidden autoapproval classes; fail closed on unknown/expired input. | Spoofed event, replay, timeout, ownership and policy-denial tests. | Pending R1-12 / lifecycle owner |
| False completion or stale evidence | Completion derives from persisted reducer, fresh evidence, detached review and tracker sync—not UI labels or agent prose. | Staleness, restart/replay, review/repair and terminal-outbox tests. | Pending R1-10–12 / quality owner |
| Readiness spoofing, host-state contamination, or false-green Dialyzer | Evidence compiles from exact staged source and pinned tools inside non-root, zero-capability sandboxes with private Git/HOME/XDG/dependency/Hex/Mix/build/coverage/escript/archive state, masked host temp/tool roots, private devices, finite writable mounts, semantic Git fingerprints, bounded output, and strict command/status truth tables. Five dependency phases use bounded setup source; the final offline warnings-as-errors compile removes it and reads the immutable staged snapshot. The nested fixture may reuse only validated fingerprinted private Hex/Mix/Rebar/NIF inputs under `HEX_OFFLINE=1`; bounded no-follow clones are created only where offline tools require writes, with entry/byte bounds before allocation/sort/copy and source identity rechecks. Compilation finishes before complete source/dependency/tool/code-root/build/link fingerprints. A distinct immutable post-bootstrap fingerprint binds every compiled `dev` ebin byte plus the exact native `exec-port` tree either sealed task can run; generic-gate build changes never advance it as a local integrity oracle, but no publisher fingerprint authorizes credential-time execution. The network-enabled staged publisher is credential/raw-response-blind and delegates seal-ID-bound live work to the external supervisor. It carries the gate's original index tree; the supervisor independently pins the startup tree before publisher launch and rejects any mismatch before private reconstruction. Before any credential preparation, key-content read, provider access, publisher launch, or capability child, the supervisor reconstructs the exact Git-index workspace and independently builds the dev runtime under fixed lexical paths in a credentialless namespace. Only locked dependency acquisition has network; replay and all compilation are networkless. After its builder process group is dead, it descriptor-projects all app `ebin` roots and exact native port into a second publisher-invisible root. Protocol-v4 seal frames contain only the tree and opaque seal ID; later capability requests cannot supply executable bytes, a digest, or a shared source name. The supervisor pins the exact publisher process across requests and validates its completed projection, pinned tools, installed Codex bytes, child lineage/executables/code roots, output bounds, strict public projections, and one absolute session deadline through response, zeroization, non-daemon/process-group reaping, verified root removal, and protected-descriptor closure. Only the exact Codex child receives the disposable credential copy; only the networkless exact Linear child receives the raw broker socket. The public projection retains and cross-checks the complete hidden reference profile. A blocked full live row derives an all-false `fail` profile from the same visible-model/auth/identity truth function rather than reusing the `not_run` pre-execution default. The ledger parser requires every normative history row to parse monotonically and the header to equal the latest record. Only one final record may reach stdout. Prepublication source/schema/installed-Codex validation is a distinct source-bound operation and never consults the superseded readiness pair. Canonical consistency is insufficient for release acceptance: the exact 13 required rows must all pass, blockers must be empty, runtime/platform/package status must pass, and paired-schema runtime/overall status must pass. A blocked pair is diagnostic only and cannot be archived as the candidate, staged, committed, or reported as published; compiler, publisher, under-lock, and final verifier boundaries enforce this independently. Outer/nested bounds, private `make all`, separate offline Dialyzer replay, error-marker rejection, version-consistent PLT filenames/versions/hashes, byte-identical replay, fully unsealed fixture candidates, exact manifest summaries, and optional-lock writer rules remain mandatory. The final publisher owns an exclusive host-resource window; agents, diagnostics, Git readers, and parallel host workloads are prohibited until it exits so the audited child deadline measures the candidate rather than external contention. | Sandbox identity/capability/mount/write/path/provenance canaries; exact five-dependency/one-application source selection; offline Hex/NIF/Mix-tool metadata and bound negatives; empty app-root rejection; hostile candidate Mix/alias/config/Rebar/rogue-Codex canaries; compiled direct entries; pre-auth runtime replacement and transactional partial-install cleanup; hostile publisher secret absence; original/startup-tree and supervisor/root/socket/private-checkout canaries; protocol-v4 seal/wrong-seal/poisoned-publisher-path/publisher-replacement/private tamper canaries; exact private peer executable/code-root/network attestation; absolute deadline, disconnect, zeroization, builder/child process-group and non-daemon reaping, cleanup ordering, and root-removal tests; strict public projections; exact broker transcript/receipt; argv/environment/workflow/runtime-tool checks; ledger header/history mismatch; hidden/reference contradictions; blocked-live fallback; snapshot drift and post-build negatives; outer-marker/private-Mix/timeout/device/temp/nested-Git canaries; publication lock/crash regressions; PLT/offline-replay negatives; exact suite summaries and archive rehearsal. | Revision 54 through Revision 62 evidence is rejected by the documented raw-key/path/runtime/copy/provenance/publisher/peer/hygiene/shared-runtime/runtime-authorization/deadline findings. Revision 63 external validation remains valid targeted evidence; its documentation-frozen 11/13 blocked pair and both fresh NO-GO P1 reviews are rejected. Revision 66 final publication and reviews remain / release-evidence owner |
| Stale or torn readiness/schema publication | Source, schema, readiness, and index evidence must refer to one candidate tree. Publication uses an alternate index, private journal, durable original/candidate copies retained through final candidate verification, fsync, source-race recheck, and no-follow paths. Git plumbing receives a secret-free allowlisted environment, excludes ambient configuration, and disables helpers. Owner/group, single-link state, and accepted index mode are validated and preserved. Before any final-verifier Git call, the durable original index occupies the conventional `.git/index.lock` fence. The fenced candidate is copied to a private transaction-owned verifier index used through explicit `GIT_INDEX_FILE`. Staged-tree and entry/flag equality tolerate stat-cache-only byte refresh; a durable verification-attempt record binds the current raw candidate for crash recovery. Verifier-index residue is disposable only after safe metadata/semantic validation. An ambiguous non-locking writer preserves its index plus the journal/rollback and never returns success. Patch-ledger history is parsed independently of its header and must reconcile before publication. Any later source or documentation edit invalidates the pair and requires republishing. The dedicated prepublication verifier must not consult the superseded pair that publication replaces. Semantic consistency is necessary but insufficient: only an exact green acceptance predicate may prepare or finalize a publication transaction. The same transaction requires a host-resource-exclusive execution window through publisher exit. | Real ambient/local fsmonitor execution canary; pre/post-commit, prepared-fence, verifier-write/mode, rejection-exchange, and verified-fence crashes; private-index residue recovery; final-window writer preservation; semantic stat-refresh cases; verifier rollback; real `write-tree`, source binding, diff, checkout, and bounded archive through the private index while the live fence exists; stale journal/backups; ledger stale-header/malformed-history negatives; symlink/special path denial; unsafe owner/mode/hardlink/parent negatives; mode preservation; and pair verification from the final staged tree. | Every pre-Revision-63 pair is rejected. The Revision 63 documentation-frozen pair is also rejected because it was internally consistent but blocked and was incorrectly staged/reported successful. Revision 66 repaired publication, verification, and both exact-tree reviews remain / release-evidence owner |
| Quota exhaustion before validation | R0-06 discovers full/sparse/multi-bucket quota shapes and keeps credits, spend control, usage, and opaque bucket IDs distinct. R1 adds protected reserve, priority lanes, durable waits, and admission; discovery itself uses no model turn or reset credit. | Full-read replacement versus sparse patch fixtures, absent/optional usage, credits/spend-control shape tests, no-thread/turn live probe, then R1 reset/restart/account-change and reserve tests. | Revision 63 protected no-model discovery remains valid targeted evidence; its frozen pair and reviews are rejected. Revision 66 final publication/reviews and R1-06 policy remain pending / quota owner |
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
