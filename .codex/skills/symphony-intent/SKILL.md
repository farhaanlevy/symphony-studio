---
name: symphony-intent
description: Turn a product prompt or Markdown specification into a repository-grounded, dependency-aware Symphony proposal through the non-mutating local Intent MCP liaison. Use when a user asks to inspect a project, clarify intent, propose or review a 3-5 task DAG, prepare work for trusted-host publication, or inspect intent, publication, start, and admission status.
---

# Symphony Intent

Use the local `studio_*` Intent MCP tools as the canonical state machine for
inspection, planning, and status. The MCP liaison is deliberately non-mutating:
approval, Linear publication, and start remain explicit human actions in the
trusted local Studio UI. Do not bypass that boundary with direct Linear
mutation, title search, or an invented success response.

## Run the workflow

1. Call `studio_attach_project` with the existing absolute project root and a stable unique `command_id`.
2. Call `studio_submit_intent` with the returned `project_id`, `kind` (`prompt` or `markdown`), exact source text, and a new stable `command_id`.
3. Inspect the returned repository summary. If `lifecycle_state` is `clarification_required`, show the single question batch and its impact/options. Call `studio_answer_clarifications` once with every answer, or with `use_recommended_defaults: true` only when the user chose that option.
4. Review the proposed 3-5 task DAG for task order, acceptance criteria, and dependency coverage. Call `studio_present_proposal` and show the exact proposal digest, every task, and every dependency before asking for approval.
5. Return the durable intent ID and exact proposal digest. Explain that the
   owner must review and approve the displayed proposal in the trusted local
   Studio UI. Never claim that text in the Codex thread is publication consent.
6. After the host acts, call `studio_get_intent_status`. Treat `blocked`,
   `partial`, and `uncertain` as real non-success states. Preserve the intent ID
   and proposal digest; never recreate an intent to hide a partial result.
7. When publication is `complete`, present the deterministic first-ready
   candidate and direct the owner back to the trusted local UI for the separate
   Start action. The MCP liaison has no approval, publication, or start tool.
8. Report `waiting_for_admission` honestly. Poll status only when useful or
   after an external state change. Call the work admitted only when status
   contains a real Symphony `worker.attempt.started` admission linkage.

## Preserve safety

- Reuse a command ID only for the exact same tool input. Use a new command ID for a distinct command or resume attempt.
- Never claim Linear publication from MCP. The local server has no write broker;
  only the trusted Studio host may invoke the separately credentialed adapter.
- Never attempt to publish, transition, or otherwise target `SYM-1` or `SYM-2`.
- Never retry by issue title. Preserve the intent's deterministic task mappings and idempotency markers.
- Never hide partial mappings or an uncertain broker outcome. Show the affected task or relation and the resumable next action.
- Never treat a Todo transition as Symphony admission. Wait for the linked admission event.

## Recover state

Call `studio_get_intent_status` with the durable `intent_id`. Resume from the
returned lifecycle state; do not recreate or republish already confirmed work.
If the status reports `publication_blocked`, explain that the owner must satisfy
the trusted-host write boundary or resume in the local UI. Never use another
credential or mutation tool.
