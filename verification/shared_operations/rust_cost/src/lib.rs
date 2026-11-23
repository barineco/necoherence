// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

//! Operation sequences for the fuel count of `rust_cost.py`. `run(op, n, k)`
//! builds a state that holds `n` entries and applies `k` operations to it.

use necoherence::core::{apply, bump, lookup, world_of, Basis, Command, Nat, ResourceId, Revision};
use necoherence::dynamic_admission as da;
use necoherence::exact_json::JsonValue;
use necoherence::exact_json_view::JsonValueView;
use necoherence::file_effect as fe;
use necoherence::network_effect as ne;
use necoherence::reconcile::reconcile;
use necoherence::request_progression as rp;
use necoherence::semantic_codegen_runtime::select_branch;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::{
    materialize_defaults, BorrowedValueDecision, FormatWorkspace, PreparedValidator,
};
use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
use necoherence::store::{self, observe, store_of};
use necoherence::type_signatures::*;
use std::hint::black_box;
use std::sync::Arc;

pub const OPERATIONS: [&str; 35] = [
    "core_lookup",
    "core_bump",
    "core_apply",
    "core_apply_conflicted",
    "core_apply_unknown",
    "rp_submit_fifo",
    "rp_submit_latest_wins",
    "rp_decide_start",
    "rp_decide_start_blocked",
    "rp_apply_start_observation",
    "rp_apply_completion_observation",
    "rp_decide_cancel",
    "rp_derive_pending",
    "rp_derive_in_flight",
    "rp_derive_concurrent",
    "da_admit_submitted",
    "da_admit_executed",
    "da_elide_admission_provenance",
    "ne_prepare",
    "ne_send_command",
    "ne_observe_start",
    "ne_cancel_command",
    "ne_observe_pending",
    "ne_observe_delivered",
    "ne_observe_late",
    "ne_annotate_effect",
    "ne_retry",
    "ne_read_network_state",
    "store_observe",
    "store_apply",
    "reconcile",
    "file_effect_replace",
    "file_effect_read",
    "file_effect_track",
    "validate_prepared",
];

fn resource(i: u32) -> ResourceId {
    ResourceId {
        kind: "k".into(),
        name: format!("r{i}"),
    }
}

fn identity(i: u32) -> rp::RequestIdentity {
    rp::RequestIdentity {
        kind: "k".into(),
        provenance: "p".into(),
        revision: Nat::from(i),
    }
}

fn demand() -> rp::ResourceDemand {
    rp::ResourceDemand {
        pending: 1u8.into(),
        in_flight: 1u8.into(),
        concurrent: 1u8.into(),
    }
}

fn limit(maximum: u32) -> rp::ConfiguredSafetyLimit {
    rp::ConfiguredSafetyLimit {
        resource: "r".into(),
        maximum: Nat::from(maximum),
    }
}

fn budget(n: u32) -> rp::ResourceBudget {
    let maximum = n.saturating_mul(4);
    rp::ResourceBudget {
        pending_maximum: limit(maximum),
        in_flight_maximum: limit(maximum),
        concurrent_maximum: limit(maximum),
    }
}

fn footprint() -> rp::RequestFootprint {
    rp::RequestFootprint {
        reads: vec![],
        writes: vec![],
        effect_class: rp::RequestEffectClass::Pure,
    }
}

fn handle(i: u32) -> rp::ExecutionHandle {
    rp::ExecutionHandle {
        value: format!("h{i}").into(),
    }
}

fn evidence() -> rp::EvidenceVersion {
    rp::EvidenceVersion {
        identifier: "e".into(),
        digest: "d".into(),
        artifact_path: "a".into(),
    }
}

fn entry(i: u32, phase: rp::RequestPhase) -> rp::RequestEntry {
    let held_handle = matches!(phase, rp::RequestPhase::Publishing).then(|| handle(i));
    rp::RequestEntry {
        identity: identity(i),
        footprint: footprint(),
        demand: demand(),
        phase,
        meaning_permission: rp::MeaningPermission::Permitted(identity(i), vec![]),
        cost_selection: None,
        execution_handle: held_handle,
    }
}

fn request(i: u32) -> rp::RequestInput {
    rp::RequestInput {
        identity: identity(i),
        footprint: footprint(),
        demand: demand(),
        permission: rp::MeaningPermission::Permitted(identity(i), vec![]),
    }
}

