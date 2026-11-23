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
    operation_checker_without_library, operation_meaning_of, prepare_direct_composition, InputId,
    ProducerRef, UnresolvedObligation,
};
use necoherence::semantic_exchange::decode_signature_problem;
use necoherence::semantic_types::SlotContract;
use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
use necoherence_composition_solver::closure::{CompositionDecision, TerminalAssessment};
use necoherence_composition_solver::composition_search::{assess_terminal, derive};
use necoherence_composition_solver::enumeration::enumerate_returns;
use necoherence_composition_solver::search_state::initial_state;
use serde_json::json;
use support::{composition_problem, empty_input, flag_input, judged};

fn empty_supplier(id: &str) -> UnresolvedObligation {
    UnresolvedObligation::Inhabitation {
        producer: ProducerRef::Initial(InputId(id.into())),
        contract: SlotContract {
            type_ref: signature_type_ref("empty"),
            required: true,
            nullable: false,
        },
    }
}

#[test]
fn valueless_supplier_terminal_is_unknown_inhabitation_as_lean_reports() {
    let (library, problem) = composition_problem(
        json!([empty_input("empty-input"), flag_input()]),
        json!([]),
        json!([]),
        None,
    );
    let graph = check_type_signatures(&library).unwrap();
    let problem = decode_signature_problem(&library, &problem).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let state = initial_state(&prepared);
    let terminals = enumerate_returns(&prepared, &state).values;
    let [terminal] = terminals.as_slice() else {
        panic!("the goal enumerates exactly one terminal");
    };
    let assessment = judged(
        assess_terminal(&prepared, &state, terminal)
            .unwrap()
            .unwrap(),
    );
    assert_eq!(
        assessment,
        TerminalAssessment::Unknown(vec![empty_supplier("empty-input")])
    );
}

#[test]
fn valueless_supplier_keeps_the_inhabitation_obligation_in_derive() {
    let (library, problem) = composition_problem(
        json!([empty_input("empty-input"), flag_input()]),
        json!([]),
        json!([]),
        None,
    );
    let graph = check_type_signatures(&library).unwrap();
    let problem = decode_signature_problem(&library, &problem).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let CompositionDecision::Incomplete {
        evaluation,
        frontier,
        ..
    } = derive(&prepared).unwrap()
    else {
        panic!("a valueless supplier leaves the derivation incomplete");
    };
    assert_eq!(judged(evaluation), vec![empty_supplier("empty-input")]);
    assert!(frontier.is_empty());
}

#[test]
fn first_valueless_supplier_is_the_only_obligation_per_terminal() {
    let (library, problem) = composition_problem(
        json!([
            empty_input("empty-input"),
            flag_input(),
            empty_input("empty-input-2")
        ]),
        json!([]),
        json!([]),
        None,
    );
    let graph = check_type_signatures(&library).unwrap();
    let problem = decode_signature_problem(&library, &problem).unwrap();
    let prepared = prepare_direct_composition(
        &graph,
        problem,
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .unwrap();
    let state = initial_state(&prepared);
    let terminals = enumerate_returns(&prepared, &state).values;
    let [terminal] = terminals.as_slice() else {
        panic!("the goal enumerates exactly one terminal");
    };
    let assessment = judged(
        assess_terminal(&prepared, &state, terminal)
            .unwrap()
            .unwrap(),
    );
    assert_eq!(
        assessment,
        TerminalAssessment::Unknown(vec![empty_supplier("empty-input")])
    );
    let CompositionDecision::Incomplete {
        evaluation,
        frontier,
        ..
    } = derive(&prepared).unwrap()
    else {
        panic!("a valueless supplier leaves the derivation incomplete");
    };
    assert_eq!(judged(evaluation), vec![empty_supplier("empty-input")]);
    assert!(frontier.is_empty());
}
