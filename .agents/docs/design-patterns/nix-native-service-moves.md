# Nix-Native Service Moves

This is the service-move adapter for the generic contract in
`dual-projection-domains.md`. Domain-independent publication, recovery,
admission, and runtime-evidence rules belong there; this document defines the
service placement and migration semantics layered on top.

Nix is the sole repository-authored desired state for new logical service
migrations. Stable placement is one small role assignment under the owning
`config/<family>/placements/<scope>/<service>.nix`; each active transaction is
one manager-owned Nix declaration under
`config/<family>/moves/<transaction>.nix`. The declaration's `scope` selects a
canonical stack or placement realization; the evaluated scope catalog
independently selects its repository owner. For example, scope `abird-gondor`
belongs to stack `abird` and configuration family `abird`, so it is authored
under `config/abird`, never a synthetic `config/abird-gondor`. Service
implementation and migration policy remain human-owned in that family's service
capsule.

The evaluated repository layout is the path ABI. Each scope declares its exact
owner, placement directory, and move directory in the projection snapshot. The
Nix adapters derive owned paths from those fields and the publisher consumes the
same fields. Scope-qualified placement directories allow sibling placement views
to author the same service independently. The write-evaluate-compare guard still
proves that a written declaration is the one Nix evaluated. Existing move paths
may be absent before first publication, so existence is not a fold-time
invariant.

Every `config/<family>` declaration has the same
`{ stacks, projectionScopes, projections }` shape. `projections` implements the
typed domains registered by `lib/flake/repository-config.nix`; today those
domains are `servicePlacements` and `serviceMoves`. `config/default.nix` is the
repository composition manifest. The central fold is domain-agnostic: each
domain owns fragment validation, collision handling, and final aggregation,
while the fold only enumerates families, stacks, fragments, and domains. Future
dual runtime/Nix domains such as identity, ingress, or load balancing add one
typed domain specification and only the family fragments that carry intent,
rather than a new parallel configuration pipeline.

The schema-4 declaration contains immutable identity, authority, scope, an
ordered, non-empty set of service items, requested phase, generation, per-item
activation attempts and lease numbers, lineage, each item's immutable
service/topology `basis_sha256`, and an optional transaction-wide terminal
decision. It does not contain generated host jobs, manually assembled effects,
observed success, or private capabilities. One pure Nix evaluator validates the
declaration and derives its transaction `semantic_sha256`, exact phase
projection, and resource claims. JSON is permitted only as the ephemeral
`nix eval --json` transport ABI.

Multi-service moves are first-class transactions, not a loop over unrelated
single-service publications. Items use stable canonical IDs (`item-001`,
`item-002`, ...); service identities are unique; and every item has its own
basis, source/target lease pair, resource endpoints, placement effect, and route
effect. Phase, lineage, authority, and close decision belong to the transaction.
Repository publication writes the one move plus all affected stable placement
files atomically. Runtime execution is a durable, ordered saga: each item is
independently evidenced and retryable, and a command is successful only when all
items reach its checkpoint. This does not claim an unimplemented distributed
simultaneous-activation barrier.

The basis catalog exposes a service only in scopes containing every eligible
endpoint role. All public evaluator outputs force the same admission set. Writer
resources and path-prefix data roots must be disjoint between items. Separate
active transactions must also have disjoint route resources. Items in one
transaction may share a route resource because the evaluator generates one
independent route file per service and the runtime applies those profiles in
deterministic item order. Writer/route cross-kind overlap remains forbidden. A
contract consumer must therefore never bypass conflict validation by selecting a
narrower output.

A move between two roles that resolve to the same host is invalid. Its source
and target would claim the same host writer resource, so claim arbitration
rejects it even when both claims belong to one transaction. Service moves model
an authority transfer between distinct writer endpoints, not a same-host role
rename.

Logical service selection is explicit and repository-aware. `--scope` selects a
scope and `--stack` limits the candidate scopes. Otherwise a unique stable
placement wins, followed by the repository's optional `defaultScope`, followed
by a unique canonical stack scope. Ambiguity fails closed. The authored
`defaultScope` is exported only through the derived `{ scope, stack; }`
`defaultSelection`; it replaces Pvl's historical `env = "prod"` inference. Pvl
can declare `pvl` directly while Abird can rely on stable placement authority or
leave the default absent.

A move scope must select a complete service stack with object-valued
`serviceRegistry.roles` and `serviceRegistry.services`. Family ownership alone
does not make shared data or a package-only evaluation move-capable. Move
evaluation, basis-catalog generation, phase effects, and repository-mutation
resolution all use this same capability predicate and fail with their own
contract diagnostic before dereferencing registry contents.

Host-manager always executes the generic runtime-plan projection returned from
the written Nix declaration and requires it to equal the domain contract.
`move`, `prepare`, and `run` commit before runtime mutation and then reconcile
granular host-agent resources directly; no deployment is needed. The runtime
journal owns observations, transfer verification, readiness, activation results,
and release capabilities.

Activation authorization is an epoch, not a phase label. A newly prepared or
rollback-authoritative projection hashes its generation and predecessor
projection into a fresh requirement. Cutover and same-phase retries inherit the
exact prepared requirement they are consuming. A later prepare therefore cannot
reuse an old activation receipt, while an interrupted run can resume after the
cutover projection is already published. Nix and Rust derive and persist the
same requirement, including the previous requirement in each authored move
declaration.

Close has two repository states:

1. adoption changes every affected stable role in one repository publication and
   changes the move to `adopting-target` or `adopting-source`, preserving the
   exact terminal runtime projection and every recovery lease;
2. cleanup removes the move after adoption deploy succeeds, deploys the clean
   stable state, then releases the inactive-side lease and archives the journal.

No activation-time controller unit may release a Nix-native recovery lease.
Activation precedes Nixbot health verification, so only the manager observing a
successful cleanup deployment may finalize the runtime transaction. A crash is
resumed from the retained runtime journal plus the clean evaluated placement;
temporary repository closeout metadata is not retained after cleanup.

Manager-written Nix files are rendered from typed values as complete canonical
documents, including explicit Nix interpolation escaping. Local publication
records a recovery marker with the exact owned paths and base revision before
the first mutation. An interrupted pre-commit attempt restores only those paths;
an exact completed commit is retained; unrelated changes or ambiguous history
fail closed. Text-fragment replacement and broad checkout cleanup are not
acceptable publication mechanisms.

Recovery is automatic on the next manager invocation. If a pre-commit marker
cannot be recovered because unrelated checkout paths are dirty, preserve the
marker, clean or stash those unrelated paths, and rerun the same command. Never
delete the marker by hand: it is the proof that lets the manager distinguish an
unstarted write, an interrupted write, and an exact completed commit.

Every generation installs a fleet-wide service-placement admission contract. The
pre-switch check compares the running and incoming contracts. A stateful role
change requires exactly one matching adoption declaration with the same basis
and semantic locks; removal of the admission contract is rejected after its
first deployed generation. Automatic rollback is admitted only for the exact
reverse transition from a deployed adoption to its matching terminal
predecessor. The normal desired-resource preflight then proves exact durable
hold and activation evidence. Unrelated services remain resource-granular; only
an actual host resource conflict is host-atomic.

Schema 3 is the only accepted service-placement admission document. Its
`predecessors` attribute remains in the deployed wire shape with exact empty
schema-1 and schema-2 slots; changing that shape now would itself require a new
schema transition. The adapter compares schema-3 documents strictly across all
scopes and rejects older documents. A future schema change must introduce an
explicit edge normalizer and prove both forward admission and rollback through
the generic domain dispatcher before deployment.

Dropping a stateful placement classification is deliberately inadmissible.
Closeout moves authority to a stable role and removes only the move declaration;
it never deletes the service from the admission contract. Service
decommissioning needs its own retirement contract with data-disposition and
rollback evidence and is unsupported until that contract exists.

A controller-authoritative nonterminal move authored directly in Nix may create
its runtime journal from the evaluated immutable intent when the deployed
reconciler first runs. This bootstrap still passes normal overlap and host-agent
admission. An adopting declaration may never bootstrap a journal: terminal
placement requires an existing journal containing the exact successful run or
rollback evidence.

`data/phase-projections/*.json` is the runtime-only authority for typed host,
instance, and resource workflows that do not yet have a Nix projection domain.
The loader and publisher reject logical service items there. Service moves must
carry both a declarative scope and repository family, and their scope, family,
services, and transaction ID must all be valid repository components before any
journal or repository mutation is created. A partial identity fails closed; a
validation error never selects the runtime-only writer.

The retired `data/service-moves` and `data/service-placements.json` surfaces are
not read, written, or scanned. Runtime-only closeout evidence is kept separately
in `data/phase-projection-closeouts.json`; it records only generic closeout and
controller-reconciliation evidence and cannot change service placement.

## Compatibility matrix and retirement gates

| Contract                                             | Current schema | Rule                                                                                          |
| ---------------------------------------------------- | -------------: | --------------------------------------------------------------------------------------------- |
| Nix move declaration                                 |              4 | The only service-move declaration; activation attempts are keyed per item.                    |
| Repository service-placement document                |              3 | The only accepted committed placement shape; it contains stable placements only.              |
| Host-generation service-placement admission document |              3 | The only accepted placement-admission shape; predecessor slots are present and empty.         |
| Runtime projection plan                              |              1 | Typed evaluated transport consumed verbatim by Rust.                                          |
| Projection domain envelope                           |              1 | Current generic fold contract.                                                                |
| Generation admission registry                        |              1 | Current multi-domain dispatcher contract.                                                     |
| Generation preflight result                          |              2 | Current adapter evidence envelope.                                                            |
| Host-agent status                                    |              3 | Current producer; schema 2 remains an independent read-side status compatibility shape.       |
| Runtime-only phase projection JSON                   |              1 | Host, instance, and resource workflows only; logical service items are rejected at both ends. |
| Active manager transaction journal                   |              2 | Exact current lifecycle, data, command-plan, and projection authority; schema 1 is archived.  |

Command journals retain their complete ordered step plan. Resume requires that
the current command derive the same plan and use its explicitly persisted
publication mode. The three terminal schema-1 Zulip journals from the
controller, user-local, and repository-local stores live in sibling
`workflow-transaction-archive` locations, outside every active store; their
bytes remain audit evidence but the current manager neither deserializes nor
lists them. A later current-schema plan which lacks a new safety step fails
before effects rather than guessing that the omitted proof ran. Runtime-only and
Nix-native closeout share one plan constructor, so optional verification follows
plan capabilities instead of duplicated mode branches. That typed plan is
carried through deployment; a repository filename or extension never reselects
closeout behavior. Deployment-request coverage is validated before runtime
reconciliation or rollback publication.
