//! Installed caller-only capture authority. No build pool, daemon, evaluation or
//! scheduler. One immutable builder admission owns one fixed local unit.

use std::collections::BTreeMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{controller_service::Account, daemon, native_intent, private_tree};

mod cleanup;
mod control;
mod execution;
pub mod relay;
mod state;
pub use super::stage::Stage;
pub use control::{client, client_until, serve};
pub use execution::{
    Execution, TransportScope, caller_credentials, reconcile_unit, require_placement,
    require_reaper_placement,
};
pub use state::{Record, State};

pub const POLICY: &str = "/etc/abird-owned-capture.json";
pub const SOCKET: &str = "/run/abird-owned-capture/control";
pub const MAX_FRAME: usize = 256 * 1024;
pub const TEMPLATE: &str = "abird-owned-capture@.service";

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Caller {
    pub account: Account,
    pub bootstrap: PathBuf,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub version: u32,
    pub state: PathBuf,
    pub manager: PathBuf,
    pub git: PathBuf,
    pub nar: PathBuf,
    pub nar_configuration: PathBuf,
    /// Root-installed closureInfo store-paths manifest for offline read scopes.
    pub runtime_closure: PathBuf,
    pub systemctl: PathBuf,
    pub callers: BTreeMap<u32, Caller>,
    /// Runtime reference only. Never a store path or a source-helper binding.
    pub relay_key: PathBuf,
    pub relay_user: String,
    pub relay_port: u16,
    pub max_seconds: u64,
    pub retention_seconds: u64,
    pub limits: private_tree::Limits,
}

impl Policy {
    pub fn load() -> Result<Self> {
        let value: Self = serde_json::from_slice(&daemon::read_declaration(Path::new(POLICY))?)
            .map_err(|_| anyhow::anyhow!("invalid capture declaration"))?;
        value.validate()?;
        Ok(value)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.version == 1
                && self.relay_port > 0
                && (1..=86400).contains(&self.max_seconds)
                && (60..=86400).contains(&self.retention_seconds),
            "invalid capture policy"
        );
        daemon::store_path(&self.runtime_closure)?;
        daemon::trusted_path(&self.runtime_closure)?;
        absolute(&self.state)?;
        ensure!(
            self.state
                .ends_with("abird/abird-host-manager/owned-capture"),
            "invalid capture state root"
        );
        for program in [
            &self.manager,
            &self.git,
            &self.nar,
            &self.systemctl,
            &self.nar_configuration,
        ] {
            absolute(program)?;
            ensure!(
                program.starts_with("/nix/store"),
                "capture executable/configuration is not pinned"
            );
            daemon::trusted_path(program)?;
        }
        validate_ssh_path(&self.relay_key)?;
        ensure!(
            !self.relay_key.starts_with("/nix/store"),
            "relay credential must not enter the store"
        );
        ensure!(
            !self.relay_user.is_empty()
                && self.relay_user.len() <= 64
                && self
                    .relay_user
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b)),
            "invalid relay login"
        );
        self.limits.validate()?;
        ensure!(
            !self.callers.is_empty() && self.callers.len() <= 16,
            "invalid capture caller count"
        );
        for (uid, caller) in &self.callers {
            let account = &caller.account;
            ensure!(
                *uid > 0
                    && *uid == account.uid
                    && account.gid > 0
                    && account.groups.len() <= 64
                    && !account.capture_roots.is_empty()
                    && account.capture_roots.len() <= 16,
                "invalid capture account"
            );
            for path in [&account.home, &account.state_home, &caller.bootstrap] {
                absolute(path)?;
            }
            ensure!(
                caller.bootstrap.starts_with("/nix/store"),
                "capture bootstrap is not immutable"
            );
            for root in &account.capture_roots {
                absolute(root)?;
                ensure!(root.components().count() > 2, "capture root too broad");
            }
        }
        Ok(())
    }

    pub fn caller(&self, uid: u32) -> Result<&Caller> {
        self.callers
            .get(&uid)
            .context("capture caller not installed")
    }
}

