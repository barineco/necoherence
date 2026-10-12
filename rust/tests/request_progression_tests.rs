// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    apply_completion_observation, apply_start_observation, decide_cancel, decide_start,
    derive_concurrent, derive_in_flight, derive_pending, empty, submit, AdapterCommand,
    AdapterFailure, AdapterResult, AdapterSignal, CancelDecisionResult, CancelFailure,
    CompletionObservationResult, ConfiguredSafetyLimit, CostSelection, EvidenceVersion,
    ExecutionHandle, MeaningPermission, Nat, PermissionDenial, RequestEffectClass,
    RequestFootprint, RequestIdentity, RequestInput, RequestPhase, RequestPolicy, ResourceBudget,
    ResourceDemand, StartDecisionResult, StartObservationResult, SubmitResult,
};

fn nat(n: u64) -> Nat {
    n.into()
}
fn identity(name: &str, revision: u64) -> RequestIdentity {
    RequestIdentity {
        kind: "test".into(),
        provenance: name.into(),
        revision: nat(revision),
    }
}
fn evidence() -> EvidenceVersion {
    EvidenceVersion {
        identifier: "id".into(),
        digest: "digest".into(),
        artifact_path: "path".into(),
    }
}
fn budget(p: u64, f: u64, c: u64) -> ResourceBudget {
    ResourceBudget {
        pending_maximum: ConfiguredSafetyLimit {
            resource: "r".into(),
            maximum: nat(p),
        },
        in_flight_maximum: ConfiguredSafetyLimit {
            resource: "r".into(),
            maximum: nat(f),
        },
        concurrent_maximum: ConfiguredSafetyLimit {
            resource: "r".into(),
            maximum: nat(c),
        },
    }
}
fn request(name: &str, revision: u64) -> RequestInput {
    let identity = identity(name, revision);
    RequestInput {
        identity: identity.clone(),
        footprint: RequestFootprint {
            reads: vec![],
            writes: vec![],
            effect_class: RequestEffectClass::Pure,
        },
        demand: ResourceDemand {
            pending: nat(1),
            in_flight: nat(1),
            concurrent: nat(1),
        },
        permission: MeaningPermission::Permitted(identity, vec![evidence()]),
    }
}
fn selected(identity: &RequestIdentity) -> CostSelection {
    CostSelection::ExecuteNow(identity.clone(), evidence(), nat(0))
}

#[test]
fn decision_then_start_and_completion_observations_progress_causally() {
    let initial = empty(RequestPolicy::Fifo, budget(10, 10, 10));
    let req = request("a", 0);
    let SubmitResult::Accepted(submitted, accepted) = submit(&initial, &req) else {
        panic!()
    };
    let StartDecisionResult::Execute(preparing, starting, AdapterCommand::StartCommand(_, _)) =
        decide_start(&submitted, &accepted, &selected(&accepted.identity))
    else {
        panic!()
    };
    assert_eq!(preparing.entries[0].phase, RequestPhase::Preparing);
    let handle = ExecutionHandle { value: "h".into() };
    let StartObservationResult::Publishing(publishing, running) = apply_start_observation::<i64>(
        &preparing,
        &starting,
        &AdapterResult::AppliedSignal(AdapterSignal::Started(
            accepted.identity.clone(),
            handle.clone(),
        )),
    ) else {
        panic!()
    };
    assert_eq!(publishing.entries[0].phase, RequestPhase::Publishing);
    let CompletionObservationResult::Applied(published, identity, value) =
        apply_completion_observation(
            &publishing,
            &running,
            &AdapterResult::AppliedSignal(AdapterSignal::Completed(
                running.identity.clone(),
                handle,
                42,
            )),
        )
    else {
        panic!()
    };
    assert_eq!(value, 42);
    assert_eq!(identity, accepted.identity);
    assert_eq!(published.entries[0].phase, RequestPhase::Published);
}

