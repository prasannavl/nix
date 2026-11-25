# Abird source commit ledger

Range: `46c3b6298..39c711a7a`, with both merge parents. Order is
`git log --reverse` on that range, not author-date filtering. **Clean** means
the substantive unit was ported without a policy adaptation, not that the commit
SHA was cherry-picked. **Adopted** identifies adapted or partial units.
**Skipped** means no independent change to apply. “This pass” includes finishing
a previously partial port.

## Commits 1–29

**1. `6e7ab688b` — feat(review): define exact review contracts.** Skipped.
ReviewPacket hashes, exact approval subject/consumption claim, publication
stages and preview recipe validators/tests belong to abird-protocol; no such
crate or 4g plan here.

**2. `f41a67007` — feat(review): assemble scoped review packets.** Skipped.
Agent review_packets/operations tables, owner-scoped create/list/get, paged
inventories/checks/diff and idempotent assembly receipts require the private
repository store; no local controller.

**3. `d7ce52e48` — feat(review): bind consent to exact packets.** Skipped.
Source-observation refresh, packet-generation decisions, once-only claim
consumption/audit and web approval routing form one agent/protocol/web
transaction; no corresponding local approval engine.

**4. `067d7e991` — feat(review): capture protected PNG previews.** Skipped.
Evaluator captures recipe-bound PNGs; supervisor checks chunks/CRC/decoded
dimensions and protocol validates the downloaded pixels. Root Cargo png pin/lock
changes serve that private crate; calculator host recipe and VM fixtures have no
consumer here.

**5. `6d90db8ec` — feat(review): deliver one-use PNG downloads.** Skipped.
Session/epoch/expiry-bound read grants, single redemption and reader-slot
lifetime, no-store PNG route and Tauri save-to-selected-file path are specific
to agent/app/web; not the local Pi Web service.

**6. `1a8380bba` — feat(review): add shared review and revision flow.** Skipped.
Revision feedback reserves one conversation send against the exact packet; web
review panel shares paged evidence, metadata edits, approve/revise and PNG
download. Schema and BlobPropertyBag feature serve absent products.

**7. `d48bd38c9` — feat(review): close recovery and privacy controls.** Skipped.
Erase packet text/feedback while preserving receipt identity; fence
restore/authority rotation, expose review status/doctor/settings and default-off
policy in agent module. Gondor enablement and operations playbook are private,
not shared module defaults.

**8. `c5557fddd` — fix(review): keep expiry timestamps in UTC.** Skipped. Packet
assembler formats expires_at with millisecond precision and UTC Z rather than
+00:00 for RecordedAt; no local packet assembler.

**9. `cae499f91` — fix(repository): accept complete paged preimages.** Skipped.
Native writer accepts contiguous same-digest reads through !has_more EOF even
when a later page is marked truncated; gap/EOF tests target the agent
patch-preimage proof, not generic Git tooling.

**10. `dc052c700` — test(desktop): update capability expectation.** Skipped.
Only the abird-app desktop-service VM expectation gains “conversation context
preparation”; no local desktop service advertises these capabilities.

**11. `dbeebd202` — fix(ui): refresh retained review readiness.** Skipped. Web
card now observes the current workflow/object/generation view without resetting
metadata drafts when availability changes. No local retained review-card
component.

**12. `b7fcf0640` — test(workflow): declare source inspection intent.** Skipped.
Fake provider now requests source evidence even for
workflow_repository_clarification_repair. This is an abird-agent workflow test
fixture, not provider policy for Nix consumers.

**13. `520e6b1b5` — test(nix): cover identity name selection.** Adopted · this
pass. Restored the installed/absent/same-name regression on the actual bound
nats-wrecking-ball client module, including the synthetic age.secrets evaluation
cycle. Updated the selection/binding guidance. The name-only binding check alone
did not cover this. No obsolete lib/flake constructor, private deployment or
rebase receipt.

**14. `56e952ea9` — test(ai): update agent calculator fixture.** Skipped. Only
the expected calculator repository commit in tests/abird/ai-agent-binding
changes (a8b6492f to 4f299a95); no calculator binding in
lib/tests/repository/pvl. Not a shared AI resolver change.

**15. `c8890dd4b` — fix(provider): try alternate public addresses.** Skipped.
Codex connector cycles through vetted public SocketAddrs with a fresh egress
check and 3s timeout per attempt; retry/denial tests and restart instructions
concern the private provider broker, not fleet DNS.

**16. `ebd39719b` — fix(workflow): retain candidate diff evidence.** Skipped.
Captures bounded cumulative original-source and relative workflow-input diffs in
immutable task/memory input, including empty relative diff for inherited parent
candidates. No local agent cell, repository writer or task protocol.

**17. `d30807bb0` — fix(workflow): validate captured diff baselines.** Skipped.
Validates retained task diffs against their immutable baseline instead of
regenerating from retained files; test temporarily removes the file and
separately rejects a wrong compared_to. Abird workflow store only.

**18. `8ab5ae0a9` — fix(ui): separate review from workflow wait.** Skipped. Web
detail validator excludes RepositoryReview subjects from pending
executor-approval count/lookup; completed runs can retain a pending review
without becoming waits. No local workflow UI.

**19. `8d58962aa` — docs(plan): record 4g private qualification.** Skipped.
Event 0028 records private restart preservation of two candidates, 24 evidence
payloads and one-use preview state without replay, plus completed-workflow UI
qualification; not destination test evidence.

**20. `850c25cf1` — style(plan): format 4g qualification record.** Skipped. Only
reflows event 0028; non-whitespace word diff is empty. Neither the private
qualification record nor its formatting belongs here.

