use super::*;
use std::cell::Cell;
use std::collections::VecDeque;
use std::process::ExitStatus;

use crate::fleet::repository::{CommitSha, StagedPatch};

fn environment() -> Vec<(OsString, OsString)> {
    [
        ("HOME", "/private/home"),
        ("PATH", "/pinned/bin"),
        ("GIT_CONFIG_NOSYSTEM", "1"),
    ]
    .into_iter()
    .map(|(k, v)| (k.into(), v.into()))
    .collect()
}
fn policy() -> RepositoryCommands {
    RepositoryCommands::new(
        "/pinned/git".into(),
        "/private".into(),
        vec!["/source".into(), "/execution".into()],
        environment(),
    )
    .unwrap()
}
fn output(status: i32, stdout: &[u8]) -> Result<Captured> {
    Ok(Captured {
        status: ExitStatus::from_raw(status << 8),
        stdout: stdout.into(),
        stderr: b"PRIVATE-STDERR".to_vec(),
    })
}
struct Seen {
    args: Vec<OsString>,
    cwd: PathBuf,
    input: Vec<u8>,
    environment: BTreeMap<OsString, Option<OsString>>,
}
#[derive(Default)]
struct Fake {
    replies: VecDeque<Result<Captured>>,
    seen: Vec<Seen>,
    checks: Cell<usize>,
    fail_check: Option<usize>,
}
impl Fake {
    fn new(replies: Vec<Result<Captured>>) -> Self {
        Self {
            replies: replies.into(),
            ..Self::default()
        }
    }
}
impl Capture for Fake {
    fn run(&mut self, command: &mut Command, input: &[u8]) -> Result<Captured> {
        assert_eq!(command.get_program(), "/pinned/git");
        self.seen.push(Seen {
            args: command.get_args().map(OsStr::to_owned).collect(),
            cwd: command.get_current_dir().unwrap().into(),
            input: input.into(),
            environment: command
                .get_envs()
                .map(|(k, v)| (k.into(), v.map(OsStr::to_owned)))
                .collect(),
        });
        self.replies
            .pop_front()
            .expect("unexpected repository helper")
    }
    fn check(&self) -> Result<()> {
        self.checks.set(self.checks.get() + 1);
        ensure!(
            self.fail_check != Some(self.checks.get()),
            "fake readiness denied"
        );
        Ok(())
    }
}
fn args(values: &[&str]) -> Vec<OsString> {
    values.iter().map(OsString::from).collect()
}
fn patch() -> StagedPatch {
    StagedPatch {
        base: CommitSha::parse("a".repeat(40)).unwrap(),
        bytes: b"binary\0patch\xff".to_vec(),
    }
}

#[test]
fn policy_rejects_ambient_paths_repository_executables_and_selector_environment() {
    for (git, cwd, dirs) in [
        ("git", "/private", vec![]),
        ("/pinned/git", "relative", vec![]),
        ("/source/git", "/private", vec!["/source".into()]),
        ("/pinned/git", "/private", vec!["/source/../other".into()]),
    ] {
        assert!(RepositoryCommands::new(git.into(), cwd.into(), dirs, environment()).is_err());
    }
    for key in GIT_REPOSITORY_ENVIRONMENT {
        let mut env = environment();
        env.push((key.into(), "/secret-selector".into()));
        let error = RepositoryCommands::new("/pinned/git".into(), "/private".into(), vec![], env)
            .err()
            .unwrap();
        assert!(!error.to_string().contains("secret-selector"));
    }
    for env in [
        vec![],
        vec![
            ("HOME".into(), "relative".into()),
            ("GIT_CONFIG_NOSYSTEM".into(), "1".into()),
        ],
        vec![
            ("HOME".into(), "/private/home".into()),
            ("GIT_CONFIG_NOSYSTEM".into(), "0".into()),
        ],
    ] {
        assert!(
            RepositoryCommands::new("/pinned/git".into(), "/private".into(), vec![], env).is_err()
        );
    }
}

#[test]
fn duplicate_invalid_and_oversized_environment_is_not_silently_normalized() {
    for extra in [
        ("HOME", b"/other".to_vec()),
        ("BAD=KEY", b"secret".to_vec()),
        ("VALUE", b"secret\0value".to_vec()),
        ("LARGE", vec![b'x'; 65536]),
    ] {
        use std::os::unix::ffi::OsStringExt;
        let mut env = environment();
        env.push((extra.0.into(), OsString::from_vec(extra.1)));
        assert!(
            RepositoryCommands::new("/pinned/git".into(), "/private".into(), vec![], env).is_err()
        );
    }
}

#[test]
fn command_keeps_explicit_cwd_and_environment_without_per_request_overrides() {
    let policy = policy();
    let request = CommandRequest::new("/pinned/git").args(["clone", "source", "/execution"]);
    assert_eq!(
        policy.command(&request).unwrap().get_current_dir(),
        Some(Path::new("/private"))
    );
    for request in [
        CommandRequest::new("/other/git"),
        request.clone().current_dir("/ambient"),
        request.environment([("TOKEN", "private-secret")]),
    ] {
        let error = policy.command(&request).err().unwrap();
        assert!(!error.to_string().contains("private-secret"));
    }
}

