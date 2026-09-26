# Phase Projection Control Plane

> Scope: logical service moves use `nix-native-service-moves.md`. This document
> remains authoritative for runtime-only host, instance, and resource
> projections and the shared runtime/host-agent projection ABI. Runtime JSON is
> not a service-move repository format.

## Decision

Phase projection is the reusable Abird control-plane mechanism for fleet changes
that must have both an immediate runtime path and an exactly equivalent
declarative repository path. Stateful moves are its first production consumer,
not its architectural boundary.

It is also the default propagation protocol for durable managed-host changes
initiated through `abird-app` and admitted by the Abird controller. The app is a
client and approval surface; it does not become a second host controller. The
application controller admits typed intent; the host manager turns it into a
projection, and repository and runtime reconcilers carry that one projection to
the host agents.

New multi-host workflows should prefer phase projection when they need explicit
human phase decisions, interruption-safe continuation, ordered runtime effects,
or the option to publish desired state without applying it immediately.

## Ownership Layers

The architecture has five strict layers:

1. A workflow adapter owns domain intent, its allowed phase transition graph,
   and the typed effects required by each phase. A service move adapter may know
   `seeded`, `prepared`, `cutover`, and `rolled_back`; the projection kernel
   does not.
2. The generic projection kernel owns canonical serialization, immutable intent
   binding, monotonic generations, predecessor binding, projection digests, and
   activation requirements. Phase names are opaque non-empty identifiers.
3. The repository reconciler publishes the projection through a manager-owned
   clean checkout in normal mode or commits it directly in the clean invoking
   checkout under explicit `--local`, derives declarative state through
   `lib/flake`, and verifies the resulting digest before any runtime work
   begins.
4. The runtime reconciler converts that same projection into ordered,
   deterministic host-agent jobs through a registered adapter for the intent
   kind. Controller-owned workflow kinds reconcile a manager journal; host-local
   kinds do not. Unknown kinds fail closed. Before it submits an activation, it
   must satisfy the projection requirement and retain a brokered receipt.
5. Each host agent applies only typed local effects already allowlisted by its
   resource manifest. It enforces holds, projection identity, atomic file-state
   replacement, local service lifecycle, and idempotent recovery; it never
   chooses a cross-host phase.

Workflow-specific code may derive a generic projection but must not duplicate
publication, hashing, runtime binding, or host-local safety logic.

## Host Admission And Granular Resource Convergence

A NixOS generation is admitted at the host boundary, but runtime convergence is
owned by the narrowest declared resource. These are different decisions and must
never share one undifferentiated success or failure result.

Pre-switch admission produces one of three outcomes:

- `host-reject`: no switch is allowed. This covers projection or receipt
  regression, unknown resources, hold ownership or service-target drift,
  released-resource ambiguity, host-scoped conflicts, and any condition that
  cannot prove isolation before mutation.
- `resource-converge`: the resource may apply its exact desired state.
- `resource-defer-held`: the host generation may switch, but one non-host
  resource must retain its exact projected hold and remain inactive.

Only a non-host resource that still owns its exact transaction, declaration,
service set, and monotonic projection hold may be deferred. A host resource is
never deferred because its latch gates the complete managed host. An immutable
activation-job conflict is deferrable only when the conflicting job is terminal
failed; pending or running jobs could still consume stale activation authority,
and a succeeded job implies release evidence that cannot be safely treated as
held.

| Condition                                                         | Host generation | Exact resource outcome      |
| ----------------------------------------------------------------- | --------------- | --------------------------- |
| Projection or receipt regression                                  | reject          | preserve current evidence   |
| Unknown resource or hold ownership drift                          | reject          | isolation is unproven       |
| Host-resource activation conflict                                 | reject          | preserve the host latch     |
| Pending, running, or succeeded conflicting job                    | reject          | stale work is not quiescent |
| Terminal failed conflicting service job with exact hold           | admit           | defer-held                  |
| Service activation or readiness failure during deploy convergence | admit           | restore and defer-held      |
| Exact valid desired transition                                    | admit           | converge                    |

Deferred convergence is an explicit deployment-only policy. The NixOS
desired-resource reconciler uses `defer-held`, so unrelated services can adopt a
safe host generation. Controller-issued jobs and ordinary host-agent commands
remain strict: activation or readiness failure is still a failed migration step,
and host-manager cannot record run success from a deferred deployment.

Before recording a deferral, the host agent atomically refreshes the exact
projected hold, which revokes any stale activation authorization, stops the
resource's declared units and their systemd-owned lifecycle closure, verifies
the declared services are inactive, and re-reads the exact hold evidence. It
writes a separate durable `deferred-held` record bound to the desired projection
and reason. It deliberately does not advance the desired-state success receipt.
A later monotonic projection with a valid successor job may converge normally;
then the agent records success and clears the deferral. A successful reconcile
also clears deferrals for resources absent from the complete authoritative
desired-state manifest. Projection removal means the prior activation request no
longer exists; retaining its non-success record would misreport an active,
unheld service as an unsafe current deferral. Preflight never performs this
cleanup, and a failed reconcile retains all evidence.

