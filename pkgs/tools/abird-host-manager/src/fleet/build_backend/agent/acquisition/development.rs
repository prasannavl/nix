//! Persistent DevBuild outputs. Location and naming come from retained capture,
//! never the reconnect working directory. No build/import operation is allowed.

use std::collections::BTreeMap;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

use abird_host_agent::build_executor::{ArtifactDelivery, native_intent::CallerRepository};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};

use super::{native, retained_paths, retention};
use crate::fleet::build_backend::agent::controller::Controller;
use crate::fleet::cli::{Action, Invocation};

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Development {
    pub repository: PathBuf,
    pub identity: (u64, u64),
    pub shared: bool,
    pub links: BTreeMap<String, String>,
}

impl Development {
    pub(super) fn new(
        repository: &CallerRepository,
        shared: bool,
        links: BTreeMap<String, String>,
    ) -> Result<Self> {
        repository.validate()?;
        let value = Self {
            repository: repository.path.clone(),
            identity: (repository.device, repository.inode),
            shared,
            links,
        };
        value.validate()?;
        Ok(value)
    }

    pub(super) fn validate(&self) -> Result<()> {
        ensure!(
            self.repository.is_absolute()
                && self
                    .repository
                    .components()
                    .all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
                && !self.repository.starts_with("/nix/store")
                && std::fs::canonicalize(&self.repository)? == self.repository,
            "development repository is not the original canonical caller path"
        );
        // No other principal may replace an ancestor after validation. Sticky
        // parents such as /tmp are safe because each following node is owned
        // by this caller or root; merely checking the repository leaf is not.
        for ancestor in self.repository.ancestors() {
            let metadata = std::fs::symlink_metadata(ancestor)?;
            ensure!(
                metadata.is_dir()
                    && (metadata.uid() == 0 || metadata.uid() == unsafe { libc::geteuid() })
                    && (metadata.mode() & 0o022 == 0 || metadata.mode() & 0o1000 != 0),
                "development repository ancestor can be replaced by another principal"
            );
        }
        let metadata = std::fs::symlink_metadata(&self.repository)?;
        ensure!(
            metadata.is_dir()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.mode() & 0o022 == 0
                && (metadata.dev(), metadata.ino()) == self.identity,
            "development repository identity/ownership differs"
        );
        ensure!(
            self.links.len() <= 1024,
            "too many development result links"
        );
        for (name, target) in &self.links {
            component(name)?;
            crate::fleet::build::NixStorePath::closure_output(target)?;
        }
        Ok(())
    }
}

fn component(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 255
            && name != "."
            && name != ".."
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)),
        "unsafe development result name"
    );
    Ok(())
}

fn names(
    invocation: &Invocation,
    outputs: &BTreeMap<String, BTreeMap<String, String>>,
) -> Result<BTreeMap<String, String>> {
    ensure!(
        invocation.action == Action::DevBuild,
        "not a development handoff"
    );
    let mut links = BTreeMap::new();
    for (host, outputs) in outputs {
        ensure!(
            outputs.contains_key("out"),
            "verified development out output missing"
        );
        let name = if invocation.options.host.as_deref() == Some(host.as_str()) {
            invocation.options.nix_config.as_deref().unwrap_or(host)
        } else {
            host
        };
        component(name)?;
        // Ordinary DevBuild selects ^out, not every output in the derivation.
        ensure!(
            links
                .insert(name.to_owned(), outputs["out"].clone())
                .is_none(),
            "development result names collide"
        );
    }
    Ok(links)
}

