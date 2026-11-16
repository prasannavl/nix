//! Presentation of captured execution inputs, never a new source authority.

use std::path::Path;
use std::process::{Command, Output};

use anyhow::{Context, Result, ensure};
use sha2::{Digest, Sha256};

use super::repository::CommitSha;
use super::workspace::ExecutionWorkspace;
use crate::programs::clear_git_repository_environment;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceIdentity {
    display: String,
    diagnostic: String,
}

impl SourceIdentity {
    pub fn display(&self) -> &str {
        &self.display
    }

    pub fn diagnostic(&self) -> &str {
        &self.diagnostic
    }

    /// Annotate existing diagnostics after execution; metadata alone must not
    /// turn an empty run into retained diagnostics. This is not an authority
    /// record: callers treat write failures as best-effort, never run failures.
    pub fn record(&self, directory: &Path) -> Result<()> {
        if std::fs::read_dir(directory)?.next().transpose()?.is_none() {
            return Ok(());
        }
        std::fs::write(
            directory.join("source-identity.txt"),
            format!("{}\n", self.diagnostic),
        )
        .context("record execution source identity")
    }

    /// Capture from the prepared execution tree, not the caller's current index.
    /// Plain --dirty permits a dirty caller but does not consume those edits.
    pub fn execution(git: &Path, workspace: &ExecutionWorkspace) -> Result<Self> {
        let root = &workspace.root;
        let head = text(git, root, &["rev-parse", "--verify", "HEAD^{commit}"])?;
        ensure!(
            head == workspace.commit.as_str(),
            "execution source HEAD differs from the resolved workspace commit"
        );
        let unstaged = command(
            git,
            root,
            &["diff", "--quiet", "--no-ext-diff", "--no-textconv", "--"],
        )?;
        ensure!(
            unstaged.status.success(),
            "execution source has unstaged changes; cannot identify it as the captured index"
        );
        let short = abbreviation(git, root, &workspace.commit)?;
        let patch = command(
            git,
            root,
            &[
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--no-textconv",
                "--no-renames",
                "--no-color",
                "--src-prefix=a/",
                "--dst-prefix=b/",
                "--ignore-submodules=none",
                "HEAD",
                "--",
            ],
        )?;
        ensure!(
            patch.status.success(),
            "capture execution source patch failed"
        );
        let digest =
            (!patch.stdout.is_empty()).then(|| format!("{:x}", Sha256::digest(&patch.stdout)));
        Ok(Self::captured(&head, &short, digest.as_deref(), None))
    }

    /// dev-build reads a mutable checkout. HEAD is context, not immutable proof.
    pub fn development(git: &Path, root: &Path) -> Result<Self> {
        let commit = CommitSha::parse(text(git, root, &["rev-parse", "HEAD^{commit}"])?)?;
        let short = abbreviation(git, root, &commit)?;
        let diff = command(
            git,
            root,
            &[
                "diff",
                "--quiet",
                "--no-ext-diff",
                "--no-textconv",
                "HEAD",
                "--",
            ],
        )?;
        ensure!(
            matches!(diff.status.code(), Some(0 | 1)),
            "inspect development checkout failed"
        );
        let dirty = if diff.status.success() { "" } else { "-dirty" };
        Ok(Self {
            display: format!("mutable {short}{dirty}"),
            diagnostic: format!(
                "Source: mutable checkout; HEAD {}; no immutable source identity",
                commit.as_str()
            ),
        })
    }

    /// Retained agent metadata only. No mutable caller Git lookup on resume.
    /// A longer presentation prefix; the full revision remains in diagnostics.
    pub fn retained(source: &abird_host_agent::build_executor::request::Source) -> Result<Self> {
        source.validate()?;
        let mut identity = Self::captured(
            &source.revision,
            &source.revision[..12],
            source.patch_digest.as_deref(),
            source.tree_digest.as_deref(),
        );
        identity
            .diagnostic
            .push_str(&format!("; base {}", source.base_revision));
        Ok(identity)
    }

    fn captured(commit: &str, short: &str, patch: Option<&str>, tree: Option<&str>) -> Self {
        let mut display = short.to_owned();
        let mut diagnostic = format!("Source: commit {commit}");
        if let Some(patch) = patch {
            // Full digest in diagnostics; the prefix is an operator label only.
            display.push_str(&format!(" + staged:{}", &patch[..12]));
            diagnostic.push_str(&format!("; staged patch sha256:{patch}"));
        }
        if let Some(tree) = tree {
            display.push_str(&format!(" + tree:{}", &tree[..12]));
            diagnostic.push_str(&format!("; captured tree sha256:{tree}"));
        }
        Self {
            display,
            diagnostic,
        }
    }
}

fn abbreviation(git: &Path, root: &Path, commit: &CommitSha) -> Result<String> {
    // Git lengthens the requested minimum when another object shares a prefix.
    text(
        git,
        root,
        &["rev-parse", "--short=8", "--verify", commit.as_str()],
    )
}

fn text(git: &Path, root: &Path, arguments: &[&str]) -> Result<String> {
    let output = command(git, root, arguments)?;
    ensure!(
        output.status.success(),
        "resolve execution source identity failed"
    );
    Ok(String::from_utf8(output.stdout)
        .context("source identity is not UTF-8")?
        .trim()
        .to_owned())
}

fn command(git: &Path, root: &Path, arguments: &[&str]) -> Result<Output> {
    let mut command = Command::new(git);
    clear_git_repository_environment(&mut command);
    command
        .current_dir(root)
        .args(arguments)
        .output()
        .context("inspect execution source identity")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retained_identity_uses_captured_metadata_not_caller_options() {
        let source = abird_host_agent::build_executor::request::Source {
            revision: "a".repeat(40),
            base_revision: "a".repeat(40),
            patch_digest: Some("b".repeat(64)),
            tree_digest: None,
        };
        let identity = SourceIdentity::retained(&source).unwrap();
        assert_eq!(
            identity.display(),
            format!("{} + staged:{}", "a".repeat(12), "b".repeat(12))
        );
        assert!(identity.diagnostic().contains(&"b".repeat(64)));
        let directory = tempfile::tempdir().unwrap();
        identity.record(directory.path()).unwrap();
        assert!(directory.path().read_dir().unwrap().next().is_none());
        std::fs::write(directory.path().join("failure.log"), "fixture").unwrap();
        identity.record(directory.path()).unwrap();
        assert_eq!(
            std::fs::read_to_string(directory.path().join("source-identity.txt")).unwrap(),
            format!("{}\n", identity.diagnostic())
        );
        assert!(
            identity
                .diagnostic()
                .contains(&format!("base {}", "a".repeat(40)))
        );
    }
}
