//! Signed acquisition of one settled successful attempt. Co-located consumers
//! use the shared store without additional daemon authority. Remote consumers
//! import through their ordinary local daemon, using temporary roots before
//! copy and durable permanent roots before acknowledgement. Both authenticate
//! against local trusted keys and rehash content. One original claim/cutoff;
//! exact immutable imports may retry, never realization or signature bypass.
//! Recorded ACK recovery verifies only: it cannot copy or repair lost roots.

pub(crate) mod development;
pub mod native;

use std::fs::File;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{ArtifactDelivery, ConsumerAck};
use abird_host_agent::sha256::digest_bytes;
use anyhow::{Context, Result, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use serde::Serialize;

use super::controller::Controller;

/// Consumer retains in the builder's own (shared) native store.
pub const STORE_ID: &str = "builder-shared-store";
/// Root-owned parent; `buildController` provisions `<uid>` 0700 per caller.
pub const ROOTS: &str = "/nix/var/nix/gcroots/abird-owned-fleet";

#[derive(Serialize)]
struct Binding<'a> {
    version: u32,
    source: &'a str,
    nix: &'a Path,
    store_id: &'a str,
    roots: &'a Path,
    tree: bool,
}

/// Exact signed source: the deployment's existing cache endpoint. Rejects
/// inline options/credentials; trust comes only from local Nix configuration.
pub fn signed_source(url: &str) -> Result<&str> {
    ensure!(
        !url.is_empty()
            && url.len() <= 2048
            // `?trusted=` etc. would change store trust; userinfo carries secrets.
            && !url.contains(['@', '#', '?'])
            && !url.chars().any(|c| c.is_whitespace() || c.is_control())
            && ["https://", "http://", "s3://"]
                .iter()
                .any(|scheme| url.starts_with(scheme)),
        "unsupported signed acquisition source"
    );
    Ok(url)
}

pub fn binding_digest(source: &str, nix: &Path, roots: &Path, tree: bool) -> Result<String> {
    let mut bytes = b"abird-owned-acquisition-binding-v2\n".to_vec();
    bytes.extend(serde_json::to_vec(&Binding {
        version: 2,
        source: signed_source(source)?,
        nix,
        store_id: STORE_ID,
        roots,
        tree,
    })?);
    Ok(digest_bytes(&bytes))
}

/// The destination is immutable per claim. Remote import binds the actual local
/// store/database/socket identities and packaged native bridge, not `daemon`
/// resolved through ambient NIX_REMOTE or a newly chosen reconnect destination.
pub fn consumer_binding(
    shared: bool,
    source: &str,
    nix: &Path,
    roots: &Path,
    tree: bool,
) -> Result<(String, &'static str)> {
    if shared {
        return Ok((binding_digest(source, nix, roots, tree)?, STORE_ID));
    }
    Ok((
        native::binding(source, nix, roots, tree, &native::Destination::capture()?)?,
        native::STORE_ID,
    ))
}

/// This caller's provisioned direct-root directory: root-owned, non-writable
/// parent; caller-owned private leaf. Never created or repaired here.
pub fn roots_base() -> Result<PathBuf> {
    #[cfg(test)]
    if let Some(path) = std::env::var_os("ABIRD_OWNED_TEST_ROOTS") {
        return Ok(PathBuf::from(path));
    }
    let parent = std::fs::symlink_metadata(ROOTS)
        .context("consumer GC-root directory is not provisioned (buildController)")?;
    ensure!(
        parent.is_dir() && parent.uid() == 0 && parent.mode() & 0o022 == 0,
        "consumer GC-root parent is not root-controlled"
    );
    let base = Path::new(ROOTS).join(unsafe { libc::geteuid() }.to_string());
    let leaf = std::fs::symlink_metadata(&base)
        .context("caller GC-root directory is not provisioned (buildController)")?;
    ensure!(
        leaf.is_dir() && leaf.uid() == unsafe { libc::geteuid() } && leaf.mode() & 0o077 == 0,
        "caller GC-root directory is not private"
    );
    Ok(base)
}

