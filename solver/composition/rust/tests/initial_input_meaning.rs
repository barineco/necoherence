// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod support;

use necoherence::semantic_composition::{
    operation_checker_without_library, operation_meaning_of, prepare_direct_composition,
    InclusionFailure, PreparedCompositionInput, UnresolvedObligation, WitnessFailure,
};
use necoherence::semantic_exchange::{decode_signature_generation, decode_signature_problem};
use necoherence::semantic_types::{
    GraphemeComponent, GraphemeRules, LengthBound, ProfileRef, SemanticObligation, SemanticReason,
    StringLengthUnit, StringSpec,
};
use necoherence::semantic_validation::meaning_obligations;
use necoherence::signature_admission::{
    check_type_signatures, signature_basis, signature_type_ref,
};
use necoherence::type_signatures::{Shape, TypeNodeInput, TypeSignatureLibrary};
use necoherence_composition_solver::closure::CompositionDecision;
use necoherence_composition_solver::composition_search::derive;
use necoherence_composition_solver::verification::{verify_composition, RawComposition};
use serde_json::{json, Value};
use support::{flag_input, judged};

const FIXTURE: &str = include_str!("fixtures/composition-budget-default.json");

fn replace_digest(value: &mut Value, old: &str, new: &str) {
    match value {
        Value::String(text) if text == old => *text = new.to_owned(),
        Value::Array(items) => items
            .iter_mut()
            .for_each(|item| replace_digest(item, old, new)),
        Value::Object(members) => members
            .values_mut()
            .for_each(|item| replace_digest(item, old, new)),
        _ => {}
    }
}

fn grapheme_rules() -> GraphemeRules {
    GraphemeRules {
        reference: ProfileRef {
            identity: "ncoh-value-semantics".into(),
            revision: "1".into(),
            content_digest: "0".repeat(64),
        },
        properties: vec![],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "C1-1-default-extended-grapheme-cluster-no-tailoring".into(),
        },
        table_sha256: "b".repeat(64),
        sources: vec![],
    }
}

fn text_input(source: Value) -> Value {
    json!({
        "id": "text",
        "contract": {"nullable": true, "required": true, "type_id": "grapheme-text"},
        "source": source,
        "resource": null
    })
}

fn problem_with(defined: bool, text_source: Value) -> (TypeSignatureLibrary, Value) {
    let mut input = decode_signature_generation(FIXTURE).unwrap();
    let old_graph = input.basis.graph_sha256.clone();
    let mut library = (*input.signatures).clone();
    library.nodes.push(TypeNodeInput {
        id: "grapheme-text".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![LengthBound {
                unit: StringLengthUnit::Graphemes,
                minimum: Some(1u8.into()),
                maximum: None,
            }],
            wrapper: None,
            const_value: None,
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    if defined {
        library.profile.grapheme_rules = Some(grapheme_rules());
    }
    let basis = signature_basis(&library, None, &[]).unwrap();
    let mut composition = input.composition.take().unwrap();
    let problem = &mut composition["problem"];
    replace_digest(problem, &old_graph, &basis.graph_sha256);
    problem["basis"]["graph_sha256"] = json!(basis.graph_sha256);
    problem["basis"]["provenance_sha256"] = json!(basis.provenance_sha256);
    problem["basis"]["metadata_sha256"] = json!(basis.metadata_sha256);
    problem["basis"]["entrypoints_sha256"] = json!(basis.entrypoints_sha256);
    problem["initial_inputs"] = json!([flag_input(), text_input(text_source)]);
    problem["invocation_domain"]["guards"] = json!([]);
    problem["goal"] = json!({
        "outputs": [{
            "id": "result",
            "contract": {"nullable": false, "required": true, "type_id": "truth"},
            "source_constraint": {"tag": "InitialOnly", "fields": {"input": "flag", "path": []}}
        }],
        "failures": [],
        "final_resources": []
    });
    problem["invocation_domain"]["sites"] = json!([]);
    problem["invocation_domain"]["permitted_transforms"] = json!([]);
    problem["signatures"]
        .as_array_mut()
        .unwrap()
        .retain(|signature| signature["reference"]["identity"] != "handler");
    (library, composition["problem"].take())
}

fn prepare<'g>(
    graph: &'g necoherence::semantic_types::SemanticGraph,
    library: &TypeSignatureLibrary,
    problem: &Value,
) -> PreparedCompositionInput<'g> {
    let problem = decode_signature_problem(library, problem).unwrap();
    prepare_direct_composition(
        graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(graph),
    )
    .unwrap()
}

fn argument() -> Value {
    json!({"tag": "Argument"})
}

fn supplied() -> Value {
    json!({"tag": "SuppliedValue", "value": {"tag": "Present", "value": {"tag": "String", "value": "a"}}})
}

fn expected_obligations(
    graph: &necoherence::semantic_types::SemanticGraph,
) -> Vec<SemanticObligation> {
    meaning_obligations(graph, &[signature_type_ref("grapheme-text")])
}

fn incomplete_obligations(prepared: &PreparedCompositionInput<'_>) -> Vec<SemanticObligation> {
    let CompositionDecision::Incomplete { evaluation, .. } = derive(prepared).unwrap() else {
        panic!("an undefined initial input type leaves the derivation incomplete");
    };
    let judgment = judged(evaluation);
    let [UnresolvedObligation::Meaning(obligations)] = judgment.as_slice() else {
        panic!("the residual is exactly one meaning obligation list");
    };
    obligations.clone()
}

fn solved_raw(prepared: &PreparedCompositionInput<'_>) -> RawComposition {
    let CompositionDecision::Solved(checked, selection) = derive(prepared).unwrap() else {
        panic!("a defined initial input type derives a solved composition");
    };
    RawComposition {
        plan: checked.plan().clone(),
        witness: checked.witness().clone(),
        selection,
    }
}

fn check_invalid_and_preserved(text_source: Value, expect_value_reason: bool) {
    let (undefined_library, undefined_problem) = problem_with(false, text_source.clone());
    let undefined_graph = check_type_signatures(&undefined_library).unwrap();
    let undefined = prepare(&undefined_graph, &undefined_library, &undefined_problem);
    let (defined_library, defined_problem) = problem_with(true, text_source);
    let defined_graph = check_type_signatures(&defined_library).unwrap();
    let defined = prepare(&defined_graph, &defined_library, &defined_problem);

    let type_obligations = expected_obligations(&undefined_graph);
    assert!(!type_obligations.is_empty());
    assert!(type_obligations
        .iter()
        .all(|obligation| obligation.reason == SemanticReason::MissingGraphemeRules));
    assert!(expected_obligations(&defined_graph).is_empty());

    let obligations = incomplete_obligations(&undefined);
    assert!(obligations.starts_with(&type_obligations));
    if expect_value_reason {
        assert!(obligations.len() > type_obligations.len());
    } else {
        assert_eq!(obligations, type_obligations);
    }

    let mut raw = solved_raw(&defined);
    raw.witness.input_snapshot = undefined.input().clone();
    let rejected = verify_composition(&undefined, &raw).err();
    assert_eq!(
        rejected,
        Some(WitnessFailure::Inclusion(
            InclusionFailure::UndefinedMeaning(obligations)
        ))
    );

    let defined_raw = solved_raw(&defined);
    assert!(verify_composition(&defined, &defined_raw).is_ok());
}

#[test]
fn undefined_argument_type_is_incomplete_and_rejected_by_verification() {
    check_invalid_and_preserved(argument(), false);
}

#[test]
fn undefined_supplied_value_is_incomplete_and_rejected_by_verification() {
    check_invalid_and_preserved(supplied(), true);
}