**21. `333cab225` — docs(plan): reconcile 4g release.** Skipped. Reconciles
release playbook/work log: installed download/consent checks, scoped cutover
authority, current-format vs abandoned epoch-14 wording and master-rebase
receipts. No runtime delta or transferable deployment authority.

**22. `def844cff` — feat(backup): prepare version 1 recovery.** Skipped.
Prepares Gondor's v1 recovery declarations alongside epoch 13; managed-backup VM
guards predecessor status against foreign v1 operations. No local abird-agent
backup service; secret/recovery material classified by path only, not inspected
or copied.

**23. `6073978ff` — fix(evaluation): advance policy generation.** Skipped.
Single hosts/common/abird-evaluation.nix field advances generation 1 to 2.
“common” is shared among source hosts, not a portable Nix option; local hosts do
not consume that policy.

**24. `8028fa36f` — docs(plan): record release qualification.** Skipped. Event
0035 records rebuilt current-master release, VM/readiness gates and the
remaining private reset qualification. No shared test implementation or local
deployment claim.

**25. `6efefbd83` — docs(plan): record reset rehearsal.** Skipped. Event 0036
and resume pointer record exact controller reset inventory/rehearsal, not a
reusable reset tool. No corresponding local controller or authorization; private
inventory not imported.

**26. `da23737a7` — fix(evaluation): align calculator pin.** Skipped. Repins
calculator commit/tree, advances repository policy 5→6 and evaluator 2→3, and
asserts manifest platform_input matches Z's locked nixpkgs in Gondor. These are
project/host facts, not a root flake input update.

**27. `aa5604a18` — fix(workflow): validate historical actions.** Skipped. Agent
reload accepts historically valid action sets (including forms without
RetryStep) while live stale repository authority still removes Resume.
Store/repository regression has no local workflow DB counterpart.

**28. `4e4e37364` — docs(plan): record 4g release proof.** Skipped. 4g plan/TODO
and events 0037–38 distinguish production v1 cutover/recovery from the epoch-13
disposal rehearsal. These are Abird-owned receipts, not permissions to
reset/delete local state.

**29. `d4628d057` — refactor(nix): unify language toolchain resolution.**
Adopted · this pass. Shared Go/Node/Deno/Python resolvers were integrated by
7d6630622/01dfd31df. Now the updater honors the go.mod toolchain directive,
verifies an exact pinned Go, and probes the registered Tailscale package with
candidate metadata. Updated the package note. Skip interim resolver aliases and
direct package import without its required ab argument.

## Commits 30–58

**30. `f327dff4e` — refactor(forgejo): reuse canonical public URL.** Skipped.
Only abird-corp's FORGEJO__server__ROOT_URL reuses its existing forgejoUrl
binding instead of a second registry lookup. Local ab/services/forgejo is a
helper, not that host deployment (c21c683be).

**31. `ba433bf6c` — style(docs): normalize upgrade notes.** Skipped. Formatting
of Abird Forgejo 17.0.1 and Zulip/RabbitMQ upgrade notes only; earlier host-pin
decisions explicitly excluded in c21c683be. No shared migration or image change.

**32. `1a7b2067f` — chore(backup): retire epoch 13.** Skipped. Retires the
source's epoch-13 declarations plus five recovery/service ciphertext paths; v1
is not a local migration. Plan/TODO and disposal receipt remain with Abird.
Deletions assessed by path only.

**33. `f0baba8dd` — docs(4g): record cleanup deployment.** Skipped. Event 0040
closes the epoch-13 cleanup deployment after 1a7b2067f; absence of old
status/material on that deployment is not local proof. No additional removal or
deployment code.

**34. `62693068d` — Merge remote-tracking branch 'origin/master' into
ai/phase4g-v1-backup.** Skipped. Parents carried the registry/identity checks
and the already-receipted fleet, Excalidash, NVIDIA and Tailscale changes. Only
overlapping test index merged automatically. See 520e6b1b5 for the restored
regression. No novel merge hunk to replay; no private deployment or 4g state.

**35. `fefddb743` — docs(4g): record master reconciliation.** Skipped. Event
0041 records reconciling the cleanup deployment with newer master and checking
current readiness; confirms the test-index overlap merged automatically. No new
merge resolution or shared code.

**36. `9865f00f8` — docs(4g): record master publication.** Skipped. Event
0042/TODO records tested 4g master publication after reconciliation. A
remote-master advance and private suite results do not establish destination
validation.

**37. `6dbc57741` — refactor(nix): standardize toolchain resolver contracts.**
Adopted · this pass. Five-resolver contract, Rust/Crane context and
language-toolchain test already landed in 7d6630622/01dfd31df. Finished the
Tailscale resolver path and documented the current bound contract. No obsolete
standalone toolchain APIs, Abird product acceptance or replacement of PVL Rust
qualification.

**38. `05fb02f6d` — refactor(nix): centralize package composition.** Adopted ·
this pass. Shared project/package scope and the Go/Node/Python examples already
landed. Made the three Pi leaves injection-only and passed the composed
llmug-hello assets derivation directly to Wrangler. Updated the packaging guide.
No Abird agent leaf, Gap3 nginx caller, intermediate composition API or nested
asset build.

**39. `43b49ceb7` — Merge remote-tracking branch 'origin/master'.** Skipped.
Parent-carried shared units only: 520e6b1b5/62693068d identity and cache intent;
6dbc57741/05fb02f6d account for toolchains/composition. From merge base
ba433bf6c the two parents changed disjoint path sets (39 vs 153); combined diff
empty. No new resolution. First-parent 4g product/Cargo/host/backup delta is not
a second port.

**40. `327868dde` — docs(plan): design Abird Nix context boundaries.** Adopted ·
already present. Three contexts (pkgs, bound ab, deployment stack), injected
leaves, one package-set fixed point and extraction boundary realized in
7d6630622; canonical component-boundary doc and lib integration layout updated
by 01dfd31df. Do not import the four Z planning/decision files or freeze the
initial five-component target: current architecture adds ab/system and tests
extracted owners. This commit itself is design-only.