fn snapshot(
    policy: rp::RequestPolicy,
    n: u32,
    phase: rp::RequestPhase,
) -> rp::RequestProgressionSnapshot {
    let entries = (0..n).map(|i| entry(i, phase)).collect();
    match rp::snapshot_of(policy, budget(n), Some(identity(0)), entries, Nat::from(n)) {
        Ok(snapshot) => snapshot,
        Err(failure) => panic!("{failure:?}"),
    }
}

fn execute_now(i: u32) -> rp::CostSelection {
    rp::CostSelection::ExecuteNow(identity(i), evidence(), Nat::from(0u8))
}

fn admission_input(i: u32, start: Option<rp::CostSelection>, n: u32) -> da::DynamicAdmissionInput {
    da::DynamicAdmissionInput {
        request: request(i),
        environment_specification: da::EnvironmentSpecification {
            max_observation_age: Nat::from(1u8),
        },
        capacity_observation: da::CapacityObservation {
            observed: budget(n),
            observed_at: Nat::from(0u8),
        },
        observed_at: Nat::from(0u8),
        start,
    }
}

fn admission_state(
    policy: rp::RequestPolicy,
    n: u32,
    phase: rp::RequestPhase,
    future_uses: Vec<rp::RequestIdentity>,
) -> da::DynamicAdmissionState {
    da::admission_state_of(
        snapshot(policy, n, phase),
        budget(n),
        da::AdmissionProvenance {
            future_uses,
            outstanding_signals: vec![],
        },
    )
}

fn world(n: u32) -> necoherence::core::World {
    world_of((0..n).map(|i| {
        (
            resource(i),
            Revision {
                value: Nat::from(i + 1),
            },
        )
    }))
}

fn command(resource: ResourceId, revision: u32) -> Command<u32> {
    Command {
        intent: revision,
        basis: Basis {
            resource,
            revision: Revision {
                value: Nat::from(revision),
            },
        },
    }
}

fn run_core(op: u32, n: u32, k: u32) {
    let mut held = world(n);
    let last = resource(n - 1);
    for step in 0..k {
        held = match op {
            0 => {
                black_box(lookup(&held, &last));
                held
            }
            1 => bump(held, &last),
            2 => apply(held, command(last.clone(), n + step)).0,
            3 => apply(held, command(last.clone(), 0)).0,
            _ => apply(held, command(resource(n + 1), 1)).0,
        };
    }
    std::mem::forget(held);
}

fn submitted(result: rp::SubmitResult) -> rp::RequestProgressionSnapshot {
    match result {
        rp::SubmitResult::Accepted(next, _) => next,
        rp::SubmitResult::SubmitRejected(_, failure) => panic!("{failure:?}"),
    }
}

fn run_progression(op: u32, n: u32, k: u32) {
    let phase = match op {
        9 => rp::RequestPhase::Preparing,
        10 => rp::RequestPhase::Publishing,
        _ => rp::RequestPhase::Pending,
    };
    let policy = match op {
        6 => rp::RequestPolicy::LatestWins,
        _ => rp::RequestPolicy::Fifo,
    };
    let mut held = snapshot(policy, n, phase);
    for step in 0..k {
        held = match op {
            5 | 6 => submitted(rp::submit(held, &request(n + step))),
            7 => match rp::decide_start(
                held,
                &rp::Accepted {
                    identity: identity(step),
                },
                &execute_now(step),
            ) {
                rp::StartDecisionResult::Execute(next, _, _) => next,
                other => panic!("{other:?}"),
            },
            8 => match rp::decide_start(
                held,
                &rp::Accepted {
                    identity: identity(n - 1),
                },
                &execute_now(n - 1),
            ) {
                rp::StartDecisionResult::Rejected(next, _) => next,
                other => panic!("{other:?}"),
            },
            9 => {
                let starting = rp::Starting {
                    identity: identity(step),
                    command: rp::AdapterCommand::StartCommand(identity(step), footprint()),
                };
                let signal: rp::AdapterResult<rp::AdapterSignal<u32>, rp::AdapterFailure> =
                    rp::AdapterResult::AppliedSignal(rp::AdapterSignal::Started(
                        identity(step),
                        handle(step),
                    ));
                match rp::apply_start_observation(held, &starting, &signal) {
                    rp::StartObservationResult::Publishing(next, _) => next,
                    other => panic!("{other:?}"),
                }
            }
            10 => {
                let running = rp::Running {
                    identity: identity(step),
                    handle: handle(step),
                };
                let signal = rp::AdapterResult::AppliedSignal(rp::AdapterSignal::Completed(
                    identity(step),
                    handle(step),
                    step,
                ));
                match rp::apply_completion_observation(held, &running, &signal) {
                    rp::CompletionObservationResult::Applied(next, _, _) => next,
                    other => panic!("{other:?}"),
                }
            }
            11 => match rp::decide_cancel(held, &identity(step)) {
                rp::CancelDecisionResult::Cancelled(next, _) => next,
                other => panic!("{other:?}"),
            },
            12 => {
                black_box(rp::derive_pending(&held));
                held
            }
            13 => {
                black_box(rp::derive_in_flight(&held));
                held
            }
            _ => {
                black_box(rp::derive_concurrent(&held));
                held
            }
        };
    }
    std::mem::forget(held);
}

