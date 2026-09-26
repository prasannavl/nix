# Dual-Projection Domains

Repository-authored operational intent has one Nix source and two derived
execution views:

1. the generation view is ordinary evaluated Nix consumed by NixOS and Nixbot;
2. the runtime view is a deterministic, fine-grained action plan consumed by a
   typed controller and local agents without requiring a deployment.

These are projections of one intent, not two desired-state stores. Runtime
journals retain observations, receipts, retries, leases, and private
capabilities; they never become a second authoring format.

## Domain registry

Every `config/<family>` declaration exposes the same
`{ stacks, projectionScopes, projections }` shape. `config/default.nix` declares
the families, repository-wide `shared` data, optional module registrations, and
projection-domain extensions. Generic composition lives under `lib/flake`:
`projection-domain-specifications.nix` owns the built-in fragment schemas,
`repository-config.nix` assembles the repository, and `repository-fold.nix`
validates and folds any compatible stack set. A domain specification owns:

- fragment validation and normalization;
- collision and authority checks across scopes;
- the folded repository contract;
- the deterministic generation and runtime views;
- a stable schema and compatibility adapter, when one is required.

A family may declare projection scopes only over stacks in that family. Stable
placement application is scope-local: changing a canonical scope does not
rewrite its sibling placement views, and an explicit placement scope is
materialized back into only its named stack placement.

Temporary phase effects use the same scope-local rule. Every deployable
placement has an explicit scope, so one environment cannot silently acquire
authority over a sibling placement view.

The repository fold only enumerates stacks, scopes, and registered domains. It
has no knowledge of repository paths, service moves, identities, or ingress.
Adding a domain must not add another bespoke top-level fold, publication
pipeline, or runtime configuration store. Every domain declares a validated
neutral fragment. Families omit unused domains; the generic fold supplies that
neutral value, so adding a domain does not create empty per-family boilerplate
and an omission cannot silently change semantics.

The fold passes each adapter only its validated `state.fragment`, explicit
dependency outputs, and shared context. Adapters must not close over the
unfolded repository declaration through a second channel. This makes the fold
the only composition boundary and keeps extension domains substitutable in
tests.

Families have two explicit construction modes. Data-driven families use
`configuration-family.nix`, including its stack-definition and registry
validation. Already-built stacks use the generic
`prebuilt-configuration-family.nix` adapter and must opt into that boundary
deliberately. A repository must not present raw imports and validated family
declarations as though they were the same construction path.

Public repository output exposes canonical facts rather than convenience
aliases. Domain names come from `attrNames projections`; canonical stack
ownership comes from `scopeOwners.<scopeName>`. The internal fold may retain
temporary declarations and stack-owner lookups, but callers receive only the
canonical `scopeOwners` and `fabrics` views, never a public `families` object.

A repository root that builds hosts always declares at least one family and one
stack. The family is required even when there is only one organization because
it partitions authored stacks and projection intent. A package-only or isolated
library consumer may still evaluate `lib/flake/default.nix` with no stacks. For
an existing simple repository such as Pvl, one prebuilt `pvl` family wraps the
existing `pvl` and `pvl-dev` stacks; shared repository data moves to
`repository.shared` while concrete stacks remain homogeneous.

Repository composition may declare one optional `defaultScope` for unqualified
operator lookup. Its stack is derived from the scope registry and exported as
`defaultSelection = { scope, stack; }`. Publication ownership remains a separate
`scopeOwners` fact. This default never supplies a missing `mkNixosSystem.stack`;
host and image construction remain explicit.

Service placements and service moves are the first domain adapters. Future
adapters may cover users and identities, identity attributes, ingress rate
limits, ingress routing, load balancing, or other fine-grained controls.

The shared modules have one direction of composition:

| Module                                 | Responsibility                                                           |
| -------------------------------------- | ------------------------------------------------------------------------ |
| `repository-config.nix`                | Validate the repository manifest and invoke the fold.                    |
| `repository-fold.nix`                  | Build family, scope, and stack ownership before evaluating projections.  |
| `projection-domain-specifications.nix` | Define fragment schemas and neutral values.                              |
| `projection-domain-fold.nix`           | Order adapters, thread declared context, and arbitrate claims and paths. |
| `projection-built-in-adapters.nix`     | Evaluate the service placement and move domains.                         |
| `projection-repository.nix`            | Define the typed repository layout and mutation rows.                    |
| `projection-domains.nix`               | Assemble built-ins and extensions and shape their public output.         |

Domain code may depend down this table. A lower layer must not import a higher
one to recover repository context, and a publisher consumes the evaluated
repository layout rather than duplicating it.

Every evaluated domain adapter returns the same schema-1 envelope:

