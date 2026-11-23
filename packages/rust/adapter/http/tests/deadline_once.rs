// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::network_effect::*;
use necoherence::request_progression::RequestIdentity;
use necoherence_http_adapter::{
    CooperativeCancellation, MonotonicClockPort, UnknownExecution, UreqHttpAdapter,
};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

type TestResult<T = ()> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

struct ReachedClock {
    capability: MonotonicClockCapability,
}

impl MonotonicClockPort for ReachedClock {
    fn capability(&self) -> MonotonicClockCapability {
        self.capability.clone()
    }

    fn observe(&self) -> Result<MonotonicClockObservation, HostFailure> {
        Ok(MonotonicClockObservation {
            clock_basis: self.capability.clock_basis.clone(),
            value: 9u8.into(),
        })
    }
}

fn start(
    adapter: &UreqHttpAdapter<ReachedClock>,
    capability: &MonotonicClockCapability,
    revision: u64,
) -> TestResult<StartedAttempt> {
    let attempt = AttemptInput {
        attempt: AttemptIdentity {
            logical: RequestIdentity {
                kind: "deadline-once".to_owned(),
                provenance: "runtime".to_owned(),
                revision: revision.into(),
            },
            ordinal: 0u8.into(),
        },
        instruction: HttpWireInstruction {
            method: "GET".to_owned(),
            target: "http://127.0.0.1:9/once".to_owned(),
            headers: Vec::new(),
            body: Vec::new(),
        },
        deadline: Some(Deadline {
            clock_basis: capability.clock_basis.clone(),
            limit: 5u8.into(),
            capability: capability.clone(),
        }),
        configuration: HostConfiguration {
            request_body_limit: 0u8.into(),
            response_body_limit: 16u8.into(),
            cancellation: None,
            monotonic_clock: Some(capability.clone()),
        },
    };
    let PrepareStep::Prepared(state, prepared) =
        prepare(NetworkState::default(), Arc::new(attempt))
    else {
        return Err("prepare".into());
    };
    let CommandStep::CommandReady(state, command) = send_command(state, prepared.clone()) else {
        return Err("send command".into());
    };
    let start = adapter.start(command);
    let NetworkStep::Started(_, started) = observe_start(state, prepared, start) else {
        return Err("observe start".into());
    };
    Ok(started)
}

fn is_deadline(observed: &Result<HostObservation, UnknownExecution>) -> bool {
    matches!(
        observed,
        Ok(HostObservation::Delivered {
            observation: AdapterObservation::DeadlineObservation { .. },
            ..
        })
    )
}

#[test]
fn a_public_observe_and_the_worker_queue_one_deadline_observation() -> TestResult {
    let capability = MonotonicClockCapability {
        identity: OpaqueEvidence {
            value: "deadline-once-clock".to_owned(),
        },
        clock_basis: ClockBasis {
            value: "deadline-once".to_owned(),
        },
    };
    let adapter = UreqHttpAdapter::new(
        ReachedClock {
            capability: capability.clone(),
        },
        CooperativeCancellation::default(),
    );
    for revision in 0..200u64 {
        let started = start(&adapter, &capability, revision)?;
        let began = Instant::now();
        loop {
            let observed = adapter.observe(&started);
            if is_deadline(&observed) {
                break;
            }
            if matches!(observed, Ok(HostObservation::Delivered { .. })) {
                return Err("an observation other than the deadline arrived".into());
            }
            if began.elapsed() > Duration::from_secs(2) {
                return Err("the deadline observation did not arrive".into());
            }
        }
        for _ in 0..5 {
            thread::sleep(Duration::from_millis(1));
            if is_deadline(&adapter.observe(&started)) {
                return Err(format!("a second deadline observation at {revision}").into());
            }
        }
    }
    Ok(())
}
