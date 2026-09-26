use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use super::privilege::Privilege;

#[derive(Clone, Debug)]
pub struct NixosGenerateConfig {
    executable: PathBuf,
}

impl NixosGenerateConfig {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("nixos-generate-config executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn show_hardware_config(&self, privilege: &Privilege, repository: &Path) -> Result<String> {
        let result = privilege.output(repository, &self.executable, ["--show-hardware-config"])?;
        if !result.success {
            bail!("nixos-generate-config failed: {}", result.stderr);
        }
        if result.stdout_truncated_bytes != 0 {
            bail!("nixos-generate-config output exceeded the bounded capture limit");
        }
        Ok(result.stdout)
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;
    use crate::test_support::write_executable;

    #[test]
    fn captures_hardware_config_through_the_privilege_boundary() {
        let temporary = tempdir().unwrap();
        let privilege = temporary.path().join("privilege");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        write_executable(
            &privilege,
            format!(
                "#!{shell}\nprintf '%s\\n' 'nixpkgs.hostPlatform = lib.mkDefault \"x86_64-linux\";'\n"
            ),
        )
        .unwrap();

        let output = NixosGenerateConfig::new("/nix/store/generator")
            .unwrap()
            .show_hardware_config(&Privilege::new(privilege).unwrap(), temporary.path())
            .unwrap();

        assert!(output.contains("nixpkgs.hostPlatform"));
    }
}
