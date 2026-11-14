//! Data ingress lives in the accounted client, not the bounded control lane.
//! The worker claim/source allocation precede socket creation or payload reads.

use std::fs;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::time::{Duration, Instant};

use anyhow::{Result, ensure};

use super::Session;
use crate::build_executor::preparation::source::{Material, material_limit};
use crate::build_executor::{
    control, daemon, private_sources::SourceSlot, source_transport as transport,
};

struct Endpoint {
    path: std::path::PathBuf,
    file: (u64, u64),
    parent: (u64, u64),
}

impl Endpoint {
    fn bound(path: std::path::PathBuf) -> Result<Self> {
        let file = fs::symlink_metadata(&path)?;
        let parent = fs::symlink_metadata(transport::DIRECTORY)?;
        ensure!(
            file.file_type().is_socket() && file.uid() == 0,
            "source endpoint differs"
        );
        Ok(Self {
            path,
            file: (file.dev(), file.ino()),
            parent: (parent.dev(), parent.ino()),
        })
    }
}

impl Drop for Endpoint {
    fn drop(&mut self) {
        // Only this live creation handle may remove this endpoint. Crash residue
        // has no adoption/retirement authority and vetoes source pruning.
        if let (Ok(file), Ok(parent)) = (
            fs::symlink_metadata(&self.path),
            fs::symlink_metadata(transport::DIRECTORY),
        ) && file.file_type().is_socket()
            && file.uid() == 0
            && (file.dev(), file.ino()) == self.file
            && parent.is_dir()
            && (parent.dev(), parent.ino()) == self.parent
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Session<'_> {
    pub(in crate::build_executor) fn receive(
        &mut self,
        config: &control::Config,
    ) -> Result<Material> {
        self.active()?;
        ensure!(
            !self.source_delivery_claimed && self.source_slot.is_none(),
            "source delivery already claimed"
        );
        self.source_delivery_claimed = true;
        let result = self
            .receive_once(config)
            .and_then(|(bytes, digest)| self.decode_material(&bytes, &digest));
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }

    fn decode_material(&mut self, bytes: &[u8], material_digest: &str) -> Result<Material> {
        use crate::build_executor::{
            journal::work::Work,
            native_intent,
            process::{Limits, Runner},
            stage::{Stage, Step},
        };
        let Work::Native(intent) = &self.intent else {
            return Material::decode(
                bytes,
                self.request
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("source intent missing"))?,
            );
        };
        let intent = (**intent).clone();
        let material = match native_intent::Delivery::decode(bytes, &intent)? {
            native_intent::Delivery::Captured(material) => *material,
            native_intent::Delivery::Repository { recipe } => {
                self.produce_repository(&intent, recipe)?
            }
            // receive_once authenticated the installed relay UID before this
            // structurally distinct frame is decoded. JSON is not authority.
            native_intent::Delivery::RemoteCaptured { remote } => *remote,
            native_intent::Delivery::LocalCapture(_) => {
                let material = self.capture_local(&intent, material_digest)?;
                self.finish_local_capture(material)?
            }
        };
        let validation = native_intent::Validation {
            request: material.request.clone(),
            context: material.context,
        };
        validation.validate()?;
        self.active()?;
        let mut command = self
            .role
            .manager(crate::build_executor::role::ManagerCommand::Request);
        command
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", "/var/empty")
            .env("LC_ALL", "C")
            .env("PATH", &self.native.search_path);
        let mut runner = Runner::new(
            self.policy.source_uid,
            Limits {
                stdin: 128 * 1024,
                stdout: 64,
                stderr: 4096,
            },
            self.deadline,
        )?;
        let mut stage = Stage::create(&self.handle.ownership, Step::Resolve)?;
        self.journal.diagnose(&self.handle, stage.activity(), || {
            let output = runner.run_as(
                &mut command,
                &serde_json::to_vec(&validation)?,
                self.policy.gid,
                &mut stage,
            )?;
            ensure!(
                output.status.success()
                    && output.stdout == material.request.binding_digest()?.as_bytes(),
                "native capture validation failed"
            );
            Ok(())
        })?;
        self.active()?;
        self.journal.bind_native(
            &self.handle.ownership,
            material.request.clone(),
            material_digest.to_owned(),
            daemon::now()?,
        )?;
        self.request = Some(material.request);
        self.native_capture = Some(validation);
        Ok(material.source)
    }