Automatic rollback uses a stricter authority boundary than forward closeout. The
incoming snapshot must contain both host-agent manifests and name every durable
projection-owned hold or deferral; omission cannot stand in for newer closeout
evidence. Ordinary forward reconciliation may still intentionally remove
released resources from the complete authoritative manifest and prune their
obsolete deferrals.

Host-agent status reports each deferral with its exact-hold and inactivity
checks. Nixbot health accepts the host only when every reported deferral is
still isolated, emits a visible `deferred-held` warning, and otherwise returns a
rollback-eligible host failure. Consequently, "host generation deployed" never
means "migration run succeeded," and one failed service never silently hides
behind a green fleet result.

## Lifecycle Commands And Canonical Closeout

Stateful moves expose four product commands: `move`, `prepare`, `run`, and
`close`. Each invocation snapshots an ordered, versioned `CommandExecution` and
its stable step IDs before mutation. The command journal records step kind,
executor, immutable input digest, attempt, status, bounded evidence, and
failure; host-agent job journals retain the exact remote specifications and
results. Commands resume their own incomplete execution. Generic `resume` only
routes to the already-running command or projected reconciliation; it never
chooses a new phase or terminal direction.

The journal transition is also the presentation boundary. Human output is the
default: terminals redraw only the active step, while redirected and systemd
output append stable lines. `--json` emits one machine-readable final document
and suppresses human progress. Workflow and adapter code publish typed command,
step, and transfer events rather than inventing command-specific prose. Seed and
other copy jobs enrich the active step from retained agent progress with entry
and byte counts, percentage, throughput, and ETA; presentation-derived rates do
not become workflow authority or alter the retained job schema.

Every blocking operation starts its truthful durable or transient step before
entering Git, Nix, SSH, polling, transfer manifest generation, or another opaque
boundary. Interactive rendering owns an independent one-second elapsed
heartbeat, so transport progress can add detail but silence from a child cannot
make the command appear hung. Projection and closeout publishers expose their
actual validation, commit, retain/push, and verification transitions to the
command runner rather than returning one opaque result whose steps are recorded
retroactively.

Generation-admission dispatchers use the same output contract as manager
commands: concise human output by default, one structured document under
`--json`, and no successful output under `--quiet`. Automated Nixbot and NixOS
pre-switch callers request quiet output; the manager emits one concise admission
status and replays captured stdout to stderr only when an older or failing
validator supplies additional evidence. Raw protocol documents are available
through direct JSON requests and never appear in ordinary successful switch
output.

Projection validation first evaluates the exact staged projection document, then
fully evaluates every affected host's `system.build.toplevel.drvPath`. Those
independent host evaluations use bounded concurrency, never more than four at
once. The active validation step reports the total concurrency and each finished
host without turning completion order into authority; failures are collected and
rendered in canonical host order. Closeout uses the same helper, so publication
and removal retain identical full-host safety while avoiding a serial
host-evaluation wall clock.

Command verbs do not define success prose. `move` success means migration intent
and a verified warm checkpoint, while only successful `run` may say traffic is
on the target. Workflow summaries label endpoint intent as `Move`; `State` alone
describes live authority and routing. Suggested continuation commands must
preserve local versus remote authority explicitly.

Prepare follows durable data authority. Its first checkpoint copies source to
target. After target has activated, prepare holds both sides, backs up target,
and copies target back to source before recording the next run epoch. A new
prepare invalidates prior run success. Reissuing run adopts pending/running jobs
and gives proven terminal failures explicit successor attempt IDs. That job ID
rotation is an internal attempt of the already-running command step: it does not
fail or replace the explicit prepare/run command, and the operator sees a retry
notice followed by the continuing active step rather than a false command
failure.

Prepare may also replace a failed run that never reached `target_active`. It
first proves every retained activation job terminal failed; pending, running,
succeeded, or ambiguous work blocks the phase change. It then retires the old
run action without allocating a successor activation job, invalidates run
success, starts a fresh prepare epoch, and follows `target_ever_started` to
conservatively back up and reverse-sync target data before checkpointing. Dry
planning performs the same transition and job-generation allocation in memory.

`transaction resume` always selects a retained running command before looking at
the last published projection. This matters when an interrupted prepare has not
published its successor projection yet: the old cutover projection is still
fail-closed repository authority, but it must not make resume choose Run. A
transition rejection that occurred after a command journal was allocated is
therefore recoverable by the command itself, not by editing the journal.

Close persists one immutable decision. Bare close first reconciles the current
run: current success completes, absence or proven terminal failure rolls back,
and ambiguous work blocks. Explicit complete or rollback chooses direction but
does not bypass transfer, activation, readiness, routing, or deployment proof.
The sole evidence override is `close --complete --force`: it requires an
already-published target-active projection, exact projected holds, inactive
source, ready target, and an idempotently converged route. It records the forced
decision and never synthesizes prepare or run.

A succeeded command step is an immutable evidence checkpoint. Replaying its
completion with the same structured evidence is idempotent; trying to replace
that evidence fails closed. Resume therefore derives forced-close authority from
the persisted decision instead of the new CLI invocation, and adoption and
cleanup retain separate revision-bound proof.

