// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::result_large_err,
    clippy::unwrap_used
)]

use necoherence::network_effect::*;
use necoherence::request_progression::ExecutionHandle;
use necoherence::semantic_composition as composition;
use necoherence::semantic_execution as execution;
use necoherence::semantic_types::*;
use necoherence::signature_admission::check_type_signatures;
use std::sync::Arc;

#[path = "fixtures/semantic_execution_samples.rs"]
#[allow(dead_code, unused_imports)]
mod samples;
use samples::*;

#[test]
fn variant_guard_uses_selected_branch_and_preserves_absent_and_null() {
    let exchange = include_str!("fixtures/variant-guard-incomplete-coverage.json");
    let input = necoherence::semantic_exchange::decode_signature_generation(exchange).unwrap();
    let graph = check_type_signatures(&input.signatures).unwrap();
    let wire = input.composition.as_ref().unwrap();
    let problem = necoherence::semantic_exchange::decode_signature_problem(
        &input.signatures,
        &wire["problem"],
    )
    .unwrap();
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    assert_eq!(
        execution::inspect_guard(&prepared, 0, &SlotValue::Absent),
        Ok(composition::GuardArm::Absent)
    );
    assert_eq!(
        execution::inspect_guard(&prepared, 0, &SlotValue::Null),
        Ok(composition::GuardArm::Null)
    );
    assert_eq!(
        execution::inspect_guard(
            &prepared,
            0,
            &SlotValue::Present(JsonValue::Obj(vec![(
                "kind".into(),
                JsonValue::Str("other".into())
            )])),
        ),
        Ok(composition::GuardArm::Variant("otherwise".into()))
    );
    assert_eq!(
        execution::inspect_guard(&prepared, 0, &SlotValue::Present(JsonValue::Obj(vec![]))),
        Err(execution::ExecutionFailure::InvalidPlan(
            "union guard discriminator".into()
        ))
    );
}

#[test]
fn prepared_completion_must_match_its_declared_outcome() {
    let binding = |label: &'static str| execution::NetworkBinding {
        transport: execution::NetworkTransport {
            encode: Arc::new(|attempt: &AttemptInput| Ok(attempt.clone())),
            decode: Arc::new(|_: &RawHttpResponse| {
                Err(execution::ExecutionFailure::InvalidPlan("unused".into()))
            }),
        },
        prepare: Arc::new(move |_: &()| {
            Ok(execution::BindingPreparedCall::Completed(
                composition::OutcomeId(label.into()),
                "external",
            ))
        }),
    };
    let outcome_id = |result: &&'static str| composition::OutcomeId((*result).into());
    assert!(matches!(
        execution::prepare_call(&binding("external"), &(), outcome_id, |outcome| outcome.0 == "external"),
        Ok(execution::BindingPreparedCall::Completed(ref outcome, "external")) if outcome.0 == "external"
    ));
    assert!(matches!(
        execution::prepare_call(&binding("external"), &(), outcome_id, |outcome| outcome.0 == "other"),
        Err(execution::ExecutionFailure::InvalidPlan(ref condition))
            if condition == "undeclared external completion"
    ));
    assert!(matches!(
        execution::prepare_call(&binding("other"), &(), outcome_id, |outcome| outcome.0 == "other"),
        Err(execution::ExecutionFailure::InvalidPlan(ref condition))
            if condition == "undeclared external completion"
    ));
}

#[test]
fn pure_provider_completes_synchronously_and_declared_failure_uses_its_plan_arm() {
    let checked = admitted(PURE);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = operation_reference(preparation.prepared());
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let progress = execution::start(
        &checked_run,
        checked_run.workspace(),
        vec![pure_provider(
            &reference,
            "success",
            SlotValue::Present(JsonValue::Bool(true)),
        )],
        vec![argument_true()],
        NetworkState::default(),
    )
    .unwrap();
    assert!(matches!(
        progress,
        execution::Progress::Completed(
            execution::ExecutionResult::Success(ref outputs),
            _
        ) if outputs == &vec![(&composition::GoalPortId("result".into()), SlotValue::Present(JsonValue::Bool(true)))]
    ));
    let failure = execution::start(
        &checked_run,
        checked_run.workspace(),
        vec![pure_provider(
            &reference,
            "refused",
            SlotValue::Present(JsonValue::Null),
        )],
        vec![argument_true()],
        NetworkState::default(),
    )
    .unwrap();
    assert!(matches!(
        failure,
        execution::Progress::Completed(
            execution::ExecutionResult::Failure(embedding, SlotValue::Present(JsonValue::Null)),
            _
        ) if embedding.0 == "refusal"
    ));
}

#[test]
fn prepared_http_completion_emits_no_network_instruction() {
    let checked = admitted(HTTP);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = operation_reference(preparation.prepared());
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let provider = execution::Provider {
        reference: reference.clone(),
        implementation: execution::ProviderImplementation::PreparedHttp(
            execution::PreparedNetworkOwner {
                prepare: Arc::new(|_| {
                    Ok(execution::PreparedCall::Completed(execution::CallResult {
                        outcome: composition::OutcomeId("success".into()),
                        outputs: vec![(
                            composition::PortId("output".into()),
                            SlotValue::Present(JsonValue::Bool(true)),
                        )],
                    }))
                }),
                decode: Arc::new(|_| unreachable!()),
            },
        ),
    };
    assert!(matches!(
        execution::start(&checked_run, checked_run.workspace(), vec![provider], vec![argument_true()], NetworkState::default()).unwrap(),
        execution::Progress::Completed(execution::ExecutionResult::Success(_), ref network)
            if network_attempts(network).is_empty()
    ));
}