pub fn run_roots(run_id: &str) -> Result<PathBuf> {
    Ok(roots_base()?.join(run_id))
}

/// Exactly the consumer-rooted paths: outputs, then the evaluated tree.
pub fn retained_paths(delivery: &ArtifactDelivery, tree: bool) -> Vec<String> {
    let mut paths = delivery.outputs();
    if tree {
        paths.push(delivery.prepared.source_path.clone());
    }
    paths
}

/// Claim → reconcile roots → verify → persist. An unfinished same-binding
/// claim may recheck within its original deadline. Shared-store acquisition
/// never copies. Remote signed import may retry only identical immutable paths,
/// binding and destination, then fully verify and root. ACKs stay immutable.
pub fn acquire(
    controller: &mut Controller,
    attempt: &str,
    nix: &Path,
    source: &str,
    tree: bool,
) -> Result<ConsumerAck> {
    ensure!(
        nix.is_absolute() && nix.file_name().is_some_and(|name| name == "nix"),
        "acquisition requires an absolute nix program"
    );
    // Before roots, acquisition binding or import_pending. A failed preflight
    // is not evidence about any previously uncertain daemon work.
    native::preflight(nix)?;
    if !controller.shares_store(attempt)? {
        return acquire_remote(controller, attempt, nix, source, tree);
    }
    let roots = controller.consumer_roots(attempt)?;
    let binding = binding_digest(source, nix, &roots, tree)?;
    let (delivery, cutoff) = controller.reconcile_acquisition(attempt, &binding, STORE_ID)?;
    let paths = retained_paths(&delivery, tree);
    root_directories(&roots, &paths)?;
    let lock = controller.acquisition_lock()?;
    let request = native::Request::shared(
        native::Input {
            program: nix,
            source,
            roots: &roots,
            tree,
            delivery: &delivery,
        },
        true,
        cutoff,
        &lock,
    )?;
    let cancellation = controller.cancellation_probe()?;
    controller.begin_native_helper(attempt)?;
    let reply = native::run(&request, &lock, cutoff, || {
        crate::fleet::signal::check_interrupted()?;
        cancellation.check()
    })?;
    controller.native_helper_returned(attempt)?;
    ensure!(
        reply.verified && reply.import_state == native::ImportState::NotStarted,
        "shared local content/signatures/protection unconfirmed"
    );
    let ack = ConsumerAck {
        version: 1,
        ownership: delivery.ownership.clone(),
        artifacts: delivery.artifacts.clone(),
        consumer: controller.consumer(attempt)?.clone(),
        store_id: STORE_ID.into(),
        acquisition_digest: shared_witness(&delivery, tree)?,
        retention_digest: retention(&roots, &paths)?,
    };
    ack.validate()?;
    ensure!(
        Instant::now() < cutoff,
        "original acquisition deadline expired"
    );
    controller.record_consumption(attempt, ack.clone())?;
    Ok(ack)
}

