//! Root-only one-shot launch/delivery records. Missing or uncertain records are
//! never recreated by observation. No queue, retry worker or source payloads.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::PathBuf;

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{Begin, MAX_FRAME, Phase, Policy, Status};
use crate::build_executor::{Ownership, daemon, source_transport::Receipt};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub version: u32,
    pub uid: u32,
    pub input: Begin,
    pub phase: Phase,
    pub cancelled: bool,
    pub invocation: Option<String>,
    pub ownership: Option<Ownership>,
    pub cutoff: Option<u64>,
    pub delivery_claim: Option<String>,
    pub receipt: Option<Receipt>,
    pub settled_at: Option<u64>,
    pub builder_stopped: bool,
    pub data_released: bool,
    pub acknowledged: bool,
}

impl Record {
    pub fn status(self) -> Result<Status> {
        Ok(Status {
            attempt: self.input.request.attempt_id()?,
            request_digest: self.input.request.digest()?,
            phase: self.phase,
            cancelled: self.cancelled,
            delivery_claim: self.delivery_claim,
            receipt: self.receipt,
            data_released: self.data_released,
        })
    }

    pub fn cleanup_allowed(&self) -> bool {
        self.phase.terminal()
            && (self.receipt.is_some() || self.delivery_claim.is_none() || self.builder_stopped)
    }

    pub(super) fn revoke(&mut self, now: u64) {
        self.cancelled = true;
        if self.phase == Phase::Claimed {
            // Running is committed before any source effect. A late StartUnit
            // can enter only start(), which now rejects this permanent fence.
            self.phase = Phase::Revoked;
            self.settled_at = Some(now);
            self.data_released = true;
        }
    }

    pub(super) fn start(&mut self, invocation: &str) -> Result<()> {
        ensure!(
            self.phase == Phase::Claimed && !self.cancelled,
            "capture launch already consumed or revoked"
        );
        self.phase = Phase::Running;
        self.invocation = Some(invocation.to_owned());
        Ok(())
    }

    fn validate(&self) -> Result<()> {
        self.input.validate()?;
        ensure!(self.version == 1 && self.uid > 0, "invalid capture record");
        if let Some(invocation) = &self.invocation {
            ensure!(
                invocation.len() == 32 && invocation.bytes().all(|b| b.is_ascii_hexdigit()),
                "invalid capture invocation"
            );
        }
        ensure!(
            matches!(self.phase, Phase::Claimed | Phase::Revoked) == self.invocation.is_none()
                && self.ownership.is_some() == self.cutoff.is_some(),
            "incomplete capture lifetime"
        );
        ensure!(
            self.phase.terminal() == self.settled_at.is_some()
                && (!self.data_released || self.cleanup_allowed())
                && (!self.acknowledged || self.phase.terminal()),
            "invalid capture retirement state"
        );
        ensure!(
            self.phase != Phase::Revoked
                || (self.cancelled
                    && self.ownership.is_none()
                    && self.delivery_claim.is_none()
                    && self.receipt.is_none()
                    && self.data_released),
            "revoked capture has execution effects"
        );
        if let Some(owner) = &self.ownership {
            owner.validate(&self.input.request.attempt_id()?)?;
            ensure!(
                owner.builder_id == self.input.request.builder.host_id
                    && owner.store_id == self.input.request.storage.store_id,
                "capture ownership differs"
            );
        }
        if let Some(digest) = &self.delivery_claim {
            crate::build_executor::digest(digest)?;
            ensure!(
                self.ownership.is_some(),
                "delivery precedes admission verification"
            );
        }
        if let Some(receipt) = &self.receipt {
            ensure!(
                receipt.version == 1
                    && receipt.attempt_id == self.input.request.attempt_id()?
                    && receipt.request_digest == self.input.request.digest()?
                    && self.delivery_claim.as_deref() == Some(receipt.material_digest.as_str()),
                "capture receipt differs"
            );
        }
        ensure!(
            serde_json::to_vec(self)?.len() <= MAX_FRAME + 4096,
            "capture record exceeds bound"
        );
        Ok(())
    }
}

pub struct State {
    root: PathBuf,
    policy: Policy,
}

