# RFC 0001 — Agent Orchestration Platform (Comprehensive)

## Status

Draft

## Authors

Prasanna Loganathar (pvl)

## Date

2026-03-23

---

## 1. Summary

This RFC defines a **cross-platform agent orchestration platform** that:

- Orchestrates agents across **local, cloud, and hybrid environments**
- Uses **NATS as a unified central nervous system (CNS)**
- Integrates a **secure agent protocol (identity + authorization layer)**
- Supports **multi-agent workflows, memory, and domain intelligence**
- Provides a **CLI-first control plane with Tauri/mobile interfaces**

---

## 2. Motivation

Modern agent systems lack:

- Unified orchestration across environments
- Reproducibility
- Persistent memory
- Secure delegation and identity model

Specifically, existing layers:

- MCP → execution
- A2A → coordination
- ACP → transport

do not answer:

> “Who is acting, on whose behalf, and is it allowed?”

This RFC defines a system that solves orchestration _and_ secure delegation
together.

---

## 3. Goals

### 3.1 Primary Goals

- Provider-agnostic agents (Claude, Codex, OpenCode)
- Unified orchestration across local + cloud
- NATS as **single CNS everywhere**
- Secure agent-to-agent communication
- Multi-agent workflows (DAG + hierarchical)
- Persistent memory + domain intelligence
- CLI-first system with cross-platform UI

### 3.2 Non-Goals

- Full IAM system
- Distributed consensus systems
- Heavy infra (Kafka-class systems)

---

## 4. Architecture Overview

### 4.1 Planes

The system is composed of:

1. Interface Plane
2. Orchestration Plane
3. Execution Plane
4. Intelligence Plane
5. Data Plane
6. Communication Plane (NATS)
7. Security / Identity Plane (Agent Protocol)

---

### 4.2 High-Level Flow

```text
User → CLI/UI → Orchestrator
     → Execution / Intelligence / Data
     → NATS (CNS)
     → Agent Protocol (Auth Layer)
     → MCP / A2A targets
```

---

## 5. Central Nervous System (NATS)

### 5.1 Decision

Adopt **NATS as the unified communication backbone across all environments**.

### 5.2 Responsibilities

- Task dispatch
- Agent communication
- Workflow coordination
- Scheduling signals
- Lifecycle events
- Data queries

### 5.3 Properties

- Works local + cloud
- Embeddable
- High-performance
- Subject-based routing
- Supports request/reply, pub/sub, streaming

### 5.4 Namespacing

```
user.{user_id}.*
```

---

## 6. Orchestration Layer

### Responsibilities

- Workflow planning
- Runtime selection
- Task dispatch
- Config resolution
- Lifecycle management

### Components

- CLI Core
- Workflow Planner
- Runtime Manager
- Scheduler
- Lifecycle Supervisor

---

## 7. Execution Layer

### Local

- Containers
- Ollama
- WSL (Windows)

### Cloud

- Containers
- Incus VMs

### Hybrid

- Combined execution

### Substrate

- NixOS-based reproducible environments

---

## 8. Intelligence Layer

### Components

- Provider adapters
- Prompt templates
- Context engine
- Sub-agent orchestration

### Behavior

- Agents can spawn sub-agents
- Context dynamically assembled
- Provider-agnostic execution

---

## 9. Data Layer

### Components

- Task memory
- Execution logs
- Artifacts
- Domain-specific databases

### Storage

- SQLite (local)
- Postgres (cloud)

---

## 10. Workflow Model

- Sequential
- Parallel
- DAG
- Hierarchical agents

Supports:

- Supervisor patterns
- Review/security loops
- Domain-aware workflows

---

## 11. Agent Protocol Integration (Security Layer)

### 11.1 Decision

Introduce a **minimal IAM-like protocol layer**.

### 11.2 Model

- User (principal)
- Service account (actor)
- Scoped impersonation

Example:

```
sa:worker → user:pvl
```

### 11.3 Authorization

```
effective_permissions =
  user ∩ service ∩ token ∩ tool policy
```

### 11.4 Message Envelope

```json
{
  "envelope": {},
  "auth": {},
  "protocols": {
    "a2a": {},
    "mcp": {}
  },
  "sig": ""
}
```

### 11.5 Rules

- Signed messages
- Short-lived tokens
- No transitive impersonation
- Protocol payloads unchanged when forwarded

---

## 12. Integration with NATS

- NATS = transport + routing
- Agent Protocol = identity + authorization

### Usage

- Internal trusted communication → raw NATS
- Cross-boundary communication → protocol envelope

---

## 13. Agent Economies

The system supports persistent multi-agent systems:

Examples:

- Engineering teams
- Finance agents
- Research systems
- Autonomous loops

Properties:

- Persistent agents
- Shared memory
- Scheduled + continuous tasks
- Cross-agent collaboration

---

## 14. Security Model

Layered security:

1. Infrastructure (containers/VMs)
2. NATS (subjects + ACLs)
3. Agent Protocol (identity + auth)
4. Execution (tool policies)
5. Data (memory access)

---

## 15. Observability

- Logs
- Metrics
- Traces
- Workflow timelines
- Authorization events
- Replayable history

---

## 16. Reliability

- Retry / backoff
- Durable streams
- Checkpoints
- Restartable workflows

---

## 17. Alternatives Considered

| System    | Reason         |
| --------- | -------------- |
| Kafka     | Not embeddable |
| Redis     | Weaker routing |
| gRPC mesh | Too rigid      |

---

## 18. Open Questions

- NATS topology (single vs federated)
- Subject schema design
- Workflow DSL
- Policy engine design

---

## 19. Future Work

- Workflow DSL
- Visual builder
- Plugin system
- Distributed clusters
- Federation
- Rust reference implementation

---

## 20. Conclusion

This system combines:

- NATS → nervous system
- Agent Protocol → identity + security layer
- CLI → control authority
- Agents → execution units
- Data → memory

It provides a **complete, secure, and scalable foundation** for agent
orchestration.
