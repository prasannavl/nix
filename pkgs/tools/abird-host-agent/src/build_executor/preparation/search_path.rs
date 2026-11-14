//! Private executable-search binding, not a complete caller profile. Keep PATH
//! verbatim; retain each symlink hop instead of replacing it with a store PATH.

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};
use std::time::Instant;

const MAX_ENTRIES: usize = 64;
const MAX_LINKS: usize = 128;
const MAX_BYTES: usize = 64 * 1024;

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Link {
    pub path: PathBuf,
    pub target: PathBuf,
    device: u64,
    inode: u64,
    changed: (i64, i64),
}

impl Link {
    pub(super) fn validate(&self) -> Result<()> {
        absolute(&self.path)?;
        ensure!(
            !self.target.as_os_str().is_empty()
                && self.target.as_os_str().len() <= 4096
                && !self.target.as_os_str().as_bytes().contains(&0)
                && self.inode > 0
                && !in_store(&self.path),
            "invalid caller namespace alias"
        );
        Ok(())
    }
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    original: PathBuf,
    store_path: PathBuf,
    resolved: PathBuf,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct SearchPath {
    value: String,
    entries: Vec<Entry>,
    links: Vec<Link>,
}

impl SearchPath {
    /// After admission, inside the original capture lifetime. Mutable executable
    /// directories and cwd-relative entries need another adapter, not fallback.
    pub fn capture(value: &str, deadline: Instant) -> Result<Self> {
        crate::build_executor::workload::require_wrapper_placement()?;
        Self::capture_at(value, deadline)
    }

    /// The original profile/Git window begins before any PATH resolution.
    pub fn capture_with_window(
        value: &str,
        window: &mut super::git_context::window::ReadWindow,
        deadline: Instant,
    ) -> Result<Self> {
        crate::build_executor::workload::require_wrapper_placement()?;
        Self::capture_observed(value, deadline, |path| window.hold_path_component(path))
    }

    fn capture_at(value: &str, deadline: Instant) -> Result<Self> {
        Self::capture_observed(value, deadline, |_| Ok(()))
    }

    pub(in crate::build_executor::preparation) fn capture_observed(
        value: &str,
        deadline: Instant,
        mut observe: impl FnMut(&Path) -> Result<()>,
    ) -> Result<Self> {
        ensure!(
            !value.is_empty() && value.len() <= 8192,
            "caller PATH exceeds bound"
        );
        let mut links = BTreeMap::new();
        let mut entries = Vec::new();
        for name in value.split(':') {
            ensure!(
                Instant::now() < deadline && entries.len() < MAX_ENTRIES,
                "caller PATH capture expired or exceeds bound"
            );
            let original = PathBuf::from(name);
            absolute(&original)?;
            let store_path = resolve(&original, &mut links, deadline, &mut observe)?;
            let resolved = immutable_resolution(&store_path, deadline)?;
            ensure!(
                in_store(&resolved) && fs::metadata(&resolved)?.is_dir(),
                "caller PATH needs a bound mutable executable directory"
            );
            crate::build_executor::daemon::trusted_path(&resolved)?;
            entries.push(Entry {
                original,
                store_path,
                resolved,
            });
        }
        let result = Self {
            value: value.to_owned(),
            entries,
            links: links.into_values().collect(),
        };
        result.validate()?;
        result.check_live(deadline)?;
        Ok(result)
    }

    pub fn validate(&self) -> Result<()> {
        ensure!(
            !self.value.is_empty()
                && self.value.len() <= 8192
                && !self.entries.is_empty()
                && self.entries.len() <= MAX_ENTRIES
                && self.links.len() <= MAX_LINKS
                && serde_json::to_vec(self)?.len() <= MAX_BYTES,
            "invalid caller PATH binding"
        );
        ensure!(
            self.value
                .split(':')
                .map(Path::new)
                .eq(self.entries.iter().map(|entry| entry.original.as_path())),
            "caller PATH order differs"
        );
        ensure!(
            self.links
                .windows(2)
                .all(|pair| pair[0].path < pair[1].path),
            "duplicate caller PATH alias"
        );
        for link in &self.links {
            link.validate()?;
        }
        let links: BTreeMap<_, _> = self
            .links
            .iter()
            .map(|link| (link.path.as_path(), link.target.as_path()))
            .collect();
        let mut used = BTreeSet::new();
        for entry in &self.entries {
            absolute(&entry.original)?;
            absolute(&entry.resolved)?;
            absolute(&entry.store_path)?;
            ensure!(
                in_store(&entry.resolved)
                    && in_store(&entry.store_path)
                    && expand(&entry.original, &links, &mut used)? == entry.store_path,
                "caller PATH target differs"
            );
        }
        ensure!(
            used.len() == self.links.len(),
            "unreferenced caller PATH alias"
        );
        Ok(())
    }

