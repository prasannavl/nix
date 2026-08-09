use std::collections::BTreeSet;
use std::ffi::{OsStr, OsString};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;

use anyhow::{Context, Result, bail};
use serde::Serialize;

const CAPTURE_LIMIT: usize = 256 * 1024;

#[derive(Clone, Debug)]
pub struct CommandSpec {
    program: PathBuf,
    arguments: Vec<OsString>,
    redacted_arguments: BTreeSet<usize>,
    environment: Vec<(OsString, OsString)>,
    redacted_environment: BTreeSet<usize>,
    current_dir: Option<PathBuf>,
}

#[derive(Debug, Serialize)]
pub struct CommandResult {
    pub program: PathBuf,
    pub arguments: Vec<String>,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub stdout_truncated_bytes: u64,
    pub stderr_truncated_bytes: u64,
}

impl CommandSpec {
    pub fn new(program: impl Into<PathBuf>) -> Self {
        Self {
            program: program.into(),
            arguments: Vec::new(),
            redacted_arguments: BTreeSet::new(),
            environment: Vec::new(),
            redacted_environment: BTreeSet::new(),
            current_dir: None,
        }
    }

    pub fn arg(mut self, argument: impl AsRef<OsStr>) -> Self {
        self.arguments.push(argument.as_ref().to_os_string());
        self
    }

    pub fn secret_arg(mut self, argument: impl AsRef<OsStr>) -> Self {
        self.redacted_arguments.insert(self.arguments.len());
        self.arguments.push(argument.as_ref().to_os_string());
        self
    }

    pub fn env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Self {
        self.environment
            .push((key.as_ref().to_os_string(), value.as_ref().to_os_string()));
        self
    }

    pub fn secret_env(mut self, key: impl AsRef<OsStr>, value: impl AsRef<OsStr>) -> Self {
        self.redacted_environment.insert(self.environment.len());
        self.environment
            .push((key.as_ref().to_os_string(), value.as_ref().to_os_string()));
        self
    }

    pub fn current_dir(mut self, path: impl Into<PathBuf>) -> Self {
        self.current_dir = Some(path.into());
        self
    }

    pub fn args(mut self, arguments: impl IntoIterator<Item = impl AsRef<OsStr>>) -> Self {
        self.arguments.extend(
            arguments
                .into_iter()
                .map(|argument| argument.as_ref().to_os_string()),
        );
        self
    }

    pub fn program(&self) -> &Path {
        &self.program
    }

    pub fn rendered_arguments(&self) -> Vec<String> {
        self.arguments
            .iter()
            .enumerate()
            .map(|(index, argument)| {
                if self.redacted_arguments.contains(&index) {
                    "<redacted>".to_owned()
                } else {
                    argument.to_string_lossy().into_owned()
                }
            })
            .collect()
    }

    pub fn rendered_environment(&self) -> Vec<(String, String)> {
        self.environment
            .iter()
            .enumerate()
            .map(|(index, (key, value))| {
                (
                    key.to_string_lossy().into_owned(),
                    if self.redacted_environment.contains(&index) {
                        "<redacted>".to_owned()
                    } else {
                        value.to_string_lossy().into_owned()
                    },
                )
            })
            .collect()
    }

    fn configure(&self, command: &mut Command) {
        command.args(&self.arguments).envs(
            self.environment
                .iter()
                .map(|(key, value)| (key.as_os_str(), value.as_os_str())),
        );
        if let Some(current_dir) = &self.current_dir {
            command.current_dir(current_dir);
        }
    }

    pub fn output(&self) -> Result<CommandResult> {
        if !self.program.is_absolute() {
            bail!(
                "external program must be an absolute path: {}",
                self.program.display()
            );
        }
        let mut command = Command::new(&self.program);
        self.configure(&mut command);
        let mut child = command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .with_context(|| format!("spawn {}", self.program.display()))?;
        let stdout = child
            .stdout
            .take()
            .context("command stdout pipe is unavailable")?;
        let stderr = child
            .stderr
            .take()
            .context("command stderr pipe is unavailable")?;
        let stdout_reader = thread::spawn(move || read_bounded(stdout));
        let stderr_reader = thread::spawn(move || read_bounded(stderr));
        let status = child.wait()?;
        let stdout = stdout_reader
            .join()
            .map_err(|_| anyhow::anyhow!("command stdout reader panicked"))??;
        let stderr = stderr_reader
            .join()
            .map_err(|_| anyhow::anyhow!("command stderr reader panicked"))??;
        Ok(CommandResult {
            program: self.program.clone(),
            arguments: self.rendered_arguments(),
            success: status.success(),
            exit_code: status.code(),
            stdout: stdout.text(),
            stderr: stderr.text(),
            stdout_truncated_bytes: stdout.truncated_bytes,
            stderr_truncated_bytes: stderr.truncated_bytes,
        })
    }

    pub fn status_inherited(&self) -> Result<()> {
        if !self.program.is_absolute() {
            bail!(
                "external program must be an absolute path: {}",
                self.program.display()
            );
        }
        let mut command = Command::new(&self.program);
        self.configure(&mut command);
        command
            .stdin(Stdio::inherit())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        let status = command
            .status()
            .with_context(|| format!("run {}", self.program.display()))?;
        if !status.success() {
            bail!(
                "{} {:?} failed with {status}",
                self.program.display(),
                self.rendered_arguments()
            );
        }
        Ok(())
    }
}

#[macro_export]
macro_rules! cmd {
    ($program:expr $(, $argument:expr)* $(,)?) => {{
        let command = $crate::command::CommandSpec::new($program);
        $(let command = command.arg($argument);)*
        command
    }};
}

struct BoundedCapture {
    bytes: Vec<u8>,
    truncated_bytes: u64,
}

impl BoundedCapture {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }
}

fn read_bounded(mut reader: impl Read) -> io::Result<BoundedCapture> {
    let mut capture = BoundedCapture {
        bytes: Vec::with_capacity(CAPTURE_LIMIT),
        truncated_bytes: 0,
    };
    let mut buffer = [0_u8; 16 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        let remaining = CAPTURE_LIMIT.saturating_sub(capture.bytes.len());
        let retained = remaining.min(read);
        capture.bytes.extend_from_slice(&buffer[..retained]);
        capture.truncated_bytes += (read - retained) as u64;
    }
    Ok(capture)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_builder_keeps_argv_structured_and_redacts_secrets() {
        let command = CommandSpec::new("/bin/echo")
            .arg("--token")
            .secret_arg("secret value")
            .arg("plain value")
            .env("PLAIN", "plain")
            .secret_env("TOKEN", "secret");
        assert_eq!(
            command.rendered_arguments(),
            ["--token", "<redacted>", "plain value"]
        );
        assert_eq!(
            command.rendered_environment(),
            [
                ("PLAIN".to_owned(), "plain".to_owned()),
                ("TOKEN".to_owned(), "<redacted>".to_owned()),
            ]
        );
    }

    #[test]
    fn bounded_output_drains_both_streams() {
        let output = CommandSpec::new("/bin/sh")
            .args([
                "-c",
                "head -c 1100000 /dev/zero; head -c 1100000 /dev/zero >&2",
            ])
            .output()
            .unwrap();
        assert!(output.success);
        assert!(output.stdout_truncated_bytes > 0);
        assert!(output.stderr_truncated_bytes > 0);
    }
}
