//! Bounded atomic metadata authority. No build, network, GC or systemd effects.
//!
//! Executor/recovery/release methods are trusted-adapter APIs, not caller verbs.
//! An I/O error is unconfirmed: reread by identity, never retry realization.

use std::collections::BTreeSet;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::num::NonZeroU64;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};

use super::events::{EventCursor, EventKind, EventPage, History, MAX_EVENT_PAGE};
use super::preparation::{Preparation, PreparedInputs};
use super::protocol::{Rejection, Unconfirmed};
use super::request::{AdmissionPolicy, BuildRequest, Owner, StorageIdentity};
use super::supervisor::{Active, Snapshot, StopProgress, StopStage};
use super::{
    ArtifactReceipt, Attempt, ClientExit, ExecutionHandle, Outcome, Ownership, Phase, PoolHealth,
    Record, Settlement, StopReason, digest, identifier,
};
use crate::sha256::digest_bytes;

mod abandonment;
pub(super) mod artifacts;
mod controller;
mod daemon;
mod diagnostics;
mod maintenance;
mod native_intent;
pub(super) mod native_phase;
pub(super) mod retirement;
mod sources;
mod verification;
pub(super) mod work;
use work::{Kind, Work};

const VERSION: u32 = 14;
const MAX_BYTES: usize = 16 * 1024 * 1024;
const MAX_JOBS: usize = 128;
const MAX_TOMBSTONES: usize = 4096;
// Reserve future inputs/events/terminal/source metadata before any effects.
const JOB_RESERVATION: usize = 120 * 1024
    + super::private_sources::MAX_ALLOCATION_BYTES
    + daemon::MAX_CLAIM_BYTES
    + verification::MAX_BYTES
    + native_phase::MAX_BYTES
    + artifacts::MAX_BYTES
    + artifacts::ACK_BYTES
    + native_intent::MAX_BYTES
    + controller::MAX_BYTES
    + retirement::MAX_BYTES;
const TOMBSTONE_RESERVATION: usize = 1024;
const SHARED_RESERVATION: usize = 16 * 1024;
const STATE: &str = "state.json";
const PENDING: &str = ".pending";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Acceptance {
    pub attempt_id: String,
    pub spec_digest: String,
    pub sequence: u64,
}