    pub fn require_value(&self, value: &str) -> Result<()> {
        self.validate()?;
        ensure!(value == self.value, "caller PATH changed");
        Ok(())
    }

    /// Before/after veto only. Production capture also retains the original
    /// ReadWindow's namespace watches across every source operation.
    pub fn check_live(&self, deadline: Instant) -> Result<()> {
        self.validate()?;
        for link in &self.links {
            ensure!(Instant::now() < deadline, "caller PATH observation expired");
            ensure!(observe(&link.path)? == *link, "caller PATH alias changed");
        }
        for entry in &self.entries {
            ensure!(
                Instant::now() < deadline
                    && fs::canonicalize(&entry.original)? == entry.resolved
                    && immutable_resolution(&entry.store_path, deadline)? == entry.resolved,
                "caller PATH resolution changed"
            );
        }
        Ok(())
    }

    /// Inside the private view, retained link text deliberately has fresh inodes.
    pub fn check_view(&self) -> Result<()> {
        self.validate()?;
        for link in &self.links {
            ensure!(
                fs::read_link(&link.path)? == link.target,
                "private caller PATH alias differs"
            );
        }
        for entry in &self.entries {
            ensure!(
                fs::canonicalize(&entry.original)? == entry.resolved
                    && fs::metadata(&entry.resolved)?.is_dir(),
                "private caller PATH resolution differs"
            );
        }
        Ok(())
    }

    /// Native PATH selection when no explicit Git override was supplied. Never
    /// run a different installed Git merely because its name matches.
    pub fn require_program(&self, name: &str, expected: &Path, deadline: Instant) -> Result<()> {
        self.validate()?;
        ensure!(
            !name.is_empty() && !name.contains('/'),
            "invalid caller executable name"
        );
        let expected = fs::canonicalize(expected)?;
        for entry in &self.entries {
            ensure!(
                Instant::now() < deadline,
                "caller executable selection expired"
            );
            let candidate = entry.original.join(name);
            let metadata = match fs::metadata(&candidate) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if !metadata.is_file() || metadata.mode() & 0o111 == 0 {
                continue;
            }
            ensure!(
                metadata.uid() == 0 && metadata.mode() & 0o001 != 0 && metadata.mode() & 0o022 == 0,
                "caller executable needs a credential-sensitive binding"
            );
            ensure!(
                fs::canonicalize(candidate)? == expected
                    && immutable_resolution(&entry.resolved.join(name), deadline)? == expected,
                "caller executable differs from installed helper"
            );
            return Ok(());
        }
        anyhow::bail!("caller executable absent from captured PATH")
    }

