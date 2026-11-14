//! Native checkout settings and standalone producer replicas.
//! Not complete Git configuration, source verification or namespace authority.

use std::ffi::OsString;
use std::fs;
use std::os::unix::fs::DirBuilderExt;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, ensure};

use super::{CommandRunner, CommitSha, RepositoryManager};

const KEYS: [&str; 6] = [
    "core.autocrlf",
    "core.eol",
    "core.filemode",
    "core.symlinks",
    "core.ignorecase",
    "core.safecrlf",
];

/// Effective supported settings, including absence. No ambient discovery or
/// claim about hooks, attributes, includes, index flags or object references.
#[derive(Clone, Eq, PartialEq)]
pub struct CheckoutSettings([Option<&'static str>; KEYS.len()]);

/// Producer result only. Unlike a linked worktree, its Git directory is local.
/// Caller still verifies objects, configuration, selected bytes and metadata.
pub struct StandaloneCheckout {
    pub path: PathBuf,
    pub commit: CommitSha,
}

impl<R: CommandRunner> RepositoryManager<R> {
    /// Fresh remote replica with history/replacement refs, followed by the exact
    /// selected commit. Declared Git context stays active; no filter suppression.
    pub fn create_installed_checkout(
        &mut self,
        parent: &Path,
        url: &str,
        commit: &CommitSha,
        before_checkout: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<StandaloneCheckout> {
        let target = parent.join("repository");
        fs::DirBuilder::new().mode(0o700).create(&target)?;
        let metadata = target.join(".git");
        let clone = self.git_request(
            parent,
            [
                OsString::from("clone"),
                "--mirror".into(),
                "--no-local".into(),
                "--no-hardlinks".into(),
                "--template=".into(),
                "--".into(),
                url.into(),
                metadata.as_os_str().to_owned(),
            ],
            None,
        );
        self.run_checked(&clone, "clone installed source")?;
        let configure =
            self.git_request(&target, ["config", "--local", "core.bare", "false"], None);
        self.run_checked(&configure, "configure standalone source")?;
        // Trusted declared-URL acquisition has ended. The installed caller must
        // restrict this fresh destination before checkout can invoke filters or
        // hooks; patching and observation remain in that same offline process.
        before_checkout(&target)?;
        let checkout = self.git_request(
            &target,
            ["checkout", "--detach", commit.as_str(), "--"],
            None,
        );
        self.run_checked(&checkout, "checkout installed source")?;
        ensure!(
            self.resolve_commit(&target, "HEAD")? == *commit,
            "installed source revision differs"
        );
        Ok(StandaloneCheckout {
            path: target,
            commit: commit.clone(),
        })
    }

    pub fn require_installed_patch(&mut self, root: &Path, expected: Option<&[u8]>) -> Result<()> {
        let observed = self.run_git(
            root,
            [
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--",
            ],
            None,
        )?;
        ensure!(
            observed.succeeded() && observed.stdout == expected.unwrap_or_default(),
            "installed staged patch differs"
        );
        Ok(())
    }

    /// Compare the frozen replica with its settled producer observation. This is
    /// additional veto evidence; native consumed-source binding remains required.
    pub fn installed_source_observation(
        &mut self,
        root: &Path,
        commit: &CommitSha,
    ) -> Result<String> {
        use sha2::{Digest, Sha256};
        ensure!(
            self.resolve_commit(root, "HEAD")? == *commit,
            "source HEAD differs"
        );
        for (argument, expected) in [
            ("--show-toplevel", root.to_owned()),
            ("--absolute-git-dir", root.join(".git")),
        ] {
            use std::os::unix::ffi::OsStrExt;
            let observed = self.run_git(root, ["rev-parse", argument], None)?;
            ensure!(
                observed.succeeded()
                    && observed.stdout.strip_suffix(b"\n") == Some(expected.as_os_str().as_bytes()),
                "source Git layout redirected"
            );
        }
        self.index_entries(root)?; // Reject hidden/unmerged entries and gitlinks.
        // Verify raw objects too; ordinary native object reads can accept corrupt
        // payloads under an existing name. Do not disable runtime replacements.
        let objects = self.run_git(
            root,
            [
                "fsck",
                "--full",
                "--strict",
                "--no-dangling",
                "--no-progress",
            ],
            None,
        )?;
        ensure!(objects.succeeded(), "source object integrity failed");
        let clean = self.run_git(root, ["diff", "--quiet", "--no-ext-diff", "--"], None)?;
        ensure!(clean.succeeded(), "source has unstaged changes");
        let patch = self.run_git(
            root,
            [
                "diff",
                "--cached",
                "--binary",
                "--full-index",
                "--no-ext-diff",
                "--",
            ],
            None,
        )?;
        ensure!(patch.succeeded(), "source index observation failed");
        let config = self.run_git(root, ["config", "--null", "--show-origin", "--list"], None)?;
        ensure!(
            config.succeeded() && config.stdout.len() <= 64 * 1024,
            "source configuration observation failed"
        );
        let fields = config
            .stdout
            .strip_suffix(&[0])
            .ok_or_else(|| anyhow::anyhow!("unterminated Git configuration"))?
            .split(|byte| *byte == 0)
            .collect::<Vec<_>>();
        ensure!(
            fields.len().is_multiple_of(2),
            "invalid Git configuration origins"
        );
        let mut digest = Sha256::new();
        digest.update(b"abird-owned-source-observation-v1\0");
        digest.update((patch.stdout.len() as u64).to_be_bytes());
        digest.update(&patch.stdout);
        for entry in fields.chunks_exact(2) {
            use std::os::unix::ffi::OsStrExt;
            let origin = entry[0]
                .strip_prefix(b"file:")
                .ok_or_else(|| anyhow::anyhow!("non-file Git configuration"))?;
            let origin = Path::new(std::ffi::OsStr::from_bytes(origin));
            let origin = if origin.is_absolute() {
                origin.to_owned()
            } else {
                root.join(origin)
            };
            let origin = fs::canonicalize(origin)?;
            ensure!(
                origin.starts_with(root) || origin.starts_with("/nix/store"),
                "mutable external Git configuration"
            );
            digest.update((entry[1].len() as u64).to_be_bytes());
            digest.update(entry[1]);
        }
        Ok(format!("{:x}", digest.finalize()))
    }

    /// Capture from the selected native execution view, not an assumed parent.
    pub fn checkout_settings(&mut self, root: &Path) -> Result<CheckoutSettings> {
        let output = self.run_git(root, ["config", "--null", "--list"], None)?;
        ensure!(
            output.status == 0,
            "read native checkout configuration failed"
        );
        let raw = configuration(&output.stdout)?;
        let mut values = [None; KEYS.len()];
        for (index, (key, value)) in KEYS.iter().zip(raw).enumerate() {
            let Some(value) = value else { continue };
            values[index] = Some(match (*key, &value) {
                ("core.autocrlf", Raw::Value(v)) if v == b"input" => "input",
                ("core.safecrlf", Raw::Value(v)) if v == b"warn" => "warn",
                ("core.eol", Raw::Value(v)) => match v.as_slice() {
                    b"lf" => "lf",
                    b"crlf" => "crlf",
                    b"native" => "native",
                    _ => anyhow::bail!("unsupported native line-ending setting"),
                },
                ("core.eol", _) => anyhow::bail!("missing native line-ending value"),
                _ => self
                    .boolean_setting(root, &value)
                    .with_context(|| format!("read {key}"))?,
            });
        }
        Ok(CheckoutSettings(values))
    }

    fn boolean_setting(&mut self, root: &Path, value: &Raw) -> Result<&'static str> {
        // Typed --get validates shadowed values too (e.g. earlier autocrlf=input).
        // Ask Git to convert only the effective value, retaining bare vs empty.
        let output = self.run_git(
            root,
            [
                "config",
                "--file",
                "-",
                "--null",
                "--type=bool",
                "--get",
                "checkout.value",
            ],
            Some(value.inline()),
        )?;
        ensure!(output.status == 0, "native boolean conversion failed");
        match output.stdout.as_slice() {
            b"true\0" => Ok("true"),
            b"false\0" => Ok("false"),
            _ => anyhow::bail!("invalid native boolean setting"),
        }
    }

    /// Replay only the enumerated settings; do not copy credentials/remote config.
    /// Caller owns this destination and supplies the same immutable environment.
    pub fn apply_checkout_settings(
        &mut self,
        root: &Path,
        settings: &CheckoutSettings,
    ) -> Result<()> {
        for (key, value) in KEYS.iter().zip(settings.0) {
            let output = match value {
                Some(value) => self.run_git(
                    root,
                    ["config", "--local", "--replace-all", key, value],
                    None,
                )?,
                None => self.run_git(root, ["config", "--local", "--unset-all", key], None)?,
            };
            ensure!(
                output.stdout.is_empty()
                    && (output.status == 0 || (value.is_none() && output.status == 5)),
                "replay native checkout setting failed"
            );
        }
        ensure!(
            self.checkout_settings(root)? == *settings,
            "native checkout settings differ after replay"
        );
        Ok(())
    }

    /// New producer directory, exact commit, no local hardlink/alternate clone.
    /// Admission/registration and exclusive namespace ownership precede this call.
    /// Errors may leave data; no adoption, cleanup, retry or source receipt here.
    pub fn create_standalone_checkout(
        &mut self,
        source: &Path,
        target: &Path,
        commit: &CommitSha,
        settings: &CheckoutSettings,
    ) -> Result<StandaloneCheckout> {
        ensure!(
            source.is_absolute() && target.is_absolute() && commit.as_str().len() == 40,
            "standalone checkout requires absolute paths and full commit"
        );
        // Exclusive creation, not an existence test followed by clone adoption.
        fs::DirBuilder::new().mode(0o700).create(target)?;
        let clone = self.git_request(
            source,
            [
                OsString::from("clone"),
                "--no-local".into(),
                "--no-hardlinks".into(),
                "--no-checkout".into(),
                "--template=".into(),
                "--".into(),
                source.as_os_str().to_owned(),
                target.as_os_str().to_owned(),
            ],
            None,
        );
        self.run_checked(&clone, "create standalone producer repository")?;
        self.apply_checkout_settings(target, settings)?;
        let checkout = self.git_request(
            target,
            ["checkout", "--detach", commit.as_str(), "--"],
            None,
        );
        self.run_checked(&checkout, "checkout exact producer commit")?;
        ensure!(
            self.resolve_commit(target, "HEAD")? == *commit,
            "standalone producer commit differs"
        );
        ensure!(
            self.checkout_settings(target)? == *settings,
            "checkout settings changed during checkout"
        );
        Ok(StandaloneCheckout {
            path: target.to_owned(),
            commit: commit.clone(),
        })
    }
}

#[derive(Clone)]
enum Raw {
    Bare,
    Value(Vec<u8>),
}
impl Raw {
    fn inline(&self) -> Vec<u8> {
        let mut out = b"[checkout]\nvalue".to_vec();
        if let Self::Value(value) = self {
            out.extend_from_slice(b"=\"");
            for byte in value {
                match byte {
                    b'\\' => out.extend_from_slice(b"\\\\"),
                    b'"' => out.extend_from_slice(b"\\\""),
                    b'\n' => out.extend_from_slice(b"\\n"),
                    b'\t' => out.extend_from_slice(b"\\t"),
                    8 => out.extend_from_slice(b"\\b"),
                    byte => out.push(*byte),
                }
            }
            out.push(b'"');
        }
        out.push(b'\n');
        out
    }
}

fn configuration(bytes: &[u8]) -> Result<[Option<Raw>; KEYS.len()]> {
    ensure!(
        bytes.len() <= 128 * 1024,
        "native configuration exceeds bound"
    );
    let mut fields = std::array::from_fn(|_| None);
    if bytes.is_empty() {
        return Ok(fields);
    }
    let records = bytes
        .strip_suffix(&[0])
        .ok_or_else(|| anyhow::anyhow!("unterminated native configuration"))?;
    for (count, record) in records.split(|b| *b == 0).enumerate() {
        ensure!(
            count < 4096 && !record.is_empty(),
            "invalid native configuration frame"
        );
        let (key, value) = match record.iter().position(|b| *b == b'\n') {
            Some(n) => (&record[..n], Some(&record[n + 1..])),
            None => (record, None),
        };
        ensure!(!key.is_empty(), "empty native configuration key");
        if let Some(index) = KEYS
            .iter()
            .position(|candidate| candidate.as_bytes() == key)
        {
            ensure!(
                value.is_none_or(|v| v.len() <= 128),
                "native checkout setting exceeds bound"
            );
            fields[index] = Some(match value {
                Some(v) => Raw::Value(v.into()),
                None => Raw::Bare,
            });
        }
    }
    Ok(fields)
}

#[cfg(test)]
mod tests;
