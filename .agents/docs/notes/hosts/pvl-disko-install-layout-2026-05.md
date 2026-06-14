# pvl Disko Install Layout 2026-05

`pvl-x2` and `pvl-a1` define disko layouts in their host `sys.nix` files for
automated installation with `nixos-anywhere`.

- `pvl-x2` installs to `/dev/disk/by-id/nvme-CT4000T500SSD3_252050263EE1`.
- `pvl-a1` installs to
  `/dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222`.
- Both hosts use a 1 GiB ESP followed by LUKS and Btrfs.
- The shared `lib/disko/default.nix` module imports upstream disko and installer
  overrides. Pure helpers live in `lib/disko/lib.nix`; host configs import them
  directly and set `disko.devices.disk.main = diskoLib.mkMain { ... }`.
- `diskoLib.mkMain` returns only the main disk config. It creates one GPT disk
  and composes `diskDevice`, `boot`, and `root`; additional disks stay explicit
  under their own `disko.devices.disk.<name>` entries.
- `diskoLib.mkEfiBoot { ... }` emits a single unencrypted vfat `boot` partition
  with GPT type `EF00`, mounted at `/boot`.
- `diskoLib.mkBiosBoot { ... }` emits a tiny GPT EF02 `biosBoot` partition plus
  an ext4 `boot` filesystem from `mkExt4Boot`. `mkExt4Boot` defaults to size
  `1G`, label `boot`, and mountpoint `/boot`.
- `diskoLib.mkBoot` remains a dispatcher with `mode = "efi"` by default, or
  `mode = "bios"`.
- Root partitions are normal composable values: use
  `root = diskoLib.mkLuksBtrfs { ... };`, `root = diskoLib.mkLuksExt4 { ... };`,
  `root = diskoLib.mkExt4 { ... };`, or pass a raw disko partition config.
- UEFI layout is `boot + root`, where `boot` is the ESP and `root` is currently
  LUKS/Btrfs.
- BIOS layout is `biosBoot + boot + root`; `biosBoot` is a tiny GPT EF02 GRUB
  core-image partition, while `boot` is the unencrypted filesystem mounted at
  `/boot`.
- Current host configs set ESP size `1G` and LUKS size `100%`.
- The generated generic GCP installer uses the EFI shape with `boot + root`;
  `boot` is a 512 MiB ESP labeled `ESP`, and root is plain ext4 labeled `nixos`.
- The disko configs pin the existing partition UUIDs and LUKS UUIDs so current
  installed systems can keep using the same stable device identities.
- The generated Btrfs subvolumes are `@` for `/` and `@home` for `/home`;
  `pvl-a1` also has `@swap` mounted at `/swap` for `/swap/swap0`.

Keep hardware-only boot details such as `boot.initrd.availableKernelModules`
beside the `lib/disko` import in `sys.nix`. Let disko own `fileSystems` and
`boot.initrd.luks.devices.<name>` for these hosts.