#[derive(Debug)]
pub enum JobStatus {
    Live {
        pool: PoolHealth,
        request: Option<Box<BuildRequest>>,
        prepared: Option<Box<Preparation>>,
        input: Option<super::source_transport::InputState>,
        attempt: Box<Attempt>,
        acceptance: Acceptance,
        accepted_at: u64,
        renewed_at: u64,
        reserved_at: Option<u64>,
        settled_at: Option<u64>,
    },
    Retired {
        pool: PoolHealth,
        acceptance: Acceptance,
        outcome: Outcome,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Pool {
    pub epoch: u64,
    pub health: PoolHealth,
    pub owner: Option<Ownership>,
    pub verified_boot: Option<String>,
    pub recovery_digest: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Job {
    request: Work,
    prepared: Option<Preparation>,
    stop: Option<StopProgress>,
    acceptance: Acceptance,
    attempt: Record,
    accepted_at: u64,
    renewed_at: u64,
    reserved_at: Option<u64>,
    settled_at: Option<u64>,
    release_digest: Option<String>,
    private_source: Option<super::private_sources::Allocation>,
    daemon_claim: Option<daemon::Claim>,
    verified: Option<verification::Verified>,
    native_phase: Option<native_phase::NativePhase>,
    artifact: Option<artifacts::Publication>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumer_ack: Option<artifacts::Acknowledged>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumer_abandonment: Option<abandonment::Abandoned>,
    native_resolution: Option<native_intent::Resolution>,
    controller: Option<controller::Claim>,
    retirement: Option<retirement::Record>,
    successor: Option<String>,
    events: History,
}

impl Job {
    fn apply(
        &mut self,
        detail: EventKind,
        now: u64,
        change: impl FnOnce(&mut Attempt) -> Result<()>,
    ) -> Result<()> {
        let mut attempt = Attempt(self.attempt.clone());
        change(&mut attempt)?;
        if self.attempt != attempt.0 {
            if attempt.phase() == Phase::Stopping && self.stop.is_none() {
                self.stop = Some(StopProgress {
                    requested_at: now,
                    advanced_at: now,
                    stage: StopStage::Requested,
                });
            }
            self.events.push(detail, now)?;
            self.attempt = attempt.0;
        }
        Ok(())
    }

    fn phase(&self) -> Phase {
        Attempt(self.attempt.clone()).phase()
    }
    fn outcome(&self) -> Option<Outcome> {
        Attempt(self.attempt.clone()).outcome().cloned()
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Tombstone {
    maintenance: bool,
    issuer: String,
    issued_at: u64,
    acceptance: Acceptance,
    outcome: Outcome,
    last_event: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumer_ack: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumer_abandonment: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    consumer_release: Option<String>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct State {
    version: u32,
    identity: StorageIdentity,
    policy: AdmissionPolicy,
    revision: u64,
    last_time: u64,
    replay_floor: u64,
    pool: Pool,
    jobs: Vec<Job>,
    tombstones: Vec<Tombstone>,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    checksum: String,
    state: State,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CommitPoint {
    Created,
    Written,
    FileSynced,
    Renamed,
    DirectorySynced,
}

pub struct Journal {
    root: PathBuf,
    device: u64,
    inode: u64,
    identity: StorageIdentity,
    policy: AdmissionPolicy,
    // Some(Ok) preserves explicit test times; None exercises the production clock.
    #[cfg(test)]
    clock: Option<fn(u64) -> Result<u64>>,
    #[cfg(test)]
    fault: Option<fn(CommitPoint) -> Result<()>>,
}

impl Journal {
    /// Provision only a previously absent authority. Never reset an existing root.
    /// The parent must already exist in the resolved XDG namespace.
    pub fn initialize(
        root: &Path,
        identity: StorageIdentity,
        policy: AdmissionPolicy,
        now: u64,
    ) -> Result<Self> {
        identity.validate()?;
        policy.validate()?;
        ensure!(root.is_absolute(), "journal root must be absolute");
        let parent = root.parent().context("journal root has no parent")?;
        ensure!(
            fs::canonicalize(parent)? == parent,
            "journal parent must be canonical"
        );
        let parent = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(parent)?;
        let metadata = parent.metadata()?;
        ensure!(
            metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o022 == 0,
            "journal parent is not exclusively service-writable"
        );
        fs::DirBuilder::new().mode(0o700).create(root)?;
        parent.sync_all()?;
        let journal = Self::at(root, identity.clone(), policy.clone())?;
        let directory = journal.lock()?;
        let now = journal.effective_time(now, 0)?;
        journal.write(
            &directory,
            &State {
                version: VERSION,
                identity,
                policy,
                revision: 0,
                last_time: now,
                replay_floor: 0,
                pool: Pool {
                    epoch: 0,
                    health: PoolHealth::Quarantined,
                    owner: None,
                    verified_boot: None,
                    recovery_digest: None,
                },
                jobs: Vec::new(),
                tombstones: Vec::new(),
            },
        )?;
        Ok(journal)
    }

    pub fn open(root: &Path, identity: StorageIdentity, policy: AdmissionPolicy) -> Result<Self> {
        let journal = Self::at(root, identity, policy)?;
        let directory = journal.lock()?;
        journal.read(&directory)?;
        Ok(journal)
    }

    fn at(root: &Path, identity: StorageIdentity, policy: AdmissionPolicy) -> Result<Self> {
        identity.validate()?;
        policy.validate()?;
        ensure!(
            root.is_absolute() && fs::canonicalize(root)? == root,
            "journal root must be canonical"
        );
        let directory = open_directory(root)?;
        let metadata = directory.metadata()?;
        Ok(Self {
            root: root.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
            identity,
            policy,
            #[cfg(test)]
            clock: Some(Ok),
            #[cfg(test)]
            fault: None,
        })
    }

    // Call under lock, after reading any existing authority. Captures before slow
    // effects/lock waits never decide production deadlines, even if >= last.
    // Unit tests explicitly inject time; never infer clock mode from its value.
    fn effective_time(&self, captured: u64, last: u64) -> Result<u64> {
        let now = self.sample_time(captured)?;
        ensure!(now >= last, Rejection::ClockRegressed);
        Ok(now)
    }

    fn sample_time(&self, _captured: u64) -> Result<u64> {
        #[cfg(test)]
        if let Some(clock) = self.clock {
            return clock(_captured);
        }
        Ok(std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_secs())
    }

    fn lock(&self) -> Result<File> {
        // Fresh descriptor per transaction: threads must not share one flock owner.
        let directory = open_directory(&self.root)?;
        directory.lock()?;
        let metadata = directory.metadata()?;
        ensure!(
            metadata.dev() == self.device && metadata.ino() == self.inode,
            "journal directory replaced"
        );
        ensure!(
            fs::canonicalize(&self.root)? == self.root,
            "journal root redirected"
        );
        Ok(directory)
    }

    fn read(&self, directory: &File) -> Result<State> {
        let mut file = private_file(&self.root.join(STATE))?;
        let mut bytes = Vec::new();
        (&mut file)
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)?;
        ensure!(bytes.len() <= MAX_BYTES, "journal exceeds byte limit");
        let envelope: Envelope =
            serde_json::from_slice(&bytes).context("decode owned-build journal")?;
        ensure!(
            serde_json::to_vec(&envelope)? == bytes,
            "noncanonical journal encoding"
        );
        ensure!(
            digest_bytes(&serde_json::to_vec(&envelope.state)?) == envelope.checksum,
            "journal checksum mismatch"
        );
        // Stored authority failure is observation uncertainty, not rejection of
        // the caller's new message. Do not leak nested policy/NotFound variants.
        self.validate(&envelope.state)
            .map_err(|error| anyhow::anyhow!("invalid owned-build journal state: {error}"))?;
        // Complete a prior unconfirmed rename before returning any durable receipt.
        file.sync_all()?;
        directory.sync_all()?;
        Ok(envelope.state)
    }

    fn write(&self, directory: &File, state: &State) -> Result<()> {
        self.validate(state)?;
        let bytes = serde_json::to_vec(&EnvelopeRef {
            checksum: digest_bytes(&serde_json::to_vec(state)?),
            state,
        })?;
        ensure!(bytes.len() <= MAX_BYTES, "journal exceeds byte limit");
        let pending = self.root.join(PENDING);
        match private_file(&pending) {
            Ok(_) => {
                fs::remove_file(&pending)?;
                directory.sync_all()?;
            }
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) => {}
            Err(error) => return Err(error),
        }
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&pending)?;
            self.commit_point(CommitPoint::Created)?;
            file.write_all(&bytes)?;
            self.commit_point(CommitPoint::Written)?;
            file.sync_all()?;
            self.commit_point(CommitPoint::FileSynced)?;
            fs::rename(&pending, self.root.join(STATE))?;
            self.commit_point(CommitPoint::Renamed)?;
            directory.sync_all()?;
            self.commit_point(CommitPoint::DirectorySynced)
        })();
        if result.is_err() {
            let _ = fs::remove_file(pending);
        }
        result
    }

    fn commit_point(&self, point: CommitPoint) -> Result<()> {
        #[cfg(test)]
        if let Some(fault) = self.fault {
            fault(point)?;
        }
        let _ = point;
        Ok(())
    }

    fn update<T>(&self, now: u64, change: impl FnOnce(&mut State, u64) -> Result<T>) -> Result<T> {
        self.update_when(now, |state, now| {
            change(state, now).map(|value| (value, true))
        })
    }

    // No-op maintenance polls are observations, not new durable clock receipts.
    // Every state change still advances/checks the committed clock atomically.
    fn update_when<T>(
        &self,
        now: u64,
        change: impl FnOnce(&mut State, u64) -> Result<(T, bool)>,
    ) -> Result<T> {
        let directory = self.lock()?;
        let mut state = self.read(&directory)?;
        // Decided under the lock; the mutation records exactly this time.
        let now = self.effective_time(now, state.last_time)?;
        let (result, changed) = change(&mut state, now).map_err(|error| {
            if error.downcast_ref::<Rejection>().is_some() {
                error
            } else {
                error.context(Rejection::InvalidTransition)
            }
        })?;
        if changed {
            state.last_time = now;
            state.revision = state.revision.checked_add(1).context(Rejection::Capacity)?;
            self.write(&directory, &state)
                .context(Unconfirmed::Persistence)?;
        }
        Ok(result)
    }

    pub fn submit(
        &self,
        authenticated_issuer: &str,
        request: BuildRequest,
        now: u64,
    ) -> Result<Acceptance> {
        request.validate().context(Rejection::InvalidRequest)?;
        ensure!(request.parent.is_none(), Rejection::InvalidRequest);
        ensure!(
            request.issuer == authenticated_issuer,
            Rejection::Unauthorized
        );
        self.submit_work(Work::Build(Box::new(request)), now)
    }

    fn submit_work(&self, request: Work, now: u64) -> Result<Acceptance> {
        self.update(now, |state, now| accept_work(state, request, now, false))
    }

    /// Atomically stop a matching intent, including a submission still in flight.
    /// No new execution permission; the ordinary supervisor proves settlement.
    pub fn withdraw(&self, issuer: &str, request: BuildRequest, now: u64) -> Result<Acceptance> {
        request.validate().context(Rejection::InvalidRequest)?;
        ensure!(request.issuer == issuer, Rejection::Unauthorized);
        ensure!(request.parent.is_none(), Rejection::InvalidRequest);
        self.withdraw_work(Work::Build(Box::new(request)), now)
    }

    fn withdraw_work(&self, request: Work, now: u64) -> Result<Acceptance> {
        self.update(now, |state, now| {
            let acceptance = accept_work(state, request, now, true)?;
            if let Some(job) = state
                .jobs
                .iter_mut()
                .find(|job| job.acceptance.attempt_id == acceptance.attempt_id)
                && job.outcome().is_none()
            {
                let owner = job.attempt.state.ownership().cloned();
                job.apply(
                    EventKind::StopRequested {
                        reason: StopReason::Cancelled,
                    },
                    now,
                    |attempt| {
                        attempt.request_stop(owner.as_ref(), StopReason::Cancelled)?;
                        Ok(())
                    },
                )?;
                if state
                    .pool
                    .owner
                    .as_ref()
                    .is_some_and(|owner| owner.attempt_id == acceptance.attempt_id)
                    && state.pool.health != PoolHealth::Quarantined
                {
                    state.pool.health = PoolHealth::Draining;
                }
            }
            Ok(acceptance)
        })
    }

    pub fn status(&self, authenticated_issuer: &str, key: &str) -> Result<JobStatus> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        if let Some(job) = state
            .jobs
            .into_iter()
            .find(|j| j.acceptance.attempt_id == key)
        {
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == authenticated_issuer,
                Rejection::NotFound
            );
            return Ok(JobStatus::Live {
                pool: state.pool.health,
                request: job.request.into_build()?,
                prepared: job.prepared.map(Box::new),
                input: job
                    .private_source
                    .as_ref()
                    .and_then(|source| source.input.clone()),
                attempt: Box::new(Attempt(job.attempt)),
                acceptance: job.acceptance,
                accepted_at: job.accepted_at,
                renewed_at: job.renewed_at,
                reserved_at: job.reserved_at,
                settled_at: job.settled_at,
            });
        }
        let tombstone = state
            .tombstones
            .into_iter()
            .find(|t| t.acceptance.attempt_id == key)
            .context(Rejection::NotFound)?;
        ensure!(
            !tombstone.maintenance && tombstone.issuer == authenticated_issuer,
            Rejection::NotFound
        );
        Ok(JobStatus::Retired {
            pool: state.pool.health,
            acceptance: tombstone.acceptance,
            outcome: tombstone.outcome,
        })
    }

