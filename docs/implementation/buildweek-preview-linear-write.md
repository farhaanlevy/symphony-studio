# Build Week Preview: Linear write boundary

Status: production live write is disabled in this preview candidate.

The accepted R0 boundary keeps its query credential, selector, provider bodies,
and network access outside candidate-controlled Mix and BEAM processes. The
first preview design attempted to validate a second write credential inside the
preview BEAM. A fresh security review rejected that direction: candidate code
would receive both credentials, could substitute its own comparison input, and
would execute provider calls directly. Constant-time comparison inside the
candidate does not repair that trust failure.

The supported preview launcher therefore strips credential-shaped variables
from build and runtime children, and production Studio uses the unavailable
broker. Do not provide either Linear credential or environment-file pointer to
the preview command. The in-process typed adapter remains deterministic
test/prototype code only; it is not a production credential boundary and is not
injected by the supported application.

## Required future boundary

Re-enabling the path requires a distinct, versioned, trusted out-of-process
preview-write broker. It must not broaden or replace the R0 read-only broker.
The trusted broker must:

- own both credentials, validate their protected files, and prove the values
  differ without returning either value or selector to candidate code;
- retain the write credential and all provider network access;
- peer-attest the exact candidate process and expose only bounded typed command
  frames plus content-free receipts;
- permit only `issueCreate` in Backlog, `issueRelationCreate(type: blocks)`, and
  one selected first-ready `issueUpdate` to Todo for the dedicated project;
- reconcile deterministic issue, relation, and transition identities before
  execution and report partial or uncertain outcomes without blind retry;
- deny `SYM-1` and `SYM-2` before any provider operation; and
- use a separate team-scoped credential with only Linear Read + Write for
  Symphony Studio / `SYM`, with no Admin, comment, label, or workspace-wide
  capability.

The local STDIO MCP server persists owner-local planning state for attach,
submit, clarification, and proposal presentation, but exposes no approval,
publication, start, or Linear mutation tool.

Automated adapter tests use an injected in-memory GraphQL transport. They
execute no live Linear mutation and never load a real credential.