impl State {
    pub fn open(policy: &Policy) -> Result<Self> {
        ensure!(
            unsafe { libc::geteuid() } == 0,
            "capture authority requires root"
        );
        let root = &policy.state;
        daemon::trusted_path(root)?;
        let metadata = fs::symlink_metadata(root)?;
        ensure!(
            metadata.is_dir()
                && metadata.uid() == 0
                && metadata.mode() & 0o077 == 0
                && fs::canonicalize(root)? == *root,
            "capture state is not private"
        );
        Ok(Self {
            root: root.clone(),
            policy: policy.clone(),
        })
    }

    fn lock(&self) -> Result<File> {
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(self.root.join("lock"))?;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        loop {
            if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                return Ok(lock);
            }
            let error = std::io::Error::last_os_error();
            ensure!(
                matches!(
                    error.raw_os_error(),
                    Some(libc::EWOULDBLOCK) | Some(libc::EINTR)
                ) && std::time::Instant::now() < deadline,
                "capture state busy"
            );
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
    }

    pub fn directory(&self, attempt: &str) -> Result<PathBuf> {
        crate::build_executor::digest(attempt)?;
        Ok(self.root.join(attempt))
    }

    pub fn read(&self, attempt: &str) -> Result<Record> {
        let directory = self.directory(attempt)?;
        let metadata = fs::symlink_metadata(&directory)?;
        ensure!(
            metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o077 == 0,
            "capture directory differs"
        );
        let mut bytes = Vec::new();
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(directory.join("record"))?;
        let meta = file.metadata()?;
        ensure!(
            meta.is_file() && meta.uid() == 0 && meta.nlink() == 1 && meta.mode() & 0o077 == 0,
            "capture record is not private"
        );
        file.take((MAX_FRAME + 4097) as u64)
            .read_to_end(&mut bytes)?;
        ensure!(
            bytes.len() <= MAX_FRAME + 4096,
            "capture record exceeds bound"
        );
        let record: Record = serde_json::from_slice(&bytes)
            .map_err(|_| anyhow::anyhow!("invalid capture record"))?;
        record.validate()?;
        ensure!(
            record.input.request.attempt_id()? == attempt,
            "capture attempt differs"
        );
        Ok(record)
    }

    fn save(&self, record: &Record) -> Result<()> {
        record.validate()?;
        let directory = self.directory(&record.input.request.attempt_id()?)?;
        let temporary = directory.join("record.next");
        if temporary.try_exists()? {
            // All writers hold the state lock. A prior unrenamed temporary was
            // never authoritative: no launch/upload follows an uncommitted save.
            // Remove only the bounded root-owned scratch, never adopt its data.
            let metadata = fs::symlink_metadata(&temporary)?;
            ensure!(
                metadata.is_file()
                    && metadata.uid() == 0
                    && metadata.nlink() == 1
                    && metadata.mode() & 0o077 == 0,
                "capture transaction scratch differs"
            );
            fs::remove_file(&temporary)?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(record)?)?;
        file.sync_all()?;
        fs::rename(temporary, directory.join("record"))?;
        File::open(directory)?.sync_all()?;
        Ok(())
    }

    /// Return false for exact existing state; never repeat a lost StartUnit.
    pub fn begin(&self, uid: u32, input: Begin) -> Result<(bool, Status)> {
        self.claim(uid, input, false)
    }

    /// No-launch fence also covers a caller crash before delivery of Begin.
    /// Exact existing Running scopes receive stop intent, never false settlement.
    pub fn revoke(&self, uid: u32, input: Begin) -> Result<Status> {
        self.claim(uid, input, true).map(|(_, status)| status)
    }

