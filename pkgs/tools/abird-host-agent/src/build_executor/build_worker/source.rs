//! One admitted source production, settled producers, fresh immutable replica,
//! native Git import and per-flake consumed-context anchors. No replay/recovery.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::Instant;

use anyhow::{Context, Result, ensure};
use serde_json::Value;

mod capsule;
use super::Session;
use crate::build_executor::daemon;
use crate::build_executor::preparation::{
    source::{MAX_MATERIAL_BYTES, Material, ProducerInput, unhex},
    worker::{Input, Snapshot},
};
use crate::build_executor::process::{Limits, Runner};
use crate::build_executor::stage::{SourceStep, Stage, Step};
pub(super) use capsule::NativeContext;

pub(super) struct Production {
    directory: fs::File,
    input: ProducerInput,
    observation: String,
}

impl Session<'_> {
    /// Same source allocation/helper as ordinary production. Resolve metadata
    /// after the selected checkout, then retain it for sealing without recloning.
    pub(super) fn produce_repository(
        &mut self,
        intent: &crate::build_executor::native_intent::Request,
        recipe: crate::build_executor::native_intent::RepositoryRecipe,
    ) -> Result<crate::build_executor::native_intent::Material> {
        self.active()?;
        recipe.validate(intent)?;
        ensure!(
            self.repository_production.is_none() && !self.source_claimed,
            "configured source already produced"
        );
        let slot = self
            .source_slot
            .as_ref()
            .context("source delivery was not claimed")?;
        let (directory, producer) = slot.producer(self.journal, daemon::now()?)?;
        let input = ProducerInput {
            version: 1,
            source: recipe.source.clone(),
            url: self.policy.repositories[&intent.repository_id].clone(),
            directory: producer,
            patch: recipe.patch,
            budget_millis: self.remaining()?,
            runtime_closure: self.role.runtime_closure.clone(),
            limits: self.policy.source_limits,
        };
        let bound =
            crate::build_executor::preparation::source::material_limit(self.policy.source_limits)?;
        let mut runner = Runner::new_source(
            self.policy.source_uid,
            Limits {
                stdin: bound,
                stdout: bound,
                stderr: 128 * 1024,
            },
            self.deadline,
            bound,
        )?;
        let mut command = self.source_helper("repository");
        let mut stage = Stage::create(&self.handle.ownership, Step::Source)?;
        let output = self.journal.diagnose(&self.handle, stage.activity(), || {
            let output = runner.run_as(
                &mut command,
                &serde_json::to_vec(&serde_json::json!({
                    "producer": &input, "intent": intent, "source_root": &recipe.source_root,
                }))?,
                self.policy.gid,
                &mut stage,
            )?;
            ensure!(
                output.status.success(),
                "configured source preparation failed"
            );
            Ok(output)
        })?;
        self.active()?;
        let output: crate::build_executor::preparation::source::RepositoryOutput =
            serde_json::from_slice(&output.stdout)?;
        crate::build_executor::digest(&output.observation)?;
        output.material.validate(intent)?;
        ensure!(
            output.material.request.source == input.source
                && output.material.source.patch == input.patch
                && output.material.source.snapshots.is_empty()
                && output.material.source.git_context.is_none()
                && output.material.source.capsule.is_none(),
            "configured source resolution differs"
        );
        self.repository_production = Some(Production {
            directory,
            input,
            observation: output.observation,
        });
        Ok(output.material)
    }

    pub(in crate::build_executor) fn materialize(&mut self, material: Material) -> Result<()> {
        self.active()?;
        ensure!(!self.source_claimed, "source already dispatched");
        self.source_claimed = true;
        let journal = self.journal;
        let handle = self.handle.clone();
        let result = journal.diagnose(
            &handle,
            crate::build_executor::diagnostics::Activity::Source,
            || self.source_once(material),
        );
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn source_once(&mut self, material: Material) -> Result<()> {
        let request = self.request.clone().context("native input is unresolved")?;
        material.validate(&request)?;
        if material.capsule.is_some() {
            return self.restore_capsule(material);
        }
        // Installed capture keeps its original private Git image; never reclone
        // an approved URL under different credentials/configuration.
        if request
            .parent
            .as_ref()
            .is_some_and(|parent| parent.bootstrap_digest.is_some())
        {
            return self.retain_caller_git(material);
        }
        let slot = self
            .source_slot
            .take()
            .context("source delivery was not claimed")?;
        let (directory, producer, produced) =
            if let Some(production) = self.repository_production.take() {
                ensure!(
                    production.input.source == request.source
                        && production.input.patch == material.patch,
                    "configured source was replaced after resolution"
                );
                (
                    production.directory,
                    production.input.directory,
                    Some(production.observation),
                )
            } else {
                let (directory, producer) = slot.producer(self.journal, daemon::now()?)?;
                (directory, producer, None)
            };
        self.cache = Some(slot.cache(
            self.journal,
            self.policy.uid,
            &self.policy.git_configuration,
            daemon::now()?,
        )?);
        let mut input = ProducerInput {
            version: 1,
            source: request.source.clone(),
            url: self.policy.repositories[&request.repository_id].clone(),
            directory: producer.clone(),
            patch: material.patch,
            budget_millis: self.remaining()?,
            runtime_closure: self.role.runtime_closure.clone(),
            limits: self.policy.source_limits,
        };
        let bound =
            crate::build_executor::preparation::source::material_limit(self.policy.source_limits)?;
        let mut runner = Runner::new_source(
            self.policy.source_uid,
            Limits {
                stdin: bound,
                stdout: 128 * 1024,
                stderr: 128 * 1024,
            },
            self.deadline,
            bound,
        )?;
        let observation = if let Some(observation) = produced {
            observation
        } else {
            let mut command = self.source_helper("produce");
            let mut stage = Stage::create(&self.handle.ownership, Step::Source)?;
            let output = self.journal.diagnose(&self.handle, stage.activity(), || {
                let output = runner.run_as(
                    &mut command,
                    &serde_json::to_vec(&input)?,
                    self.policy.gid,
                    &mut stage,
                )?;
                ensure!(output.status.success(), "source production failed");
                Ok(output)
            })?;
            std::str::from_utf8(&output.stdout)
                .context("invalid source observation")?
                .to_owned()
        };
        crate::build_executor::digest(&observation)?;
        self.active()?;
        // Restores have no store backend and run as the producer UID. Digest and
        // exact context coverage were checked before the first restore effect.
        for (ordinal, (hash, bytes)) in material.snapshots.iter().enumerate() {
            self.active()?;
            let mut command = self
                .native
                .native_restore(&producer.join(format!("context-{hash}")))?;
            let mut stage = Stage::source(
                &self.handle.ownership,
                SourceStep::Restore,
                u16::try_from(ordinal)?,
            )?;
            self.journal.diagnose(&self.handle, stage.activity(), || {
                let output = runner.run_as(
                    &mut command,
                    &unhex(bytes, MAX_MATERIAL_BYTES / 2)?,
                    self.policy.gid,
                    &mut stage,
                )?;
                ensure!(output.status.success(), "context restore failed");
                Ok(())
            })?;
            self.active()?;
        }
        // Each run_as returned only after positive original subgroup emptiness.
        // No producer receives the new inodes or writable destination handles.
        let sealed = self.journal.diagnose(
            &self.handle,
            crate::build_executor::diagnostics::Activity::SourceSeal,
            || slot.freeze(self.journal, &directory, self.deadline, daemon::now()?),
        )?;
        self.active()?;
        require_git_layout(
            &sealed.join("repository"),
            self.policy.source_limits.entries,
            self.deadline,
        )?;
        input.directory = sealed.clone();
        input.budget_millis = self.remaining()?;
        let mut command = self.source_helper("observe");
        let mut stage = Stage::create(&self.handle.ownership, Step::SourceCheck)?;
        self.journal.diagnose(&self.handle, stage.activity(), || {
            let observed = runner.run_as(
                &mut command,
                &serde_json::to_vec(&input)?,
                self.policy.gid,
                &mut stage,
            )?;
            ensure!(
                observed.status.success() && observed.stdout == observation.as_bytes(),
                "sealed native source context differs"
            );
            Ok(())
        })?;
        self.active()?;
        // Do not pre-evaluate #sourceInfo as a stand-in for later consumption.
        // The preparation helper returns roots from its actual native queries.
        self.import_and_evaluate(
            request,
            sealed.join("repository"),
            &material.snapshots,
            &sealed,
            observation,
            BTreeMap::new(),
        )
    }

    /// Shared native import of one sealed Git view, then the single preparation
    /// dispatch. Same worker guard/deadline; no recapture, clone or replay.
    fn import_and_evaluate(
        &mut self,
        request: crate::build_executor::request::BuildRequest,
        repository: std::path::PathBuf,
        contexts: &BTreeMap<String, String>,
        sealed: &Path,
        observation: String,
        native_roots: BTreeMap<String, crate::build_executor::preparation::worker::NativeRoot>,
    ) -> Result<()> {
        let reference = format!(
            "file://{}",
            uri(repository.to_str().context("non-UTF8 sealed repository")?)
        );
        let mut command = self.native.native_client()?;
        self.git_context(&mut command)?;
        command
            .args([
                "eval",
                "--raw",
                "--impure",
                "--option",
                "allow-import-from-derivation",
                "false",
                "--option",
                "eval-cache",
                "false",
                "--expr",
            ])
            .arg(format!(
                "({}) builtins.toJSON (builtins.fetchTree {{ type = \"git\"; url = \"{reference}\"; }})",
                crate::build_executor::preparation::source::NATIVE_METADATA_JSON
            ));
        let mut stage = Stage::create(&self.handle.ownership, Step::SourceImport)?;
        let info: serde_json::Map<String, Value> =
            serde_json::from_slice(&self.run(&mut command, &mut stage)?)?;
        let path = info
            .get("outPath")
            .and_then(Value::as_str)
            .context("native source path missing")?
            .to_owned();
        crate::build_executor::request::store_path(&path)?;
        self.roots
            .retain(self.journal, self.gate, std::slice::from_ref(&path))?;
        let mut command = self.native.native_hash(&path)?;
        let mut stage = Stage::source(&self.handle.ownership, SourceStep::Hash, 0)?;
        let hash = native_line(self.run(&mut command, &mut stage)?)?;
        crate::build_executor::digest(&hash)?;
        let mut snapshots = BTreeMap::new();
        for (ordinal, expected) in contexts.keys().enumerate() {
            let tree = sealed.join(format!("context-{expected}"));
            ensure!(tree.is_dir(), "context NAR is not a directory");
            reject_git_metadata(&tree, self.policy.source_limits.entries, self.deadline)?;
            let mut command = self.native.native_client()?;
            self.git_context(&mut command)?;
            command
                .args([
                    "store",
                    "add",
                    "--mode",
                    "nar",
                    "--name",
                    "owned-context",
                    "--",
                ])
                .arg(&tree);
            let mut stage = Stage::source(
                &self.handle.ownership,
                SourceStep::Import,
                u16::try_from(ordinal)?,
            )?;
            let path = native_line(self.run(&mut command, &mut stage)?)?;
            crate::build_executor::request::store_path(&path)?;
            self.roots
                .retain(self.journal, self.gate, std::slice::from_ref(&path))?;
            snapshots.insert(expected.clone(), path);
        }
        self.source_observation = Some(observation);
        let protection_digest = self.roots.verify(self.journal)?.digest()?;
        let caller_repository = self
            .native_capture
            .as_ref()
            .map(crate::build_executor::native_intent::Validation::caller_repository)
            .transpose()?
            .flatten();
        self.evaluate(Input {
            version: 4,
            request,
            source: Snapshot {
                path,
                nar_digest: hash,
            },
            protection_digest,
            snapshots,
            native_source: repository,
            native_info: Value::Object(info),
            native_roots,
            caller_repository,
            native_system: self.native.system.clone(),
            budget_millis: self.remaining()?,
        })
    }

    fn retain_caller_git(&mut self, material: Material) -> Result<()> {
        let git = material
            .git_context
            .context("captured caller Git context missing")?;
        let validation = self
            .native_capture
            .clone()
            .context("captured caller validation missing")?;
        ensure!(
            validation
                .context
                .get("git_context_digest")
                .and_then(Value::as_str)
                == Some(git.digest()?.as_str()),
            "captured caller Git binding differs"
        );
        let account = self.caller_account(
            validation
                .request
                .parent
                .as_deref()
                .context("caller admission missing")?,
        )?;
        let allocation = self.journal.source_allocation(&self.handle.ownership)?;
        ensure!(
            allocation.source_uid == account.uid,
            "caller source allocation credential differs"
        );
        let delivery_digest = match allocation.input {
            Some(crate::build_executor::source_transport::InputState::Received { digest }) => {
                digest
            }
            _ => anyhow::bail!("caller checkout delivery is unconfirmed"),
        };
        let checkout_input = crate::build_executor::native_intent::CheckoutInput {
            validation,
            delivery_digest,
            patch: material.patch,
            search_path: git
                .search_path
                .clone()
                .context("captured caller PATH binding missing")?,
            configuration: git
                .configuration
                .clone()
                .context("captured caller Git configuration missing")?,
            git_layout: git.layout.clone(),
            runtime_closure: self.role.runtime_closure.clone(),
            limits: self.policy.source_limits,
            budget_millis: self.remaining()?,
        };
        checkout_input.validate()?;
        let (_, checkout) = checkout_input.context()?;
        let slot = self
            .source_slot
            .take()
            .context("source delivery was not claimed")?;
        let producer = slot.private_producer(self.journal, account.gid, daemon::now()?)?;
        let scope = crate::build_executor::process::DirectoryFd::new(&producer.directory)?;
        let mut command = self.native.native_restore(&scope.path().join(".git"))?;
        let bound =
            crate::build_executor::preparation::source::material_limit(self.policy.source_limits)?;
        let mut runner = Runner::new_source(
            account.uid,
            Limits {
                stdin: bound / 2,
                stdout: 64,
                stderr: 4096,
            },
            self.deadline,
            bound,
        )?;
        let mut stage = Stage::create(&self.handle.ownership, Step::Source)?;
        self.active()?;
        self.journal.diagnose(&self.handle, stage.activity(), || {
            let output = runner.run_as_directory(
                &mut command,
                &git.archive()?,
                account.gid,
                scope,
                &mut stage,
            )?;
            ensure!(
                output.status.success() && output.stdout.is_empty(),
                "caller Git context restore failed"
            );
            Ok(())
        })?;
        self.active()?;
        // Only after the original restore subgroup is positively empty. Native
        // NARs omit timestamps; restore them before copying to fresh sealed inodes.
        git.restore_times(
            &producer.path.join(".git"),
            account.uid,
            self.policy.source_limits,
            self.deadline,
        )?;
        let view = super::caller_view::View::prepare(
            producer
                .path
                .parent()
                .context("caller view parent missing")?,
            &producer.path,
            &checkout_input,
            &account,
            self.deadline,
        )?;
        let workspace = view.workspace.clone();
        let mut input = checkout_input;
        input.budget_millis = self.remaining()?;
        input.validate()?;
        let mut command = self
            .role
            .manager(crate::build_executor::role::ManagerCommand::Capture);
        command
            .arg("--checkout")
            .arg(&self.policy.git_program)
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", &account.home)
            .env("XDG_STATE_HOME", &account.state_home)
            .env("LC_ALL", "C")
            .env("PATH", &self.native.search_path)
            .env("GIT_CONFIG_GLOBAL", &self.policy.git_configuration)
            .envs(crate::build_executor::native_intent::CALLER_GIT_PROFILE);
        let mut runner = Runner::new_source(
            account.uid,
            Limits {
                stdin: bound,
                stdout: 64,
                stderr: 4096,
            },
            self.deadline,
            bound,
        )?
        .with_umask(checkout.umask)?;
        let mut stage = Stage::create(&self.handle.ownership, Step::CallerCheckout)?;
        self.journal.diagnose(&self.handle, stage.activity(), || {
            let result = runner.run_as_view(
                &mut command,
                &serde_json::to_vec(&input)?,
                account.gid,
                &account.groups,
                view,
                &mut stage,
            )?;
            ensure!(
                result.status.success()
                    && result.stdout == input.validation.request.binding_digest()?.as_bytes(),
                "original caller checkout failed"
            );
            Ok(())
        })?;
        self.active()?;
        slot.collect_checkout(self.journal, &producer, &workspace, daemon::now()?)?;
        // Raw Git config may carry credentials. Unlike evaluated source trees,
        // this retained image must not be published to the native reader group.
        let sealed = self.journal.diagnose(
            &self.handle,
            crate::build_executor::diagnostics::Activity::SourceSeal,
            || slot.freeze_private(self.journal, &producer, self.deadline, daemon::now()?),
        )?;
        require_git_layout(&sealed, self.policy.source_limits.entries, self.deadline)?;
        self.active()?;
        // External context trees need their own captured Git context; never
        // substitute a NAR snapshot for a caller repository.
        ensure!(
            material.snapshots.is_empty(),
            "caller context snapshots lack their own Git context"
        );
        // The original checkout is a linked worktree of the caller's restored
        // repository. Relocate only its two admin pointers (`git worktree
        // repair` semantics), then grant the exact native client read access.
        let worktree = self.journal.diagnose(
            &self.handle,
            crate::build_executor::diagnostics::Activity::SourceCheckout,
            || {
                let worktree = relocate_worktree(&sealed)?;
                slot.grant_private_reader(
                    self.journal,
                    &producer,
                    self.policy.uid,
                    self.deadline,
                    daemon::now()?,
                )?;
                Ok(worktree)
            },
        )?;
        self.active()?;
        self.cache = Some(slot.cache(
            self.journal,
            self.policy.uid,
            &self.policy.git_configuration,
            daemon::now()?,
        )?);
        // Upstream consumption of this exact view is proved by the adapter's
        // accessor binding against the protected import, not by this layout.
        let observation = input.validation.request.binding_digest()?;
        let request = self.request.clone().context("native input is unresolved")?;
        self.import_and_evaluate(
            request,
            worktree,
            &BTreeMap::new(),
            &sealed,
            observation,
            BTreeMap::new(),
        )
    }

    fn source_helper(&self, operation: &str) -> std::process::Command {
        let mut command = self
            .role
            .manager(crate::build_executor::role::ManagerCommand::Source);
        command
            .arg(operation)
            .arg(&self.policy.git_program)
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", "/var/empty")
            .env("LC_ALL", "C")
            .env("PATH", &self.native.search_path)
            .env("GIT_CONFIG_GLOBAL", &self.policy.git_configuration)
            .env("GIT_CONFIG_NOSYSTEM", "1");
        command
    }

    pub(super) fn git_context(&self, command: &mut std::process::Command) -> Result<()> {
        let cache = self.cache.as_ref().context("source cache unavailable")?;
        command
            .env("GIT_CONFIG_GLOBAL", &self.policy.git_configuration)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_OPTIONAL_LOCKS", "0")
            .env("XDG_CACHE_HOME", cache)
            // Upstream libgit2 reads only XDG/HOME global configuration.
            .env("XDG_CONFIG_HOME", cache.with_file_name("config"));
        if let Some(context) = &self.native_context {
            command
                .env("HOME", &context.home)
                .env("XDG_CONFIG_HOME", &context.xdg_config_home)
                .env("GIT_CONFIG_GLOBAL", context.home.join(".gitconfig"));
            if context.system_configuration {
                command.env_remove("GIT_CONFIG_NOSYSTEM");
            }
        }
        Ok(())
    }

    fn remaining(&self) -> Result<u64> {
        self.active()?;
        Ok(u64::try_from(
            self.deadline
                .saturating_duration_since(Instant::now())
                .as_millis(),
        )?)
    }
}