#[test]
fn http_provider_returns_send_observe_and_completed_progress() {
    let checked = admitted(HTTP);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = operation_reference(preparation.prepared());
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let execution::Progress::Pending(pending_start, execution::NetworkInstruction::Send) =
        execution::start(
            &checked_run,
            checked_run.workspace(),
            vec![http_provider(&reference)],
            vec![argument_true()],
            NetworkState::default(),
        )
        .unwrap()
    else {
        panic!("HTTP execution must request send");
    };
    let attempt = pending_start
        .send_command()
        .unwrap()
        .prepared
        .input
        .attempt
        .clone();
    let handle = ExecutionHandle { value: "h".into() };
    let execution::Progress::Pending(pending_response, execution::NetworkInstruction::Observe) =
        execution::resume(
            pending_start,
            execution::ExecutionObservation::Start(StartObservation::Started { attempt, handle }),
        )
        .unwrap()
    else {
        panic!("start observation must request response observation");
    };
    let started = pending_response.observed_attempt().unwrap().clone();
    let delivered = HostObservation::Delivered {
        delivery: 0u8.into(),
        observation: response(&started),
    };
    let execution::Progress::Completed(execution::ExecutionResult::Success(_), _) =
        execution::resume(
            pending_response,
            execution::ExecutionObservation::Host(delivered),
        )
        .unwrap()
    else {
        panic!("response observation must complete execution");
    };
}

#[test]
fn guard_selects_failure_and_success_arms() {
    let checked = admitted(PRESENCE);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let absent = execution::start(
        &checked_run,
        checked_run.workspace(),
        vec![],
        vec![(composition::InputId("argument".into()), SlotValue::Absent)],
        NetworkState::default(),
    )
    .unwrap();
    assert!(matches!(
        absent,
        execution::Progress::Completed(execution::ExecutionResult::Failure(id, SlotValue::Absent), _)
            if id.0 == "absent"
    ));
    let present = execution::start(
        &checked_run,
        checked_run.workspace(),
        vec![],
        vec![(
            composition::InputId("argument".into()),
            SlotValue::Present(JsonValue::Str("present-value".into())),
        )],
        NetworkState::default(),
    )
    .unwrap();
    assert!(matches!(
        present,
        execution::Progress::Completed(execution::ExecutionResult::Success(_), _)
    ));
}

#[test]
fn provider_argument_and_output_failures_match_execution_failure_constructors() {
    let checked = admitted(PURE);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = operation_reference(preparation.prepared());
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let wrong_reference = execution::Provider {
        reference: composition::FunctionRef {
            identity: "other".into(),
            ..reference.clone()
        },
        implementation: pure_provider(
            &reference,
            "success",
            SlotValue::Present(JsonValue::Bool(true)),
        )
        .implementation,
    };
    assert!(matches!(
        execution::start(
            &checked_run,
            checked_run.workspace(),
            vec![wrong_reference],
            vec![argument_true()],
            NetworkState::default()
        ),
        Err(execution::RunFailure {
            cause: execution::ExecutionFailure::MissingProvider(_),
            ..
        })
    ));
    assert!(matches!(
        execution::start(
            &checked_run,
            checked_run.workspace(),
            vec![http_provider(&reference)],
            vec![argument_true()],
            NetworkState::default()
        ),
        Err(execution::RunFailure {
            cause: execution::ExecutionFailure::ProviderEffect(_),
            ..
        })
    ));
    assert!(matches!(
        execution::start(
            &checked_run,
            checked_run.workspace(),
            vec![pure_provider(
                &reference,
                "success",
                SlotValue::Present(JsonValue::Str("wrong".into()))
            )],
            vec![argument_true()],
            NetworkState::default(),
        ),
        Err(execution::RunFailure {
            cause: execution::ExecutionFailure::Value(execution::ValidationFailure::Value(_)),
            ..
        })
    ));

    let guard_checked = admitted(PRESENCE);
    let guard_preparation = guard_checked.prepare_admission().unwrap().unwrap();
    let guard_checked_run = execution::PreparedRun::new(guard_preparation.admitted());
    assert!(matches!(
        execution::start(&guard_checked_run, guard_checked_run.workspace(), vec![], vec![], NetworkState::default()),
        Err(execution::RunFailure {
            cause: execution::ExecutionFailure::MissingArgument(ref id),
            ..
        }) if id.0 == "argument"
    ));
}

#[test]
fn resume_requires_matching_observation_kind() {
    let checked = admitted(HTTP);
    let preparation = checked.prepare_admission().unwrap().unwrap();
    let reference = operation_reference(preparation.prepared());
    let checked_run = execution::PreparedRun::new(preparation.admitted());
    let execution::Progress::Pending(pending, _) = execution::start(
        &checked_run,
        checked_run.workspace(),
        vec![http_provider(&reference)],
        vec![argument_true()],
        NetworkState::default(),
    )
    .unwrap() else {
        panic!("HTTP execution must be pending");
    };
    assert!(matches!(
        execution::resume(
            pending,
            execution::ExecutionObservation::Host(HostObservation::Pending {
                attempt: attempt_input().attempt,
                handle: ExecutionHandle { value: "h".into() },
            }),
        ),
        Err(execution::RunFailure {
            cause: execution::ExecutionFailure::InvalidPlan(ref condition),
            ..
        }) if condition == "network observation kind mismatch"
    ));
}