    fn claim(&self, uid: u32, input: Begin, revoke: bool) -> Result<(bool, Status)> {
        input.validate()?;
        let _lock = self.lock()?;
        let attempt = input.request.attempt_id()?;
        let directory = self.directory(&attempt)?;
        let exists = directory.try_exists()?;
        if exists && self.committed(&attempt, revoke)? {
            let mut old = self.read(&attempt)?;
            ensure!(
                old.uid == uid
                    && old.input.request == input.request
                    && old.input.ownership == input.ownership
                    && old.input.reserved_at == input.reserved_at
                    && old.input.pending == input.pending,
                "capture intent conflict"
            );
            if revoke {
                old.revoke(daemon::now()?);
                self.save(&old)?;
            }
            return Ok((false, old.status()?));
        }
        let now = daemon::now()?;
        let (clock_floor, issued_floor) = self.replay_floor()?;
        ensure!(
            revoke
                || (input.request.id.issued_at > issued_floor
                    && now.max(clock_floor) <= self.latest_begin(&input)?
                    && input.request.id.issued_at <= now.saturating_add(self.policy.max_seconds)),
            "capture request expired or future-dated"
        );
        let mut count = 0;
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            count += 1;
            ensure!(
                count < 64 || (exists && count == 64),
                "capture retention capacity reached"
            );
            let name = entry.file_name();
            let name = name.to_str().context("invalid capture state entry")?;
            if name.starts_with("expired-") {
                continue;
            }
            if !revoke {
                ensure!(
                    self.read(name)?.phase.terminal(),
                    "prior local capture is unresolved"
                );
            }
        }
        if !exists {
            fs::DirBuilder::new().mode(0o700).create(&directory)?;
            File::open(&self.root)?.sync_all()?;
        }
        let mut record = Record {
            version: 1,
            uid,
            input,
            phase: Phase::Claimed,
            cancelled: false,
            invocation: None,
            ownership: None,
            cutoff: None,
            delivery_claim: None,
            receipt: None,
            settled_at: None,
            builder_stopped: false,
            data_released: false,
            acknowledged: false,
        };
        if revoke {
            record.revoke(now.max(clock_floor));
        }
        self.save(&record)?;
        Ok((!revoke, record.status()?))
    }

    /// Only revocation can recover an interrupted initial metadata transaction.
    /// StartUnit follows the durable record; no committed record => no launch.
    fn committed(&self, attempt: &str, revoke: bool) -> Result<bool> {
        let directory = self.directory(attempt)?;
        match fs::symlink_metadata(directory.join("record")) {
            Ok(_) => return Ok(true),
            Err(error) if revoke && error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let metadata = fs::symlink_metadata(&directory)?;
        ensure!(
            metadata.is_dir() && metadata.uid() == 0 && metadata.mode() & 0o077 == 0,
            "uncommitted capture directory differs"
        );
        let mut entries = fs::read_dir(directory)?;
        if let Some(entry) = entries.next() {
            ensure!(
                entry?.file_name() == "record.next",
                "uncommitted capture has data"
            );
        }
        ensure!(
            entries.next().is_none(),
            "uncommitted capture has extra entries"
        );
        Ok(false)
    }

    pub fn update<T>(
        &self,
        attempt: &str,
        change: impl FnOnce(&mut Record) -> Result<T>,
    ) -> Result<T> {
        let _lock = self.lock()?;
        let mut record = self.read(attempt)?;
        let result = change(&mut record)?;
        self.save(&record)?;
        Ok(result)
    }

    fn latest_begin(&self, input: &Begin) -> Result<u64> {
        // Request-only horizon: a later installation increasing capture limits
        // must not make an already pruned attempt eligible to launch again.
        input
            .request
            .id
            .issued_at
            .checked_add(input.request.deadlines.queue_seconds)
            .and_then(|time| time.checked_add(input.request.deadlines.runtime_seconds))
            .context("capture replay cutoff overflow")
    }

    fn replay_floor(&self) -> Result<(u64, u64)> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(self.root.join("replay-floor"))
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok((0, 0)),
            Err(error) => return Err(error.into()),
        };
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file()
                && metadata.uid() == 0
                && metadata.nlink() == 1
                && metadata.mode() & 0o077 == 0
                && metadata.len() <= 64,
            "capture replay floor differs"
        );
        let mut bytes = String::new();
        file.take(65).read_to_string(&mut bytes)?;
        ensure!(bytes.len() <= 64, "capture replay floor exceeds bound");
        Ok(serde_json::from_str(&bytes)?)
    }

    fn advance_replay_floor(&self, now: u64, issued: u64) -> Result<()> {
        let old = self.replay_floor()?;
        let next = (old.0.max(now), old.1.max(issued));
        if old == next {
            return Ok(());
        }
        let temporary = self.root.join("replay-floor.next");
        if temporary.try_exists()? {
            let metadata = fs::symlink_metadata(&temporary)?;
            ensure!(
                metadata.is_file()
                    && metadata.uid() == 0
                    && metadata.nlink() == 1
                    && metadata.mode() & 0o077 == 0,
                "capture replay transaction differs"
            );
            fs::remove_file(&temporary)?;
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&temporary)?;
        file.write_all(&serde_json::to_vec(&next)?)?;
        file.sync_all()?;
        fs::rename(temporary, self.root.join("replay-floor"))?;
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }

    pub fn attempts(&self) -> Result<Vec<String>> {
        let mut attempts = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| anyhow::anyhow!("invalid capture state entry"))?;
            if let Some(attempt) = name.strip_prefix("expired-") {
                crate::build_executor::digest(attempt)?;
            } else {
                crate::build_executor::digest(&name)?;
            }
            attempts.push(name);
            ensure!(attempts.len() <= 64, "capture metadata exceeds bound");
        }
        Ok(attempts)
    }

    /// May resume partial deletion, but only after durable positive settlement
    /// and authenticated intake (or a settled stop/no upload). Never recaptures.
    pub fn release_data(&self, attempt: &str, deadline: std::time::Instant) -> Result<()> {
        let _lock = self.lock()?;
        let mut record = self.read(attempt)?;
        ensure!(
            record.cleanup_allowed(),
            "capture data still has uncertain ownership"
        );
        if record.data_released {
            return Ok(());
        }
        super::cleanup::remove_data(
            &self.directory(attempt)?,
            record.uid,
            u64::from(self.policy.limits.entries)
                .saturating_mul(16)
                .clamp(4096, 1_000_000),
            self.policy.limits.depth.saturating_add(16),
            deadline,
            true,
        )?;
        record.data_released = true;
        self.save(&record)
    }

    pub fn prune(&self, name: &str, deadline: std::time::Instant) -> Result<()> {
        let _lock = self.lock()?;
        let expired = if let Some(attempt) = name.strip_prefix("expired-") {
            crate::build_executor::digest(attempt)?;
            self.root.join(name)
        } else {
            let record = self.read(name)?;
            // Retain the only positive local-settlement proof until its caller
            // has durably reconciled the receipt or settled cancellation.
            if !record.acknowledged {
                return Ok(());
            }
            ensure!(
                record.data_released && record.phase.terminal(),
                "capture retirement incomplete"
            );
            let after = self
                .latest_begin(&record.input)?
                .max(record.settled_at.context("capture settlement missing")?)
                .checked_add(self.policy.retention_seconds)
                .context("capture retention overflow")?;
            let now = daemon::now()?.max(self.replay_floor()?.0);
            if now <= after {
                return Ok(());
            }
            // Durable before forgetting an ID: wall-clock rollback cannot make
            // a retired attempt launchable again. One bounded global watermark,
            // not an indefinitely growing list of old attempt IDs.
            self.advance_replay_floor(now, record.input.request.id.issued_at)?;
            let expired = self.root.join(format!("expired-{name}"));
            ensure!(!expired.try_exists()?, "capture tombstone already exists");
            fs::rename(self.directory(name)?, &expired)?;
            File::open(&self.root)?.sync_all()?;
            expired
        };
        super::cleanup::remove_data(&expired, 0, 8, 1, deadline, false)?;
        fs::remove_dir(expired)?;
        File::open(&self.root)?.sync_all()?;
        Ok(())
    }

    pub fn acknowledge(
        &self,
        uid: u32,
        request: &crate::build_executor::native_intent::Request,
    ) -> Result<Option<Status>> {
        request.validate()?;
        let attempt = request.attempt_id()?;
        let _lock = self.lock()?;
        let directory = self.directory(&attempt)?;
        match fs::symlink_metadata(&directory) {
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Absence alone is insufficient. The floor is durable before
                // pruning and excludes every later Begin with this original ID.
                ensure!(
                    request.id.issued_at <= self.replay_floor()?.1,
                    "capture retention closure is unconfirmed"
                );
                return Ok(None);
            }
            Err(error) => return Err(error.into()),
        }
        let mut record = self.read(&attempt)?;
        ensure!(
            record.uid == uid
                && record.input.request == *request
                && record.phase.terminal()
                && record.data_released,
            "capture acknowledgement lacks original settlement/data release"
        );
        record.acknowledged = true;
        self.save(&record)?;
        record.status().map(Some)
    }

    pub fn status(&self, uid: u32, attempt: &str, digest: &str, cancel: bool) -> Result<Status> {
        crate::build_executor::digest(digest)?;
        if cancel {
            self.update(attempt, |record| {
                ensure!(
                    record.uid == uid && record.input.request.digest()? == digest,
                    "capture caller differs"
                );
                record.revoke(daemon::now()?);
                Ok(())
            })?;
        }
        let record = self.read(attempt)?;
        ensure!(
            record.uid == uid && record.input.request.digest()? == digest,
            "capture caller differs"
        );
        record.status()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::build_executor::{journal::tests::request, native_intent};

    fn claimed() -> Record {
        let resolved = request("capture-revocation");
        let request = native_intent::Request {
            version: 1,
            executor_version: 1,
            controller_service: false,
            bootstrap_digest: Some("a".repeat(64)),
            caller_digest: Some("b".repeat(64)),
            id: resolved.id,
            run_id: "1".repeat(32),
            issuer: resolved.issuer,
            repository_id: resolved.repository_id,
            controller: resolved.controller,
            builder: resolved.builder,
            storage: resolved.storage,
            action: resolved.evaluation.action,
            invocation: serde_json::json!({"action": "build", "options": {}}),
            nix: resolved.nix,
            policy_digest: resolved.policy_digest,
            deadlines: resolved.deadlines,
            owner: resolved.owner,
        };
        let ownership = Ownership {
            executor_version: 1,
            builder_id: request.builder.host_id.clone(),
            store_id: request.storage.store_id.clone(),
            attempt_id: request.attempt_id().unwrap(),
            pool_epoch: 1.try_into().unwrap(),
            boot_id: "fixture-boot".into(),
        };
        let record = Record {
            version: 1,
            uid: 2700,
            input: Begin {
                request,
                ownership,
                reserved_at: 1001,
                pending: serde_json::json!({}),
            },
            phase: Phase::Claimed,
            cancelled: false,
            invocation: None,
            ownership: None,
            cutoff: None,
            delivery_claim: None,
            receipt: None,
            settled_at: None,
            builder_stopped: false,
            data_released: false,
            acknowledged: false,
        };
        record.validate().unwrap();
        record
    }

    #[test]
    fn revocation_before_start_permanently_closes_the_source_launch() {
        let mut record = claimed();
        let original = serde_json::to_vec(&record.input).unwrap();
        record.revoke(1002);
        record.validate().unwrap();
        assert_eq!(record.phase, Phase::Revoked);
        assert!(record.cleanup_allowed() && record.data_released);
        assert!(record.invocation.is_none() && record.receipt.is_none());
        assert!(record.start(&"c".repeat(32)).is_err());
        record.revoke(2000);
        assert_eq!(record.settled_at, Some(1002));
        assert_eq!(serde_json::to_vec(&record.input).unwrap(), original);
        // No executed-worker receipt may be inferred from a no-launch fence.
        record.phase = Phase::Settled;
        assert!(record.validate().is_err());
    }

    #[test]
    fn revocation_after_start_is_only_stop_intent_not_settlement() {
        let mut record = claimed();
        record.start(&"c".repeat(32)).unwrap();
        record.revoke(1002);
        record.validate().unwrap();
        assert!(record.cancelled);
        assert_eq!(record.phase, Phase::Running);
        assert_eq!(record.invocation.as_deref(), Some("c".repeat(32).as_str()));
        assert!(!record.cleanup_allowed() && !record.data_released);
        assert!(record.settled_at.is_none() && record.receipt.is_none());
        assert!(record.start(&"d".repeat(32)).is_err());
        record.phase = Phase::Revoked;
        record.settled_at = Some(1002);
        record.data_released = true;
        assert!(record.validate().is_err());
    }
}