fn acquire_remote(
    controller: &mut Controller,
    attempt: &str,
    nix: &Path,
    source: &str,
    tree: bool,
) -> Result<ConsumerAck> {
    let roots = controller.consumer_roots(attempt)?;
    let (binding, store_id) = consumer_binding(false, source, nix, &roots, tree)?;
    let (delivery, cutoff) = controller.reconcile_acquisition(attempt, &binding, store_id)?;
    let paths = retained_paths(&delivery, tree);
    root_directories(&roots, &paths)?;
    let lock = controller.acquisition_lock()?;
    let request = native::Request::new(
        native::Input {
            program: nix,
            source,
            roots: &roots,
            tree,
            delivery: &delivery,
        },
        true,
        cutoff,
        &lock,
    )?;
    ensure!(
        request.binding()? == binding,
        "consumer destination changed before import"
    );
    let cancellation = controller.cancellation_probe()?;
    let previously_pending = controller.begin_import(attempt)?;
    let reply = native::run(&request, &lock, cutoff, || {
        crate::fleet::signal::check_interrupted()?;
        cancellation.check()
    })?;
    controller.native_helper_returned(attempt)?;
    if previously_pending && reply.effects_confined {
        controller.import_effects_reconciled(attempt)?;
    } else if reply.import_state.settles(previously_pending) {
        controller.import_settled(attempt)?;
    }
    ensure!(
        reply.verified
            && reply.effects_confined
            && reply.import_state == native::ImportState::Completed,
        "signed local acquisition failed; reconcile this same run/binding"
    );
    ensure!(
        Instant::now() < cutoff && !controller.cancelled()?,
        "acquisition cancelled or original deadline expired"
    );
    ensure!(
        consumer_binding(false, source, nix, &roots, tree)?.0 == binding,
        "consumer destination changed during acquisition"
    );
    let ack = ConsumerAck {
        version: 1,
        ownership: delivery.ownership.clone(),
        artifacts: delivery.artifacts.clone(),
        consumer: controller.consumer(attempt)?.clone(),
        store_id: store_id.into(),
        acquisition_digest: remote_witness(&binding, &delivery)?,
        retention_digest: retention(&roots, &paths)?,
    };
    ack.validate()?;
    controller.record_consumption(attempt, ack.clone())?;
    Ok(ack)
}

/// Bounded read-only effect reconciliation, including after cancellation or
/// the original acquisition cutoff. Never copies, repairs or records an ACK.
/// Complete rooted local verification can discharge an older NoRepair effect.
/// Explicit cancelled/expired, unacknowledged retirement first durably revokes
/// consumption, then confines residual daemon work to immutable cache effects.
pub(crate) fn reconcile_pending(
    controller: &mut Controller,
    attempt: &str,
    nix: &Path,
    tree: bool,
    deadline: Instant,
) -> Result<()> {
    controller.require_import_reconciliation(attempt)?;
    let delivery = controller.retained(attempt)?;
    let source = controller.retained_acquisition_source(attempt)?;
    let roots = controller.consumer_roots(attempt)?;
    let (binding, store_id) = consumer_binding(false, &source, nix, &roots, tree)?;
    controller.require_acquisition_binding(attempt, &binding, store_id)?;
    root_directories(&roots, &retained_paths(&delivery, tree))?;
    let discard = controller.prepare_import_reconciliation(attempt)?;
    let lock = controller.acquisition_lock()?;
    let request = native::Request::reconciliation(
        native::Input {
            program: nix,
            source: &source,
            roots: &roots,
            tree,
            delivery: &delivery,
        },
        discard,
        deadline,
        &lock,
    )?;
    ensure!(
        request.binding()? == binding,
        "reconciliation destination changed"
    );
    controller.begin_native_helper(attempt)?;
    let reply = native::run(
        &request,
        &lock,
        deadline,
        crate::fleet::signal::check_interrupted,
    )?;
    controller.native_helper_returned(attempt)?;
    ensure!(
        reply.effects_confined && reply.import_state == native::ImportState::NotStarted,
        "native import effects remain unconfirmed; preserve this run"
    );
    controller.import_effects_reconciled(attempt)
}

fn remote_witness(binding: &str, delivery: &ArtifactDelivery) -> Result<String> {
    Ok(digest_bytes(&serde_json::to_vec(&(
        "abird-owned-local-verified-v1",
        binding,
        digest_bytes(&delivery.encode()?),
    ))?))
}

