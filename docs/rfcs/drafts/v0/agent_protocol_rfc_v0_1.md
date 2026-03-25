# RFC-0001: Agent Protocol (Simple IAM Model)

## Status

Draft

## Version

v0.1

## Authors

Prasanna Loganathar (pvl) and collaborators

## Date

2026-03-23

---

## 1. Abstract

This document specifies a minimal, composable protocol for secure agent-to-agent
communication.\
It introduces a **simple IAM-like model** based on:

- user principals
- service accounts
- scoped impersonation tokens

The protocol is designed to:

- reuse existing standards such as MCP (Model Context Protocol)
- align with A2A (agent coordination patterns)
- operate over ACP-style transport systems

while adding a missing layer for:

- identity
- authorization
- trust boundaries
- auditability

---

## 2. Motivation

Modern agent systems rely on three emerging layers:

- MCP → execution (tools/resources)
- A2A → coordination (tasks/workflows)
- ACP → transport (messaging/routing)

However, none of these provide a coherent answer to:

> “Who is performing an action, on whose behalf, and is it allowed?”

This leads to:

- unsafe delegation
- unclear authority boundaries
- poor auditability
- inconsistent authorization models

This RFC introduces a minimal solution.

---

## 3. Design Goals

- Simplicity over completeness
- Strong default security posture
- Protocol composability
- Forward compatibility
- Minimal cognitive overhead
- Easy to audit and reason about

---

## 4. Non-Goals

- Full IAM system replacement
- Complex delegation graphs
- Multi-hop attenuation semantics
- Cross-org federation (v1)
- Formal policy language specification

---

## 5. Terminology

## 5.1 User (Principal)

Human or originating authority.

Example:

- user:pvl

## 5.2 Service Account (Actor)

Runtime identity executing operations.

Example:

- sa:worker

## 5.3 Subject

The user on whose behalf an action is executed.

## 5.4 Issuer

Service account sending the message.

## 5.5 Target

Intended recipient.

---

## 6. Architecture Overview

```text
Transport Layer (ACP-style)
        ↓
Message Envelope
        ↓
Auth Layer (NEW)
        ↓
Protocol Payloads
   ├── A2A (coordination)
   └── MCP (execution)
```

---

## 7. Message Format

```json
{
  "envelope": {
    "id": "msg-123",
    "from": "sa:planner",
    "to": "sa:worker",
    "trace_id": "trace-1"
  },
  "auth": {
    "subject": "user:pvl",
    "token": "..."
  },
  "protocols": {
    "a2a": { "type": "task.request" },
    "mcp": { "method": "tools/call" }
  },
  "sig": "..."
}
```

---

## 8. Impersonation Model

A service account may act on behalf of a user:

```text
sa:worker → user:pvl
```

This is the only delegation mechanism.

---

## 9. Authorization Model

```text
effective_permissions =
  user_permissions
  ∩ service_permissions
  ∩ token_scopes
  ∩ tool_policy
```

All must pass.

---

## 10. Token Format

```json
{
  "iss": "auth-service",
  "sub": "user:pvl",
  "azp": "sa:planner",
  "aud": "sa:worker",
  "actions": ["tool.call"],
  "tools": ["read_file"],
  "resources": ["/docs/*"],
  "exp": 1770000000
}
```

---

## 11. Authorization Algorithm

1. Verify signature
2. Validate token
3. Check service account policy
4. Check user permissions
5. Check tool policy
6. Intersect all permissions

---

## 12. Security Considerations

- No implicit transitive impersonation
- All messages signed
- Tokens short-lived
- LLM excluded from auth decisions
- Idempotency for side effects
- High-risk tools require stricter controls

---

## 13. Protocol Interoperability

## MCP

Used unchanged for tool execution.

## A2A

Used unchanged for task semantics.

## ACP

Used for transport and routing.

---

## 14. Forwarding Semantics

Subprotocol payloads MUST remain unchanged.

Example:

- Extract `protocols.mcp` and forward directly
- Extract `protocols.a2a` and forward directly

---

## 15. Error Model (High-Level)

Errors should be layered:

- transport
- authentication
- authorization
- protocol (A2A/MCP)
- tool/runtime

---

## 16. Extensibility

Future versions may include:

- delegation chains
- federation
- richer policy engines
- approval workflows

---

## 17. Example Flow

```text
Planner → Worker
  task.request + mcp tool.call

Worker:
  validate
  execute
  return result
```

---

## 18. Conclusion

This protocol provides:

- a missing identity layer
- simple IAM semantics
- composability with MCP/A2A/ACP
- a strong but minimal foundation for agent systems

---

## 19. References

- MCP (Anthropic)
- A2A patterns (LangGraph, CrewAI)
- Distributed systems messaging models

---

## 20. Appendix

Future work:

- binary encoding
- NATS mapping
- Rust reference implementation
