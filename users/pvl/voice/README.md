# Voice dictation

All three tools are installed on the `pvl` dev profile (a1, l5, x2). Vulkan
is the default for Whisper; install only one same-named daemon binary per
profile. Nothing auto-starts or takes a global hotkey until configured.

| Tool | Installed | Optional Nix packages (`pkgs.voiceTools`) |
| --- | --- | --- |
| Voxtype | `voxtype` (Whisper/Vulkan), `voxtype-onnx` (Parakeet/Cohere/CPU) | `voxtype.cpu`, `voxtype.rocm`, `voxtype.onnxCuda`, `voxtype.onnxMigraphx` |
| whisrs | `whisrs`, `whisrsd` (Whisper/Vulkan) | `whisrs.cpu`, `whisrs.cuda`, `whisrs.rocm` |
| Vocalinux | `vocalinux` (Whisper/Vulkan) | No extra upstream Nix variants |

Voxtype's upstream Nix flake does **not** install the GGUF worker required
by its Vulkan build. Our overlay builds `voxtype-gguf-worker` separately
from the same pinned source, with its own Vulkan feature, and packages it
with the Vulkan daemon. `VOXTYPE_GGUF_WORKER` defaults to its immutable
store path (existing user overrides still win). ONNX command wrappers
point to the same Vulkan worker, while the CPU-only daemon gets a CPU
worker. The build rejects a missing executable or a Vulkan worker without
the `libvulkan.so.1` dependency.

The upstream Voxtype ONNX packages also omit Oniguruma, which their Rust
tokenizer dependency needs in a Nix build. Our CPU, CUDA and MIGraphX ONNX
variants include that dependency; all Voxtype variants also need SQLite
for linking. The package-specific fixes live in `lib/ext/voxtype/`,
`lib/ext/whisrs/` and `lib/ext/vocalinux/`. The `overlays/voice.nix`
file only wires these into `pkgs.voiceTools`, retaining upstream wrappers.

The optional Voxtype ONNX builds appear as distinct commands
(`voxtype-onnx-cuda` / `voxtype-onnx-migraphx`) rather than another
`voxtype`; install the alternative you need alongside the Vulkan binary.
The backends are independently compiled, **not** run simultaneously in a
single Voxtype daemon.

## Model and accelerator coverage

| Tool / model | CPU | Vulkan | NVIDIA CUDA | AMD ROCm/MIGraphX |
| --- | --- | --- | --- | --- |
| Voxtype / Whisper | Yes | **Installed** | Not shipped by upstream flake | ROCm optional |
| Voxtype / Parakeet | **Installed** (ONNX) | **Installed** (GGUF worker) | ONNX CUDA optional | ONNX MIGraphX optional |
| Voxtype / Cohere | **Installed** (ONNX) | **Installed** (GGUF worker) | ONNX CUDA optional | Not in MIGraphX feature set |
| whisrs / Whisper | Yes | **Installed** | CUDA optional | HIP/ROCm optional |
| whisrs / Parakeet or Cohere | Via an external ASR sidecar | Sidecar-dependent | Sidecar-dependent | Sidecar-dependent |
| Vocalinux / Whisper | Yes | **Installed** | Not in upstream Nix package | Vulkan only |
| Vocalinux / Parakeet | Optional upstream Python engine, **not** bundled by its Nix package | No | No | No |

Vocalinux's official Nix package bundles `pywhispercpp` with
`GGML_VULKAN=ON`, but does not package the optional sherpa-onnx, PyTorch
or Faster Whisper engines. Do not select Parakeet in Vocalinux without a
separately packaged dependency.

## First use

```sh
# Whisper + Vulkan; select/download model and run one daemon at a time:
voxtype setup --download
voxtype daemon
voxtype record toggle

# For Parakeet/Cohere, stop the Whisper daemon and select the ONNX engine.
# The Nix wrapper replaces the upstream binary-switching step:
voxtype-onnx configure
voxtype-onnx daemon

# whisrs supports streaming local Whisper (phrase-by-phrase), streaming
# hosted backends, ASR sidecars, and TTS. The wizard creates its config:
whisrs setup
whisrs status

# GTK interface, Whisper/Vulkan by default:
vocalinux
```

For Parakeet/Cohere in Voxtype, select the engine and model in its config
before starting the ONNX binary. A model is **not** downloaded at NixOS
activation; the first-use setup manages model files under the user's XDG
data directory.

For Parakeet or Cohere **GGUF**, the normal Vulkan `voxtype` command can
use the worker directly; the separate ONNX command is not required.
GGUF Parakeet does not support streaming. Verify worker presence with
`command -v voxtype-gguf-worker` after activation and run
`voxtype info engines --json` to check GGUF model availability. If a
previous installation set a stale `VOXTYPE_GGUF_WORKER`, unset it to
allow the Nix wrapper to select the matching worker automatically.

The compositor owns shortcuts on Niri/Sway (e.g. `voxtype record toggle`
or `whisrs toggle`); use GNOME's custom shortcuts there. GNOME does not
support `wtype`, so use the app's IBus or uinput/clipboard typing path.
The NixOS profile enables `/dev/uinput` and grants only the `uinput`
group, **not** the privileged `input` group. That supports injected text
without granting every app raw access to all keystrokes. Do not enable
evdev-captured hotkeys without considering extra device permissions.

## Streaming, TTS and device choices

whisrs's `local-whisper` backend streams text phrase by phrase on CPU,
Vulkan, CUDA or HIP builds. Its `asr-sidecar` supports separately hosted
Parakeet/Cohere servers, while `deepgram-streaming` and
`openai-compatible-realtime` support compatible streaming APIs.
Batch-only sidecars do **not** become streaming simply by choosing whisrs.

whisrs also provides read-aloud and spoken replies through its `[tts]`
config: `tts-sidecar` accepts an OpenAI-compatible
`/v1/audio/speech` endpoint (including a locally hosted TTS service).
No TTS model/server is installed or started by this module. Which voice
is fastest/best depends on the chosen server/model; benchmark that separately.
Voxtype and Vocalinux remain primarily speech-to-text tools.

Backends are exposed on all three machines without eagerly installing CUDA
and ROCm toolchains in every desktop closure. Change the package chosen in
`default.nix` when a specific machine should use a non-Vulkan build:

- L5: NVIDIA RTX **3060** Laptop GPU (compute capability 8.6, confirmed
  with `nvidia-smi`), plus AMD integrated graphics.
- A1: RTX 4060 (compute capability 8.9) plus AMD graphics, per hardware plan.
- X2: AMD integrated graphics; choose Vulkan or ROCm/MIGraphX.

The optional whisrs CUDA build compiles for both 8.6 and 8.9. For its
CUDA-only `local-whisper` configuration, `flash_attn = true` may improve
long utterance throughput; leave it off by default for Vulkan/CPU.

Source pins are in the root `flake.nix`. See the upstream projects for
runtime tuning: [Voxtype](https://github.com/peteonrails/voxtype),
[whisrs](https://github.com/y0sif/whisrs) and
[Vocalinux](https://github.com/VocaHQ/vocalinux).