    pub fn events(
        &self,
        issuer: &str,
        key: &str,
        cursor: Option<&EventCursor>,
        limit: usize,
    ) -> Result<EventPage> {
        ensure!(
            (1..=MAX_EVENT_PAGE).contains(&limit)
                && cursor.is_none_or(|cursor| cursor.attempt_id == key),
            Rejection::InvalidCursor
        );
        let after = cursor.map_or(0, |cursor| cursor.after);
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        if let Some(job) = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == key)
        {
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            return job.events.page(key, after, limit);
        }
        let tombstone = state
            .tombstones
            .iter()
            .find(|t| !t.maintenance && t.acceptance.attempt_id == key && t.issuer == issuer)
            .ok_or(Rejection::NotFound)?;
        ensure!(after <= tombstone.last_event, Rejection::InvalidCursor);
        Ok(EventPage {
            next: EventCursor {
                attempt_id: key.to_owned(),
                after: tombstone.last_event,
            },
            oldest: None,
            latest: tombstone.last_event,
            gap: after < tombstone.last_event,
            more: false,
            retired: true,
            events: Vec::new(),
        })
    }

    pub fn pool(&self) -> Result<Pool> {
        let directory = self.lock()?;
        Ok(self.read(&directory)?.pool)
    }

    pub(super) fn identity(&self) -> &StorageIdentity {
        &self.identity
    }

    pub(super) fn admission_policy(&self) -> &AdmissionPolicy {
        &self.policy
    }

    pub(super) fn authority_root(&self) -> &Path {
        &self.root
    }

    pub(super) fn protection_context(
        &self,
        owner: &Ownership,
    ) -> Result<(String, bool, Option<String>)> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let job = state
            .jobs
            .iter()
            .find(|job| job.acceptance.attempt_id == owner.attempt_id)
            .context("protection attempt missing")?;
        ensure!(
            job.attempt.state.ownership() == Some(owner),
            "protection ownership mismatch"
        );
        ensure!(job.request.kind() == Kind::Build, Rejection::NotFound);
        let settled = job.outcome().is_some();
        ensure!(
            settled || state.pool.owner.as_ref() == Some(owner),
            "protection owner unavailable"
        );
        Ok((
            job.acceptance.spec_digest.clone(),
            settled,
            job.release_digest.clone(),
        ))
    }

    /// Necessary retention veto, NOT permission to run GC. A qualified maintenance
    /// actor must additionally serialize admission and establish global ingress,
    /// native-store locking, placement and its own lifetime/settlement authority.
    /// Never let a lost process/lease/deadline release unsettled protection.
    pub fn retention_clear(&self) -> Result<bool> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        Ok(retention_clear(&state, None))
    }

    /// Trusted supervisor's single-snapshot view; not a public caller verb.
    pub fn supervision(&self) -> Result<Snapshot> {
        let directory = self.lock()?;
        let state = self.read(&directory)?;
        let active = if let Some(owner) = &state.pool.owner {
            let job = state
                .jobs
                .iter()
                .find(|job| job.acceptance.attempt_id == owner.attempt_id)
                .context("missing active job")?;
            let handle = match job.attempt.state.execution() {
                Some(super::Execution::Started { handle }) => Some(handle),
                _ => None,
            };
            Some(Active {
                owner: owner.clone(),
                handle,
                phase: job.phase(),
                stop: job.stop.clone(),
                deadlines: job.request.deadlines().clone(),
            })
        } else {
            None
        };
        Ok(Snapshot {
            pool: state.pool,
            active,
        })
    }

    /// Commit stop/kill intent before the effect. Replays do not refresh timing.
    pub fn advance_stop(&self, owner: &Ownership, stage: StopStage, now: u64) -> Result<()> {
        self.update_when(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner),
                "pool ownership mismatch"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(job.phase() == Phase::Stopping, "attempt is not stopping");
            let stop = job.stop.as_mut().context("missing stop progress")?;
            if stop.stage == stage {
                return Ok(((), false));
            }
            ensure!(
                matches!(
                    (stop.stage, stage),
                    (
                        StopStage::Requested,
                        StopStage::Terminating | StopStage::Killing
                    ) | (StopStage::Terminating, StopStage::Killing)
                ),
                "stop phase regression"
            );
            if stage == StopStage::Killing {
                ensure!(
                    now.saturating_sub(stop.requested_at)
                        >= job.request.deadlines().stop_grace_seconds,
                    "stop grace has not elapsed"
                );
            }
            stop.stage = stage;
            stop.advanced_at = now;
            Ok(((), true))
        })
    }

    /// Installed controller advances accepted metadata. Stop/expiry and queue
    /// publication share the transaction; withdrawal can never reopen admission.
    pub(in crate::build_executor) fn queue_pending(&self, now: u64) -> Result<()> {
        self.update_when(now, |state, now| {
            let mut changed = false;
            for job in &mut state.jobs {
                if job.phase() == Phase::Pending
                    && !job_deadline_expired(job, now)
                    && (!job.request.foreground()
                        || now.saturating_sub(job.renewed_at)
                            < job.request.deadlines().owner_seconds)
                {
                    job.apply(EventKind::Queued, now, Attempt::mark_queued)?;
                    changed = true;
                }
            }
            Ok(((), changed))
        })
    }

    /// Queue validated metadata; never perform Nix or source effects here.
    pub fn queue(&self, key: &str, now: u64) -> Result<()> {
        self.update(now, |state, now| {
            job_mut(state, key)?.apply(EventKind::Queued, now, Attempt::mark_queued)
        })
    }

    /// Trusted input verifier only. Preparation runs inside the admitted workload.
    /// Immutable receipt must publish before the worker can report success.
    pub fn record_prepared(
        &self,
        owner: &Ownership,
        inputs: PreparedInputs,
        now: u64,
    ) -> Result<String> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner),
                "preparation ownership mismatch"
            );
            ensure!(
                state.pool.health == PoolHealth::Owned,
                "preparation pool is not available to owner"
            );
            let job = job_mut(state, &owner.attempt_id)?;
            ensure!(
                job.phase() == Phase::Running,
                "preparation requires a live admitted worker"
            );
            ensure!(
                !job_deadline_expired(job, now)
                    && (!job.request.foreground()
                        || now.saturating_sub(job.renewed_at)
                            < job.request.deadlines().stale_seconds),
                Rejection::LeaseExpired
            );
            let prepared = Preparation::new(inputs, job.request.build()?)?;
            if let Some(existing) = &job.prepared {
                ensure!(existing == &prepared, "prepared inputs are immutable");
            } else {
                job.events.push(
                    EventKind::InputsPrepared {
                        digest: prepared.digest.clone(),
                    },
                    now,
                )?;
                job.prepared = Some(prepared.clone());
            }
            Ok(prepared.digest)
        })
    }

    pub(in crate::build_executor) fn dispatch_unconfirmed(
        &self,
        owner: &Ownership,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner),
                "unconfirmed dispatch owner differs"
            );
            job_mut(state, &owner.attempt_id)?
                .events
                .push(EventKind::DispatchUnconfirmed, now)
        })
    }

    /// Trusted supervisor failures; no caller-provided evidence or stop reason.
    pub fn stop(&self, owner: &Ownership, reason: StopReason, now: u64) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(owner),
                "stop ownership mismatch"
            );
            job_mut(state, &owner.attempt_id)?.apply(
                EventKind::StopRequested { reason },
                now,
                |attempt| {
                    attempt.request_stop(Some(owner), reason)?;
                    Ok(())
                },
            )?;
            if state.pool.health != PoolHealth::Quarantined {
                state.pool.health = PoolHealth::Draining;
            }
            Ok(())
        })
    }

    /// Trusted evidence that all ingress is reconciled and the pool is safe to use.
    pub fn recovered(&self, epoch: u64, boot_id: &str, evidence: &str, now: u64) -> Result<()> {
        identifier(boot_id)?;
        digest(evidence)?;
        self.update(now, |state, _| {
            ensure!(
                state.pool.epoch == epoch && state.pool.owner.is_none(),
                "pool recovery fence mismatch"
            );
            state.pool.health = PoolHealth::Available;
            state.pool.verified_boot = Some(boot_id.to_owned());
            state.pool.recovery_digest = Some(evidence.to_owned());
            Ok(())
        })
    }

    pub fn quarantine(&self, now: u64) -> Result<()> {
        self.update_when(now, |state, _| {
            let changed = state.pool.health != PoolHealth::Quarantined;
            state.pool.health = PoolHealth::Quarantined;
            Ok(((), changed))
        })
    }

    /// Metadata primitive only. Runtime dispatch must use Supervisor::launch_next
    /// with store/admission serialization; direct calls grant no effect authority.
    pub fn reserve_next(&self, boot_id: &str, now: u64) -> Result<Option<Ownership>> {
        self.reserve_next_kind(boot_id, now, None)
    }

    pub(super) fn reserve_next_kind(
        &self,
        boot_id: &str,
        now: u64,
        expected: Option<Kind>,
    ) -> Result<Option<Ownership>> {
        identifier(boot_id)?;
        self.update(now, |state, now| {
            ensure!(
                state.pool.health == PoolHealth::Available
                    && state.pool.owner.is_none()
                    && state.pool.verified_boot.as_deref() == Some(boot_id),
                "pool is not reconciled/available"
            );
            expire(state, now)?;
            let retained = !retention_clear(state, None);
            let Some(job) = state
                .jobs
                .iter_mut()
                .filter(|j| {
                    j.outcome().is_none() && (j.request.kind() != Kind::Maintenance || !retained)
                })
                .min_by_key(|j| (j.request.kind() != Kind::Retirement, j.acceptance.sequence))
            else {
                return Ok(None);
            };
            if expected.is_some_and(|kind| kind != job.request.kind())
                || (job.request.kind() == Kind::Maintenance && retained)
                || job.phase() != Phase::Queued
                || job.request.foreground()
                    && now.saturating_sub(job.renewed_at) >= job.request.deadlines().stale_seconds
            {
                return Ok(None);
            }
            let epoch = state
                .pool
                .epoch
                .checked_add(1)
                .and_then(NonZeroU64::new)
                .context("pool epoch exhausted")?;
            let ownership = Ownership {
                executor_version: 1,
                builder_id: state.identity.builder_id.clone(),
                store_id: state.identity.store_id.clone(),
                attempt_id: job.acceptance.attempt_id.clone(),
                pool_epoch: epoch,
                boot_id: boot_id.to_owned(),
            };
            job.apply(EventKind::Reserved { epoch }, now, |attempt| {
                attempt.reserve(ownership.clone())
            })?;
            job.reserved_at = Some(now);
            state.pool.epoch = epoch.get();
            state.pool.health = PoolHealth::Owned;
            state.pool.owner = Some(ownership.clone());
            Ok(Some(ownership))
        })
    }

    /// Root launch wrapper, after placement and gate authorization. Unlike a late
    /// observation, this grants one invocation permission to exec the worker.
    pub fn begin_worker(&self, handle: ExecutionHandle, now: u64) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(&handle.ownership)
                    && state.pool.health == PoolHealth::Owned,
                "worker ownership unavailable"
            );
            let job = job_mut(state, &handle.ownership.attempt_id)?;
            ensure!(
                job.phase() == Phase::Starting,
                "worker already started or stopped"
            );
            ensure!(
                !job_deadline_expired(job, now)
                    && (!job.request.foreground()
                        || now.saturating_sub(job.renewed_at)
                            < job.request.deadlines().stale_seconds),
                Rejection::LeaseExpired
            );
            job.apply(EventKind::Started, now, |attempt| attempt.started(handle))
        })
    }

    pub fn started(&self, handle: ExecutionHandle, now: u64) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(&handle.ownership),
                "pool ownership mismatch"
            );
            job_mut(state, &handle.ownership.attempt_id)?.apply(
                EventKind::Started,
                now,
                |attempt| attempt.started(handle.clone()),
            )
        })
    }

    pub fn client_exited(
        &self,
        handle: &ExecutionHandle,
        exit: ClientExit,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            ensure!(
                state.pool.owner.as_ref() == Some(&handle.ownership),
                "pool ownership mismatch"
            );
            let job = job_mut(state, &handle.ownership.attempt_id)?;
            job.apply(EventKind::ClientExited { exit }, now, |attempt| {
                attempt.client_exited(handle, exit)
            })?;
            if job.phase() == Phase::Verifying && job.prepared.is_none() && job.verified.is_none() {
                job.apply(
                    EventKind::StopRequested {
                        reason: StopReason::VerificationFailed,
                    },
                    now,
                    |attempt| {
                        attempt.request_stop(
                            Some(&handle.ownership),
                            StopReason::VerificationFailed,
                        )?;
                        Ok(())
                    },
                )?;
            }
            if job.phase() == Phase::Stopping && state.pool.health != PoolHealth::Quarantined {
                state.pool.health = PoolHealth::Draining;
            }
            Ok(())
        })
    }

    pub fn cancel(
        &self,
        issuer: &str,
        key: &str,
        expected: Option<&Ownership>,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let job = job_mut(state, key)?;
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            ensure!(
                job.attempt.state.ownership() == expected,
                Rejection::StaleFence
            );
            job.apply(
                EventKind::StopRequested {
                    reason: StopReason::Cancelled,
                },
                now,
                |attempt| {
                    attempt.request_stop(expected, StopReason::Cancelled)?;
                    Ok(())
                },
            )?;
            if state
                .pool
                .owner
                .as_ref()
                .is_some_and(|owner| owner.attempt_id == key)
                && state.pool.health != PoolHealth::Quarantined
            {
                state.pool.health = PoolHealth::Draining;
            }
            Ok(())
        })
    }

    pub fn renew(
        &self,
        issuer: &str,
        key: &str,
        expected: Option<&Ownership>,
        token: &[u8],
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let job = job_mut(state, key)?;
            ensure!(
                job.request.kind() == Kind::Build && job.request.issuer() == issuer,
                Rejection::NotFound
            );
            let Owner::Foreground { token_digest } = job.request.owner()? else {
                bail!(Rejection::InvalidTransition)
            };
            ensure!(
                digest_bytes(token) == *token_digest,
                Rejection::Unauthorized
            );
            ensure!(
                job.attempt.state.ownership() == expected,
                Rejection::StaleFence
            );
            ensure!(
                job.outcome().is_none()
                    && job.phase() != Phase::Stopping
                    && now.saturating_sub(job.renewed_at) < job.request.deadlines().owner_seconds
                    && !job_deadline_expired(job, now),
                Rejection::LeaseExpired
            );
            if job.renewed_at != now {
                job.events.push(EventKind::OwnerRenewed, now)?;
            }
            job.renewed_at = now;
            Ok(())
        })
    }

    pub fn expire(&self, now: u64) -> Result<()> {
        self.update_when(now, |state, now| {
            expire(state, now).map(|changed| ((), changed))
        })
    }

    /// Metadata-only requests cannot have touched Nix or protection. Never apply
    /// this evidence to a reservation, even if no unit/start receipt was observed.
    pub fn settle_unlaunched(&self, now: u64) -> Result<usize> {
        self.update_when(now, |state, now| {
            let mut count = 0;
            for job in &mut state.jobs {
                if job.phase() == Phase::Stopping
                    && job.reserved_at.is_none()
                    && job.attempt.state.execution().is_none()
                {
                    job.apply(EventKind::Settled, now, |attempt| {
                        attempt.settle(Settlement::Unlaunched, None)?;
                        Ok(())
                    })?;
                    job.settled_at = Some(now);
                    count += 1;
                }
            }
            Ok((count, count != 0))
        })
    }

    pub fn settle(
        &self,
        key: &str,
        evidence: Settlement,
        artifacts: Option<ArtifactReceipt>,
        now: u64,
    ) -> Result<()> {
        self.update(now, |state, now| {
            let job = job_mut(state, key)?;
            if let Some(receipt) = &artifacts {
                ensure!(
                    job.prepared
                        .as_ref()
                        .is_some_and(|prepared| prepared.digest == receipt.preparation_digest),
                    "success requires matching prepared inputs"
                );
            }
            job.apply(EventKind::Settled, now, |attempt| {
                attempt.settle(evidence, artifacts)?;
                Ok(())
            })?;
            job.settled_at.get_or_insert(now);
            if state
                .pool
                .owner
                .as_ref()
                .is_some_and(|owner| owner.attempt_id == key)
            {
                state.pool.owner = None;
                if state.pool.health != PoolHealth::Quarantined {
                    state.pool.health = PoolHealth::Recovering;
                }
                state.pool.recovery_digest = None;
            }
            Ok(())
        })
    }

    /// Trusted artifact adapter: all protection has been safely handed off/released.
    pub fn released(&self, key: &str, evidence: &str, now: u64) -> Result<()> {
        digest(evidence)?;
        self.update(now, |state, now| {
            let original = state
                .jobs
                .iter()
                .find(|job| job.acceptance.attempt_id == key)
                .context("release target missing")?;
            if original.retirement.is_some() || original.consumer_abandonment.is_some() {
                retirement::effect_owner(state, original, now)?;
                ensure!(
                    retirement::release_evidence(original)? == evidence,
                    "release differs from admitted retirement evidence"
                );
            }
            let job = job_mut(state, key)?;
            ensure!(
                job.outcome().is_some(),
                "unsettled protection cannot be released"
            );
            ensure!(
                job.release_digest
                    .as_deref()
                    .is_none_or(|old| old == evidence),
                "release receipt is immutable"
            );
            if job.release_digest.is_none() {
                job.events.push(EventKind::ProtectionReleased, now)?;
            }
            job.release_digest = Some(evidence.to_owned());
            Ok(())
        })
    }

    // Sidecars must not accumulate beyond the bounded live job set. Native root
    // retirement removes its registry entry first, then this metadata directory.
    fn protection_retired(&self, key: &str) -> Result<bool> {
        let parent = self.root.join("roots");
        let directory = match open_directory(&parent) {
            Ok(directory) => directory,
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                return Ok(true);
            }
            Err(error) => return Err(error),
        };
        match fs::symlink_metadata(parent.join(key)) {
            Ok(_) => Ok(false),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                // Confirm an uncertain removal before discarding its recovery row.
                directory.sync_all()?;
                Ok(true)
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Avoid rewriting the bounded ledger on every idle supervisor poll.
    pub(super) fn prune_if_due(&self, now: u64) -> Result<()> {
        let due = {
            let directory = self.lock()?;
            let state = self.read(&directory)?;
            let now = self.effective_time(now, state.last_time)?;
            state
                .tombstones
                .iter()
                .any(|entry| entry.issued_at <= now.saturating_sub(state.policy.replay_seconds))
                || state.jobs.iter().any(|job| {
                    job.release_digest.is_some()
                        && job.settled_at.is_some_and(|time| {
                            now.saturating_sub(time) >= job.request.deadlines().retention_seconds
                        })
                        && job
                            .private_source
                            .as_ref()
                            .is_none_or(|source| source.retired)
                        && controller::retired(job)
                        && retirement::prunable(&state, job)
                        && job.native_phase.as_ref().is_none_or(|phase| phase.retired)
                        && job
                            .artifact
                            .as_ref()
                            .is_none_or(|artifact| artifact.retired)
                })
        };
        if due {
            self.prune(now)?;
        }
        Ok(())
    }

    pub fn prune(&self, now: u64) -> Result<()> {
        self.update(now, |state, now| {
            state.replay_floor = state
                .replay_floor
                .max(now.saturating_sub(state.policy.replay_seconds));
            state
                .tombstones
                .retain(|t| t.issued_at > state.replay_floor);
            // Snapshot before draining: a Build's cleanup proof names another job.
            let prunable = state
                .jobs
                .iter()
                .filter(|job| retirement::prunable(state, job))
                .map(|job| job.acceptance.attempt_id.clone())
                .collect::<std::collections::BTreeSet<_>>();
            let mut kept = Vec::new();
            for job in state.jobs.drain(..) {
                if job.release_digest.is_some()
                    && prunable.contains(&job.acceptance.attempt_id)
                    && controller::retired(&job)
                    && match &job.artifact {
                        Some(artifact) => super::artifacts::retired(
                            self,
                            job.attempt
                                .state
                                .ownership()
                                .context("artifact owner missing")?,
                            artifact,
                        )?,
                        None => true,
                    }
                    && match &job.native_phase {
                        Some(phase) => super::native_phase::retired(
                            self,
                            phase,
                            job.attempt
                                .state
                                .ownership()
                                .context("native phase owner missing")?,
                        )?,
                        None => true,
                    }
                    && match &job.private_source {
                        Some(source) => {
                            super::private_sources::retired(source, &job.acceptance.attempt_id)?
                        }
                        None => true,
                    }
                    && job.settled_at.is_some_and(|time| {
                        now.saturating_sub(time) >= job.request.deadlines().retention_seconds
                    })
                    && self.protection_retired(&job.acceptance.attempt_id)?
                {
                    if job.request.id().issued_at > state.replay_floor {
                        state.tombstones.push(Tombstone {
                            last_event: job.events.last,
                            consumer_ack: job
                                .consumer_ack
                                .as_ref()
                                .map(|ack| ack.receipt.digest())
                                .transpose()?,
                            consumer_abandonment: job
                                .consumer_abandonment
                                .as_ref()
                                .map(|abandoned| abandoned.statement.digest())
                                .transpose()?,
                            consumer_release: if job.consumer_ack.is_some()
                                || job.consumer_abandonment.is_some()
                            {
                                job.release_digest.clone()
                            } else {
                                None
                            },
                            maintenance: job.request.kind() != Kind::Build,
                            issuer: job.request.issuer().to_owned(),
                            issued_at: job.request.id().issued_at,
                            acceptance: job.acceptance.clone(),
                            outcome: Attempt(job.attempt)
                                .outcome()
                                .cloned()
                                .context("cannot retire active job")?,
                        });
                    }
                } else {
                    kept.push(job);
                }
            }
            state.jobs = kept;
            ensure!(
                state.tombstones.len() <= MAX_TOMBSTONES,
                "tombstone capacity exhausted"
            );
            Ok(())
        })
    }

    fn validate(&self, state: &State) -> Result<()> {
        ensure!(
            state.version == VERSION
                && state.identity == self.identity
                && state.policy == self.policy,
            "journal version/storage/policy mismatch"
        );
        ensure!(
            state.replay_floor <= state.last_time
                && metadata_room(state.jobs.len(), state.tombstones.len()),
            "invalid journal bounds"
        );
        let mut keys = BTreeSet::new();
        let mut sequences = BTreeSet::new();
        let mut active = None;
        for job in &state.jobs {
            job.events.validate(state.last_time)?;
            job.request.validate()?;
            job.request.authority(&self.identity, &self.policy)?;
            ensure!(
                job.acceptance.attempt_id == job.request.attempt_id()?
                    && job.acceptance.spec_digest == job.request.digest()?
                    && job.acceptance.sequence > 0
                    && job.acceptance.sequence <= state.revision
                    && keys.insert(&job.acceptance.attempt_id)
                    && sequences.insert(job.acceptance.sequence),
                "stored request identity mismatch"
            );
            let attempt = Attempt(job.attempt.clone());
            attempt.validate()?;
            ensure!(
                serde_json::to_vec(&job.attempt)?.len() <= 4096,
                "attempt exceeds metadata reservation"
            );
            match &job.attempt.state {
                super::State::Stopping { .. }
                | super::State::Finished {
                    outcome: Outcome::Failed { .. } | Outcome::Cancelled { .. },
                    ..
                } => ensure!(job.stop.is_some(), "missing durable stop progress"),
                super::State::Finished {
                    outcome: Outcome::Interrupted,
                    ..
                } => {}
                _ => ensure!(job.stop.is_none(), "stop progress outside stopping history"),
            }
            if let Some(stop) = &job.stop {
                stop.validate(state.last_time)?;
                ensure!(
                    job.accepted_at <= stop.requested_at,
                    "stop before admission"
                );
                if stop.stage != StopStage::Requested {
                    ensure!(
                        job.attempt.state.ownership().is_some(),
                        "escalation without ownership"
                    );
                }
                if stop.stage == StopStage::Killing {
                    ensure!(
                        stop.advanced_at.saturating_sub(stop.requested_at)
                            >= job.request.deadlines().stop_grace_seconds,
                        "premature kill intent"
                    );
                }
            }
            if let Some(prepared) = &job.prepared {
                prepared.validate(job.request.build()?)?;
                ensure!(
                    job.attempt.state.ownership().is_some(),
                    "prepared inputs without ownership"
                );
                ensure!(
                    !matches!(
                        attempt.phase(),
                        Phase::Pending | Phase::Queued | Phase::Starting
                    ),
                    "inputs prepared before worker admission"
                );
            }
            if let Some(outcome @ Outcome::MaintenanceSucceeded { .. }) = attempt.outcome() {
                ensure!(
                    job.request.kind() != Kind::Build
                        && job
                            .verified
                            .as_ref()
                            .is_some_and(|verified| &verified.outcome == outcome),
                    "maintenance success requires its verifier receipt"
                );
            }
            if let Some(Outcome::Succeeded { artifacts }) = attempt.outcome() {
                ensure!(
                    job.prepared
                        .as_ref()
                        .is_some_and(|prepared| prepared.digest == artifacts.preparation_digest),
                    "success preparation mismatch"
                );
            }
            ensure!(
                job.attempt.attempt_id == job.acceptance.attempt_id
                    && job.attempt.spec_digest == job.acceptance.spec_digest,
                "attempt specification mismatch"
            );
            ensure!(
                job.accepted_at <= job.renewed_at
                    && job.renewed_at <= state.last_time
                    && job
                        .reserved_at
                        .is_none_or(|t| job.accepted_at <= t && t <= state.last_time)
                    && job
                        .settled_at
                        .is_none_or(|t| job.accepted_at <= t && t <= state.last_time)
                    && job.settled_at.is_some() == attempt.outcome().is_some(),
                "invalid journal timestamps"
            );
            ensure!(
                job.release_digest.is_none() || attempt.outcome().is_some(),
                "active protection released"
            );
            if let Some(value) = &job.release_digest {
                digest(value)?;
            }
            if let Some(value) = &job.successor {
                job.request.build()?;
                digest(value)?;
            }
            native_intent::validate(job)?;
            controller::validate(job)?;
            if let Some(native) = &job.native_phase {
                native.validate(job, state.last_time)?;
            }
            if let Some(artifact) = &job.artifact {
                artifact.validate(job)?;
            }
            ensure!(
                job.consumer_ack.is_none() || job.consumer_abandonment.is_none(),
                "consumer ACK conflicts with abandonment"
            );
            if let Some(ack) = &job.consumer_ack {
                ack.validate(job, state.last_time)?;
            }
            if let Some(abandoned) = &job.consumer_abandonment {
                abandoned.validate(job, state.last_time)?;
            }
            if let Some(retirement) = &job.retirement {
                retirement.validate(job)?;
            }
            if let Some(verified) = &job.verified {
                verified.validate(job, state.last_time)?;
            }
            if let Some(claim) = &job.daemon_claim {
                claim.validate(job, state.last_time)?;
            }
            if let Some(source) = &job.private_source {
                ensure!(
                    job.request.kind() == Kind::Build,
                    "private source on maintenance"
                );
                source.validate()?;
                ensure!(
                    job.attempt.state.ownership().is_some() && job.reserved_at.is_some(),
                    "source without reserved ownership"
                );
                ensure!(
                    !source.retired || (job.outcome().is_some() && job.release_digest.is_some()),
                    "source retired before release"
                );
            }
            if let Some(owner) = job.attempt.state.ownership() {
                ensure!(
                    owner.builder_id == self.identity.builder_id
                        && owner.store_id == self.identity.store_id
                        && owner.pool_epoch.get() <= state.pool.epoch
                        && job.reserved_at.is_some(),
                    "stored execution identity mismatch"
                );
                if attempt.outcome().is_none() {
                    ensure!(
                        active.replace(owner).is_none(),
                        "multiple unsettled executions"
                    );
                }
            }
        }
        for tombstone in &state.tombstones {
            ensure!(
                serde_json::to_vec(tombstone)?.len() <= TOMBSTONE_RESERVATION,
                "tombstone exceeds metadata reservation"
            );
            tombstone
                .outcome
                .validate(&tombstone.acceptance.spec_digest)?;
            ensure!(
                (tombstone.consumer_ack.is_none() || tombstone.consumer_abandonment.is_none())
                    && (tombstone.consumer_ack.is_some()
                        || tombstone.consumer_abandonment.is_some())
                        == tombstone.consumer_release.is_some(),
                "consumer tombstone conflicts or lacks matching release"
            );
            if let Some(release) = &tombstone.consumer_release {
                digest(release)?;
            }
            if let Some(decision) = tombstone
                .consumer_ack
                .as_ref()
                .or(tombstone.consumer_abandonment.as_ref())
            {
                digest(decision)?;
                ensure!(
                    !tombstone.maintenance
                        && matches!(tombstone.outcome, Outcome::Succeeded { .. }),
                    "consumer decision on unsuccessful tombstone"
                );
            }
            identifier(&tombstone.issuer)?;
            digest(&tombstone.acceptance.attempt_id)?;
            digest(&tombstone.acceptance.spec_digest)?;
            ensure!(
                tombstone.last_event > 0
                    && keys.insert(&tombstone.acceptance.attempt_id)
                    && tombstone.issued_at > state.replay_floor
                    && tombstone.acceptance.sequence > 0
                    && tombstone.acceptance.sequence <= state.revision
                    && sequences.insert(tombstone.acceptance.sequence),
                "invalid tombstone identity"
            );
        }
        ensure!(
            active == state.pool.owner.as_ref(),
            "pool owner differs from unsettled execution"
        );
        if let Some(owner) = &state.pool.owner {
            ensure!(
                owner.pool_epoch.get() == state.pool.epoch
                    && matches!(
                        state.pool.health,
                        PoolHealth::Owned | PoolHealth::Draining | PoolHealth::Quarantined
                    ),
                "invalid owned pool state"
            );
        } else {
            ensure!(
                matches!(
                    state.pool.health,
                    PoolHealth::Available | PoolHealth::Recovering | PoolHealth::Quarantined
                ),
                "invalid idle pool state"
            );
        }
        if state.pool.health == PoolHealth::Available {
            identifier(
                state
                    .pool
                    .verified_boot
                    .as_deref()
                    .context("missing reconciled boot")?,
            )?;
            digest(
                state
                    .pool
                    .recovery_digest
                    .as_deref()
                    .context("missing recovery receipt")?,
            )?;
        }
        Ok(())
    }
}