Removing temporary move intent must not restore the old base placement. A
Nix-native service closeout first commits the adopted placement together with
the terminal move declaration, deploys and verifies it, then removes the move
declaration in a second clean-generation commit and verifies that deployment. If
the manager stops after publishing cleanup, resume accepts that clean revision
only when its sole parent is the persisted adoption revision. It reconstructs
only missing cleanup publication checkpoints and never rewrites succeeded
adoption deployment or verification evidence. Runtime-only host, instance, and
resource workflows remove their projection and record generic closeout evidence
atomically in `data/phase-projection-closeouts.json`. That catalog cannot
express service placement. Its closeout record retains the exact affected-host
set, decision, projection digest, and controller-reconciliation mode. Nixbot
deploys those hosts before the controller. A digest-bound oneshot in that
deployed controller generation then releases the final inactive-side projection
hold and closes the journal. Close submits the exact pushed revision as a
durable controller Nixbot job, releases its authority lock only after the job is
retained, and waits for that deployed reconciler before reporting success. Under
`--local`, the closeout instead records `controller_reconcile = false`, Nixbot
consumes the exact local commit from the invoking checkout, and that same
invoking manager performs final hold release against its local journal. A push,
client exit, or controller generation that predates a normal closeout can never
release that hold; a controller generation can never acquire a local closeout
journal.

A projected release consumes the exact hold capability, including its activation
requirement digest. That digest is immutable lineage evidence, not permission to
start the resource; release still only removes the hold and never activates a
service. A deployed closeout automatically preserves a terminal failed host job
and retries the same logical step under a deterministic successor attempt ID.
`transaction resume` recognizes this post-deploy boundary and continues the
digest-bound closeout instead of routing it back through phase reconciliation.
Conversely, a phase reconciler whose exact projection has been replaced by a
matching canonical closeout exits successfully as a superseded no-op. Digest,
decision, or terminal-phase mismatches continue to fail closed.

For repository-backed fleet workflows, one configured host-manager controller
owns the manager journal from the first command. Operator commands dispatch to
that controller, and deploy-time reconciliation runs there against the same
journal. Git does not replace or reconstruct observed workflow state. A
controller with no matching immutable journal fails closed instead of inferring
completed steps from desired state.

## Fleet Capability Topology

Infrastructure roles are a small flat capability map over canonical host
resources, not service-specific automation nesting:

```nix
config = {
  controller = "abird-ci";
  transferBroker = "abird-ci";
  builders = ["abird-ci"];
  registries.nix = {
    host = "abird-ci";
    url = "http://ci.abird.internal:5000";
  };
};
```

The controller owns workflow state, admission sequencing, repository
publication, and deploy routes. The transfer broker owns peer-to-peer data
movement. Builders are ordered execution resources; the first is the default,
not an automatic failover promise. Registries are protocol-specific named
capabilities, so Nix cache behavior does not leak into a future Podman artifact
registry. Ingress is absent because it is an effect endpoint resolved by the
relevant projection adapter, not a global controller dependency.

One host may implement several capabilities today. Consumers must still read
only their own role so those capabilities can move independently later. Config
references use canonical `resourceId` values and resolve to exactly one
inventory endpoint; unknown or ambiguous references fail before execution. A
canonical resource match takes precedence over a coincident legacy inventory
key, with the exact inventory name used only when no resource match exists.

Controller selection is orthogonal to state placement. `--controller local` uses
local XDG state by default. `--controller HOST --state-dir RUN` stores an
isolated run beneath the remote controller's existing manager state root. The
repo-local `--local-run NAME` shorthand selects local execution and
`.agents/runs/NAME/host-manager`; it conflicts with both explicit controls so
there is never more than one state owner.

Global `--local` is a stronger end-to-end authority choice than either
`--controller local` or `--local-run`. It fixes controller, journal, repository
checkout, commit ownership, and deployment source together: controller dispatch
is disabled, state is `.agents/runs/local/host-manager`, phase and closeout
commits are written directly to the clean invoking branch, and no publication
push preflight, push, or remote-ref verification is permitted. Every command
accepts the flag so a transaction never needs to cross authority models. Local
phase commits add their projection IDs to canonical controller-reconcile
exclusions, preventing a later exact-local-commit deployment from creating a
remote reconciler for the local journal; close removes the phase exclusion and
retains the locally owned closeout marker.

Nixbot owns managed-mirror freshness and the repository-scoped read-only fetch
transport on that controller. Each configured repository derives that transport
and, when requested, one mirror-ready systemd unit. Host-manager matches its
checkout to the Nixbot repository by exact path, keeps its ordinary `git`
default, and inherits the same strict persistent host-key policy. The mirror
identity never gains publication authority.

For an explicit operator-dispatched phase decision, the dispatcher permits an
operator branch that is behind prior controller-published projections but
rejects unpublished or divergent local commits. It opportunistically forwards
the operator's SSH agent only for that controller session. The publisher uses
the exact configured publication transport with the mirror's pinned host keys
for the final fast-forward push after validation and commit. The controller
stores no persistent write-capable repository identity. Missing publication
credentials or a rejected push fail before runtime handoff.

