use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, bail};
use tempfile::{Builder, NamedTempFile, TempDir};

use crate::programs::age::Age;

const DEFAULT_AGE_PROGRAM: &str = match option_env!("ABIRD_HOST_MANAGER_DEFAULT_AGE_PROGRAM") {
    Some(path) => path,
    None => "/run/current-system/sw/bin/age",
};
const NIXBOT_PRIMARY_IDENTITY: &str = "/var/lib/nixbot/.ssh/id_ed25519";
const NIXBOT_AGE_IDENTITY: &str = "/var/lib/nixbot/.age/identity";

#[derive(Debug)]
pub struct SshRuntime {
    age: Age,
    decrypt_identities: Vec<PathBuf>,
    state: Mutex<RuntimeState>,
}

#[derive(Debug)]
struct RuntimeState {
    _directory: TempDir,
    identities: BTreeMap<PathBuf, NamedTempFile>,
    known_hosts: BTreeMap<String, NamedTempFile>,
}

impl SshRuntime {
    pub fn from_environment() -> Result<Self> {
        let age_program = env::var_os("ABIRD_HOST_MANAGER_AGE")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(DEFAULT_AGE_PROGRAM));
        Self::new(Age::new(age_program)?, decrypt_identity_candidates()?)
    }

    fn new(age: Age, decrypt_identities: Vec<PathBuf>) -> Result<Self> {
        let directory = Builder::new()
            .prefix("abird-host-manager-ssh-")
            .tempdir()
            .context("create private SSH runtime directory")?;
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
        Ok(Self {
            age,
            decrypt_identities,
            state: Mutex::new(RuntimeState {
                _directory: directory,
                identities: BTreeMap::new(),
                known_hosts: BTreeMap::new(),
            }),
        })
    }

    pub fn resolve_identity(&self, source: &Path) -> Result<PathBuf> {
        if !source.is_absolute() {
            bail!("SSH identity source must be absolute: {}", source.display());
        }
        if source.extension().and_then(|value| value.to_str()) != Some("age") {
            if !source.is_file() {
                bail!("SSH identity does not exist: {}", source.display());
            }
            return Ok(source.to_path_buf());
        }

        let mut state = self.state.lock().expect("SSH runtime lock poisoned");
        if let Some(identity) = state.identities.get(source) {
            return Ok(identity.path().to_path_buf());
        }

        let mut errors = Vec::new();
        for decrypt_identity in &self.decrypt_identities {
            if !decrypt_identity.is_file() {
                continue;
            }
            let output = Builder::new()
                .prefix("identity-")
                .tempfile_in(state._directory.path())?;
            match self.age.decrypt(source, decrypt_identity, output.path()) {
                Ok(()) => {
                    fs::set_permissions(output.path(), fs::Permissions::from_mode(0o600))?;
                    let path = output.path().to_path_buf();
                    state.identities.insert(source.to_path_buf(), output);
                    return Ok(path);
                }
                Err(error) => errors.push(format!("{}: {error:#}", decrypt_identity.display())),
            }
        }
        bail!(
            "cannot decrypt SSH identity {}; {}",
            source.display(),
            if errors.is_empty() {
                "no usable age identities were found".to_owned()
            } else {
                format!("attempts failed: {}", errors.join("; "))
            }
        )
    }

    pub fn materialize_known_hosts(&self, label: &str, contents: &str) -> Result<PathBuf> {
        let mut state = self.state.lock().expect("SSH runtime lock poisoned");
        if let Some(file) = state.known_hosts.get(label) {
            return Ok(file.path().to_path_buf());
        }
        let mut file = Builder::new()
            .prefix("known-hosts-")
            .tempfile_in(state._directory.path())?;
        file.write_all(contents.as_bytes())?;
        file.as_file().sync_all()?;
        fs::set_permissions(file.path(), fs::Permissions::from_mode(0o600))?;
        let path = file.path().to_path_buf();
        state.known_hosts.insert(label.to_owned(), file);
        Ok(path)
    }
}

fn decrypt_identity_candidates() -> Result<Vec<PathBuf>> {
    if let Some(path) = env::var_os("AGE_KEY_FILE") {
        return Ok(vec![absolute_from_current_dir(PathBuf::from(path))?]);
    }
    let mut candidates = Vec::new();
    if let Some(home) = env::var_os("HOME") {
        candidates.push(PathBuf::from(home).join(".ssh/id_ed25519"));
    }
    candidates.extend([
        PathBuf::from(NIXBOT_PRIMARY_IDENTITY),
        PathBuf::from(NIXBOT_AGE_IDENTITY),
    ]);
    candidates.dedup();
    Ok(candidates)
}

fn absolute_from_current_dir(path: PathBuf) -> Result<PathBuf> {
    if path.is_absolute() {
        return Ok(path);
    }
    Ok(env::current_dir()
        .context("resolve current directory for age identity")?
        .join(path))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn plain_identity_is_returned_without_materialization() {
        let temp = tempfile::tempdir().unwrap();
        let identity = temp.path().join("identity");
        fs::write(&identity, "private\n").unwrap();
        let runtime = SshRuntime::new(Age::new("/bin/false").unwrap(), Vec::new()).unwrap();

        assert_eq!(runtime.resolve_identity(&identity).unwrap(), identity);
    }

    #[test]
    fn encrypted_identity_is_materialized_once_with_private_permissions() {
        let temp = tempfile::tempdir().unwrap();
        let age = temp.path().join("age");
        fs::write(&age, "#!/bin/sh\nset -eu\ncp -- \"$6\" \"$5\"\n").unwrap();
        fs::set_permissions(&age, fs::Permissions::from_mode(0o700)).unwrap();
        let decrypt_identity = temp.path().join("decrypt-identity");
        fs::write(&decrypt_identity, "dummy\n").unwrap();
        let source = temp.path().join("nixbot.key.age");
        fs::write(&source, "decrypted-private-key\n").unwrap();
        let runtime = SshRuntime::new(Age::new(age).unwrap(), vec![decrypt_identity]).unwrap();

        let first = runtime.resolve_identity(&source).unwrap();
        let second = runtime.resolve_identity(&source).unwrap();

        assert_eq!(first, second);
        assert_eq!(
            fs::read_to_string(&first).unwrap(),
            "decrypted-private-key\n"
        );
        assert_eq!(
            fs::metadata(first).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
