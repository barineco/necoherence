// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::network_effect::{observe as observe_network, *};
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn identity() -> RequestIdentity {
    RequestIdentity {
        kind: "test".into(),
        provenance: "generated".into(),
        revision: 0u8.into(),
    }
}

fn input() -> AttemptInput {
    AttemptInput {
        attempt: AttemptIdentity {
            logical: identity(),
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".into(),
            target: "http://127.0.0.1/".into(),
            headers: vec![
                RawHeaderField {
                    name: "x-test".into(),
                    value: vec![1u8.into()],
                },
                RawHeaderField {
                    name: "x-test".into(),
                    value: vec![2u8.into()],
                },
            ],
            body: vec![],
        },
        deadline: None,
        configuration: HostConfiguration {
            request_body_limit: 16u8.into(),
            response_body_limit: 16u8.into(),
            cancellation: None,
            monotonic_clock: None,
        },
    }
}

fn started() -> Result<(NetworkState, PreparedAttempt, StartedAttempt), &'static str> {
    let PrepareStep::Prepared(state, prepared) = prepare(NetworkState::default(), input()) else {
        return Err("prepare");
    };
    let CommandStep::CommandReady(state, _) = send_command(state, prepared.clone()) else {
        return Err("send");
    };
    let handle = ExecutionHandle { value: "h".into() };
    let NetworkStep::Started(state, started) = observe_start(
        state,
        prepared.clone(),
        StartObservation::Started {
            attempt: prepared.input.attempt.clone(),
            handle,
        },
    ) else {
        return Err("start");
    };
    Ok((state, prepared, started))
}

fn response(started: &StartedAttempt, source_sequence: SourceSequence) -> AdapterObservation {
    AdapterObservation::ResponseObservation {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle.clone(),
        source_sequence,
        response: RawHttpResponse {
            status: 404u16.into(),
            headers: vec![RawHeaderField {
                name: "x-response".into(),
                value: vec![4u8.into(), 2u8.into()],
            }],
            body: vec![1u8.into(), 2u8.into()],
        },
        provenance: HeaderProvenance::LibraryNormalized,
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::ProtocolWitnessMissing,
        },
    }
}

#[test]
fn invalid_state_is_rejected_without_replacement() {
    let attempt = input().attempt;
    let state = NetworkState {
        attempts: vec![AttemptRecord {
            input: input(),
            lineage: AttemptLineage::Root,
            disposition: AttemptDisposition::Prepared,
            first_delivery: Some(DeliveredObservation {
                delivery: 0u8.into(),
                observation: AdapterObservation::CancellationObservation {
                    attempt: attempt.clone(),
                    handle: ExecutionHandle {
                        value: "wrong".into(),
                    },
                    source_sequence: None,
                    effect: EffectStatus::Unknown {
                        reason: UnknownEffectReason::Cancellation,
                    },
                },
            }),
            late: vec![],
        }],
    };
    let original = state.clone();
    assert!(matches!(
        read_network_state(state),
        ReadStateStep::Rejected(
            rejected,
            NetworkFailure::InvalidNetworkState {
                violation: NetworkStateViolation::DeliveryLogMismatch { attempt: invalid }
            }
        ) if rejected == original && invalid == attempt
    ));
}

#[test]
fn full_prepared_relation_rejects_a_single_field_mutation() -> TestResult {
    let PrepareStep::Prepared(state, mut prepared) = prepare(NetworkState::default(), input())
    else {
        return Err("prepare".into());
    };
    prepared.input.instruction.headers.swap(0, 1);
    let original = state.clone();
    assert!(matches!(
        send_command(state, prepared),
        CommandStep::Rejected(
            rejected,
            NetworkFailure::AttemptTokenMismatch {
                field: AttemptTokenField::Instruction,
                ..
            }
        ) if rejected == original
    ));
    Ok(())
}

