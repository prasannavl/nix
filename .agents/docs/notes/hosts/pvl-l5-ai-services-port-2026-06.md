# PVL-L5 AI Services Port 2026-06

`pvl-l5` imports `hosts/pvl-l5/services`, which ports the local `pvl-a1` Ollama
and Open WebUI service layout onto the Legion host.

Service shape:

- `services.podman-compose.pvl` uses user `pvl`, stack directory
  `/var/lib/pvl/compose`, and service prefix `pvl-`.
- `ollama` runs the ROCm image on host port `11434`, mounts `/dev/kfd` and
  `/dev/dri`, stores shared model data at `/var/lib/pvl/ollama-models`, and uses
  `OLLAMA_CONTEXT_LENGTH=65536`.
- `ollama-nvidia` is declared with the same shared model store on host port
  `11435` and also uses `OLLAMA_CONTEXT_LENGTH=65536`, but its desired state is
  `stopped` so it is available for manual use without starting by default.
- `openwebui` runs on host port `4000` and points at both Ollama backends via
  `host.containers.internal:11434` and `host.containers.internal:11435`.
- `pvl-ollama-models.service` pulls the same required model list as `pvl-a1`
  after both backend units in ordering only; it does not want either backend, so
  it does not start a stopped backend during reconcile. It is not auto-started
  by `systemd-user-manager`; instead, `pvl-ollama-models-boot.timer` starts it 2
  minutes after boot. The boot delay gives the selected Ollama backend time to
  expose its API and keeps model pulls from competing with early startup. Its
  restart triggers include the normalized `ollama` and `ollama-nvidia` Podman
  Compose instance configs, so backend config changes rerun the model-pull
  helper.
- The model-pull script lives at `lib/services/ollama/helper.sh`, matching
  Abird's helper behavior while keeping the reusable implementation under the
  shared service-helper namespace. `pvl-l5` sets `OLLAMA_URLS` to both local
  backend endpoints, so the helper pulls through whichever backend API is
  reachable. If no configured Ollama API is available after the wait window, the
  helper logs a skip and exits successfully; model-pull failure remains reserved
  for API/pull errors after an API is reachable.

Validation:

- `alejandra hosts/pvl-l5/default.nix hosts/pvl-l5/services/default.nix hosts/pvl-l5/services/ollama.nix hosts/pvl-l5/services/openwebui.nix`
- `nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw`

The eval required temporary `git add -N` for the new service files because flake
source filtering does not include untracked imported paths.

## 2026-06-21 deploy failure

A deploy of system generation
`gdw6iixg62phl62gikv3hpashzyc8nx5-nixos-system-pvl-l5-26.05.20260611.a037402`
failed during activation because `systemd-user-manager-dispatcher-pvl.service`
treats the `pvl` user compose units as managed units and verifies them before
the deploy is considered successful.

The failing dependency chain was:

- `pvl-ollama.service` started first and ran `podman compose up`.
- `pvl-openwebui.service` depends on `pvl-ollama.service`, so it stayed inactive
  when Ollama failed.
- the dispatcher then reported failed managed unit verification for `pvl-ollama`
  and `pvl-openwebui`, which made activation fail and nixbot roll the host back.

The first `pvl-ollama.service` start created `/var/lib/pvl/compose/ollama`, a
Podman pod, and a compose network, then exceeded the helper start deadline after
about 81 seconds. This was not a deliberate 20-second service budget: the
compose helper defaulted to 90 seconds and reserved about 9 seconds for cleanup
because the generated user service did not set `TimeoutStartSec`. The helper
killed the compose process and cleaned up the pod and network. Later retries
failed immediately with:

```text
Refusing to manage existing Podman compose working directory without compatible helper state: /var/lib/pvl/compose/ollama; set adopt = true to adopt it
```

After rollback, `/var/lib/pvl/compose/ollama/.podman-compose/state.json`
remained with only the helper ownership stamp, and no Ollama/Open WebUI images
or containers were left. This means the immediate retry blocker was stale helper
state from a timed-out first start, while the original first-start problem was
that `podman compose up` for the ROCm Ollama service did not complete inside the
effective user-unit start timeout. Failed-start cleanup should remove generated
runtime files when the start never reached a healthy runtime, but preserve the
helper ownership marker so service data directories under the working directory
remain retryable. Leaving failed first-start debris that blocks retry is a
shared helper bug, not a host-specific adoption requirement.

Likely fixes:

- Pre-pull the large `ollama/ollama:rocm` image before activation, or enable the
  instance `imageTag`/image-pull path so image transfer happens outside the
  critical service start.
- The main ROCm Ollama compose units on `pvl-a1`, `pvl-l5`, and `pvl-x2` now set
  `serviceOverrides.serviceConfig.TimeoutStartSec = "5min"`. This is for cold
  image/container startup only; model pulls remain owned by
  `pvl-ollama-models.service`.
- The shared helper now records helper ownership before staging runtime files,
  and failed-start cleanup removes generated runtime files while preserving real
  service data and the retry ownership marker. The hard adoption refusal remains
  for genuinely unmanaged or incompatible existing directories, not for failed
  first-start leftovers.
- If retrying without the shared helper fix, either remove the empty stale
  `/var/lib/pvl/compose/ollama` helper shell or temporarily set `adopt = true`
  for one deploy. Do not keep `adopt = true` permanently unless the host is
  intentionally taking over an existing unmanaged compose directory.