**41. `2e1c0ad94` — fix(workflow): preserve bound source state.** Skipped. Bound
repository workflows keep exact source across deployment-only workspace
revision/path changes; unbound workflows still fence those changes. Linked
transcript actions bind workflow/run/generation, with browser regression. No
local agent or web surface.

**42. `015ce9a2b` — test(web): await provider event stream.** Skipped. One
Playwright poll waits for testEventResponse before cloud settings test emits the
provider event; not a provider implementation or shared test-runner change.

**43. `235db78a1` — docs(4g): record repository boundary fix.** Skipped. Event
0043 and reuse note record a false repository_changed after deployment with
unchanged calculator source, then qualification of 2e1c0ad94. No generic Git or
host-manager corrective code.

**44. `dd2453b07` — chore(agent): allow calculator README edits.** Skipped. Adds
README.md to calculator manifest and writable-path admission, repins
commit/tree, raises project generation 6→7 and evaluation 3→4. No global agent
permission or local calculator enrollment.

**45. `ba1c098d4` — docs(plan): add desktop review cleanup.** Skipped. Opens
private desktop-review plan/queue around exact candidate follow-ups, blocker
visibility and release acceptance. No widget, service or shared test implemented
in this commit.

**46. `b01239f75` — fix(agent): bind candidate follow-ups exactly.** Skipped.
Dispatch rejects a missing/substituted/unselected parent, not just a mismatching
digest. Discuss Candidate selects that resource and focuses the conversation
composer; agent/web browser tests require absent product APIs.

**47. `1f1ef82fc` — fix(agent): retain unchanged candidates.** Skipped. Review
assembly accepts an inherited Candidate input on a no-change run but never
treats raw Source as a candidate; retries deduplicate the same object.
Unchanged-result labels/tests target private store/web.

**48. `c90a0f5ad` — fix(review): report contextual blockages.** Skipped. Typed
bounded ReviewBlockage distinguishes missing inventories/checks/preview from
failed evaluation, with ranked deduplication and check details propagated
through state/consumption/UI. Private packet wire and store only.

**49. `5c39c4113` — fix(review): explain review blockers.** Skipped.
PublicationUnavailable alone no longer prevents local review; client presents
reason-specific actionable evidence/evaluation messages. Agent decisions and web
tests concern local-vs-publication consent in the unshipped product.

**50. `bd18e3b97` — fix(web): render literal diffs safely.** Skipped.
Packet/digest/offset-checked pages escape opaque bytes; shared web GitDiff text
component classifies metadata/hunks/+/- lines and leaves page fragments neutral.
Browser assertions cover literal rendering; no local copy of this web UI.

**51. `a870297a6` — docs(plan): record desktop review release.** Skipped. Events
0003–04 document candidate/blocked-review fixes, browser/VM checks and release
against retained paused workflows. Source desktop acceptance/release proof is
not a local fixture or gate.

**52. `5451b2856` — fix(review): clarify paused check failures.** Skipped.
Paused runs with failed checks prefer settled check details over
work-in-progress; StepFailed safe message points to retained step/check
evidence. Agent/protocol/web behavior only, not fleet post-switch health.

**53. `87a98059a` — fix(agent): update calculator checker.** Skipped. Repins
calculator checker commit/tree to target the submit control, raises project
policy 7→8 and evaluator 4→5. Only source host/project pins changed; not a
shared browser checker.

**54. `f85f48e99` — fix(deploy): confirm settled health.** Clean · already
present. 7d6630622 already ported stable-health confirmation: after Settling
require a second healthy sample within the original readiness deadline; preserve
ignored failures, fail if too late. Both fleet health/host test changes
retained; architecture-convergence.md records exact hunk transfer. None; keep
independent destination fleet_host_runtime tests, not a whole-file replacement.

**55. `b3050ec78` — test(deploy): hold replaced Git profile.** Clean · already
present. 7d6630622 already ported capture.rs regression: open original Git
profile before unlink/recreate, drop handle after rejection assertion to prevent
inode reuse. capture.rs matches the source commit. None; test-only. Distinct
from the later lock-transfer lifetime fix 81cbadde8.

**56. `778847980` — docs(plan): record review corrections.** Skipped. Shared
verifier and replaced-inode test already recorded in 7d6630622
(f85f48e99/b3050ec78); no new code in this commit. Event 0005 records
paused-check UI, calculator selector/policy generations and fleet health
qualification on Abird. Do not copy deployment/desktop acceptance claims.

**57. `d5506aee8` — docs(plan): define candidate formatting.** Skipped.
Plan/queue pairs a fixed formatter and read-only check, requires pre-seal
convergence and independent evaluation of the immutable candidate; source
execution authority only, not this repo's formatter configuration.

**58. `f3bf11233` — feat(protocol): declare candidate formatter.** Skipped.
Private protocol admits one optional fixed writable fix_command paired to check
targets; binds operator qualification to commit/tree/catalogue/check/toolchain
digests and records draft→output normalization provenance on candidates. Agent
constructors/tests updated, no shared Nix formatter or local protocol consumer.

## Commits 59–87

**59. `a2ca76552` — feat(agent): contain candidate formatting.** Skipped.
Contained Ruff fix/check in the repository image; bounded inventory, path/mode
checks and normalization proof belong to the unshipped abird-agent writer.

**60. `5ea5fd2e6` — feat(agent): normalize before candidate seal.** Skipped.
Freeze the normalizer recipe and verify its proof before sealing/publishing a
candidate; private agent store, native writer and workflow refs, not
host-manager.

