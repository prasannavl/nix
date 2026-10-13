---
type: source-review
plan: 2026-w40-rust-fabric-implementation
actor: agent:packet_readiness
coordinator: MAIN
state: narrow-startup-coverage-reviewed-fresh-implementation-pending
---

# Source-confirmed startup coverage under unchanged original caps

MAIN reported the separately closed v3 unit UNSUPPORTED, wall0.2815347s, public
reservation17334076 and native reservation11752353, no recipe result, with302
mappings,1271 continued calls and an actually reaped child. Those coarse
counters identify no offending syscall, file or actor. This Source review does
not attribute the refusal to the startup calls below, refund the closed unit, or
grant any BODY/native/custody/reuse qualification.

Exact official Nix2.34.8
[main.cc558-567](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/nix/main.cc)
calls setStackSize(60MiB) before its exception wrapper. Its
[current-process.cc59-91](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/current-process.cc)
queries RLIMIT_STACK, requests the lesser of60MiB and the existing hard limit,
and logs a failure without throwing. initNix also calls bumpFileLimit:
[shared.cc121-138 and205](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libmain/shared.cc).
That best-effort operation changes the open-file soft limit toward the hard
limit, capped at1048576, and ignores setrlimit failure. The current v3 policy
allows only read-only prlimit queries and lacks SYS_setrlimit coverage.

The narrow proposed correction permits current-process prlimit64 writes only
when the immutable scalar resource selector is RLIMIT_STACK or RLIMIT_NOFILE,
and permits setrlimit only for those same resources. Current-process queries
retain their existing restriction; nonself writes and mutations of CPU, AS,
FSIZE and every other resource remain refused. Child-memory pointer inspection
is unnecessary to establish this boundary: a raced payload cannot change the
kernel's scalar resource selector into a protected limit. This review does not
claim the monitor attests the requested stack/open-file values themselves. The
original15CPU/512MiBAS/16MiBFSIZE/oneCPU/25wall/public128 limits remain
unchanged. Allowing the original best-effort calls preserves startup semantics
without injecting a fabricated successful limit mutation.

Nix's
[unix/signals.cc44-56 and95-111](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/unix/signals.cc)
starts a signal-handler thread whose loop calls sigwait. Exact glibc2.42
[sigwait.c](https://raw.githubusercontent.com/bminor/glibc/glibc-2.42/sysdeps/unix/sysv/linux/sigwait.c)
uses sigtimedwait. Linux's
[signal.c3573-3601](https://raw.githubusercontent.com/torvalds/linux/v6.18/kernel/signal.c)
implements rt_sigtimedwait and copies fixed signal information to the optional
output pointer on a successful wait. The proposed native-x86_64-only policy
conservatively reserves128 metadata bytes before every such continuation,
including failures/repeats; it does not inspect or trust a child length pointer.
Existing architecture/x32 rejection, fixed whole-unit CPU/wall accounting and
owned cleanup remain required. This is bounded signal metadata, not an alternate
public Source-body acquisition path.

Exact --offline sets useNet=false in main.cc124-129, so main.cc518-522 skips the
Internet-interface probe. No AF_NETLINK/Internet socket admission or broad
getsockopt addition follows from this review. Ordinary UDS connection uses the
already covered AF_UNIX socket/fcntl/connect chain:
[uds-remote-store.cc73-85](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libstore/uds-remote-store.cc)
and
[unix-domain-socket.cc14-29 and93-115](https://raw.githubusercontent.com/NixOS/nix/2.34.8/src/libutil/unix-domain-socket.cc).

Fresh v4 code must be reviewed completely, with meaningful controls for allowed
STACK/NOFILE writes, rejected protected-resource/nonself writes, exact128 signal
reservation and repeated/failing requests. Saved compile/control results and new
sanitized binary pins require review, followed by full final wrapper and all
dependency/held-bootstrap joins. The scoped Source streaming proof035912, daemon
body proof033328 and original acceptance boundaries still apply. This reviewer
performed public primary Source research only, with no child/Nix/build, trace,
private probe or predecessor mutation.