pub(crate) fn publish(
    controller: &mut Controller,
    attempt: &str,
    nix: &Path,
    deadline: Instant,
) -> Result<()> {
    ensure!(!controller.cancelled()?, "development handoff cancelled");
    let invocation = controller.original_invocation(attempt)?;
    let delivery: ArtifactDelivery = controller.retained(attempt)?;
    let repository = delivery
        .prepared
        .caller_repository
        .as_ref()
        .context("original development destination was not captured; retain this run")?;
    let outputs = delivery
        .prepared
        .targets
        .iter()
        .map(|target| {
            Ok((
                target.target.host.clone(),
                delivery.host_outputs(&target.target.host)?,
            ))
        })
        .collect::<Result<BTreeMap<_, _>>>()?;
    let links = names(&invocation, &outputs)?;
    if links.is_empty() {
        return Ok(());
    }
    let shared = controller.shares_store(attempt)?;
    let development = Development::new(repository, shared, links)?;
    let roots = controller.consumer_roots(attempt)?;
    let paths = retained_paths(&delivery, false);
    let ack = controller.recorded_consumer(attempt)?.clone();
    ensure!(
        retention(&roots, &paths)? == ack.retention_digest,
        "original development protection differs"
    );
    let source = controller.retained_acquisition_source(attempt)?;
    let (binding, store_id) = super::consumer_binding(shared, &source, nix, &roots, false)?;
    controller.require_acquisition_binding(attempt, &binding, store_id)?;
    let lock = controller.acquisition_lock()?;
    let request = native::Request::development(
        native::Input {
            program: nix,
            source: &source,
            roots: &roots,
            tree: false,
            delivery: &delivery,
        },
        development,
        deadline,
        &lock,
    )?;
    ensure!(
        shared || request.binding()? == binding,
        "development destination changed before publication"
    );
    let cancellation = controller.cancellation_probe()?;
    controller.begin_native_helper(attempt)?;
    let reply = native::run(&request, &lock, deadline, || {
        crate::fleet::signal::check_interrupted()?;
        cancellation.check()
    })?;
    controller.native_helper_returned(attempt)?;
    ensure!(
        reply.development_published && reply.import_state == native::ImportState::NotStarted,
        "development result publication unconfirmed; retain this run"
    );
    ensure!(
        retention(&roots, &paths)? == ack.retention_digest,
        "original development protection changed"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_names_match_ordinary_single_host_configuration_rule() {
        let outputs = BTreeMap::from([
            (
                "app".into(),
                BTreeMap::from([
                    ("out".into(), "app-output".into()),
                    ("dev".into(), "dev-output".into()),
                ]),
            ),
            (
                "other".into(),
                BTreeMap::from([("out".into(), "other-output".into())]),
            ),
        ]);
        let mut invocation =
            Invocation::parse_legacy(["dev-build", "--host=app", "--nix-config=custom"]).unwrap();
        assert_eq!(
            names(&invocation, &outputs).unwrap(),
            BTreeMap::from([
                ("custom".into(), "app-output".into()),
                ("other".into(), "other-output".into()),
            ])
        );
        invocation.options.host = None;
        assert!(names(&invocation, &outputs).unwrap().contains_key("app"));
        invocation.options.host = Some("app".into());
        invocation.options.nix_config = Some("../escape".into());
        assert!(names(&invocation, &outputs).is_err());
    }

    #[test]
    fn publication_binds_original_repository_and_rejects_symlink_replacement() {
        use std::os::unix::fs::symlink;
        let root = tempfile::tempdir().unwrap();
        let repo = root.path().join("repo");
        std::fs::create_dir(&repo).unwrap();
        let metadata = std::fs::symlink_metadata(&repo).unwrap();
        let original = CallerRepository {
            path: repo.clone(),
            device: metadata.dev(),
            inode: metadata.ino(),
        };
        let value = Development::new(&original, false, BTreeMap::new()).unwrap();
        std::fs::rename(&repo, root.path().join("old")).unwrap();
        std::fs::create_dir(&repo).unwrap();
        assert!(value.validate().is_err());
        // Reconstructing a publication never samples a replacement identity.
        assert!(Development::new(&original, false, BTreeMap::new()).is_err());
        std::fs::remove_dir(&repo).unwrap();
        symlink(root.path().join("old"), &repo).unwrap();
        assert!(Development::new(&original, false, BTreeMap::new()).is_err());
    }
}
