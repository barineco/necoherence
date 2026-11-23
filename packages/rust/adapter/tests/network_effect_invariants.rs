// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::unwrap_used)]
use necoherence::network_effect::*;
use necoherence::request_progression::{ExecutionHandle, RequestIdentity};
use proptest::prelude::*;
use std::sync::Arc;

#[derive(Clone, Debug)]
enum Step {
    Prepare(u8, u8),
    Send(u8, u8),
    Start(u8, u8, u8),
    Pending(u8, u8, u8),
    Deliver(u8, u8, u8, u8),
    Annotate(u8, u8, bool),
    Retry(u8, u8),
    Cancel(u8, u8, u8),
    Read,
    Advance(u8, bool),
}

#[derive(Debug, PartialEq, Eq)]
enum Observed {
    Prepare(PrepareStep),
    Send(CommandStep<SendCommand>),
    Cancel(CommandStep<CancelCommand>),
    Network(NetworkStep),
    State(StateStep),
    Read(ReadStateStep),
}

fn identity(logical: u8) -> RequestIdentity {
    RequestIdentity {
        kind: "k".into(),
        provenance: format!("p{logical}"),
        revision: logical.into(),
    }
}

fn attempt(logical: u8, ordinal: u8) -> AttemptIdentity {
    AttemptIdentity {
        logical: identity(logical),
        ordinal: ordinal.into(),
    }
}

fn handle(index: u8) -> ExecutionHandle {
    ExecutionHandle {
        value: format!("h{index}").into(),
    }
}

fn instruction() -> HttpWireInstruction {
    HttpWireInstruction {
        method: "GET".into(),
        target: "http://127.0.0.1/".into(),
        headers: vec![],
        body: vec![],
    }
}

fn configuration() -> HostConfiguration {
    HostConfiguration {
        request_body_limit: 16u8.into(),
        response_body_limit: 16u8.into(),
        cancellation: Some(CancellationCapability {
            identity: OpaqueEvidence { value: "c".into() },
        }),
        monotonic_clock: None,
    }
}

fn root_input(logical: u8, ordinal: u8) -> AttemptInput {
    AttemptInput {
        attempt: attempt(logical, ordinal),
        instruction: instruction(),
        deadline: None,
        configuration: configuration(),
    }
}

fn prepared(state: &NetworkState, logical: u8, ordinal: u8) -> PreparedAttempt {
    let key = attempt(logical, ordinal);
    network_attempts(state)
        .iter()
        .find(|record| record.input.attempt == key)
        .map_or_else(
            || PreparedAttempt {
                input: Arc::new(root_input(logical, ordinal)),
                chain: AttemptChain::Root,
            },
            |record| PreparedAttempt {
                input: Arc::clone(&record.input),
                chain: record.chain.clone(),
            },
        )
}

fn started(state: &NetworkState, logical: u8, ordinal: u8, index: u8) -> StartedAttempt {
    StartedAttempt {
        prepared: prepared(state, logical, ordinal),
        handle: handle(index),
    }
}

fn response(logical: u8, ordinal: u8, index: u8) -> AdapterObservation {
    AdapterObservation::ResponseObservation {
        attempt: attempt(logical, ordinal),
        handle: handle(index),
        source_sequence: None,
        response: RawHttpResponse {
            status: 200u8.into(),
            headers: vec![],
            body: vec![],
        },
        provenance: HeaderProvenance::LibraryNormalized,
        effect: EffectStatus::Unknown {
            reason: UnknownEffectReason::ProtocolWitnessMissing,
        },
    }
}

fn witness(logical: u8, ordinal: u8, occurred: bool) -> EffectStatus {
    let witness = EffectWitness {
        attempt: attempt(logical, ordinal),
        source: EffectWitnessSource::Protocol,
        evidence: OpaqueEvidence { value: "w".into() },
    };
    if occurred {
        EffectStatus::EffectOccurred { witness }
    } else {
        EffectStatus::NoEffect { witness }
    }
}

fn retry_request(logical: u8, from: u8) -> RetryRequest {
    RetryRequest {
        permission: RetryPermission::RetryAllowed {
            authorization: RetryAuthorization {
                logical: identity(logical),
                from: attempt(logical, from),
                next: attempt(logical, from.saturating_add(1)),
                protocol_evidence: OpaqueEvidence { value: "r".into() },
            },
        },
        instruction: instruction(),
        deadline: None,
        configuration: configuration(),
    }
}

fn advanced(state: &NetworkState, logical: u8, late: bool) -> Step {
    let latest = network_attempts(state)
        .iter()
        .filter(|record| record.input.attempt.logical == identity(logical))
        .max_by_key(|record| record.input.attempt.ordinal.to_u64());
    let Some(record) = latest else {
        return Step::Prepare(logical, 0);
    };
    let ordinal = record
        .input
        .attempt
        .ordinal
        .to_u64()
        .and_then(|value| u8::try_from(value).ok())
        .unwrap_or(u8::MAX);
    match &record.disposition {
        AttemptDisposition::Prepared => Step::Send(logical, ordinal),
        AttemptDisposition::CommandIssued => Step::Start(logical, ordinal, 0),
        AttemptDisposition::Started { .. } if late => Step::Cancel(logical, ordinal, 0),
        AttemptDisposition::Started { .. } => Step::Deliver(logical, ordinal, 0, 0),
        AttemptDisposition::Settled { .. } if late => {
            let delivery = u8::try_from(record.late.len().saturating_add(1)).unwrap_or(u8::MAX);
            Step::Deliver(logical, ordinal, 0, delivery)
        }
        AttemptDisposition::Settled { .. } => Step::Retry(logical, ordinal),
    }
}

