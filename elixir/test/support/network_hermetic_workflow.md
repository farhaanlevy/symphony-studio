---
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
tracker:
  kind: memory
  endpoint: "http://127.0.0.1:0/graphql"
  api_key: "network-hermetic-test-token"
  project_slug: "network-hermetic-test-project"
  assignee: "network-hermetic-test-assignee"
  required_labels: []
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
polling:
  interval_ms: 30000
workspace:
  root: "/tmp/symphony-studio-test-startup-workspaces"
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: "codex app-server"
  approval_policy:
    reject:
      sandbox_approval: true
      rules: true
      mcp_elicitations: true
  thread_sandbox: "workspace-write"
observability:
  dashboard_enabled: false
server:
  port: null
  host: "127.0.0.1"
---
Test-only startup workflow. Never dispatch to an external tracker.
