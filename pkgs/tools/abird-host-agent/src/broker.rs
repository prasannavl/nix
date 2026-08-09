use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::resource::{BrokerTransferPolicy, DataRootPlan};
use crate::sha256::digest_bytes;
use crate::transfer::{RemoteSource, TransferProgress};

const AGENT_START_TIMEOUT: Duration = Duration::from_secs(5);
const OUTPUT_LIMIT: usize = 256 * 1024;
const PROGRESS_FRAME_LIMIT: usize = 64 * 1024;
const PROGRESS_PREFIX: &str = "abird-host-agent-progress ";

pub struct BrokerTransferRequest<'a> {
    pub source: &'a RemoteSource,
    pub target: &'a RemoteSource,
    pub resource: &'a str,
    pub job_id: &'a str,
    pub verify: bool,
    pub destination_root: Option<&'a Path>,
    pub runtime_root: &'a Path,
    pub data_root_plan: &'a [DataRootPlan],
    pub backup_source: bool,
}

pub fn run_broker_transfer(
    policy: &BrokerTransferPolicy,
    request: BrokerTransferRequest<'_>,
) -> Result<Value> {
    run_broker_transfer_with_progress(policy, request, |_| Ok(()))
}

pub fn run_broker_transfer_with_progress(
    policy: &BrokerTransferPolicy,
    request: BrokerTransferRequest<'_>,
    mut progress: impl FnMut(&TransferProgress) -> Result<()>,
) -> Result<Value> {
    let BrokerTransferRequest {
        source,
        target,
        resource,
        job_id,
        verify,
        destination_root,
        runtime_root,
        data_root_plan,
        backup_source,
    } = request;
    validate_endpoint("source", source)?;
    validate_endpoint("target", target)?;
    if source.identity_file.is_some() || target.identity_file.is_some() {
        bail!("broker endpoints cannot contain private identity paths");
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(runtime_root)
        .with_context(|| format!("create broker runtime root {}", runtime_root.display()))?;
    let socket = runtime_root.join(format!(
        "agent-{}-{}.sock",
        digest_bytes(job_id.as_bytes()),
        std::process::id()
    ));
    let mut agent = AgentGuard::start(policy, socket)?;
    agent.add_identity(policy)?;
    let source_host_key = read_authenticated_host_key(policy, &agent, source)?;
    let target_host_key = read_authenticated_host_key(policy, &agent, target)?;
    agent.constrain_identity(
        policy,
        source,
        target,
        &source_host_key,
        &target_host_key,
        runtime_root,
    )?;
    let mut target = target.clone();
    target.host_public_keys = vec![target_host_key];

    let mut source_argv = source.agent_prefix.clone();
    source_argv.push(source.agent_program.to_string_lossy().into_owned());
    source_argv.extend([
        "--json".to_owned(),
        "data".to_owned(),
        "push".to_owned(),
        "--resource".to_owned(),
        resource.to_owned(),
        "--target-endpoint".to_owned(),
        serde_json::to_string(&target)?,
    ]);
    if verify {
        source_argv.push("--verify".to_owned());
    }
    if let Some(destination_root) = destination_root {
        source_argv.extend([
            "--destination-root".to_owned(),
            destination_root.to_string_lossy().into_owned(),
        ]);
    }
    if !data_root_plan.is_empty() {
        source_argv.extend([
            "--data-root-plan".to_owned(),
            serde_json::to_string(data_root_plan)?,
        ]);
    }
    if backup_source {
        source_argv.push("--backup-source".to_owned());
    }

    let mut command = Command::new(&policy.ssh_program);
    command
        .args(&policy.ssh_args)
        .args(["-o", "BatchMode=yes", "-A"])
        .env("SSH_AUTH_SOCK", agent.socket())
        .env_remove("SSH_AGENT_PID");
    append_endpoint_connection(&mut command, source);
    let mut child = command
        .arg(shell_join(&source_argv)?)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("run controller-brokered source agent")?;
    let stdout = child
        .stdout
        .take()
        .context("broker source stdout is not piped")?;
    let stderr = child
        .stderr
        .take()
        .context("broker source stderr is not piped")?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout));
    let (sender, receiver) = mpsc::channel();
    let stderr_reader = thread::spawn(move || read_progress(stderr, sender));
    let status = loop {
        while let Ok(frame) = receiver.try_recv() {
            progress(&frame)?;
        }
        if let Some(status) = child.try_wait()? {
            break status;
        }
        thread::sleep(Duration::from_millis(20));
    };
    while let Ok(frame) = receiver.try_recv() {
        progress(&frame)?;
    }
    let stdout = stdout_reader
        .join()
        .map_err(|_| anyhow::anyhow!("broker stdout reader panicked"))??;
    let stderr = stderr_reader
        .join()
        .map_err(|_| anyhow::anyhow!("broker stderr reader panicked"))??;
    if !status.success() {
        bail!(
            "controller-brokered direct transfer failed with {}: {}",
            status,
            stderr.trim()
        );
    }
    serde_json::from_slice(&stdout).context("parse direct source-agent response")
}

