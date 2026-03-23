# 🧠 Agent Orchestration Platform — System Design

## 0. Overview

This system is a **cross-platform agent orchestration platform** designed to:

- Run and coordinate **AI agents locally and in the cloud**
- Provide a unified **CLI-first experience**, with a **Tauri-based GUI companion**
- Support **multi-agent workflows**, including hierarchical and parallel execution
- Enable **data-aware agents** with persistent memory and domain-specific intelligence
- Allow users to deploy **entire agent ecosystems ("economies")**

This document defines the architecture that can run agents locally, in the cloud, and across hybrid environments. The platform is **CLI-first**, uses a **Tauri-based app as a visual control plane**, treats **NATS as the central nervous system**, and integrates a **secure agent protocol layer** wherever agent-to-agent or agent-to-tool communication requires identity, authorization, delegation, and auditability.

---

## 2. Design Intent

The platform is intended to support:

- local-first execution for desktop users
- cloud-managed execution for mobile and hosted usage
- hybrid execution where local and cloud agents cooperate
- provider-agnostic agent runtimes
- reproducible execution environments
- long-running autonomous systems
- recurring scheduled systems
- composable multi-agent workflows
- domain-specific intelligence and data planes
- secure, auditable delegation between users, orchestrators, agents, and tools

The core orchestration goals and layering described here come from the system design document. The protocol and authorization model integrated below come from the agent protocol design, which adds a thin identity and authorization layer while reusing MCP, A2A, and ACP-style transport patterns. This is the missing piece that answers: **who is doing what, on whose behalf, and whether it is allowed**. fileciteturn1file0L1-L18 fileciteturn1file1L1-L18

---

## 3. Core Philosophy

- **CLI is the source of truth**
- **GUI is a monitor and control plane, not the primary execution authority**
- **NixOS is the reproducible substrate across runtimes**
- **NATS is the central nervous system across local, cloud, and hybrid execution**
- **Agents are provider-agnostic, composable, stateful, and collaborative**
- **Security is layered in explicitly, not implied**
- **Protocol payloads should remain clean and forwardable**
- **Identity, authorization, and impersonation must be auditable**
- **Data and memory are first-class system components, not afterthoughts**

The orchestration design already defined the platform as model-agnostic and layered across interface, orchestration, execution, intelligence, data, and communication. The protocol design adds that the system should reuse existing agent/tool standards where possible, and add only a minimal auth layer rather than a heavyweight IAM system. fileciteturn1file0L20-L56 fileciteturn1file1L20-L48

---

## 4. High-Level System Summary

At a high level, the platform has seven major planes:

1. **Interface Plane**
   - Tauri desktop app
   - mobile app surface
   - CLI
   - future web control plane

2. **Orchestration Plane**
   - workflow planning
   - runtime selection
   - lifecycle management
   - scheduling
   - config resolution

3. **Execution Plane**
   - local containers
   - local model runtimes
   - cloud containers
   - cloud VMs
   - distributed execution across machines

4. **Intelligence Plane**
   - provider adapters
   - instruction / prompt systems
   - sub-agent spawning
   - context assembly
   - specialized agent roles

5. **Data Plane**
   - task memory
   - execution logs
   - artifacts
   - vertical databases
   - persistent state

6. **Communication Plane**
   - NATS subjects
   - request/reply
   - streaming
   - event propagation
   - lifecycle signaling

7. **Security / Identity Plane**
   - user principals
   - service accounts
   - scoped impersonation
   - signed messages
   - authorization intersection checks

The original system design defines the first six of these explicitly. The protocol design fills in the seventh plane and clarifies that secure communication should be a wrapper on top of transport and coordination rather than a replacement for MCP or A2A. fileciteturn1file0L24-L72 fileciteturn1file1L50-L96

---

## 5. Architecture Diagram

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Interface Plane                                  │
│               Tauri Desktop / Mobile / CLI / Future Web                    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Orchestration Plane                                │
│        CLI Core / Planner / Config / Scheduler / Lifecycle Supervisor      │
└─────────────────────────────────────────────────────────────────────────────┘
             │                         │                          │
             ▼                         ▼                          ▼
