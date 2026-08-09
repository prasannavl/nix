use std::fmt;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BootMode {
    Efi,
    Bios,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(transparent)]
pub struct PartitionSize(String);

impl PartitionSize {
    pub fn new(value: impl Into<String>) -> Result<Self> {
        let value = value.into();
        let digit_count = value.bytes().take_while(u8::is_ascii_digit).count();
        let (amount, unit) = value.split_at(digit_count);
        let valid_unit = matches!(unit, "K" | "M" | "G" | "T" | "KiB" | "MiB" | "GiB" | "TiB");
        if amount.is_empty()
            || amount
                .parse::<u64>()
                .ok()
                .filter(|amount| *amount > 0)
                .is_none()
            || !valid_unit
        {
            bail!(
                "partition size must be a positive integer followed by K, M, G, T, KiB, MiB, GiB, or TiB"
            );
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl FromStr for PartitionSize {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        Self::new(value)
    }
}

impl fmt::Display for PartitionSize {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(formatter)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PhysicalLayoutRequest {
    pub disk: PathBuf,
    pub boot_mode: BootMode,
    pub esp_size: PartitionSize,
    pub boot_size: PartitionSize,
    pub swap_size_mib: u64,
}

impl PhysicalLayoutRequest {
    pub fn new(disk: PathBuf) -> Result<Self> {
        validate_disk_path(&disk)?;
        Ok(Self {
            disk,
            boot_mode: BootMode::Efi,
            esp_size: PartitionSize::new("1G")?,
            boot_size: PartitionSize::new("1G")?,
            swap_size_mib: 0,
        })
    }

    pub fn validate(&self) -> Result<()> {
        validate_disk_path(&self.disk)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PhysicalLayout {
    pub disk: PathBuf,
    pub boot_mode: BootMode,
    pub esp_size: PartitionSize,
    pub boot_size: PartitionSize,
    pub swap_size_mib: u64,
    pub boot_partition_uuid: Uuid,
    pub bios_partition_uuid: Uuid,
    pub root_partition_uuid: Uuid,
    pub luks_uuid: Uuid,
}

impl PhysicalLayout {
    pub fn resolve(
        request: PhysicalLayoutRequest,
        previous: Option<&Self>,
        fresh_ids: bool,
    ) -> Result<Self> {
        request.validate()?;
        let ids = match (fresh_ids, previous) {
            (false, Some(previous)) => [
                previous.boot_partition_uuid,
                previous.bios_partition_uuid,
                previous.root_partition_uuid,
                previous.luks_uuid,
            ],
            _ => [
                Uuid::new_v4(),
                Uuid::new_v4(),
                Uuid::new_v4(),
                Uuid::new_v4(),
            ],
        };
        Ok(Self {
            disk: request.disk,
            boot_mode: request.boot_mode,
            esp_size: request.esp_size,
            boot_size: request.boot_size,
            swap_size_mib: request.swap_size_mib,
            boot_partition_uuid: ids[0],
            bios_partition_uuid: ids[1],
            root_partition_uuid: ids[2],
            luks_uuid: ids[3],
        })
    }

    pub fn render_system_module(&self, hardware: &HardwareProjection) -> String {
        let boot = match self.boot_mode {
            BootMode::Efi => format!(
                "    boot = diskoLib.mkEfiBoot {{\n      size = {};\n      partUuid = {};\n    }};\n",
                nix_string(self.esp_size.as_str()),
                nix_string(&self.boot_partition_uuid.to_string()),
            ),
            BootMode::Bios => format!(
                "    boot = diskoLib.mkBiosBoot {{\n      biosBoot.partUuid = {};\n      boot = diskoLib.mkExt4Boot {{\n        size = {};\n        partUuid = {};\n      }};\n    }};\n",
                nix_string(&self.bios_partition_uuid.to_string()),
                nix_string(self.boot_size.as_str()),
                nix_string(&self.boot_partition_uuid.to_string()),
            ),
        };
        let swap_subvolume = if self.swap_size_mib == 0 {
            String::new()
        } else {
            "        \"@swap\".mountpoint = \"/swap\";\n".to_owned()
        };
        let swap_devices = if self.swap_size_mib == 0 {
            "  swapDevices = [];\n".to_owned()
        } else {
            format!(
                "  swapDevices = [\n    {{\n      device = \"/swap/swap0\";\n      size = {};\n    }}\n  ];\n",
                self.swap_size_mib
            )
        };
        let hardware = hardware.render();
        format!(
            "# Hardware and install-storage config generated by abird-host-manager.\n{{\n  lib,\n  modulesPath,\n  ...\n}}: let\n  diskoLib = import ../../lib/disko/lib.nix {{inherit lib;}};\nin {{\n  imports = [\n    (modulesPath + \"/installer/scan/not-detected.nix\")\n    ../../lib/disko\n  ];\n\n  disko.devices.disk.main = diskoLib.mkMain {{\n    diskDevice = {};\n{boot}    root = diskoLib.mkLuksBtrfs {{\n      size = \"100%\";\n      name = {};\n      luksUuid = {};\n      partUuid = {};\n      subvolumes = {{\n        \"@\" = {{\n          mountpoint = \"/\";\n          mountOptions = [\"compress=zstd\"];\n        }};\n        \"@home\" = {{\n          mountpoint = \"/home\";\n          mountOptions = [\"compress=zstd\"];\n        }};\n{swap_subvolume}      }};\n    }};\n  }};\n\n{hardware}{swap_devices}}}\n",
            nix_string(&self.disk.to_string_lossy()),
            nix_string(&format!("luks-{}", self.luks_uuid)),
            nix_string(&self.luks_uuid.to_string()),
            nix_string(&self.root_partition_uuid.to_string()),
        )
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HardwareProjection {
    assignments: Vec<String>,
}

impl HardwareProjection {
    pub fn minimal() -> Self {
        Self {
            assignments: vec!["nixpkgs.hostPlatform = lib.mkDefault \"x86_64-linux\";".to_owned()],
        }
    }

    pub fn from_nixos_hardware_config(source: &str) -> Result<Self> {
        let lines = source.lines().collect::<Vec<_>>();
        let mut assignments = Vec::new();
        let mut index = 0;
        while index < lines.len() {
            let line = lines[index];
            let Some((attribute, _)) = line.trim().split_once('=') else {
                index += 1;
                continue;
            };
            let attribute = attribute.trim();
            if !allowed_hardware_attribute(attribute) {
                index += 1;
                continue;
            }
            let mut statement = line.trim().to_owned();
            while !statement_is_complete(&statement) {
                index += 1;
                if index >= lines.len() {
                    bail!("hardware configuration ends inside {attribute} assignment");
                }
                statement.push('\n');
                statement.push_str(lines[index].trim_end());
            }
            assignments.push(statement);
            index += 1;
        }
        if assignments.is_empty() {
            bail!(
                "hardware configuration contains none of the supported nixos-generate-config assignments"
            );
        }
        Ok(Self { assignments })
    }

    fn render(&self) -> String {
        let mut rendered = String::new();
        for assignment in &self.assignments {
            for line in assignment.lines() {
                rendered.push_str("  ");
                rendered.push_str(line.trim_start());
                rendered.push('\n');
            }
        }
        if !rendered.is_empty() {
            rendered.push('\n');
        }
        rendered
    }
}

fn validate_disk_path(path: &Path) -> Result<()> {
    if !path.is_absolute() || path == Path::new("/") || !path.starts_with("/dev") {
        bail!("physical disk must be an absolute path below /dev");
    }
    if path.to_string_lossy().contains(['\0', '\r', '\n']) {
        bail!("physical disk path contains control characters");
    }
    Ok(())
}

fn allowed_hardware_attribute(attribute: &str) -> bool {
    matches!(
        attribute,
        "boot.initrd.availableKernelModules"
            | "boot.initrd.kernelModules"
            | "boot.kernelModules"
            | "boot.extraModulePackages"
            | "nixpkgs.hostPlatform"
    ) || (attribute.starts_with("hardware.cpu.") && attribute.ends_with(".updateMicrocode"))
}

fn statement_is_complete(statement: &str) -> bool {
    statement
        .lines()
        .last()
        .map(str::trim)
        .is_some_and(|line| line.ends_with(';'))
}

pub(crate) fn nix_string(value: &str) -> String {
    serde_json::to_string(value)
        .expect("JSON string serialization cannot fail")
        .replace("${", "\\${")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(mode: BootMode) -> PhysicalLayoutRequest {
        PhysicalLayoutRequest {
            disk: PathBuf::from("/dev/disk/by-id/test"),
            boot_mode: mode,
            esp_size: PartitionSize::new("2G").unwrap(),
            boot_size: PartitionSize::new("3G").unwrap(),
            swap_size_mib: 4096,
        }
    }

    #[test]
    fn persistent_ids_survive_layout_updates_until_explicitly_rotated() {
        let original = PhysicalLayout::resolve(request(BootMode::Efi), None, false).unwrap();
        let updated =
            PhysicalLayout::resolve(request(BootMode::Bios), Some(&original), false).unwrap();
        let fresh =
            PhysicalLayout::resolve(request(BootMode::Bios), Some(&original), true).unwrap();

        assert_eq!(updated.luks_uuid, original.luks_uuid);
        assert_eq!(updated.root_partition_uuid, original.root_partition_uuid);
        assert_ne!(fresh.luks_uuid, original.luks_uuid);
        assert_ne!(fresh.root_partition_uuid, original.root_partition_uuid);
    }

    #[test]
    fn renders_existing_disko_library_for_efi_bios_and_swap() {
        let efi = PhysicalLayout::resolve(request(BootMode::Efi), None, false)
            .unwrap()
            .render_system_module(&HardwareProjection::minimal());
        assert!(efi.contains("diskoLib.mkEfiBoot"));
        assert!(efi.contains("size = \"2G\""));
        assert!(efi.contains("\"@swap\".mountpoint = \"/swap\""));
        assert!(efi.contains("size = 4096"));

        let bios = PhysicalLayout::resolve(request(BootMode::Bios), None, false)
            .unwrap()
            .render_system_module(&HardwareProjection::minimal());
        assert!(bios.contains("diskoLib.mkBiosBoot"));
        assert!(bios.contains("diskoLib.mkExt4Boot"));
        assert!(bios.contains("size = \"3G\""));
    }

    #[test]
    fn projects_only_hardware_assignments_from_generated_config() {
        let projection = HardwareProjection::from_nixos_hardware_config(
            r#"
{ config, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "xhci_pci" ];
  fileSystems."/" = { device = "/dev/unsafe"; };
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
"#,
        )
        .unwrap();
        let rendered = projection.render();
        assert!(rendered.contains("boot.initrd.availableKernelModules"));
        assert!(rendered.contains("hardware.cpu.amd.updateMicrocode"));
        assert!(rendered.contains("nixpkgs.hostPlatform"));
        assert!(!rendered.contains("fileSystems"));
    }

    #[test]
    fn nix_strings_escape_interpolation() {
        assert_eq!(nix_string("/dev/${unsafe}"), r#""/dev/\${unsafe}""#);
    }

    #[test]
    fn partition_sizes_and_disk_paths_are_typed() {
        assert!(PartitionSize::new("1G").is_ok());
        assert!(PartitionSize::new("1024MiB").is_ok());
        assert!(PartitionSize::new("0G").is_err());
        assert!(PartitionSize::new("100%").is_err());
        assert!(PhysicalLayoutRequest::new(PathBuf::from("relative")).is_err());
    }
}