/// SSH must open the same path whose authority was checked, not expand tokens,
/// environment variables, quoting, escapes or a whitespace-separated file list.
pub fn validate_ssh_path(path: &Path) -> Result<()> {
    absolute(path)?;
    ensure!(
        path.to_str()
            .is_some_and(|text| text.chars().all(|character| !character.is_control()
                && !character.is_whitespace()
                && !['%', '$', '\\', '\'', '"'].contains(&character))),
        "capture SSH file references must be literal"
    );
    Ok(())
}

/// Validate the fixed SSH client reference used by privileged capture transport.
/// Metadata-only qualification, not a general daemon/store authority API.
pub fn trusted_ssh_program(path: &Path) -> Result<()> {
    trusted_ssh_file(path, false)?;
    let resolved = std::fs::canonicalize(path)?;
    daemon::store_path(&resolved)?;
    ensure!(
        path.file_name().is_some_and(|name| name == "ssh")
            && std::fs::metadata(&resolved)?.mode() & 0o111 != 0,
        "capture SSH client is not an installed executable"
    );
    Ok(())
}

/// Filesystem authority only; never read credential contents. Writable/sticky
/// caller namespaces are rejected. The sole writable-ancestor exception is the
/// canonical Nix store directory, for root-approved immutable public trust.
pub fn trusted_ssh_file(path: &Path, private: bool) -> Result<()> {
    validate_ssh_path(path)?;
    let resolved = std::fs::canonicalize(path)?;
    let mut pending = vec![path.to_owned(), resolved.clone()];
    let mut visited = std::collections::BTreeSet::new();
    let mut components = 0usize;
    while let Some(name) = pending.pop() {
        if !visited.insert(name.clone()) {
            continue;
        }
        ensure!(
            visited.len() <= 64,
            "capture SSH authority link bound exceeded"
        );
        for ancestor in name.ancestors() {
            components += 1;
            ensure!(
                components <= 2048,
                "capture SSH authority ancestry bound exceeded"
            );
            let metadata = std::fs::symlink_metadata(ancestor)?;
            let store = !private
                && metadata.is_dir()
                && metadata.mode() & 0o002 == 0
                && metadata.mode() & 0o1000 != 0
                && std::fs::canonicalize(ancestor)? == Path::new("/nix/store");
            ensure!(
                metadata.uid() == 0
                    && (metadata.file_type().is_symlink() || metadata.mode() & 0o022 == 0 || store),
                "capture SSH authority has writable ancestry"
            );
            if metadata.file_type().is_symlink() {
                // Canonical paths alone hide transit namespaces: a root link
                // may traverse a caller-owned intermediate link and end at a
                // protected file. Qualify every raw target ancestry as well.
                let target = std::fs::read_link(ancestor)?;
                pending.push(if target.is_absolute() {
                    target
                } else {
                    ancestor
                        .parent()
                        .context("SSH authority link has no parent")?
                        .join(target)
                });
                ensure!(
                    pending.len() <= 128,
                    "capture SSH authority link bound exceeded"
                );
            }
        }
    }
    let metadata = std::fs::metadata(&resolved)?;
    ensure!(
        metadata.is_file() && metadata.uid() == 0 && metadata.mode() & 0o022 == 0,
        "capture SSH authority is not a protected regular file"
    );
    if private {
        ensure!(
            !path.starts_with("/nix/store")
                && !resolved.starts_with("/nix/store")
                && std::fs::symlink_metadata(path)?.is_file()
                && metadata.mode() & 0o077 == 0
                && metadata.nlink() == 1,
            "relay key is not private runtime material"
        );
    }
    Ok(())
}

pub fn unit(attempt: &str) -> Result<String> {
    super::digest(attempt)?;
    Ok(format!("abird-owned-capture@{attempt}.service"))
}

pub(super) fn absolute(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.to_str().is_some()
            && path
                .components()
                .all(|c| matches!(c, Component::RootDir | Component::Normal(_))),
        "noncanonical capture path"
    );
    Ok(())
}

/// Local private metadata, not a source image or a remote credential channel.
/// The manager validates `pending` against caller_digest before source effects.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Begin {
    pub request: native_intent::Request,
    pub ownership: super::Ownership,
    pub reserved_at: u64,
    pub pending: serde_json::Value,
}

