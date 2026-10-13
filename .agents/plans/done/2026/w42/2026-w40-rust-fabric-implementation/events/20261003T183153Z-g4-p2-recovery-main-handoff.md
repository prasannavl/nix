# G4 P2 recovery-main handoff — event

- Event time: 2026-10-03T18:31:53Z
- Kind: coordination event (append-only). Records completed recovery handoff and
  the user's operational ownership/allocation instructions. NOT clearance; NOT a
  new grant.
- Author: focused delegated coordination-document writer (writer session
  re-used).

## 1. Handoff artifact created and independently verified

- Recovery handoff: `tmp/g4-native-invalidation-20261003T133000Z/HANDOFF.txt`
  - Full SHA256:
    `82937ffd9a3d6cecafc38ce407a3a77be9c4568ee66f210a6493b9baac422e66`
  - Size: 19825 bytes, regular file, mode 644.
  - Status: created by this writer session and independently verified.
- Independent verification:
  `.orchestrator/g4-recovery-handoff-writer-20261003/evidence/FINAL-verification.md`
  - Result: PASS, no objection, no blocker. Confirms the three precision
    corrections (explicit OPEN ledger status; six full literal absolute
    `source_paths`; exact preserved `.corrupt` filenames) and that every
    original fact and all source/test/native HOLDS remain intact.
- The read-only hash above is link-metadata accuracy only, NOT clearance.

## 2. Four rescue scripts restored to exact known-good SHAs

Restoration was performed earlier by the recovery lane; this event does not
restore them now. Full path/hash pairs:

- `scripts/rust-g4-qualification/fixture.py`
  `22d100682bf586575bef621f97b843cc79b98c707b0c39ec11334049f0bd8396`
- `scripts/rust-g4-qualification/freshness.py`
  `e3a5eed761da487e1aebd7fc7ba994e49f523fdeee79c362b41401c86670d54a`
- `scripts/rust-g4-qualification/freshness.nix`
  `aa6b540dd746aa587a430744f00a02b0d24be9d98122aa1cb5ffb04f5bb7fe80`
- `scripts/rust-g4-qualification/freshness-eval.nix`
  `64f79c2df34d6b8a19ba3773ff327bd4a4450a4751909e530753a744eb374559`

No tests were rerun for the recovery, the handoff, or this event.

## 3. Exact new-adapter P2 forensics

- Mechanism: `self.root / ABS source_paths` — pathlib discards `self.root` when
  the right operand is absolute — then `path.write_text(key)` overwrites the
  REAL source files.
- Incident: 2026-10-03 17:52:26 UTC.
- Writer/session: `01a102e1-244d-716d-bf2b-b2ffb2250b56`; transcript line 34
  creation / line 36 execution (as supplied by the emergency report).
- The current relative-filename fix is NOT independent test or native clearance.

Mandatory BEFORE any future tests or native work:

- hermetic `fakeRepo`/`tmp/lane`;
- ALL resolved paths prewrite-bound inside `fakeRepo` at the filesystem boundary
  (reject escaping absolute paths, traversal, and symlinks);
- production FOUR + adapter THREE real-source SHA256 captured before/after EACH
  mock;
- independent hermetic-repair clearance.

No tests now. Testing remains forbidden, not waived.

## 4. Ownership / allocation instructions (user-supplied; recorded, not reinterpreted)

- New-adapter owner `438`: RELEASED ownership of `freshness-controller.py`,
  `freshness-contained.py`, `freshness-test-adapter.py` to MAIN.
- Recovery owner `125` / `125deed`: RELEASED four-file recovery ownership to
  MAIN.
- Old `669` / `669740bc`: original `controller.py`, `contained.py`,
  `test-budget.py` remain PROTECTED and still running per user. No native
  authority; no reassignment and no stopping by this event.

## 5. Operational native allocation (user-supplied coordination state)

- Native allocation: HANDOFF TO MAIN, SAME existing aggregate `300`.
- Native ledger: OPEN, spent `0`, attempts `[]`.
- No CLOSED, no reset, no refund, no new grant, no ledger change.
- Compiled cache kept; old ledgers and budgets immutable.
- These are user-supplied coordination state, not observed by reading or
  modifying any ledger now.

## 6. Proof / HOLD status

- ActualCargo / native proof: NOT PROVEN.
- No exact producer certificate, no DAG proof, no cost certificate.
- SOURCE / TEST / NATIVE HOLD preserved. Document verification is not code or
  native clearance.

## 7. Review IDs (exact)

- `018c292d` — forensics.
- `125deed` — restoration.
- `6a` — prior source gate.
- `62ac` — prior 56 static PASS (historical; not current adapter clearance).
- `b5` — pending / no clearance.
- `aee` — independent document verification.

Only IDs already supplied in the HANDOFF are used; no full UUIDs invented.

## 8. Change scope

- Append-only new event. No earlier event, document, source, ledger, cache,
  README, index, canonical or note was changed.
- Bookkeeping for this event:
  `.orchestrator/g4-recovery-handoff-writer-20261003/evidence/event-writer.md`
  and
  `.orchestrator/g4-recovery-handoff-writer-20261003/evidence/event-path.txt`.
