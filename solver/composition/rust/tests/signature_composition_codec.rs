// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::indexing_slicing)]

use necoherence::exact_json::JsonValue as ExchangeJson;
use necoherence::semantic_composition::{FunctionRef, OutcomeId};
use necoherence::semantic_exchange::{
    decode_signature_generation, decode_signature_problem, SignatureCompositionAdmissionFailure,
    WireDecode,
};
use necoherence::signature_admission::check_type_signatures;
use necoherence::type_signatures::OutcomeCause;
use necoherence_composition_solver::document::signature_composition_from_native;
use serde_json::{json, Value};

const DEFAULT_CASE: &str = include_str!("fixtures/composition-budget-default.json");
const PRESENCE_CASE: &str =
    include_str!("../../../../packages/rust/adapter/tests/fixtures/execution-presence.json");
const GUARD_CASE: &str = include_str!(
    "../../../../packages/rust/adapter/tests/fixtures/variant-guard-incomplete-coverage.json"
);
const UNIQUE_REQUEST: &str =
    include_str!("../../../../verification/declaration/signature_admission/examples/accepted-unique.request.json");

#[derive(Clone, Copy)]
enum Case {
    Default,
    Presence,
    Guard,
    Unique,
}

fn exchange_text(case: Case) -> String {
    match case {
        Case::Default => DEFAULT_CASE.to_owned(),
        Case::Presence => PRESENCE_CASE.to_owned(),
        Case::Guard => GUARD_CASE.to_owned(),
        Case::Unique => {
            let request: Value = serde_json::from_str(UNIQUE_REQUEST).expect("unique request");
            request["exchange"]
                .as_str()
                .expect("exchange text")
                .to_owned()
        }
    }
}

fn exchange_value(value: &Value) -> Option<ExchangeJson> {
    necoherence::exact_json::parse_json_text(&value.to_string()).ok()
}

type CauseGroups = Vec<(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)>;

fn causes_of(problem: &Value) -> Option<CauseGroups> {
    let mut groups = Vec::new();
    for row in problem.get("signatures")?.as_array()? {
        let reference =
            FunctionRef::decode_wire(&exchange_value(row.get("reference")?)?, "$").ok()?;
        let mut outcomes = Vec::new();
        for outcome in row.get("outcomes")?.as_array()? {
            let id = OutcomeId::decode_wire(&exchange_value(outcome.get("id")?)?, "$").ok()?;
            let cause =
                OutcomeCause::decode_wire(&exchange_value(outcome.get("cause")?)?, "$").ok()?;
            outcomes.push((id, cause));
        }
        groups.push((reference, outcomes));
    }
    Some(groups)
}

fn failure_text(failure: &SignatureCompositionAdmissionFailure) -> String {
    match failure {
        SignatureCompositionAdmissionFailure::Wire(failure) => format!("wire {failure:?}"),
        SignatureCompositionAdmissionFailure::CompositionInput(failure) => {
            format!("input {failure:?}")
        }
        SignatureCompositionAdmissionFailure::Composition(failure) => {
            format!("composition {failure:?}")
        }
    }
}

fn observe_composition(exchange: &str) -> Result<Value, String> {
    let input = decode_signature_generation(exchange).map_err(|failure| format!("{failure:?}"))?;
    let composition = input.composition.as_ref().expect("composition");
    let graph =
        check_type_signatures(&input.signatures).map_err(|failure| format!("{failure:?}"))?;
    let (composed, derivation) =
        necoherence_composition_solver::wire_admission::verified_signature_derivation(
            &input, &graph,
        )
        .map_err(|failure| failure_text(&failure))?
        .expect("verified composition");
    let causes = causes_of(&composition["problem"]).expect("causes");
    signature_composition_from_native(&input.signatures, &composed.problem, &derivation, &causes)
        .map_err(|failure| format!("{failure:?}"))
}

#[test]
fn composition_problem_and_derivation_roundtrip() {
    for (label, case) in [
        ("default", Case::Default),
        ("presence", Case::Presence),
        ("unique", Case::Unique),
    ] {
        let raw = exchange_text(case);
        let input = decode_signature_generation(&raw).expect("generation input");
        let composition = input.composition.as_ref().expect("composition");
        let problem_original = decode_signature_problem(&input.signatures, &composition["problem"])
            .expect("original problem");
        let encoded = observe_composition(&raw).expect("encoded composition");

        let mut rebuilt_exchange: Value = serde_json::from_str(&raw).expect("exchange JSON");
        rebuilt_exchange["composition"] = encoded.clone();
        let rebuilt_text = rebuilt_exchange.to_string();
        let rebuilt_input = decode_signature_generation(&rebuilt_text).expect("rebuilt input");
        let rebuilt_composition = rebuilt_input
            .composition
            .as_ref()
            .expect("rebuilt composition");
        let problem_roundtrip =
            decode_signature_problem(&rebuilt_input.signatures, &rebuilt_composition["problem"])
                .expect("roundtrip problem");
        assert_eq!(problem_original, problem_roundtrip, "case {label}");
        let encoded_again = observe_composition(&rebuilt_text).expect("re-encoded composition");
        assert_eq!(encoded, encoded_again, "case {label}");
    }
}