- `contract`: its normalized repository intent;
- `generation`: ordinary Nix state consumed by builds and deployments;
- `runtime.plans`: typed `{ adapter, payload }` execution envelopes;
- `admission`: the validator and authority paths required before activation;
- `claims`: shared exact or path-prefix ownership claims;
- `repository`: exact paths and document kind owned by the adapter; and
- `next_context`: explicit outputs made available to dependent domains.

Dependencies declare the execution order: the fold topologically orders the
adapters from their `dependencies` lists (attribute-name order breaks ties) and
rejects a dependency cycle. Shared claim arbitration runs after every adapter
and rejects cross-domain conflicts even when two domains reuse the same logical
object ID. This is where an identity adapter and an ingress adapter, for
example, can safely coordinate ownership of a user attribute or route without
knowing each other's implementation.

The validated dependency order also owns runtime-plan publication order. An
attribute set is only a lookup index; flattening plans through attribute-name
order would violate the declared dependency contract.

Extension adapters are additive. A repository registers one
`projectionDomainExtensions.<name> = { specification; adapter; };` value in its
`config/default.nix`, so fragment validation and evaluated behavior cannot
drift. The service-placement and service-move domains are mandatory and cannot
be replaced. Each adapter sees immutable shared inputs plus only the outputs and
context of dependencies named in its `dependencies` list. Context keys are
globally single-writer. Extension names must not collide with a built-in domain.
An adapter always declares `schema_version` and its durable `contract`. The fold
supplies empty generation, runtime, admission, claim, repository-ownership, and
next-context views, so a domain declares only the capabilities it actually uses.
Overriding any view opts into that view's complete validated envelope.

Publisher-owned mutation paths must be safe relative paths and may not overlap
by path prefix across owners. The evaluated projection snapshot is the path
authority: its repository contract carries the flat ownership records and a
per-scope `{ owner, placement_directory, move_directory }` layout. Standard
placement paths are `config/<family>/placements/<scope>/<service>.nix`; move
paths remain `config/<family>/moves/<transaction>.nix`. Nix derives
`owned_paths` from that same layout and publishers consume it instead of
rebuilding either convention. Owned files need not already exist because
publication creates them.

Service-domain closeout authority is Nix-native. Runtime-only host, instance,
and resource workflows keep their generic receipts in
`data/phase-projection-closeouts.json`; those receipts are outside every family
and cannot express a service placement. Families therefore author only their
current placements and moves, with no compatibility input or second service
publication surface.

## Publication contract

A repository projection adapter provides a validated identity, exact owned
relative paths, a typed canonical Nix document, and an evaluator for its folded
contract. Shared publication machinery owns the invariant sequence:

1. require the expected clean repository revision;
2. record exact preimages for every owned path;
3. render and write complete documents;
4. stage exactly the owned paths so Git-backed flake evaluation sees them;
5. evaluate and validate the typed contract;
6. record exact postimages;
7. commit, publish or retain locally, and verify the resulting revision.

Recovery restores only an exact known manager-produced state. A changed path,
partial or foreign commit, advanced revision, or ambiguous index fails closed
without modifying human work. Domain adapters may select paths and contracts;
they may not reimplement Git ordering or recovery policy.

The publisher writes an exact index tree against the captured parent and
advances the checked-out branch with Git's old-value compare-and-swap. It
verifies the symbolic checkout and old branch value in the same reference
transaction where supported, and compensates the exact update on older Git if
the checkout changes in the remaining window. Remote transport pushes the
captured commit rather than mutable `HEAD`. Every dirty path must remain
publisher-owned before the update, and the checkout must be exactly clean before
transport. A concurrent ref advance or foreign untracked path therefore cannot
enter publication lineage.

Repository mutation paths are also evaluated authority. The operation-specific
`hostManager.serviceMoveRepositoryMutationsFor` resolver validates the scope,
owner, safe transaction identity, and declared services, then returns the move
and placement mutation rows for one proposed service move. A transaction need
not already exist in the evaluated contract: first publication necessarily
resolves its paths before adding that declaration. Rust checks every returned
identity and consumes the paths; it does not reconstruct the
`config/<family>/...` convention. The folded ownership envelope is checked again
after evaluation. Nix therefore owns repository layout, the projection owns
semantic identity, and the publisher binds both without a circular creation-time
lookup.

A single domain transaction may own several typed objects and several files.
That is still one publication: preimages, writes, staging, validation, commit,
and recovery cover the complete ordered path set. Adapters must not emulate a
multi-object transaction by publishing one object at a time. Runtime execution
may be a resumable saga when no distributed barrier exists, but its journal and
result remain transaction-wide and expose item-level evidence truthfully.