#[derive(Serialize)]
struct EnvelopeRef<'a> {
    checksum: String,
    state: &'a State,
}

fn retention_clear(state: &State, except: Option<&str>) -> bool {
    state.jobs.iter().all(|job| {
        except == Some(job.acceptance.attempt_id.as_str())
            || job.reserved_at.is_none()
            || (job.outcome().is_some()
                && job.release_digest.is_some()
                && retirement::prunable(state, job))
    })
}

fn metadata_room(jobs: usize, tombstones: usize) -> bool {
    jobs <= MAX_JOBS
        && tombstones <= MAX_TOMBSTONES
        && jobs * JOB_RESERVATION + tombstones * TOMBSTONE_RESERVATION + SHARED_RESERVATION
            <= MAX_BYTES
}

fn job_mut<'a>(state: &'a mut State, key: &str) -> Result<&'a mut Job> {
    state
        .jobs
        .iter_mut()
        .find(|job| job.acceptance.attempt_id == key)
        .context(Rejection::NotFound)
}

fn job_deadline_expired(job: &Job, now: u64) -> bool {
    job.reserved_at.map_or_else(
        || now.saturating_sub(job.accepted_at) >= job.request.deadlines().queue_seconds,
        |time| now.saturating_sub(time) >= job.request.deadlines().runtime_seconds,
    )
}