fn composition_observed_in(case: Case, mutate: impl FnOnce(&mut Value)) -> Result<Value, String> {
    let mut exchange: Value = serde_json::from_str(&exchange_text(case)).expect("exchange JSON");
    mutate(&mut exchange["composition"]);
    observe_composition(&exchange.to_string())
}

fn composition_failure_in(case: Case, mutate: impl FnOnce(&mut Value)) -> String {
    composition_observed_in(case, mutate).expect_err("expected composition failure")
}

fn composition_failure(mutate: impl FnOnce(&mut Value)) -> String {
    composition_failure_in(Case::Default, mutate)
}

#[test]
fn unknown_fields_on_derivation_parts_are_rejected_as_wire_unknown_field() {
    let unknown_field = |path: &str| format!("wire UnknownField {{ path: \"{path}\"");
    assert!(composition_failure(|c| c["derivation"]["extra"] = json!(1))
        .starts_with(&unknown_field("$.extra")));
    assert!(
        composition_failure(|c| c["derivation"]["witness"]["extra"] = json!(1))
            .starts_with(&unknown_field("$.extra"))
    );
    assert!(
        composition_failure(|c| c["derivation"]["plan"]["extra"] = json!(1))
            .starts_with(&unknown_field("$.extra"))
    );
}

#[test]
fn unknown_tags_and_mismatched_snapshot_in_derivation_produce_typed_wire_failures() {
    let unknown_tag = |path: &str| format!("wire UnknownTag {{ path: \"{path}\"");
    assert!(composition_failure(
        |c| c["derivation"]["plan"]["root"]["node"]["tag"] = json!("Bogus")
    )
    .starts_with(&unknown_tag("$.node.tag")));
    assert!(
        composition_failure(|c| c["derivation"]["selection"]["tag"] = json!("Bogus"))
            .starts_with(&unknown_tag("$.tag"))
    );
    assert!(composition_failure(|c| {
        c["derivation"]["witness"]["resource_traces"][0]["trace"]["terminal"]["tag"] =
            json!("Bogus");
    })
    .starts_with(&unknown_tag("$.trace.terminal.tag")));
    assert!(composition_failure(
        |c| c["derivation"]["witness"]["input_snapshot"] = json!({ "x": 1 })
    )
    .starts_with("wire Syntax { path: \"$\", message: \"input snapshot mismatch\""));
}

#[test]
fn problem_basis_is_read_as_a_basis_before_the_comparison() {
    assert!(
        composition_failure(|c| c["problem"]["basis"]["extra"] = json!(1))
            .starts_with("wire UnknownField { path: \"$.composition.problem.basis.extra\"")
    );
    assert!(
        composition_failure(|c| c["problem"]["basis"]["library_revision"] = json!("2"))
            .starts_with("wire Syntax { path: \"$.composition.problem.basis\"")
    );
}

fn first_inclusion(value: &mut Value) -> Option<&mut Value> {
    let is_inclusion = value.as_object().is_some_and(|members| {
        [
            "basis",
            "source",
            "destination",
            "empty_types",
            "pairs",
            "root",
        ]
        .iter()
        .all(|name| members.contains_key(*name))
    });
    if is_inclusion {
        return Some(value);
    }
    match value {
        Value::Object(members) => members.values_mut().find_map(first_inclusion),
        Value::Array(items) => items.iter_mut().find_map(first_inclusion),
        _ => None,
    }
}

#[test]
fn inclusion_records_reject_unknown_fields_with_typed_wire_failures() {
    for target in [
        "/basis",
        "/basis/profile",
        "/pairs/0/source_shape",
        "/pairs/0/source_shape/value",
        "/pairs/0/destination_shape",
        "/pairs/0/destination_shape/value",
    ] {
        let failure = composition_failure(|c| {
            let inclusion = first_inclusion(&mut c["derivation"]).expect("inclusion");
            inclusion.pointer_mut(target).expect("record")["extra"] = json!(1);
        });
        assert!(
            failure.starts_with("wire UnknownField { path: "),
            "{target}: {failure}"
        );
    }
}

#[test]
fn invalid_correspondence_in_resource_trace_produces_typed_wire_failure() {
    let failure = composition_failure(|c| {
        let trace = &mut c["derivation"]["witness"]["resource_traces"][0];
        trace["correspondence"]["extra"] = json!(1);
    });
    assert!(
        failure.starts_with("wire UnknownField { path: "),
        "{failure}"
    );
    let failure = composition_failure(|c| {
        let trace = &mut c["derivation"]["witness"]["resource_traces"][0];
        trace["correspondence"] = json!(5);
    });
    assert!(failure.starts_with("wire Syntax { path: "), "{failure}");
}

