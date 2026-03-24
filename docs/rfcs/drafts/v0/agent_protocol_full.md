# Agent Protocol

A minimal, composable protocol for secure agent-to-agent communication that:

- Reuses MCP, A2A, and ACP-style transport
- Adds a thin identity + authorization layer
- Uses user as the source of authority
- Uses service accounts for execution
- Supports scoped impersonation
- Preserves exact protocol payloads for forwarding

---

# 0. Background & Motivation

## Existing Protocols

### MCP — Model Context Protocol

- LLM ↔ tools/resources interface
- JSON-RPC (tools/call, resources/read)
- Focus: execution

Missing:

- identity
- auth
- delegation
- trust boundaries

---

### A2A — Agent-to-Agent

- Task coordination semantics
- Planner/worker patterns

Missing:

- security model
- auth semantics

---

### ACP — Communication Layer

- Transport, routing, delivery

Missing:

- user-level authorization
- delegation model

---

## Core Gap

“Who is doing what, on whose behalf, and are they allowed?”

---

## Design Direction

We reuse:

- MCP for execution
- A2A for coordination
- ACP for transport

Add:

- identity
- impersonation
- authorization

---

## Why Not Full IAM

Full IAM is:

- complex
- hard to audit
- overkill

We use: User + Service Account + Scoped Impersonation

---

# 1. Core Concepts

User (Principal):

> user:pvl

Service Account (Actor):

> sa:planner sa:worker

Impersonation:

> sa:worker → user:pvl

Authorization:

```
effective_permissions =
  user_permissions ∩ service_permissions ∩ token_scopes ∩ tool_policy
```

---

# 2. Structure

```
{
  "envelope": {...},
  "auth": {...},
  "protocols": {
    "a2a": {...},
    "mcp": {...}
  },
  "sig": "..."
}
```

---

# 3. Message Example

```
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
    "a2a": {
      "type": "task.request"
    },
    "mcp": {
      "method": "tools/call"
    }
  },
  "sig": "..."
}
```

---

# 4. Forwardability

Allowed:

- protocols.mcp → MCP server
- protocols.a2a → other agent

Not allowed:

- modifying protocol payloads

---

# 5. Token

```
{
  "sub": "user:pvl",
  "azp": "sa:planner",
  "aud": "sa:worker",
  "tools": ["read_file"],
  "resources": ["/docs/*"],
  "exp": 1770000000
}
```

---

# 6. Authorization Flow

1. Verify signature
2. Validate token
3. Check service permissions
4. Check user permissions
5. Check tool policy
6. Intersect

---

# 7. Security Rules

- signed messages
- short-lived tokens
- no transitive impersonation
- user AND service must allow
- LLM not trusted

---

# 8. Architecture

```
ACP (transport)
 ↓
Envelope
 ↓
Auth
 ↓
A2A
 ↓
MCP
```

---

# Summary

A simple, secure wrapper around MCP and A2A adding identity and authorization
while preserving protocol purity.