┌────────────────────┐   ┌──────────────────────────┐   ┌─────────────────────┐
│   Execution Plane  │   │   Intelligence Plane     │   │     Data Plane      │
│ containers / VMs   │   │ providers / agent roles  │   │ memory / artifacts  │
│ local + cloud      │   │ context / sub-agents     │   │ logs / vertical DBs │
└────────────────────┘   └──────────────────────────┘   └─────────────────────┘
             │                         │                          │
             └─────────────────────────┼──────────────────────────┘
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Communication Plane — NATS CNS                          │
│    subjects / request-reply / streams / events / scheduler / lifecycle     │
└─────────────────────────────────────────────────────────────────────────────┘
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                 Security + Identity Plane — Agent Protocol                  │
│ user principals / service accounts / scoped impersonation / signed msgs    │
│ auth envelope / forwarding rules / authorization intersection              │
└─────────────────────────────────────────────────────────────────────────────┘
                                       ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                  External Protocols and Execution Targets                   │
│                    MCP tools / A2A tasks / ACP-style transport              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 6. Interface Plane

### 6.1 Tauri Desktop App

The Tauri desktop app is the main visual interface for desktop users. It should:

- start and observe local workloads through the CLI
- present task progress, logs, and topology
- expose config editing, workflow launch, and runtime inspection
- visualize multi-agent graphs, queues, and state
- surface artifacts, memory, and domain data summaries

### 6.2 Mobile App Surface

The mobile app is primarily a cloud-mode interface. It should:

- monitor remote tasks
- trigger workflows
- inspect outputs and artifacts
- manage long-running hosted systems
- review alerts, schedules, and state changes

It is not required to host the full local runtime stack.

### 6.3 CLI

The CLI remains the platform’s primary authority. It should:

- be scriptable and composable
- bootstrap local infrastructure
- talk to cloud infrastructure
- resolve config and runtime choices
- dispatch workflows
- be the authoritative bridge between user intent and the orchestration system

The system design explicitly treats the CLI as the source of truth and the Tauri app as the visual orchestrator and monitor. fileciteturn1file0L11-L18 fileciteturn1file0L106-L140

---

## 7. Orchestration Plane

### 7.1 CLI Core

The CLI core parses commands, resolves configuration, selects runtime targets, and dispatches workflow executions.

### 7.2 Workflow Planner

The workflow planner converts high-level intent into executable plans. It should support:

- sequential workflows
- parallel branches
- hybrid DAG workflows
- hierarchical delegation
- role-based agent assignment
- supervisor / worker patterns
- dynamic insertion of review, verification, and security stages

### 7.3 Runtime Manager

The runtime manager chooses where work runs:

- local container
- local model runtime
- cloud container
- cloud VM
- distributed multi-node placement

It is responsible for startup, teardown, health checking, placement, and recovery.

### 7.4 Config Manager

The config manager should resolve:

- user-level config
- project-level config
- task config
- workflow config
- runtime config
- provider/model config
- policy overlays

### 7.5 Scheduler

The scheduler should support:

- on-demand tasks
- recurring tasks
- long-running autonomous tasks
- time-boxed tasks
- retries and backoff
- priority
- trigger semantics
- durable scheduled state

### 7.6 Lifecycle Supervisor

The lifecycle supervisor tracks:

- agents
- containers
- VMs
- workflows
- long-running systems

It should restart, repair, or tear down resources based on policy.

The original orchestration design already defined planner, runtime manager, config manager, task scheduler, and lifecycle supervisor as distinct orchestration responsibilities. fileciteturn1file0L142-L177

---

## 8. Execution Plane

### 8.1 Local Execution

Local execution supports:

- native Linux containers where possible
- Windows via WSL-based Linux runtime
- macOS through supported container/runtime paths
- local model runtimes such as Ollama
- one or many agents on a machine

### 8.2 Cloud Execution

Cloud execution supports:

- managed containers
- managed Incus VMs
- burst capacity
- long-running hosted systems
- shared hosted memory/data services

### 8.3 Distributed Execution

Distributed execution allows:

- multiple containers, VMs, or machines
- hybrid local + cloud cooperation
- role separation across runtimes
- placement decisions based on security, performance, cost, or locality

### 8.4 Reproducible Substrate

NixOS is the common operating substrate. The system design specifically calls for NixOS-based images and a convergent operating model across local and cloud containers and VMs. fileciteturn1file0L179-L199 fileciteturn1file0L360-L367

---

## 9. Intelligence Plane

### 9.1 Provider Adapters

The system should normalize:

- Claude
- Codex
- OpenCode
- Ollama-backed local models
- future providers

This preserves provider-agnostic orchestration and lets execution policies stay independent of any single vendor.

### 9.2 Prompt and Instruction Systems

Instruction layers should include:

- system-level templates
- task-level templates
- agent-role templates
- domain templates
- policy/safety overlays

### 9.3 Hierarchical Agents

Agents can spawn sub-agents. Example patterns include:

- planner → coder → reviewer → security agent
- research lead → retrieval agents → summarizer
- infra lead → diagnostics agent → patching agent → verification agent