#[test]
fn native_binary_patch_application_preserves_exact_bytes_and_argv() {
    let mut capture = Fake::new(vec![output(0, b"")]);
    policy()
        .with_capture(&mut capture, |manager| {
            manager.apply_staged_patch(Path::new("/execution"), &patch())
        })
        .unwrap();
    let seen = &capture.seen[0];
    assert_eq!(
        seen.args,
        args(&["apply", "--index", "--binary", "--allow-empty", "-"])
    );
    assert_eq!(seen.cwd, Path::new("/execution"));
    assert_eq!(seen.input, patch().bytes);
    assert_eq!(
        seen.environment,
        environment()
            .into_iter()
            .map(|(k, v)| (k, Some(v)))
            .collect()
    );
    assert_eq!(capture.checks.get(), 2);
}

#[test]
fn native_staged_capture_preserves_base_binary_diff_and_ignored_changes() {
    let revision = format!("{}\n", "a".repeat(40));
    let mut capture = Fake::new(vec![
        output(1, b""),
        output(0, &patch().bytes),
        output(0, revision.as_bytes()),
        output(1, b""),
        output(0, b"untracked\n"),
    ]);
    let result = policy()
        .with_capture(&mut capture, |manager| {
            manager.capture_staged_patch(Path::new("/source"))
        })
        .unwrap()
        .unwrap();
    assert_eq!(result.patch, patch());
    assert!(result.ignored.unstaged_tracked && result.ignored.untracked);
    assert_eq!(
        capture.seen[0].args,
        args(&["diff", "--cached", "--quiet", "--no-ext-diff", "--"])
    );
    assert_eq!(
        capture.seen[1].args,
        args(&[
            "diff",
            "--cached",
            "--binary",
            "--full-index",
            "--no-ext-diff",
            "--"
        ])
    );
    assert_eq!(
        capture.seen[2].args,
        args(&["rev-parse", "--verify", "HEAD^{commit}"])
    );
}

#[test]
fn observed_no_staged_change_is_not_an_error_or_a_second_capture() {
    let mut capture = Fake::new(vec![output(0, b"")]);
    assert!(
        policy()
            .with_capture(&mut capture, |manager| manager
                .capture_staged_patch(Path::new("/source")))
            .unwrap()
            .is_none()
    );
    assert_eq!(capture.seen.len(), 1);
}

#[test]
fn native_errors_keep_observed_status_without_dumping_private_stderr() {
    for reply in [
        output(42, b""),
        Ok(Captured {
            status: ExitStatus::from_raw(libc::SIGTERM),
            stdout: vec![],
            stderr: b"PRIVATE-STDERR".to_vec(),
        }),
    ] {
        let mut capture = Fake::new(vec![reply]);
        let error = policy()
            .with_capture(&mut capture, |manager| {
                manager.apply_staged_patch(Path::new("/execution"), &patch())
            })
            .unwrap_err();
        let message = error.to_string();
        assert!(message.contains("status 42") || message.contains("status 143"));
        assert!(!message.contains("PRIVATE-STDERR"));
    }
}

#[test]
fn ignored_native_prune_uncertainty_cannot_escape_scope_or_start_another_command() {
    let revision = format!("{}\n", "a".repeat(40));
    let mut capture = Fake::new(vec![
        output(0, revision.as_bytes()),
        output(0, b""),
        Err(anyhow::anyhow!("uncertain capture")),
    ]);
    let error = policy()
        .with_capture(&mut capture, |manager| {
            let worktree = manager.create_detached_worktree(
                Path::new("/source"),
                Path::new("/execution"),
                patch().base.as_str(),
            )?;
            assert!(manager.ensure_clean(Path::new("/source"), false).is_err());
            Ok(worktree)
        })
        .unwrap_err();
    assert!(error.to_string().contains("unresolved"));
    assert_eq!(capture.seen.len(), 3);
    assert_eq!(capture.seen[2].args, args(&["worktree", "prune"]));
}

#[test]
fn caught_policy_errors_cannot_become_successful_native_scope_results() {
    let mut capture = Fake::default();
    assert!(
        policy()
            .with_capture(&mut capture, |manager| {
                assert!(manager.ensure_clean(Path::new("/foreign"), false).is_err());
                Ok(())
            })
            .is_err()
    );
    assert!(capture.seen.is_empty());
}

#[test]
fn entry_and_exit_readiness_cover_operations_without_helpers() {
    for fail in [1, 2] {
        let mut capture = Fake {
            fail_check: Some(fail),
            ..Fake::default()
        };
        let entered = Cell::new(false);
        assert!(
            policy()
                .with_capture(&mut capture, |_| {
                    entered.set(true);
                    Ok(())
                })
                .is_err()
        );
        assert_eq!(entered.get(), fail == 2);
        assert!(capture.seen.is_empty());
    }
}

#[test]
fn public_scope_checks_identity_before_any_native_operation() {
    let uid = if unsafe { libc::geteuid() } == 1000 {
        1001
    } else {
        1000
    };
    let mut runner = Runner::new(
        uid,
        abird_host_agent::build_executor::process::Limits {
            stdin: 1024,
            stdout: 1024,
            stderr: 1024,
        },
        std::time::Instant::now() + std::time::Duration::from_secs(1),
    )
    .unwrap();
    assert!(
        policy()
            .with_repository(&mut runner, |_| -> Result<()> {
                panic!("foreign identity entered source scope")
            })
            .is_err()
    );
}