fn run_admission(op: u32, n: u32, k: u32) {
    let (policy, phase) = match op {
        15 => (rp::RequestPolicy::Fifo, rp::RequestPhase::Pending),
        16 => (rp::RequestPolicy::AllExecute, rp::RequestPhase::Pending),
        _ => (rp::RequestPolicy::Fifo, rp::RequestPhase::Cancelled),
    };
    let future_uses = if op == 17 {
        (2 * n..3 * n).map(identity).collect()
    } else {
        vec![]
    };
    let mut held = admission_state(policy, n, phase, future_uses);
    for step in 0..k {
        let (next, applied) = match op {
            15 => {
                let (next, outcome) =
                    da::admit_dynamic_request(held, &admission_input(n + step, None, n));
                (next, matches!(outcome, da::Outcome2::Applied(_)))
            }
            16 => {
                let input = admission_input(n + step, Some(execute_now(n + step)), n);
                let (next, outcome) = da::admit_dynamic_request(held, &input);
                (next, matches!(outcome, da::Outcome2::Applied(_)))
            }
            _ => {
                let (next, outcome) = da::elide_admission_provenance(held, &identity(step));
                (next, matches!(outcome, da::Outcome2::Applied(_)))
            }
        };
        assert!(applied, "operation {op} was rejected at step {step}");
        held = next;
    }
    std::mem::forget(held);
}

fn attempt(i: u32, ordinal: u8) -> ne::AttemptIdentity {
    ne::AttemptIdentity {
        logical: identity(i),
        ordinal: ordinal.into(),
    }
}

fn instruction() -> ne::HttpWireInstruction {
    ne::HttpWireInstruction {
        method: "GET".into(),
        target: "http://127.0.0.1/".into(),
        headers: vec![],
        body: vec![],
    }
}

fn configuration() -> ne::HostConfiguration {
    ne::HostConfiguration {
        request_body_limit: 16u8.into(),
        response_body_limit: 16u8.into(),
        cancellation: Some(ne::CancellationCapability {
            identity: ne::OpaqueEvidence { value: "c".into() },
        }),
        monotonic_clock: None,
    }
}

fn attempt_input(i: u32) -> Arc<ne::AttemptInput> {
    Arc::new(ne::AttemptInput {
        attempt: attempt(i, 0),
        instruction: instruction(),
        deadline: None,
        configuration: configuration(),
    })
}

fn unknown() -> ne::EffectStatus {
    ne::EffectStatus::Unknown {
        reason: ne::UnknownEffectReason::ProtocolWitnessMissing,
    }
}

fn response(started: &ne::StartedAttempt) -> ne::AdapterObservation {
    ne::AdapterObservation::ResponseObservation {
        attempt: started.prepared.input.attempt.clone(),
        handle: started.handle.clone(),
        source_sequence: None,
        response: ne::RawHttpResponse {
            status: 200u8.into(),
            headers: vec![],
            body: vec![],
        },
        provenance: ne::HeaderProvenance::LibraryNormalized,
        effect: unknown(),
    }
}

#[derive(Clone, Copy, PartialEq, PartialOrd)]
enum Stage {
    Prepared,
    Issued,
    Started,
    Settled,
}

struct NetworkFixture {
    state: ne::NetworkState,
    prepared: Vec<ne::PreparedAttempt>,
    started: Vec<ne::StartedAttempt>,
}

