# pvl-a1 amdxdna firmware protocol mismatch (2026-03-02)

## Scope

- Host: `pvl-a1` (ASUS FA401WV / Strix class).
- Problem investigated: repeated boot-time `amdxdna` errors.

## Findings

- `amdxdna` probe fails every observed boot with:
  - `aie2_check_protocol: Incompatible firmware protocol major 7 minor 2`
  - `amdxdna_probe: Hardware init failed, ret -22`
- The issue reproduces on both kernels currently used in boot history:
  - `6.18.13`
  - `6.19.3`
- Therefore this is not a `6.19`-only regression.
- `lspci -nnk -s 67:00.1` identifies the NPU as `1022:17f0` and shows `amdxdna`
  as the kernel module.
- `modinfo amdxdna` expects firmware blobs under `amdnpu/.../npu.sbin`; the
  probe reaches protocol negotiation (so firmware is being loaded), then fails
  compatibility checks.

## Interpretation

- This is an NPU firmware/driver protocol mismatch on this
  platform/BIOS/firmware stack.
- It is distinct from the `amdgpu` display driver path and should not be treated
  as the primary suspend-reboot trigger by itself.

## Recommended fixes (priority order)

1. If NPU is not required now, disable `amdxdna` on `pvl-a1` to stop probe
   failures and log noise.
2. Keep BIOS and fwupd firmware current; retest after BIOS updates that include
   NPU firmware updates.
3. When NPU is needed, re-enable `amdxdna` and validate against a known-good
   kernel + linux-firmware pairing.
4. Do not rely on `6.19 -> 6.18` pinning as the primary fix for this specific
   error, since both fail with the same protocol mismatch.

## Nix change option (safe immediate workaround)

- Add host-scoped blacklist on `pvl-a1` (for example in
  `hosts/pvl-a1/default.nix` or `lib/devices/asus-fa401wv.nix` with host
  gating):

```nix
{
  boot.blacklistedKernelModules = [
    "amdxdna"
  ];
}
```

## Validation commands

- Confirm module is no longer loaded:
  - `lsmod | rg amdxdna` (expect no output)
- Confirm errors are gone in current boot:
  - `journalctl -k -b --no-pager | rg -n "amdxdna|aie2_check_protocol|amdxdna_probe"`