**61. `c48cb11e4` — feat(web): present formatter outcomes.** Skipped. Classify
candidate-format failures across writer/orchestrator/protocol and show
changed-path counts in workflow cards; neither product endpoint ships here.

**62. `d5807f344` — feat(agent): enable calculator formatting.** Skipped.
Calculator fixer/check declaration, manifest and host evaluation qualification;
Abird project, image and admitted generations, not shared Ruff policy.

**63. `3fd9fd8c3` — fix(agent): bound formatter proof size.** Skipped. Box the
optional NormalizationProof in the agent repository outcome and construct it in
the worktree writer; no such local type.

**64. `325f6cf85` — docs(release): record formatter rollout.** Skipped.
Restricted-evaluation playbook and formatter implementation/deployment evidence
describe the Abird calculator rollout; not local release evidence.

**65. `7ddefbd27` — fix(workflow): own review finalization.** Skipped. Make
repository review a controller postcondition, not model-authored work, with
agent regression; also close formatter plan/open conversation-unification plan.
Both are product-owned.

**66. `b25e5f646` — fix(review): scope request state.** Skipped. Key web review
busy/status, pending retry and delayed responses by workflow; review UI
regression and plan event have no local web product.

**67. `dbf3e935f` — feat(chat): inline workflow history.** Skipped. Inline
linked workflow history in chat, omit duplicate prose, place current action
last; conversation/shell UI and rollout note are Abird-only.

**68. `99d5790fc` — feat(chat): inherit candidate context.** Skipped. Carry
candidate context into composer follow-ups: sole active or newest finished, no
ambiguous selection; agent conversation store, web targets/UI and plan event are
private.

**69. `eb77265a4` — fix(ui): disclose evidence immediately.** Skipped. Open
evidence disclosure immediately, load its body on expansion and expose
package/preview metadata; private workflow web UI and plan evidence.

**70. `b172c4535` — fix(ui): clean conversation controls.** Skipped. Clean
composer/repository picker, workspace selection and CSS; bind usage to the
authenticated repository scope. Web product and its plan only.

**71. `e6387fabf` — test(desktop): follow inline workflows.** Skipped. Rewrite
installed desktop-service acceptance to follow the newest inline workflow card,
its state and linked answer; no abird-app desktop test here.

**72. `df737fabf` — docs(plan): archive desktop reviews.** Skipped. Archive
conversation-unification and desktop-review plans, qualification/acceptance
events and queue entries; Z planning history only.

**73. `f2c99578b` — docs(plan): add context read recovery.** Skipped. Open
context-read failure recovery plan, queue item, baseline, review and execution
authority; not a code or shared test change.

**74. `86aad8438` — docs(plan): adopt alpha reset policy.** Skipped. Choose
alpha-v1 reset instead of compatibility readers and record closeout policy for
context recovery; product release decision, not host-manager policy.

**75. `f2970bbe0` — test(agent): privatize backup fixture.** Skipped. Set mode
0700 on the recovery temp directory in an abird-agent workflow-context test; no
equivalent local fixture or payload needed.

**76. `15ebb62b9` — fix(agent): attach context to searches.** Skipped. Attach
bounded, validated source passages to search observations; deduplicate/clip
reads, charge evidence and avoid redundant provider reads. Private cell, broker
and workflow schema.

**77. `a29eabd24` — fix(workflow): preserve failure causes.** Skipped. Project
durable provider/repair, source, authority and budget causes into workflow stop
reasons rather than generic StepFailed; private workflow store.

**78. `26cad05f7` — fix(workflow): retry failures from chat.** Skipped. Add
typed RetryWorkflow from chat, controller acknowledgement, exact
conversation/workflow source binding and matched Codex schema; no agent/protocol
consumer here.

**79. `cf26b84f9` — fix(ui): surface actionable failures.** Skipped. Project
bounded failed-step cause and one actionable retry into agency/protocol and
conversation/review/workflow views; Abird-only server and UI.

**80. `86d196185` — docs(plan): record implementation review.** Skipped. Record
code review and local qualification of search passages, stop causes, chat retry
and UI in the recovery plan; no new implementation.

**81. `802088aae` — docs(plan): record release qualification.** Skipped. Record
matched broker/cell deployment and narrow reset of obsolete search observations;
Abird recovery qualification, not a shared reset procedure.

**82. `ae8d511fc` — docs(plan): archive context read recovery.** Skipped.
Archive recovery plan and release/closeout events; remove its queue/TODO entry.
Z publication history only.

**83. `b763ea32e` — docs(plans): start workflow self-repair.** Skipped. Record
prior desktop acceptance and open/authorize workflow-action and candidate
self-repair work; private plan lifecycle.

**84. `d39e861a9` — fix(web): derive workflow actions from live state.**
Skipped. Derive web failure guidance from current actions, with terminal
cancellation overriding earlier failed steps; private workflow presentation and
tests.

**85. `dbff49360` — feat(conversation): cancel selected workflow.** Skipped.
Cancel only the selected workflow from conversation; publish available actions,
authorize/store the mutation and cover exact targeting. Private
agent/Codex/protocol contract.

**86. `05e320f4a` — feat(repository): return typed rejection.** Skipped. Return
typed apply/formatter rejection with bounded feedback; persist/replay rejection
or acceptance through repository writer, store and protocol. Private candidate
API.

**87. `2579bfd43` — fix(agent): repair rejected candidate drafts.** Skipped.
Feed the matching patch rejection back into the accounted tool loop to repair a
candidate draft; private agent orchestration/writer and regression.

## Commits 88–116

**88. `f26c3633c` — fix(agent): preserve candidate failure causes.** Skipped.
Carry exact attempt-bound candidate failure detail/code through store, agency,
protocol and web failure guidance; no local producer or UI.