#[test]
fn relation_failures_report_the_first_failed_check() -> TestResult {
    let PrepareStep::Prepared(prepared_state, prepared) = prepare(NetworkState::default(), input())
    else {
        return Err("prepare".into());
    };
    let mut unknown = prepared.clone();
    unknown.input.attempt.ordinal = 9u8.into();
    assert!(matches!(
        send_command(prepared_state.clone(), unknown),
        CommandStep::Rejected(_, NetworkFailure::UnknownAttempt { .. })
    ));

    let CommandStep::CommandReady(command_state, _) =
        send_command(prepared_state, prepared.clone())
    else {
        return Err("command".into());
    };
    assert!(matches!(
        send_command(command_state.clone(), prepared.clone()),
        CommandStep::Rejected(_, NetworkFailure::CommandAlreadyIssued { attempt })
            if attempt == prepared.input.attempt
    ));

    let handle = ExecutionHandle {
        value: "authoritative".into(),
    };
    let attempt = prepared.input.attempt.clone();
    let NetworkStep::Started(started_state, started) = observe_start(
        command_state,
        prepared,
        StartObservation::Started {
            attempt,
            handle: handle.clone(),
        },
    ) else {
        return Err("start".into());
    };
    let wrong_handle = ExecutionHandle {
        value: "forged".into(),
    };
    let mut forged_started = started.clone();
    forged_started.handle = wrong_handle.clone();
    assert!(matches!(
        cancel_command(started_state.clone(), forged_started),
        CommandStep::Rejected(
            _,
            NetworkFailure::HandleMismatch {
                expected,
                actual
            }
        ) if expected == handle && actual == wrong_handle
    ));
    assert!(matches!(
        observe_network(
            started_state.clone(),
            HostObservation::Pending {
                attempt: started.prepared.input.attempt.clone(),
                handle: wrong_handle,
            },
        ),
        NetworkStep::Rejected(_, NetworkFailure::HandleMismatch { .. })
    ));

    let malformed = AdapterObservation::ResponseObservation {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle,
        source_sequence: None,
        response: RawHttpResponse {
            status: 99u8.into(),
            headers: vec![],
            body: vec![],
        },
        provenance: HeaderProvenance::LibraryNormalized,
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::ProtocolWitnessMissing,
        },
    };
    assert!(matches!(
        observe_network(
            started_state,
            HostObservation::Delivered {
                delivery: 0u8.into(),
                observation: malformed,
            },
        ),
        NetworkStep::Rejected(_, NetworkFailure::MalformedAdapterObservation)
    ));
    Ok(())
}

#[test]
fn first_late_duplicate_and_conflicting_deliveries_are_distinct() -> TestResult {
    let (state, _, started) = started()?;
    let first = response(&started, Some(7u8.into()));
    let NetworkStep::Terminal(state, settled) = observe_network(
        state,
        HostObservation::Delivered {
            delivery: 0u8.into(),
            observation: first.clone(),
        },
    ) else {
        return Err("terminal".into());
    };
    assert!(matches!(
        settled.terminal.outcome,
        NetworkOutcome::Response {
            response: RawHttpResponse { ref status, .. },
            provenance: HeaderProvenance::LibraryNormalized
        } if status == &Natural::from(404u16)
    ));

    assert!(matches!(
        observe_network(
            state.clone(),
            HostObservation::Delivered {
                delivery: 0u8.into(),
                observation: first.clone(),
            },
        ),
        NetworkStep::Duplicate(_, _, delivery) if delivery == 0u8.into()
    ));

    let conflict = response(&started, Some(8u8.into()));
    assert!(matches!(
        observe_network(
            state.clone(),
            HostObservation::Delivered {
                delivery: 0u8.into(),
                observation: conflict,
            },
        ),
        NetworkStep::Rejected(_, NetworkFailure::ConflictingDelivery { delivery, .. })
            if delivery == 0u8.into()
    ));

    let late = AdapterObservation::CancellationObservation {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle,
        source_sequence: Some(1u8.into()),
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::Cancellation,
        },
    };
    assert!(matches!(
        observe_network(
            state,
            HostObservation::Delivered {
                delivery: 1u8.into(),
                observation: late,
            },
        ),
        NetworkStep::Late(_, preserved, LateObservation { delivered: DeliveredObservation { delivery, .. } })
            if delivery == 1u8.into() && preserved.terminal == settled.terminal
    ));
    Ok(())
}

