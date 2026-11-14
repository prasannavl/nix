use super::*;
use std::fs::{self, OpenOptions};
use std::io::{Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};
use std::os::unix::net::UnixListener;
use std::path::Path;

struct Fixture {
    temp: tempfile::TempDir,
    source: File,
    target: File,
}

impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        for name in ["source", "target"] {
            fs::create_dir(temp.path().join(name)).unwrap();
            fs::set_permissions(temp.path().join(name), fs::Permissions::from_mode(0o700)).unwrap();
        }
        let source = File::open(temp.path().join("source")).unwrap();
        let target = File::open(temp.path().join("target")).unwrap();
        Self {
            temp,
            source,
            target,
        }
    }
    fn root(&self) -> &Path {
        self.temp.path()
    }
    fn copy(&self, limits: Limits) -> Result<CopySummary> {
        copy_as(
            &self.source,
            &self.target,
            unsafe { libc::geteuid() },
            unsafe { libc::getegid() },
            limits,
            unsafe { libc::geteuid() },
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        // Only test-owned directories; no symlink following during teardown.
        fn writable(path: &Path) {
            if !fs::symlink_metadata(path).unwrap().is_dir() {
                return;
            }
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
            for child in fs::read_dir(path).unwrap() {
                writable(&child.unwrap().path());
            }
        }
        writable(self.root());
    }
}

fn limits() -> Limits {
    Limits {
        entries: 64,
        bytes: 1024 * 1024,
        depth: 16,
    }
}

#[test]
fn fresh_inodes_survive_producer_writable_descriptors_and_renames() {
    let f = Fixture::new();
    fs::write(f.root().join("source/payload"), b"selected").unwrap();
    let mut writer = OpenOptions::new()
        .write(true)
        .open(f.root().join("source/payload"))
        .unwrap();
    assert_eq!(
        f.copy(limits()).unwrap(),
        CopySummary {
            entries: 2,
            bytes: 8,
            symlinks: 0
        }
    );
    let original = writer.metadata().unwrap();
    let target = fs::metadata(f.root().join("target/payload")).unwrap();
    assert_ne!(
        (original.dev(), original.ino()),
        (target.dev(), target.ino())
    );
    assert_eq!(target.nlink(), 1);
    fs::rename(
        f.root().join("source/payload"),
        f.root().join("source/renamed"),
    )
    .unwrap();
    writer.seek(SeekFrom::Start(0)).unwrap();
    writer.write_all(b"tampered").unwrap();
    writer.sync_all().unwrap();
    assert_eq!(
        fs::read(f.root().join("target/payload")).unwrap(),
        b"selected"
    );
    assert_eq!(
        fs::read(f.root().join("source/renamed")).unwrap(),
        b"tampered"
    );
}

#[test]
fn permissions_strip_special_bits_and_preserve_nar_owner_execute() {
    let f = Fixture::new();
    fs::create_dir(f.root().join("source/nested")).unwrap();
    for (name, mode) in [("plain", 0o660), ("exec", 0o4755), ("group-exec", 0o650)] {
        let path = f.root().join("source/nested").join(name);
        fs::write(&path, b"x").unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(mode)).unwrap();
    }
    f.copy(limits()).unwrap();
    for (name, mode) in [
        ("", 0o550),
        ("nested", 0o550),
        ("nested/plain", 0o440),
        ("nested/exec", 0o550),
        ("nested/group-exec", 0o440),
    ] {
        let meta = fs::metadata(f.root().join("target").join(name)).unwrap();
        assert_eq!(meta.mode() & 0o7777, mode);
        assert_eq!(meta.uid(), unsafe { libc::geteuid() });
        assert_eq!(meta.gid(), unsafe { libc::getegid() });
    }
}

#[test]
fn links_are_inert_bytes_not_confinement_evidence() {
    let f = Fixture::new();
    let outside = f.root().join("outside");
    fs::write(&outside, b"must not copy").unwrap();
    symlink(&outside, f.root().join("source/link")).unwrap();
    let summary = f.copy(limits()).unwrap();
    assert_eq!(summary.symlinks, 1);
    assert_eq!(summary.bytes, outside.as_os_str().as_bytes().len() as u64);
    assert!(
        fs::symlink_metadata(f.root().join("target/link"))
            .unwrap()
            .is_symlink()
    );
    assert_eq!(
        fs::read_link(f.root().join("target/link")).unwrap(),
        outside
    );
    assert_eq!(fs::read_dir(f.root().join("target")).unwrap().count(), 1);
}

