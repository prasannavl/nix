# Nix-Native Service Moves

Nix is the sole repository-authored desired state for new logical service
migrations. Stable placement is a small role assignment in
`data/service-placements.nix`; each active transaction is one manager-owned Nix
declaration in `data/service-moves/`. Service implementation and migration
policy remain human-owned in the stack service capsule.

The declaration contains immutable identity, authority, scope, services,
endpoints, requested phase, generation, activation attempt, lease numbers,
lineage, and optional terminal decision. It does not contain generated host
jobs, manually assembled effects, observed success, or private capabilities. One
pure Nix evaluator validates the declaration and derives the exact phase
projection consumed by NixOS and host-manager. JSON is permitted only as the
ephemeral `nix eval --json` transport ABI.

Host-manager always executes the evaluated projection returned from the written
Nix declaration. `move`, `prepare`, and `run` commit before runtime mutation and
then reconcile granular host-agent resources directly; no deployment is needed.
The runtime journal owns observations, transfer verification, readiness,
activation results, and release capabilities.

Close has two repository states:

1. adoption changes the stable role and changes the move to `adopting-target` or
   `adopting-source`, preserving the exact terminal runtime projection and
   recovery lease;
2. cleanup removes the move after adoption deploy succeeds, deploys the clean
   stable state, then releases the inactive-side lease and archives the journal.

No activation-time controller unit may release a Nix-native recovery lease.
Activation precedes Nixbot health verification, so only the manager observing a
successful cleanup deployment may finalize the runtime transaction. A crash is
resumed from the retained runtime journal plus the clean evaluated placement;
temporary repository closeout metadata is not retained after cleanup.

Every generation installs a fleet-wide service-placement admission contract. The
pre-switch check compares the running and incoming contracts. A stateful role
change requires exactly one matching adoption declaration; removal of the
admission contract is rejected after its first deployed generation. The normal
desired-resource preflight then proves exact durable hold and activation
evidence. Unrelated services remain resource-granular; only an actual host
resource conflict is host-atomic.

A controller-authoritative nonterminal move authored directly in Nix may create
its runtime journal from the evaluated immutable intent when the deployed
reconciler first runs. This bootstrap still passes normal overlap and host-agent
admission. An adopting declaration may never bootstrap a journal: terminal
placement requires an existing journal containing the exact successful run or
rollback evidence.

Legacy `data/phase-projections/*.json` and schema-1 placement documents are
read-only compatibility authority for existing transactions and resource
projections. New service transactions must never enter that path.
