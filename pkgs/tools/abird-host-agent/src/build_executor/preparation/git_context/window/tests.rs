use super::*;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::process::Stdio;
use std::time::Duration;

const CHILD: &str = "build_executor::preparation::git_context::window::tests::lease_child";

// Parallel-test forks can retain writable FDs until exec despite CLOEXEC.
// Create lease fixtures in isolated processes; no acquisition retry or
// production fallback.
fn isolated(name: &str) -> bool {
    if std::env::var("ABIRD_GIT_WINDOW_ISOLATED").ok().as_deref() == Some(name) {
        return true;
    }
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--exact",
            &format!("build_executor::preparation::git_context::window::tests::{name}"),
            "--nocapture",
            "--test-threads=1",
        ])
        .env("ABIRD_GIT_WINDOW_ISOLATED", name);
    let observed = crate::build_executor::process::transport::exchange(
        &mut command,
        &[],
        crate::build_executor::process::Limits {
            stdin: 1,
            stdout: 64 * 1024,
            stderr: 32 * 1024,
        },
        Instant::now() + Duration::from_secs(30),
    )
    .unwrap();
    assert!(
        observed.complete && observed.status.is_some_and(|status| status.success()),
        "isolated lease test {name} failed: {}",
        String::from_utf8_lossy(&observed.stdout)
    );
    false
}

fn limits() -> Limits {
    Limits {
        entries: 128,
        bytes: 4096,
        depth: 8,
    }
}
fn deadline() -> Instant {
    Instant::now() + Duration::from_secs(10)
}
fn window(path: &Path) -> Result<ReadWindow> {
    ReadWindow::open_at(path, unsafe { libc::geteuid() }, limits(), deadline())
}
fn fixture() -> tempfile::TempDir {
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("HEAD"), b"ref: refs/heads/main\n").unwrap();
    root
}

fn child(path: &Path, mode: &str) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args(["--exact", CHILD, "--nocapture"])
        .env("ABIRD_GIT_WINDOW_TEST_PATH", path)
        .env("ABIRD_GIT_WINDOW_TEST_MODE", mode);
    command
}

#[test]
fn lease_child() {
    let Some(path) = std::env::var_os("ABIRD_GIT_WINDOW_TEST_PATH") else {
        return;
    };
    let mode = std::env::var("ABIRD_GIT_WINDOW_TEST_MODE").unwrap();
    if mode == "writer" {
        let result = OpenOptions::new()
            .write(true)
            .custom_flags(libc::O_NONBLOCK)
            .open(path);
        assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
        return;
    }
    assert_eq!(mode, "mapping");
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .open(path)
        .unwrap();
    let memory = unsafe {
        libc::mmap(
            std::ptr::null_mut(),
            1,
            libc::PROT_READ | libc::PROT_WRITE,
            libc::MAP_SHARED,
            file.as_raw_fd(),
            0,
        )
    };
    assert_ne!(memory, libc::MAP_FAILED);
    drop(file);
    println!("MAPPING_HELD_AFTER_FD_CLOSE");
    std::io::stdout().flush().unwrap();
    let mut release = [0u8; 1];
    std::io::stdin().read_exact(&mut release).unwrap();
    unsafe {
        memory.cast::<u8>().write(b'r');
    }
    assert_eq!(unsafe { libc::munmap(memory, 1) }, 0);
}

#[test]
fn read_window_keeps_leases_cloexec_and_restores_the_original_thread_mask() {
    if !isolated("read_window_keeps_leases_cloexec_and_restores_the_original_thread_mask") {
        return;
    }
    let root = fixture();
    let before = mask();
    let window = window(root.path()).unwrap();
    window.check().unwrap();
    assert_eq!(window.leases.len(), 1);
    for held in &window.leases {
        assert!(!held.immutable);
        let file = &held.file;
        assert_ne!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFD) } & libc::FD_CLOEXEC,
            0
        );
        assert_eq!(
            unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETLEASE) },
            libc::F_RDLCK
        );
    }
    let during = mask();
    assert_eq!(
        member(&during, libc::SIGPIPE),
        member(&before, libc::SIGPIPE)
    );
    assert_eq!(member(&during, libc::SIGRTMAX()), 1);
    window.finish().unwrap();
    let after = mask();
    for signal in 1..=libc::SIGRTMAX() {
        assert_eq!(member(&after, signal), member(&before, signal));
    }
}