fn expire(state: &mut State, now: u64) -> Result<bool> {
    let mut changed = false;
    for job in &mut state.jobs {
        if job.outcome().is_some() || job.phase() == Phase::Stopping {
            continue;
        }
        let owner_expired = job.request.foreground()
            && now.saturating_sub(job.renewed_at) >= job.request.deadlines().owner_seconds;
        let deadline = job_deadline_expired(job, now);
        if owner_expired || deadline {
            changed = true;
            let owner = job.attempt.state.ownership().cloned();
            let reason = if owner_expired {
                StopReason::OwnerExpired
            } else {
                StopReason::DeadlineExpired
            };
            job.apply(EventKind::StopRequested { reason }, now, |attempt| {
                attempt.request_stop(owner.as_ref(), reason)?;
                Ok(())
            })?;
            if owner.is_some() && state.pool.health != PoolHealth::Quarantined {
                state.pool.health = PoolHealth::Draining;
            }
        }
    }
    Ok(changed)
}

fn private_metadata(file: &File) -> Result<()> {
    let metadata = file.metadata()?;
    // Effective service UID is trusted; production provisioning must run as root.
    ensure!(
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
        "journal path is not private/service-owned"
    );
    Ok(())
}

pub(super) fn open_directory(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    private_metadata(&file)?;
    Ok(file)
}