The Rust publisher follows the same split. A repository adapter selects and
renders complete owned-path mutations; one publication transaction performs
clean-base admission, planned preimage/postimage recovery, exact staging, commit
verification, and lineage advancement. It holds a distinct publication lease
across publication, deployment, evidence verification, and cleanup, because the
workflow journal lock is deliberately released while Nixbot runs. The lease is
non-blocking to avoid lock-order deadlocks, and every mutation still rechecks
the exact clean revision. A concurrent command therefore stops clearly before it
can reset or advance the shared publisher checkout.

Local publication also holds a lock keyed by the shared Git repository, not only
by a controller state directory. Two local controllers with different journals
therefore cannot interleave writes, staging, or commits in the same checkout.
The recovery marker records the exact publication commit. If a crash occurs
between the ref update and recording that identity, recovery may discover only
the unique immediate child with the planned tree. Later unrelated descendant
commits are accepted only when the publication commit remains in branch lineage
and none changes an owned path. Unrelated working-tree drift after the commit is
reported and preserved; it does not turn an already committed publication into a
permanent recovery wedge. Push/retain/verify transport is shared by move,
adoption, and cleanup publication instead of being copied into three subtly
different pipelines. Runtime-only JSON publication uses the same
planned-mutation transaction and may not write a path before the recovery marker
contains that path's exact postimage.

Repository kind is derived once from typed intent. Validation returns either a
valid Nix-native service identity, a non-service runtime-only kind, or an error.
A failed service identity check never changes the selected writer.

## Runtime and generation convergence

The runtime view names granular resources, desired states, effects, ordering,
and immutable evidence bindings. It acts immediately through the manager and
host agents. The generation view expresses the same selected state through
normal NixOS configuration.

Runtime plans are envelopes rather than an assumed service-move schema. The fold
has an explicit executor-capability registry keyed by adapter name and supported
plan schemas; an unregistered name or schema fails during evaluation. The
`host-phase-projection` adapter is the first executor. Host-manager consumes
this generic envelope and cross-checks it against the domain contract; it does
not reconstruct a second service-move runtime document. Unknown runtime adapter
names fail closed. A future identity, ingress, or load-balancing domain can use
the generic evaluation envelope immediately, but runtime execution requires a
corresponding shared typed executor before it may emit runtime plans.

The projection snapshot carries one role endpoint map. Each entry contains both
the host and canonical host resource; consumers must not transport a second
role-to-resource map. Runtime-only directory documents and Nix-native runtime
plans also enter one phase-projection validator and are applied once. Every
effect scope must name a service-capable stack in that exact application set;
unknown or non-service scopes fail before a document can be exposed or applied.

Nix is the sole derivation authority for move identities. It emits resource hold
epochs, activation attempt IDs, rollback requirements, and the complete runtime
plan. Rust publishes transition inputs, evaluates the result, binds the journal
to those exact projected identities, and submits only those identities to
agents. Empty coordination collections remain explicit in the transport so Rust
and Nix have one stable intent shape. Host-manager's public flake output also
includes the evaluated per-host resource catalog, allowing a multi-service
request to resolve every placement and endpoint resource in one Nix evaluation.

One generation-preflight dispatcher runs the executable validator registered by
each admission domain in a named `normal` or `rollback` mode. The registry binds
each validator to its exact authority paths. The dispatcher proves every
incoming file exists, records incoming and current digests, passes that evidence
to the adapter, and requires the adapter to return the exact same authority set.
Adapter name, result schema, and authority paths remain identical across a
retained domain. Authority-document schemas may evolve only when the current
document declares how each supported predecessor is normalized. The adapter must
validate both directions; a schema-number increase alone is insufficient. The
dispatcher validates registry evolution and every result envelope, then returns
combined per-domain checks and evidence. Resource-granular conflicts may be
safely isolated and reported as deferred; host conflicts remain host-atomic.

Admission compatibility is schema-aware. Historical schema-2 agent status is
validated against the fields schema 2 actually emitted; transaction and
projection identity become mandatory only in schema 3. Normal-mode admission
fails closed if an existing authority registry loses any member of its required
trio, while a genuinely absent registry remains a supported first deployment.
Every adapter must emit exactly one result document. Read-only `dry-activate`
runs the same generation-admission checks as activation, so it is a real
rehearsal without host mutation. Generation-admission rejections have a distinct
pre-switch marker and preserve the adapter's exit status, so Nixbot never
mistakes a safe rejection for an attempted activation. `boot` is rejected while
any projection admission domain is registered: its check would run only when the
boot target is scheduled, while runtime authority can change before the later
reboot. Operators must use `switch`, `test`, or `dry-activate` until a boot-time
boundary can revalidate the target generation.

