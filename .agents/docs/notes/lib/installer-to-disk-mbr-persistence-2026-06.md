# Installer-to-disk MBR persistence partition

## Context

`lib/installer/installer-to-disk.sh` writes a NixOS live installer ISO to a USB
disk and can append an encrypted persistence partition in the remaining free
space.

The live installer ISO can present as an ISO-hybrid MBR/DOS partition table
after `dd`, with an ISO9660 partition and an EFI partition. In that case,
`sgdisk -e` fails with:

```text
Invalid partition data!
```

## Decision

Choose the persistence partitioning path from the post-write partition table:

- `gpt`: keep the existing `sgdisk -e`, `sgdisk -F/-E`, and GPT partition-label
  flow.
- `dos`: append a primary MBR partition with `sfdisk -N <slot>` in the free
  space after the ISO partitions.

The live system discovers persistence by running `blkid -L` against the LUKS
label (`NIXOS_PERSIST` by default), so the MBR path does not need a GPT
partition label. During media creation, find the new MBR partition by its
partition number instead.
