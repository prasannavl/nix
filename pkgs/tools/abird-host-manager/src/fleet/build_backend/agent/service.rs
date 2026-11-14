//! Independently durable CI observer. Existing private parent, one writer,
//! ordinary principal IPC only. First capture is a worker directive, not source
//! IO here. No submit, recapture, successor or deploy.

use std::time::{Duration, Instant};

use abird_host_agent::build_executor::{
    client, native_intent,
    protocol::{Command, Request, Response},
    source_transport,
};
use anyhow::{Result, ensure};

use crate::fleet::build_backend::agent::control::transport::Transport;
use crate::fleet::build_backend::agent::run::{Run, controller};
use crate::fleet::host_runtime::HostExecutionTarget;

pub fn run(
    run: &str,
    attempt: &str,
    spec: &str,
    invocation: &str,
    budget_millis: u64,
) -> Result<()> {
    ensure!(
        unsafe { libc::geteuid() } != 0
            && budget_millis > 0
            && budget_millis <= 7 * 24 * 60 * 60 * 1000
            && invocation.len() == 32
            && invocation
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
            && std::env::var("INVOCATION_ID").ok().as_deref() == Some(invocation),
        "invalid installed CI observer context"
    );
    abird_host_agent::build_executor::workload::require_controller_placement(attempt)?;
    let deadline = Instant::now()
        .checked_add(Duration::from_millis(budget_millis))
        .ok_or_else(|| anyhow::anyhow!("CI observer deadline overflow"))?;
    // Busy is the only waitable file-open result. Corruption, replacement and
    // missing/partial allocation close the service; no adoption/reconstruction.
    let mut parent = loop {
        ensure!(Instant::now() < deadline, "CI observer handoff expired");
        if let Some(parent) = Run::try_service(run, attempt, spec)? {
            break parent;
        }
        std::thread::park_timeout(
            Duration::from_millis(100).min(deadline.saturating_duration_since(Instant::now())),
        );
    };
    let interval = match &parent.manifest().children[attempt].request {
        crate::fleet::build_backend::agent::run::intent::Intent::Native(request) => {
            Duration::from_secs(request.deadlines.heartbeat_seconds)
        }
        _ => anyhow::bail!("CI observer intent changed"),
    };
    let mut transport = Local {
        attempt: attempt.to_owned(),
        spec: spec.to_owned(),
        deadline,
    };
    loop {
        ensure!(
            Instant::now() < deadline,
            "CI observer original deadline expired"
        );
        let replies = controller::poll(&mut parent, &mut transport, |_| Ok(None))?;
        if controller::require_settled(&replies).is_ok() {
            return Ok(());
        }
        std::thread::park_timeout(interval.min(deadline.saturating_duration_since(Instant::now())));
    }
}

// No SSH alias, inherited environment, executable or per-host route can redirect
// this service. The builder authenticates this ordinary UID on its native IPC.
struct Local {
    attempt: String,
    spec: String,
    deadline: Instant,
}

impl Local {
    fn target(&self, target: &HostExecutionTarget) -> Result<()> {
        ensure!(
            Instant::now() < self.deadline,
            "CI observer original deadline expired"
        );
        ensure!(
            target.local && target.control_master.is_none(),
            "CI observer requires installed local IPC"
        );
        Ok(())
    }

    fn intent(&self, request: &native_intent::Request) -> Result<()> {
        ensure!(
            request.controller_service
                && request.attempt_id()? == self.attempt
                && request.digest()? == self.spec,
            "CI observer request differs"
        );
        Ok(())
    }
}

impl Transport for Local {
    fn request(&mut self, target: &HostExecutionTarget, request: &Request) -> Result<Response> {
        self.target(target)?;
        match &request.command {
            Command::Status { attempt_id }
            | Command::Cancel { attempt_id, .. }
            | Command::Renew { attempt_id, .. }
            | Command::Events { attempt_id, .. }
            | Command::Logs { attempt_id, .. } => {
                ensure!(attempt_id == &self.attempt, "CI observer child differs")
            }
            Command::WithdrawNative { request } => self.intent(request)?,
            _ => anyhow::bail!("CI observer cannot submit or choose another authority"),
        }
        let owned = Request::decode(&serde_json::to_vec(request)?)?;
        let response = client::request_until(owned.command, self.deadline)?;
        response.validate_for(request)?;
        Ok(response)
    }

    fn inputs(
        &mut self,
        _target: &HostExecutionTarget,
        _request: &abird_host_agent::build_executor::request::BuildRequest,
        _bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        anyhow::bail!("CI observer cannot replace native source with a resolved submission")
    }

    fn native_inputs(
        &mut self,
        target: &HostExecutionTarget,
        request: &native_intent::Request,
        bytes: &[u8],
    ) -> Result<Option<source_transport::Receipt>> {
        self.target(target)?;
        self.intent(request)?;
        native_intent::Delivery::decode(bytes, request)?;
        // Original delivery was durably claimed by the shared controller before
        // entering here. Lost ACK stays unconfirmed; never resend to discover it.
        Ok(source_transport::deliver_until(&self.attempt, &self.spec, bytes, self.deadline).ok())
    }
}
