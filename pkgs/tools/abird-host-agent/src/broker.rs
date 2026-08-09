use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStrExt;
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
const UNIX_SOCKET_PATH_MAX: usize = 107;
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
    let socket = broker_agent_socket(runtime_root, job_id, std::process::id())?;
    let mut agent = AgentGuard::start(policy, socket)?;
    agent.add_identity(policy)?;
    let source_host_key =
        read_authenticated_host_key(policy, &agent, source, runtime_root, "source")?;
    let target_host_key =
        read_authenticated_host_key(policy, &agent, target, runtime_root, "target")?;
    agent.constrain_identity(
        policy,
        source,
        target,
        &source_host_key,
        &target_host_key,
        runtime_root,
    )?;
    let known_hosts = TransferKnownHosts::create(
        runtime_root,
        job_id,
        source,
        target,
        &source_host_key,
        &target_host_key,
    )?;
    let mut source = source.clone();
    pin_endpoint(&mut source, known_hosts.path());
    source.host_public_keys = vec![source_host_key];
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
    append_pinned_host_key_options(&mut command, known_hosts.path());
    command
        .args(&policy.ssh_args)
        .args(["-o", "BatchMode=yes", "-A"])
        .env("SSH_AUTH_SOCK", agent.socket())
        .env_remove("SSH_AGENT_PID");
    append_endpoint_connection(&mut command, &source);
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
    runtime_root: &Path,
    label: &str,
) -> Result<String> {
    let known_hosts = DiscoveryKnownHosts::create(runtime_root, endpoint, label)?;
    let mut endpoint = endpoint.clone();
    pin_endpoint(&mut endpoint, known_hosts.path());
    let mut argv = endpoint.agent_prefix.clone();
    argv.retain(|argument| argument != "--preserve-env=SSH_AUTH_SOCK");
    argv.extend([
        endpoint.agent_program.to_string_lossy().into_owned(),
        "--json".to_owned(),
        "data".to_owned(),
        "ssh-host-key".to_owned(),
    ]);
    let mut command = Command::new(&policy.ssh_program);
    append_pinned_host_key_options(&mut command, known_hosts.path());
    command
        .args(&policy.ssh_args)
        .args(["-o", "BatchMode=yes"])
        .env("SSH_AUTH_SOCK", agent.socket())
        .env_remove("SSH_AGENT_PID");
    append_endpoint_connection(&mut command, &endpoint);
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
    if !known_hosts.contains(public_key)? {
        bail!("host-agent SSH host key does not match the key used by the SSH transport");
    }
    if !endpoint.host_public_keys.is_empty()
        && !endpoint
            .host_public_keys
            .iter()
            .any(|expected| expected == public_key)
    {
        bail!("host-agent SSH host key does not match the manager-pinned key");
    }
    Ok(public_key.to_owned())
}

fn pin_endpoint(endpoint: &mut RemoteSource, known_hosts: &Path) {
    let mut pinned = pinned_host_key_options(known_hosts);
    pinned.append(&mut endpoint.ssh_args);
    endpoint.ssh_args = pinned;
}

fn append_pinned_host_key_options(command: &mut Command, known_hosts: &Path) {
    command.args(pinned_host_key_options(known_hosts));
}

fn pinned_host_key_options(known_hosts: &Path) -> Vec<String> {
    vec![
        "-o".to_owned(),
        "GlobalKnownHostsFile=/dev/null".to_owned(),
        "-o".to_owned(),
        format!("UserKnownHostsFile={}", known_hosts.display()),
        "-o".to_owned(),
        "StrictHostKeyChecking=yes".to_owned(),
        "-o".to_owned(),
        "HashKnownHosts=no".to_owned(),
    ]
}

struct DiscoveryKnownHosts {
    path: PathBuf,
}

impl DiscoveryKnownHosts {
    fn create(runtime_root: &Path, endpoint: &RemoteSource, label: &str) -> Result<Self> {
        if endpoint.host_public_keys.is_empty() {
            bail!("broker {label} endpoint has no manager-authenticated SSH host-key pin");
        }
        let path = runtime_root.join(format!(
            "discover-{label}-{}-{}.known-hosts",
            &digest_bytes(
                format!(
                    "{}\0{:?}\0{:?}",
                    endpoint.host, endpoint.port, endpoint.user
                )
                .as_bytes()
            )[..24],
            std::process::id()
        ));
        write_known_hosts(
            &path,
            [(
                endpoint,
                endpoint
                    .host_public_keys
                    .iter()
                    .map(String::as_str)
                    .collect(),
            )],
        )?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }

    fn contains(&self, public_key: &str) -> Result<bool> {
        let contents = fs::read_to_string(&self.path)
            .with_context(|| format!("read {}", self.path.display()))?;
        Ok(contents.lines().any(|line| {
            let mut fields = line.split_whitespace();
            let _host = fields.next();
            let Some(kind) = fields.next() else {
                return false;
            };
            let Some(key) = fields.next() else {
                return false;
            };
            format!("{kind} {key}") == public_key
        }))
    }
}

