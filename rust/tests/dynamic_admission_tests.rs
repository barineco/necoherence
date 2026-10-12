// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    admit_dynamic_request, decide_cancel, elide_admission_provenance, empty, submit,
    AdmissionProvenance, CancelDecisionResult, CapacityObservation, ConfiguredSafetyLimit,
    DynamicAdmissionFailure, DynamicAdmissionInput, DynamicAdmissionState,
    EnvironmentSpecification, EvidenceVersion, MeaningPermission, Nat, Outcome2, PermissionDenial,
    ProvenanceErasureWitness, RequestEffectClass, RequestFootprint, RequestIdentity, RequestInput,
    RequestPolicy, ResourceBudget, ResourceDemand, SubmitResult,
};
use proptest::prelude::*;

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

fn identity(prov: &str, revision: u64) -> RequestIdentity {
    RequestIdentity {
        kind: "test".to_string(),
        provenance: prov.to_string(),
        revision: nat(revision),
    }
}

fn evidence() -> EvidenceVersion {
    EvidenceVersion {
        identifier: "id".to_string(),
        digest: "digest".to_string(),
        artifact_path: "path".to_string(),
    }
}

fn budget(pending: u64, in_flight: u64, concurrent: u64) -> ResourceBudget {
    ResourceBudget {
        pending_maximum: ConfiguredSafetyLimit {
            resource: "r".to_string(),
            maximum: nat(pending),
        },
        in_flight_maximum: ConfiguredSafetyLimit {
            resource: "r".to_string(),
            maximum: nat(in_flight),
        },
        concurrent_maximum: ConfiguredSafetyLimit {
            resource: "r".to_string(),
            maximum: nat(concurrent),
        },
    }
}

fn request(prov: &str, revision: u64) -> RequestInput {
    let id = identity(prov, revision);
    RequestInput {
        identity: id.clone(),
        footprint: RequestFootprint {
            reads: vec![],
            writes: vec![],
            effect_class: RequestEffectClass::Pure,
        },
        demand: ResourceDemand {
            pending: nat(1),
            in_flight: nat(0),
            concurrent: nat(0),
        },
        permission: MeaningPermission::Permitted(id, vec![evidence()]),
    }
}

fn state(progression_budget: ResourceBudget) -> DynamicAdmissionState {
    DynamicAdmissionState {
        progression: empty(RequestPolicy::Fifo, progression_budget.clone()),
        configured_safety_limit: progression_budget,
        provenance: AdmissionProvenance {
            future_uses: vec![],
            outstanding_signals: vec![],
        },
    }
}

proptest! {
    #[test]
    fn expired_observation_is_rejected(age in 11u64..30) {
        let b = budget(10, 10, 10);
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            state: state(b.clone()),
            request: request("a", 0),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(10) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(age),
            start: None,
        };
        match admit_dynamic_request(&input) {
            Outcome2::Rejected(DynamicAdmissionFailure::CapacityObservationUnavailable(..)) => {}
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn fresh_request_within_budget_is_submitted(revision in 0u64..10) {
        let b = budget(10, 10, 10);
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            state: state(b.clone()),
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(&input) {
            Outcome2::Applied(result) => {
                prop_assert!(matches!(result.admission_decision, necoherence::AdmissionDecision::Submitted(..)));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn pending_limit_exceeded_is_rejected(revision in 0u64..10) {
        let b = budget(0, 10, 10);
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            state: state(b.clone()),
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(&input) {
            Outcome2::Rejected(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(..)) => {}
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn duplicate_pending_request_coalesces_idempotently(revision in 0u64..10) {
        let b = budget(10, 10, 10);
        let progression = empty(RequestPolicy::Fifo, b.clone());
        let SubmitResult::Accepted(progression2, _) = submit(&progression, &request("a", revision)) else {
            panic!("expected accepted")
        };
        let s = DynamicAdmissionState {
            progression: progression2,
            configured_safety_limit: b.clone(),
            provenance: AdmissionProvenance { future_uses: vec![], outstanding_signals: vec![] },
        };
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            state: s,
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(&input) {
            Outcome2::Applied(result) => {
                prop_assert!(matches!(result.coalescing_witness, necoherence::CoalescingWitness::Coalesced(_)));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }
}

#[test]
fn denied_permission_is_rejected() {
    let b = budget(10, 10, 10);
    let id = identity("a", 0);
    let req = RequestInput {
        identity: id.clone(),
        footprint: RequestFootprint {
            reads: vec![],
            writes: vec![],
            effect_class: RequestEffectClass::Pure,
        },
        demand: ResourceDemand {
            pending: nat(1),
            in_flight: nat(0),
            concurrent: nat(0),
        },
        permission: MeaningPermission::Denied(id, PermissionDenial::Denial("no".to_string())),
    };
    let input: DynamicAdmissionInput = DynamicAdmissionInput {
        state: state(b.clone()),
        request: req,
        environment_specification: EnvironmentSpecification {
            max_observation_age: nat(100),
        },
        capacity_observation: CapacityObservation {
            observed: b,
            observed_at: nat(0),
        },
        observed_at: nat(0),
        start: None,
    };
    match admit_dynamic_request(&input) {
        Outcome2::Rejected(DynamicAdmissionFailure::MeaningDenied(..)) => {}
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn unknown_identity_erasure_is_rejected() {
    let b = budget(10, 10, 10);
    let s = state(b);
    match elide_admission_provenance(&s, &identity("ghost", 0)) {
        Outcome2::Rejected(DynamicAdmissionFailure::UnknownRequest(_)) => {}
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn terminal_entry_with_no_provenance_erases() {
    let b = budget(10, 10, 10);
    let progression = empty(RequestPolicy::Fifo, b.clone());
    let SubmitResult::Accepted(progression2, accepted) = submit(&progression, &request("a", 0))
    else {
        panic!("expected accepted")
    };
    let cancel_result = decide_cancel(&progression2, &accepted.identity);
    let CancelDecisionResult::Cancelled(progression3, ident) = cancel_result else {
        panic!("expected cancelled")
    };
    let s = DynamicAdmissionState {
        progression: progression3,
        configured_safety_limit: b,
        provenance: AdmissionProvenance {
            future_uses: vec![],
            outstanding_signals: vec![],
        },
    };
    match elide_admission_provenance(&s, &ident) {
        Outcome2::Applied((_, ProvenanceErasureWitness::Erased(_))) => {}
        other => panic!("unexpected {other:?}"),
    }
}
