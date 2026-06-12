# pvl-l5 Legion GPU PCI Map 2026-06

Live validation on `pvl-l5` showed the Lenovo Legion 5 15ACH6H GPU PCI topology
differs from the previous repo assumptions:

- `0000:01:00.0` / `PCI:1:0:0` is NVIDIA GA106M RTX 3060 Mobile, driver
  `nvidia`, DRM `card0` / `renderD129`.
- `0000:06:00.0` / `PCI:6:0:0` is AMD Cezanne Radeon iGPU, driver `amdgpu`, DRM
  `card1` / `renderD128`.
- `0000:05:00.0` / `PCI:5:0:0` is the SK hynix NVMe SSD, not a GPU.

The shared Legion module must therefore use `PCI:6:0:0` for
`hardware.nvidia.prime.amdgpuBusId`, and its AMD udev aliases must match
`0000:06:00.0` so `/dev/dri/zcard-default` and `/dev/dri/zrender-default` point
at the AMD iGPU.
