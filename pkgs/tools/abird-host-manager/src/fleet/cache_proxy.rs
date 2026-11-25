//! A transfer-scoped route to the signed HTTP cache. Nix keeps its original
//! store URL; SOCKS5h resolves the publisher from the owner's network.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail, ensure};

use super::host_runtime::{HostExecutionTarget, ssh_connection_args_without_control_master};

pub(super) struct CacheProxy {
    child: Child,
    environment: ProxyEnvironment,
    _directory: tempfile::TempDir,
}

impl CacheProxy {
    pub(super) fn open(
        owner: &HostExecutionTarget,
        root: &Path,
        check: impl Fn() -> Result<()>,
    ) -> Result<Self> {
        check()?;
        ensure!(!owner.local, "local cache owner needs no SSH relay");
        let directory = tempfile::Builder::new()
            .prefix("r-")
            .permissions(std::fs::Permissions::from_mode(0o700))
            .tempdir_in(root)?;
        let socket = directory.path().join("s");
        let environment = ProxyEnvironment::for_socket(&socket)?;
        let mut errors = tempfile::tempfile_in(directory.path())?;
        let mut command = Command::new("ssh");
        command
            .args(ssh_connection_args_without_control_master(owner)?)
            .args(["-NT", "-o", "ExitOnForwardFailure=yes", "-D"])
            .arg(&socket)
            .arg("--")
            .arg(owner.route.endpoint.connect_target())
            .current_dir(&owner.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(errors.try_clone()?)
            .process_group(0);
        #[cfg(target_os = "linux")]
        {
            let parent = std::process::id();
            // SAFETY: only async-signal-safe syscalls in the pre-exec child.
            unsafe {
                command.pre_exec(move || {
                    if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) != 0
                        || libc::getppid() as u32 != parent
                    {
                        return Err(std::io::Error::last_os_error());
                    }
                    Ok(())
                });
            }
        }
        let child = command.spawn().context("start cache-owner SSH route")?;
        let mut proxy = Self {
            child,
            environment,
            _directory: directory,
        };
        let start = Instant::now();
        loop {
            check()?;
            if let Some(status) = proxy.child.try_wait()? {
                bail!(
                    "cache-owner SSH exited ({status}): {}",
                    ssh_error(&mut errors)
                );
            }
            // A private pathname is not a readiness signal: connect to the listener.
            if UnixStream::connect(&socket).is_ok() {
                return Ok(proxy);
            }
            ensure!(
                start.elapsed() < Duration::from_secs(owner.remote_read_timeout_seconds),
                "timed out opening cache-owner SSH route"
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    pub(super) fn environment(&self) -> impl Iterator<Item = (String, String)> + '_ {
        self.environment.copy_env.iter().cloned()
    }

    pub(super) fn destination_command(&self, command: &str) -> String {
        format!("{} {command}", self.environment.ssh_env)
    }
}

struct ProxyEnvironment {
    copy_env: Vec<(String, String)>,
    ssh_env: String,
}

impl ProxyEnvironment {
    fn for_socket(socket: &Path) -> Result<Self> {
        Self::new(&socket_url(socket)?, |key| std::env::var_os(key))
    }

    fn new(url: &str, original: impl Fn(&str) -> Option<std::ffi::OsString>) -> Result<Self> {
        let mut copy_env = Vec::new();
        // The destination's ProxyCommand (e.g. cloudflared) is a child of Nix,
        // but must see its original network. Never write proxy credentials into a script.
        let mut ssh_env = String::from("env -u http_proxy -u https_proxy -u no_proxy -u NO_PROXY");
        for (key, value) in [
            ("http_proxy", url),
            ("https_proxy", url),
            ("no_proxy", ""),
            ("NO_PROXY", ""),
        ] {
            copy_env.push((key.to_owned(), value.to_owned()));
            if let Some(previous) = original(key) {
                let saved = format!("ABIRD_RELAY_SAVED_{key}");
                ssh_env.push_str(&format!(" {key}=\"${saved}\""));
                copy_env.push((
                    saved,
                    previous
                        .into_string()
                        .map_err(|_| anyhow::anyhow!("non-UTF-8 {key}"))?,
                ));
            }
        }
        Ok(Self { copy_env, ssh_env })
    }
}

fn ssh_error(file: &mut File) -> String {
    let mut text = String::new();
    let _ = file
        .seek(SeekFrom::Start(0))
        .and_then(|_| file.take(4096).read_to_string(&mut text));
    if text.contains("Permission denied") {
        "authentication denied"
    } else if super::transport::output_indicates_host_key_failure(&text) {
        "host key verification failed"
    } else {
        "forwarding unavailable"
    }
    .to_owned()
}

fn socket_url(socket: &Path) -> Result<String> {
    let path = socket
        .to_str()
        .context("non-UTF-8 cache relay socket path")?;
    ensure!(
        socket.is_absolute()
            && path
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"/-_.".contains(&b)),
        "cache relay requires a URL-safe absolute transport directory"
    );
    Ok(format!("socks5h://localhost{path}"))
}

impl Drop for CacheProxy {
    fn drop(&mut self) {
        // A nested ProxyCommand belongs to the same isolated process group.
        if matches!(self.child.try_wait(), Ok(None)) {
            // SAFETY: the unreaped child is the leader of this owned group.
            unsafe {
                libc::kill(-(self.child.id() as i32), libc::SIGKILL);
            }
        }
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ssh_proxy_command_sees_original_environment_without_embedding_credentials() {
        let original = "http://user:p'$word@private/";
        let env = ProxyEnvironment::new("socks5h://localhost/tmp/unused", |k| match k {
            "https_proxy" => Some(original.into()),
            "NO_PROXY" => Some("domain.invalid".into()),
            _ => None,
        })
        .unwrap();
        assert!(!env.ssh_env.contains(original));
        let probe = r#"sh -c 'printf "%s\n" "${http_proxy-unset}" "$https_proxy" "${no_proxy-unset}" "$NO_PROXY"'"#;
        let output = Command::new("sh")
            .arg("-c")
            .arg(format!("{} {probe}", env.ssh_env))
            .envs(env.copy_env)
            .output()
            .unwrap();
        assert!(output.status.success());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            format!("unset\n{original}\nunset\ndomain.invalid\n")
        );
    }
}