/// ACK recovery never copies or repairs roots. It rehashes local closure/tree
/// bytes and checks signatures with current local trusted public keys, even if
/// the original builder has already released its protection after a lost ACK.
pub(crate) fn retained_remote(
    input: native::Input<'_>,
    ack: &ConsumerAck,
    lock: &File,
    deadline: Instant,
    mut active: impl FnMut() -> Result<()>,
) -> Result<()> {
    let native::Input {
        roots,
        delivery,
        tree,
        ..
    } = input;
    let paths = retained_paths(delivery, tree);
    ensure!(
        ack.store_id == native::STORE_ID && retention(roots, &paths)? == ack.retention_digest,
        "remote consumer roots changed"
    );
    let cutoff = deadline.min(Instant::now() + Duration::from_secs(60));
    let request = native::Request::new(input, false, cutoff, lock)?;
    ensure!(
        remote_witness(&request.binding()?, delivery)? == ack.acquisition_digest,
        "recorded consumer binding differs from local verification"
    );
    let reply = native::run(&request, lock, cutoff, || {
        crate::fleet::signal::check_interrupted()?;
        active()
    })?;
    ensure!(
        reply.verified && reply.import_state == native::ImportState::NotStarted,
        "local consumer protection/content/signatures unconfirmed"
    );
    ensure!(
        retention(roots, &paths)? == ack.retention_digest,
        "consumer roots changed during recheck"
    );
    Ok(())
}

/// Shared-store ACK recovery hashes local bytes using retained registration
/// and signature evidence. No publisher liveness, daemon authority or root repair.
pub(super) fn retained_shared(
    input: native::Input<'_>,
    ack: &ConsumerAck,
    lock: &File,
    deadline: Instant,
    mut active: impl FnMut() -> Result<()>,
) -> Result<()> {
    let paths = retained_paths(input.delivery, input.tree);
    ensure!(
        ack.store_id == STORE_ID
            && ack.ownership == input.delivery.ownership
            && ack.artifacts == input.delivery.artifacts
            && ack.acquisition_digest == shared_witness(input.delivery, input.tree)?
            && retention(input.roots, &paths)? == ack.retention_digest,
        "shared consumer protection differs"
    );
    let cutoff = deadline.min(Instant::now() + Duration::from_secs(60));
    let request = native::Request::shared(input, false, cutoff, lock)?;
    let reply = native::run(&request, lock, cutoff, || {
        crate::fleet::signal::check_interrupted()?;
        active()
    })?;
    ensure!(
        reply.verified && reply.import_state == native::ImportState::NotStarted,
        "shared local content/signatures/protection unconfirmed"
    );
    ensure!(
        retention(input.roots, &paths)? == ack.retention_digest,
        "shared consumer roots changed during recheck"
    );
    Ok(())
}

/// Preserve the original shared ACK encoding while strengthening its producer
/// to local native verification. This function itself is only a metadata hash.
fn shared_witness(delivery: &ArtifactDelivery, tree: bool) -> Result<String> {
    let metadata = serde_json::to_value(delivery)?;
    let content = delivery.compare_acquired(&serde_json::to_vec(&metadata["paths"])?)?;
    if !tree {
        return Ok(content);
    }
    let expected = format!(
        "sha256-{}",
        STANDARD.encode(hex(&delivery.prepared.tree_digest)?)
    );
    let mut witness = b"abird-owned-consumer-tree-v1\n".to_vec();
    witness.extend(format!("{content}\n{}\n{expected}", delivery.prepared.source_path).as_bytes());
    Ok(digest_bytes(&witness))
}

fn hex(value: &str) -> Result<Vec<u8>> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "invalid evaluated tree digest"
    );
    (0..64)
        .step_by(2)
        .map(|n| Ok(u8::from_str_radix(&value[n..n + 2], 16)?))
        .collect()
}

fn private_directory(path: &Path, create: bool) -> Result<File> {
    if create {
        match std::fs::DirBuilder::new().mode(0o700).create(path) {
            Err(error) if error.kind() != std::io::ErrorKind::AlreadyExists => {
                return Err(error).context("create consumer root directory");
            }
            _ => {}
        }
    }
    let directory = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    let metadata = directory.metadata()?;
    ensure!(
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o7777 == 0o700,
        "consumer root directory is not private"
    );
    Ok(directory)
}