For every remotely dispatched non-dry lifecycle command that can publish
(`move`, `prepare`, `run`, rollback, and `close`), the dispatcher forwards a
valid local SSH agent when one is available. The controller then refreshes its
owned publication checkout and runs `git push --dry-run` to the exact branch
with the exact configured publication transport. This catches authentication,
transport, and obvious ref-update denial before lifecycle-journal mutation; the
real push remains authoritative for server-side hooks and branch policy. A
particular credential mechanism is not the gate. Dry planning, inspection, and
reconciliation of already-published intent run no write preflight.

Closeout deployment is part of terminal safety, not optional synchronization. In
normal mode, the pushed closeout revision must replace the projection-bearing
generations on the source, target, effect hosts, and controller before the
inactive projection hold can be released and the journal archived. In local
mode, the corresponding authority is the exact committed local `HEAD`; it is
deployed from the invoking checkout before that invoking manager releases the
hold and archives its local journal.

The deploy boundary is operator-selectable without weakening that invariant.
Interactive close asks whether host-manager should submit and follow the durable
Nixbot job or leave its command step pending and print an exact manual command.
`--yes` selects the managed path without a prompt; `--manual-deploy` selects the
manual handoff. In normal mode, both begin only after the exact revision is
pushed and verified. In local mode, both bind to the exact local commit: managed
mode executes Nixbot synchronously with inherited logs, while manual mode prints
the equivalent local command and leaves the local journal step pending. Local
mode never materializes or submits a Nixbot job through the controller host
agent.

Managed Nixbot jobs persist a bounded stdout/stderr tail as job progress.
Interactive host-manager renders one current line and toggles the retained tail
with `l`, preserving ordinary signal keys. Observability is therefore durable
across manager disconnects and does not couple job execution to an SSH stream.

Controller self-deployment must be classified before constructing activation
locking. The packaged Nixbot runtime owns all hostname and address-discovery
programs used by that classification. When the target matches the current
controller, activation reuses the already-held outer host-local lock; it must
never wrap itself in a second wait on the same lock. Package tests assert both
the discovery runtime and the self-target lock command.

The mirror-ready unit refreshes the clean managed checkout with read authority
after network readiness. It runs at boot and restarts when the deployed
repository revision changes. Controller projection reconciliation requires that
unit, consumes only already-published projections, and never commits or pushes.
A deployment therefore needs no forwarded agent or write Git capability. Dirty
mirrors and fetch authentication or host-verification failures fail visibly
instead of being reset or silently bypassed.

## Managed-Host Propagation Spine

```text
abird-app or another client
          |
          | objective, review, and explicit approval
          v
abird-agent application controller and capability policy
          |
          | admitted typed workflow intent
          v
abird-host-manager workflow adapter and manager journal
          |
          | validated phase transition
          v
immutable phase projection
          |                         |
          |                         |
repository publisher          runtime reconciler
          |                         |
          +-----------+-------------+
                      v
       identical projection-bound host-agent jobs
                      |
                      v
       authority evidence and observed state returned to the controller
```

For controller-initiated changes whose durable effect reaches a managed host,
phase projection is the architectural default. This includes service state,
placement, routing, identity, secret-reference installation, access policy,
trust, package, instance, and host lifecycle once their typed effect adapters
exist.

The application controller owns capability admission and approval binding. The
host manager's workflow adapter owns the domain transition graph, manager
journal, cross-host sequencing, and projection recovery. A model, prompt, UI,
workflow step, or repository document may propose desired state, but none
bypasses controller policy, host-manager transition validation, or host-agent
allowlists. A normal deployment and an immediate runtime reconcile are co-equal
issuers of the same projection-bound capability; either may start a phase, and
the other must adopt the same retained job and evidence.

Phase projection is a propagation protocol, not a general event bus. Read-only
observation, diagnostics, isolated task-local effects, and Git or PR work that
does not change managed-host state remain ordinary typed controller operations.
If a workflow eventually changes durable managed-host state, that boundary must
enter the projection engine. An exception requires an explicit design decision
that records why declarative/runtime equivalence, interruption recovery, and
projection receipts do not apply.

## Runtime-Only JSON Projection Path

This path is current for typed host, instance, and resource workflows that do
not yet have a Nix projection domain. Logical service items are rejected at the
publisher and loader boundaries. New service moves and new dual-projectable
domains follow `dual-projection-domains.md` and author Nix under
`config/<family>`.

Every runtime-only phase command renders one immutable, secret-free projection
before it can mutate live state. The projection is stored under:

```text
data/phase-projections/<projection-id>.json
```

Only root-level JSON files in that directory are active desired-state documents.
Human workflow guides may live under `data/phase-projections/guides/` and are
not loaded by the flake. Host-manager inventory, transport, and issuer policy
remain package-owned configuration or repository-derived state; they must not
masquerade as projections. Workflows that cannot yet prove declarative/runtime
equivalence may remain under `data/migrations/` until they gain a typed
projection adapter.

