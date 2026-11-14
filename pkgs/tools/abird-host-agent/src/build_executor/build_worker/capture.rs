//! Local caller capture is an original worker stage, not an observer subprocess.
//! Only the installed principal can read its private parent/source context.

use std::time::Instant;

use anyhow::{Context, Result, ensure};

use super::Session;
use crate::build_executor::{
    control, controller_service, daemon, native_intent,
    process::{Limits, Runner, offline::CaptureView},
    stage::{Stage, Step},
};

impl Session<'_> {
    pub(super) fn caller_account(
        &self,
        intent: &native_intent::Request,
    ) -> Result<controller_service::Account> {
        self.active()?;
        ensure!(
            intent.controller == intent.builder && intent.bootstrap_digest.is_some(),
            "capture is not local to the admitted worker"
        );
        let account = self
            .role
            .controller
            .accounts
            .get(&intent.issuer)
            .context("capture principal is not installed")?;
        let config: control::Config =
            serde_json::from_slice(&daemon::read_declaration(&self.role.control)?)?;
        config.validate()?;
        ensure!(
            config
                .principals
                .iter()
                .any(|principal| principal.uid == account.uid && principal.issuer == intent.issuer)
                && !config.workload_uids.contains(&account.uid)
                && !self
                    .native
                    .clients
                    .iter()
                    .any(|client| client.uid == account.uid),
            "capture principal has different or native store authority"
        );
        daemon::verify_source_account(account.uid, &account.user)?;
        controller_service::require_primary_group(account)?;
        controller_service::require_groups(account)?;
        self.active()?;
        Ok(account.clone())
    }

    pub(super) fn capture_local(
        &mut self,
        intent: &native_intent::Request,
        delivery_digest: &str,
    ) -> Result<native_intent::Material> {
        let account = self.caller_account(intent)?;
        let input = native_intent::CaptureInput {
            intent: intent.clone(),
            delivery_digest: delivery_digest.to_owned(),
            roots: account.capture_roots.clone(),
            limits: self.policy.source_limits,
            nar_configuration: self.native.configuration_directory.clone(),
            runtime_closure: self.role.runtime_closure.clone(),
            budget_millis: self
                .deadline
                .saturating_duration_since(Instant::now())
                .as_millis()
                .try_into()?,
        };
        input.validate()?;
        // Same registered allocation; caller checkout has its separate private
        // producer. No untracked /tmp directory, new lifetime or cleanup owner.
        let (scratch, _) = self
            .source_slot
            .as_ref()
            .context("capture source allocation missing")?
            .producer(self.journal, daemon::now()?)?;
        let view = CaptureView::prepare(&scratch)?;
        ensure!(
            view.preserves(&account.capture_roots)
                && view.preserves(&[account.home.clone(), account.state_home.clone()]),
            "caller capture roots overlap private scratch"
        );
        let mut command = self
            .role
            .manager(crate::build_executor::role::ManagerCommand::Capture);
        command
            .arg(&self.policy.git_program)
            .arg(self.native.native_nar_program()?)
            .current_dir("/var/empty")
            .env_clear()
            .env("HOME", &account.home)
            .env("XDG_STATE_HOME", &account.state_home)
            .env("LC_ALL", "C")
            .env("PATH", &self.native.search_path)
            .env("GIT_CONFIG_GLOBAL", &self.policy.git_configuration)
            .envs(crate::build_executor::native_intent::CALLER_GIT_PROFILE);
        let mut runner = Runner::new_source(
            account.uid,
            Limits {
                stdin: 32 * 1024,
                stdout: crate::build_executor::preparation::source::MAX_MATERIAL_BYTES,
                stderr: 4096,
            },
            self.deadline,
            crate::build_executor::preparation::source::MAX_MATERIAL_BYTES,
        )?;
        let mut stage = Stage::create(&self.handle.ownership, Step::Capture)?;
        let output = self.journal.diagnose(&self.handle, stage.activity(), || {
            let output = runner.run_as_capture(
                &mut command,
                &serde_json::to_vec(&input)?,
                account.gid,
                &account.groups,
                view,
                &mut stage,
            )?;
            ensure!(output.status.success(), "admitted caller capture failed");
            Ok(output)
        })?;
        // run_as positively settles the original producer subgroup. Neither its
        // exit status nor a data-lane ACK can substitute for that barrier.
        self.active()?;
        native_intent::Material::decode(&output.stdout, intent)
    }
}
