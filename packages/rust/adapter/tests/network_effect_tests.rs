// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use neco_quotient_retention::{ErasureDecision, RetentionReason};
use necoherence::network_effect::{observe as observe_network, *};
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use std::sync::Arc;

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
                    value: vec![1u8],
                },
                RawHeaderField {
                    name: "x-test".into(),
                    value: vec![2u8],
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
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(input()))
    else {
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
                value: vec![4u8, 2u8],
            }],
            body: vec![1u8, 2u8],
        },
        provenance: HeaderProvenance::LibraryNormalized,
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::ProtocolWitnessMissing,
        },
    }
}

#[test]
fn construction_rejects_a_delivery_on_a_prepared_record() {
    let attempt = input().attempt;
    let built = network_state_of(vec![AttemptRecord {
        input: Arc::new(input()),
        chain: AttemptChain::Root,
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
    }]);
    assert_eq!(
        built,
        Err(NetworkStateViolation::DeliveryLogMismatch { attempt })
    );
}

#[test]
fn full_prepared_relation_rejects_a_single_field_mutation() -> TestResult {
    let PrepareStep::Prepared(state, mut prepared) =
        prepare(NetworkState::default(), Arc::new(input()))
    else {
        return Err("prepare".into());
    };
    Arc::make_mut(&mut prepared.input)
        .instruction
        .headers
        .swap(0, 1);
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
    let PrepareStep::Prepared(prepared_state, prepared) =
        prepare(NetworkState::default(), Arc::new(input()))
    else {
        return Err("prepare".into());
    };
    let mut unknown = prepared.clone();
    Arc::make_mut(&mut unknown.input).attempt.ordinal = 9u8.into();
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
        from: prepared.input.attempt.clone(),
        next,
        protocol_evidence: OpaqueEvidence {
            value: "retry-rule".into(),
        },
    };
    let request = RetryRequest {
        permission: RetryPermission::RetryAllowed {
            authorization: authorization.clone(),
        },
        instruction: prepared.input.instruction.clone(),
        deadline: prepared.input.deadline.clone(),
        configuration: prepared.input.configuration.clone(),
    };
    let PrepareStep::Prepared(retried, retry_prepared) = retry(state, request.clone()) else {
        return Err("retry".into());
    };
    assert_eq!(network_attempts(&retried).len(), 2);
    assert_eq!(
        retry_prepared.chain,
        AttemptChain::RetryOf { authorization }
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

fn settled_record(attempt: AttemptIdentity, chain: AttemptChain) -> AttemptRecord {
    AttemptRecord {
        input: Arc::new(AttemptInput { attempt, ..input() }),
        chain,
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

fn prepared_record(attempt: AttemptIdentity, chain: AttemptChain) -> AttemptRecord {
    AttemptRecord {
        input: Arc::new(AttemptInput { attempt, ..input() }),
        chain,
        disposition: AttemptDisposition::Prepared,
        first_delivery: None,
        late: vec![],
    }
}

#[test]
fn retry_authorization_from_a_different_logical_is_rejected_as_chain_mismatch() {
    let l = logical("L");
    let m = logical("M");
    let l0 = attempt_identity(l.clone(), 0);
    let m0 = attempt_identity(m.clone(), 0);
    let m1 = attempt_identity(m.clone(), 1);
    let l2 = attempt_identity(l.clone(), 2);

    let l0_record = settled_record(l0.clone(), AttemptChain::Root);
    let m0_record = settled_record(m0.clone(), AttemptChain::Root);
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
        AttemptChain::RetryOf {
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
        AttemptChain::RetryOf {
            authorization: l2_authorization,
        },
    );

    assert_eq!(
        network_state_of(vec![l0_record, m0_record, m1_record, l2_record]),
        Err(NetworkStateViolation::ChainMismatch { attempt: l2 })
    );
}

type HostRecordDecision = ErasureDecision<AttemptIdentity, (), (), (), HostRecordObservation>;

fn host_record_reasons(
    decision: HostRecordDecision,
) -> Option<Vec<RetentionReason<AttemptIdentity, (), HostRecordObservation>>> {
    match decision {
        ErasureDecision::Retain(reasons) => Some(reasons),
        _ => None,
    }
}

fn settled_state() -> Result<(NetworkState, AttemptIdentity), &'static str> {
    let (state, _, started) = started()?;
    let key = started.prepared.input.attempt.clone();
    let NetworkStep::Terminal(state, _) = observe_network(
        state,
        HostObservation::Delivered {
            delivery: 0u8.into(),
            observation: response(&started, None),
        },
    ) else {
        return Err("terminal");
    };
    Ok((state, key))
}

#[test]
fn started_record_is_retained_only_for_future_use() -> TestResult {
    let (state, _, started) = started()?;
    let key = started.prepared.input.attempt.clone();
    assert!(host_awaits(&state, &key));
    assert!(!host_settled(&state, &key));
    let reasons = host_record_reasons(release_host_record(&state, |_| false, &key));
    assert_eq!(reasons, Some(vec![RetentionReason::FutureUse(key)]));
    Ok(())
}

#[test]
fn settled_record_with_a_running_worker_is_retained_only_for_the_outstanding_effect() -> TestResult
{
    let (state, key) = settled_state()?;
    assert!(!host_awaits(&state, &key));
    assert!(host_settled(&state, &key));
    let reasons = host_record_reasons(release_host_record(&state, |_| true, &key));
    assert_eq!(reasons, Some(vec![RetentionReason::OutstandingEffect(key)]));
    Ok(())
}

#[test]
fn settled_record_without_a_running_worker_may_be_discarded() -> TestResult {
    let (state, key) = settled_state()?;
    let ErasureDecision::Dematerialize(witness) = release_host_record(&state, |_| false, &key)
    else {
        return Err("dematerialize".into());
    };
    assert_eq!(witness.target, key);
    assert_eq!(
        witness.removed_observations,
        vec![
            HostRecordObservation::Undelivered,
            HostRecordObservation::DeliveryOrdinal
        ]
    );
    Ok(())
}

#[test]
fn missing_record_without_a_running_worker_may_be_discarded() {
    let key = input().attempt;
    let state = NetworkState::default();
    assert!(!host_awaits(&state, &key));
    assert!(!host_settled(&state, &key));
    assert!(matches!(
        release_host_record(&state, |_| false, &key),
        ErasureDecision::Dematerialize(_)
    ));
}