The normal deployment path and live reconciler consume the same projection
digest and typed effects. They may differ in transport and timing, but not in
the intended resource state, selected configuration profile, placement, or
activation requirement.

All manager-side projection commands hold one controller authority lock from
repository refresh and publication through the optional runtime handoff. The
publisher requires proof of that exact state-directory authority, so move and
standalone-hold commands cannot race through the shared manager checkout.

Publication validation is projection-scoped. Nix must load and return the exact
staged projection document, including its canonical digest, before the publisher
evaluates the controller and every host named by the projection's resources or
typed effects. Evaluate each affected NixOS configuration in a separate process
so a bounded controller releases evaluator state between consumers. A
repository-wide flake check remains a development and deployment gate; it is not
the per-projection publication primitive because unrelated packages and fleet
configurations do not strengthen the atomic publication decision and can exceed
controller memory. Read the staged documents through the controller's existing
`services.abird-host-manager.phaseProjections` option, which is the real
declarative consumer. Do not add a parallel top-level flake output solely for
publication: controller code may be deployed ahead of the authoritative Git
branch, while the consumer contract is already part of every repository version
that supports projected reconciliation.

Projected holds carry the canonical host-agent transaction identity and
projection lineage. Hold, unhold, and activation each materialize a canonical
immutable job from that lineage and the same host resource manifest. Hold job
identity includes the projection digest because several phases may retain one
hold epoch while changing the projected generation. The host-agent job store is
therefore the shared execution record: whichever path arrives second attaches to
the existing pending, running, succeeded, or failed job instead of creating a
parallel operation.

Projection lineage is also retained in the durable hold record. Unscoped raw
acquire, release, and activation commands may continue to operate on raw
runtime-only holds, but they cannot claim or consume a projection-owned hold.
Only an exact projected job may advance or release that capability. This keeps
backward compatibility outside the two-issuer boundary instead of creating a
third activation path.

Repository publication is allowed to be ahead of observed runtime. A projection
expresses desired state and the identity of a prerequisite; it never embeds an
observed receipt or claims that work completed. Observed evidence belongs only
in manager and agent journals.

`--skip-runtime` is available on every operator decision. It publishes and
validates the declarative projection but submits no host-agent job and performs
no live mutation. A later deployment or explicit runtime reconciliation resumes
the same projection.

A partial deployment may enforce host-local holds immediately. A normal
controller deployment also runs projected reconciliation, so cross-host work is
resumed from the controller journal. A direct host deployment is a distinct,
trusted administrative override: reviewed repository provenance may authorize
the active projected state without first producing a manager receipt.

Operators recover every interrupted transaction with `transaction resume`. For a
projected journal, resume refreshes and validates the published projection,
computes the missing actions up to that desired phase, and runs the projection
reconciler. A non-projected historical journal remains inspectable audit
evidence and cannot be resumed. Resume never selects or publishes a new phase.
The generated controller service uses a hidden `_reconcile` entrypoint whose
mandatory expected digest binds execution to the deployed projection generation.

There are exactly two activation issuers:

- `repository_deploy`: trusted reviewed Nix deployment authorizes the exact
  projected generation. Verification and attestation are best effort. This may
  deliberately override a missing cross-host receipt, including in a partial
  target-only deployment; that operational risk is part of granting deployment
  authority, not evidence that preparation completed.
- `brokered_receipt`: the host manager must derive and durably retain the
  matching prerequisite receipt before it may submit the activation job.

The two issuers materialize the same immutable host-agent job. Issuer evidence
is deliberately outside that job specification: the stable requirement digest
keeps job identity equal across both paths, while the manager journal records
which authority was used. A later manager run may adopt only an already
succeeded job whose full immutable specification matches the current projection;
it records `repository_deploy` rather than fabricating a broker receipt.

This is the central distributed-safety boundary:

- repository deployment may issue or replay the exact projected capability by
  trusted provenance;
- the manager may issue that identical capability only after a brokered receipt;
- both remain constrained by the current projection, exact hold epoch, local
  resource allowlist, and unrelated holds; and
- neither authority turns a deployment override into false preparation or
  verification evidence.

At cold start the host module uses one latch barrier for both system and user
managers: it first persists the complete declared and projected hold set,
enforces every hold, and only then publishes a generation-bound user-visible
readiness marker. System units remain ordered behind the reconciler. User units
wait for the marker and evaluate their exact hold conditions only after every
latch exists and its service stop has completed. The marker is outside the
agent's private runtime directory and contains no authority or secret; the
durable hold files remain the authority.

For every gated user, the system reconciler wants and orders itself after the
exact `user@UID.service`. This makes the local user bus available for hold
enforcement without releasing any managed user service: those services remain
queued behind the readiness marker until enforcement completes. Gated users
therefore require fixed integer UIDs. The ordering uses systemd's existing
manager timeouts; the phase-projection layer does not add a competing boot wait.