// Separate filesystem boundary permits deterministic fsync failure/ordering
// tests without a store or native signature verifier.
#[cfg(test)]
fn retain_roots(
    roots: &Path,
    paths: &[String],
    mut sync: impl FnMut(&File, &Path) -> Result<()>,
) -> Result<()> {
    let run = roots.parent().context("consumer root run missing")?;
    let base = run.parent().context("consumer root base missing")?;
    let [root_directory, run_directory, base_directory] = root_directories(roots, paths)?;
    for (index, path) in paths.iter().enumerate() {
        ensure!(
            std::fs::symlink_metadata(path).is_ok(),
            "consumed path absent from the shared store"
        );
        let link = roots.join(index.to_string());
        match std::os::unix::fs::symlink(path, &link) {
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                root_link(&link, path)?;
            }
            result => result.context("register consumer GC root")?,
        }
    }
    // Child links, attempt entry, then run entry. Repeat after partial writes.
    sync(&root_directory, roots)?;
    sync(&run_directory, run)?;
    sync(&base_directory, base)?;
    Ok(())
}

fn root_directories(roots: &Path, paths: &[String]) -> Result<[File; 3]> {
    ensure!(paths.len() <= 1024, "consumer root set exceeds bound");
    let run = roots.parent().context("consumer root run missing")?;
    let base = run.parent().context("consumer root base missing")?;
    let base_directory = private_directory(base, false)?;
    let run_directory = private_directory(run, true)?;
    let root_directory = private_directory(roots, true)?;
    // Inspect the complete bounded residue before filling any missing entries.
    for entry in std::fs::read_dir(roots)?.take(paths.len() + 1) {
        let entry = entry?;
        let name = entry.file_name();
        let index: usize = name
            .to_str()
            .context("invalid consumer root name")?
            .parse()?;
        ensure!(
            index < paths.len() && name == index.to_string().as_str(),
            "unexpected consumer root entry"
        );
        root_link(&entry.path(), &paths[index])?;
    }
    Ok([root_directory, run_directory, base_directory])
}

fn root_link(link: &Path, target: &str) -> Result<std::fs::Metadata> {
    let metadata = std::fs::symlink_metadata(link)?;
    ensure!(
        metadata.file_type().is_symlink()
            && metadata.uid() == unsafe { libc::geteuid() }
            && std::fs::read_link(link)? == Path::new(target),
        "consumer root differs"
    );
    Ok(metadata)
}

/// Explicit local retirement only. Remove a bounded subset of the original
/// output/tree links; never recurse, follow directory links or remove targets.
/// Missing entries permit recovery after interrupted cleanup, not acquisition.
pub(super) fn release_run_roots(
    run: &Path,
    expected: &std::collections::BTreeMap<String, Vec<String>>,
) -> Result<()> {
    let base = run.parent().context("consumer root base missing")?;
    let base_directory = match private_directory(base, false) {
        Err(error) if is_missing(&error) => return Ok(()),
        result => result?,
    };
    let run_directory = match private_directory(run, false) {
        Err(error) if is_missing(&error) => {
            base_directory.sync_all()?;
            return Ok(());
        }
        result => result?,
    };
    let mut attempts = Vec::new();
    // Validate all residue before removing anything. Only exact named children
    // from the retained manifest can own a directory in this run.
    for entry in std::fs::read_dir(run)?.take(expected.len() + 1) {
        let entry = entry?;
        let name = entry.file_name();
        let paths = expected
            .get(name.to_str().context("invalid consumer attempt name")?)
            .context("unexpected consumer attempt directory")?;
        let path = entry.path();
        let directory = private_directory(&path, false)?;
        let mut links = Vec::new();
        for entry in std::fs::read_dir(&path)?.take(paths.len() + 1) {
            let entry = entry?;
            let name = entry.file_name();
            let index: usize = name
                .to_str()
                .context("invalid consumer root name")?
                .parse()?;
            ensure!(
                index < paths.len() && name == index.to_string().as_str(),
                "unexpected consumer root entry"
            );
            root_link(&entry.path(), &paths[index])?;
            links.push(entry.path());
        }
        attempts.push((path, directory, links));
    }
    for (path, directory, links) in attempts {
        for link in links {
            std::fs::remove_file(link)?;
        }
        directory.sync_all()?;
        std::fs::remove_dir(path)?;
    }
    run_directory.sync_all()?;
    std::fs::remove_dir(run)?;
    base_directory.sync_all()?;
    Ok(())
}

