---
type: validation
plan: 2026-w40-rust-fabric-implementation
actor: MAIN
coordinator: MAIN
state: sixth-constructor-unit-closed-source-coverage-gap-reviewed
---

# Sixth constructor refusal and independent startup Source proof

MAIN executed scope043213 once. Actual REFUSED/IOCTL_POLICY, native124/wrapper1,
expiredfalse, wall0.13263144297525287s, total17330105 public reservations,
native11744161/128628038, bootstrap11659785, continued1271, mappings302,
metadataCalls0, monitor metadata8192. Owned child reaped; childExit-1; recipe
stdout/stderr empty; runtimeGrantfalse. CLOSED/full25 without retry/refund. No
private probe, BODY/native or manager/warm execution.

Observed family is IOCTL_POLICY only. It identifies no selector, argument,
payload, path or exact syscall occurrence. It does not establish earlier refusal
causes or the historical ctimeNs cause.

Separately, complete primary Nix2.34.8 startup Source review establishes an
unconditional coverage gap: saved main.cc396 calls initNix; shared.cc163 calls
startSignalHandlerThread; unix/signals.cc103 calls updateWindowSize before
creating its thread; terminal.cc172 performs ioctl(2,TIOCGWINSZ,&winsize), even
when stderr is a file, and ignores failure. Saved offsets are authoritative;
earlier informal offsets named approximate function ranges. Linux x86_64 winsize
is four unsigned-short fields, fixed8 bytes. Immutable selector bounds this
operation; target pointers cannot race the selector into other ioctls.

Primary files and exact URLs/pins are retained at the absolute R
.agents/runs/rust-foundation-read-accounting-v7-source-20261011/primary-source:
terminal6207/677a1d1044cad8c9bf0cb8cc0f62d597b8f9f884536462efce3396ce27c2d776;
signals4834/3797d92964a484639ea8dc8d4b1447cbd03afc0fa4a0238c99e2b05aadbb927d;
shared13312/309b950491053e5017ad2d3b7a8048841433f09d5e2f335ca9b4de1227df9505;
main18972/59026f920ce966dbb8f462cf614b2ca95c42703d3ad3300af3c4d76a7614ad14.

Fresh v7 Source adds only TIOCGWINSZ fixed8 metadata reservation before
continuation, including failed/partial/repeated requests; all unknown ioctl
selectors remain denied. Existing Source/caps/config/argv/CPU/AS/bootstrap and
guards remain. Complete independent C/control Source review accepted a bounded
synthetic component batch. Final binary/wrapper review and fresh scope remain
required before another actual constructor. This Source proof justifies
coverage; it does not claim that TIOCGWINSZ was the observed rejected selector.
Original recipe/custody/proof/manager-before-warm and remaining gates remain.