fn read_bounded(mut reader: impl Read) -> std::io::Result<Vec<u8>> {
    let mut retained = Vec::with_capacity(OUTPUT_LIMIT);
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let count = reader.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        let available = OUTPUT_LIMIT.saturating_sub(retained.len());
        retained.extend_from_slice(&buffer[..count.min(available)]);
    }
    Ok(retained)
}

fn read_progress(
    reader: impl Read,
    sender: mpsc::Sender<TransferProgress>,
) -> std::io::Result<String> {
    let mut diagnostics = Vec::with_capacity(OUTPUT_LIMIT);
    let mut reader = BufReader::new(reader);
    let mut line = Vec::new();
    loop {
        line.clear();
        if reader
            .by_ref()
            .take(PROGRESS_FRAME_LIMIT as u64)
            .read_until(b'\n', &mut line)?
            == 0
        {
            break;
        }
        let parsed = std::str::from_utf8(&line)
            .ok()
            .and_then(|line| line.trim_end().strip_prefix(PROGRESS_PREFIX))
            .and_then(|json| serde_json::from_str::<TransferProgress>(json).ok());
        if let Some(progress) = parsed {
            if sender.send(progress).is_err() {
                break;
            }
        } else {
            let available = OUTPUT_LIMIT.saturating_sub(diagnostics.len());
            diagnostics.extend_from_slice(&line[..line.len().min(available)]);
        }
    }
    Ok(String::from_utf8_lossy(&diagnostics).into_owned())
}

