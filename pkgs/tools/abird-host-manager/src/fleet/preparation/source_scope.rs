//! Fixed-manager read authority. Live roots grant only bounded regular inodes;
//! runtime package roots come solely from the installed immutable closure list.
use abird_host_agent::build_executor::{
    daemon,
    private_tree::Limits,
    process::offline::{Policy, ReadScope},
};
use anyhow::{Context, Result, ensure};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io::Read;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

pub(in crate::fleet) struct Runtime {
    list: PathBuf,
    roots: Vec<PathBuf>,
    limits: Limits,
    deadline: Instant,
    decoder: RefCell<Option<Policy>>,
}

impl Runtime {
    pub fn load(path: &Path, limits: Limits, deadline: Instant) -> Result<Self> {
        // ReadScope::capture validates these bounds before constructing any grants.
        crate::programs::nix::StorePath::new(path)?;
        daemon::trusted_path(path)?;
        ensure!(
            fs::canonicalize(path)? == path && Instant::now() < deadline,
            "runtime closure list redirected or expired"
        );
        let file = File::open(path)?;
        let metadata = file.metadata()?;
        ensure!(
            metadata.is_file()
                && metadata.uid() == 0
                && metadata.mode() & 0o222 == 0
                && metadata.len() <= 2 * 1024 * 1024,
            "runtime closure list is not immutable metadata"
        );
        let mut text = String::new();
        file.take(2 * 1024 * 1024 + 1).read_to_string(&mut text)?;
        ensure!(
            text.len() <= 2 * 1024 * 1024,
            "runtime closure metadata exceeds bound"
        );
        let mut roots = BTreeSet::new();
        for line in text.lines() {
            let root = PathBuf::from(line);
            crate::programs::nix::StorePath::new(&root)?;
            crate::programs::nix::StorePath::new(fs::canonicalize(&root)?)?;
            ensure!(
                root.parent() == Some(Path::new("/nix/store")) && roots.len() < 4096,
                "runtime closure requires exact store object roots"
            );
            roots.insert(root);
        }
        ensure!(!roots.is_empty(), "runtime closure is empty");
        Ok(Self {
            list: path.to_owned(),
            roots: roots.into_iter().collect(),
            limits,
            deadline,
            decoder: RefCell::new(None),
        })
    }

    pub fn policy(
        &self,
        live: &[PathBuf],
        writable: &[&Path],
        private_proc: bool,
    ) -> Result<Policy> {
        ensure!(
            Instant::now() < self.deadline,
            "source read-scope deadline expired"
        );
        let mut files = BTreeSet::from([self.list.clone()]);
        files.extend(live.iter().cloned());
        files.extend(self.roots.iter().cloned());
        // Exact regular NSS/system inputs, not a recursive /etc read grant.
        // Named-user includes still use Git's original native path expansion.
        for path in [
            "/etc/passwd",
            "/etc/group",
            "/etc/nsswitch.conf",
            "/etc/hosts",
            "/etc/ld.so.cache",
            "/etc/localtime",
            "/etc/resolv.conf",
        ] {
            match fs::metadata(path) {
                Ok(metadata) if metadata.is_file() => {
                    files.insert(PathBuf::from(path));
                }
                Ok(_) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error).context("runtime system input unavailable"),
            }
        }
        let files = files.iter().map(PathBuf::as_path).collect::<Vec<_>>();
        // No package-directory READ_FILE rule: even the authoritative installed
        // closure is scanned into exact regular-inode grants at this checkpoint.
        let scope = ReadScope::capture(&files, self.limits, self.deadline)?;
        let policy = Policy::new(writable)?.with_read_scope(scope)?;
        Ok(if private_proc {
            policy.with_private_proc()
        } else {
            policy
        })
    }

    pub fn decoder(&self) -> Result<Policy> {
        // Only used inside the actual root-created caller/capture PID view.
        let mut cached = self.decoder.borrow_mut();
        if cached.is_none() {
            *cached = Some(self.policy(&[], &[], true)?);
        }
        Ok(cached
            .as_ref()
            .context("decoder scope missing")?
            .try_clone()?)
    }
}