Domain lifecycle is also admitted explicitly. Normal deployment may add a domain
but may not remove one or replace its named adapter. Rollback executes the
incoming adapter for retained domains and the current adapter for a domain that
exists only in the failed generation. This lets the adapter prove an older
generation's authority even when that generation predates the common registry.
First registration requires the predecessor to contain the complete authority
path set. The incoming dispatcher then runs the incoming adapter twice before
mutation: once for the forward transition and once against reversed evidence in
rollback mode. This admits a one-generation registry introduction only when the
domain itself can normalize the predecessor schema and prove both transitions.
The lower schema defines the semantic comparison surface for both directions:
newer-only domain entities are allowed only outside that surface, while every
entity represented by the predecessor remains protected. Equal-schema
transitions compare the complete domain. The dispatcher neither requires
byte-identical opaque documents nor infers their semantics.

Schema-specific normalization metadata is a rollout lease. The first generation
of a new schema declares the mappings needed for its real predecessor. After the
fleet has successfully entered that schema, a same-schema successor may retire
those mappings because equal-schema validation no longer consumes them. This
deliberately ends rollback to generations that require the retired mapping while
preserving strict rollback among retained same-schema generations. The adapter's
generic lower-schema support remains available for a future transition that
declares its own mappings.

Retirement leaves a durable registry tombstone: a compatibility generation first
converges the domain to empty or otherwise stable neutral authority, and later
generations retain that validator and authority shape. Registry removal is
unsupported because it would discard the rollback boundary. Adapter name, result
schema, and authority paths remain immutable while a domain is retained.
Authority-document evolution remains an adapter-owned, bidirectional
compatibility protocol.

Strict stateful rollback is an orchestrator contract. Nixbot and native
host-manager explicitly invoke generation admission in `rollback` mode so the
adapter can prove complete current authority and the exact deployed predecessor.
A current dispatcher may roll back to a pre-registry generation after that
proof. In that one case, and only when the target has neither a dispatcher nor
registry evidence, the orchestrator points the target's legacy placement check
at the target contract itself. This prevents the obsolete schema comparison from
rejecting an already-proved rollback while every unrelated target pre-switch
check still runs. Any target-generation interface evidence disables this
compatibility edge and must validate normally. A direct operator
`nixos-rebuild switch --rollback` has no controller transaction or predecessor
receipt to bind and therefore runs the generation pre-switch check in normal
mode. Treat that command as an emergency operator boundary, not as a proved
service-move rollback path.

A generic deployment may succeed with unrelated safely deferred resources. A
domain transaction may advance only after its own required active resources are
proven active, unheld, not deferred, and ready. Adoption and cleanup are
separate repository generations, and recovery authority is released only after
the clean generation passes this transaction-scoped proof. Both adoption and
cleanup proof require two stable samples bound to the exact deployed Git
revision, active-resource readiness, and exact held-and-stopped recovery-side
evidence. A successful deploy process alone is not closeout proof.

The deploy receipt must cover exactly every host whose projection resource is
required for adoption; verification fails with a coverage error before asking an
undeployed host for revision evidence. The stability interval between the two
postcondition samples is bounded configuration rather than a hard-coded sleep.
The real Nix evaluator tests adoption and rollback projection pairs for exact
generation stability, so rollback admission may safely require identical
projection digests across those transitions.

## Adding a domain

A new dual-projectable domain adds one scope fragment schema and one evaluated
adapter. It must declare:

1. canonical Nix intent and scope ownership;
2. normalized contract and dependency inputs;
3. generation output;
4. typed runtime plan adapter and payload;
5. common ownership claims;
6. exact repository-owned paths and renderer;
7. activation authority paths and validator; and
8. normal, rollback, and neutral-tombstone retirement admission behavior; and
9. revision-bound runtime postconditions.

It does not add a parallel JSON configuration, a new Git transaction, a new
stack fold, another generation-preflight entrypoint, or empty declarations in
families that do not use it. The adapter and its fragment schema enter through
the repository's `config/default.nix` as one
`projectionDomainExtensions.<name> = { specification; adapter; };` declaration;
no shared registry file changes.

## Compatibility boundary

Compatibility code is a one-way adapter at the edge. When a future transition
needs one, it normalizes an older schema into the current internal model before
validation. Current code does not branch throughout the evaluator on retired
shapes, and new repository intent is emitted only in the current format.

JSON is allowed as an ephemeral structured transport or evidence envelope. It is
not a committed parallel configuration language when Nix is the repository
authority.

Removing a stateful service classification is not a service move. The current
adapter rejects that transition even when a move declaration exists. A future
decommission domain must first establish explicit data-retirement evidence,
converge the service to a neutral authority state, and retain rollback proof;
until then operators keep the stable placement and disable the implementation
through its own supported lifecycle.