#[test]
fn a_window_cannot_be_reused_for_another_repository_path() {
    if !isolated("a_window_cannot_be_reused_for_another_repository_path") {
        return;
    }
    let root = fixture();
    let other = fixture();
    let window = window(root.path()).unwrap();
    assert!(window.require_path(other.path()).is_err());
    assert!(window.require_path(root.path()).is_err());
}

#[test]
fn namespace_changes_poison_the_window_even_when_an_error_is_swallowed() {
    if !isolated("namespace_changes_poison_the_window_even_when_an_error_is_swallowed") {
        return;
    }
    let root = fixture();
    let window = window(root.path()).unwrap();
    std::fs::rename(root.path().join("HEAD"), root.path().join("OTHER")).unwrap();
    assert!(window.check().is_err());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
}

#[test]
fn metadata_changes_without_a_writer_poison_the_live_poll() {
    if !isolated("metadata_changes_without_a_writer_poison_the_live_poll") {
        return;
    }
    use std::os::unix::fs::PermissionsExt;
    let root = fixture();
    let window = window(root.path()).unwrap();
    std::fs::set_permissions(
        root.path().join("HEAD"),
        std::fs::Permissions::from_mode(0o400),
    )
    .unwrap();
    assert!(window.poll().is_err());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
}

#[test]
fn a_nonblocking_writer_cannot_mutate_and_its_break_vetoes_capture() {
    if !isolated("a_nonblocking_writer_cannot_mutate_and_its_break_vetoes_capture") {
        return;
    }
    let root = fixture();
    let window = window(root.path()).unwrap();
    let mut writer = child(&root.path().join("HEAD"), "writer");
    window.prepare_command(&mut writer).unwrap();
    assert!(writer.status().unwrap().success());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
    assert_eq!(
        std::fs::read(root.path().join("HEAD")).unwrap(),
        b"ref: refs/heads/main\n"
    );
}

#[test]
fn a_writable_shared_mapping_without_its_original_fd_prevents_capture() {
    if !isolated("a_writable_shared_mapping_without_its_original_fd_prevents_capture") {
        return;
    }
    let root = fixture();
    let mut child = child(&root.path().join("HEAD"), "mapping")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    // Child progress, not a clock-only wait; the test process is bounded by the
    // consolidated child-process qualification deadline.
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    loop {
        line.clear();
        assert_ne!(output.read_line(&mut line).unwrap(), 0);
        if line.trim() == "MAPPING_HELD_AFTER_FD_CLOSE" {
            break;
        }
    }
    let result = window(root.path());
    child.stdin.take().unwrap().write_all(b"x").unwrap();
    assert!(child.wait().unwrap().success());
    assert!(
        result.is_err(),
        "writable mappings must not be mistaken for closed writers"
    );
    window(root.path()).unwrap().finish().unwrap();
}

#[test]
fn unsafe_entries_and_original_bounds_are_not_lease_fallbacks() {
    if !isolated("unsafe_entries_and_original_bounds_are_not_lease_fallbacks") {
        return;
    }
    let root = fixture();
    symlink("HEAD", root.path().join("link")).unwrap();
    assert!(window(root.path()).is_err());
    std::fs::remove_file(root.path().join("link")).unwrap();
    std::fs::hard_link(root.path().join("HEAD"), root.path().join("alias")).unwrap();
    assert!(window(root.path()).is_err());
    std::fs::remove_file(root.path().join("alias")).unwrap();
    let uid = unsafe { libc::geteuid() };
    assert!(
        ReadWindow::open_at(
            root.path(),
            uid,
            Limits {
                entries: 1,
                ..limits()
            },
            deadline()
        )
        .is_err()
    );
    assert!(
        ReadWindow::open_at(
            root.path(),
            uid,
            Limits {
                bytes: 1,
                ..limits()
            },
            deadline()
        )
        .is_err()
    );
    assert!(ReadWindow::open_at(root.path(), uid, limits(), Instant::now()).is_err());
}