#[test]
fn effect_annotation_is_monotone_and_retry_authorization_is_one_use() -> TestResult {
    let (state, prepared, started) = started()?;
    let NetworkStep::Terminal(state, _) = observe_network(
        state,
        HostObservation::Delivered {
            delivery: 0u8.into(),
            observation: response(&started, None),
        },
    ) else {
        return Err("terminal".into());
    };
    let witness = EffectWitness {
        attempt: prepared.input.attempt.clone(),
        source: EffectWitnessSource::Protocol,
        evidence: OpaqueEvidence {
            value: "protocol-rule".into(),
        },
    };
    let StateStep::Applied(state) = annotate_effect(
        state,
        EffectObservation {
            attempt: prepared.input.attempt.clone(),
            status: EffectStatus::EffectOccurred {
                witness: witness.clone(),
            },
        },
    ) else {
        return Err("annotation".into());
    };
    assert!(matches!(
        annotate_effect(
            state.clone(),
            EffectObservation {
                attempt: prepared.input.attempt.clone(),
                status: EffectStatus::NoEffect { witness },
            },
        ),
        StateStep::Rejected(_, NetworkFailure::EffectKnowledgeConflict { .. })
    ));

    let next = AttemptIdentity {
        logical: prepared.input.attempt.logical.clone(),
        ordinal: 1u8.into(),
    };
    let authorization = RetryAuthorization {
        logical: prepared.input.attempt.logical.clone(),
        from: prepared.input.attempt,
        next,
        protocol_evidence: OpaqueEvidence {
            value: "retry-rule".into(),
        },
    };
    let request = RetryRequest {
        permission: RetryPermission::RetryAllowed {
            authorization: authorization.clone(),
        },
        instruction: prepared.input.instruction,
        deadline: prepared.input.deadline,
        configuration: prepared.input.configuration,
    };
    let PrepareStep::Prepared(retried, retry_prepared) = retry(state, request.clone()) else {
        return Err("retry".into());
    };
    assert_eq!(retried.attempts.len(), 2);
    assert_eq!(
        retry_prepared.lineage,
        AttemptLineage::RetryOf { authorization }
    );
    assert!(matches!(
        retry(retried.clone(), request),
        PrepareStep::Rejected(rejected, NetworkFailure::RetryNotPermitted { .. }) if rejected == retried
    ));
    Ok(())
}

fn logical(kind: &str) -> RequestIdentity {
    RequestIdentity {
        kind: kind.into(),
        provenance: "generated".into(),
        revision: 0u8.into(),
    }
}

fn attempt_identity(logical: RequestIdentity, ordinal: u8) -> AttemptIdentity {
    AttemptIdentity {
        logical,
        ordinal: ordinal.into(),
    }
}

fn settled_record(attempt: AttemptIdentity, lineage: AttemptLineage) -> AttemptRecord {
    AttemptRecord {
        input: AttemptInput { attempt, ..input() },
        lineage,
        disposition: AttemptDisposition::Settled {
            handle: None,
            terminal: NetworkTerminal {
                outcome: NetworkOutcome::Response {
                    response: RawHttpResponse {
                        status: 200u16.into(),
                        headers: vec![],
                        body: vec![],
                    },
                    provenance: HeaderProvenance::LibraryNormalized,
                },
                effect: EffectStatus::Unknown {
                    reason: UnknownEffectReason::ProtocolWitnessMissing,
                },
            },
        },
        first_delivery: None,
        late: vec![],
    }
}

fn prepared_record(attempt: AttemptIdentity, lineage: AttemptLineage) -> AttemptRecord {
    AttemptRecord {
        input: AttemptInput { attempt, ..input() },
        lineage,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: vec![],
    }
}

#[test]
fn retry_authorization_from_a_different_logical_is_rejected_as_lineage_mismatch() {
    let l = logical("L");
    let m = logical("M");
    let l0 = attempt_identity(l.clone(), 0);
    let m0 = attempt_identity(m.clone(), 0);
    let m1 = attempt_identity(m.clone(), 1);
    let l2 = attempt_identity(l.clone(), 2);

    let l0_record = settled_record(l0.clone(), AttemptLineage::Root);
    let m0_record = settled_record(m0.clone(), AttemptLineage::Root);
    let m1_authorization = RetryAuthorization {
        logical: m.clone(),
        from: m0.clone(),
        next: m1.clone(),
        protocol_evidence: OpaqueEvidence {
            value: "retry-rule".into(),
        },
    };
    let m1_record = settled_record(
        m1.clone(),
        AttemptLineage::RetryOf {
            authorization: m1_authorization,
        },
    );
    let l2_authorization = RetryAuthorization {
        logical: l.clone(),
        from: m1.clone(),
        next: l2.clone(),
        protocol_evidence: OpaqueEvidence {
            value: "retry-rule".into(),
        },
    };
    let l2_record = prepared_record(
        l2.clone(),
        AttemptLineage::RetryOf {
            authorization: l2_authorization,
        },
    );

    let state = NetworkState {
        attempts: vec![l0_record, m0_record, m1_record, l2_record],
    };
    let original = state.clone();
    assert!(matches!(
        read_network_state(state),
        ReadStateStep::Rejected(
            rejected,
            NetworkFailure::InvalidNetworkState {
                violation: NetworkStateViolation::LineageMismatch { attempt: invalid }
            }
        ) if rejected == original && invalid == l2
    ));
}
