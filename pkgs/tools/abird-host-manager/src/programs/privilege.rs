use std::ffi::OsStr;
use std::path::{Path, PathBuf};

use abird_host_agent::command::{CommandResult, CommandSpec};
use anyhow::{Result, bail};

#[derive(Clone, Debug)]
pub struct Privilege {
    executable: PathBuf,
}

impl Privilege {
    pub fn new(executable: impl Into<PathBuf>) -> Result<Self> {
        let executable = executable.into();
        if !executable.is_absolute() {
            bail!("privilege executable must be absolute");
        }
        Ok(Self { executable })
    }

    pub fn run(
        &self,
        current_dir: &Path,
        program: &Path,
        arguments: impl IntoIterator<Item = impl AsRef<OsStr>>,
    ) -> Result<()> {
        if !program.is_absolute() {
            bail!("privileged child executable must be absolute");
        }
        CommandSpec::new(&self.executable)
            .arg("-n")
            .arg(program)
            .args(arguments)
            .current_dir(current_dir)
            .status_inherited()
    }

    pub fn output(
        &self,
        current_dir: &Path,
        program: &Path,
        arguments: impl IntoIterator<Item = impl AsRef<OsStr>>,
    ) -> Result<CommandResult> {
        if !program.is_absolute() {
            bail!("privileged child executable must be absolute");
        }
        CommandSpec::new(&self.executable)
            .arg("-n")
            .arg(program)
            .args(arguments)
            .current_dir(current_dir)
            .output()
    }
}