#[test]
fn plan_ranks_and_inclusion_roots_are_read_as_unbounded_naturals() {
    let huge = json!("18446744073709551616");
    let failure = composition_failure(|c| c["derivation"]["plan"]["root"]["rank"] = huge.clone());
    assert!(
        failure.starts_with("composition RankViolation"),
        "{failure}"
    );
    let observed = composition_observed_in(Case::Default, |c| {
        c["derivation"]["plan"]["root"]["node"]["fields"]["arms"][0][1]["rank"] = huge.clone();
    });
    assert!(observed.is_ok(), "{observed:?}");
    let failure = composition_failure(|c| {
        first_inclusion(&mut c["derivation"]).expect("inclusion")["root"] = huge.clone();
    });
    assert!(failure.starts_with("composition "), "{failure}");
}

fn unique_failure(mutate: impl FnOnce(&mut Value)) -> String {
    composition_failure_in(Case::Unique, |c| {
        mutate(&mut c["derivation"]["selection"]["fields"]["closure"]);
    })
}

#[test]
fn invalid_closure_rows_and_choices_produce_typed_wire_failures() {
    let failure = unique_failure(|closure| {
        closure["states"][1]["extra"] = json!(1);
    });
    assert!(
        failure.starts_with("wire UnknownField { path: "),
        "{failure}"
    );
    let failure = unique_failure(|closure| {
        closure["states"][0]["terminals"] = json!(5);
    });
    assert!(failure.starts_with("wire Syntax { path: "), "{failure}");
    let failure = unique_failure(|closure| {
        closure["states"][0]["choices"][0]["extra"] = json!(1);
    });
    assert!(
        failure.starts_with("wire UnknownField { path: "),
        "{failure}"
    );
    let failure = unique_failure(|closure| {
        closure["states"][0]["state"]["trace"] = json!(5);
    });
    assert!(failure.starts_with("wire Syntax { path: "), "{failure}");
}

#[test]
fn closure_terminal_assessment_is_compared_while_decoding() {
    let failure = unique_failure(|closure| {
        let terminal = closure["states"][1]["terminals"][0]["assessment"]["value"]["trace"]
            ["terminal"]["value"]
            .as_array_mut()
            .expect("terminal values");
        terminal.pop();
    });
    assert!(
        failure.starts_with("wire Syntax { path: \"$\", message: \"terminal assessment mismatch\""),
        "{failure}"
    );
}

#[test]
fn search_bounds_are_read_as_unbounded_naturals() {
    let huge = json!("18446744073709551616");
    for name in [
        "max_expanded_states",
        "max_binding_candidates",
        "max_type_obligations",
        "max_branch_nodes",
        "max_sample_length",
    ] {
        let observed = composition_observed_in(Case::Default, |c| {
            c["problem"]["bounds"][name] = huge.clone();
            c["derivation"]["witness"]["input_snapshot"]["bounds"][name] = huge.clone();
        });
        assert!(observed.is_ok(), "{name}: {observed:?}");
    }
}

fn plan_failure(case: Case, pointer: &str, edits: &[(&str, Value)]) -> String {
    composition_failure_in(case, |c| {
        let record = c["derivation"]["plan"]
            .pointer_mut(pointer)
            .expect("record to edit");
        for (name, value) in edits {
            record[*name] = value.clone();
        }
    })
}

#[test]
fn malformed_plan_and_inclusion_fields_produce_typed_wire_failures() {
    let extra = json!({ "extra": 1 });
    type CaseEdit<'a> = (&'a str, Case, &'a str, Vec<(&'a str, Value)>);
    let cases: Vec<CaseEdit> = vec![
        (
            "source binding compatibility",
            Case::Default,
            "/root/node/fields/arms/0/1/node/value/value/0/1/fields",
            vec![("compatibility", json!({ "tag": "Bogus" }))],
        ),
        (
            "invocation resources",
            Case::Default,
            "/root/node/fields/invocation",
            vec![("resources", json!(5))],
        ),
        (
            "invoke node arms",
            Case::Default,
            "/root/node/fields",
            vec![("arms", json!(5))],
        ),
        (
            "guard node arms",
            Case::Guard,
            "/root/node/fields",
            vec![("arms", json!(5))],
        ),
    ];
    for (name, case, pointer, edits) in cases {
        let failure = plan_failure(case, pointer, &edits);
        assert!(
            failure.starts_with("wire "),
            "{name}: expected typed wire failure, got {failure}"
        );
    }
    let failure = composition_failure(|c| {
        let inclusion = first_inclusion(&mut c["derivation"]).expect("inclusion");
        inclusion["source"] = extra;
    });
    assert!(failure.starts_with("wire "), "{failure}");
}

#[test]
fn operation_forms_without_a_matching_definition_fail_in_the_composition_input() {
    for form in [
        json!({ "tag": "Operation", "value": "missing" }),
        json!({ "tag": "Operation", "value": "" }),
    ] {
        assert!(
            composition_failure(|c| c["problem"]["signatures"][0]["form"] = form.clone())
                .starts_with("input InvalidSignature")
        );
    }
    assert!(composition_failure(|c| {
        c["problem"]["signatures"][1]["form"] = json!({ "tag": "Operation", "value": "operation" });
    })
    .starts_with("input InvalidSignature"));
}