**89. `74ed92759` — test(conversation): refresh cancel schema fixture.**
Skipped. Refresh Codex runtime schema fixture for cancel_workflow and
acknowledgement; fixture belongs to the private agent protocol.

**90. `5775f46d4` — fix(backup): pin alpha configuration to v1.** Skipped. Pin
the private agent module's alpha backup configuration to v1; matching recovery
playbook/reset decision and self-repair plan are Z-owned. No backup payload
required.

**91. `022b3a769` — docs(plans): archive workflow self-repair.** Skipped.
Archive workflow self-repair plan, move release/publication evidence to done,
remove queue/TODO entry; Z plan state only.

**92. `f3056aec3` — docs(plans): correct workflow test count.** Skipped. Correct
agent binary/integration suite counts in archived release evidence (5 and 9);
not local test evidence.

**93. `5035c17a0` — fix(workflow): canonicalize goal objective.** Skipped.
Canonicalize raw chat request whitespace for the workflow goal objective, with
store regression; private agent conversation admission.

**94. `b19f5eeb0` — fix(workflow): prevent late control overflow.** Skipped.
Preflight the 64 KiB control envelope before approval, keep overflow revisable,
align text-first web feedback and browser test; private agent/web workflow.

**95. `fc1a40ee6` — refactor(nix)!: split reusable ab components.** Adopted ·
this pass. The six-component split and repository callers landed in
7d6630622/01dfd31df. This pass repairs Cloudflare root/helper/asset paths, maps
portable synthetic external-consumer checks into the local check registry, and
updates active guides. Guard the relocated exporter against false-success
encryption of an unmanaged output. No intermediate nix/ tree, private
products/topology, private deployment receipts, or deletion of PVL qualification
policy.

**96. `8707466cc` — fix(ab): unify package scopes and dependencies.** Adopted ·
this pass. The package scope, explicit overrides, publication collisions,
rebinding and child contracts landed in 7d6630622. Portable extraction coverage
is included in this pass (see the qualification unit). Do not adopt the product
manifest, private leaf constructors or source-only directory conventions.

**97. `0226ed5f0` — fix(stack): preserve owned assembly namespaces.** Adopted ·
already present. 7d6630622: common registry/family stack finalizer, owned
topology.placements/network/infra joins, collision rejection, role remapping and
assembly regression/check wiring. No outstanding shared unit; destination
topology values are not replaced.

**98. `9268c6511` — fix(services): make adapters extractable.** Adopted · this
pass. Core helper and phase-projection injection, Kache and the portable
adapters were already in 7d6630622. Include the portable external-consumer
checks on the local registry. Skip Z service instances, private proxy/mail/auth
configuration and Gondor wiring.

**99. `84a47066a` — feat(system): separate modules from repo policy.** Adopted ·
already present. 7d6630622: optional desktop/network/hardware/security modules,
native Nvidia option, mkWmModule profile, resolved Nix policy, explicit unknown
installer rejection; shared extraction/policy tests. Keep local driver,
trust/order, GC/build settings (16/0/16), state versions and host profiles; skip
private agent module caller and Z identity tests.

**100. `345d8bbef` — docs: record verified cross-repo convergence.** Adopted ·
already present. 7d6630622: boundary design and cross-sync playbook,
packageScope/withDeps guidance, architecture-convergence.md and checks manifest;
01dfd31df updates final lib/ naming. Retain destination Nix conventions,
integration evidence and policy facts; Z reviews are historical, not fresh Pvl
validation.

**101. `8bfb8c7cb` — docs: note concurrent Nix input commit.** Adopted · already
present. 7d6630622: convergence note/manifest already preserve concurrent Pvl
Dotlink commit 673d750c5 and identify df659590b as the earlier review base. Do
not reapply the historical staged-worktree status or roll back later local input
pins.

**102. `7a4bf7303` — style: format migrated documentation.** Adopted · already
present. 7d6630622: three formatted Rust READMEs (packaging/rust, mirror,
qualification) included; post-format ab tree d5bf0fbf4 matches exactly at
integration. Other reflow follows Z handoffs, plans, product docs or divergent
guides; format local guides after #95/#109 semantic path fixes rather than
transplant 78 files.

**103. `63484ac44` — docs(agent): plan workflow finalization.** Skipped. Open
workflow finalization/actions plan, verified findings, correctness review and
execution authority; private agent plan, no shared code.

**104. `616374d70` — fix(agent): finalize workflows safely.** Skipped. Canonical
required checks, receipt-based finalization, invalid-control handling and
stale-safe intent-only retry/resume/revise/cancel; desktop
targeting/tests/schema/notes all belong to Abird workflow products.

**105. `28ba1b025` — docs(agent): archive workflow finalization.** Skipped.
Archive workflow-finalization plan and signed-release evidence, retire
queue/TODO entry; no local release to record.

**106. `cf0799135` — docs(git): require pre-deploy rebase.** Skipped. Require
fetch/rebase of unpublished changes before freeze and revalidate/redeploy if
master advances; Z local-review-and-deployment playbook has no counterpart. Pvl
deployment/rewrite authority stays local.

**107. `8cd7270d1` — style: format publication record.** Skipped. Reflow
archived workflow release/publication test record only; private historical
evidence.

**108. `5e0f073f7` — test(deploy): isolate lock-transfer lifetime.** Clean ·
already present. 81cbadde8: isolate descriptor-transfer exclusion assertions in
a subprocess. The service.rs change and lock-transfer note match. No production
lock change or omitted unit.

**109. `53eb54739` — refactor(repo)!: consolidate integration in lib.** Adopted
· this pass. 01dfd31df already moved integration and overlays under lib/. Fixed
the child-ref test separator and updated affected guides for the final layout
and repository binder. No compatibility roots or Abird overlay/host inventory.
Retain PVL inputs, patched-Cargo lane and policies.