/// Relocate the sealed linked worktree's two absolute admin pointers to the
/// sealed copy. Content, HEAD, index, objects and config are unchanged. Per-
/// worktree configuration fails closed rather than being merged.
fn relocate_worktree(sealed: &Path) -> Result<std::path::PathBuf> {
    use std::io::Write;
    let checkout = sealed.join("checkout");
    let pointer = checkout.join(".git");
    ensure!(
        fs::symlink_metadata(&pointer)?.is_file(),
        "caller checkout is not a linked worktree"
    );
    let text = fs::read_to_string(&pointer)?;
    let original = text
        .strip_prefix("gitdir: ")
        .and_then(|value| value.strip_suffix('\n'))
        .context("invalid worktree pointer")?;
    let original = Path::new(original);
    let name = original
        .file_name()
        .and_then(|name| name.to_str())
        .context("invalid worktree name")?;
    ensure!(
        original.is_absolute()
            && original.parent().and_then(Path::file_name) == Some("worktrees".as_ref())
            && !name.is_empty()
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
            && !matches!(name, "." | ".."),
        "worktree pointer outside its common directory"
    );
    let admin = sealed.join(".git/worktrees").join(name);
    ensure!(
        fs::read_to_string(admin.join("commondir"))? == "../..\n"
            && fs::symlink_metadata(admin.join("config.worktree")).is_err()
            && fs::read_to_string(admin.join("gitdir"))?.ends_with("/.git\n"),
        "caller worktree administration differs"
    );
    let write = |path: &Path, value: String| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .truncate(true)
            .open(path)?;
        file.write_all(value.as_bytes())?;
        file.sync_all()?;
        Ok(())
    };
    let utf8 = |path: &Path| -> Result<String> {
        Ok(path
            .to_str()
            .context("non-UTF8 sealed worktree")?
            .to_owned())
    };
    write(&pointer, format!("gitdir: {}\n", utf8(&admin)?))?;
    write(&admin.join("gitdir"), format!("{}\n", utf8(&pointer)?))?;
    Ok(checkout)
}