#[test]
fn hardlinked_inputs_reject_without_reading_shared_inode() {
    let f = Fixture::new();
    fs::write(f.root().join("outside"), b"not selected").unwrap();
    fs::hard_link(f.root().join("outside"), f.root().join("source/linked")).unwrap();
    assert!(
        f.copy(limits())
            .unwrap_err()
            .to_string()
            .contains("hardlinks")
    );
    assert!(Entries::new(&f.target).unwrap().next().unwrap().is_none());
}

#[test]
fn fifo_and_socket_reject_without_opening_or_blocking() {
    for socket in [false, true] {
        let f = Fixture::new();
        let name = f.root().join("source/special");
        let _listener = if socket {
            Some(UnixListener::bind(&name).unwrap())
        } else {
            let name = CString::new(name.as_os_str().as_bytes()).unwrap();
            syscall(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }).unwrap();
            None
        };
        assert!(
            f.copy(limits())
                .unwrap_err()
                .to_string()
                .contains("unsupported source entry")
        );
        assert_eq!(stat(&f.target).unwrap().st_mode & 0o777, 0o700);
    }
}

#[test]
fn bounds_precede_excess_writes_and_directory_allocation() {
    let f = Fixture::new();
    fs::write(f.root().join("source/large"), vec![0; BUFFER_BYTES * 2]).unwrap();
    let mut bound = limits();
    bound.bytes = BUFFER_BYTES as u64;
    assert!(
        f.copy(bound)
            .unwrap_err()
            .to_string()
            .contains("byte bound")
    );
    assert_eq!(
        fs::metadata(f.root().join("target/large")).unwrap().len(),
        bound.bytes
    );
    assert_eq!(stat(&f.target).unwrap().st_mode & 0o777, 0o700);
    for (entries, depth) in [(1, 16), (64, 1)] {
        let f = Fixture::new();
        fs::create_dir(f.root().join("source/nested")).unwrap();
        assert!(
            f.copy(Limits {
                entries,
                depth,
                ..limits()
            })
            .is_err()
        );
        assert!(Entries::new(&f.target).unwrap().next().unwrap().is_none());
    }
}

#[test]
fn invalid_limits_and_aliases_are_effect_free() {
    let f = Fixture::new();
    for bound in [
        Limits {
            entries: 0,
            ..limits()
        },
        Limits {
            depth: 0,
            ..limits()
        },
        Limits {
            depth: MAX_DEPTH + 1,
            ..limits()
        },
    ] {
        assert!(f.copy(bound).is_err());
        assert!(Entries::new(&f.target).unwrap().next().unwrap().is_none());
    }
    let uid = unsafe { libc::geteuid() };
    let gid = unsafe { libc::getegid() };
    assert!(
        copy_as(&f.source, &f.source, uid, gid, limits(), uid)
            .unwrap_err()
            .to_string()
            .contains("aliases")
    );
}

#[test]
fn nonempty_or_nonprivate_destinations_are_never_overwritten() {
    let f = Fixture::new();
    fs::write(f.root().join("target/foreign"), b"preserve").unwrap();
    assert!(
        f.copy(limits())
            .unwrap_err()
            .to_string()
            .contains("not empty")
    );
    assert_eq!(
        fs::read(f.root().join("target/foreign")).unwrap(),
        b"preserve"
    );
    let f = Fixture::new();
    fs::set_permissions(f.root().join("target"), fs::Permissions::from_mode(0o750)).unwrap();
    assert!(
        f.copy(limits())
            .unwrap_err()
            .to_string()
            .contains("not private")
    );
}

#[test]
fn enumeration_does_not_share_caller_directory_offsets() {
    let f = Fixture::new();
    fs::write(f.root().join("source/value"), b"x").unwrap();
    let mut entries = Entries::new(&f.source).unwrap();
    assert!(entries.next().unwrap().is_some());
    assert!(entries.next().unwrap().is_none());
    f.copy(limits()).unwrap();
    assert_eq!(fs::read(f.root().join("target/value")).unwrap(), b"x");
}