**110. `6adbe871e` — chore: ignore Ruff caches and local Kilo files.** Adopted ·
already present. 2c984b37b: .ruff_cache/ ignored; shared .gitignore header
matches including .kilo/. Z-only tracked .kilo/agents/data.md deletion and
negation cleanup; no tracked Pvl Kilo data or exception to remove.

**111. `8be9d73c6` — fix(gondor): include lib in agent workspace.** Skipped.
Update Gondor's private agent workspace fileset from nix/ to lib/ and force the
actual snapshot in ai-agent-binding; host note/test have no local agent
workspace owner.

**112. `532d3a1c6` — fix(health): diagnose unsettled service failures.** Clean ·
this pass. Ported bounded unsettled-unit diagnostics, baseline timer filtering,
recent error selection and regressions. Final three touched files match
upstream. None. Stable-health confirmation was already local and is a distinct
change.

**113. `ce1de437c` — fix(gondor): retain admitted calculator policy.** Skipped.
Retain Gondor calculator's already-admitted generation-10 main
declaration/manifest and validate its binding; host note plus Z identity test,
no local calculator policy.

**114. `6ad84ce5f` — docs(plan): open workflow repair.** Skipped. Record
finalization human acceptance and open workflow repair, approval UI and
calculator-main plan with baseline/review; private product planning only.

**115. `9b7345def` — fix(web): keep workflow action current.** Skipped. Bind
action/status to current workflow/run; show live progress, exact per-check
outcomes and repair limit in chat/workflow UI. No local abird-web.

**116. `088e75814` — fix(agent): enable bounded check repair.** Skipped. Derive
repair permission/budget for required checks with a mutation predecessor; reject
model-supplied repair flag, type check selection and test
controller/evidence/delivery rules. Z agent/protocol only.

## Commits 117–145

**117. `0dccc09e6` — chore(agent): repin calculator main.** Skipped. Calculator
maintenance playbook makes main the sole admitted/published fixture branch; no
calculator fixture in Pvl. No pin file in this commit.

**118. `d57286aa0` — test(agent): refresh workflow schema.** Skipped. Adds
nullable repair_prohibition to the Codex workflow schema fixture; Pvl does not
ship abird-agent or its schema suite.

**119. `5aa654112` — style(docs): format calculator playbook.** Skipped. Reflows
the checked-ui PNG paragraph in the calculator playbook only; no Pvl
counterpart.

**120. `9ea2d9f6f` — docs(plan): record local qualification.** Skipped.
Workflow/UI-main event 0003 records composer, approval, bounded repair and
calculator local qualification; Abird plan evidence, not shared code.

**121. `4832ffdc8` — fix(agent): follow Nix lib move.** Skipped. Plan/TODO and
event 0004 record calculator main publication and the workspace fileset
nix/→lib/ fix after rebase. Despite subject, no fileset, flake or package edit
here.

**122. `390b52e39` — docs(plan): record live deployment.** Skipped. Event 0005
and work index record Gondor deployment, application-state reset,
requalification and remaining acceptance gate; not a Pvl rollout.

**123. `9f4fa74ff` — docs(plan): record combined deployment.** Skipped. Event
0006 records combined rollout after absorbing the generation-10 calculator
declaration and settled-health changes; neither implementation is in this
commit.

**124. `e6eb2c19a` — docs(plan): start conversation recovery.** Skipped.
Archives accepted workflow/UI-main work; opens Abird admission recovery with
stale-pending, malformed response, attachment UI and authorization events. No
shared plan action.

**125. `b92a42330` — fix(abird): recover conversation admission.** Skipped.
Agent/store pre-admission receipts, replay/restart and patch repair; protocol,
conversation/workflow UI, browser tests and qualification belong to the absent
app. Table-based receipt superseded by ef5af33e7.

**126. `ef5af33e7` — fix(abird): preserve live admission state.** Skipped. Moves
submission receipts into existing durable events to preserve deployed v1 schema;
audit/protocol/UI filtering, schema incident and successor record all
app-specific. Fleet shallow-health observation is not a manager patch.

**127. `b471e15ca` — docs(plan): record live qualification.** Skipped. Event
0009 records schema-safe Gondor deployment, live health and no reset/migration;
Abird qualification only.

**128. `ba3382d1d` — style(plan): format qualification record.** Skipped.
Reflows admission plan and event 0009's schema/qualification text; no change to
behavior or deployment.

**129. `ef90b2222` — docs(plan): close conversation recovery.** Skipped.
Publishes/closes admission recovery: queue/TODO cleanup, archive, done events
and closeout; Pvl does not own this work history.

**130. `49189bee6` — fix(abird): stabilize editing workflows.** Skipped. One
accounted repair for invalid turns, retained replay, startup fetch/writer
scratch reconciliation, app/VM tests and release guidance; controller
state/capacity playbook edits are not generic fleet procedures.

**131. `daea66764` — docs(plans): format qualification record.** Skipped.
Formatting of editing-stability event 0005, including whole-flake host-memory
limit vs passing bounded gates; not Pvl evidence.

**132. `cad9b9622` — docs(plans): close editing stability work.** Skipped.
Closes editing-stability plan, archives work/removes queue entry and records
Gondor release/live orphan cleanup. No shared implementation.

**133. `bfdc440a1` — feat(nginx): allow per-vhost access log opt-out.** Adopted
· this pass. Ported both shared files exactly: boolean opt-out on the normalized
root proxy, inherited logging by default and per-vhost rendering. Added a local
rendering regression. The private proxy adapter and Corp vhost have no PVL
counterpart. No local vhost opted out.

