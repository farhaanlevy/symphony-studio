---
name: symphony-intent
description: Turn a product prompt or Markdown specification into a repository-grounded, dependency-aware Symphony backlog through the local Intent MCP lifecycle. Use when a user asks to inspect a project, clarify intent, propose or review a 3-8 task DAG, publish an explicitly approved plan to Linear, start the first ready task, or inspect intent publication and admission status.
---

# Symphony Intent

Use the local `studio_*` Intent MCP tools as the canonical state machine. Do not bypass them with direct Linear mutation, title search, or an invented success response.

## Run the workflow

1. Call `studio_attach_project` with the existing absolute project root and a stable unique `command_id`.
2. Call `studio_submit_intent` with the returned `project_id`, `kind` (`prompt` or `markdown`), exact source text, and a new stable `command_id`.
3. Inspect the returned repository summary. If `lifecycle_state` is `clarification_required`, show the single question batch and its impact/options. Call `studio_answer_clarifications` once with every answer, or with `use_recommended_defaults: true` only when the user chose that option.
4. Review the proposed 3-8 task DAG for task order, acceptance criteria, and dependency coverage. Call `studio_present_proposal` and show the exact proposal digest, every task, and every dependency before asking for approval.
5. Do not infer approval. Call `studio_approve_publication` only after the user supplies the exact confirmation `publish_linear_backlog`, and pass the exact digest returned by presentation.
6. Call `studio_publish_approved_plan`. Treat `blocked`, `partial`, and `uncertain` as real non-success states. Preserve the intent ID and proposal digest. For a later resume attempt, use a new command ID; the service reconciles the same deterministic issue and relation markers before any execution.
7. After publication is `complete`, present the deterministic first-ready candidate. Do not reuse publication consent. Call `studio_start_first_ready` only after the user separately supplies the exact confirmation `start_first_ready`.
8. Report `waiting_for_admission` honestly. Poll `studio_get_intent_status` only when useful or after an external state change. Call the work admitted only when status contains a real Symphony `worker.attempt.started` admission linkage.

## Preserve safety

- Reuse a command ID only for the exact same tool input. Use a new command ID for a distinct command or resume attempt.
- Never claim Linear publication from the fake broker. The local server defaults to a fail-closed unavailable write broker until a separate least-privilege credential and adapter exist.
- Never attempt to publish, transition, or otherwise target `SYM-1` or `SYM-2`.
- Never retry by issue title. Preserve the intent's deterministic task mappings and idempotency markers.
- Never hide partial mappings or an uncertain broker outcome. Show the affected task or relation and the resumable next action.
- Never treat a Todo transition as Symphony admission. Wait for the linked admission event.

## Recover state

Call `studio_get_intent_status` with the durable `intent_id`. Resume from the returned lifecycle state; do not recreate or republish already confirmed work. If the status reports `publication_blocked` because the least-privilege broker is unavailable, stop and explain that configuration is required rather than using another credential or mutation tool.
