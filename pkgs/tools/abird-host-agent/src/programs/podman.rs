use std::path::PathBuf;

use anyhow::{Result, bail};

use crate::cmd;
use crate::command::CommandResult;

#[derive(Clone, Debug)]
pub struct Podman {
    executable: PathBuf,
}

impl Podman {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("Podman executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn volume_names(&self) -> Result<CommandResult> {
        cmd!(&self.executable, "volume", "ls", "--format", "{{.Name}}").output()
    }

    pub fn containers_using_volume(&self, volume: &str) -> Result<CommandResult> {
        cmd!(
            &self.executable,
            "ps",
            "-aq",
            "--filter",
            format!("volume={volume}")
        )
        .output()
    }

    pub fn remove_volume(&self, volume: &str) -> Result<CommandResult> {
        cmd!(&self.executable, "volume", "rm", volume).output()
    }
}
