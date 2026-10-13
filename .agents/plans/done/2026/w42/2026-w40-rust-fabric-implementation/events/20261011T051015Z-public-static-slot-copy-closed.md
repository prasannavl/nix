# Public static-slot copying closed at its final check

- Type: validation / closed finite public-data preparation
- Author: raw_events
- Result: exit 1; no preparation PASS, replay, current authority, or
  qualification claim.

Root and packet_readiness independently reviewed the complete finite copying
Source, bootstrap, manifest, inventory, and fourteen unique authentic public
inputs before root authorized one execution. The external whole-unit KILL25,
CPU15, AS512MiB, one CPU, file16MiB and public READ128MiB limits applied before
bootstrap Source ingestion. The process exited and was reaped; the tool call
reported 0.46449 seconds. No actual Nix, private body, operational main, peer
issuance, custody grant, or build ran in this unit.

The retained Source stage is
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/.agents/runs/rust-foundation-compact-public-slot-preparation-source-20261011`.
Its frozen inputs were:

| File                    | Bytes | SHA256                                                           |
| ----------------------- | ----: | ---------------------------------------------------------------- |
| prepare-public-slots.py | 12139 | 56bcfc61d6fe7de5ff9f931935d75392032a86ffaa6d5e35873b1dbd3a0835e6 |
| bootstrap.py.txt        |  3179 | 8eeb5cd37ab9ca6c3881a690ebfeff83c5396dea6d0e27b8a09941057db68d4b |
| public-inputs.json      |  8155 | 6170ed47854029820b6e48dede51a8f2cf8bac002a34d97ceae525aede2a3159 |
| slot-inventory.json     |  2442 | 22125bb73f15ee692609513f3c4822f89c7cbdbc10f38b9c6978d6536d10e6bf |
| preparation-stdout.json |     0 | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| preparation-stderr.txt  |  1242 | 7202de1bd3b069c8f747ecacf9252c12877f7d5a5a8389d157780e9a26cb774e |

The traceback identifies the final membership predicate at Source line 233:
`need(set(os.listdir(directory)) == set(values)|{'public-slot-provenance.json'})`.
Complete Source inspection confirms that the union binds before equality. This
unit did not record the observed membership set at failure, so a cause is not
established. A later read-only metadata listing showed the seventeen expected
names; this later observation does not turn the failed check into a PASS.

All sixteen payloads and the provenance were created with O_EXCL, mode0400 and
fsync before that final check. They are retained unchanged in
`/home/pvl/src/nix/worktrees/rust-fabric-foundation-20261001/.agents/runs/rust-foundation-compact-public-slots-20261011`.
The original exact public-input manifest specifies every payload hash and byte
length; fresh independent byte verification remains necessary before using these
retained copies in a new unarmed packet. The copying tool reserved 18679920
public Source bytes, including EOF capacity and its own Source, before reads;
external bootstrap ingestion reserved another 3180. Copied payload length was
18680741 because four named control slots share the same two genuine observed
reports. They do not represent four independent control batches. Provenance is
18218 bytes, SHA256
`837080e52696190d80b1c4c5697408e11801ce732bac3fe4eacb8d0d6d995d26`, pinned
during subsequent bounded public Source preparation; it is not a completed
copy-unit receipt. That preparation read the provenance twice, 18218 bytes each,
with pre-body file size checks; the first post-read comparison incorrectly
included atime and refused, then the static preparation used the specified nine
stat fields. This was no operational copy retry and changed no retained file.

Historical grant fields remain literal historical data. Current recipes, current
custody, independent Source peer issuance, runtime grants and initial manager
PASS remain unclaimed. Old Source/program prototypes and failed records were not
rewritten. Root selected fresh coherent Source candidates separately; failed
copies have not been promoted into them. A new finite data-only verifier will
authenticate the known retained payloads and provenance without recreating or
altering them. Its observation will remain distinct from this closed failure.
