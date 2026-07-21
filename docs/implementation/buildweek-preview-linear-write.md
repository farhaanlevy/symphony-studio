# Build Week Preview: Linear write boundary

The preview keeps the accepted R0 query-only Linear credential unchanged. Plan
publication uses a second, team-scoped credential with only Linear **Read +
Write** access to the **Symphony Studio** team (`SYM`). It needs no Admin,
comment, label, or workspace-wide capability.

The protected file contract is deliberately separate:

- `SYMPHONY_LINEAR_WRITE_ENV_FILE` is set only for the Studio launch command;
- it points outside every Git repository and worktree to a regular,
  single-link, current-user-owned file with mode `0600`;
- the file contains exactly one non-empty
  `SYMPHONY_LINEAR_WRITE_API_KEY=` assignment;
- the same launch must also provide the protected R0 query credential through
  `SYMPHONY_LINEAR_ENV_FILE`, or through the already supported bounded
  `LINEAR_API_KEY` environment boundary;
- before any write callback, Studio validates both authorities and compares
  fixed-size in-memory frames in constant time; unavailable comparison or equal
  credential values fails closed;
- the pointer and key are never logged, returned, copied to application
  configuration, or exposed to model/shell children.

The recommended location is
`$HOME/.config/symphony-studio/linear-write.env`, with each parent directory at
mode `0700`. The launch process should set the pointer command-locally rather
than exporting it from a shell profile.

The production adapter is explicitly injected only at the trusted local Studio
host boundary as:

```elixir
broker = SymphonyElixir.Studio.LinearWriteBroker.Linear.target()
SymphonyElixir.Studio.IntentService.publish_approved_plan(intent_id, command_id,
  broker: broker
)
```

The default Intent Service broker remains fail-closed. The adapter is bound to
project `symphony-studio-build-week-3f2698765546`, team `Symphony Studio` / `SYM`,
and exactly these mutations:

1. `issueCreate` with an exact client-generated UUID, project/team binding, and
   the team's `Backlog` state;
2. `issueRelationCreate` with an exact client-generated UUID and type `blocks`;
3. `issueUpdate` for the one explicitly selected first-ready issue, using the
   team's exact `Todo` state ID.

Every issue and relation is reconciled before execution. Lost mutation
responses become `uncertain`; a retry queries the same deterministic UUID
instead of creating a duplicate. Relation and transition writes additionally
prove that their endpoints are Studio-created issues for the exact approved
intent and proposal digest. `SYM-1` and `SYM-2` are denied before mutation.

The local STDIO MCP server intentionally exposes no approval, publication, or
start tool and has no production write broker. A Codex thread can attach,
submit, clarify, present, and query status, while the owner must perform the
proposal-bound approval, publication, and separate Start action in the trusted
local Studio UI.

Automated tests use an injected in-memory GraphQL transport. They execute no
live Linear mutation and never load a real credential.
