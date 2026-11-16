//! Run-local workers share authority and cancellation, never mutable results.

use super::*;
use crate::fleet::admission::{
    self, AdmissionControl, AdmissionLimits, AdmissionSnapshot, BlockReason,
};

pub(super) struct WorkerContext<'a> {
    invocation: &'a Invocation,
    nix_program: &'a Path,
    repository: &'a Path,
    inventory: &'a Inventory,
    selection: &'a Selection,
    invocation_id: InvocationId,
    builder_lease: Arc<BuilderLeaseCoordinator>,
    diagnostic_dir: Option<PathBuf>,
    owned: Option<Arc<OwnedHandoff>>,
    forward_work: Option<ForwardWorkGuard<'a>>,
}

impl<'a> WorkerContext<'a> {
    pub(super) fn stopped(&self) -> bool {
        self.forward_work
            .as_ref()
            .is_some_and(ForwardWorkGuard::stopped)
            || crate::fleet::signal::runtime().is_some_and(|signal| signal.cancel_local())
    }

    pub(super) fn create(&self) -> Result<NativeFleetEffects<'a>> {
        crate::fleet::signal::check_interrupted()?;
        check_forward_work(&self.forward_work)?;
        let mut worker = NativeFleetEffects::create(
            self.invocation,
            self.nix_program,
            self.repository,
            self.inventory,
            self.selection,
            self.diagnostic_dir.as_deref(),
            self.owned.clone(),
        )?;
        worker.forward_work = self.forward_work.clone();
        worker.invocation_id = self.invocation_id.clone();
        worker.builder_lease = Arc::clone(&self.builder_lease);
        Ok(worker)
    }
}

impl<'a> NativeFleetEffects<'a> {
    pub(super) fn worker_context(&self) -> WorkerContext<'a> {
        WorkerContext {
            invocation: self.invocation,
            nix_program: self.nix_program,
            repository: self.repository,
            inventory: self.inventory,
            selection: self.selection,
            invocation_id: self.invocation_id.clone(),
            builder_lease: Arc::clone(&self.builder_lease),
            diagnostic_dir: self.diagnostic_dir.clone(),
            owned: self.owned.clone(),
            forward_work: self.forward_work.clone(),
        }
    }
}

impl NativeFleetEffects<'_> {
    pub(super) fn admission_control(
        &self,
        global: usize,
        domains: bool,
    ) -> Result<AdmissionControl> {
        let options = &self.invocation.options;
        let per_domain =
            crate::fleet::preparation::effective_jobs_per_domain(self.inventory, options);
        self.admission.with_limits(AdmissionLimits {
            global,
            per_domain: if domains { per_domain } else { global },
            hard_domain_max: domains
                .then_some(options.deploy_jobs_per_domain_max)
                .flatten(),
        })
    }

    pub(super) fn domain_tasks<T>(
        &self,
        tasks: Vec<T>,
        host: impl Fn(&T) -> &str,
    ) -> Result<Vec<(Option<String>, T)>> {
        tasks
            .into_iter()
            .map(|task| {
                let domain = crate::fleet::selection::deploy_domain(self.inventory, host(&task))?;
                Ok((Some(domain), task))
            })
            .collect()
    }
}

pub(super) fn unrestricted<T>(tasks: Vec<T>) -> Vec<(Option<String>, T)> {
    tasks.into_iter().map(|task| (None, task)).collect()
}

pub(super) fn dispatch<T, U>(
    tasks: Vec<(Option<String>, T)>,
    control: &AdmissionControl,
    progress: &FleetProgress,
    operation: impl Fn(T) -> U + Sync,
    stop: impl FnMut(&U) -> bool,
    completed: impl FnMut(usize, &U),
) -> Result<Vec<Option<U>>>
where
    T: Send,
    U: Send,
{
    admission::dispatch(tasks, control, operation, stop, completed, |snapshot| {
        progress.phase_admission(
            snapshot.running,
            snapshot.target,
            snapshot.adjustable(),
            admission_constraint(snapshot),
        );
    })
}

fn admission_constraint(snapshot: AdmissionSnapshot) -> Option<&'static str> {
    if snapshot.draining {
        return Some("draining");
    }
    match snapshot.blocked {
        Some(BlockReason::HardDomainMax) => Some("domain max"),
        Some(BlockReason::DomainLimit) => Some("domain limit"),
        Some(BlockReason::Stopped) => Some("closed"),
        Some(BlockReason::GlobalLimit) | None => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snapshot(blocked: Option<BlockReason>, draining: bool) -> AdmissionSnapshot {
        AdmissionSnapshot {
            target: 4,
            running: 1,
            waiting: 0,
            ceiling: 8,
            blocked,
            draining,
            active: true,
        }
    }

    #[test]
    fn admission_constraint_exposes_only_operator_relevant_scheduler_state() {
        assert_eq!(admission_constraint(snapshot(None, false)), None);
        assert_eq!(
            admission_constraint(snapshot(Some(BlockReason::GlobalLimit), false)),
            None
        );
        assert_eq!(
            admission_constraint(snapshot(Some(BlockReason::DomainLimit), false)),
            Some("domain limit")
        );
        assert_eq!(
            admission_constraint(snapshot(Some(BlockReason::HardDomainMax), false)),
            Some("domain max")
        );
        assert_eq!(
            admission_constraint(snapshot(Some(BlockReason::Stopped), false)),
            Some("closed")
        );
        assert_eq!(
            admission_constraint(snapshot(Some(BlockReason::DomainLimit), true)),
            Some("draining")
        );
    }
}