During `switch` and `test`, the NixOS activation script performs that same
idempotent reconciliation before the user generation is reloaded. It must not
delegate marker publication exclusively to a changed system unit:
`switch-to-configuration` may wait for user jobs before it restarts that unit,
which creates a cross-manager deadlock. The ordinary system service repeats the
same reconciliation at boot and after activation. The user readiness wait is
bounded so any future ordering regression fails visibly instead of hanging a
deployment indefinitely.

Every independent runtime lifecycle owner must carry the same cold-start gate as
its public resource unit. Native Quadlet container units therefore require the
user hold-readiness barrier and evaluate the exact service hold or activation
authorization plus the optional whole-host hold. Preparation-only stage, image,
and network units remain outside that runtime gate. A child with
`Restart=always` can otherwise restart independently after a propagated
`PartOf=` stop and briefly run a writer while its public resource is held.

When enforcing a hold, the host agent reads the public unit's `ConsistsOf=`
ownership graph and explicitly names the public unit and every currently loaded
child in one systemd stop transaction. The declarative runtime gate closes the
race for children that appear after that ownership snapshot. After the stop, the
agent clears failure state only for the still-loaded failed subset of that exact
closure. Units unloaded by the stop already have no retained failure state. This
keeps deliberately stopped Quadlet children from turning a successful hold into
fleet-health failure without masking an unrelated failed unit. Read-only systemd
ownership and failure queries use a short bounded retry because user-manager
transport is briefly unavailable during some generation transitions. Named local
user managers are addressed directly as `USER@`; they must not be routed through
the extra `.host` machine transport during activation. The configured host agent
enters that user context with `runuser`, supplies the exact `/run/user/UID`
runtime directory, and connects to the user's own bus; arbitrary shell text is
never involved.

## Generic Projection Contract

The versioned outer document contains:

- a stable projection ID and workflow intent kind;
- the immutable intent value and digest;
- an opaque desired phase and monotonic generation;
- the previous projection digest and published repository revision;
- typed desired resource states and typed effects;
- an optional activation requirement; and
- the canonical projection digest.

Generic resource states are `held`, `active`, `inactive`, and `unheld`. A
projected hold uses an immutable hold epoch owned by the projection intent.
`unheld` releases only that exact epoch and never starts the resource; `active`
is the distinct start-and-verify transition. Activation may require matching
retained evidence; the generic layer calls this an activation requirement rather
than naming a workflow-specific receipt.

A standalone hold is not a second hold subsystem. It is the smallest workflow
adapter: one immutable `resource_hold` intent, one endpoint, and the phase graph
`held <-> unheld`. The first phase is always `held`; each later re-hold rotates
the epoch while retaining the stable intent ID. Migration phases use the same
endpoint states and host-agent primitives inside their larger projections. There
is no nested migration hold state machine.

`resource_hold` is registered as a host-local projection adapter and therefore
does not receive a controller transaction-reconcile service. `move` is
registered as a controller-owned workflow adapter and does. This registry is the
only mapping from an intent kind to reconciliation ownership; generic Nix code
must not infer a controller command from an arbitrary projection.

The operator surface is correspondingly small:

```console
abird-host-manager resource hold set HOST RESOURCE --id ID
abird-host-manager resource hold clear HOST RESOURCE --id ID
```

Both commands publish the projection before optional runtime reconciliation.
Adding `--skip-runtime` changes only repository desired state so deployment may
reconcile it. The paths are interchangeable at every boundary: a hold may be
established live and cleared by deploy, or established by deploy and cleared
live. Rerunning an exact command is idempotent. Reusing the same ID for a later
`set` advances the projection generation and selects a fresh hold epoch, so
stale release evidence cannot unlock it.

Initial typed effect families are:

- desired resource state;
- allowlisted file-state profile selection with compare-and-swap, validation,
  atomic replacement, reload, and exact rollback;
- service placement projected through the flake stack engine; and
- deterministic local lifecycle or provisioning actions already declared in the
  host-agent resource manifest.

A service-placement effect must preserve the stack's complete placement family.
It remaps the service role on the active stack and on every named endpoint-group
placement; it must never replace a placement-bearing stack with one concrete
projected stack. Host configurations select those named placements
independently, so collapsing the family makes an otherwise valid projection
unevaluable before publication. Regression coverage must force an active
projection through both the active placement and at least one inactive
placement.

A route-profile effect names one selected profile, one fail-safe baseline, one
executor resource, and the complete allowlisted endpoint-profile set for that
transition. Profile names are stable catalog identities derived from the service
and canonical host resource, not workflow words such as `source`, `target`, or
`zulip`. The projection carries endpoint identities only; it never contains
Nginx text.

The Nginx adapter is a standing generic capability. It uses the ordinary stack
service registry and ordinary route renderer to externalize each routable
service into one durable file, and precompiles exact profiles for the registry's
declared roles. This is what permits the first runtime command to select a route
without first deploying migration-specific proxy configuration. An active
projection merely narrows that catalog to its declared endpoint pair and names
the baseline used on a fresh host. Because profiles are addressed by canonical
host resource, role aliases must resolve to unique hosts; the adapter rejects an
ambiguous catalog instead of silently choosing one rendering.

