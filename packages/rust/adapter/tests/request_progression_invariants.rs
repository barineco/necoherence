// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    apply_completion_observation, apply_start_observation, decide_cancel, decide_start,
    derive_concurrent, derive_in_flight, derive_pending, empty, progression_budget,
    progression_current_identity, progression_entries, progression_policy, progression_revision,
    snapshot_of, submit, Accepted, AdapterFailure, AdapterResult, AdapterSignal,
    CancelDecisionResult, CompletionObservationResult, ConfiguredSafetyLimit, CostSelection,
    EvidenceVersion, ExecutionHandle, MeaningPermission, Nat, RequestEffectClass, RequestEntry,
    RequestFootprint, RequestIdentity, RequestInput, RequestPhase, RequestPolicy,
    RequestProgressionSnapshot, ResourceBudget, ResourceDemand, Running, SnapshotFailure,
    StartDecisionFailure, StartDecisionResult, StartObservationResult, Starting, SubmitResult,
};
use proptest::prelude::*;

#[derive(Clone, Debug)]
enum Step {
    Submit(u8, bool, u8),
    DecideStart(u8, bool),
    ObserveStart(u8, u8),
    ObserveCompletion(u8, u8),
    Cancel(u8),
}

fn identity(index: u8) -> RequestIdentity {
    RequestIdentity {
        kind: "k".into(),
        provenance: format!("p{index}"),
        revision: Nat::from(index),
    }
}

fn handle(index: u8) -> ExecutionHandle {
    ExecutionHandle {
        value: format!("h{index}").into(),
    }
}

fn evidence() -> EvidenceVersion {
    EvidenceVersion {
        identifier: "e".into(),
        digest: "d".into(),
        artifact_path: "a".into(),
    }
}

fn limit(maximum: u64) -> ConfiguredSafetyLimit {
    ConfiguredSafetyLimit {
        resource: "r".into(),
        maximum: Nat::from(maximum),
    }
}

fn budget() -> ResourceBudget {
    ResourceBudget {
        pending_maximum: limit(12),
        in_flight_maximum: limit(9),
        concurrent_maximum: limit(6),
    }
}

fn request(index: u8, ordered: bool, weight: u8) -> RequestInput {
    let effect_class = if ordered {
        RequestEffectClass::OrderedEffect
    } else {
        RequestEffectClass::Pure
    };
    let permission = if ordered {
        MeaningPermission::Ordered(identity(index), vec![evidence()])
    } else {
        MeaningPermission::Permitted(identity(index), vec![evidence()])
    };
    RequestInput {
        identity: identity(index),
        footprint: RequestFootprint {
            reads: vec![],
            writes: vec![],
            effect_class,
        },
        demand: ResourceDemand {
            pending: Nat::from(weight),
            in_flight: Nat::from(weight + 1),
            concurrent: Nat::from(weight + 2),
        },
        permission,
    }
}

fn policy() -> impl Strategy<Value = RequestPolicy> {
    prop_oneof![
        Just(RequestPolicy::LatestWins),
        Just(RequestPolicy::Fifo),
        Just(RequestPolicy::AllExecute),
    ]
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        (0u8..6, any::<bool>(), 0u8..3).prop_map(|(i, o, w)| Step::Submit(i, o, w)),
        (0u8..6, any::<bool>()).prop_map(|(i, e)| Step::DecideStart(i, e)),
        (0u8..6, 0u8..3).prop_map(|(i, s)| Step::ObserveStart(i, s)),
        (0u8..6, 0u8..3).prop_map(|(i, s)| Step::ObserveCompletion(i, s)),
        (0u8..6).prop_map(Step::Cancel),
    ]
}

fn apply_step(snapshot: RequestProgressionSnapshot, step: &Step) -> RequestProgressionSnapshot {
    match step {
        Step::Submit(index, ordered, weight) => {
            match submit(snapshot, &request(*index, *ordered, *weight)) {
                SubmitResult::Accepted(next, _) | SubmitResult::SubmitRejected(next, _) => next,
            }
        }
        Step::DecideStart(index, execute) => {
            let selection = if *execute {
                CostSelection::ExecuteNow(identity(*index), evidence(), Nat::from(0u8))
            } else {
                CostSelection::RemainPending(identity(*index), evidence(), Nat::from(0u8))
            };
            let accepted = Accepted {
                identity: identity(*index),
            };
            match decide_start(snapshot, &accepted, &selection) {
                StartDecisionResult::Execute(next, _, _)
                | StartDecisionResult::Deferred(next, _)
                | StartDecisionResult::Rejected(next, _) => next,
            }
        }
        Step::ObserveStart(index, signal) => {
            let starting = Starting {
                identity: identity(*index),
                command: necoherence::AdapterCommand::StartCommand(
                    identity(*index),
                    request(*index, false, 0).footprint,
                ),
            };
            let observed: AdapterResult<AdapterSignal<u8>, AdapterFailure> = match signal {
                0 => AdapterResult::AppliedSignal(AdapterSignal::Started(
                    identity(*index),
                    handle(*index),
                )),
                1 => AdapterResult::AppliedSignal(AdapterSignal::Started(
                    identity(index.wrapping_add(1)),
                    handle(*index),
                )),
                _ => AdapterResult::AdapterFailed(AdapterFailure::StartAdapterFailure(
                    identity(*index),
                    "f".into(),
                )),
            };
            match apply_start_observation(snapshot, &starting, &observed) {
                StartObservationResult::Publishing(next, _)
                | StartObservationResult::Failed(next, _) => next,
            }
        }
        Step::ObserveCompletion(index, signal) => {
            let running = Running {
                identity: identity(*index),
                handle: handle(*index),
            };
            let observed: AdapterResult<AdapterSignal<u8>, AdapterFailure> = match signal {
                0 => AdapterResult::AppliedSignal(AdapterSignal::Completed(
                    identity(*index),
                    handle(*index),
                    *index,
                )),
                1 => AdapterResult::AppliedSignal(AdapterSignal::CancelledAtAdapter(
                    identity(*index),
                    handle(*index),
                )),
                _ => AdapterResult::AdapterFailed(AdapterFailure::CompletionAdapterFailure(
                    identity(*index),
                    handle(*index),
                    "f".into(),
                )),
            };
            match apply_completion_observation(snapshot, &running, &observed) {
                CompletionObservationResult::Applied(next, _, _)
                | CompletionObservationResult::Superseded(next, _)
                | CompletionObservationResult::Cancelled(next, _)
                | CompletionObservationResult::Failed(next, _) => next,
            }
        }
        Step::Cancel(index) => match decide_cancel(snapshot, &identity(*index)) {
            CancelDecisionResult::Cancelled(next, _)
            | CancelDecisionResult::CancelCommand(next, _, _)
            | CancelDecisionResult::Rejected(next, _) => next,
        },
    }
}

