use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::programs::nix::{FileBinaryCache, StorePath};

const MANIFEST_VERSION: u32 = 1;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct OfflineHostManifest {
    pub version: u32,
    pub host: String,
    pub system: PathBuf,
    pub disko_script: PathBuf,
    pub manager: PathBuf,
    pub runtime: Vec<PathBuf>,
}

impl OfflineHostManifest {
    pub fn new(
        host: impl Into<String>,
        system: &StorePath,
        disko_script: &StorePath,
        manager: &StorePath,
        runtime: &[StorePath],
    ) -> Self {
        Self {
            version: MANIFEST_VERSION,
            host: host.into(),
            system: system.as_path().to_path_buf(),
            disko_script: disko_script.as_path().to_path_buf(),
            manager: manager.as_path().to_path_buf(),
            runtime: runtime
                .iter()
                .map(|path| path.as_path().to_path_buf())
                .collect(),
        }
    }

    pub fn validate(&self, expected_host: &str) -> Result<()> {
        if self.version != MANIFEST_VERSION {
            bail!(
                "unsupported offline cache manifest version {}; expected {MANIFEST_VERSION}",
                self.version
            );
        }
        if self.host != expected_host {
            bail!(
                "offline cache manifest belongs to host {:?}, not {:?}",
                self.host,
                expected_host
            );
        }
        for path in self
            .runtime
            .iter()
            .chain([&self.system, &self.disko_script, &self.manager])
        {
            StorePath::new(path.clone())?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct OfflineStore {
    cache: FileBinaryCache,
}

impl OfflineStore {
    pub fn new(directory: impl Into<PathBuf>) -> Result<Self> {
        Ok(Self {
            cache: FileBinaryCache::new(directory)?,
        })
    }

    pub fn cache(&self) -> &FileBinaryCache {
        &self.cache
    }

    pub fn require_initialized(&self) -> Result<()> {
        let cache_info = self.cache.directory().join("nix-cache-info");
        if !cache_info.is_file() {
            bail!(
                "{} is not an initialized Nix file binary cache",
                self.cache.directory().display()
            );
        }
        Ok(())
    }

    pub fn load(&self, host: &str) -> Result<OfflineHostManifest> {
        self.require_initialized()?;
        let path = self.manifest_path(host);
        let manifest: OfflineHostManifest = serde_json::from_reader(
            File::open(&path)
                .with_context(|| format!("open offline host manifest {}", path.display()))?,
        )
        .with_context(|| format!("parse offline host manifest {}", path.display()))?;
        manifest.validate(host)?;
        Ok(manifest)
    }

    pub fn publish(&self, manifest: &OfflineHostManifest) -> Result<PathBuf> {
        self.require_initialized()?;
        manifest.validate(&manifest.host)?;
        let path = self.manifest_path(&manifest.host);
        let parent = path.parent().context("offline manifest has no parent")?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(
            ".{}.{}.{}.tmp",
            path.file_name()
                .and_then(|name| name.to_str())
                .context("offline manifest name is not UTF-8")?,
            std::process::id(),
            Uuid::new_v4(),
        ));
        let bytes = serde_json::to_vec_pretty(manifest)?;
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o644)
            .open(&temporary)
            .with_context(|| format!("create offline manifest {}", temporary.display()))?;
        file.write_all(&bytes)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, &path)?;
        File::open(parent)?.sync_all()?;
        Ok(path)
    }

    fn manifest_path(&self, host: &str) -> PathBuf {
        self.cache
            .directory()
            .join("abird-host-manager/hosts")
            .join(format!("{host}.json"))
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    fn store_path(name: &str) -> StorePath {
        StorePath::new(format!(
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-{name}"
        ))
        .unwrap()
    }

    #[test]
    fn manifest_is_published_only_into_an_initialized_cache() {
        let temporary = tempdir().unwrap();
        let directory = temporary.path().join("cache");
        fs::create_dir(&directory).unwrap();
        let store = OfflineStore::new(directory.clone()).unwrap();
        let manifest = OfflineHostManifest::new(
            "demo",
            &store_path("system"),
            &store_path("disko"),
            &store_path("manager"),
            &[store_path("nix")],
        );

        assert!(store.publish(&manifest).is_err());
        fs::write(directory.join("nix-cache-info"), "StoreDir: /nix/store\n").unwrap();
        let path = store.publish(&manifest).unwrap();
        assert!(path.is_file());
        assert_eq!(store.load("demo").unwrap(), manifest);
    }

    #[test]
    fn manifest_rejects_wrong_hosts_and_non_store_paths() {
        let mut manifest = OfflineHostManifest::new(
            "demo",
            &store_path("system"),
            &store_path("disko"),
            &store_path("manager"),
            &[],
        );
        assert!(manifest.validate("other").is_err());
        manifest.system = PathBuf::from("/tmp/system");
        assert!(manifest.validate("demo").is_err());
    }
}