Planned reusable effect families include:

- identity principals, memberships, roles, and policy bindings;
- secret reference, version, recipient, and installation lifecycle;
- access policy, trust material, and credential rotation;
- DNS, ingress, routing, and service-discovery selection; and
- host, instance, package, and service lifecycle transitions.

Every effect family has one canonical desired-state renderer and two adapters:
the repository adapter writes the ordinary declarative unit, while the runtime
adapter applies the same normalized desired value immediately. A verifier
produces typed attestations proving the observed system matches the projected
value. Those attestations remain observed journal state and never change the
projection or deterministic job identity. The adapters may differ in transport,
but must agree on the same canonical effect digest.

Effect schemas are versioned and deny unknown fields. A projection selects
identifiers and expected digests; it does not carry arbitrary commands, paths,
credentials, or peer-authored executable content.

Identity and secret workflows require stronger boundaries. Identity adapters
must use stable principal and policy identities, provider compare-and-swap or
equivalent preconditions, and retained provider receipts. Secret projections
never contain plaintext or low-entropy plaintext hashes. They may select an
existing secret reference, encrypted artifact, recipient policy, provider
version, or ciphertext digest. Secret creation and retrieval remain inside a
typed secret owner or provider adapter, and host agents install only an
allowlisted reference at an allowlisted target. Repository history records the
encrypted artifact or reference needed to reproduce the same state.

Cross-system phases may eventually group several effects behind explicit
prerequisites and ordered activation barriers. Until a real distributed barrier
and compensation protocol exists, move specifications reject multi-item
consistency groups and multi-item activation waves instead of presenting serial
ordering as atomicity. A workflow adapter defines compensation or rollback
semantics for its domain; the generic projection kernel records evidence but
does not invent reversal behavior.

## Repository Boundaries

User-editable family declarations under `config/<family>/` remain simple
canonical inputs. Phase projection interpretation and stack transformation
belong under `lib/flake/`, after base stacks are loaded.

Individual host files do not scan projection directories or implement phase
logic. The root flake loads validated projection documents once and injects them
generically into the host-agent module. Service modules declare ordinary
resources and allowlisted state profiles only where needed.

Mutable route selection is isolated from ordinary generated configuration by a
generic Nginx adapter under `lib/services/nginx/`. The proxy host module
contains no workflow, service-move, or Zulip phase names. Each registry-backed
HTTP service has one durable route file covering its complete HTTP, internal
TLS, and edge TLS configuration. Services with no active projection follow
ordinary declarative deployment. An active projection bootstraps its declared
baseline only when the file is absent and otherwise preserves controller-owned
bytes. Every profile transition uses an allowlist compare-and-swap across all
valid catalog states, candidate validation, atomic replacement, and reload
rollback.

Composable route files contain only route-local declarations: rate-limit zones,
upstreams, and server blocks whose bytes vary with the selected profile.
HTTP-scope singleton scaffolding such as shared normalization maps, deferred TLS
certificate maps, and default unknown-SNI rejection servers is rendered once in
an earlier ordinary configuration file. It must never be repeated per service.
The base Nginx configuration loads durable files through a dedicated
`phase-route-*.conf` include. A pre-projection generation has no such include
and therefore safely ignores retained route state during rollback. Regression
coverage assembles multiple projected profiles and runs the real Nginx parser,
in addition to checking singleton cardinality and the dedicated include.

Runtime candidate validation derives container identity from runtime ownership,
not from a duplicated Compose container name. For native Quadlet, the validator
walks the public service's systemd `ConsistsOf` graph and resolves its running
container through the `PODMAN_SYSTEMD_UNIT` label. A Compose backend falls back
to the same instance's resolved working-directory and Compose-service labels.
Both paths require exactly one running match, reuse that container's exact image
and mounted configuration, and run the parser in a new network namespace.
Validation must never join the serving container's namespace: configuration
tests bind declared listen sockets and would contend with the live proxy. Tests
cover both runtime ownership paths, missing and ambiguous ownership, and the
isolated-network invocation.

Executable Nginx adapter behavior belongs in the packaged
`lib/services/nginx/helper.sh`, not in generated Nix shell text. Nix constructs
typed argv and immutable inputs for the helper's config installation,
best-effort reload, and runtime candidate-validation subcommands. This keeps
shell control flow independently lintable and testable while leaving the host
module as declarative wiring.

Ordinary service lifecycle follows declarative placement. A service shared by
source and target hosts derives `autoStart` from whether the registry's selected
endpoint is the local host. Migration bootstrap latches do not belong in host
files; the projection installs and owns its transactional hold.

`services.abird-host-agent.declaredHolds` remains only a bootstrap latch. It may
safely hand off to the first projected `held` phase in one durable record
replacement, but it is not synthesized from projections and may not overlap a
projected hold in one Nix generation. Early boot reconciles projected hold
epochs before ordinary units and before full desired-state activation, which
closes the deploy-first handoff window without placing workflow logic in a host
file.

