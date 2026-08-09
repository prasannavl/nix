use std::path::PathBuf;

use anyhow::{Result, bail};

use crate::cmd;
use crate::command::CommandResult;

#[derive(Clone, Debug)]
pub struct NixCollectGarbage {
    executable: PathBuf,
}

impl NixCollectGarbage {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("nix-collect-garbage executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn delete_all(&self) -> Result<CommandResult> {
        cmd!(&self.executable, "-d").output()
    }

    pub fn delete_older_than(&self, age: &str) -> Result<CommandResult> {
        cmd!(&self.executable, "--delete-older-than", age).output()
    }
}