fn is_missing(error: &anyhow::Error) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound)
}

/// Digest of each durable root link: name, exact target and link inode.
fn retention(roots: &Path, outputs: &[String]) -> Result<String> {
    let mut bytes = b"abird-owned-consumer-roots-v1\n".to_vec();
    let run = roots.parent().context("consumer root run missing")?;
    private_directory(run.parent().context("consumer root base missing")?, false)?;
    private_directory(run, false)?;
    private_directory(roots, false)?;
    let entries = std::fs::read_dir(roots)?
        .take(outputs.len() + 1)
        .collect::<std::io::Result<Vec<_>>>()?;
    ensure!(
        entries.len() == outputs.len(),
        "unexpected consumer root entries"
    );
    for (index, path) in outputs.iter().enumerate() {
        let link = roots.join(index.to_string());
        let metadata = root_link(&link, path)?;
        ensure!(
            std::fs::symlink_metadata(path).is_ok(),
            "consumer root target missing"
        );
        bytes
            .extend(format!("{index}\0{path}\0{}:{}\n", metadata.dev(), metadata.ino()).as_bytes());
    }
    Ok(digest_bytes(&bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn evaluated_tree_digest_is_the_exact_hex_nar_hash() {
        assert_eq!(hex(&"ab".repeat(32)).unwrap(), vec![0xab; 32]);
        for invalid in ["AB".repeat(32), "ab".repeat(31), "zz".repeat(32)] {
            assert!(hex(&invalid).is_err());
        }
    }

    fn root_fixture() -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        directory
    }

    #[test]
    fn signed_sources_exclude_inline_credentials_options_and_builder_ingress() {
        for valid in ["https://cache.example", "http://abird-ci:5000"] {
            signed_source(valid).unwrap();
        }
        for invalid in [
            "",
            "ssh-ng://root@builder",
            "https://user:token@cache.example",
            "https://cache.example?trusted=1",
            "https://cache.example --no-check-sigs",
            "file:///nix/store",
            "daemon",
        ] {
            assert!(signed_source(invalid).is_err(), "{invalid}");
        }
    }

    #[test]
    fn binding_covers_source_program_store_and_root_location() {
        let nix = Path::new("/nix/store/0-nix/bin/nix");
        let roots = Path::new("/state/roots/a");
        let base = binding_digest("https://cache.example", nix, roots, false).unwrap();
        assert_ne!(
            base,
            binding_digest("https://other.example", nix, roots, false).unwrap()
        );
        assert_ne!(
            base,
            binding_digest(
                "https://cache.example",
                Path::new("/nix/store/1-nix/bin/nix"),
                roots,
                false
            )
            .unwrap()
        );
        assert_ne!(
            base,
            binding_digest(
                "https://cache.example",
                nix,
                Path::new("/state/roots/b"),
                false
            )
            .unwrap()
        );
        assert_ne!(
            base,
            binding_digest("https://cache.example", nix, roots, true).unwrap()
        );
    }

    #[test]
    fn root_reconciliation_keeps_partial_links_and_syncs_child_to_base() {
        let directory = root_fixture();
        let run = directory.path().join("run");
        let roots = run.join("attempt");
        private_directory(&run, true).unwrap();
        private_directory(&roots, true).unwrap();
        let paths = (0..2)
            .map(|index| {
                let target = directory.path().join(format!("target-{index}"));
                std::fs::write(&target, b"x").unwrap();
                target.to_string_lossy().into_owned()
            })
            .collect::<Vec<_>>();
        // A dead writer left only the first link, without publishing a receipt.
        std::os::unix::fs::symlink(&paths[0], roots.join("0")).unwrap();
        let original = root_link(&roots.join("0"), &paths[0]).unwrap().ino();
        let mut synced = Vec::new();
        retain_roots(&roots, &paths, |file, path| {
            file.sync_all()?;
            synced.push(path.to_owned());
            Ok(())
        })
        .unwrap();
        assert_eq!(synced, [roots.clone(), run, directory.path().to_owned()]);
        assert_eq!(
            root_link(&roots.join("0"), &paths[0]).unwrap().ino(),
            original
        );
        let digest = retention(&roots, &paths).unwrap();
        retain_roots(&roots, &paths, |file, _| Ok(file.sync_all()?)).unwrap();
        assert_eq!(retention(&roots, &paths).unwrap(), digest);
    }

    #[test]
    fn every_root_sync_failure_is_reported_and_can_reconcile() {
        for failure in 0..3 {
            let directory = root_fixture();
            let roots = directory.path().join("run/attempt");
            let target = directory.path().join("target");
            std::fs::write(&target, b"x").unwrap();
            let paths = vec![target.to_string_lossy().into_owned()];
            let mut calls = 0;
            let result = retain_roots(&roots, &paths, |file, _| {
                let current = calls;
                calls += 1;
                ensure!(current != failure, "injected directory sync failure");
                Ok(file.sync_all()?)
            });
            assert!(result.is_err());
            assert_eq!(calls, failure + 1);
            let digest = retention(&roots, &paths).unwrap();
            let mut synced = Vec::new();
            retain_roots(&roots, &paths, |file, path| {
                file.sync_all()?;
                synced.push(path.to_owned());
                Ok(())
            })
            .unwrap();
            assert_eq!(synced.len(), 3); // Existing entries need all barriers too.
            assert_eq!(synced.last().unwrap(), directory.path());
            assert_eq!(retention(&roots, &paths).unwrap(), digest);
        }
    }

    #[test]
    fn root_reconciliation_rejects_foreign_entries_without_repair() {
        let directory = root_fixture();
        let roots = directory.path().join("run/attempt");
        let target = directory.path().join("target");
        std::fs::write(&target, b"x").unwrap();
        let paths = vec![target.to_string_lossy().into_owned()];
        retain_roots(&roots, &paths, |file, _| Ok(file.sync_all()?)).unwrap();
        let original = retention(&roots, &paths).unwrap();
        for name in ["extra", "00", "1"] {
            std::os::unix::fs::symlink(&target, roots.join(name)).unwrap();
            assert!(retain_roots(&roots, &paths, |_, _| panic!("must not sync")).is_err());
            assert!(roots.join(name).is_symlink());
            std::fs::remove_file(roots.join(name)).unwrap();
        }
        assert_eq!(retention(&roots, &paths).unwrap(), original);
        // Wrong target and regular-file impostors must not be replaced.
        std::fs::remove_file(roots.join("0")).unwrap();
        std::os::unix::fs::symlink("foreign", roots.join("0")).unwrap();
        assert!(retain_roots(&roots, &paths, |_, _| panic!("must not sync")).is_err());
        assert_eq!(
            std::fs::read_link(roots.join("0")).unwrap(),
            Path::new("foreign")
        );
        std::fs::remove_file(roots.join("0")).unwrap();
        std::fs::write(roots.join("0"), b"foreign").unwrap();
        assert!(retain_roots(&roots, &paths, |_, _| panic!("must not sync")).is_err());
        assert_eq!(std::fs::read(roots.join("0")).unwrap(), b"foreign");
    }

    #[test]
    fn root_reconciliation_rejects_symlink_directories_and_missing_targets() {
        let directory = root_fixture();
        let run = directory.path().join("run");
        let roots = run.join("attempt");
        let foreign = directory.path().join("foreign");
        private_directory(&foreign, true).unwrap();
        std::os::unix::fs::symlink(&foreign, &run).unwrap();
        assert!(retain_roots(&roots, &[], |_, _| panic!("must not sync")).is_err());
        assert!(!foreign.join("attempt").exists());
        std::fs::remove_file(&run).unwrap();
        private_directory(&run, true).unwrap();
        std::os::unix::fs::symlink(&foreign, &roots).unwrap();
        assert!(retain_roots(&roots, &[], |_, _| panic!("must not sync")).is_err());
        std::fs::remove_file(&roots).unwrap();
        let paths = vec![
            directory
                .path()
                .join("absent")
                .to_string_lossy()
                .into_owned(),
        ];
        assert!(retain_roots(&roots, &paths, |_, _| panic!("must not sync")).is_err());
        assert!(!roots.join("0").is_symlink());
    }

    #[test]
    fn root_release_is_exact_nonrecursive_and_recovers_partial_cleanup() {
        let directory = root_fixture();
        let run = directory.path().join("run");
        let roots = run.join("attempt");
        let target = directory.path().join("target");
        std::fs::write(&target, b"keep").unwrap();
        let paths = vec![target.to_string_lossy().into_owned()];
        retain_roots(&roots, &paths, |file, _| Ok(file.sync_all()?)).unwrap();
        let expected = std::collections::BTreeMap::from([("attempt".into(), paths)]);
        std::fs::write(run.join("foreign"), b"keep").unwrap();
        assert!(release_run_roots(&run, &expected).is_err());
        assert!(roots.join("0").is_symlink());
        assert_eq!(std::fs::read(run.join("foreign")).unwrap(), b"keep");
        std::fs::remove_file(run.join("foreign")).unwrap();
        // Interrupted after one allowed unlink, before directory removal.
        std::fs::remove_file(roots.join("0")).unwrap();
        release_run_roots(&run, &expected).unwrap();
        assert!(!run.exists());
        assert_eq!(std::fs::read(target).unwrap(), b"keep");
        release_run_roots(&run, &expected).unwrap();
    }

    #[test]
    fn root_release_never_follows_attempt_directory_links() {
        let directory = root_fixture();
        let run = directory.path().join("run");
        let foreign = directory.path().join("foreign");
        private_directory(&run, true).unwrap();
        private_directory(&foreign, true).unwrap();
        std::fs::write(foreign.join("keep"), b"keep").unwrap();
        std::os::unix::fs::symlink(&foreign, run.join("attempt")).unwrap();
        let expected = std::collections::BTreeMap::from([("attempt".into(), Vec::new())]);
        assert!(release_run_roots(&run, &expected).is_err());
        assert_eq!(std::fs::read(foreign.join("keep")).unwrap(), b"keep");
        assert!(run.join("attempt").is_symlink());
    }

    #[test]
    fn retention_binds_exact_links_and_rejects_extra_or_changed_roots() {
        let directory = root_fixture();
        let run = directory.path().join("run");
        let roots = run.join("attempt");
        private_directory(&run, true).unwrap();
        private_directory(&roots, true).unwrap();
        let target = directory.path().join("target");
        std::fs::write(&target, b"x").unwrap();
        let outputs = vec![target.to_string_lossy().into_owned()];
        std::os::unix::fs::symlink(&target, roots.join("0")).unwrap();
        let digest = retention(&roots, &outputs).unwrap();
        assert_eq!(retention(&roots, &outputs).unwrap(), digest);
        // Replacing the link (new inode) changes the durable binding.
        std::fs::remove_file(roots.join("0")).unwrap();
        std::os::unix::fs::symlink(&target, roots.join("0")).unwrap();
        let replaced = retention(&roots, &outputs).unwrap();
        std::os::unix::fs::symlink(&target, roots.join("1")).unwrap();
        assert!(retention(&roots, &outputs).is_err());
        std::fs::remove_file(roots.join("1")).unwrap();
        std::fs::remove_file(&target).unwrap();
        assert!(retention(&roots, &outputs).is_err());
        let _ = (digest, replaced);
    }
}

#[cfg(test)]
mod tree_tests {}
