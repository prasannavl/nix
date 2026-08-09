use std::path::{Path, PathBuf};

use abird_host_agent::cmd;
use anyhow::{Result, bail};

#[derive(Clone, Debug)]
pub struct Age {
    executable: PathBuf,
}

impl Age {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("age executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn decrypt(&self, source: &Path, identity: &Path, destination: &Path) -> Result<()> {
        let result = cmd!(
            &self.executable,
            "--decrypt",
            "--identity",
            identity,
            "--output",
            destination,
            source
        )
        .output()?;
        if !result.success {
            bail!("age decryption failed: {}", result.stderr.trim());
        }
        Ok(())
    }
}
