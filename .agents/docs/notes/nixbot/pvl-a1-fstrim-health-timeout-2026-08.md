# `pvl-a1` fstrim health timeout on 2026-08-12

## Incident

Nixbot run `uBdPIk` deployed
`r8s5z3vk4pf2fx4smhclj0zq9d0s3wln-nixos-system-pvl-a1-26.05.20260808.8b8c811`.
The build, activation, profile promotion, and deploy result succeeded, including
recovery from the expected SSH disconnect while NetworkManager restarted. The
run was summarized as `FAIL (health)` because the post-deploy health check saw
`fstrim.service` still activating after its 180-second settlement window.

`nix-gc.service` started at the same time and completed successfully in about 13
seconds, deleting 3,062 paths and freeing 1.8 GiB. `fstrim.service` completed
successfully after 4 minutes 55 seconds, trimming `/boot` and 437.6 GiB on `/`.
It had only 7 seconds of CPU time and no failure result. The health result was
therefore a timeout false positive, not evidence of a failed trim or activation.

The weekly persistent fstrim timer became due as activation completed. Current
nixbot health logic treats any non-filtered transitional system service as
deployment work, so unrelated maintenance can consume the timeout derived from
service readiness metadata. A durable correction should distinguish deploy-
owned convergence from independent timer work, or give known successful
maintenance services a separate observation policy.

## Superseding activation during validation

While the failed run was being validated, a second nixbot run `zuMYXx` arrived
from the controller and switched the host to
`g2bwdf93f8v9m9isvkgmpv4bl1rlzh46-nixos-system-pvl-a1-26.05.20260808.8b8c811`.
It created profile generation 1005, ran the post-promotion bootloader `boot`
goal, and completed its immediate health check. This superseded `uBdPIk`'s
`r8s5...` target. The current checkout still evaluates to `r8s5...`, so future
validation must identify which source state produced `g2bw...` rather than
assuming the closures are identical from their shared version suffix.

After the second activation, `/run/current-system` and the persistent profile
both resolved to `g2bw...`; `/run/booted-system` remained the older `247p5...`
generation. Systemd reported `running`, with no pending jobs or failed system or
`pvl` user units. GDM and the Niri graphical session were active. Ollama and
Open WebUI were running, their ready targets were active, and Open WebUI
returned HTTP 200. Network and external DNS recovered after the activation
restart. Available memory was about 13 GiB, with about 10 GiB of the 64 GiB swap
file in use and no current pressure or OOM evidence.

## Reboot and service follow-ups

The live switch crossed an NVIDIA driver boundary. The booted kernel and module
remain Linux 7.1.4 and NVIDIA 595.84, while active userspace is NVIDIA
595.91.07. `nvidia-smi` therefore reports a driver/library mismatch. The CDI
generator was deliberately not restarted and still holds the old boot's
successful spec. Reboot into the promoted generation before treating GPU
validation as complete; afterward verify that booted, current, and profile
generations match and that the kernel, NVIDIA module, `nvidia-smi`, and CDI spec
all use the new versions.

Ollama 0.32.0 also introduced a separate functional regression. Its API and
ready target are healthy, but the log says the Radeon 890M integrated GPU was
dropped because `OLLAMA_IGPU_ENABLE` is unset, then reports CPU as the only
inference device. The `pvl-a1` ROCm instance is intended to use that iGPU, so
its environment needs an explicit `OLLAMA_IGPU_ENABLE=1` after confirming the
new upstream behavior. Current health checks do not validate the selected
inference device.

The controller's normal batch SSH initially failed because `pvl-a1` had no entry
in either configured known-hosts file, not because a saved key mismatched. The
observed ED25519 fingerprint was
`SHA256:Xj7KTFOoTnoba0wHhW3vrG3KNtj/GoO/tm2jk0Ph+pY`, distinct from `pvl-x2`.
The public-key comment still says `root@pvl-x2`, which is stale metadata but
does not indicate key reuse.
