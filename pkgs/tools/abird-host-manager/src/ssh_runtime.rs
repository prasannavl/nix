use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use anyhow::{Context, Result, anyhow, bail};
use tempfile::{Builder, NamedTempFile, TempDir};

use crate::programs::age::Age;

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
        Self::new(Age::new(), decrypt_identity_candidates()?)
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

        let output = Builder::new()
            .prefix("identity-")
            .tempfile_in(state._directory.path())?;
        self.age
            .decrypt(source, &self.decrypt_identities, output.path())
            .map_err(|error| {
                anyhow!(
                    "cannot decrypt SSH identity {}; {error:#}",
                    source.display()
                )
            })?;
        fs::set_permissions(output.path(), fs::Permissions::from_mode(0o600))?;
        let path = output.path().to_path_buf();
        state.identities.insert(source.to_path_buf(), output);
        Ok(path)
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
    use std::os::unix::fs::PermissionsExt;

    use age::secrecy::ExposeSecret;

    use super::*;

    #[test]
    fn plain_identity_is_returned_without_materialization() {
        let temp = tempfile::tempdir().unwrap();
        let identity = temp.path().join("identity");
        fs::write(&identity, "private\n").unwrap();
        let runtime = SshRuntime::new(Age::new(), Vec::new()).unwrap();

        assert_eq!(runtime.resolve_identity(&identity).unwrap(), identity);
    }

    #[test]
    fn encrypted_identity_is_materialized_once_with_private_permissions() {
        let temp = tempfile::tempdir().unwrap();
        let recipient = age::x25519::Identity::generate();
        let decrypt_identity = temp.path().join("decrypt-identity");
        fs::write(&decrypt_identity, recipient.to_string().expose_secret()).unwrap();
        let source = temp.path().join("nixbot.key.age");
        fs::write(
            &source,
            age::encrypt(&recipient.to_public(), b"decrypted-private-key\n").unwrap(),
        )
        .unwrap();
        let runtime = SshRuntime::new(Age::new(), vec![decrypt_identity]).unwrap();

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

    #[test]
    fn unreadable_identities_are_named_in_the_failure() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("nixbot.key.age");
        fs::write(&source, b"not an age file").unwrap();
        let runtime = SshRuntime::new(Age::new(), Vec::new()).unwrap();

        let error = runtime.resolve_identity(&source).unwrap_err();
        let message = format!("{error:#}");
        assert!(
            message.contains("no usable age identities were found"),
            "{message}"
        );
    }
}
