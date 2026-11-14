use super::*;
use std::os::unix::fs::{PermissionsExt, symlink};
use std::time::Duration;

fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(5)
}

fn image() -> ConfigImage {
    ConfigImage::new(unsafe { libc::geteuid() }.max(1)).unwrap()
}

fn config(path: &Path, bytes: &[u8]) {
    fs::write(path, bytes).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
}

#[test]
fn private_configuration_keeps_raw_bytes_and_one_bounded_image() {
    let directory = tempfile::tempdir().unwrap();
    let first = directory.path().join("a-config");
    let second = directory.path().join("b-config");
    let bytes = b"# fixture-only\r\n[includeIf \"gitdir:~/work/\"]\r\n\tpath = ../other\r\n";
    config(&first, bytes);
    config(&second, b"[core]\n\tfilemode = false\n");
    let mut image = image();
    image.capture_at(&second, deadline()).unwrap();
    image.capture_at(&first, deadline()).unwrap();
    assert_eq!(
        image.paths().collect::<Vec<_>>(),
        [first.as_path(), second.as_path()]
    );
    assert_eq!(image.bytes(&first).unwrap(), bytes);
    image.check_live(deadline()).unwrap();
    let value = serde_json::to_value(&image).unwrap();
    assert!(value.get("links").is_none());
    assert!(
        value["files"]
            .as_array()
            .unwrap()
            .iter()
            .all(|file| file.get("location").is_none())
    );
    let encoded = serde_json::to_vec(&image).unwrap();
    let decoded: ConfigImage = serde_json::from_slice(&encoded).unwrap();
    assert!(decoded == image);
    assert!(image.capture_at(&first, deadline()).is_err());
    assert_eq!(serde_json::to_vec(&image).unwrap(), encoded);
    let mut altered = decoded;
    altered.files[0].digest = "0".repeat(64);
    assert!(altered.validate().is_err());
}

#[test]
fn private_configuration_never_turns_missing_or_changed_files_into_absence() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("config");
    let mut image = image();
    assert!(image.capture_at(&path, deadline()).is_err());
    assert!(image.files.is_empty());
    config(&path, b"[core]\n\tfilemode = true\n");
    image.capture_at(&path, deadline()).unwrap();
    config(&path, b"[core]\n\tfilemode = false\n");
    assert!(image.check_live(deadline()).is_err());
    assert!(image.check_live(Instant::now()).is_err());
    assert_eq!(image.bytes(&path).unwrap(), b"[core]\n\tfilemode = true\n");
}

#[test]
fn private_configuration_rejects_special_files_and_shared_bounds() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("config");
    config(&path, b"[core]\n\tfilemode = true\n");
    let mut image = image();
    let hardlink = directory.path().join("hardlink");
    fs::hard_link(&path, &hardlink).unwrap();
    assert!(image.capture_at(&path, deadline()).is_err());
    let fifo = directory.path().join("fifo");
    let name = std::ffi::CString::new(fifo.as_os_str().as_bytes()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    assert!(image.capture_at(&fifo, deadline()).is_err());
    assert!(
        image
            .capture_at(&directory.path().join("forbidden.key"), deadline())
            .is_err()
    );
    let full = directory.path().join("full");
    config(&full, &vec![b'x'; MAX_BYTES]);
    image.capture_at(&full, deadline()).unwrap();
    let extra = directory.path().join("extra");
    config(&extra, b"x");
    assert!(image.capture_at(&extra, deadline()).is_err());
    assert_eq!(image.paths().count(), 1);
    image.validate().unwrap();
}

#[test]
fn configuration_aliases_keep_logical_origins_and_reject_replacement() {
    let directory = tempfile::tempdir().unwrap();
    let target = directory.path().join("profile");
    fs::create_dir(&target).unwrap();
    let file = target.join("config");
    let bytes = b"[include]\n\tpath = sibling\n";
    config(&file, bytes);
    let alias = directory.path().join("global");
    symlink("profile/config", &alias).unwrap();
    let mut image = image();
    image.capture_at(&alias, deadline()).unwrap();
    assert_eq!(image.paths().collect::<Vec<_>>(), [&alias]);
    assert_eq!(image.bytes(&alias).unwrap(), bytes);
    let location = image.files[0].location.as_ref().unwrap();
    assert_eq!(location.expanded, file);
    assert_eq!(location.resolved, file);
    assert_eq!(image.links.len(), 1);
    let encoded = serde_json::to_vec(&image).unwrap();
    let decoded: ConfigImage = serde_json::from_slice(&encoded).unwrap();
    assert!(decoded == image);
    decoded.check_live(deadline()).unwrap();
    fs::rename(&alias, directory.path().join("original")).unwrap();
    symlink("profile/config", &alias).unwrap();
    assert!(image.check_live(deadline()).is_err());
    // Fresh private aliases preserve text/path semantics, not original inodes.
    image
        .check_view(&directory.path().join(".git"), false, deadline())
        .unwrap();

    let mut bad = image.clone();
    bad.files[0].location = None;
    assert!(bad.validate().is_err());
    let mut bad = image.clone();
    bad.files[0].location.as_mut().unwrap().expanded = directory.path().join("different");
    assert!(bad.validate().is_err());
    let mut bad = image;
    let mut unused = bad.links[0].clone();
    unused.path = directory.path().join("unused");
    bad.links.push(unused);
    bad.links.sort_by(|a, b| a.path.cmp(&b.path));
    assert!(bad.validate().is_err());
}

#[test]
fn configuration_aliases_do_not_bypass_credentials_or_local_mutability() {
    let directory = tempfile::tempdir().unwrap();
    let git = directory.path().join(".git");
    fs::create_dir(&git).unwrap();
    let alias = git.join("config");
    let external = directory.path().join("external");
    config(&external, b"# fixture\n");
    symlink(&external, &alias).unwrap();
    let mut image = image();
    image.capture_at(&alias, deadline()).unwrap();
    image.check_view(&git, false, deadline()).unwrap();
    assert!(image.check_view(&git, true, deadline()).is_err());

    let forbidden = directory.path().join("fixture.key");
    config(&forbidden, b"synthetic denied fixture");
    let alias = directory.path().join("alias");
    symlink(&forbidden, &alias).unwrap();
    let encoded = serde_json::to_vec(&image).unwrap();
    assert!(image.capture_at(&alias, deadline()).is_err());
    assert_eq!(serde_json::to_vec(&image).unwrap(), encoded);
}

#[test]
fn checkout_mutability_does_not_exempt_external_configuration() {
    let directory = tempfile::tempdir().unwrap();
    let git = directory.path().join(".git");
    fs::create_dir(&git).unwrap();
    let local = git.join("config");
    let global = directory.path().join("global");
    config(&local, b"[core]\n\tbare = false\n");
    config(&global, b"[core]\n\tfilemode = true\n");
    let mut image = image();
    image.capture_at(&local, deadline()).unwrap();
    image.capture_at(&global, deadline()).unwrap();
    image.check_view(&git, false, deadline()).unwrap();
    config(&local, b"# private native checkout mutation\n");
    assert!(image.check_view(&git, false, deadline()).is_err());
    image.check_view(&git, true, deadline()).unwrap();
    config(&global, b"# external mutation\n");
    assert!(image.check_view(&git, true, deadline()).is_err());
    // This command-time veto is not source sealing or native-consumption proof.
}