fn summed(entries: &[RequestEntry], phases: &[RequestPhase]) -> ResourceDemand {
    let mut total = ResourceDemand {
        pending: Nat::from(0u8),
        in_flight: Nat::from(0u8),
        concurrent: Nat::from(0u8),
    };
    for entry in entries.iter().filter(|entry| phases.contains(&entry.phase)) {
        total.pending += &entry.demand.pending;
        total.in_flight += &entry.demand.in_flight;
        total.concurrent += &entry.demand.concurrent;
    }
    total
}

fn first_pending(snapshot: &RequestProgressionSnapshot) -> Option<RequestIdentity> {
    progression_entries(snapshot)
        .iter()
        .find(|entry| entry.phase == RequestPhase::Pending)
        .map(|entry| entry.identity.clone())
}

proptest! {
    #[test]
    fn generated_operation_sequences_keep_the_snapshot_invariant(
        policy in policy(),
        steps in prop::collection::vec(step(), 0..40),
    ) {
        let mut snapshot = empty(policy, budget());
        for step in &steps {
            snapshot = apply_step(snapshot, step);
            let rebuilt = snapshot_of(
                progression_policy(&snapshot),
                progression_budget(&snapshot).clone(),
                progression_current_identity(&snapshot).cloned(),
                progression_entries(&snapshot).to_vec(),
                progression_revision(&snapshot).clone(),
            );
            prop_assert_eq!(rebuilt.as_ref(), Ok(&snapshot));
            let entries = progression_entries(&snapshot);
            prop_assert_eq!(derive_pending(&snapshot), summed(entries, &[RequestPhase::Pending]));
            prop_assert_eq!(
                derive_in_flight(&snapshot),
                summed(entries, &[RequestPhase::Preparing, RequestPhase::Publishing])
            );
            prop_assert_eq!(derive_concurrent(&snapshot), summed(entries, &[RequestPhase::Publishing]));
        }
    }

    #[test]
    fn fifo_start_is_blocked_exactly_for_pending_entries_after_the_first(
        steps in prop::collection::vec(step(), 0..40),
        candidate in 0u8..6,
    ) {
        let mut snapshot = empty(RequestPolicy::Fifo, budget());
        for step in &steps {
            snapshot = apply_step(snapshot, step);
        }
        let held = progression_entries(&snapshot)
            .iter()
            .find(|entry| entry.identity == identity(candidate))
            .cloned();
        let first = first_pending(&snapshot);
        let selection = CostSelection::RemainPending(identity(candidate), evidence(), Nat::from(0u8));
        let decided = decide_start(snapshot, &Accepted { identity: identity(candidate) }, &selection);
        let blocked = matches!(
            decided,
            StartDecisionResult::Rejected(_, StartDecisionFailure::PolicyOrderBlocked(_))
        );
        let pending = held.as_ref().is_some_and(|entry| entry.phase == RequestPhase::Pending);
        let ordered_blocked = held.as_ref().is_some_and(|entry| {
            entry.footprint.effect_class == RequestEffectClass::OrderedEffect
        });
        if pending && !ordered_blocked {
            prop_assert_eq!(blocked, first != Some(identity(candidate)));
        }
    }
}

#[test]
fn construction_rejects_duplicate_identities() {
    let entry = |phase| RequestEntry {
        identity: identity(0),
        footprint: request(0, false, 0).footprint,
        demand: request(0, false, 0).demand,
        phase,
        meaning_permission: request(0, false, 0).permission,
        cost_selection: None,
        execution_handle: None,
    };
    let built = snapshot_of(
        RequestPolicy::Fifo,
        budget(),
        None,
        vec![entry(RequestPhase::Pending), entry(RequestPhase::Failed)],
        Nat::from(0u8),
    );
    assert_eq!(built, Err(SnapshotFailure::DuplicateIdentity(identity(0))));
}
