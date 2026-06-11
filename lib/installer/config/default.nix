{
  name = "live-installer";

  targets = {
    # Matches hosts/pvl-a1/sys.nix: same host, disk, partition UUIDs, and LUKS UUID.
    pvl-a1 = {
      host = "pvl-a1";
      disk = "/dev/disk/by-id/nvme-Lexar_SSD_ARES_2TB_QEC053R000846P2222";
    };

    # Same pvl-a1 system closure, but installed onto the other NVMe in pvl-a1.
    pvl-a1-wd = {
      host = "pvl-a1";
      disk = "/dev/disk/by-id/nvme-WD_PC_SN5000S_SDEQNSJ-1T00-1002_24204M801689";
      ids = {
        bootPartUuid = "5568887e-4235-4720-aab0-ae5b1c88b7f0";
        rootPartUuid = "c069a548-bc51-43ce-8d65-9e826567f74d";
        luksUuid = "adf2b531-78fe-4a4f-8e52-a2752ada0911";
      };
    };

    pvl-x2 = {
      host = "pvl-x2";
      disk = "/dev/disk/by-id/nvme-CT4000T500SSD3_252050263EE1";
    };

    pvl-l5 = {
      host = "pvl-l5";
      disk = "/dev/disk/by-id/nvme-SKHynix_HFS001TDE9X084N_ANA4N476110504A1C";
    };
  };
}