fn network(n: u32, stage: Stage) -> NetworkFixture {
    let mut state = ne::NetworkState::with_capacity(2 * n as usize);
    let mut prepared = Vec::with_capacity(n as usize);
    let mut started = Vec::with_capacity(n as usize);
    for i in 0..n {
        let ne::PrepareStep::Prepared(next, attempt) = ne::prepare(state, attempt_input(i)) else {
            panic!("prepare {i}");
        };
        state = next;
        if stage >= Stage::Issued {
            let ne::CommandStep::CommandReady(next, _) = ne::send_command(state, attempt.clone())
            else {
                panic!("send {i}");
            };
            state = next;
        }
        if stage >= Stage::Started {
            let observation = ne::StartObservation::Started {
                attempt: attempt.input.attempt.clone(),
                handle: handle(i),
            };
            let ne::NetworkStep::Started(next, running) =
                ne::observe_start(state, attempt.clone(), observation)
            else {
                panic!("start {i}");
            };
            state = next;
            if stage >= Stage::Settled {
                let delivered = ne::HostObservation::Delivered {
                    delivery: 0u8.into(),
                    observation: response(&running),
                };
                let ne::NetworkStep::Terminal(next, _) = ne::observe(state, delivered) else {
                    panic!("deliver {i}");
                };
                state = next;
            }
            started.push(running);
        }
        prepared.push(attempt);
    }
    NetworkFixture {
        state,
        prepared,
        started,
    }
}

fn witness(i: u32) -> ne::EffectStatus {
    ne::EffectStatus::NoEffect {
        witness: ne::EffectWitness {
            attempt: attempt(i, 0),
            source: ne::EffectWitnessSource::Protocol,
            evidence: ne::OpaqueEvidence { value: "w".into() },
        },
    }
}

fn retry_request(i: u32) -> ne::RetryRequest {
    ne::RetryRequest {
        permission: ne::RetryPermission::RetryAllowed {
            authorization: ne::RetryAuthorization {
                logical: identity(i),
                from: attempt(i, 0),
                next: attempt(i, 1),
                protocol_evidence: ne::OpaqueEvidence { value: "r".into() },
            },
        },
        instruction: instruction(),
        deadline: None,
        configuration: configuration(),
    }
}

fn network_step(
    op: u32,
    fixture: &NetworkFixture,
    state: ne::NetworkState,
    n: u32,
    step: u32,
) -> ne::NetworkState {
    let index = step as usize;
    match op {
        18 => match ne::prepare(state, attempt_input(n + step)) {
            ne::PrepareStep::Prepared(next, _) => next,
            other => panic!("{other:?}"),
        },
        19 => match ne::send_command(state, fixture.prepared[index].clone()) {
            ne::CommandStep::CommandReady(next, _) => next,
            other => panic!("{other:?}"),
        },
        20 => {
            let prepared = fixture.prepared[index].clone();
            let observation = ne::StartObservation::Started {
                attempt: prepared.input.attempt.clone(),
                handle: handle(step),
            };
            match ne::observe_start(state, prepared, observation) {
                ne::NetworkStep::Started(next, _) => next,
                other => panic!("{other:?}"),
            }
        }
        21 => match ne::cancel_command(state, fixture.started[index].clone()) {
            ne::CommandStep::CommandReady(next, _) => next,
            other => panic!("{other:?}"),
        },
        22 => {
            let running = &fixture.started[index];
            let observation = ne::HostObservation::Pending {
                attempt: running.prepared.input.attempt.clone(),
                handle: running.handle.clone(),
            };
            match ne::observe(state, observation) {
                ne::NetworkStep::Pending(next, _) => next,
                other => panic!("{other:?}"),
            }
        }
        23 | 24 => {
            let delivery: u8 = if op == 23 { 0 } else { 1 };
            let observation = ne::HostObservation::Delivered {
                delivery: delivery.into(),
                observation: response(&fixture.started[index]),
            };
            match ne::observe(state, observation) {
                ne::NetworkStep::Terminal(next, _) | ne::NetworkStep::Late(next, _, _) => next,
                other => panic!("{other:?}"),
            }
        }
        25 => {
            let observation = ne::EffectObservation {
                attempt: attempt(step, 0),
                status: witness(step),
            };
            match ne::annotate_effect(state, observation) {
                ne::StateStep::Applied(next) => next,
                other => panic!("{other:?}"),
            }
        }
        26 => match ne::retry(state, retry_request(step)) {
            ne::PrepareStep::Prepared(next, _) => next,
            other => panic!("{other:?}"),
        },
        _ => match ne::read_network_state(state) {
            ne::ReadStateStep::Read(next) => next,
            other => panic!("{other:?}"),
        },
    }
}