impl Drop for DiscoveryKnownHosts {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

struct TransferKnownHosts {
    path: PathBuf,
}

impl TransferKnownHosts {
    fn create(
        runtime_root: &Path,
        job_id: &str,
        source: &RemoteSource,
        target: &RemoteSource,
        source_key: &str,
        target_key: &str,
    ) -> Result<Self> {
        let path = runtime_root.join(format!(
            "peers-{}-{}.known-hosts",
            &digest_bytes(job_id.as_bytes())[..24],
            std::process::id()
        ));
        write_known_hosts(
            &path,
            [(source, vec![source_key]), (target, vec![target_key])],
        )?;
        Ok(Self { path })
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TransferKnownHosts {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn write_known_hosts<'a>(
    path: &Path,
    endpoints: impl IntoIterator<Item = (&'a RemoteSource, Vec<&'a str>)>,
) -> Result<()> {
    let mut file = fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .with_context(|| format!("create {}", path.display()))?;
    for (endpoint, keys) in endpoints {
        for key in keys {
            validate_public_host_key(key)?;
            writeln!(file, "{} {key}", known_host_name(endpoint))?;
        }
    }
    file.sync_all()?;
    Ok(())
}

fn validate_public_host_key(public_key: &str) -> Result<()> {
    let fields = public_key.split_whitespace().collect::<Vec<_>>();
    if fields.len() != 2
        || !fields[0].starts_with("ssh-")
        || public_key.contains(['\0', '\r', '\n'])
    {
        bail!("broker endpoint has an invalid public SSH host key");
    }
    Ok(())
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
        command.stdout(Stdio::null()).stderr(Stdio::piped());
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
        let mut guard = Self { child, socket };
        let deadline = Instant::now() + AGENT_START_TIMEOUT;
        while !guard.socket.exists() {
            if let Some(status) = guard
                .child
                .try_wait()
                .context("inspect broker ssh-agent startup")?
            {
                let mut stderr = String::new();
                if let Some(mut child_stderr) = guard.child.stderr.take() {
                    child_stderr
                        .read_to_string(&mut stderr)
                        .context("read broker ssh-agent startup diagnostics")?;
                }
                bail!(
                    "broker ssh-agent exited during startup with {status}: {}",
                    stderr.trim()
                );
            }
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

fn broker_agent_socket(runtime_root: &Path, job_id: &str, process_id: u32) -> Result<PathBuf> {
    let digest = digest_bytes(job_id.as_bytes());
    let socket = runtime_root.join(format!("agent-{}-{process_id}.sock", &digest[..24]));
    let length = socket.as_os_str().as_bytes().len();
    if length > UNIX_SOCKET_PATH_MAX {
        bail!(
            "broker ssh-agent socket path is {length} bytes; maximum is {UNIX_SOCKET_PATH_MAX}: {}",
            socket.display()
        );
    }
    Ok(socket)
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
    fn broker_socket_fits_the_linux_unix_socket_limit() {
        let socket = broker_agent_socket(
            Path::new("/run/abird-host-agent/broker"),
            "zulip-tearoff-20260804--item-001-seed-seed",
            4_294_967_295,
        )
        .unwrap();
        assert!(socket.as_os_str().as_bytes().len() <= UNIX_SOCKET_PATH_MAX);
    }

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

    fn endpoint(host: &str, key: Option<&str>) -> RemoteSource {
        RemoteSource {
            host: host.to_owned(),
            host_public_keys: key.into_iter().map(str::to_owned).collect(),
            user: Some("nixbot".to_owned()),
            port: None,
            identity_file: None,
            ssh_program: PathBuf::from("/bin/ssh"),
            ssh_args: Vec::new(),
            agent_program: PathBuf::from("/bin/agent"),
            agent_prefix: Vec::new(),
            rsync_program: PathBuf::from("/bin/rsync"),
            rsync_prefix: Vec::new(),
            tar_program: PathBuf::from("/bin/tar"),
        }
    }

    #[test]
    fn shell_join_quotes_every_argument() {
        assert_eq!(
            shell_join(&["a b".to_owned(), "c'd".to_owned()]).unwrap(),
            "'a b' 'c'\\''d'"
        );
    }

    #[test]
    fn transfer_known_hosts_pins_both_peers_in_a_private_file() {
        let temp = tempfile::tempdir().unwrap();
        let source = endpoint("10.0.0.2", None);
        let target = endpoint("10.0.0.3", None);
        let known_hosts = TransferKnownHosts::create(
            temp.path(),
            "move-seed",
            &source,
            &target,
            "ssh-ed25519 source-key",
            "ssh-ed25519 target-key",
        )
        .unwrap();
        let contents = fs::read_to_string(known_hosts.path()).unwrap();
        assert!(contents.contains("10.0.0.2 ssh-ed25519 source-key"));
        assert!(contents.contains("10.0.0.3 ssh-ed25519 target-key"));

        let mut pinned = source;
        pin_endpoint(&mut pinned, known_hosts.path());
        assert_eq!(
            &pinned.ssh_args[..8],
            pinned_host_key_options(known_hosts.path())
        );
    }

    #[test]
    fn discovery_uses_supplied_manager_pin_when_available() {
        let temp = tempfile::tempdir().unwrap();
        let endpoint = endpoint("10.0.0.2", Some("ssh-ed25519 manager-key"));
        let known_hosts = DiscoveryKnownHosts::create(temp.path(), &endpoint, "source").unwrap();
        assert!(known_hosts.contains("ssh-ed25519 manager-key").unwrap());
        assert!(!known_hosts.contains("ssh-ed25519 other-key").unwrap());
    }

    #[test]
    fn discovery_fails_closed_without_a_manager_pin() {
        let temp = tempfile::tempdir().unwrap();
        let endpoint = endpoint("10.0.0.2", None);
        let error = match DiscoveryKnownHosts::create(temp.path(), &endpoint, "source") {
            Ok(_) => panic!("empty endpoint pin unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.to_string().contains("no manager-authenticated"));
    }
}
