//! Persistent physical namespace veto, not a capacity/reservation certificate.
//! No store creation, relocation, repair or replacement adoption on open.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};

use super::request::StorageIdentity;

const FILE: &str = "native-store.json";
const PATHS: [(&str, bool); 4] = [
    ("/nix/store", true),
    ("/nix/var/nix", true),
    ("/nix/var/nix/db", true),
    ("/nix/var/nix/db/db.sqlite", false),
];

#[derive(Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Object {
    path: String,
    device: u64,
    inode: u64,
    filesystem: i64,
}

#[derive(Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Binding {
    version: u32,
    identity: StorageIdentity,
    objects: Vec<Object>,
}

fn observe(identity: &StorageIdentity) -> Result<Binding> {
    let mut objects = Vec::new();
    for (path, directory) in PATHS {
        let path = Path::new(path);
        ensure!(
            fs::canonicalize(path)? == path,
            "native store namespace redirected"
        );
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(
                libc::O_CLOEXEC
                    | libc::O_NOFOLLOW
                    | libc::O_NONBLOCK
                    | if directory { libc::O_DIRECTORY } else { 0 },
            )
            .open(path)?;
        let meta = file.metadata()?;
        ensure!(
            meta.uid() == 0
                && meta.ino() > 0
                && meta.is_dir() == directory
                && (directory || (meta.is_file() && meta.nlink() == 1 && meta.mode() & 0o022 == 0)),
            "native store object differs"
        );
        let mut stat: libc::statfs = unsafe { std::mem::zeroed() };
        ensure!(
            unsafe { libc::fstatfs(file.as_raw_fd(), &mut stat) } == 0,
            std::io::Error::last_os_error()
        );
        let current = fs::symlink_metadata(path)?;
        ensure!(
            (current.dev(), current.ino()) == (meta.dev(), meta.ino()),
            "native store object replaced"
        );
        objects.push(Object {
            path: path.to_string_lossy().into_owned(),
            device: meta.dev(),
            inode: meta.ino(),
            filesystem: stat.f_type,
        });
    }
    Ok(Binding {
        version: 1,
        identity: identity.clone(),
        objects,
    })
}

/// Only explicit bootstrap calls this, with ingress stopped and aggregate empty.
pub(super) fn initialize(root: &Path, identity: &StorageIdentity) -> Result<()> {
    let binding = observe(identity)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(root.join(FILE))?;
    file.write_all(&serde_json::to_vec(&binding)?)?;
    file.sync_all()?;
    File::open(root)?.sync_all()?;
    validate(root, identity)
}

pub(super) fn validate(root: &Path, identity: &StorageIdentity) -> Result<()> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(root.join(FILE))?;
    let meta = file.metadata()?;
    ensure!(
        meta.is_file() && meta.uid() == 0 && meta.nlink() == 1 && meta.mode() & 0o7777 == 0o600,
        "native store binding unavailable"
    );
    let mut bytes = Vec::new();
    file.take(16 * 1024 + 1).read_to_end(&mut bytes)?;
    ensure!(
        bytes.len() <= 16 * 1024,
        "native store binding exceeds bound"
    );
    let binding: Binding = serde_json::from_slice(&bytes)
        .map_err(|_| anyhow::anyhow!("invalid native store binding"))?;
    ensure!(
        binding == observe(identity)?,
        "native store binding differs; no adoption permitted"
    );
    Ok(())
}