fn run_network(op: u32, n: u32, k: u32) {
    let stage = match op {
        18 | 19 => Stage::Prepared,
        20 => Stage::Issued,
        21..=23 => Stage::Started,
        _ => Stage::Settled,
    };
    let mut fixture = network(n, stage);
    let mut held = std::mem::take(&mut fixture.state);
    for step in 0..k {
        held = network_step(op, &fixture, held, n, step);
    }
    std::mem::forget(held);
    std::mem::forget(fixture);
}

fn store_fixture(n: u32) -> store::Store<u32> {
    store_of((0..n).map(|i| {
        (
            resource(i),
            Revision {
                value: Nat::from(i + 1),
            },
            i,
        )
    }))
}

fn run_store(op: u32, n: u32, k: u32) {
    let mut held = store_fixture(n);
    let last = resource(n - 1);
    for step in 0..k {
        held = match op {
            28 => {
                black_box(observe(&held, &last));
                held
            }
            _ => match store::apply(held, command(last.clone(), n + step)) {
                necoherence::Outcome::Applied((_, next)) => next,
                other => panic!("{other:?}"),
            },
        };
    }
    std::mem::forget(held);
}

fn run_reconcile(n: u32, k: u32) {
    let bases: Vec<Option<Basis>> = (0..n)
        .map(|i| {
            Some(Basis {
                resource: resource(i),
                revision: Revision {
                    value: Nat::from(i + 1),
                },
            })
        })
        .collect();
    let held = world(n);
    for _ in 0..k {
        black_box(reconcile(
            black_box(&bases),
            black_box(&held),
            Nat::from(0u8),
        ));
    }
    std::mem::forget(bases);
    std::mem::forget(held);
}

fn file_path(i: u32) -> fe::NormalizedPath {
    fe::NormalizedPath {
        root: true,
        segments: vec![format!("f{i}")],
    }
}

fn file_resource(i: u32) -> ResourceId {
    ResourceId {
        kind: "file".into(),
        name: format!("/f{i}"),
    }
}

fn file_digest(i: u32) -> fe::ContentDigest {
    fe::ContentDigest {
        value: format!("d{i}"),
    }
}

fn run_file_effect(op: u32, n: u32, k: u32) {
    let mut state = fe::ExternalFileState::new(
        (0..n)
            .map(|i| {
                (
                    file_path(i),
                    fe::FileRecord {
                        digest: file_digest(0),
                        bytes: vec![0u8; 4],
                    },
                )
            })
            .collect(),
        vec![],
        vec![],
    );
    let mut held_world = world_of((0..n).map(|i| {
        (
            file_resource(i),
            Revision {
                value: Nat::from(0u8),
            },
        )
    }));
    let mut digests =
        fe::Digests::new((0..n).map(|i| (file_resource(i), file_digest(0))).collect());
    let last = n - 1;
    for step in 0..k {
        if op == 32 {
            let request = fe::ReadReq {
                path: file_path(last),
                world: held_world,
                digests,
                state: &state,
                observed_at: Nat::from(step),
            };
            let necoherence::Outcome::Applied(read) = fe::read(request) else {
                panic!("read {step}");
            };
            held_world = read.world;
            digests = read.digests;
            continue;
        }
        let request = fe::ReplaceReq {
            command: Command {
                intent: fe::ReplaceContents {
                    new_contents: vec![1u8; 4],
                    new_digest: file_digest(step + 1),
                },
                basis: Basis {
                    resource: file_resource(last),
                    revision: Revision {
                        value: Nat::from(step),
                    },
                },
            },
            path: file_path(last),
            world: held_world,
            digests,
            state,
            observed_at: Nat::from(step),
        };
        let necoherence::Outcome::Applied(replaced) = fe::replace(request) else {
            panic!("replace {step}");
        };
        held_world = replaced.world;
        digests = replaced.digests;
        state = replaced.state;
    }
    std::mem::forget(held_world);
    std::mem::forget(digests);
    std::mem::forget(state);
}

