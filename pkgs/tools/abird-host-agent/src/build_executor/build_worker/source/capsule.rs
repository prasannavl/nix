//! Restore operator-produced checkout capsules without operator credentials,
//! original live files, another checkout, or a path-flake conversion.
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use anyhow::{Context, Result, ensure};
use serde_json::Value;

use super::super::{Session, caller_view::View};
use crate::build_executor::preparation::{
    source::{MAX_MATERIAL_BYTES, Material, unhex},
    worker::{NativeRoot, Snapshot},
};
use crate::build_executor::stage::{SourceStep, Stage, Step};
use crate::build_executor::{
    daemon,
    process::{DirectoryFd, Limits, Runner},
};

pub(in crate::build_executor::build_worker) struct NativeContext {
    pub home: PathBuf,
    pub xdg_config_home: PathBuf,
    pub system_configuration: bool,
    bindings: Vec<(PathBuf, PathBuf)>,
    profiles: Vec<(PathBuf, PathBuf)>,
    parent: PathBuf,
    next: u16,
}

impl NativeContext {
    pub(in crate::build_executor::build_worker) fn view(
        &mut self,
        cache: &std::path::Path,
        deadline: Instant,
    ) -> Result<View> {
        ensure!(self.next < 32, "native source view count exceeds bound");
        let root = self.parent.join(format!("native-view-{}", self.next));
        self.next += 1;
        View::prepare_native(&root, &self.bindings, &self.profiles, cache, deadline)
    }
}