**134. `a4f0b10f5` — feat(corp): add Vaultwarden with Kanidm SSO.** Skipped.
Pvl-x2 already runs its own containerized Vaultwarden (no shared change here).
Native Corp Vaultwarden, Kanidm OIDC, network/ingress/DNS, secret references,
identity tests and rollout note are Abird policy. Do not import Corp
SSO/firewall or treat Pvl as opted out of logging.

**135. `449f593fb` — style(corp): group Vaultwarden network settings.** Skipped.
Regroups issuer routing/firewall/nftables under networking in the native Corp
Vaultwarden host module; no reusable module or Pvl policy change.

**136. `52ae7710a` — docs(plan): start workflow repair.** Skipped. Starts Abird
specification/control plan: duplicated requirement roles, malformed plan JSON,
bounded repair and execution approval; private product queue/work state.

**137. `9d1c48d24` — fix(abird): repair workflow control.** Skipped. Distinct
goal roles, bounded JSON repair feedback and complete repair schema,
retained-goal projection, agent/protocol/schema/browser tests. No Pvl
agent/protocol/web product.

**138. `87a02e0a2` — docs(plan): record workflow rollout.** Skipped. Updates
durable-workflow/conversation-UI notes and events 0004–0005 for semantic
deduplication, repair qualification and Gondor rollout; Abird contracts and
evidence only.

**139. `5c2ec1a58` — docs(plan): record root sync.** Skipped. Event 0006
explains Abird root checkout/ref synchronization after workflow rollout; neither
source patch nor Pvl git operation.

**140. `ac03b4248` — docs(plans): add completion repair plan.** Skipped.
Archives accepted specification/control repair; opens completion/presentation
plan for capacity failure and unstable check/candidate cards. Abird planning
state only.

**141. `f666e2ead` — docs(plans): correct completion repair plan.** Skipped.
Corrects plan baseline, prompt inputs, non-model capacity accounting, latest
evaluation selection and review readiness criteria; not an implementation
commit.

**142. `404921179` — fix(fleet): lock prepare across repository reexec.**
Adopted · this pass. Ported prepare/action exclusion across older re-exec
children, safe activation lock handoff and workspace lifetime, source/lock
reporting and regressions. Documented in the local deploy-system note. No
unrelated consolidated operator history or overwrite of PVL launch
receipts/user-job telemetry.

**143. `3f8c74f5d` — docs(notes): record abird site DNS parity.** Skipped. Site
DNS parity note records abird.ai live/state differences, imports and
redirect-first sequence; zone-specific evidence, not a shared DNS module change.

**144. `bd4018506` — feat(tf-platform): redirect `www.abird.ai` to apex.**
Skipped. Cloudflare platform rule is a 301 `www.abird.ai`→apex with query
preservation; specific zone/edge ownership, not a default for Pvl zones.

**145. `cf3bca575` — feat(tf-dns): adopt abird.ai site records.** Skipped.
Adopts abird.ai apex/site-verification/www records, variable wiring, rollout
README and protected inputs; no Pvl zone or generic Cloudflare module change.
Secret paths excluded.

## Commits 146–174

**146. `493d3c721` — feat(fleet): show Terraform project progress.** Clean ·
this pass. Ported Terraform project/phase timing, phase-specific host roster,
outcome handling and tests, README and Terraform progress note. None. No
project/state/deployment changes.

**147. `9a6450211` — feat(fleet): show a live lock wait timer.** Adopted · this
pass. Ported TTY lock-wait ticks, a single off-TTY waiting line and final
elapsed time, tests and local lock guidance. No unrelated consolidated Abird
operations history.

**148. `652dfc6ff` — fix(workflow): classify completion capacity.** Skipped.
Reduces completion-revision input before preflight and classifies irreducible
capacity as controller-owned, not a model-repair opportunity; abird-agent
workflow/store test only.

**149. `e141c6822` — fix(web): stabilize workflow results.** Skipped. Web
selects newest effective required evaluation, gates repository/review result on
retained evidence and stabilizes transcript render identities; Pvl has no Abird
web client.

**150. `f92583984` — fix(web): preserve workflow card state.** Skipped. Keeps
request/linked workflow cards and disclosure state across refresh, with browser
node-identity assertions; private web UI/test only.

**151. `867947491` — fix(web): satisfy stable render lint.** Skipped. Lint-only
then_some/flatten projection in abird-web conversations/workflows; same absence
of product as preceding UI fixes.

**152. `b74e98de5` — docs(plans): record repair qualification.** Skipped.
Execution and implementation/qualification events summarize capacity
classification, result projection and browser state retention; Abird plan
receipt, not shared tests.

**153. `e925f4743` — docs(plans): close workflow repair.** Skipped. Archives
completion/presentation work, removes queue item, records requalified signed
rollout and live gates; Abird deployment history only.

**154. `5a07fe779` — fix(review): classify source verification.** Skipped.
Review state gates checks/policy/preview blockages on source readability;
regression prevents disclosure of retained check state. Agent review store
absent.

**155. `0eb8bc07e` — fix(review): verify bases before display.** Skipped.
Validates review source observations, verifies selected base before display and
distinguishes pending/blockage states in protocol and web; no Pvl product
counterpart.

**156. `209837e1c` — docs(review): record base verification.** Skipped.
Repository-review playbook, base-verification plan/work events and bounded
browser/VM qualification document the previous two Abird changes, not a generic
git-review policy.

**157. `4bd062caa` — fix(update): reuse GitHub CLI credentials.** Adopted · this
pass. Ported noninteractive gh fallback after explicit tokens, public mode,
xtrace suppression, child/Nix propagation and isolated tests. Added the operator
contract to the local updater note. Nixbot service authentication is unchanged;
skip Abird incident/quota history.

**158. `b69f296a1` — fix(nvidia): resolve current production releases.** Adopted
· this pass. Ported the US runfile endpoint, strict explicit-update failures,
offline explicit-version report and guidance. Combined with PVL 360744d96 and
final source tests in 99e83aded. Do not regress to the intermediate
first-missing preflight; report every confirmed missing artifact and retain
fatal unexpected errors.