fn apply_step(state: NetworkState, step: &Step) -> (NetworkState, Observed) {
    if let Step::Advance(logical, late) = *step {
        let step = advanced(&state, logical, late);
        return apply_step(state, &step);
    }
    match *step {
        Step::Prepare(logical, ordinal) => {
            prepare_result(prepare(state, Arc::new(root_input(logical, ordinal))))
        }
        Step::Send(logical, ordinal) => {
            let input = prepared(&state, logical, ordinal);
            let result = send_command(state, input);
            let next = match &result {
                CommandStep::CommandReady(next, _) | CommandStep::Rejected(next, _) => next.clone(),
            };
            (next, Observed::Send(result))
        }
        Step::Start(logical, ordinal, index) => {
            let input = prepared(&state, logical, ordinal);
            let observation = StartObservation::Started {
                attempt: attempt(logical, ordinal),
                handle: handle(index),
            };
            network_result(observe_start(state, input, observation))
        }
        Step::Pending(logical, ordinal, index) => network_result(observe(
            state,
            HostObservation::Pending {
                attempt: attempt(logical, ordinal),
                handle: handle(index),
            },
        )),
        Step::Deliver(logical, ordinal, index, delivery) => network_result(observe(
            state,
            HostObservation::Delivered {
                delivery: delivery.into(),
                observation: response(logical, ordinal, index),
            },
        )),
        Step::Annotate(logical, ordinal, occurred) => {
            let observation = EffectObservation {
                attempt: attempt(logical, ordinal),
                status: witness(logical, ordinal, occurred),
            };
            let result = annotate_effect(state, observation);
            let next = match &result {
                StateStep::Applied(next) | StateStep::Rejected(next, _) => next.clone(),
            };
            (next, Observed::State(result))
        }
        Step::Retry(logical, from) => prepare_result(retry(state, retry_request(logical, from))),
        Step::Cancel(logical, ordinal, index) => {
            let input = started(&state, logical, ordinal, index);
            let result = cancel_command(state, input);
            let next = match &result {
                CommandStep::CommandReady(next, _) | CommandStep::Rejected(next, _) => next.clone(),
            };
            (next, Observed::Cancel(result))
        }
        Step::Advance(..) => (
            state,
            Observed::Read(ReadStateStep::Read(NetworkState::default())),
        ),
        Step::Read => {
            let result = read_network_state(state);
            let next = match &result {
                ReadStateStep::Read(next) | ReadStateStep::Rejected(next, _) => next.clone(),
            };
            (next, Observed::Read(result))
        }
    }
}

fn prepare_result(result: PrepareStep) -> (NetworkState, Observed) {
    let next = match &result {
        PrepareStep::Prepared(next, _) | PrepareStep::Rejected(next, _) => next.clone(),
    };
    (next, Observed::Prepare(result))
}

fn network_result(result: NetworkStep) -> (NetworkState, Observed) {
    let next = match &result {
        NetworkStep::Started(next, _)
        | NetworkStep::Pending(next, _)
        | NetworkStep::Terminal(next, _)
        | NetworkStep::Late(next, _, _)
        | NetworkStep::Duplicate(next, _, _)
        | NetworkStep::Rejected(next, _) => next.clone(),
    };
    (next, Observed::Network(result))
}

fn step() -> impl Strategy<Value = Step> {
    let logical = 0u8..3;
    let ordinal = 0u8..3;
    let index = 0u8..2;
    prop_oneof![
        6 => (0u8..3, any::<bool>()).prop_map(|(l, late)| Step::Advance(l, late)),
        1 => (logical.clone(), 0u8..2).prop_map(|(l, o)| Step::Prepare(l, o)),
        1 => (logical.clone(), ordinal.clone()).prop_map(|(l, o)| Step::Send(l, o)),
        1 => (logical.clone(), ordinal.clone(), index.clone())
            .prop_map(|(l, o, h)| Step::Start(l, o, h)),
        1 => (logical.clone(), ordinal.clone(), index.clone())
            .prop_map(|(l, o, h)| Step::Pending(l, o, h)),
        1 => (logical.clone(), ordinal.clone(), index.clone(), 0u8..3)
            .prop_map(|(l, o, h, d)| Step::Deliver(l, o, h, d)),
        1 => (logical.clone(), ordinal.clone(), any::<bool>())
            .prop_map(|(l, o, b)| Step::Annotate(l, o, b)),
        1 => (logical.clone(), ordinal.clone()).prop_map(|(l, o)| Step::Retry(l, o)),
        1 => (logical, ordinal, index).prop_map(|(l, o, h)| Step::Cancel(l, o, h)),
        1 => Just(Step::Read),
    ]
}

proptest! {
    #[test]
    fn generated_operation_sequences_keep_the_state_invariant(
        steps in proptest::collection::vec(step(), 0..60),
        probe in step(),
    ) {
        let mut state = NetworkState::default();
        for step in &steps {
            let rebuilt = network_state_of(network_attempts(&state).to_vec());
            prop_assert_eq!(rebuilt.as_ref().ok(), Some(&state));
            let rebuilt = rebuilt.unwrap();
            let (next, result) = apply_step(state, step);
            let (rebuilt_next, rebuilt_result) = apply_step(rebuilt, step);
            prop_assert_eq!(&result, &rebuilt_result);
            prop_assert_eq!(&next, &rebuilt_next);
            state = next;
        }
        let rebuilt = network_state_of(network_attempts(&state).to_vec());
        prop_assert_eq!(rebuilt.as_ref().ok(), Some(&state));
        let (_, probed) = apply_step(state, &probe);
        let (_, rebuilt_probed) = apply_step(rebuilt.unwrap(), &probe);
        prop_assert_eq!(probed, rebuilt_probed);
    }
}
