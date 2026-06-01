{pkgs, ...}: {
  imports = [
    ../hardware/mesa.nix
    ../hardware/amdgpu-strix.nix
    ../hardware/nvidia.nix
    ../hardware/logitech.nix
    ../hardware/mt7921e.nix
    ../hardware/openrgb.nix
    ../hardware/tpm.nix
    ../keyd.nix
  ];

  # AMD Strix / ASUS bug, ignore microcode until BIOS update
  hardware.cpu.amd.updateMicrocode = false;

  hardware.nvidia = {
    nvidiaPersistenced = false;
    dynamicBoost.enable = false;
    prime = {
      offload.enable = true;
      reverseSync.enable = true;
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
  };

  boot.extraModprobeConfig = ''
    # Attempt amdgpu binds before nvidia. This doesn't happen if the
    # PCI device comes earlier, but we try anyway.
    softdep nvidia pre: amdgpu
    softdep nvidia_drm pre: amdgpu
    softdep nouveau pre: amdgpu
  '';

  services = {
    udev.extraRules = ''
      KERNEL=="card*", KERNELS=="0000:66:00.0", SYMLINK+="dri/zcard-amd", SYMLINK+="dri/zcard-default"
      KERNEL=="renderD*", KERNELS=="0000:66:00.0", SYMLINK+="dri/zrender-amd", SYMLINK+="dri/zrender-default"
      KERNEL=="card*", KERNELS=="0000:64:00.0", SYMLINK+="dri/zcard-nvidia"
      KERNEL=="renderD*", KERNELS=="0000:64:00.0", SYMLINK+="dri/zrender-nvidia"
    '';

    # Adds the missing asus functionality to Linux.
    # https://asus-linux.org/manual/asusctl-manual/
    # Note: It generates a lot of spam logs currently
    # So we just have it disabled for now, since it's
    # doesn't bring any key features, just nice to have.
    # asusd = {
    #   enable = true;
    #   # This device doesn't have LEDs that this enables.
    #   # enableUserService = true;
    # };

    # Enable gfx mux control
    supergfxd.enable = true;

    # Key remaps
    keyd = {
      keyboards = {
        default = {
          ids = ["0001:0001:3cf016cc"];
          settings = {
            main = {
              # Right ctrl key mapping (from co-pilot key)
              "leftmeta+leftshift+f23" = "layer(control)";
            };
          };
        };
      };
    };

    udev.extraHwdb = ''
      # Sysrq key maps (Since it lacks print scr)
      # ===
      # dev: AT Translated Set 2 keyboard
      # key: Fn + Left Ctrl
      evdev:name:AT Translated Set 2 keyboard:*
       KEYBOARD_KEY_dd=sysrq

      # dev: Asus WMI hotkeys
      # key: Armory crate
      # notes: This isn't picked up kernel as it only
      # listens to AT device.
      evdev:name:Asus WMI hotkeys:*
       KEYBOARD_KEY_38=sysrq
    '';
  };

  environment.sessionVariables = {
    # GNOME on vulkan wakes up the dGPU momentarily that causes a 2-3s gap
    # when opening new apps.
    GSK_RENDERER = "gl";
  };
  environment.systemPackages = let
    asusFa401wvPower = pkgs.writeShellApplication {
      name = "asus-fa401wv-power";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        usage() {
          cat >&2 <<'EOF'
        usage: sudo asus-fa401wv-power 5w|15w|15-35w|35w|80w|low|med|high|reset

        Modes:
          5w       experimental 5W cap for maximum battery life
          15w      15W cap across all exposed PPT limits
          15-35w   firmware-supported low-power cap
          35w      firmware-supported balanced cap
          80w      firmware-supported max power
          reset    apply 35w, then rebind amd-pmf

        Firmware aliases:
          low   same as 15-35w
          med   same as 35w
          high  same as 80w
        EOF
          exit 2
        }

        mode="''${1:-}"
        [ "$#" -eq 1 ] || usage
        reset_amd_pmf=0

        if [ "$(id -u)" -ne 0 ]; then
          echo "asus-fa401wv-power: run as root, e.g. sudo asus-fa401wv-power $mode" >&2
          exit 1
        fi

        asus_wmi=/sys/devices/platform/asus-nb-wmi
        amd_profile=/sys/devices/platform/AMDI0103:00/platform-profile/platform-profile-0/profile
        asus_profile=/sys/devices/platform/asus-nb-wmi/platform-profile/platform-profile-1/profile
        acpi_profile=/sys/firmware/acpi/platform_profile

        case "$mode" in
          5w)
            pl1=5
            pl2=5
            fppt=5
            ppd_mode=power-saver
            amd_mode=low-power
            asus_mode=quiet
            acpi_mode=low-power
            ;;
          15w)
            pl1=15
            pl2=15
            fppt=15
            ppd_mode=power-saver
            amd_mode=low-power
            asus_mode=quiet
            acpi_mode=low-power
            ;;
          15-35w | low)
            pl1=15
            pl2=35
            fppt=35
            ppd_mode=power-saver
            amd_mode=low-power
            asus_mode=quiet
            acpi_mode=low-power
            ;;
          35w | med)
            pl1=35
            pl2=35
            fppt=35
            ppd_mode=balanced
            amd_mode=balanced
            asus_mode=balanced
            acpi_mode=balanced
            ;;
          80w | high)
            pl1=80
            pl2=80
            fppt=80
            ppd_mode=performance
            amd_mode=performance
            asus_mode=performance
            acpi_mode=performance
            ;;
          reset)
            pl1=35
            pl2=35
            fppt=35
            ppd_mode=balanced
            amd_mode=balanced
            asus_mode=balanced
            acpi_mode=balanced
            reset_amd_pmf=1
            ;;
          *)
            usage
            ;;
        esac

        write_value() {
          path="$1"
          value="$2"

          if [ ! -e "$path" ]; then
            echo "skip missing $path" >&2
            return 0
          fi

          printf '%s\n' "$value" >"$path"
        }

        reset_amd_pmf() {
          device=AMDI0103:00
          driver=/sys/bus/platform/drivers/amd-pmf

          if [ ! -e "$driver/unbind" ] || [ ! -e "$driver/bind" ]; then
            echo "warning: amd-pmf bind controls are not available" >&2
            return 0
          fi

          if [ -L "/sys/bus/platform/devices/$device/driver" ]; then
            if ! printf '%s\n' "$device" >"$driver/unbind"; then
              echo "warning: failed to unbind amd-pmf device $device" >&2
              return 0
            fi
            sleep 2
          else
            echo "warning: amd-pmf device $device is not currently bound" >&2
          fi

          if ! printf '%s\n' "$device" >"$driver/bind"; then
            echo "warning: failed to bind amd-pmf device $device" >&2
          fi
        }

        if command -v powerprofilesctl >/dev/null 2>&1; then
          if ! powerprofilesctl set "$ppd_mode"; then
            echo "warning: powerprofilesctl set $ppd_mode failed" >&2
          fi
        fi

        write_value "$asus_wmi/ppt_pl1_spl" "$pl1"
        write_value "$asus_wmi/ppt_pl2_sppt" "$pl2"
        write_value "$asus_wmi/ppt_fppt" "$fppt"

        # The global ACPI profile can fan out to provider profiles, so write it
        # before the provider-specific profiles we want to pin.
        write_value "$acpi_profile" "$acpi_mode"
        write_value "$amd_profile" "$amd_mode"
        write_value "$asus_profile" "$asus_mode"

        if [ "$reset_amd_pmf" = 1 ]; then
          reset_amd_pmf
        fi

        echo "mode=$mode"
        for path in \
          "$asus_wmi/ppt_pl1_spl" \
          "$asus_wmi/ppt_pl2_sppt" \
          "$asus_wmi/ppt_fppt" \
          "$acpi_profile" \
          "$amd_profile" \
          "$asus_profile"; do
          if [ -e "$path" ]; then
            printf '%s=%s\n' "$path" "$(cat "$path")"
          fi
        done
      '';
    };
  in [asusFa401wvPower];
}