impl Begin {
    pub fn validate(&self) -> Result<()> {
        self.request.validate()?;
        self.ownership.validate(&self.request.attempt_id()?)?;
        ensure!(
            self.reserved_at > 0
                && self
                    .reserved_at
                    .checked_add(self.request.deadlines.runtime_seconds)
                    .is_some()
                && self
                    .request
                    .id
                    .issued_at
                    .checked_add(self.request.deadlines.queue_seconds)
                    .and_then(|time| time.checked_add(self.request.deadlines.runtime_seconds))
                    .is_some()
                && self.ownership.builder_id == self.request.builder.host_id
                && self.ownership.store_id == self.request.storage.store_id,
            "capture claim ownership differs"
        );
        ensure!(
            self.request.bootstrap_digest.is_some()
                && self.request.caller_digest.is_some()
                && self.request.controller != self.request.builder
                && !self.request.controller_service
                && self.pending.is_object()
                && serde_json::to_vec(self)?.len() <= MAX_FRAME,
            "capture requires installed remote native admission"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    Check,
    Begin {
        input: Box<Begin>,
    },
    /// Close a claimed (possibly never delivered) launch before observing cleanup.
    Revoke {
        input: Box<Begin>,
    },
    Status {
        attempt: String,
        request_digest: String,
    },
    Cancel {
        attempt: String,
        request_digest: String,
    },
    Acknowledge {
        request: Box<native_intent::Request>,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Claimed,
    Running,
    Settled,
    /// Durable no-launch fence, not a receipt for an executed worker.
    Revoked,
}

impl Phase {
    pub fn terminal(self) -> bool {
        matches!(self, Self::Settled | Self::Revoked)
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Status {
    pub attempt: String,
    pub request_digest: String,
    pub phase: Phase,
    pub cancelled: bool,
    pub delivery_claim: Option<String>,
    pub receipt: Option<super::source_transport::Receipt>,
    pub data_released: bool,
}

impl Status {
    pub fn validate_for(&self, request: &native_intent::Request) -> Result<()> {
        ensure!(
            self.attempt == request.attempt_id()? && self.request_digest == request.digest()?,
            "capture status identity differs"
        );
        ensure!(
            self.phase.terminal() || !self.data_released,
            "live capture data was released"
        );
        if let Some(claim) = &self.delivery_claim {
            super::digest(claim)?;
            ensure!(
                self.phase != Phase::Claimed && self.phase != Phase::Revoked,
                "capture delivery precedes execution"
            );
        }
        if let Some(receipt) = &self.receipt {
            ensure!(
                self.phase == Phase::Settled
                    && receipt.version == 1
                    && receipt.attempt_id == self.attempt
                    && receipt.request_digest == self.request_digest
                    && self.delivery_claim.as_ref() == Some(&receipt.material_digest),
                "capture receipt differs"
            );
        }
        ensure!(
            self.phase != Phase::Revoked
                || (self.cancelled
                    && self.data_released
                    && self.delivery_claim.is_none()
                    && self.receipt.is_none()),
            "revoked capture has execution effects"
        );
        Ok(())
    }
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Reply {
    Ready,
    Status {
        status: Box<Status>,
    },
    /// No record remains and the durable replay floor excludes this ID. This
    /// closes metadata retention, never fabricates source execution or intake.
    RetentionClosed {
        attempt: String,
        request_digest: String,
    },
    Rejected,
    Unconfirmed,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protected_leaf_does_not_qualify_caller_writable_ancestry() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o1777))
            .unwrap();
        let file = directory.path().join("ssh");
        std::fs::write(&file, b"disposable non-credential fixture").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o500)).unwrap();
        assert!(trusted_ssh_file(&file, false).is_err());
        assert!(trusted_ssh_file(&file, true).is_err());
        assert!(trusted_ssh_program(&file).is_err());
        let alias = directory.path().join("alias");
        symlink(&file, &alias).unwrap();
        assert!(trusted_ssh_file(&alias, false).is_err());
        assert!(trusted_ssh_file(&alias, true).is_err());
    }

    #[test]
    fn ssh_authority_paths_are_not_expanded_or_split_after_validation() {
        validate_ssh_path(Path::new("/run/keys/capture-relay")).unwrap();
        for path in [
            "/run/keys/%h",
            "/run/keys/${HOME}",
            "/etc/pinned /home/caller/known-hosts",
            "/etc/a\\ b",
            "/etc/'quoted'",
        ] {
            assert!(validate_ssh_path(Path::new(path)).is_err());
        }
    }
}
