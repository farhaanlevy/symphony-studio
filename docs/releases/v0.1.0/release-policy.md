# v0.1.0 release-controller contract

R0-07 separates candidate-controlled verification from the authority that can
satisfy protected `main`.

## Trust boundary

- Pull-request workflows are read-only, receive no publication credential, and
  never use `pull_request_target` to execute candidate code.
- The explicitly labelled untrusted Actions release-gate job is evidence for
  the trusted external attestor. It deliberately does not claim the protected
  `studio/release-gate` context because candidate code cannot be its own
  authority.
- Branch protection must bind `studio/release-gate` to one dedicated GitHub App
  that is not the general GitHub Actions App (`15368`). The attestor verifies
  the exact workflow blob, head, base, tree, test receipts, candidate manifest,
  and independent-review records before reporting success.
- The App is installed only on this fork with Metadata read, Contents read,
  Actions read, Checks write, and Pull requests read; it has no Contents,
  Pull requests, or Administration write. Repository variable
  `TRUSTED_CHECK_APP_ID` exposes only its public numeric identity. Its private
  key and short-lived installation token remain entirely in the owner-operated
  out-of-band controller and are never stored as repository Actions secrets.
  Its latest exact-head CheckRun must be
  completed/success, use the candidate-manifest SHA-256 as `external_id`, and
  carry the fixed title, digest-summary, and base64 canonical-manifest text
  contract. Older successes cannot mask a later pending or failed run.
- Administration-only publication Doctor checks run in that out-of-band
  controller/operator boundary. They never receive an administrator token in
  candidate-controlled Actions; the untrusted candidate job is limited to
  source, runtime, and evidence checks supported by its read-only token.
- Protected GitHub auto-merge creates the merge commit. The release controller
  never pushes directly to `main`, reproduces the merge locally, removes a
  requirement, or changes the required context to accept any app.
- Publication starts only from the exact merged `main` commit and uses the
  protected-main copy of `publish-release.yml` with job-scoped permissions.

## Candidate manifest transport

`release-candidate-manifest.json` binds an exact release head SHA, base SHA,
candidate tree, tested merge tree, workflow hashes, readiness/schema hashes,
test evidence, and two fresh independent reviews. It is generated outside the
checkout after the final commit and transported as a hash-bound workflow input.

This avoids an impossible self-reference: a committed file cannot contain the
SHA of the commit that contains that exact file. The canonical bytes appear in
the exact PR body and as the dedicated attestor CheckRun's hash-bound base64
attachment; protected-merge verification rejects any attachment mismatch. The
same bytes later become an immutable release asset. The manifest never enters
the checkout as an untracked file.

## Package and publication

- The package is built only from the exact merged commit.
- Build children receive no Linear, Codex-auth, GitHub, or other secret-shaped
  environment variable.
- The release escript embeds only public version/provenance values.
- The version-pinned Hex and checksum-pinned Rebar tool inputs, tracked source
  inventory, escript ZIP, and extracted tar inventory are all bounded before
  unbounded allocation;
  the normalized escript is archived twice with fixed ownership, mode,
  timestamp, ordering, and gzip metadata.
- The production escript application closure, dependency versions, SPDX
  licenses, license/notice texts, and any exact build-only determinism patch
  are committed and hash-locked. Build preparation rejects drift before
  compilation; provenance and the SBOM disclose each build-only patch.
- A clean extraction must run `symphony --version` with the exact expected
  output, preserve the guardrail denial path, and start the real packaged
  runner against a network-hermetic memory workflow. The Debian gate requires
  an HTTP 200 from `/api/v1/state`, zero admitted/model work, and complete
  process-group cleanup.
- All final draft assets, including the post-merge final manifest and checksum
  inventory, are uploaded, downloaded, and rehashed before attestation. The
  workflow attests those exact bytes before the separate finalize command can
  publish them.
- Repository release immutability must be enabled before the draft is created.
  After publication, GitHub locks the release tag and assets. An organization-
  owner policy may enforce the same setting but is not required for this
  user-owned fork.
- The immutable release manifest contains typed JSON-pointer references for
  publication time and status. A post-publication receipt supplies the causal
  facts that cannot exist inside a pre-publication immutable asset: actual
  publication time, published URL, tag target, release ID, Latest identity,
  asset count, final hashes, and immutable-release state. A protected custom
  attestation uses the immutable `release-manifest.json` as subject and stores
  the complete canonical receipt as its predicate. The workflow verifies that
  predicate and also preserves every available progress receipt under
  `always()`. This resolvable two-part record avoids fabricating a future
  publication timestamp while keeping every immutable release asset fixed
  before publication, as GitHub release immutability requires.
- Finalization records cleanup-pending facts before the remote release branch
  is deleted and reaches final `pass` only after exact deletion is observed.

## Idempotency and failure

A rerun may reuse only a draft or already-published release whose tag, merged
commit, asset names, sizes, and hashes match exactly. A later protected `main`
workflow source is allowed only when it descends from the release merge and its
`publish-release.yml` blob exactly matches the candidate-approved hash; packages
still come from the original merged commit and attestations bind the actual
workflow-source SHA. A tag without the matching release, a moved tag, a stale
base/head/tree, an asset mismatch, a failed clean install, or a failed download
verification blocks. Every post-merge failure preserves a bounded
`action-required` receipt and leaves `Latest` unchanged; Release 0 deliberately
does not store a pull-request mutation credential in repository Actions to
automate a revert. This is the visible action-required recovery allowed by the
release contract. In particular, an unstructured `make all` failure is not
sufficient proof of a merged-code defect, and the supported-platform job maps
only explicit package/runtime integrity diagnostics to `clean-install`;
unknown, bootstrap, upstream-fetch, and tool/network failures fail closed as
`environment-or-evidence`. Any active or merged manual release-revert branch or
pull request blocks publication until the owner resolves it; release automation
does not close, delete, create, or merge that state. No failed attempt replaces
Latest or deletes a prior stable release.
