use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::path::PathBuf;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PathRequirement {
    #[default]
    Exists,
    File,
    Directory,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum ReadinessCheck {
    Path {
        path: PathBuf,
        #[serde(default)]
        requirement: PathRequirement,
    },
    Tcp {
        address: String,
        #[serde(default = "default_timeout_ms")]
        timeout_ms: u64,
    },
    Http {
        address: String,
        host: String,
        #[serde(default = "default_http_path")]
        path: String,
        #[serde(default = "default_expected_statuses")]
        expected_statuses: Vec<u16>,
        #[serde(default = "default_timeout_ms")]
        timeout_ms: u64,
    },
}

#[derive(Clone, Debug, Serialize)]
pub struct ReadinessResult {
    pub check: ReadinessCheck,
    pub success: bool,
    pub detail: String,
}

pub fn validate_check(check: &ReadinessCheck) -> Result<()> {
    match check {
        ReadinessCheck::Path { path, .. } => {
            if !path.is_absolute() {
                bail!("readiness path must be absolute: {}", path.display());
            }
        }
        ReadinessCheck::Tcp {
            address,
            timeout_ms,
        } => {
            validate_network_check(address, *timeout_ms)?;
        }
        ReadinessCheck::Http {
            address,
            host,
            path,
            expected_statuses,
            timeout_ms,
        } => {
            validate_network_check(address, *timeout_ms)?;
            if host.trim().is_empty() || host.contains(['\r', '\n']) {
                bail!("HTTP readiness host must be non-empty and cannot contain newlines");
            }
            if !path.starts_with('/') || path.contains(['\r', '\n']) {
                bail!("HTTP readiness path must start with / and cannot contain newlines");
            }
            if expected_statuses.is_empty()
                || expected_statuses
                    .iter()
                    .any(|status| !(100..=599).contains(status))
            {
                bail!("HTTP readiness expected statuses must contain valid HTTP status codes");
            }
        }
    }
    Ok(())
}

pub fn run_checks(checks: &[ReadinessCheck]) -> Vec<ReadinessResult> {
    checks
        .iter()
        .cloned()
        .map(|check| match run_check(&check) {
            Ok(detail) => ReadinessResult {
                check,
                success: true,
                detail,
            },
            Err(error) => ReadinessResult {
                check,
                success: false,
                detail: format!("{error:#}"),
            },
        })
        .collect()
}

fn validate_network_check(address: &str, timeout_ms: u64) -> Result<()> {
    if address.trim().is_empty() || address.contains('\0') {
        bail!("readiness address must be non-empty and cannot contain NUL");
    }
    if timeout_ms == 0 || timeout_ms > 300_000 {
        bail!("readiness timeout must be between 1 and 300000 milliseconds");
    }
    Ok(())
}

fn run_check(check: &ReadinessCheck) -> Result<String> {
    match check {
        ReadinessCheck::Path { path, requirement } => {
            let metadata =
                fs::metadata(path).with_context(|| format!("inspect {}", path.display()))?;
            let valid = match requirement {
                PathRequirement::Exists => true,
                PathRequirement::File => metadata.is_file(),
                PathRequirement::Directory => metadata.is_dir(),
            };
            if !valid {
                bail!(
                    "{} does not satisfy requirement {:?}",
                    path.display(),
                    requirement
                );
            }
            Ok(format!("{} satisfies {:?}", path.display(), requirement))
        }
        ReadinessCheck::Tcp {
            address,
            timeout_ms,
        } => {
            let peer = connect(address, *timeout_ms)?;
            Ok(format!("connected to {peer}"))
        }
        ReadinessCheck::Http {
            address,
            host,
            path,
            expected_statuses,
            timeout_ms,
        } => {
            let (mut stream, peer) = connect_stream(address, *timeout_ms)?;
            let timeout = Duration::from_millis(*timeout_ms);
            stream
                .set_read_timeout(Some(timeout))
                .context("set HTTP readiness read timeout")?;
            stream
                .set_write_timeout(Some(timeout))
                .context("set HTTP readiness write timeout")?;
            let request = format!(
                "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nUser-Agent: abird-host-agent\r\n\r\n"
            );
            stream
                .write_all(request.as_bytes())
                .context("write HTTP readiness request")?;
            stream.flush().context("flush HTTP readiness request")?;

            let mut response = BufReader::new(stream).take(4096);
            let mut status_line = String::new();
            let length = response
                .read_line(&mut status_line)
                .context("read HTTP readiness status line")?;
            if length == 0 {
                bail!("HTTP readiness response is empty");
            }
            if !status_line.ends_with('\n') {
                bail!("HTTP readiness status line is incomplete or exceeds 4096 bytes");
            }
            let status = status_line
                .split_whitespace()
                .nth(1)
                .and_then(|status| status.parse::<u16>().ok())
                .context("HTTP readiness response has no valid status line")?;
            if !expected_statuses.contains(&status) {
                bail!(
                    "HTTP readiness at {peer} returned {status}, expected one of {expected_statuses:?}"
                );
            }
            Ok(format!("HTTP readiness at {peer} returned {status}"))
        }
    }
}

fn connect(address: &str, timeout_ms: u64) -> Result<SocketAddr> {
    connect_stream(address, timeout_ms).map(|(_, peer)| peer)
}

fn connect_stream(address: &str, timeout_ms: u64) -> Result<(TcpStream, SocketAddr)> {
    let addresses = address
        .to_socket_addrs()
        .with_context(|| format!("resolve readiness address {address:?}"))?
        .collect::<Vec<_>>();
    if addresses.is_empty() {
        bail!("readiness address {address:?} did not resolve");
    }
    let timeout = Duration::from_millis(timeout_ms);
    let mut errors = Vec::new();
    for peer in addresses {
        match TcpStream::connect_timeout(&peer, timeout) {
            Ok(stream) => return Ok((stream, peer)),
            Err(error) => errors.push(format!("{peer}: {error}")),
        }
    }
    bail!(
        "connect to readiness address {address:?}: {}",
        errors.join("; ")
    )
}

fn default_timeout_ms() -> u64 {
    5_000
}

fn default_http_path() -> String {
    "/".to_owned()
}

fn default_expected_statuses() -> Vec<u16> {
    vec![200]
}

#[cfg(test)]
mod tests {
    use std::net::TcpListener;
    use std::thread;

    use super::*;

    #[test]
    fn path_checks_report_success_and_failure_without_short_circuiting() {
        let temp = tempfile::tempdir().unwrap();
        let checks = vec![
            ReadinessCheck::Path {
                path: temp.path().to_owned(),
                requirement: PathRequirement::Directory,
            },
            ReadinessCheck::Path {
                path: temp.path().join("missing"),
                requirement: PathRequirement::Exists,
            },
        ];
        let results = run_checks(&checks);
        assert!(results[0].success);
        assert!(!results[1].success);
    }

    #[test]
    fn http_check_validates_the_status_code() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut chunk = [0_u8; 256];
                let length = stream.read(&mut chunk).unwrap();
                assert_ne!(length, 0, "HTTP request ended before its headers");
                request.extend_from_slice(&chunk[..length]);
                assert!(request.len() <= 16 * 1024, "HTTP request is too large");
            }
            assert!(request.starts_with(b"GET /health HTTP/1.1\r\n"));
            stream
                .write_all(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
                .unwrap();
            stream.flush().unwrap();
        });
        let results = run_checks(&[ReadinessCheck::Http {
            address: address.to_string(),
            host: "zulip.internal".to_owned(),
            path: "/health".to_owned(),
            expected_statuses: vec![204],
            timeout_ms: 1_000,
        }]);
        server.join().unwrap();
        assert!(results[0].success, "{}", results[0].detail);
    }
}
