# Nixbot local self-deploy network race

## Incident

Nixbot run `6BLH0j`, started August 10, 2026 at `17:08:54 +0800`, ran on
`pvl-l5` and deployed `pvl-l5` in the same dependency wave as remote required
host `pvl-x2`.

The `pvl-x2` closure copy connected successfully to its effective inventory
target, `192.168.1.1`, and began copying 3,155 paths. The stream then failed
with `Broken pipe`; both bounded retries returned `Network is unreachable`.
Activation was never submitted on `pvl-x2`.

The local `pvl-l5` journal established the matching route outage:

- At `17:10:02`, the concurrent `pvl-l5` switch stopped
  `NetworkManager.service`.
- NetworkManager did not restart until `17:10:50`.
- Nixbot's two copy retries waited only two and four seconds, so both ran while
  the controller had no LAN route.
- The optional `pvl-l5` activation returned status 4 for the known stale GDM
  greeter user-unit failure. Its rollback stopped NetworkManager again from
  `17:11:04` until `17:11:51` and returned the same non-fatal user-switch status
  4.

This was a controller transport failure caused by deploying the controller, not
a `pvl-x2` activation or host-health failure. After the run, `pvl-x2` was
reachable and `systemctl is-system-running` reported `running`. Both
`/run/current-system` and the persistent system profile still pointed to the
snapshotted pre-deploy generation
`wrmnr5b0za3zp9hsdpn3v927f1fjk92k-nixos-system-pvl-x2-26.05.20260724.597283a`.
The local `pvl-l5` rollback likewise restored both links to its saved
`r9n6vkwqw35w2rcm0prn71fbcs99am7m` generation.

## Ownership boundary

Deploy parallelism currently treats a local self-target like any other sibling
inside a dependency wave. A self-target activation can restart the operator
host's network or SSH services while sibling jobs still need those services for
closure copies, activation submission, or result observation.

The durable scheduling rule should be stronger than starting the self-target
last: deploy a local self-target only after all remote siblings in the wave have
completed, and isolate its rollback for the same reason. Merely extending
transport retries hides the race and cannot bound how long a local activation or
rollback may disrupt connectivity.

## Safe recovery

Because `pvl-x2` never crossed the activation boundary, no target rollback or
runtime repair is needed. A deploy selecting only `pvl-x2`, while the controller
network is stable, can safely resume by copying the remaining content-addressed
store paths and then activating normally.

Until self-target isolation is implemented, use one of these operational
boundaries:

- deploy remote required hosts separately before deploying `pvl-l5`; or
- use serial deployment only when host ordering guarantees the local self-target
  has fully completed before later remote work begins.

Do not interpret the recurring `pvl-l5` status 4 as the cause of the remote
target failure. It triggers rollback and a second route outage, but the first
NetworkManager stop already broke the `pvl-x2` copy.

## Isolated retry

Run `zeJbAm`, started at `17:51:42`, selected only `pvl-x2`. Its closure copy
completed without transport loss and activation was submitted, confirming that
isolating the remote target removed the controller self-deploy race.

The isolated deploy still returned status 4 for the independent, previously
known GDM greeter user-switch failure. Its rollback restored the saved
generation but returned the same status 4. This follow-up does not revise the
self-target scheduling diagnosis; it separates that transport bug from the
remaining activation ownership bug.
