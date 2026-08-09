use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use super::privilege::Privilege;

#[derive(Clone, Debug)]
pub struct NixosInstall {
    executable: PathBuf,
}

impl NixosInstall {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("nixos-install executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn install_system(
        &self,
        privilege: &Privilege,
        repository: &Path,
        root: &Path,
        system: &Path,
    ) -> Result<()> {
        if !root.is_absolute() || root == Path::new("/") {
            bail!("install root must be an absolute non-root path");
        }
        if !system.starts_with("/nix/store") {
            bail!("installation system must be a Nix store path");
        }
        privilege.run(
            repository,
            &self.executable,
            [
                "--no-root-passwd".to_owned(),
                "--root".to_owned(),
                root.to_string_lossy().into_owned(),
                "--system".to_owned(),
                system.to_string_lossy().into_owned(),
            ],
        )
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn installs_the_exact_prebuilt_system_without_reevaluating_a_flake() {
        let temporary = tempdir().unwrap();
        let log = temporary.path().join("argv");
        let privilege = temporary.path().join("privilege");
        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_owned());
        fs::write(
            &privilege,
            format!("#!{shell}\nprintf '%s\\n' \"$@\" > '{}'\n", log.display()),
        )
        .unwrap();
        fs::set_permissions(&privilege, fs::Permissions::from_mode(0o700)).unwrap();

        NixosInstall::new("/nix/store/install/bin/nixos-install")
            .unwrap()
            .install_system(
                &Privilege::new(privilege).unwrap(),
                temporary.path(),
                Path::new("/mnt"),
                Path::new("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"),
            )
            .unwrap();

        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains("--system"));
        assert!(arguments.contains("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"));
        assert!(!arguments.contains("--flake"));
    }
}