**159. `d3d902ba9` — fix(pi): validate staged updater builds.** Clean · this
pass. Ported the locked-nixpkgs callPackage against the staged candidate for
both hash probing and validation, its regression and the staged-build note.
None. This is not a source-pin update.

**160. `30d567d86` — feat(agent): add independent project enrollment.** Skipped.
Independent operator project enrollment, edit grants vs checked releases,
revision/policy/runner, agent/protocol/UI and contained tests; plan
index/playbooks target Abird only, not a reusable flake API.

**161. `3130d58e6` — refactor(gondor): externalize project enrollment.**
Skipped. Externalizes calculator manifest/checks from Gondor; host keeps
capacity/runtime only, changes enrollment binding/test/playbook and documents
superseded nixpkgs hold. No root flake pin change in this SHA.

**162. `59de34012` — chore(deps): refresh flake and source pins.** Adopted ·
already present. Bladebro 4.8.3 and shared inputs via f85d99458; Pi/tuicr
0.30.0/VS Code 1.147.0 pins and vscode-ext 19b08a92e via fb1db04a2. All four
sources files exact and all six changed direct lock nodes match by input (Pvl
nixpkgs_2). Keep distinct root graphs (Abird aw, Pvl desktop inputs); no
flake.nix edit or lock transplant. Reverse receipt's 9/10 common pins at
81107f4e9 is now 10/10.

**163. `54595c825` — chore(services): update container images.** Skipped.
Independent Pvl refresh fb1db04a2 already matches relevant Ollama 0.40.18,
Meilisearch 1.58.0 and Timescale pg18.7-ts2.32.1 tags. 13 Abird/Gap3 host image
declarations: AnythingLLM, Excalidash, Forgejo, LibreChat, OpenCloud/Collabora,
Outline/Zulip Redis, PostgreSQL, VictoriaMetrics, Ollama. No reusable image
default; do not repin Pvl hosts by analogy.

**164. `a55d0078a` — fix(forgejo): use Forgejo image registry.** Adopted · this
pass. Documented the shared operator limitation: Compose image acquisition does
not cover native Quadlet pulls, and a generation rollback is not proof of
stateful recovery. No PVL Forgejo host pin; skip the Corp registry switch and
Gondor incident history. The source did not implement an acquisition-engine
change.

**165. `bf4c1cd38` — feat(ext): add kache, oyo and diffx packages.** Clean ·
already present. Reverse port: kache 2.1.1 (c37c9038f), oyo 0.1.72 and diffx
0.7.1 (e1207b9d1); recipes, release sources and overlay registrations already
present. No z overlay-order transplant or change to Pvl CLI installs.

**166. `55aa65893` — fix(pgadmin4): ignore internal pg_ column options.** Clean
· already present. Reverse port ef61ec05b: pgAdmin 9.14 overlay registration and
six SQL template backports filtering internal pg_ column options already
present. No additional upstream test bypass or host rollout.

**167. `365e848fa` — chore(nvidia): bump production driver to 620.70.06.** Clean
· already present. Reverse port 63753111b: NVIDIA production 620.70.06 complete
source pin matches (runfile, open module, settings, persistenced). No updater
behavior or GPU deployment in this commit.

**168. `99e83aded` — fix(nvidia): skip incomplete driver releases.** Adopted ·
this pass. PVL 360744d96 supplied four-artifact preflight, suite continuation
and the check registration. Ported final explicit-failure/offline-report and
isolated-gh regressions; updater and suite now match upstream. No duplicate
check or rollback of collect-all semantics.

**169. `9002b7aa2` — fix(fleet): classify build failures from a launch
receipt.** Clean · already present. Reverse port 0e57521ab:
nonce/derivation-bound launcher receipt, failed vs unconfirmed disposition,
bounded output/diagnostics and build/host/native tests are already local. Other
differences in shared manager files are independent fleet changes, not missing
launch-receipt logic.

**170. `f453ac113` — feat(fleet): observe and render pending user jobs.** Clean
· already present. Reverse port 8e021acf1 + 24bba7754: bounded manager-wide
pending-user-job sampler, cleanup, parsing/rendering and tests already local;
operator scope noted in df659590b. Do not attribute observed jobs to activation
or import z presentation file wholesale over local work.

**171. `920d50aec` — docs(lang-patterns): require parenthesized list elements.**
Clean · already present. Exact parenthesized list-element rule/example already
in Pvl (052b2ec44; retained through f5bfc5b1a). Reverse documentation alignment.
No change to Pvl child-flake or Rust policy text.

**172. `7d530b5e5` — chore(tailscale): clarify the builder comment.** Clean ·
already present. Reverse port d4cfe0c24: version-neutral Tailscale builder
comment; default.nix matches. No updater change here; toolchain-directive
parsing/bound resolver are separate earlier source commits.

**173. `b42649fd4` — test(lib): pin cache trust list and registry defaults.**
Adopted · this pass. 7d6630622 already checked exact ordered trust, state
version, unfree and weekly/14-day GC. Removed redundant membership checks in
this pass. Keep the additional PVL Numtide cache and key, including the
corresponding registry count.

**174. `39c711a7a` — docs(notes): record the pvl forward-port receipt.**
Skipped. Reverse receipt only (57 Pvl commits through 81107f4e9, parity ledger
and divergence map), not Pvl implementation/verification. Rebase findings to
fb1db04a2: pins now match; keep local nginx:1.30.8 and tuicr git/ps check
inputs. Earlier-layout findings: three Cloudflare operator scripts/asset paths,
child-ref separator and llmug-hello --file against an unapplied constructor.
