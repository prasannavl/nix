//! Native Git image export. Copies the actual indexed working view and complete
//! common administration, without checkout, index reconstruction or path flakes.
use abird_host_agent::build_executor::{
    preparation::{
        capsule::GitImage,
        git_context::{GitContext, GitLayout, MAX_NAR_BYTES, Observation, window::ReadWindow},
    },
    private_tree,
    process::{Limits, Runner},
};
use anyhow::{Context, Result, ensure};
use std::ffi::{CString, OsStr, OsString};
use std::fs::{self, File};
use std::os::unix::{
    ffi::OsStrExt,
    fs::{MetadataExt, PermissionsExt},
};
use std::path::Path;
use std::process::Command;
use std::time::Instant;

#[allow(clippy::too_many_arguments)]
pub(super) fn capture(
    layout: &GitLayout,
    revision: String,
    directory: &Path,
    git: &Path,
    nar: &Path,
    nar_configuration: &Path,
    environment: &[(OsString, OsString)],
    limits: private_tree::Limits,
    deadline: Instant,
    window: &mut ReadWindow,
    caller_digest: &str,
) -> Result<GitImage> {
    fs::create_dir(directory)?;
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    let uid = unsafe { libc::geteuid() };
    let worktree = directory.join("worktree");
    fs::create_dir(&worktree)?;
    let mut runner = Runner::new_source(
        uid,
        Limits {
            stdin: MAX_NAR_BYTES,
            stdout: MAX_NAR_BYTES,
            stderr: 4096,
        },
        deadline,
        MAX_NAR_BYTES,
    )?;
    // Recheck in the selected worktree: includeIf/gitdir may activate a
    // different filter profile than the original source repository.
    super::config::require_filters(&layout.worktree, git, environment, &mut runner, window)?;
    let mut command = Command::new(git);
    command
        .current_dir(&layout.worktree)
        .env_clear()
        .envs(environment.iter().cloned())
        .args(["ls-files", "--cached", "-z"]);
    window.prepare_command(&mut command)?;
    let result = runner.run_while(&mut command, &[], || window.poll())?;
    ensure!(
        result.status.success() && (result.stdout.is_empty() || result.stdout.last() == Some(&0)),
        "native working-path capture failed"
    );
    let mut bytes = 0u64;
    let mut count = 0u32;
    for name in result
        .stdout
        .split(|b| *b == 0)
        .filter(|name| !name.is_empty())
    {
        let relative = Path::new(OsStr::from_bytes(name));
        ensure!(
            relative
                .components()
                .all(|part| matches!(part, std::path::Component::Normal(_)))
                && relative.extension().is_none_or(|ext| ext != "key")
                && relative.components().count() < usize::from(limits.depth),
            "native source enters prohibited/unrepresentable path"
        );
        let source = layout.worktree.join(relative);
        window.hold_source_directory(source.parent().context("working parent missing")?)?;
        let metadata = match fs::symlink_metadata(&source) {
            Ok(value) => value,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error.into()),
        };
        ensure!(
            !metadata.is_dir(),
            "native Git submodule requires its own captured context"
        );
        if metadata.is_symlink() {
            window.hold_source_link(&source)?;
        } else {
            window.hold_source_file(&source)?;
        }
        let metadata = fs::symlink_metadata(&source)?;
        count += 1;
        bytes = bytes
            .checked_add(metadata.len())
            .context("native working size overflow")?;
        ensure!(
            count <= limits.entries && bytes <= limits.bytes && Instant::now() < deadline,
            "native working view exceeds declared bound"
        );
        let target = worktree.join(relative);
        fs::create_dir_all(target.parent().context("working path parent missing")?)?;
        if metadata.is_symlink() {
            std::os::unix::fs::symlink(fs::read_link(&source)?, &target)?;
            let stamp = libc::timespec {
                tv_sec: metadata.mtime(),
                tv_nsec: metadata.mtime_nsec(),
            };
            let times = [stamp, stamp];
            let name = CString::new(target.as_os_str().as_bytes())?;
            ensure!(
                unsafe {
                    libc::utimensat(
                        libc::AT_FDCWD,
                        name.as_ptr(),
                        times.as_ptr(),
                        libc::AT_SYMLINK_NOFOLLOW,
                    )
                } == 0,
                "native symlink timestamp copy failed"
            );
        } else {
            ensure!(metadata.is_file(), "unsupported native working entry");
            fs::copy(&source, &target)?;
            File::open(&target)?.set_modified(metadata.modified()?)?;
        }
    }
    let dotgit = layout.worktree.join(".git");
    if fs::symlink_metadata(&dotgit)?.is_file() {
        window.hold_source_file(&dotgit)?;
        fs::copy(&dotgit, worktree.join(".git"))?;
    } else {
        fs::create_dir(worktree.join(".git"))?;
    }
    // Preserve the complete real common directory, including linked admin data.
    // A separate native restore is filesystem-only and has no daemon backend.
    let before = Observation::read(&layout.common, uid, limits, deadline)?;
    let mut command = nar_command(nar, nar_configuration);
    command.arg("--dump").arg(&layout.common);
    window.prepare_command(&mut command)?;
    let archive = runner.run_while(&mut command, &[], || window.poll())?;
    ensure!(archive.status.success(), "native common Git dump failed");
    let captured = GitContext::new(caller_digest.to_owned(), &archive.stdout, before)?;
    let mut command = nar_command(nar, nar_configuration);
    command.arg("--restore").arg(directory.join("common"));
    let restored = runner.run(&mut command, &archive.stdout)?;
    ensure!(
        restored.status.success(),
        "native common Git restore failed"
    );
    drop(archive);
    captured.restore_times(&directory.join("common"), uid, limits, deadline)?;
    drop(captured);
    let before = Observation::read(directory, uid, limits, deadline)?;
    let mut command = nar_command(nar, nar_configuration);
    command.arg("--dump").arg(directory);
    let output = runner.run_while(&mut command, &[], || window.poll())?;
    ensure!(
        output.status.success() && before == Observation::read(directory, uid, limits, deadline)?,
        "native image export changed"
    );
    window.check()?;
    let image = GitContext::new(caller_digest.to_owned(), &output.stdout, before)?;
    image.require_limits(limits)?;
    let root = GitImage {
        worktree: layout.worktree.clone(),
        common: layout.common.clone(),
        revision,
        image,
    };
    root.validate()?;
    Ok(root)
}

fn nar_command(program: &Path, configuration: &Path) -> Command {
    let mut command = Command::new(program);
    command
        .current_dir("/var/empty")
        .env_clear()
        .env("HOME", "/var/empty")
        .env("PATH", "/var/empty")
        .env("NIX_CONF_DIR", configuration);
    command
}