fn read_authenticated_host_key(
    policy: &BrokerTransferPolicy,
    agent: &AgentGuard,
    endpoint: &RemoteSource,
) -> Result<String> {
    let mut argv = endpoint.agent_prefix.clone();
    argv.retain(|argument| argument != "--preserve-env=SSH_AUTH_SOCK");
    argv.extend([
        endpoint.agent_program.to_string_lossy().into_owned(),
        "--json".to_owned(),
        "data".to_owned(),
        "ssh-host-key".to_owned(),
    ]);
    let mut command = Command::new(&policy.ssh_program);
    command
        .args(&policy.ssh_args)
        .args(["-o", "BatchMode=yes"])
        .env("SSH_AUTH_SOCK", agent.socket())
        .env_remove("SSH_AGENT_PID");
    append_endpoint_connection(&mut command, endpoint);
    let output = command
        .arg(shell_join(&argv)?)
        .output()
        .context("read public SSH host key over authenticated controller channel")?;
    if !output.status.success() {
        bail!(
            "read public SSH host key failed with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    let value: Value = serde_json::from_slice(&output.stdout)
        .context("parse public SSH host-key agent response")?;
    let public_key = value
        .pointer("/result/public_key")
        .and_then(Value::as_str)
        .context("public SSH host-key response has no public_key")?;
    if public_key.contains(['\0', '\r', '\n']) || !public_key.starts_with("ssh-") {
        bail!("host returned an invalid public SSH host key");
    }
    Ok(public_key.to_owned())
}

fn validate_endpoint(label: &str, endpoint: &RemoteSource) -> Result<()> {
    if endpoint.host.trim().is_empty()
        || endpoint.host.starts_with('-')
        || endpoint.host.contains(['\0', '\r', '\n'])
    {
        bail!("broker {label} endpoint has an invalid host");
    }
    if endpoint.user.as_ref().is_some_and(|user| {
        user.is_empty()
            || !user
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    }) {
        bail!("broker {label} endpoint has an invalid user");
    }
    if endpoint.port == Some(0) {
        bail!("broker {label} endpoint port cannot be zero");
    }
    for (name, path) in [
        ("SSH", &endpoint.ssh_program),
        ("agent", &endpoint.agent_program),
        ("rsync", &endpoint.rsync_program),
        ("tar", &endpoint.tar_program),
    ] {
        if !path.is_absolute() {
            bail!("broker {label} {name} path must be absolute");
        }
    }
    if endpoint
        .ssh_args
        .iter()
        .chain(&endpoint.agent_prefix)
        .chain(&endpoint.rsync_prefix)
        .any(|argument| argument.contains('\0'))
    {
        bail!("broker {label} endpoint argv cannot contain NUL");
    }
    Ok(())
}

fn append_endpoint_connection(command: &mut Command, endpoint: &RemoteSource) {
    if let Some(port) = endpoint.port {
        command.arg("-p").arg(port.to_string());
    }
    command.args(&endpoint.ssh_args).arg("--");
    command.arg(match &endpoint.user {
        Some(user) => format!("{user}@{}", endpoint.host),
        None => endpoint.host.clone(),
    });
}

struct AgentGuard {
    child: Child,
    socket: PathBuf,
}

impl AgentGuard {
    fn start(policy: &BrokerTransferPolicy, socket: PathBuf) -> Result<Self> {
        if socket.exists() {
            fs::remove_file(&socket)
                .with_context(|| format!("remove stale broker socket {}", socket.display()))?;
        }
        let parent_pid = std::process::id() as libc::pid_t;
        let mut command = Command::new(&policy.ssh_agent_program);
        command.args(["-D", "-a"]).arg(&socket);
        // SAFETY: prctl, getppid, and kill are async-signal-safe syscalls. No
        // allocation or lock-taking occurs between fork and exec.
        unsafe {
            command.pre_exec(move || {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() != parent_pid {
                    libc::kill(libc::getpid(), libc::SIGTERM);
                }
                Ok(())
            });
        }
        let child = command
            .spawn()
            .with_context(|| format!("start {}", policy.ssh_agent_program.display()))?;
        let guard = Self { child, socket };
        let deadline = Instant::now() + AGENT_START_TIMEOUT;
        while !guard.socket.exists() {
            if Instant::now() >= deadline {
                bail!("timed out waiting for broker ssh-agent socket");
            }
            thread::sleep(Duration::from_millis(20));
        }
        Ok(guard)
    }

    fn add_identity(&mut self, policy: &BrokerTransferPolicy) -> Result<()> {
        let output = Command::new(&policy.ssh_add_program)
            .arg(&policy.identity_file)
            .env("SSH_AUTH_SOCK", &self.socket)
            .env_remove("SSH_AGENT_PID")
            .output()
            .with_context(|| format!("run {}", policy.ssh_add_program.display()))?;
        if !output.status.success() {
            bail!(
                "load controller transfer identity into ephemeral agent failed with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn constrain_identity(
        &mut self,
        policy: &BrokerTransferPolicy,
        source: &RemoteSource,
        target: &RemoteSource,
        source_key: &str,
        target_key: &str,
        runtime_root: &Path,
    ) -> Result<()> {
        let known_hosts = runtime_root.join(format!(
            "constraints-{}-{}.known-hosts",
            digest_bytes(format!("{}\0{}", source.host, target.host).as_bytes()),
            std::process::id()
        ));
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&known_hosts)
            .with_context(|| format!("create {}", known_hosts.display()))?;
        writeln!(file, "{} {source_key}", known_host_name(source))?;
        writeln!(file, "{} {target_key}", known_host_name(target))?;
        file.sync_all()?;

        let clear = Command::new(&policy.ssh_add_program)
            .arg("-D")
            .env("SSH_AUTH_SOCK", &self.socket)
            .env_remove("SSH_AGENT_PID")
            .output()
            .with_context(|| format!("clear {}", policy.ssh_add_program.display()))?;
        if !clear.status.success() {
            bail!(
                "clear ephemeral SSH agent before constraining identity failed with {}: {}",
                clear.status,
                String::from_utf8_lossy(&clear.stderr).trim()
            );
        }
        let source_constraint = destination_name(source);
        let forwarded_constraint = format!("{}>{}", source.host, destination_name(target));
        let constrained = Command::new(&policy.ssh_add_program)
            .args(["-H", known_hosts.to_string_lossy().as_ref()])
            .args(["-h", &source_constraint])
            .args(["-h", &forwarded_constraint])
            .arg(&policy.identity_file)
            .env("SSH_AUTH_SOCK", &self.socket)
            .env_remove("SSH_AGENT_PID")
            .output()
            .with_context(|| format!("constrain {}", policy.ssh_add_program.display()))?;
        let _ = fs::remove_file(&known_hosts);
        if !constrained.status.success() {
            bail!(
                "load destination-constrained controller identity failed with {}: {}",
                constrained.status,
                String::from_utf8_lossy(&constrained.stderr).trim()
            );
        }
        Ok(())
    }

    fn socket(&self) -> &Path {
        &self.socket
    }
}

fn destination_name(endpoint: &RemoteSource) -> String {
    match &endpoint.user {
        Some(user) => format!("{user}@{}", endpoint.host),
        None => endpoint.host.clone(),
    }
}

fn known_host_name(endpoint: &RemoteSource) -> String {
    if endpoint.port.is_some_and(|port| port != 22) {
        format!(
            "[{}]:{}",
            endpoint.host,
            endpoint.port.expect("checked port")
        )
    } else {
        endpoint.host.clone()
    }
}

impl Drop for AgentGuard {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_file(&self.socket);
    }
}

fn shell_join(argv: &[String]) -> Result<String> {
    if argv.iter().any(|argument| argument.contains('\0')) {
        bail!("remote argv cannot contain NUL");
    }
    Ok(argv
        .iter()
        .map(|argument| format!("'{}'", argument.replace('\'', "'\\''")))
        .collect::<Vec<_>>()
        .join(" "))
}

#[cfg(test)]
mod progress_tests {
    use std::io::Cursor;

    use super::*;

    #[test]
    fn progress_frames_are_separated_from_bounded_diagnostics() {
        let progress = TransferProgress {
            stage: "copying".to_owned(),
            engine: None,
            entries_completed: 2,
            bytes_completed: 3,
            total_entries: 4,
            total_bytes: 5,
            detail: "live".to_owned(),
        };
        let input = format!(
            "noise\n{PROGRESS_PREFIX}{}\n{PROGRESS_PREFIX}not-json\n{}",
            serde_json::to_string(&progress).unwrap(),
            "x".repeat(OUTPUT_LIMIT + 10)
        );
        let (sender, receiver) = mpsc::channel();
        let diagnostics = read_progress(Cursor::new(input), sender).unwrap();
        let received = receiver.recv().unwrap();
        assert_eq!(received.entries_completed, 2);
        assert!(diagnostics.starts_with("noise\n"));
        assert!(diagnostics.len() <= OUTPUT_LIMIT);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shell_join_quotes_every_argument() {
        assert_eq!(
            shell_join(&["a b".to_owned(), "c'd".to_owned()]).unwrap(),
            "'a b' 'c'\\''d'"
        );
    }
}
