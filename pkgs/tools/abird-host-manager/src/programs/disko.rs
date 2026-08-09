use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use super::privilege::Privilege;

#[derive(Clone, Debug)]
pub struct DiskoScript {
    executable: PathBuf,
}

impl DiskoScript {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.starts_with("/nix/store") || executable == Path::new("/nix/store") {
            bail!("disko script must be an absolute store path");
        }
        Ok(Self { executable })
    }

    pub fn destroy_format_mount(&self, privilege: &Privilege, repository: &Path) -> Result<()> {
        // system.build.diskoScript already contains the complete configured
        // destroy/format/mount operation. It does not consume disko CLI flags.
        privilege.run(repository, &self.executable, std::iter::empty::<&str>())
    }
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::os::unix::fs::PermissionsExt;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn executes_the_prebuilt_script_without_legacy_cli_arguments() {
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

        DiskoScript::new("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-disko")
            .unwrap()
            .destroy_format_mount(&Privilege::new(privilege).unwrap(), temporary.path())
            .unwrap();

        let arguments = fs::read_to_string(log).unwrap();
        assert!(arguments.contains("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-disko"));
        assert!(!arguments.contains("--mode"));
    }
}