fn run_file_effect_track(n: u32, k: u32) {
    let mut held_world = world_of((0..n).map(|i| {
        (
            file_resource(i),
            Revision {
                value: Nat::from(0u8),
            },
        )
    }));
    for step in 0..k {
        let request = fe::TrackReq {
            path: file_path(n + step),
            world: held_world,
            observed_at: Nat::from(step),
        };
        let necoherence::Outcome::Applied(tracked) = fe::track(request) else {
            panic!("track {step}");
        };
        held_world = tracked.world;
    }
    std::mem::forget(held_world);
}

fn validation_profile() -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference,
            range: IntegerDomain::Unbounded,
            forms: vec![IntegerForm::Number],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![],
        tag: None,
        bytes_policy: None,
    }
}

fn plain_string() -> Shape {
    Shape::String(StringSpec {
        format: None,
        lengths: vec![],
        wrapper: None,
        const_value: None,
        enum_values: None,
        examples: vec![],
        default_value: None,
    })
}

fn run_validate_prepared(n: u32, k: u32) {
    let mut nodes = vec![TypeNodeInput {
        id: "target".into(),
        shape: plain_string(),
    }];
    nodes.extend((1..n).map(|i| TypeNodeInput {
        id: format!("filler-{i}"),
        shape: plain_string(),
    }));
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: validation_profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes,
        definitions: vec![],
    };
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let target = signature_type_ref("target");
    let value = JsonValue::Str("abc".into());
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for _ in 0..k {
        black_box(validator.accepts_value(&target, &value));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn run_select_branch_prepared(n: u32, k: u32) {
    let mut nodes: Vec<TypeNodeInput> = (2..n)
        .map(|i| TypeNodeInput {
            id: format!("filler-{i}"),
            shape: plain_string(),
        })
        .collect();
    nodes.push(TypeNodeInput {
        id: "text".into(),
        shape: plain_string(),
    });
    nodes.push(TypeNodeInput {
        id: "target".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![
                SignatureUnionBranch {
                    target: "text".into(),
                    wire_tag: "number".into(),
                    selector: BranchSelector::Kind(ValueKind::Number),
                },
                SignatureUnionBranch {
                    target: "text".into(),
                    wire_tag: "text".into(),
                    selector: BranchSelector::Kind(ValueKind::String),
                },
            ],
        }),
    });
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: validation_profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes,
        definitions: vec![],
    };
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let choice = signature_type_ref("target");
    let accepted = JsonValue::Str("abc".into());
    let rejected = JsonValue::Bool(true);
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    assert_eq!(
        select_branch(validator.metadata(), &choice, &accepted).ok(),
        Some(1)
    );
    assert!(select_branch(validator.metadata(), &choice, &rejected).is_err());
    for _ in 0..k {
        black_box(select_branch(validator.metadata(), &choice, &accepted));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn defaulting_library(n: u32) -> TypeSignatureLibrary {
    let defaulted = |default_value: Option<String>| {
        Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value,
        })
    };
    let mut nodes = vec![
        TypeNodeInput {
            id: "target".into(),
            shape: plain_string(),
        },
        TypeNodeInput {
            id: "defaulted".into(),
            shape: defaulted(Some("fallback".into())),
        },
        TypeNodeInput {
            id: "holder".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "slot".into(),
                    slot: SignatureSlot {
                        type_id: "defaulted".into(),
                        required: false,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ];
    nodes.extend((3..n).map(|i| TypeNodeInput {
        id: format!("filler-{i}"),
        shape: plain_string(),
    }));
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: validation_profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes,
        definitions: vec![],
    }
}

