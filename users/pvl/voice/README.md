# Voice dictation

Voxtype and Vocalinux are installed on the `pvl` dev profile (a1, l5, x2);
whisrs is packaged in `pkgs.voiceTools` but not installed. Vulkan is the default
for Whisper; install only one same-named daemon binary per profile. Nothing
auto-starts or takes a global hotkey until configured.

| Tool      | Installed                                                       | Optional (`pkgs.voiceTools`)                                       |
| --------- | --------------------------------------------------------------- | ------------------------------------------------------------------ |
| Voxtype   | `voxtype` (Whisper/Vulkan + Parakeet/Cohere ONNX + GGUF worker) | `voxtype.accel.{cpu,rocm,cuda}`, `voxtype.mk {whisper=…; onnx=…;}` |
| whisrs    | Not installed (packaged only)                                   | `whisrs.accel.{cpu,cuda,rocm}`, `whisrs.mk ["vulkan" "cuda"]`      |
| Vocalinux | `vocalinux` (Whisper/Vulkan)                                    | No extra upstream Nix variants                                     |

## Which accelerator a host runs

`users/pvl/voice/default.nix` holds one table, `accelByHost`, mapping each host
to `cpu`, `vulkan`, `cuda` or `rocm`, and installs
`voiceTools.voxtype.accel.<name>`. The table currently selects `vulkan`
everywhere: it is the only backend qualified on all three GPUs in the fleet
(NVIDIA, RADV, Radeon iGPU), it falls back to the CPU inside the same binary,
and CUDA/ROCm would add a multi-gigabyte toolchain to the desktop closure for a
small gain on short dictation clips. Move a host to `cuda` or `rocm` after
building and timing that variant on it. Voxtype has no upstream Whisper CUDA
build, so its `cuda` entry keeps Whisper on Vulkan and only moves the ONNX
execution provider.

## How a backend is selected

Cargo features are additive, so a backend is a feature list rather than a
separate derivation: `voice.whisrs.mk ["vulkan" "cuda"]` is one daemon that can
use either GPU, and `mk []` is the CPU build. Voxtype's `mk` composes upstream's
own builds — it reads the engine list, inputs, ONNX Runtime location and runtime
wrapper from `voxtype-onnx-unwrapped` — so this repo never restates an upstream
feature list that changes between releases.

The part that can silently break is the glue. `buildFeatures` is an argument of
`rustPlatform.buildRustPackage`; setting it through `overrideAttrs` is ignored
and builds the default (CPU) feature set, which is how a `vulkan` package once
shipped a CPU-only daemon. Each `mk` therefore extends `cargoBuildFeatures` and
`cargoCheckFeatures` directly in its `overrideAttrs` — the two environment names
the cargo hooks read.

A build can still end up on the CPU at runtime, and only the loaded model says
which backend it got: whisper-rs derives `use_gpu` from
`cfg!(feature = "_gpu")`, and whisper.cpp prints `use gpu = 1` from the
requested parameters before deciding `no GPU found` and falling back. Confirm
from the loaded model, not the config:

```sh
# Vulkan build with a GPU present, at model load:
#   whisper_init_with_params_no_state: use gpu    = 1
#   ggml_vulkan: Found 2 Vulkan devices: ... RTX 4060 ...
#   whisper_model_load: Vulkan0 total size =  487.00 MB

voxtype info accel --json   # observed GPU use of the running daemon
whisrs status               # daemon state; check its journal for ggml_vulkan
```

`voxtype info accel` deliberately reports `unknown` rather than intent: it
prefers the daemon's own state file, then VRAM held by its PID, then the
journal's `ggml_vulkan` lines, then the variant of the binary behind the PID.

## Packaging fixes in this repo

Voxtype's upstream Nix flake does **not** install the GGUF worker required by
its Vulkan build. Our overlay builds `voxtype-gguf-worker` separately from the
same pinned source, with its own Vulkan feature, and packages it with the Vulkan
daemon. `VOXTYPE_GGUF_WORKER` defaults to its immutable store path (existing
user overrides still win). A build whose Whisper backend is Vulkan gets the
Vulkan worker; the CPU build gets the CPU worker. The build rejects a missing
worker executable.

The upstream Voxtype ONNX packages also omit Oniguruma, which their Rust
tokenizer dependency needs in a Nix build; `mk` adds it. SQLite is not needed:
`rusqlite` is built bundled. The package-specific fixes live in
`lib/ext/voxtype/`, `lib/ext/whisrs/` and `lib/ext/vocalinux/`. The
`lib/overlays/voice.nix` file only wires these into `pkgs.voiceTools`, retaining
upstream wrappers.

Upstream ships the ONNX engines as separate binaries (`voxtype-onnx`, `-cuda`,
`-migraphx`) to keep each artifact small. One `voxtype` here carries a Whisper
backend and the ONNX engines at once, so one command serves every engine. If a
combined build ever misbehaves, install upstream's split packages themselves
(`inputs.voxtype.packages.<system>.vulkan` and `.onnx`); nothing in this repo is
needed for that, and only one same-named `voxtype` may be on `PATH`.

## Model and accelerator coverage

