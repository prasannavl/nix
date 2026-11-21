{
  lib,
  disk ? null,
  bootPartUuid ? null,
  rootPartUuid ? null,
  luksUuid ? null,
}: {
  config = lib.mkMerge [
    (lib.optionalAttrs (disk != null) {
      disko.devices.disk.main.device = lib.mkForce disk;
    })

    (lib.optionalAttrs (bootPartUuid != null) {
      disko.devices.disk.main.content.partitions.boot.uuid = lib.mkForce bootPartUuid;
    })

    (lib.optionalAttrs (rootPartUuid != null) {
      disko.devices.disk.main.content.partitions.root.uuid = lib.mkForce rootPartUuid;
    })

    (lib.optionalAttrs (luksUuid != null) {
      disko.devices.disk.main.content.partitions.root.content.name = lib.mkForce "luks-${luksUuid}";
      disko.devices.disk.main.content.partitions.root.content.extraFormatArgs = lib.mkForce ["--uuid" luksUuid];
    })
  ];
}