The standalone host-agent module accepts typed projections through module
options or special arguments and has no hard dependency on this repository's
directory layout. The standalone host manager may use a different projection
store, but it cannot claim repository/runtime equivalence without a durable
declarative publisher.

## Safety And Recovery

- Repository publication and validation complete before runtime submission.
- Publication validates the exact staged document and all declarative consumers
  affected by its resources and effects, including the controller. It does not
  substitute an unrelated repository-wide evaluation for that bounded proof.
- Projection generations advance monotonically and bind their predecessor.
- Repeated reconciliation uses deterministic job IDs and exact digest matching.
  When a terminal job is superseded, the workflow journal allocates the
  successor attempt before projection rendering, and the projection carries that
  exact attempt ID. Repository and direct reconciliation must never derive
  different job identities for one attempt.
- Every switch or test activation preflights the incoming desired-resource
  manifest against durable hold generations and retained immutable jobs before
  `/run/current-system` or an activation script can change. A Nixbot rollback
  first uses the currently running generation's stable preflight command, so
  even an older snapshot without the pre-switch hook is refused before switching
  when its projection generation is older than durable host-agent evidence.
  Missing manifests and omitted durable projected resources also fail closed;
  rollback omission is not accepted as forward closeout. If the current
  generation itself predates that stable command, automatic rollback fails
  closed because it cannot prove projection safety. An incoming generation's
  terminal pre-switch rejection is explicitly classified as non-mutating and
  never triggers snapshot rollback. New generations repeat the check in their
  own pre-switch hook.
- A newer desired phase never erases missing prerequisite work.
- A host agent rejects unknown resources, effects, profiles, epochs, or digest
  mismatches.
- Declarative and controller activation share one primitive bound to intent
  digest, projection digest, generation, hold epoch, and activation requirement.
  The manager separately journals its receipt; a deployment is authorized by
  reviewed provenance. Older releases cannot authorize a newer projection.
- Activation never follows from elapsed time, connectivity loss, or declaration
  removal.
- Failed local reload restores exact prior bytes and mode, then reloads the
  restored state.
- Workflow adapters, not the generic reconciler, decide allowed transitions and
  whether rollback requires compensating data movement.
- Rollback projection is derived from controller observations such as whether
  the source hold completed and whether the target ever started. Desired Git
  phase alone never guesses those facts or rotates an unnecessary hold epoch.
- Before an executable rollback advances beyond a deployed cutover, the manager
  retains superseded projections by digest, probes and adopts the exact prior
  cutover activation job, and then derives compensation. This prevents a
  declarative-only rollback from erasing evidence of a deployment-first target
  start. `--skip-runtime` remains contact-free and therefore makes no observed
  claim.
- Repository overrides are terminal scheduler decisions recorded separately as
  overridden steps. They never enter the completed-step set and therefore never
  masquerade as preparation, transfer, readiness, or verification evidence.
- Repository authorization records bind to a retained projection digest,
  generation, and that projection's exact activation requirement. Evidence
  digests are computed from the retained canonical job specification and result,
  not from optional response fields.
- Normal Git publication is fast-forward only and never mutates an operator's
  checkout. Explicit `--local` performs no publication and intentionally commits
  in the clean invoking checkout.
- Every repository-scoped Git subprocess clears inherited repository-selection
  variables such as `GIT_DIR`, `GIT_WORK_TREE`, and `GIT_INDEX_FILE` before
  selecting its explicit working directory. Hooks and wrappers may export those
  variables for their own repository; allowing them to leak into owned or test
  checkouts can commit against the wrong repository while appearing successful.
  Transport variables such as `GIT_SSH_COMMAND` remain explicit publication
  inputs and are not part of this isolation boundary.
- Normal repository-backed operator and deploy paths share one
  host-manager-controller-owned workflow store; local-mode paths share one
  invoking-repository journal instead. Missing state in either selected
  authority is an error, never a cue to infer a phase.

## Adoption Rule

When adding a future controller capability that changes durable managed-host
state, first express its phases and desired effects as a workflow adapter over
the generic projection contract. Extend the generic kernel only for a genuinely
reusable typed effect. Do not add a direct controller-to-shell mutation lane or
workflow-specific projection readers to host files, stack declarations, or
host-agent execution code.

The long-term goal is that repo-only fleet state—including identity, secrets,
policy, placement, and routing—can opt into the same projection path and gain an
immediate dynamic reconcile without creating a second source of truth. The
projection, immutable job, issuer record, and optional attestations make both
paths reproducible, consistent, and verifiable without mixing desired and
observed state.

Human-authored static configuration that needs only an ordinary deployment does
not need a phase projection. Controller-initiated host changes use phase
projection by default, including declarative-only requests made with
`--skip-runtime`. When an effect has no safe runtime adapter, its projection may
remain declarative-only and report runtime reconciliation as unsupported; it
must not fall back to arbitrary remote execution.

This unsupported-adapter rule is fail-closed in the current move producer.
Repository-backed Incus instance moves are rejected until a typed declarative
instance adapter maps the exact Incus remote, project, instance, executor, and
host-agent job identity. The explicit runtime-only transaction path remains
available; the projection engine does not claim false equivalence.