| Tool / model                | CPU                                                                 | Vulkan                      | NVIDIA CUDA                   | AMD ROCm/MIGraphX           |
| --------------------------- | ------------------------------------------------------------------- | --------------------------- | ----------------------------- | --------------------------- |
| Voxtype / Whisper           | Yes (CPU build or Vulkan fallback)                                  | **Installed**               | Not shipped by upstream flake | ROCm optional               |
| Voxtype / Parakeet          | **Installed** (ONNX, same binary)                                   | **Installed** (GGUF worker) | ONNX CUDA optional            | ONNX MIGraphX optional      |
| Voxtype / Cohere            | **Installed** (ONNX, same binary)                                   | **Installed** (GGUF worker) | ONNX CUDA optional            | Not in MIGraphX feature set |
| whisrs / Whisper            | Yes                                                                 | Packaged, not installed     | CUDA optional                 | HIP/ROCm optional           |
| whisrs / Parakeet or Cohere | Via an external ASR sidecar                                         | Sidecar-dependent           | Sidecar-dependent             | Sidecar-dependent           |
| Vocalinux / Whisper         | Yes (inside the Vulkan build)                                       | **Installed**               | Not in upstream Nix package   | Vulkan only                 |
| Vocalinux / Parakeet        | Optional upstream Python engine, **not** bundled by its Nix package | No                          | No                            | No                          |

Vocalinux's official Nix package bundles `pywhispercpp` with `GGML_VULKAN=ON`,
but does not package the optional sherpa-onnx, PyTorch or Faster Whisper
engines. Do not select Parakeet in Vocalinux without a separately packaged
dependency. It needs no extra check: its Python side already detects Vulkan →
CUDA → CPU at model load and logs the device it chose, and the bundled
`libggml-vulkan.so` plus `libggml-cpu.so` are both present.

## First use

```sh
# One voxtype binary carries the Whisper and the Parakeet/Cohere engines; select
# the engine and model in its config, then run one daemon at a time:
voxtype setup --download
voxtype configure
voxtype daemon
voxtype record toggle

# whisrs is packaged but not installed; add voiceTools.whisrs.accel.<accel> to
# users/pvl/voice/default.nix if needed. It supports streaming local Whisper
# (phrase-by-phrase), streaming hosted backends, ASR sidecars, and TTS. The
# wizard creates its config:
whisrs setup
whisrs status

# GTK interface, Whisper/Vulkan by default:
vocalinux
```

For Parakeet/Cohere in Voxtype, select the engine and model in its config before
starting the daemon. A model is **not** downloaded at NixOS activation; the
first-use setup manages model files under the user's XDG data directory.

For Parakeet or Cohere **GGUF**, the Vulkan `voxtype` command can use the worker
directly. GGUF Parakeet does not support streaming. Verify worker presence with
`command -v voxtype-gguf-worker` after activation and run
`voxtype info engines --json` to check GGUF model availability. If a previous
installation set a stale `VOXTYPE_GGUF_WORKER`, unset it to allow the Nix
wrapper to select the matching worker automatically.

The compositor owns shortcuts on Niri/Sway (e.g. `voxtype record toggle` or
`whisrs toggle`); use GNOME's custom shortcuts there. GNOME does not support
`wtype`, so use the app's IBus or uinput/clipboard typing path. The NixOS
profile enables `/dev/uinput` and grants only the `uinput` group, **not** the
privileged `input` group. That supports injected text without granting every app
raw access to all keystrokes. Do not enable evdev-captured hotkeys without
considering extra device permissions.

## Streaming, TTS and device choices

whisrs is packaged but not installed, so `whisrs status` and its `[tts]` replies
only apply after adding it back to the profile. Its `local-whisper` backend
streams text phrase by phrase on CPU, Vulkan, CUDA or HIP builds. Its
`asr-sidecar` supports separately hosted Parakeet/Cohere servers, while
`deepgram-streaming` and `openai-compatible-realtime` support compatible
streaming APIs. Batch-only sidecars do **not** become streaming simply by
choosing whisrs.

whisrs also provides read-aloud and spoken replies through its `[tts]` config:
`tts-sidecar` accepts an OpenAI-compatible `/v1/audio/speech` endpoint
(including a locally hosted TTS service). No TTS model/server is installed or
started by this module. Which voice is fastest/best depends on the chosen
server/model; benchmark that separately. Voxtype and Vocalinux remain primarily
speech-to-text tools.

Hardware per host, for choosing `accelByHost` and the GPU index those tools
take:

- L5: NVIDIA RTX **3060** Laptop GPU (compute capability 8.6, confirmed with
  `nvidia-smi`), plus AMD integrated graphics.
- A1: RTX 4060 (compute capability 8.9) plus Radeon 890M, per hardware plan.
- X2: AMD integrated graphics; Vulkan or ROCm/MIGraphX.

On a hybrid machine whisper.cpp enumerates both GPUs (for example
`0 = NVIDIA GeForce RTX 4060 Laptop GPU`, `1 = AMD Radeon 890M`) and uses device
0 by default, which was the discrete card on the hosts checked. Voxtype can
override that with `[whisper] gpu_device` or `VOXTYPE_VULKAN_DEVICE`; whisrs has
no device key in `[local-whisper]` and always takes the default device.

The optional whisrs CUDA build is left on ggml's default architecture list,
which already includes real code for the fleet's 8.6 and 8.9. Trimming it is the
`CUDAARCHS` env var, not `CMAKE_CUDA_ARCHITECTURES`. For its CUDA-only
`local-whisper` configuration, `flash_attn = true` may improve long utterance
throughput; leave it off by default for Vulkan/CPU.

Source pins are in the root `flake.nix`. See the upstream projects for runtime
tuning: [Voxtype](https://github.com/peteonrails/voxtype),
[whisrs](https://github.com/y0sif/whisrs) and
[Vocalinux](https://github.com/VocaHQ/vocalinux).