fn run_expand_prepared(n: u32, k: u32) {
    let library = defaulting_library(n);
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let target = signature_type_ref("target");
    let value = JsonValue::Str("abc".into());
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for _ in 0..k {
        black_box(validator.expand_value(&target, &[], &value));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn run_defaults_prepared(n: u32, k: u32) {
    let library = defaulting_library(n);
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let holder = signature_type_ref("holder");
    let value = JsonValue::Obj(vec![]);
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    for _ in 0..k {
        black_box(materialize_defaults(&validator, &holder, &value));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn run_materialize_prepared(n: u32, k: u32) {
    let library = defaulting_library(n);
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let slot = SlotContract {
        type_ref: signature_type_ref("target"),
        required: true,
        nullable: false,
    };
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let value: SlotValue<JsonValueView<'_>> = SlotValue::Absent;
    let BorrowedValueDecision::Rejected(recipe) = validator.decide_view_slot(&slot, value) else {
        panic!("required absent slot is accepted");
    };
    for _ in 0..k {
        black_box(recipe.materialize());
    }
    std::mem::forget(recipe);
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn meaning_library(n: u32) -> TypeSignatureLibrary {
    let mut nodes = vec![
        TypeNodeInput {
            id: "target".into(),
            shape: plain_string(),
        },
        TypeNodeInput {
            id: "flagged".into(),
            shape: Shape::Bytes(LengthSpec {
                minimum: None,
                maximum: None,
            }),
        },
    ];
    nodes.extend((2..n).map(|i| TypeNodeInput {
        id: format!("filler-{i}"),
        shape: plain_string(),
    }));
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: validation_profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes,
        definitions: vec![],
    }
}

fn run_meaning_prepared(n: u32, k: u32, root: &str, expected: usize) {
    let library = meaning_library(n);
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let roots = [signature_type_ref(root)];
    let validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    assert_eq!(validator.meaning_obligations(&roots).len(), expected);
    for _ in 0..k {
        black_box(validator.meaning_obligations(&roots));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

fn product_library(n: u32) -> TypeSignatureLibrary {
    let slot = || SignatureSlot {
        type_id: "target".into(),
        required: true,
        nullable: false,
    };
    let mut nodes = vec![
        TypeNodeInput {
            id: "target".into(),
            shape: plain_string(),
        },
        TypeNodeInput {
            id: "pair".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![
                    SignatureField {
                        wire_name: "a".into(),
                        slot: slot(),
                    },
                    SignatureField {
                        wire_name: "b".into(),
                        slot: slot(),
                    },
                ],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ];
    nodes.extend((2..n).map(|i| TypeNodeInput {
        id: format!("filler-{i}"),
        shape: plain_string(),
    }));
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: validation_profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes,
        definitions: vec![],
    }
}

fn pair_value(second: JsonValue) -> JsonValue {
    JsonValue::Obj(vec![
        ("a".into(), JsonValue::Str("abc".into())),
        ("b".into(), second),
    ])
}

fn run_validate_variant(n: u32, k: u32, op: u32) {
    let library = product_library(n);
    let Ok(graph) = check_type_signatures(&library) else {
        panic!("validation library");
    };
    let target = signature_type_ref("target");
    let pair = signature_type_ref("pair");
    let slot = SlotContract {
        type_ref: target.clone(),
        required: true,
        nullable: false,
    };
    let text = JsonValue::Str("abc".into());
    let number = JsonValue::Num(1.into());
    let accepted_pair = pair_value(JsonValue::Str("def".into()));
    let rejected_pair = pair_value(JsonValue::Num(1.into()));
    let mut validator = PreparedValidator::new(&graph, FormatWorkspace::empty());
    let decide =|validator: &mut PreparedValidator<'_>| match op {
        40 => validator.accepts_value(&target, &number),
        41 => validator.accepts_slot(&slot, SlotValue::Present(&text)),
        42 => validator.accepts_value(&pair, &accepted_pair),
        _ => validator.accepts_value(&pair, &rejected_pair),
    };
    assert_eq!(
        matches!(decide(&mut validator), ValueDecision::Accepted),
        matches!(op, 41 | 42)
    );
    for _ in 0..k {
        black_box(decide(&mut validator));
    }
    std::mem::forget(validator);
    std::mem::forget(graph);
    std::mem::forget(library);
}

#[no_mangle]
pub extern "C" fn run(op: u32, n: u32, k: u32) -> u32 {
    match op {
        0..=4 => run_core(op, n, k),
        5..=14 => run_progression(op, n, k),
        15..=17 => run_admission(op, n, k),
        28 | 29 => run_store(op, n, k),
        30 => run_reconcile(n, k),
        31 | 32 => run_file_effect(op, n, k),
        33 => run_file_effect_track(n, k),
        34 => run_validate_prepared(n, k),
        35 => run_expand_prepared(n, k),
        36 => run_defaults_prepared(n, k),
        37 => run_materialize_prepared(n, k),
        38 => run_meaning_prepared(n, k, "target", 0),
        39 => run_meaning_prepared(n, k, "flagged", 1),
        40..=43 => run_validate_variant(n, k, op),
        44 => run_select_branch_prepared(n, k),
        18..=27 => run_network(op, n, k),
        _ => panic!("unknown operation {op}"),
    }
    0
}
