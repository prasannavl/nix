use std::path::PathBuf;

use anyhow::{Result, bail};

use crate::cmd;
use crate::command::CommandResult;

#[derive(Clone, Debug)]
pub struct Systemd {
    systemctl: PathBuf,
}

impl Systemd {
    pub fn new(systemctl: impl Into<PathBuf>) -> Result<Self> {
        let systemctl = systemctl.into();
        if !systemctl.is_absolute() {
            bail!("systemctl executable must be absolute");
        }
        Ok(Self { systemctl })
    }

    pub fn reboot_no_block(&self) -> Result<CommandResult> {
        cmd!(&self.systemctl, "reboot", "--no-block").output()
    }
}