impl Session<'_> {
    pub(in crate::build_executor) fn finish_local_capture(
        &mut self,
        mut material: crate::build_executor::native_intent::Material,
    ) -> Result<crate::build_executor::native_intent::Material> {
        use crate::build_executor::native_intent::{CheckoutInput, Validation};
        use crate::build_executor::preparation::capsule::{Capsule, CheckoutExecution};
        self.active()?;
        if material.source.capsule.is_some() {
            return Ok(material);
        }
        let intent = material
            .request
            .parent
            .as_ref()
            .context("local capsule parent missing")?;
        let account = self.caller_account(intent)?;
        let mut git = material
            .source
            .git_context
            .take()
            .context("local common Git missing")?;
        let allocation = self.journal.source_allocation(&self.handle.ownership)?;
        let delivery_digest = match allocation.input {
            Some(crate::build_executor::source_transport::InputState::Received { digest }) => {
                digest
            }
            _ => anyhow::bail!("local capture delivery unconfirmed"),
        };
        let input = CheckoutInput {
            validation: Validation {
                request: material.request.clone(),
                context: material.context.clone(),
            },
            delivery_digest,
            patch: material.source.patch.clone(),
            search_path: git.search_path.clone().context("captured PATH missing")?,
            configuration: git
                .configuration
                .clone()
                .context("captured profile missing")?,
            git_layout: git.layout.clone(),
            runtime_closure: self.role.runtime_closure.clone(),
            limits: self.policy.source_limits,
            budget_millis: self.remaining()?,
        };
        let nar = self.native.native_nar_program()?;
        let payload = serde_json::to_vec(&serde_json::json!({ "input": input,
            "nar": nar, "nar_configuration": self.native.configuration_directory,
            "limits": self.policy.source_limits }))?;
        let directory = self
            .source_slot
            .as_ref()
            .context("local source slot missing")?
            .checkout_path(self.journal, daemon::now()?)?;
        let bytes = CheckoutExecution {
            directory: &directory,
            account: &account,
            input: &input,
            git_context: &mut git,
            manager: &self.role.manager_program,
            git: &self.policy.git_program,
            nar: &nar,
            nar_configuration: &self.native.configuration_directory,
            source_limits: self.policy.source_limits,
            local: true,
            deadline: self.deadline,
        }
        .run(
            &payload,
            &mut Stage::create(&self.handle.ownership, Step::Source)?,
            &mut Stage::create(&self.handle.ownership, Step::CallerCheckout)?,
        )?;
        self.active()?;
        let external = std::mem::take(&mut git.external);
        drop(git);
        let mut capsule: Capsule = serde_json::from_slice(&bytes)?;
        drop(bytes);
        for (hash, image) in external {
            ensure!(
                capsule.roots.insert(hash, image).is_none(),
                "local native roots alias"
            );
        }
        capsule.validate(&material.request)?;
        capsule.require_limits(self.policy.source_limits, &material.source.snapshots)?;
        material.context["git_context_digest"] = Value::String(capsule.digest()?);
        material.source.capsule = Some(capsule);
        material.source.version = 2;
        material.validate(
            material
                .request
                .parent
                .as_ref()
                .context("local parent missing")?,
        )?;
        Ok(material)
    }

    pub(super) fn restore_capsule(&mut self, mut material: Material) -> Result<()> {
        let request = self.request.clone().context("capsule request missing")?;
        let mut capsule = material.capsule.context("checkout capsule missing")?;
        capsule.validate(&request)?;
        let validation = self
            .native_capture
            .as_ref()
            .context("capsule validation missing")?;
        ensure!(
            validation
                .context
                .get("git_context_digest")
                .and_then(Value::as_str)
                == Some(capsule.digest()?.as_str()),
            "checkout capsule admission differs"
        );
        let slot = self
            .source_slot
            .take()
            .context("capsule delivery was not claimed")?;
        let allocation = self.journal.source_allocation(&self.handle.ownership)?;
        capsule.require_limits(allocation.limits, &material.snapshots)?;
        let producer = slot.private_producer(self.journal, self.policy.gid, daemon::now()?)?;
        let mut runner = Runner::new_source(
            allocation.source_uid,
            Limits {
                stdin: MAX_MATERIAL_BYTES / 2,
                stdout: 64,
                stderr: 4096,
            },
            self.deadline,
            MAX_MATERIAL_BYTES / 2,
        )?;
        for (ordinal, (hash, root)) in capsule.roots.iter_mut().enumerate() {
            self.active()?;
            root.image.require_limits(allocation.limits)?;
            let scope = DirectoryFd::new(&producer.directory)?;
            let mut command = self
                .native
                .native_restore(&scope.path().join(format!("git-{hash}")))?;
            let mut stage = Stage::source(
                &self.handle.ownership,
                SourceStep::Restore,
                u16::try_from(ordinal)?,
            )?;
            let output = runner.run_as_directory(
                &mut command,
                &root.image.archive()?,
                self.policy.gid,
                scope,
                &mut stage,
            )?;
            ensure!(
                output.status.success() && output.stdout.is_empty(),
                "capsule restore failed"
            );
            // The original subgroup is empty before any timestamp/sealing work.
            root.image.restore_times(
                &producer.path.join(format!("git-{hash}")),
                allocation.source_uid,
                allocation.limits,
                self.deadline,
            )?;
            // The frame digest and complete image were validated before any
            // restore. Only sealed bytes/paths are needed past this point.
            drop(std::mem::take(&mut root.image.nar));
        }
        for (ordinal, (hash, nar)) in material.snapshots.iter_mut().enumerate() {
            self.active()?;
            let scope = DirectoryFd::new(&producer.directory)?;
            let mut command = self
                .native
                .native_restore(&scope.path().join(format!("context-{hash}")))?;
            let mut stage = Stage::source(
                &self.handle.ownership,
                SourceStep::Restore,
                u16::try_from(ordinal + capsule.roots.len())?,
            )?;
            let output = runner.run_as_directory(
                &mut command,
                &unhex(nar, MAX_MATERIAL_BYTES / 2)?,
                self.policy.gid,
                scope,
                &mut stage,
            )?;
            ensure!(
                output.status.success() && output.stdout.is_empty(),
                "capsule data restore failed"
            );
            drop(std::mem::take(nar));
        }
        self.active()?;
        // One fresh-copy budget across all roots and contexts, never per-root
        // admission expansion. No restored producer retains the sealed inodes.
        let sealed = slot.freeze_private(self.journal, &producer, self.deadline, daemon::now()?)?;
        slot.grant_private_reader(
            self.journal,
            &producer,
            self.policy.uid,
            self.deadline,
            daemon::now()?,
        )?;
        let mut bindings = vec![(sealed.clone(), sealed.clone())];
        for (hash, root) in &capsule.roots {
            let image = sealed.join(format!("git-{hash}"));
            let common = image.join("common");
            ensure!(
                std::fs::symlink_metadata(&common)?.is_dir()
                    && std::fs::symlink_metadata(image.join("worktree"))?.is_dir(),
                "invalid capsule image layout"
            );
            for redirect in [
                "commondir",
                "gitdir",
                "objects/info/alternates",
                "objects/info/http-alternates",
            ] {
                ensure!(
                    matches!(std::fs::symlink_metadata(common.join(redirect)),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound),
                    "capsule common Git directory redirects outside its binding"
                );
            }
            super::walk(&common, allocation.limits.entries, self.deadline, true)?;
            bindings.push((root.worktree.clone(), image.join("worktree")));
            bindings.push((root.common.clone(), common));
        }
        // Data-only snapshots are imported from the private sealed allocation;
        // expose only those exact trees to the trusted native importer as well.
        for hash in material.snapshots.keys() {
            let tree = sealed.join(format!("context-{hash}"));
            bindings.push((tree.clone(), tree));
        }
        // Ambiguous namespace mounts are not merged or overwritten.
        bindings.sort_by(|a, b| a.0.cmp(&b.0));
        ensure!(
            bindings.windows(2).all(|pair| pair[0].0 != pair[1].0),
            "capsule native namespaces alias"
        );
        let parent = producer
            .path
            .parent()
            .context("capsule parent missing")?
            .to_owned();
        let roots = capsule
            .roots
            .values()
            .map(|root| (root.worktree.clone(), root.common.clone()))
            .collect::<Vec<_>>();
        let profiles = capsule.configuration.install_native(
            &parent.join("native-profile"),
            &capsule.home,
            &capsule.xdg_config_home,
            &roots,
            self.policy.uid,
            self.deadline,
        )?;
        self.cache = Some(slot.cache(
            self.journal,
            self.policy.uid,
            &self.policy.git_configuration,
            daemon::now()?,
        )?);
        self.native_context = Some(NativeContext {
            home: capsule.home.clone(),
            xdg_config_home: capsule.xdg_config_home.clone(),
            system_configuration: capsule.system_configuration,
            bindings,
            profiles,
            parent,
            next: 0,
        });
        let mut native_roots = BTreeMap::new();
        for (hash, root) in &capsule.roots {
            if hash == &capsule.primary {
                continue;
            }
            let reference = format!(
                "file://{}",
                super::uri(root.worktree.to_str().context("non-UTF8 native root")?)
            );
            let mut command = self.native.native_client()?;
            command.args(["eval", "--raw", "--impure", "--option",
                "allow-import-from-derivation", "false", "--option", "eval-cache", "false", "--expr"])
                .arg(format!("({}) builtins.toJSON (builtins.fetchTree {{ type = \"git\"; url = \"{reference}\"; }})",
                    crate::build_executor::preparation::source::NATIVE_METADATA_JSON));
            let mut stage = Stage::source(&self.handle.ownership, SourceStep::Import, 16)?;
            let info: Value = serde_json::from_slice(&self.run(&mut command, &mut stage)?)?;
            let path = info
                .get("outPath")
                .and_then(Value::as_str)
                .context("independent native source path missing")?
                .to_owned();
            crate::build_executor::request::store_path(&path)?;
            self.roots
                .retain(self.journal, self.gate, std::slice::from_ref(&path))?;
            let mut command = self.native.native_hash(&path)?;
            let mut stage = Stage::source(&self.handle.ownership, SourceStep::Hash, 16)?;
            let nar_digest = super::native_line(self.run(&mut command, &mut stage)?)?;
            native_roots.insert(
                hash.clone(),
                NativeRoot {
                    source: Snapshot { path, nar_digest },
                    native_source: root.worktree.clone(),
                    native_info: info,
                    revision: root.revision.clone(),
                },
            );
        }
        let primary = capsule.primary()?.worktree.clone();
        let observation = request.binding_digest()?;
        self.import_and_evaluate(
            request,
            primary,
            &material.snapshots,
            &sealed,
            observation,
            native_roots,
        )?;
        // Realization/verification needs no caller namespace/profile access.
        self.native_context = None;
        Ok(())
    }
}