fn native_line(bytes: Vec<u8>) -> Result<String> {
    let value = std::str::from_utf8(&bytes)?
        .strip_suffix('\n')
        .context("native line terminator missing")?;
    ensure!(!value.contains(['\n', '\r']), "ambiguous native line");
    Ok(value.to_owned())
}

fn uri(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~/".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

fn require_git_layout(root: &Path, limit: u32, deadline: Instant) -> Result<()> {
    let git = root.join(".git");
    ensure!(
        fs::symlink_metadata(&git)?.is_dir(),
        "source Git metadata is not standalone"
    );
    for path in [
        "commondir",
        "gitdir",
        "objects/info/alternates",
        "objects/info/http-alternates",
    ] {
        match fs::symlink_metadata(git.join(path)) {
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            _ => anyhow::bail!("source Git metadata redirects outside the sealed replica"),
        }
    }
    walk(&git, limit, deadline, true)
}

fn reject_git_metadata(root: &Path, limit: u32, deadline: Instant) -> Result<()> {
    walk(root, limit, deadline, false)
}

fn walk(root: &Path, limit: u32, deadline: Instant, git: bool) -> Result<()> {
    let mut pending = vec![root.to_owned()];
    let mut entries = 0u32;
    while let Some(directory) = pending.pop() {
        for entry in fs::read_dir(directory)? {
            ensure!(
                Instant::now() < deadline && entries < limit,
                "source layout observation exceeds bound"
            );
            entries += 1;
            let entry = entry?;
            let kind = entry.file_type()?;
            if git {
                ensure!(!kind.is_symlink(), "source Git metadata contains a symlink");
            } else {
                ensure!(entry.file_name() != ".git", "context contains Git metadata");
            }
            if kind.is_dir() {
                pending.push(entry.path());
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layout(root: &Path, original: &str) -> std::path::PathBuf {
        let sealed = root.join("sealed");
        let admin = sealed.join(".git/worktrees/repo");
        fs::create_dir_all(&admin).unwrap();
        fs::create_dir_all(sealed.join("checkout")).unwrap();
        fs::write(admin.join("commondir"), "../..\n").unwrap();
        fs::write(admin.join("gitdir"), "/run/user/1/abird/run/repo/.git\n").unwrap();
        fs::write(
            sealed.join("checkout/.git"),
            format!("gitdir: {original}\n"),
        )
        .unwrap();
        sealed
    }

    #[test]
    fn linked_worktree_relocation_rewrites_only_both_admin_pointers() {
        let root = tempfile::tempdir().unwrap();
        let sealed = layout(root.path(), "/home/caller/z/.git/worktrees/repo");
        let checkout = relocate_worktree(&sealed).unwrap();
        assert_eq!(checkout, sealed.join("checkout"));
        assert_eq!(
            fs::read_to_string(checkout.join(".git")).unwrap(),
            format!("gitdir: {}\n", sealed.join(".git/worktrees/repo").display())
        );
        assert_eq!(
            fs::read_to_string(sealed.join(".git/worktrees/repo/gitdir")).unwrap(),
            format!("{}\n", checkout.join(".git").display())
        );
        assert_eq!(
            fs::read_to_string(sealed.join(".git/worktrees/repo/commondir")).unwrap(),
            "../..\n"
        );
    }

    #[test]
    fn relocation_rejects_foreign_or_per_worktree_configuration() {
        for original in ["/home/caller/z/.git/other/repo", "relative/worktrees/repo"] {
            let root = tempfile::tempdir().unwrap();
            assert!(relocate_worktree(&layout(root.path(), original)).is_err());
        }
        let root = tempfile::tempdir().unwrap();
        let sealed = layout(root.path(), "/home/caller/z/.git/worktrees/repo");
        fs::write(sealed.join(".git/worktrees/repo/config.worktree"), "").unwrap();
        assert!(relocate_worktree(&sealed).is_err());
        let root = tempfile::tempdir().unwrap();
        let sealed = layout(root.path(), "/home/caller/z/.git/worktrees/repo");
        fs::remove_file(sealed.join("checkout/.git")).unwrap();
        fs::create_dir(sealed.join("checkout/.git")).unwrap();
        assert!(relocate_worktree(&sealed).is_err());
    }
}
