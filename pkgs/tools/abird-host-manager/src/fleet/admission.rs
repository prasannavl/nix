//! Invocation-wide admission, reusable across sequential caller-owned stages/waves.
//!
//! Dependencies, selection and exclusivity belong to the caller. Only admitted
//! jobs get threads; completions and keyboard adjustments wake the coordinator.

use std::collections::{BTreeMap, VecDeque};
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, mpsc};

use anyhow::{Result, bail};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionLimits {
    pub global: usize,
    pub per_domain: usize,
    pub hard_domain_max: Option<usize>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Adjustment {
    Increase,
    Decrease,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum BlockReason {
    GlobalLimit,
    DomainLimit,
    /// Every waiting job's domain is at its hard maximum.
    HardDomainMax,
    Stopped,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct AdmissionSnapshot {
    /// Effective startup limit, or the operator's invocation-wide override.
    pub target: usize,
    /// Admitted jobs whose completions the coordinator has not yet consumed.
    pub running: usize,
    /// Unadmitted jobs; after stop these will return `None`, not run.
    pub waiting: usize,
    /// Total selected capacity supplied by the caller, including later waves.
    pub ceiling: usize,
    pub blocked: Option<BlockReason>,
    /// Admitted work exceeds lowered budgets, or stop is draining workers.
    pub draining: bool,
    pub active: bool,
}

impl AdmissionSnapshot {
    /// Scheduler-owned availability, independent of input registration.
    pub fn adjustable(self) -> bool {
        self.active
            && self.ceiling > 1
            && self.blocked != Some(BlockReason::Stopped)
            && (self.running > 0 || self.waiting > 0)
    }
}

/// Invocation input capability: no stage defaults or dispatch authority.
#[derive(Clone, Debug)]
pub struct AdmissionInput {
    shared: Arc<Shared>,
}

#[derive(Clone, Debug)]
pub struct AdmissionControl {
    shared: Arc<Shared>,
    limits: AdmissionLimits,
}

#[derive(Debug)]
struct Shared {
    state: Mutex<State>,
    changed: Condvar,
}

#[derive(Debug)]
struct State {
    capacity: usize,
    /// One operator override, shared by every remaining pool in this invocation.
    target: Option<usize>,
    wave: Option<Wave>,
}

#[derive(Debug)]
struct Job {
    index: usize,
    domain: Option<String>,
}

#[derive(Debug)]
struct Wave {
    limits: AdmissionLimits,
    queue: VecDeque<Job>,
    domains: BTreeMap<String, usize>,
    running: usize,
    stopped: bool,
}

impl AdmissionControl {
    /// `capacity` covers the invocation's selected hosts, not one wave.
    pub fn new(limits: AdmissionLimits, capacity: usize) -> Result<Self> {
        validate_limits(limits)?;
        Ok(Self {
            limits,
            shared: Arc::new(Shared {
                state: Mutex::new(State {
                    capacity,
                    target: None,
                    wave: None,
                }),
                changed: Condvar::new(),
            }),
        })
    }

    /// Stage defaults change; an explicit operator target does not.
    pub fn with_limits(&self, limits: AdmissionLimits) -> Result<Self> {
        validate_limits(limits)?;
        Ok(Self {
            limits,
            shared: Arc::clone(&self.shared),
        })
    }

    pub fn snapshot(&self) -> AdmissionSnapshot {
        self.lock().snapshot(self.limits.global)
    }

    /// A serial, non-interactive invocation cannot later become parallel.
    pub fn parallelism_possible(&self, interactive: bool) -> bool {
        let state = self.lock();
        state.capacity > 1 && (interactive || state.target.unwrap_or(self.limits.global) > 1)
    }

    pub fn input(&self) -> AdmissionInput {
        AdmissionInput {
            shared: Arc::clone(&self.shared),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.shared.lock()
    }
}

impl AdmissionInput {
    /// Change the active wave's displayed target by one, for the remaining run.
    /// Idle, stopped and saturated presses are never banked.
    pub fn adjust(&self, adjustment: Adjustment) -> bool {
        let mut state = self.shared.lock();
        let Some(wave) = &state.wave else {
            return false;
        };
        let snapshot = state.snapshot(wave.limits.global);
        if !snapshot.adjustable() {
            return false;
        }
        let target = match adjustment {
            Adjustment::Increase if snapshot.target < snapshot.ceiling => snapshot.target + 1,
            Adjustment::Decrease if snapshot.target > 1 => snapshot.target - 1,
            _ => return false,
        };
        state.target = Some(target);
        self.shared.changed.notify_all();
        true
    }
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        // No caller code runs under this lock. Recovery also lets the wave
        // guard finalize after a thread-spawn panic poisoned admission.
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

fn validate_limits(limits: AdmissionLimits) -> Result<()> {
    if limits.global == 0 || limits.per_domain == 0 || limits.hard_domain_max == Some(0) {
        bail!("admission limits must be positive");
    }
    if limits
        .hard_domain_max
        .is_some_and(|maximum| maximum < limits.per_domain)
    {
        bail!("hard domain maximum must not be below initial per-domain parallelism");
    }
    Ok(())
}

impl State {
    fn snapshot(&self, default: usize) -> AdmissionSnapshot {
        let target = self
            .target
            .unwrap_or_else(|| {
                self.wave
                    .as_ref()
                    .map_or(default, |wave| wave.initial_target())
            })
            .min(self.capacity.max(1));
        let Some(wave) = &self.wave else {
            return AdmissionSnapshot {
                target,
                running: 0,
                waiting: 0,
                ceiling: self.capacity,
                blocked: None,
                draining: false,
                active: false,
            };
        };
        let blocked = if wave.stopped {
            Some(BlockReason::Stopped)
        } else if wave.queue.is_empty() {
            None
        } else if wave.queue.iter().all(|job| wave.hard_blocked(job)) {
            Some(BlockReason::HardDomainMax)
        } else if !wave
            .queue
            .iter()
            .any(|job| wave.domain_ready(job, self.target.is_some()))
        {
            Some(BlockReason::DomainLimit)
        } else if wave.running >= target {
            Some(BlockReason::GlobalLimit)
        } else {
            None
        };
        AdmissionSnapshot {
            target,
            running: wave.running,
            waiting: wave.queue.len(),
            ceiling: self.capacity,
            blocked,
            draining: wave.running > target || (wave.stopped && wave.running > 0),
            active: true,
        }
    }
}

impl Wave {
    /// Capacity of remaining work under startup limits, including admitted
    /// jobs. A finished domain must not strand another at its soft limit when
    /// the nominal global cap is already at selected capacity.
    fn initial_target(&self) -> usize {
        let mut domains = self
            .domains
            .iter()
            .map(|(domain, count)| (domain.as_str(), *count))
            .collect::<BTreeMap<_, _>>();
        let mut slots = self.running - domains.values().sum::<usize>();
        for job in &self.queue {
            if let Some(domain) = &job.domain {
                *domains.entry(domain).or_default() += 1;
            } else {
                slots += 1;
            }
        }
        slots += domains
            .values()
            .map(|count| (*count).min(self.limits.per_domain))
            .sum::<usize>();
        slots.min(self.limits.global).max(1)
    }

    fn hard_blocked(&self, job: &Job) -> bool {
        job.domain.as_ref().is_some_and(|domain| {
            self.limits
                .hard_domain_max
                .is_some_and(|maximum| self.domains.get(domain).copied().unwrap_or(0) >= maximum)
        })
    }

    fn domain_ready(&self, job: &Job, manual: bool) -> bool {
        !self.hard_blocked(job)
            && (manual
                || job.domain.as_ref().is_none_or(|domain| {
                    self.domains.get(domain).copied().unwrap_or(0) < self.limits.per_domain
                }))
    }

    fn finish(&mut self, domain: &Option<String>) {
        self.running -= 1;
        if let Some(domain) = domain {
            *self.domains.get_mut(domain).expect("running domain") -= 1;
        }
    }
}

struct WaveGuard<'a>(&'a AdmissionControl);

impl Drop for WaveGuard<'_> {
    fn drop(&mut self) {
        self.0.lock().wave = None;
        self.0.shared.changed.notify_all();
    }
}

/// Dispatch one wave, returning results in input order (`None` = not admitted).
///
/// `None` domains consume only the global budget. The first eligible queued
/// job wins, so a saturated domain does not block unrelated work. A control
/// accepts only one wave at a time; clones share its settings and wakeup.
///
/// `stop`, `completed(index, &output)` and `observe` run on the coordinator,
/// outside scheduler locks, and need not be `Send` or `Sync`. Each completion
/// runs `stop` then `completed` before any more admission. A true stop decision
/// is sticky; already admitted jobs still finish and publish their results.
/// Snapshot observation follows changes, not a polling timer.
///
/// Worker/callback panics stop admission, join admitted threads, reset the
/// control and propagate the original panic. Final observation is attempted
/// even on unwind; its panic cannot replace an already propagating panic.
/// Workers must eventually return; this scheduler does not cancel them.
pub fn dispatch<T, U, F, S, C, O>(
    inputs: Vec<(Option<String>, T)>,
    control: &AdmissionControl,
    operation: F,
    mut stop: S,
    mut completed: C,
    mut observe: O,
) -> Result<Vec<Option<U>>>
where
    T: Send,
    U: Send,
    F: Fn(T) -> U + Sync,
    S: FnMut(&U) -> bool,
    C: FnMut(usize, &U),
    O: FnMut(AdmissionSnapshot),
{
    let mut wave = Wave {
        limits: control.limits,
        queue: VecDeque::new(),
        domains: BTreeMap::new(),
        running: 0,
        stopped: false,
    };
    let mut pending = Vec::with_capacity(inputs.len());
    for (index, (domain, input)) in inputs.into_iter().enumerate() {
        wave.queue.push_back(Job { index, domain });
        pending.push(Some(input));
    }
    {
        let mut state = control.lock();
        if state.wave.is_some() {
            bail!("admission control already has an active wave");
        }
        if pending.len() > state.capacity {
            bail!("admission wave exceeds selected capacity");
        }
        state.wave = Some(wave);
    }
    let guard = WaveGuard(control);
    let outcome = catch_unwind(AssertUnwindSafe(|| {
        let mut results = std::iter::repeat_with(|| None)
            .take(pending.len())
            .collect::<Vec<_>>();
        let (sender, receiver) = mpsc::channel::<(Job, std::thread::Result<U>)>();
        std::thread::scope(|scope| {
            let mut observed = None;
            loop {
                let mut state = control.lock();
                // Completion publication and admission use the same lock.
                // Drain completions before admitting even one additional job.
                if let Ok((job, output)) = receiver.try_recv() {
                    state
                        .wave
                        .as_mut()
                        .expect("active wave")
                        .finish(&job.domain);
                    drop(state);
                    let output = match output {
                        Ok(output) => output,
                        Err(panic) => resume_unwind(panic),
                    };
                    if stop(&output) {
                        control.lock().wave.as_mut().expect("active wave").stopped = true;
                    }
                    completed(job.index, &output);
                    results[job.index] = Some(output);
                    continue;
                }
                let snapshot = state.snapshot(control.limits.global);
                if observed != Some(snapshot) {
                    observed = Some(snapshot);
                    drop(state);
                    observe(snapshot);
                    // A completion/adjustment may have arrived in the callback.
                    continue;
                }
                let manual = state.target.is_some();
                let wave = state.wave.as_mut().expect("active wave");
                if wave.running == 0 && (wave.queue.is_empty() || wave.stopped) {
                    break;
                }
                if snapshot.blocked.is_none() && !wave.queue.is_empty() {
                    let position = wave
                        .queue
                        .iter()
                        .position(|job| wave.domain_ready(job, manual))
                        .expect("unblocked admission");
                    let job = wave.queue.remove(position).expect("queued job");
                    wave.running += 1;
                    if let Some(domain) = &job.domain {
                        *wave.domains.entry(domain.clone()).or_default() += 1;
                    }
                    let input = pending[job.index].take().expect("unadmitted input");
                    let sender = sender.clone();
                    let operation = &operation;
                    scope.spawn(move || {
                        let output = catch_unwind(AssertUnwindSafe(|| operation(input)));
                        let _state = control.lock();
                        let _ = sender.send((job, output));
                        control.shared.changed.notify_all();
                    });
                } else {
                    // The same mutex guards both wake sources and the predicate:
                    // no lost completion or key press between checking and wait.
                    drop(
                        control
                            .shared
                            .changed
                            .wait(state)
                            .unwrap_or_else(|poisoned| poisoned.into_inner()),
                    );
                }
            }
        });
        results
    }));
    // Outside the scope: every admitted worker has joined, including on panic.
    drop(guard);
    let snapshot = control.snapshot();
    match outcome {
        Ok(results) => {
            observe(snapshot);
            Ok(results)
        }
        Err(panic) => {
            let _ = catch_unwind(AssertUnwindSafe(|| observe(snapshot)));
            resume_unwind(panic)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    // Timeouts are deadlock watchdogs, never synchronization or timing asserts.
    fn receive<T>(receiver: &mpsc::Receiver<T>) -> T {
        receiver
            .recv_timeout(Duration::from_secs(10))
            .expect("scheduler test channel stalled")
    }

    fn until(
        receiver: &mpsc::Receiver<AdmissionSnapshot>,
        predicate: impl Fn(AdmissionSnapshot) -> bool,
    ) -> AdmissionSnapshot {
        loop {
            let snapshot = receive(receiver);
            if predicate(snapshot) {
                return snapshot;
            }
        }
    }

    fn control(
        global: usize,
        per_domain: usize,
        hard: Option<usize>,
        capacity: usize,
    ) -> AdmissionControl {
        AdmissionControl::new(
            AdmissionLimits {
                global,
                per_domain,
                hard_domain_max: hard,
            },
            capacity,
        )
        .unwrap()
    }

    fn adjust(control: &AdmissionControl, adjustment: Adjustment) -> AdmissionSnapshot {
        control.input().adjust(adjustment);
        control.snapshot()
    }

    struct Gate {
        index: usize,
        release: mpsc::Receiver<()>,
    }

    impl Gate {
        fn run(self, started: &mpsc::Sender<usize>) -> usize {
            started.send(self.index).unwrap();
            receive(&self.release);
            self.index
        }
    }

    struct Gated {
        jobs: Vec<(Option<String>, Gate)>,
        releases: Vec<mpsc::Sender<()>>,
    }

    fn gated(domains: &[Option<&str>]) -> Gated {
        let mut jobs = Vec::new();
        let mut releases = Vec::new();
        for (index, domain) in domains.iter().enumerate() {
            let (release, receiver) = mpsc::channel();
            jobs.push((
                domain.map(str::to_owned),
                Gate {
                    index,
                    release: receiver,
                },
            ));
            releases.push(release);
        }
        Gated { jobs, releases }
    }

    #[test]
    fn increase_wakes_workers_and_ignores_requests_above_capacity() {
        let control = control(1, 1, None, 3);
        let Gated { jobs, releases } = gated(&[None; 3]);
        let (started, starts) = mpsc::channel();
        let (observed, snapshots) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |snapshot| observed.send(snapshot).unwrap(),
                )
                .unwrap()
            });
            assert_eq!(receive(&starts), 0);
            until(&snapshots, |s| s.blocked == Some(BlockReason::GlobalLimit));
            let adjusted = adjust(&control, Adjustment::Increase);
            assert_eq!(adjusted.target, 2);
            assert_eq!(receive(&starts), 1);
            until(&snapshots, |s| s.running == 2);
            adjust(&control, Adjustment::Increase);
            assert_eq!(receive(&starts), 2);
            let at_ceiling = until(&snapshots, |s| s.running == 3);
            for _ in 0..20 {
                assert_eq!(adjust(&control, Adjustment::Increase), at_ceiling);
            }
            for release in releases {
                release.send(()).unwrap();
            }
            assert_eq!(runner.join().unwrap(), vec![Some(0), Some(1), Some(2)]);
        });
    }

    #[test]
    fn decrease_drains_without_cancelling() {
        let control = control(2, 1, None, 4);
        let Gated { jobs, releases } = gated(&[None; 4]);
        let (started, starts) = mpsc::channel();
        let (observed, snapshots) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |snapshot| observed.send(snapshot).unwrap(),
                )
                .unwrap()
            });
            let mut first = [receive(&starts), receive(&starts)];
            first.sort();
            assert_eq!(first, [0, 1]);
            adjust(&control, Adjustment::Increase);
            assert_eq!(receive(&starts), 2);
            let down = adjust(&control, Adjustment::Decrease);
            assert_eq!(down.target, 2);
            let down = adjust(&control, Adjustment::Decrease);
            assert_eq!(down.target, 1);
            assert_eq!(adjust(&control, Adjustment::Decrease), down);
            until(&snapshots, |s| {
                s.target == 1 && s.running == 3 && s.draining
            });
            releases[0].send(()).unwrap();
            until(&snapshots, |s| s.running == 2 && s.draining);
            assert!(starts.try_recv().is_err());
            releases[1].send(()).unwrap();
            until(&snapshots, |s| {
                s.running == 1 && s.waiting == 1 && !s.draining
            });
            assert!(starts.try_recv().is_err());
            releases[2].send(()).unwrap();
            assert_eq!(receive(&starts), 3);
            releases[3].send(()).unwrap();
            assert_eq!(
                runner.join().unwrap(),
                vec![Some(0), Some(1), Some(2), Some(3)]
            );
        });
    }

    #[test]
    fn completion_is_immediate_but_results_remain_in_input_order() {
        let control = control(3, 1, None, 3);
        let Gated { jobs, releases } = gated(&[None; 3]);
        let (started, starts) = mpsc::channel();
        let (completed, completions) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                let coordinator = std::thread::current().id();
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |index, output| {
                        assert_eq!(std::thread::current().id(), coordinator);
                        assert_eq!(index, *output);
                        completed.send(index).unwrap();
                    },
                    |_| {},
                )
                .unwrap()
            });
            for _ in 0..3 {
                receive(&starts);
            }
            for index in [2, 0, 1] {
                releases[index].send(()).unwrap();
                // The other workers are still blocked: no end-of-batch callback.
                assert_eq!(receive(&completions), index);
            }
            assert_eq!(runner.join().unwrap(), vec![Some(0), Some(1), Some(2)]);
        });
    }

    #[test]
    fn callbacks_can_borrow_local_effects_and_precede_next_admission() {
        let control = control(1, 1, None, 4);
        let published = AtomicUsize::new(0);
        let local_effects = Rc::new(Cell::new(0));
        let output = dispatch(
            (0..4).map(|index| (None, index)).collect(),
            &control,
            |index| {
                assert_eq!(published.load(Ordering::SeqCst), index);
                index
            },
            |_| false,
            |index, _| {
                local_effects.set(index + 1);
                published.store(index + 1, Ordering::SeqCst);
                // Re-entry is rejected without disturbing this wave.
                assert!(
                    dispatch(
                        Vec::<(Option<String>, usize)>::new(),
                        &control,
                        |value| value,
                        |_| false,
                        |_, _| {},
                        |_| {},
                    )
                    .is_err()
                );
            },
            |_| {},
        )
        .unwrap();
        assert_eq!(local_effects.get(), 4);
        assert_eq!(output, vec![Some(0), Some(1), Some(2), Some(3)]);
    }

    #[test]
    fn failure_stops_admission_but_publishes_already_admitted_results() {
        let control = control(2, 1, None, 3);
        let Gated { jobs, releases } = gated(&[None; 3]);
        let (started, starts) = mpsc::channel();
        let (completed, completions) = mpsc::channel();
        let (observed, snapshots) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started) != 0,
                    |succeeded| !*succeeded,
                    |index, _| completed.send(index).unwrap(),
                    |snapshot| observed.send(snapshot).unwrap(),
                )
                .unwrap()
            });
            receive(&starts);
            receive(&starts);
            releases[0].send(()).unwrap();
            assert_eq!(receive(&completions), 0);
            let stopped = until(&snapshots, |s| s.blocked == Some(BlockReason::Stopped));
            assert_eq!(
                (stopped.running, stopped.waiting, stopped.draining),
                (1, 1, true)
            );
            assert_eq!(adjust(&control, Adjustment::Increase), stopped);
            assert!(starts.try_recv().is_err());
            releases[1].send(()).unwrap();
            assert_eq!(receive(&completions), 1);
            assert_eq!(runner.join().unwrap(), vec![Some(false), Some(true), None]);
        });
    }

    #[test]
    fn hard_domain_maximum_survives_repeated_increases() {
        let control = control(1, 1, Some(2), 4);
        let Gated { jobs, releases } = gated(&[Some("a"); 4]);
        let (started, starts) = mpsc::channel();
        let (observed, snapshots) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |snapshot| {
                        assert!(snapshot.running <= 2);
                        observed.send(snapshot).unwrap();
                    },
                )
                .unwrap()
            });
            assert_eq!(receive(&starts), 0);
            adjust(&control, Adjustment::Increase);
            assert_eq!(receive(&starts), 1);
            for _ in 0..20 {
                adjust(&control, Adjustment::Increase);
            }
            let blocked = until(&snapshots, |s| {
                s.target == 4 && s.blocked == Some(BlockReason::HardDomainMax)
            });
            assert_eq!((blocked.running, blocked.target), (2, 4));
            assert!(starts.try_recv().is_err());
            releases[0].send(()).unwrap();
            assert_eq!(receive(&starts), 2);
            releases[1].send(()).unwrap();
            assert_eq!(receive(&starts), 3);
            releases[2].send(()).unwrap();
            releases[3].send(()).unwrap();
            assert!(runner.join().unwrap().iter().all(Option::is_some));
        });
    }

    #[test]
    fn small_wave_adjustment_persists_for_later_larger_wave() {
        let control = control(1, 1, None, 4);
        let (started, starts) = mpsc::channel();
        let Gated { jobs, releases } = gated(&[Some("a")]);
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |_| {},
                )
                .unwrap()
            });
            receive(&starts);
            adjust(&control, Adjustment::Increase);
            assert_eq!(adjust(&control, Adjustment::Increase).target, 3);
            releases[0].send(()).unwrap();
            runner.join().unwrap();
        });
        let idle = control.snapshot();
        assert_eq!((idle.target, idle.active), (3, false));
        assert_eq!(adjust(&control, Adjustment::Increase), idle);
        let Gated { jobs, releases } = gated(&[Some("a"); 3]);
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |_| {},
                )
                .unwrap()
            });
            // All three must start before any can finish, using the session override.
            for _ in 0..3 {
                receive(&starts);
            }
            for release in releases {
                release.send(()).unwrap();
            }
            assert_eq!(runner.join().unwrap(), vec![Some(0), Some(1), Some(2)]);
        });
    }

    #[test]
    fn panics_finalize_control_and_observer_then_propagate_original_payload() {
        for panic_at in 0..4 {
            let control = control(1, 1, None, 2);
            let mut snapshots = Vec::new();
            let panic = catch_unwind(AssertUnwindSafe(|| {
                dispatch(
                    vec![(None, 0), (None, 1)],
                    &control,
                    |index| {
                        assert_ne!(panic_at, 0, "original panic");
                        index
                    },
                    |_| {
                        assert_ne!(panic_at, 1, "original panic");
                        false
                    },
                    |_, _| assert_ne!(panic_at, 2, "original panic"),
                    |snapshot| {
                        snapshots.push(snapshot);
                        if snapshot.active {
                            assert_ne!(panic_at, 3, "original panic");
                        } else if panic_at == 0 {
                            panic!("secondary final-observer panic");
                        }
                    },
                )
            }))
            .unwrap_err();
            let message = panic.downcast_ref::<String>().unwrap();
            assert!(message.contains("original panic"));
            let final_snapshot = control.snapshot();
            assert!(!final_snapshot.active);
            assert_eq!((final_snapshot.running, final_snapshot.waiting), (0, 0));
            assert_eq!(snapshots.last(), Some(&final_snapshot));
            assert_eq!(
                dispatch(
                    vec![(None, 7)],
                    &control,
                    |value| value,
                    |_| false,
                    |_, _| {},
                    |_| {}
                )
                .unwrap(),
                vec![Some(7)]
            );
        }
    }

    #[test]
    fn callback_panic_still_joins_other_admitted_worker() {
        let control = control(2, 1, None, 2);
        let Gated { jobs, releases } = gated(&[None; 2]);
        let (started, starts) = mpsc::channel();
        let (panicking, panics) = mpsc::channel();
        let (finished, finishes) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                catch_unwind(AssertUnwindSafe(|| {
                    dispatch(
                        jobs,
                        &control,
                        |gate| {
                            let index = gate.run(&started);
                            finished.send(index).unwrap();
                            index
                        },
                        |_| false,
                        |_, _| {
                            panicking.send(()).unwrap();
                            panic!("completion callback panic");
                        },
                        |_| {},
                    )
                }))
            });
            receive(&starts);
            receive(&starts);
            releases[0].send(()).unwrap();
            receive(&panics);
            assert_eq!(receive(&finishes), 0);
            assert!(control.snapshot().active);
            releases[1].send(()).unwrap();
            assert_eq!(receive(&finishes), 1);
            assert!(runner.join().unwrap().is_err());
            assert!(!control.snapshot().active);
        });
    }

    fn initial_wave(control: &AdmissionControl, domains: &[Option<&str>]) {
        let wave = Wave {
            limits: control.limits,
            queue: domains
                .iter()
                .enumerate()
                .map(|(index, domain)| Job {
                    index,
                    domain: domain.map(str::to_owned),
                })
                .collect(),
            domains: BTreeMap::new(),
            running: 0,
            stopped: false,
        };
        control.lock().wave = Some(wave);
    }

    #[test]
    fn input_outlives_originating_pool_and_uses_only_active_wave_limits() {
        let root = control(8, 8, None, 8);
        let plan = root
            .with_limits(AdmissionLimits {
                global: 1,
                per_domain: 1,
                hard_domain_max: None,
            })
            .unwrap();
        let input = plan.input();
        drop(plan);
        assert!(!input.adjust(Adjustment::Increase));
        assert_eq!(root.lock().target, None);
        let build = root
            .with_limits(AdmissionLimits {
                global: 4,
                per_domain: 4,
                hard_domain_max: None,
            })
            .unwrap();
        initial_wave(&build, &[None; 8]);
        assert!(input.adjust(Adjustment::Increase));
        assert_eq!(build.snapshot().target, 5);
        root.lock().wave = None;
        assert!(!input.adjust(Adjustment::Decrease));
        assert_eq!(root.snapshot().target, 5);
        let deploy = root
            .with_limits(AdmissionLimits {
                global: 3,
                per_domain: 2,
                hard_domain_max: Some(2),
            })
            .unwrap();
        initial_wave(&deploy, &[Some("a"); 8]);
        assert_eq!(deploy.snapshot().target, 5);
        assert!(input.adjust(Adjustment::Decrease));
        assert_eq!(deploy.snapshot().target, 4);
        {
            let mut state = root.lock();
            let wave = state.wave.as_mut().unwrap();
            wave.running = 2;
            wave.domains.insert("a".into(), 2);
        }
        assert_eq!(deploy.snapshot().blocked, Some(BlockReason::HardDomainMax));
    }

    #[test]
    fn empty_stopped_waves_and_single_host_selections_are_not_adjustable() {
        for capacity in [1, 8] {
            let control = control(1, 1, None, capacity);
            let input = control.input();
            assert!(!control.snapshot().adjustable());
            initial_wave(&control, &[]);
            assert!(!control.snapshot().adjustable());
            assert!(!input.adjust(Adjustment::Increase));
            assert_eq!(control.lock().target, None);
            initial_wave(&control, &[None]);
            assert_eq!(control.snapshot().adjustable(), capacity > 1);
            control.lock().wave.as_mut().unwrap().stopped = true;
            assert!(!control.snapshot().adjustable());
            assert!(!input.adjust(Adjustment::Increase));
            assert_eq!(control.lock().target, None);
        }
    }

    #[test]
    fn adjustments_use_effective_limit_are_reversible_and_share_one_target() {
        let control = control(8, 2, None, 8);
        let input = control.input();
        initial_wave(&control, &[Some("a"); 8]);
        assert_eq!(control.snapshot().target, 2);
        assert_eq!(adjust(&control, Adjustment::Increase).target, 3);
        assert_eq!(adjust(&control, Adjustment::Decrease).target, 2);
        assert_eq!(adjust(&control, Adjustment::Decrease).target, 1);
        assert!(!input.adjust(Adjustment::Decrease));
        assert_eq!(control.snapshot().target, 1);
        for expected in 2..=8 {
            assert_eq!(adjust(&control, Adjustment::Increase).target, expected);
        }
        assert!(!input.adjust(Adjustment::Increase));
        assert_eq!(control.snapshot().target, 8);
        assert_eq!(adjust(&control, Adjustment::Decrease).target, 7);
        assert_eq!(adjust(&control, Adjustment::Increase).target, 8);
        // A later stage with different defaults inherits exactly this override.
        control.lock().wave = None;
        let next = control
            .with_limits(AdmissionLimits {
                global: 1,
                per_domain: 1,
                hard_domain_max: Some(2),
            })
            .unwrap();
        initial_wave(&next, &[Some("a"); 8]);
        assert_eq!(next.snapshot().target, 8);
        next.lock()
            .wave
            .as_mut()
            .unwrap()
            .domains
            .insert("a".into(), 2);
        assert_eq!(next.snapshot().blocked, Some(BlockReason::HardDomainMax));
    }

    #[test]
    fn finished_domains_do_not_leave_soft_limits_stuck_at_global_ceiling() {
        let control = control(8, 2, None, 8);
        initial_wave(&control, &[Some("a"); 6]);
        {
            let mut state = control.lock();
            let wave = state.wave.as_mut().unwrap();
            wave.running = 2;
            wave.domains.insert("a".into(), 2);
            wave.domains.insert("finished-domain".into(), 0);
        }
        assert_eq!(control.snapshot().target, 2);
        assert_eq!(adjust(&control, Adjustment::Increase).target, 3);
        assert_eq!(control.snapshot().blocked, None);
    }

    #[test]
    fn lowered_target_does_not_block_unrelated_domains_below_global_occupancy() {
        let control = control(8, 2, None, 12);
        initial_wave(&control, &[Some("a"), Some("b"), Some("c"), Some("d")]);
        {
            let mut state = control.lock();
            state.target = Some(9);
            let wave = state.wave.as_mut().unwrap();
            wave.running = 3;
            wave.domains.insert("a".into(), 3);
        }
        let down = adjust(&control, Adjustment::Decrease);
        assert_eq!(
            (down.target, down.running, down.blocked, down.draining),
            (8, 3, None, false)
        );
    }

    #[test]
    fn one_key_admits_only_one_extra_host_even_with_idle_global_capacity() {
        let control = control(8, 2, None, 8);
        let Gated { jobs, releases } = gated(&[Some("a"); 8]);
        let (started, starts) = mpsc::channel();
        let (observed, snapshots) = mpsc::channel();
        std::thread::scope(|scope| {
            let runner = scope.spawn(|| {
                dispatch(
                    jobs,
                    &control,
                    |gate| gate.run(&started),
                    |_| false,
                    |_, _| {},
                    |snapshot| observed.send(snapshot).unwrap(),
                )
                .unwrap()
            });
            receive(&starts);
            receive(&starts);
            until(&snapshots, |s| {
                s.running == 2 && s.blocked == Some(BlockReason::DomainLimit)
            });
            assert_eq!(adjust(&control, Adjustment::Increase).target, 3);
            receive(&starts);
            until(&snapshots, |s| {
                s.running == 3 && s.blocked == Some(BlockReason::GlobalLimit)
            });
            assert!(starts.try_recv().is_err());
            for release in releases {
                release.send(()).unwrap();
            }
            assert!(runner.join().unwrap().iter().all(Option::is_some));
        });
    }

    #[test]
    fn serial_noninteractive_execution_keeps_eval_cache_enabled() {
        let control = control(1, 1, None, 8);
        assert!(!control.parallelism_possible(false));
        assert!(control.parallelism_possible(true));
        initial_wave(&control, &[None; 8]);
        adjust(&control, Adjustment::Increase);
        assert!(control.parallelism_possible(false));
        let single = super::AdmissionControl::new(control.limits, 1).unwrap();
        assert!(!single.parallelism_possible(true));
    }

    #[test]
    fn validates_limits_and_selected_capacity_and_handles_empty_wave() {
        for limits in [
            AdmissionLimits {
                global: 0,
                per_domain: 1,
                hard_domain_max: None,
            },
            AdmissionLimits {
                global: 1,
                per_domain: 0,
                hard_domain_max: None,
            },
            AdmissionLimits {
                global: 1,
                per_domain: 1,
                hard_domain_max: Some(0),
            },
            AdmissionLimits {
                global: 4,
                per_domain: 3,
                hard_domain_max: Some(2),
            },
        ] {
            assert!(AdmissionControl::new(limits, 2).is_err());
        }
        let control = control(8, 1, None, 0);
        let mut snapshots = Vec::new();
        let result = dispatch(
            Vec::<(Option<String>, usize)>::new(),
            &control,
            |value| value,
            |_| false,
            |_, _| {},
            |snapshot| snapshots.push(snapshot),
        )
        .unwrap();
        assert!(result.is_empty());
        assert_eq!(snapshots.len(), 2);
        assert!(!snapshots[1].active);
        assert_eq!((snapshots[1].target, snapshots[1].ceiling), (1, 0));
        assert!(
            dispatch(
                vec![(None, 0)],
                &control,
                |value| value,
                |_| false,
                |_, _| {},
                |_| {}
            )
            .is_err()
        );
        assert!(!control.snapshot().active);
    }
}