    fn receive_once(&mut self, config: &control::Config) -> Result<(Vec<u8>, String)> {
        config.validate()?;
        let caller_uid = config
            .principals
            .iter()
            .find(|principal| principal.issuer == self.intent.issuer())
            .map(|principal| principal.uid)
            .ok_or_else(|| anyhow::anyhow!("source principal unavailable"))?;
        // Role comes from the accepted intent and installed UID mapping, never
        // from source JSON or an SSH key name sharing the ordinary caller UID.
        let remote_capture = matches!(&self.intent,
            crate::build_executor::journal::work::Work::Native(intent)
                if intent.bootstrap_digest.is_some() && intent.controller != intent.builder);
        let uid = if remote_capture {
            let uid = *self
                .role
                .input_principals
                .get(self.intent.issuer())
                .ok_or_else(|| anyhow::anyhow!("remote capture relay is not installed"))?;
            ensure!(
                !config.workload_uids.contains(&uid)
                    && !config
                        .principals
                        .iter()
                        .any(|principal| principal.uid == uid),
                "source relay overlaps control or workload authority"
            );
            uid
        } else {
            caller_uid
        };
        ensure!(
            uid > 0 && config.workload_uids.contains(&self.policy.source_uid),
            "source principal/producer differs"
        );
        let root = Path::new(transport::DIRECTORY);
        daemon::trusted_path(root)?;
        ensure!(
            fs::canonicalize(root)? == root && root.is_dir(),
            "source ingress directory redirected"
        );
        let producer_uid = match &self.intent {
            crate::build_executor::journal::work::Work::Native(intent)
                if intent.bootstrap_digest.is_some() && !remote_capture =>
            {
                let account = self.caller_account(intent)?;
                ensure!(account.uid == uid, "source caller/receiver differs");
                account.uid
            }
            _ => self.policy.source_uid,
        };
        self.source_slot = Some(SourceSlot::allocate(
            self.journal,
            self.gate,
            self.handle.ownership.clone(),
            producer_uid,
            self.policy.gid,
            self.policy.source_limits,
            daemon::now()?,
        )?);
        let path = transport::path(&self.handle.ownership.attempt_id)?;
        // Unix bind is exclusive. Never unlink/adopt/rebind an earlier endpoint.
        let listener = UnixListener::bind(&path)?;
        let name = std::ffi::CString::new(path.as_os_str().as_bytes())?;
        ensure!(
            unsafe { libc::chown(name.as_ptr(), 0, self.role.input_gid) } == 0,
            std::io::Error::last_os_error()
        );
        fs::set_permissions(&path, fs::Permissions::from_mode(0o660))?;
        let _endpoint = Endpoint::bound(path.clone())?;
        fs::File::open(transport::DIRECTORY)?.sync_all()?;
        self.journal.bind_source_endpoint(
            &self.handle.ownership,
            transport::EndpointBinding {
                device: _endpoint.file.0,
                inode: _endpoint.file.1,
                parent_device: _endpoint.parent.0,
                parent_inode: _endpoint.parent.1,
            },
            daemon::now()?,
        )?;
        listener.set_nonblocking(true)?;
        self.active()?;
        let mut ingress = if remote_capture {
            Some(super::ingress::Ingress::bind(
                self.role
                    .input_transport
                    .as_ref()
                    .ok_or_else(|| anyhow::anyhow!("input SSH policy missing"))?,
                &self.handle.ownership,
                self.deadline,
            )?)
        } else {
            None
        };
        self.journal
            .input_event(&self.handle.ownership, None, daemon::now()?)?;
        let mut rejected = 0u16;
        let mut stream = loop {
            self.active()?;
            if let Some(ingress) = &mut ingress {
                ingress.poll()?;
            }
            match listener.accept() {
                Ok((stream, _)) => {
                    if control::peer_uid(&stream)? == uid
                        && match &ingress {
                            Some(ingress) => ingress.authenticates(&stream)?,
                            None => true,
                        }
                    {
                        break stream;
                    }
                    rejected += 1;
                    ensure!(rejected <= 64, "source ingress rejection bound exceeded");
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::park_timeout(Duration::from_millis(10))
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error.into()),
            }
        };
        drop(listener);
        if let Some(ingress) = &mut ingress {
            ingress.close();
        }
        stream.set_nonblocking(true)?;
        let mut active = || self.active();
        let mut length = [0; 4];
        transport::read(&mut stream, &mut length, &mut active)?;
        let length = u32::from_be_bytes(length) as usize;
        ensure!(
            (1..=material_limit(self.policy.source_limits)?).contains(&length),
            "source frame exceeds bound"
        );
        let mut bytes = vec![0; length];
        transport::read(&mut stream, &mut bytes, &mut active)?;
        let mut commit = [0u8; 64];
        transport::read(&mut stream, &mut commit, &mut active)?;
        let digest = crate::sha256::digest_bytes(&bytes);
        ensure!(
            commit == digest.as_bytes(),
            "source delivery commit differs"
        );
        transport::end(&mut stream, &mut active)?;
        // Validate the frame before acknowledging delivery. Capture/validation
        // run after this socket closes; a delivery ACK is not a source receipt.
        match &self.intent {
            crate::build_executor::journal::work::Work::Native(intent) => {
                crate::build_executor::native_intent::Delivery::decode(&bytes, intent)?;
            }
            _ => {
                Material::decode(
                    &bytes,
                    self.request
                        .as_ref()
                        .ok_or_else(|| anyhow::anyhow!("source intent missing"))?,
                )?;
            }
        }
        self.active()?;
        self.journal
            .input_event(&self.handle.ownership, Some(digest.clone()), daemon::now()?)?;
        let receipt = serde_json::to_vec(&transport::Receipt {
            version: 1,
            attempt_id: self.handle.ownership.attempt_id.clone(),
            request_digest: self.intent.digest()?,
            material_digest: digest.clone(),
        })?;
        ensure!(receipt.len() <= 512, "source receipt exceeds bound");
        let deadline = std::cmp::min(self.deadline, Instant::now() + Duration::from_secs(2));
        let mut active = || {
            self.active()?;
            ensure!(Instant::now() < deadline, "source reply deadline expired");
            Ok(())
        };
        // Durable acceptance survives EPIPE/reset; never restart source work to
        // discover whether the sender saw this acknowledgment.
        let _ = transport::write(
            &mut stream,
            &u32::try_from(receipt.len())?.to_be_bytes(),
            &mut active,
        )
        .and_then(|()| transport::write(&mut stream, &receipt, &mut active));
        drop(stream);
        if let Some(ingress) = &mut ingress {
            ingress.settle(|| self.active())?;
        }
        self.active()?;
        Ok((bytes, digest))
    }
}