    pub fn links(&self) -> &[Link] {
        &self.links
    }
}

fn absolute(path: &Path) -> Result<()> {
    ensure!(
        path.is_absolute()
            && path.as_os_str().len() <= 4096
            && !path.as_os_str().as_bytes().contains(&0)
            && path
                .components()
                .all(|part| matches!(part, Component::RootDir | Component::Normal(_))),
        "caller PATH needs absolute normalized entries"
    );
    Ok(())
}
pub(super) fn in_store(path: &Path) -> bool {
    path.strip_prefix("/nix/store")
        .is_ok_and(|suffix| suffix.components().next().is_some())
}
/// Immutable hops may not visit a mutable provider and then re-enter the store.
/// Keep native link text in the view; inspect it rather than recreating it.
pub(super) fn immutable_resolution(path: &Path, deadline: Instant) -> Result<PathBuf> {
    let mut current = path.to_owned();
    for _ in 0..=MAX_LINKS {
        ensure!(
            Instant::now() < deadline && in_store(&current),
            "immutable profile resolution unavailable"
        );
        absolute(&current)?;
        crate::build_executor::daemon::trusted_path(Path::new("/nix/store"))?;
        let mut prefix = PathBuf::from("/nix/store");
        let mut next = None;
        for part in current.strip_prefix("/nix/store")?.components() {
            ensure!(
                Instant::now() < deadline,
                "immutable profile resolution expired"
            );
            prefix.push(part.as_os_str());
            let metadata = fs::symlink_metadata(&prefix)?;
            ensure!(
                metadata.uid() == 0,
                "immutable profile inode has foreign ownership"
            );
            if metadata.is_symlink() {
                next = Some(immutable_destination(
                    &prefix,
                    &fs::read_link(&prefix)?,
                    current.strip_prefix(&prefix)?,
                )?);
                break;
            }
            ensure!(
                metadata.mode() & 0o222 == 0 && (metadata.is_dir() || metadata.is_file()),
                "immutable profile inode is mutable or special"
            );
        }
        if let Some(path) = next {
            current = path;
        } else {
            ensure!(
                fs::canonicalize(path)? == current,
                "immutable profile resolution changed"
            );
            return Ok(current);
        }
    }
    anyhow::bail!("immutable profile alias cycle")
}

fn immutable_destination(link: &Path, target: &Path, tail: &Path) -> Result<PathBuf> {
    let path = destination(link, target, tail)?;
    ensure!(in_store(&path), "immutable profile alias escapes the store");
    Ok(path)
}

pub(super) fn observe(path: &Path) -> Result<Link> {
    let before = fs::symlink_metadata(path)?;
    ensure!(before.is_symlink(), "caller PATH alias is not a symlink");
    let target = fs::read_link(path)?;
    let after = fs::symlink_metadata(path)?;
    ensure!(
        (
            before.dev(),
            before.ino(),
            before.ctime(),
            before.ctime_nsec()
        ) == (after.dev(), after.ino(), after.ctime(), after.ctime_nsec()),
        "caller PATH alias changed during observation"
    );
    Ok(Link {
        path: path.to_path_buf(),
        target,
        device: before.dev(),
        inode: before.ino(),
        changed: (before.ctime(), before.ctime_nsec()),
    })
}

pub(super) fn destination(link: &Path, target: &Path, tail: &Path) -> Result<PathBuf> {
    // Only leading relative '..' traverses an already resolved parent. Lexical
    // removal after a new component could skip an unobserved symlink/provider.
    let mut entered = target.is_absolute();
    for part in target.components() {
        match part {
            Component::Normal(_) => entered = true,
            Component::ParentDir => ensure!(
                !entered,
                "caller alias upward traversal requires its original namespace"
            ),
            _ => {}
        }
    }
    let path = if target.is_absolute() {
        target.to_path_buf()
    } else {
        link.parent()
            .context("caller PATH alias parent missing")?
            .join(target)
    };
    let mut normalized = PathBuf::from("/");
    for part in path.join(tail).components() {
        match part {
            Component::RootDir | Component::CurDir => {}
            Component::ParentDir => {
                ensure!(normalized.pop(), "caller PATH alias escapes root");
            }
            Component::Normal(value) => normalized.push(value),
            Component::Prefix(_) => anyhow::bail!("invalid caller PATH alias prefix"),
        }
    }
    absolute(&normalized)?;
    Ok(normalized)
}

pub(super) fn expand(
    original: &Path,
    links: &BTreeMap<&Path, &Path>,
    used: &mut BTreeSet<PathBuf>,
) -> Result<PathBuf> {
    let mut path = original.to_path_buf();
    for _ in 0..=MAX_LINKS {
        let found = path
            .ancestors()
            .filter_map(|ancestor| links.get(ancestor).map(|target| (ancestor, *target)))
            .last();
        let Some((link, target)) = found else {
            return Ok(path);
        };
        used.insert(link.to_path_buf());
        path = destination(link, target, path.strip_prefix(link)?)?;
    }
    anyhow::bail!("caller PATH alias cycle")
}

pub(super) fn resolve(
    original: &Path,
    links: &mut BTreeMap<PathBuf, Link>,
    deadline: Instant,
    watch: &mut impl FnMut(&Path) -> Result<()>,
) -> Result<PathBuf> {
    let mut path = original.to_path_buf();
    for _ in 0..=MAX_LINKS {
        ensure!(Instant::now() < deadline, "caller PATH capture expired");
        // Store contents use their native immutable symlinks, not recreated aliases.
        if in_store(&path) {
            for root in ["/", "/nix", "/nix/store"] {
                watch(Path::new(root))?;
            }
            return Ok(path);
        }
        let mut prefix = PathBuf::from("/");
        watch(&prefix)?;
        let mut redirected = None;
        for part in path.components().skip(1) {
            prefix.push(part.as_os_str());
            if in_store(&prefix) {
                break;
            }
            watch(&prefix)?;
            if fs::symlink_metadata(&prefix)?.is_symlink() {
                let link = observe(&prefix)?;
                redirected = Some(destination(
                    &prefix,
                    &link.target,
                    path.strip_prefix(&prefix)?,
                )?);
                if let Some(previous) = links.get(&prefix) {
                    ensure!(previous == &link, "caller PATH alias changed");
                } else {
                    ensure!(
                        links.len() < MAX_LINKS,
                        "caller PATH alias count exceeds bound"
                    );
                    links.insert(prefix, link);
                }
                break;
            }
        }
        match redirected {
            Some(next) => path = next,
            None => return Ok(path),
        }
    }
    anyhow::bail!("caller PATH alias cycle")
}

#[cfg(test)]
mod tests;