### 9.4 Context Engine

The context engine assembles:

- user intent
- prior execution memory
- relevant artifacts
- vertical data
- domain context
- policy context
- runtime context

This allows each task to get dynamically assembled, task-appropriate context instead of one static prompt.

The system design explicitly calls out provider adapters, prompt/instruction templating, sub-agent orchestration, and context injection/memory retrieval as first-class concerns. fileciteturn1file0L201-L218

---

## 10. Data Plane

### 10.1 Execution Memory

Execution memory stores:

- structured logs
- inputs and outputs
- status changes
- metrics
- decisions
- revisions
- intermediate artifacts where appropriate

### 10.2 Task Memory

Task memory stores historical task knowledge that can be reused across repeated task categories or workflow templates.

### 10.3 Artifacts

Artifacts include:

- files
- reports
- code patches
- plans
- research outputs
- generated documents
- execution bundles

Artifacts should be referenceable by future agents and future tasks.

### 10.4 Vertical Data Stores

Each domain can have its own schema or its own database. Examples include:

- VC market intelligence
- trading / market data
- DevOps / telemetry
- research corpora

These are not just passive databases; each can expose active intelligence via specialized data agents.

### 10.5 Storage Strategy

- SQLite for local-first portability
- Postgres for cloud/shared workloads
- specialized stores later for vector, timeseries, or search-heavy use cases

The system design already establishes execution memory, task memory, artifacts, vertical stores, and a SQLite/Postgres split. fileciteturn1file0L220-L244 fileciteturn1file0L398-L434

---

## 11. Communication Plane — NATS as CNS

NATS is the **single central nervous system** across:

- local
- cloud
- hybrid
- cross-agent
- cross-container
- cross-VM
- cross-machine communication

It is the unified platform bus for:

- task dispatch
- event propagation
- data coordination
- workflow execution
- scheduling
- lifecycle signals
- service-to-service communication

### 11.1 Communication Patterns

- **Pub/Sub** for event broadcasting
- **Request/Reply** for direct commands and synchronous interactions
- **JetStream / streaming** for persistence, replay, durable workflows, scheduler state, and long-running propagation

### 11.2 Namespacing

Each user gets isolated subject space, for example:

```text
user.{user_id}.*
```

Examples:

- `user.pvl.tasks.run`
- `user.pvl.agent.spawn`
- `user.pvl.workflow.dispatch`
- `user.pvl.data.query`
- `user.pvl.scheduler.tick`

### 11.3 Communication Properties

The communication plane should provide:

- strong isolation
- auditability
- explicit routing
- security policy layering
- subject-based observability
- reusable control-plane semantics

The system design strongly defines NATS as the CNS everywhere, with request/reply, pub/sub, JetStream, and user-scoped namespaces. fileciteturn1file0L251-L324

---

## 12. Security + Identity Plane — Agent Protocol Integration

This is where the two documents most importantly join.

The agent protocol is **not** a replacement for the orchestration system and not a separate product. It is the **security, identity, and forwarding layer used wherever the orchestration system needs protocol-safe delegation and execution**.

The protocol design says the system should:

- reuse **MCP** for execution
- reuse **A2A** for coordination
- reuse **ACP-style transport** for messaging/routing
- add a thin layer for:
  - identity
  - impersonation
  - authorization

This is the missing protocol support that the orchestration document needed. fileciteturn1file1L1-L37

### 12.1 Core Security Model

The protocol introduces:

- **User (principal)** — the source of authority
- **Service account (actor)** — the runtime identity performing work
- **Scoped impersonation** — a service account acts on behalf of a user
- **Authorization intersection** — permissions are granted only if all required layers allow it

Example conceptually:

- user principal: `user:pvl`
- service accounts: `sa:planner`, `sa:worker`
- impersonation relation: `sa:worker -> user:pvl`

This model is intentionally smaller and easier to audit than full IAM. fileciteturn1file1L39-L74

### 12.2 Effective Permissions Model

Authorization is defined as:

```text
effective_permissions =
  user_permissions ∩ service_permissions ∩ token_scopes ∩ tool_policy
```

This should be treated as a core platform invariant.

That means a workflow step is not allowed merely because:

- the user wants it, or
- the service account can do it, or
- the token mentions it

All relevant policy layers must agree. fileciteturn1file1L50-L74

### 12.3 Message Envelope

Whenever protocol-secure delegation is needed, the platform should wrap messages in an envelope with:

- `envelope`
- `auth`
- `protocols`
- `sig`

Conceptually:

```json
{
  "envelope": { "id": "...", "from": "...", "to": "...", "trace_id": "..." },
  "auth": { "subject": "user:pvl", "token": "..." },
  "protocols": {
    "a2a": { "type": "task.request" },
    "mcp": { "method": "tools/call" }
  },
  "sig": "..."
}
```

This should be the basis for secure routing through the orchestration system wherever agent coordination or tool execution crosses trust boundaries. fileciteturn1file1L76-L118

### 12.4 Forwarding Rule

A critical design constraint from the protocol doc is:

- subprotocol payloads should remain unchanged when forwarded
- `protocols.mcp` can be forwarded directly to an MCP server
- `protocols.a2a` can be forwarded directly to another agent
- wrappers should not mutate protocol payloads

This is extremely useful architecturally because it means the orchestration system can add security, routing, and observability without corrupting protocol purity. fileciteturn1file1L120-L152

### 12.5 Token Model

Tokens should carry at least:

- subject user
- authorized party / service account
- audience
- tool scopes
- resource scopes
- expiry

The protocol design gives a representative example with `sub`, `azp`, `aud`, `tools`, `resources`, and `exp`. fileciteturn1file1L154-L164

### 12.6 Authorization Flow

Authorization should follow a layered sequence:

1. verify signature
2. validate token
3. check service permissions
4. check user permissions
5. check tool policy
6. intersect all permissions

This is the right place to integrate policy engines, approval flows, or higher-risk tool gating later. fileciteturn1file1L166-L176

### 12.7 Security Rules

The protocol document also provides non-negotiable rules that should be adopted platform-wide:

- signed messages
- short-lived tokens
- no transitive impersonation
- both user and service must allow
- the LLM is not trusted for auth decisions

These are extremely important for keeping the platform safe once workflows become autonomous and long-running. fileciteturn1file1L178-L188

---

## 13. How the Protocol Fits into the Orchestration System

### 13.1 Inside One Trust Boundary

Within a tightly controlled internal component boundary, not every internal event needs the full auth envelope. Some internal NATS events may remain lightweight.

### 13.2 Across Trust Boundaries

Whenever communication crosses one of these boundaries, the protocol envelope should be used:

- user → orchestrator
- orchestrator → agent runtime
- planner agent → worker agent
- agent → MCP tool service
- agent → vertical data agent
- local runtime → cloud runtime
- project boundary → shared system boundary
- tenant boundary → tenant boundary
- privilege boundary → higher-risk tool boundary

### 13.3 Layering with NATS

The clean mental model is:

- **NATS** provides transport, routing, delivery, request/reply, and streams
- **Agent Protocol** provides identity, delegation, authorization, and forwarding semantics
- **A2A** provides coordination semantics
- **MCP** provides execution semantics

This is directly aligned with the protocol design’s own stated architecture of ACP-style transport under an envelope/auth layer above A2A and MCP. fileciteturn1file1L190-L201

---

## 14. Workflow Architecture

### 14.1 Workflow Types

The platform supports:

- sequential workflows
- parallel workflows
- hybrid DAG workflows
- hierarchical workflows
- supervisory review loops
- recurring workflows
- long-running autonomous workflows

### 14.2 Hierarchical Example

```text
Task: Build Feature X

Planner Agent
  ├─ Coding Agent
  ├─ Review Agent
  └─ Security Agent
```

### 14.3 Workflow Execution Model

A typical execution path:

1. user triggers a workflow through CLI or UI
2. orchestration layer resolves config and policy
3. workflow planner breaks intent into stages
4. runtime manager places agents
5. NATS subjects route work and events
6. agent protocol envelope is used where trust boundaries require identity and auth
7. results, artifacts, and logs flow into the data plane
8. lifecycle supervisor monitors progress and recovery

### 14.4 Domain-Infused Workflows

Workflows may call vertical data agents for:

- market context
- investor intelligence
- infrastructure telemetry
- research context

This lets workflows become domain-aware without hard-coding each domain into the core orchestrator.

The system design explicitly calls out sequential, parallel, and DAG workflows, plus hierarchical spawning patterns. fileciteturn1file0L371-L393

---

## 15. Long-Running Systems and Agent Economies

A major design goal is not just one-off tasks, but **economies of agents**.

Users should be able to define cooperating systems such as:

- engineering org
- finance org
- research org
- startup operating system
- city-style simulated economy
- autonomous market watchers
- periodic research services

These systems may include:

- persistent agents
- shared memory
- scheduled tasks
- long-running processes
- vertical data services
- supervisory agents
- approval and policy layers

The system design already frames this as “agent economies” with teams and organizational analogies. fileciteturn1file0L457-L474

---

## 16. Observability

The platform should expose:

- logs
- metrics
- traces
- workflow timelines
- agent run timelines
- event history
- replayable workflow history
- subject-level routing observability
- authorization failures
- token / signature validation failures
- artifact lineage

The system design already lists observability as a core cross-cutting concern. The protocol integration adds auth, signature, and delegation observability as equally important categories. fileciteturn1file0L472-L488

---

## 17. Reliability and Failure Handling

The platform should support:

- retry / backoff
- durable streams
- state checkpoints
- restartable long-running workflows
- clear failure domains
- degraded-mode operation
- idempotent side effects where possible
- signature / token failure isolation
- runtime restart without losing control-plane integrity

The system design explicitly calls out retry/backoff, durable streams, checkpoints, and restartable long-running workflows, while the protocol design adds the need for signed messages, short-lived tokens, and layered error handling around authentication and authorization. fileciteturn1file0L490-L507 fileciteturn1file1L178-L188

---

## 18. Security Model

Security is not one feature; it is layered across the whole platform:

### 18.1 Infrastructure Isolation
- container / VM boundaries
- project boundaries
- tenant boundaries
- local vs cloud policy boundaries

### 18.2 NATS-Level Security
- subject namespaces
- subject ACLs
- service communication boundaries

### 18.3 Protocol-Level Security
- signed messages
- scoped tokens
- no transitive impersonation
- exact forwarding of protocol payloads

### 18.4 Execution-Level Security
- tool policy checks
- resource scoping
- runtime policy overlays
- side-effect approvals for high-risk actions

### 18.5 Data-Level Security
- per-user and per-project memory boundaries
- artifact permissions
- domain-data access policies

The system design emphasizes user-scoped namespaces, explicit communication paths, workload isolation, and role/subject-based policies; the protocol design supplies the exact delegation and authorization logic to make that enforceable. fileciteturn1file0L246-L251 fileciteturn1file1L166-L188

---

## 19. Portability and Modes

### 19.1 Managed Mode
- cloud-hosted execution path
- mobile-first interaction
- managed infrastructure

### 19.2 Unmanaged Mode
- local-first execution
- user control
- self-hosted infrastructure

### 19.3 Hybrid Mode
- local execution with cloud augmentation
- shared CNS
- unified orchestration

The system design defines managed, unmanaged, and hybrid as explicit platform modes. fileciteturn1file0L476-L495

---

## 20. Practical Mental Model

A useful platform metaphor is:

- **CLI = brainstem / command authority**
- **Tauri / mobile / web = user-facing nervous system**
- **NATS = central nervous system**
- **Agent Protocol = identity + immune / permission system**
- **runtimes = muscles and organs**
- **data plane = memory**
- **workflows = behavior**
- **vertical modules = specialized knowledge centers**

This extends the original design’s mental model by giving the protocol a precise role rather than leaving security abstract. fileciteturn1file0L503-L516

---

## 21. Recommended Boundary Rules

To make the design implementable, the system should adopt these practical rules:

1. **Use raw NATS events for low-risk internal control-plane chatter within the same trusted subsystem.**
2. **Use the agent protocol envelope whenever an action crosses a trust or privilege boundary.**
3. **Preserve A2A and MCP payloads exactly when forwarding.**
4. **Require explicit intersection authorization for all tool use and delegated actions.**
5. **Treat the user as the authority source and service accounts as runtime actors.**
6. **Do not allow transitive impersonation in v1.**
7. **Keep the protocol thin; do not reinvent MCP or A2A.**

These rules are direct consequences of the protocol design and are what let the orchestration system stay both powerful and simple. fileciteturn1file1L39-L74 fileciteturn1file1L120-L152

---

## 22. Future Extensions

Potential next layers include:

- workflow DSL
- visual builder
- plugin ecosystem
- distributed clusters
- richer policy engines
- approval workflows
- federation
- delegation chains
- Rust reference protocol implementation
- formal NATS subject schema
- binary encoding for selected protocol paths

The base system design and the protocol design both point naturally toward these areas. fileciteturn1file0L518-L526 fileciteturn1file1L203-L211

---

## 23. Conclusion

The full orchestration system should be understood as:

- a **cross-platform orchestration platform**
- with a **CLI-first control model**
- a **Tauri/mobile visual plane**
- **NixOS-backed reproducible runtimes**
- **NATS as the single communication backbone**
- **provider-agnostic agents**
- **persistent memory and vertical intelligence**
- and a **thin but rigorous protocol layer** for identity, impersonation, authorization, and forwarding semantics

That combination gives you a platform that is not only capable of orchestrating agents, but capable of doing so **safely, audibly, portably, and at system scale**.