#[test]
fn profile_and_git_share_one_window_and_reuse_local_configuration_leases() {
    if !isolated("profile_and_git_share_one_window_and_reuse_local_configuration_leases") {
        return;
    }
    let root = fixture();
    let profile = fixture();
    let uid = unsafe { libc::geteuid() };
    let cutoff = deadline();
    let before = mask();
    let mut window = ReadWindow::begin_at(uid, limits(), cutoff).unwrap();
    window
        .hold_configuration(&profile.path().join("HEAD"), uid)
        .unwrap();
    window.bind_git(root.path()).unwrap();
    window
        .hold_configuration(&root.path().join("HEAD"), uid)
        .unwrap();
    assert_eq!(window.leases.len(), 2);
    assert_eq!(window.held_files.len(), 2);
    assert_eq!(window.deadline, cutoff);
    window.require_path(root.path()).unwrap();
    window.finish().unwrap();
    let after = mask();
    for signal in 1..=libc::SIGRTMAX() {
        assert_eq!(member(&after, signal), member(&before, signal));
    }
}

#[test]
fn restoring_a_profile_ancestor_does_not_erase_the_namespace_veto() {
    if !isolated("restoring_a_profile_ancestor_does_not_erase_the_namespace_veto") {
        return;
    }
    let root = fixture();
    let profile = fixture();
    let path = profile.path().join("HEAD");
    let uid = unsafe { libc::geteuid() };
    let mut window = ReadWindow::begin_at(uid, limits(), deadline()).unwrap();
    window.hold_configuration(&path, uid).unwrap();
    window.bind_git(root.path()).unwrap();
    let moved = profile.path().with_extension("moved");
    std::fs::rename(profile.path(), &moved).unwrap();
    std::fs::rename(&moved, profile.path()).unwrap();
    assert_eq!(std::fs::read(&path).unwrap(), b"ref: refs/heads/main\n");
    assert!(window.poll().is_err());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
}

#[test]
fn a_profile_writer_cannot_be_healed_by_later_git_binding() {
    if !isolated("a_profile_writer_cannot_be_healed_by_later_git_binding") {
        return;
    }
    let root = fixture();
    let profile = fixture();
    let path = profile.path().join("HEAD");
    let uid = unsafe { libc::geteuid() };
    let mut window = ReadWindow::begin_at(uid, limits(), deadline()).unwrap();
    window.hold_configuration(&path, uid).unwrap();
    let mut writer = child(&path, "writer");
    window.prepare_command(&mut writer).unwrap();
    assert!(writer.status().unwrap().success());
    assert!(window.bind_git(root.path()).is_err());
    assert!(window.finish().is_err());
    assert_eq!(std::fs::read(path).unwrap(), b"ref: refs/heads/main\n");
}

#[test]
fn profile_bytes_consume_the_original_window_budget() {
    if !isolated("profile_bytes_consume_the_original_window_budget") {
        return;
    }
    let root = fixture();
    let profile = fixture();
    let uid = unsafe { libc::geteuid() };
    let mut window = ReadWindow::begin_at(
        uid,
        Limits {
            bytes: 30,
            ..limits()
        },
        deadline(),
    )
    .unwrap();
    window
        .hold_configuration(&profile.path().join("HEAD"), uid)
        .unwrap();
    assert!(window.bind_git(root.path()).is_err());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
}

#[test]
fn executable_namespace_watches_survive_restored_ancestors_and_precede_git_binding() {
    if !isolated("executable_namespace_watches_survive_restored_ancestors_and_precede_git_binding")
    {
        return;
    }
    let profile = tempfile::tempdir().unwrap();
    let selected = profile.path().join("selected");
    std::fs::create_dir(&selected).unwrap();
    let target = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .filter_map(|path| std::fs::canonicalize(path).ok())
        .find(|path| path.starts_with("/nix/store") && path.is_dir())
        .expect("immutable package-managed test PATH");
    let alias = selected.join("current");
    symlink(&target, &alias).unwrap();
    let uid = unsafe { libc::geteuid() };
    let cutoff = deadline();
    let mut window = ReadWindow::begin_at(uid, limits(), cutoff).unwrap();
    let search = crate::build_executor::preparation::search_path::SearchPath::capture_observed(
        alias.to_str().unwrap(),
        cutoff,
        |path| window.hold_path_component(path),
    )
    .unwrap();
    let before = std::fs::symlink_metadata(&alias).unwrap();
    // Unrelated sibling activity does not poison a directory-self watch,
    // including named IN_ATTRIB child events (e.g. a busy /nix/store or /tmp).
    std::fs::write(selected.join("unrelated"), b"not a selected component").unwrap();
    let sibling = profile.path().join("sibling");
    std::fs::create_dir(&sibling).unwrap();
    std::fs::set_permissions(&sibling, std::fs::Permissions::from_mode(0o700)).unwrap();
    window.check().unwrap();
    let moved = profile.path().join("moved");
    std::fs::rename(&selected, &moved).unwrap();
    std::fs::rename(&moved, &selected).unwrap();
    let after = std::fs::symlink_metadata(&alias).unwrap();
    assert_eq!(
        (
            before.dev(),
            before.ino(),
            before.ctime(),
            before.ctime_nsec()
        ),
        (after.dev(), after.ino(), after.ctime(), after.ctime_nsec())
    );
    search.check_live(cutoff).unwrap(); // Final PATH binding alone would pass.
    assert!(window.poll().is_err());
    let git = fixture();
    assert!(window.bind_git(git.path()).is_err());
    assert!(window.finish().is_err());
}

