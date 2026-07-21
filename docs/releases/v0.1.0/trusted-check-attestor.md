# R0-07 trusted CheckRun attestor

The successful `studio/release-gate` CheckRun is created by a reviewed,
owner-invoked attestor outside GitHub Actions and outside every Git worktree.
Candidate code and candidate workflows never receive the credential that can
satisfy protected `main`.

## Dedicated GitHub App

Use a dedicated GitHub App installed with **selected repositories** set to only
`farhaanlevy/symphony-studio`. Its repository permissions must be exactly:

- Metadata: read;
- Contents: read;
- Actions: read;
- Pull requests: read;
- Checks: write.

No other repository or organization permission is allowed. The App private key
and its short-lived installation tokens must never be Actions secrets, workflow
inputs, repository files, release assets, model inputs, or candidate-process
environment. This App and attestor have no pull-request write or revert
authority. A post-merge failure stops with action-required for a separately
authorized human recovery flow.

Before any mutation, the attestor queries the authenticated installation and
requires the exact expected App ID, the exact permission map above, an active
selected-repository installation, and an inventory containing exactly the one
intended repository.

## Credential-free external seal

First review `scripts/release/trusted_check.py` and its tests. Independently
approve the public source digest recorded in
`scripts/release/trusted_check.sha256`; do not accept a digest merely because it
appears in the candidate manifest or pull-request body.

With no App token or private key in the environment, copy the reviewed program
to a new owner-only directory outside every repository and worktree:

```bash
attestor_dir="$HOME/.local/state/symphony-studio-attestor"
attestor="$attestor_dir/trusted_check-<approved-attestor-sha256>.py"
install -d -m 700 "$attestor_dir"
/usr/bin/python3 -I scripts/release/trusted_check.py seal --output "$attestor"
```

`seal` fails if the source does not match the committed public digest, if a
token is present, if the destination is not a new regular file, or if the
destination is inside a Git worktree. It creates the external file as owner-only
mode `0500` and emits its public SHA-256 receipt. Compare that receipt and an
independent `sha256sum "$attestor"` with the approved attestor digest before
continuing.

Do not reuse or overwrite an older sealed file. A reviewed attestor change gets
a new public digest and a new external filename.

## Out-of-band approval inputs

Before acquiring a token, independently record the exact approved SHA-256 for
each of these exact-head files:

- `.github/workflows/make-all.yml`;
- `.github/workflows/pr-description-lint.yml`;
- `.github/workflows/release-gate.yml`;
- `.github/workflows/publish-release.yml`;
- `scripts/release/release.py`.

Also independently record the canonical record SHA-256 for:

- the evidence-review `GO` record;
- the release-security-review `GO` record;
- the `r0-07-complete-gate` passing test record.

These values, the reviewed attestor SHA-256, the dedicated App's public numeric
ID, the pull-request number, and the exact 40-character release head are the
non-secret approval inputs. Obtain them from the owner-controlled review and
release record, not from candidate-authored claims alone.

## External attestation

Leave the candidate checkout before introducing the token. Disable shell
tracing, clear Python path overrides, acquire a short-lived installation token
out of band into a shell variable without echoing it, and run only the sealed
external file:

```bash
cd "$HOME"
set +x
unset PYTHONHOME PYTHONPATH
read -rsp 'Short-lived trusted-check installation token: ' token
printf '\n'

SYMPHONY_TRUSTED_CHECK_TOKEN="$token" \
  /usr/bin/python3 -I "$attestor" attest \
    --pull-request <number> \
    --head-sha <exact-release-head-sha1> \
    --attestor-sha256 <approved-attestor-sha256> \
    --trusted-app-id <dedicated-app-id> \
    --make-all-sha256 <approved-make-all-sha256> \
    --pr-description-lint-sha256 <approved-pr-lint-sha256> \
    --release-gate-sha256 <approved-release-gate-sha256> \
    --publish-release-sha256 <approved-publish-release-sha256> \
    --release-controller-sha256 <approved-release-py-sha256> \
    --evidence-review-record-sha256 <approved-evidence-review-sha256> \
    --security-review-record-sha256 <approved-security-review-sha256> \
    --complete-gate-record-sha256 <approved-complete-gate-sha256>
status=$?
unset token
exit "$status"
```

The assignment applies only to the sealed attestor process. The token is not a
command argument or file and is removed from that process environment as soon
as it starts. Do not use `env`, `printenv`, shell tracing, `gh`, a build tool, a
test runner, or a model process to carry or inspect it.

Both modes require Python isolated mode (`-I`), which excludes the current
directory, user site-packages, and Python path environment overrides. At
startup, `attest` proves that its running file is owner-owned mode `0500`, is
under an owner-owned mode `0700` directory outside every worktree, and exactly
matches `--attestor-sha256`. It does not import or execute candidate modules.

## Fail-closed decision

Before its sole possible POST, the attestor:

1. validates the dedicated App installation, exact minimum permissions, and
   single-repository scope;
2. reads the live open non-draft release PR and extracts its hash-bound,
   canonical candidate manifest;
3. proves the exact repository, branch, head, base, candidate tree, and GitHub
   test-merge tree;
4. fetches the five approved files at the exact head, verifies Git blob
   identity, and compares every byte digest with both manifest provenance and
   the owner-approved out-of-band value;
5. requires the two canonical review records and complete-gate record to match
   their owner-approved out-of-band digests;
6. verifies committed readiness and schema evidence is green and internally
   cross-bound;
7. selects the latest exact-head `make-all` and `pr-description-lint` CheckRuns
   from GitHub Actions, fetches each CheckSuite, queries the exact approved
   workflow path, selects the latest exact path/head/event/branch/repository
   run, and requires its suite ID to equal the named CheckRun's suite ID;
8. verifies the latest exact-path `release-gate` workflow run, its one expected
   job, all expected steps, and its bounded public artifact; artifact redirects
   never receive the GitHub Authorization header;
9. re-fetches every mutable PR, base, check, and workflow-run decision surface
   immediately before mutation and rejects any change.

The Actions release-gate artifact is untrusted evidence, not authority. It can
contribute only after the sealed attestor has independently validated the
owner-approved source and records.

Only then may the attestor create one completed successful CheckRun named
`studio/release-gate`. Its `external_id`, summary, and text bind the exact
canonical candidate-manifest bytes. The returned App ID and the stable fields
of the created CheckRun are revalidated; server-added output annotation fields
are tolerated but do not replace any expected field.

Re-running after a lost success receipt is safe only when the latest CheckRun
with this name, head, and dedicated App already matches the exact expected
payload. The attestor re-fetches and reuses that ID without another POST. A
newer incomplete, failed, or mismatched trusted CheckRun fails closed rather
than falling back to an older success.

On failure the command exits `78`, emits one content-free error identifier, and
creates no CheckRun. On success it emits a public canonical JSON receipt with
the repository, PR number, head SHA, candidate digest, CheckRun ID, and
`status: pass`. It never emits the token.