pub(super) fn private_file(path: &Path) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
        .open(path)?;
    private_metadata(&file)?;
    let metadata = file.metadata()?;
    ensure!(
        metadata.is_file() && metadata.nlink() == 1,
        "journal path is not a private regular file"
    );
    Ok(file)
}

// Shared admission/deduplication logic; withdrawal only creates stopped metadata.
fn accept_work(state: &mut State, request: Work, now: u64, withdraw: bool) -> Result<Acceptance> {
    request.validate().context(Rejection::InvalidRequest)?;
    let key = request.attempt_id()?;
    let spec_digest = request.digest()?;
    if let Some(existing) = state
        .jobs
        .iter()
        .map(|j| &j.acceptance)
        .chain(state.tombstones.iter().map(|t| &t.acceptance))
        .find(|a| a.attempt_id == key)
    {
        ensure!(existing.spec_digest == spec_digest, Rejection::Conflict);
        return Ok(existing.clone());
    }
    request.authority(&state.identity, &state.policy)?;
    ensure!(
        request.id().issued_at > state.replay_floor
            && request.id().issued_at <= now.saturating_add(state.policy.future_skew_seconds)
            && (withdraw
                || now.saturating_sub(request.id().issued_at)
                    <= state.policy.submission_age_seconds),
        Rejection::ExpiredRequest
    );
    ensure!(
        metadata_room(
            state
                .jobs
                .len()
                .saturating_add(if request.kind() == Kind::Retirement {
                    1
                } else {
                    2
                }),
            state.tombstones.len()
        ),
        Rejection::Capacity
    );
    if let Work::Build(request) = &request
        && let Some(predecessor) = &request.predecessor
    {
        let previous = job_mut(state, predecessor)?;
        ensure!(
            previous.request.build()?.issuer == request.issuer
                && previous.request.build()?.repository_id == request.repository_id
                && previous.request.build()?.run_id == request.run_id
                && previous.successor.is_none()
                && previous
                    .outcome()
                    .is_some_and(|o| !matches!(o, Outcome::Succeeded { .. })),
            Rejection::InvalidPredecessor
        );
        previous.successor = Some(key.clone());
    }
    let acceptance = Acceptance {
        attempt_id: key.clone(),
        spec_digest: spec_digest.clone(),
        sequence: state.revision.checked_add(1).context(Rejection::Capacity)?,
    };
    state.jobs.push(Job {
        attempt: Attempt::pending(&key, spec_digest)?.0,
        request,
        prepared: None,
        stop: None,
        acceptance: acceptance.clone(),
        accepted_at: now,
        renewed_at: now,
        reserved_at: None,
        settled_at: None,
        release_digest: None,
        private_source: None,
        daemon_claim: None,
        verified: None,
        native_phase: None,
        artifact: None,
        consumer_ack: None,
        consumer_abandonment: None,
        native_resolution: None,
        controller: None,
        retirement: None,
        successor: None,
        events: History::accepted(now),
    });
    Ok(acceptance)
}

#[cfg(test)]
pub(super) mod tests;