#[test]
fn configuration_aliases_acquire_the_original_target_lease_before_bytes() {
    if !isolated("configuration_aliases_acquire_the_original_target_lease_before_bytes") {
        return;
    }
    let profile = fixture();
    let alias = profile.path().join("global");
    symlink("HEAD", &alias).unwrap();
    let uid = unsafe { libc::geteuid() };
    let cutoff = deadline();
    let mut window = ReadWindow::begin_at(uid, limits(), cutoff).unwrap();
    let mut image = crate::build_executor::preparation::git_profile::ConfigImage::new(uid).unwrap();
    image
        .capture_watched(&alias, cutoff, |path, content| {
            if content {
                window.hold_configuration(path, uid)
            } else {
                window.hold_path_component(path)
            }
        })
        .unwrap();
    assert_eq!(window.leases.len(), 1);
    assert_eq!(image.bytes(&alias).unwrap(), b"ref: refs/heads/main\n");
    let mut writer = child(&profile.path().join("HEAD"), "writer");
    window.prepare_command(&mut writer).unwrap();
    assert!(writer.status().unwrap().success());
    assert!(window.check().is_err());
    assert!(window.finish().is_err());
}

#[test]
fn replacing_a_watched_path_alias_cannot_silently_change_executable_resolution() {
    if !isolated("replacing_a_watched_path_alias_cannot_silently_change_executable_resolution") {
        return;
    }
    let profile = tempfile::tempdir().unwrap();
    let target = profile.path().join("target");
    std::fs::create_dir(&target).unwrap();
    let alias = profile.path().join("current");
    symlink(&target, &alias).unwrap();
    let mut window =
        ReadWindow::begin_at(unsafe { libc::geteuid() }, limits(), deadline()).unwrap();
    window.hold_path_component(&alias).unwrap();
    std::fs::rename(&alias, profile.path().join("saved")).unwrap();
    symlink("other", &alias).unwrap();
    assert!(window.poll().is_err());
    assert!(window.check().is_err());
}

fn mask() -> libc::sigset_t {
    let mut mask = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
    assert_eq!(
        unsafe { libc::pthread_sigmask(libc::SIG_SETMASK, std::ptr::null(), mask.as_mut_ptr()) },
        0
    );
    unsafe { mask.assume_init() }
}
fn member(mask: &libc::sigset_t, signal: i32) -> i32 {
    unsafe { libc::sigismember(mask, signal) }
}

#[test]
fn event_decoding_is_bounded_and_rejects_truncation() {
    let mut bytes = Vec::new();
    for (wd, name) in [(2i32, b"child\0\0\0".as_slice()), (3, b"".as_slice())] {
        bytes.extend(wd.to_ne_bytes());
        bytes.extend(libc::IN_ATTRIB.to_ne_bytes());
        bytes.extend(0u32.to_ne_bytes());
        bytes.extend(u32::try_from(name.len()).unwrap().to_ne_bytes());
        bytes.extend(name);
    }
    assert_eq!(super::events(&bytes).unwrap(), [(2, true), (3, false)]);
    assert!(super::events(&bytes[..bytes.len() - 1]).is_err());
    assert!(super::events(&bytes[..10]).is_err());
}