#[test]
fn start_observation_failure_closes_preparing_entry() {
    let initial = empty(RequestPolicy::Fifo, budget(10, 10, 10));
    let req = request("a", 0);
    let SubmitResult::Accepted(submitted, accepted) = submit(&initial, &req) else {
        panic!()
    };
    let StartDecisionResult::Execute(preparing, starting, _) =
        decide_start(&submitted, &accepted, &selected(&accepted.identity))
    else {
        panic!()
    };
    let StartObservationResult::Failed(failed, _) = apply_start_observation::<()>(
        &preparing,
        &starting,
        &AdapterResult::AdapterFailed(AdapterFailure::StartAdapterFailure(
            accepted.identity.clone(),
            "no".into(),
        )),
    ) else {
        panic!()
    };
    assert_eq!(failed.entries[0].phase, RequestPhase::Failed);
}

#[test]
fn latest_wins_stale_completion_is_superseded_without_altering_new_request() {
    let initial = empty(RequestPolicy::LatestWins, budget(10, 10, 10));
    let SubmitResult::Accepted(one, accepted) = submit(&initial, &request("a", 1)) else {
        panic!()
    };
    let StartDecisionResult::Execute(preparing, starting, _) =
        decide_start(&one, &accepted, &selected(&accepted.identity))
    else {
        panic!()
    };
    let handle = ExecutionHandle { value: "h".into() };
    let StartObservationResult::Publishing(running_snapshot, running) =
        apply_start_observation::<i64>(
            &preparing,
            &starting,
            &AdapterResult::AppliedSignal(AdapterSignal::Started(
                accepted.identity.clone(),
                handle.clone(),
            )),
        )
    else {
        panic!()
    };
    let SubmitResult::Accepted(newer, _) = submit(&running_snapshot, &request("b", 2)) else {
        panic!()
    };
    let CompletionObservationResult::Superseded(result, _) = apply_completion_observation(
        &newer,
        &running,
        &AdapterResult::AppliedSignal(AdapterSignal::Completed(
            running.identity.clone(),
            handle,
            1,
        )),
    ) else {
        panic!()
    };
    assert_eq!(
        result
            .entries
            .iter()
            .find(|entry| entry.identity.provenance == "b")
            .unwrap()
            .phase,
        RequestPhase::Pending
    );
}

#[test]
fn cancel_pending_is_immediate_and_preparing_is_missing_handle() {
    let initial = empty(RequestPolicy::Fifo, budget(10, 10, 10));
    let req = request("a", 0);
    let SubmitResult::Accepted(submitted, accepted) = submit(&initial, &req) else {
        panic!()
    };
    let CancelDecisionResult::Cancelled(cancelled, _) =
        decide_cancel(&submitted, &accepted.identity)
    else {
        panic!()
    };
    assert_eq!(cancelled.entries[0].phase, RequestPhase::Cancelled);
    let SubmitResult::Accepted(submitted, accepted) = submit(&initial, &request("b", 1)) else {
        panic!()
    };
    let StartDecisionResult::Execute(preparing, _, _) =
        decide_start(&submitted, &accepted, &selected(&accepted.identity))
    else {
        panic!()
    };
    assert!(matches!(
        decide_cancel(&preparing, &accepted.identity),
        CancelDecisionResult::Rejected(_, CancelFailure::MissingExecutionHandle(_))
    ));
}

#[test]
fn derived_demands_follow_phases_and_denied_permission_rejects_decision() {
    let initial = empty(RequestPolicy::Fifo, budget(10, 10, 10));
    let req = request("a", 0);
    let SubmitResult::Accepted(submitted, accepted) = submit(&initial, &req) else {
        panic!()
    };
    assert_eq!(derive_pending(&submitted).pending, nat(1));
    let StartDecisionResult::Execute(preparing, _, _) =
        decide_start(&submitted, &accepted, &selected(&accepted.identity))
    else {
        panic!()
    };
    assert_eq!(derive_in_flight(&preparing).in_flight, nat(1));
    assert_eq!(derive_concurrent(&preparing).concurrent, nat(0));
    let denied = RequestInput {
        permission: MeaningPermission::Denied(
            identity("d", 2),
            PermissionDenial::Denial("no".into()),
        ),
        ..request("d", 2)
    };
    let SubmitResult::Accepted(snapshot, accepted) = submit(&initial, &denied) else {
        panic!()
    };
    assert!(matches!(
        decide_start(&snapshot, &accepted, &selected(&accepted.identity)),
        StartDecisionResult::Rejected(_, _)
    ));
}