fn acl(mask: u16) -> Vec<u8> {
    let mut bytes = 2u32.to_le_bytes().to_vec();
    for (tag, permission, id) in [
        (1u16, 7u16, u32::MAX),
        (2, 7, 424242),
        (4, 0, u32::MAX),
        (16, mask, u32::MAX),
        (32, 0, u32::MAX),
    ] {
        bytes.extend(tag.to_le_bytes());
        bytes.extend(permission.to_le_bytes());
        bytes.extend(id.to_le_bytes());
    }
    bytes
}

#[test]
fn inherited_acl_entries_cannot_reactivate_when_group_access_is_granted() {
    let f = Fixture::new();
    fs::write(f.root().join("source/value"), b"private").unwrap();
    for (name, mask) in [
        (c"system.posix_acl_access", 0),
        (c"system.posix_acl_default", 7),
    ] {
        let bytes = acl(mask);
        syscall(unsafe {
            libc::fsetxattr(
                f.target.as_raw_fd(),
                name.as_ptr(),
                bytes.as_ptr().cast(),
                bytes.len(),
                0,
            )
        })
        .unwrap();
    }
    assert_eq!(stat(&f.target).unwrap().st_mode & 0o777, 0o700);
    f.copy(limits()).unwrap();
    for file in [
        &f.target,
        &File::open(f.root().join("target/value")).unwrap(),
    ] {
        assert_eq!(
            unsafe {
                libc::fgetxattr(
                    file.as_raw_fd(),
                    c"system.posix_acl_access".as_ptr(),
                    std::ptr::null_mut(),
                    0,
                )
            },
            -1
        );
        assert_eq!(
            io::Error::last_os_error().raw_os_error(),
            Some(libc::ENODATA)
        );
    }
    assert_eq!(
        unsafe {
            libc::fgetxattr(
                f.target.as_raw_fd(),
                c"system.posix_acl_default".as_ptr(),
                std::ptr::null_mut(),
                0,
            )
        },
        -1
    );
    assert_eq!(
        io::Error::last_os_error().raw_os_error(),
        Some(libc::ENODATA)
    );
}

#[test]
fn different_source_owner_rejects_before_copying() {
    let f = Fixture::new();
    let uid = unsafe { libc::geteuid() };
    let gid = unsafe { libc::getegid() };
    assert!(
        copy_as(&f.source, &f.target, uid + 1, gid, limits(), uid)
            .unwrap_err()
            .to_string()
            .contains("foreign source")
    );
    assert!(Entries::new(&f.target).unwrap().next().unwrap().is_none());
}

#[test]
fn exact_reader_acl_preserves_owner_other_and_never_grants_write() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("file");
    std::fs::write(&path, b"x").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o440)).unwrap();
    let file = File::open(&path).unwrap();
    let observed = stat(&file).unwrap();
    if let Err(error) = set_acl(&file, &observed, 4242, 0o4) {
        // Filesystems without POSIX ACLs fail closed; nothing to assert.
        assert!(error.to_string().contains("grant exact private reader"));
        return;
    }
    let mut bytes = [0u8; 64];
    let count = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            c"system.posix_acl_access".as_ptr(),
            bytes.as_mut_ptr().cast(),
            bytes.len(),
        )
    };
    assert_eq!(count, 4 + 5 * 8);
    let entries: Vec<(u16, u16, u32)> = bytes[4..count as usize]
        .chunks(8)
        .map(|entry| {
            (
                u16::from_le_bytes([entry[0], entry[1]]),
                u16::from_le_bytes([entry[2], entry[3]]),
                u32::from_le_bytes([entry[4], entry[5], entry[6], entry[7]]),
            )
        })
        .collect();
    assert_eq!(
        entries,
        vec![
            (0x01, 0o4, u32::MAX),
            (0x02, 0o4, 4242),
            (0x04, 0o4, u32::MAX),
            (0x10, 0o4, u32::MAX),
            (0x20, 0, u32::MAX)
        ]
    );
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o440);
}
