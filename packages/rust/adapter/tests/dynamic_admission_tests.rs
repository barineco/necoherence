// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use neco_quotient_retention::{Recoverability, RetentionReason};
use necoherence::request_progression::ExecutionHandle;
use necoherence::AdmissionSignal;
use necoherence::{
    admission_state_of, admit_dynamic_request, decide_cancel, elide_admission_provenance, empty,
    submit, AdmissionProvenance, CancelDecisionResult, CapacityObservation, ConfiguredSafetyLimit,
    DynamicAdmissionFailure, DynamicAdmissionInput, DynamicAdmissionState,
    EnvironmentSpecification, ErasureWitness, EvidenceVersion, MeaningPermission, Nat, Outcome2,
    PermissionDenial, ProvenanceObservation, RequestEffectClass, RequestFootprint, RequestIdentity,
    RequestInput, RequestPolicy, ResourceBudget, ResourceDemand, SignalKind, SubmitResult,
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
    admission_state_of(
        empty(RequestPolicy::Fifo, progression_budget.clone()),
        progression_budget,
        AdmissionProvenance {
            future_uses: vec![],
            outstanding_signals: vec![],
        },
    )
}

proptest! {
    #[test]
    fn expired_observation_is_rejected(age in 11u64..30) {
        let b = budget(10, 10, 10);
        let held = state(b.clone());
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            request: request("a", 0),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(10) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(age),
            start: None,
        };
        match admit_dynamic_request(held, &input).1 {
            Outcome2::Rejected(DynamicAdmissionFailure::CapacityObservationUnavailable(..)) => {}
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn fresh_request_within_budget_is_submitted(revision in 0u64..10) {
        let b = budget(10, 10, 10);
        let held = state(b.clone());
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(held, &input).1 {
            Outcome2::Applied(result) => {
                prop_assert!(matches!(result.admission_decision, necoherence::AdmissionDecision::Submitted(..)));
            }
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn pending_limit_exceeded_is_rejected(revision in 0u64..10) {
        let b = budget(0, 10, 10);
        let held = state(b.clone());
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(held, &input).1 {
            Outcome2::Rejected(DynamicAdmissionFailure::ConfiguredSafetyLimitExceeded(..)) => {}
            other => prop_assert!(false, "unexpected {other:?}"),
        }
    }

    #[test]
    fn duplicate_pending_request_coalesces_idempotently(revision in 0u64..10) {
        let b = budget(10, 10, 10);
        let progression = empty(RequestPolicy::Fifo, b.clone());
        let SubmitResult::Accepted(progression2, _) = submit(progression, &request("a", revision)) else {
            panic!("expected accepted")
        };
        let s = admission_state_of(
            progression2,
            b.clone(),
            AdmissionProvenance { future_uses: vec![], outstanding_signals: vec![] },
        );
        let held = s;
        let input: DynamicAdmissionInput = DynamicAdmissionInput {
            request: request("a", revision),
            environment_specification: EnvironmentSpecification { max_observation_age: nat(100) },
            capacity_observation: CapacityObservation { observed: b, observed_at: nat(0) },
            observed_at: nat(0),
            start: None,
        };
        match admit_dynamic_request(held, &input).1 {
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
    let held = state(b.clone());
    let input: DynamicAdmissionInput = DynamicAdmissionInput {
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
    match admit_dynamic_request(held, &input).1 {
        Outcome2::Rejected(DynamicAdmissionFailure::MeaningDenied(..)) => {}
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn unknown_identity_erasure_is_rejected() {
    let b = budget(10, 10, 10);
    let s = state(b);
    match elide_admission_provenance(s, &identity("ghost", 0)).1 {
        Outcome2::Rejected(DynamicAdmissionFailure::UnknownRequest(_)) => {}
        other => panic!("unexpected {other:?}"),
    }
}

fn cancelled_state(provenance: AdmissionProvenance) -> (DynamicAdmissionState, RequestIdentity) {
    let b = budget(10, 10, 10);
    let progression = empty(RequestPolicy::Fifo, b.clone());
    let SubmitResult::Accepted(progression2, accepted) = submit(progression, &request("a", 0))
    else {
        panic!("expected accepted")
    };
    let cancel_result = decide_cancel(progression2, &accepted.identity);
    let CancelDecisionResult::Cancelled(progression3, ident) = cancel_result else {
        panic!("expected cancelled")
    };
    (admission_state_of(progression3, b, provenance), ident)
}

fn signal_of(ident: &RequestIdentity) -> AdmissionSignal {
    AdmissionSignal {
        identity: ident.clone(),
        handle: ExecutionHandle { value: "h0".into() },
        kind: SignalKind::PendingCompletion,
    }
}

#[test]
fn terminal_entry_with_no_provenance_erases() {
    let (s, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![],
        outstanding_signals: vec![],
    });
    let expected: ErasureWitness = neco_quotient_retention::DematerializeWitness {
        target: ident.clone(),
        recoverability: Recoverability::Irrecoverable,
        removed_observations: vec![
            ProvenanceObservation::Footprint,
            ProvenanceObservation::Evidence,
        ],
    };
    match elide_admission_provenance(s, &ident).1 {
        Outcome2::Applied(witness) => assert_eq!(witness, expected),
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn terminal_entry_with_future_use_is_retained() {
    let (_, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![],
        outstanding_signals: vec![],
    });
    let (s, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![ident.clone()],
        outstanding_signals: vec![],
    });
    match elide_admission_provenance(s, &ident).1 {
        Outcome2::Rejected(DynamicAdmissionFailure::ProvenanceRetentionRequired(id, reasons)) => {
            assert_eq!(id, ident);
            assert_eq!(reasons, vec![RetentionReason::FutureUse(ident)]);
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn terminal_entry_with_outstanding_signal_is_retained() {
    let (_, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![],
        outstanding_signals: vec![],
    });
    let (s, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![],
        outstanding_signals: vec![signal_of(&ident)],
    });
    match elide_admission_provenance(s, &ident).1 {
        Outcome2::Rejected(DynamicAdmissionFailure::ProvenanceRetentionRequired(id, reasons)) => {
            assert_eq!(id, ident);
            assert_eq!(reasons, vec![RetentionReason::OutstandingSignal(ident)]);
        }
        other => panic!("unexpected {other:?}"),
    }
}

#[test]
fn terminal_entry_with_future_use_and_signal_lists_both_reasons_in_order() {
    let (_, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![],
        outstanding_signals: vec![],
    });
    let (s, ident) = cancelled_state(AdmissionProvenance {
        future_uses: vec![ident.clone()],
        outstanding_signals: vec![signal_of(&ident)],
    });
    match elide_admission_provenance(s, &ident).1 {
        Outcome2::Rejected(DynamicAdmissionFailure::ProvenanceRetentionRequired(id, reasons)) => {
            assert_eq!(id, ident);
            assert_eq!(
                reasons,
                vec![
                    RetentionReason::FutureUse(ident.clone()),
                    RetentionReason::OutstandingSignal(ident)
                ]
            );
        }
        other => panic!("unexpected {other:?}"),
    }
}
