// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::*;
use super::enumeration::*;
use super::search_state::*;
use super::verification::*;
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::type_signatures::*;
use num_bigint::BigUint;
use std::sync::Arc;

#[derive(Clone)]
pub struct WireCompositionClosureWitness {
    pub(crate) input_snapshot: CompositionInput,
    pub(crate) root: BigUint,
    pub(crate) states: Vec<ClosedSearchState>,
}

#[derive(Clone)]
pub enum WireSelectionEvidence {
    AnyFeasible,
    Unique {
        closure: Box<WireCompositionClosureWitness>,
        canonical_plan: String,
    },
}

#[derive(Clone)]
pub struct WireRawComposition {
    pub(crate) plan: CompositionPlan,
    pub(crate) witness: CompositionWitness,
    pub(crate) selection: Arc<WireSelectionEvidence>,
}

fn closure_to_wire(
    prepared: &PreparedCompositionInput<'_>,
    problem: &CompositionInput,
    closure: &CompositionClosureWitness,
) -> Decoded<WireCompositionClosureWitness> {
    let root = closure
        .nodes
        .iter()
        .position(|node| node.state == initial_state(prepared))
        .map(BigUint::from)
        .ok_or_else(|| syntax("$", "closure initial state"))?;
    let states = closure
        .nodes
        .iter()
        .map(|node| {
            let choices = node
                .actions
                .iter()
                .map(|action| {
                    let choice = local_action_choice(prepared, &node.state, action)
                        .map_err(GenerationFailure::Composition)?;
                    let children = action_successors(prepared, &node.state, action)
                        .map_err(GenerationFailure::Composition)?
                        .iter()
                        .map(|(_, successor)| {
                            closure
                                .nodes
                                .iter()
                                .position(|candidate| candidate.state == *successor)
                                .map(BigUint::from)
                                .ok_or_else(|| syntax("$", "closure successor state"))
                        })
                        .collect::<Decoded<Vec<_>>>()?;
                    Ok(ChoiceCoverage { choice, children })
                })
                .collect::<Decoded<Vec<_>>>()?;
            Ok(ClosedSearchState {
                state: node.state.clone(),
                terminals: node
                    .terminals
                    .iter()
                    .map(|certificate| TerminalCoverage {
                        terminal: certificate.trace.terminal.clone(),
                        assessment: TerminalAssessment::Feasible(certificate.clone()),
                    })
                    .collect(),
                choices,
                rejected_connections: Vec::new(),
                missing_supply: Vec::new(),
            })
        })
        .collect::<Decoded<Vec<_>>>()?;
    Ok(WireCompositionClosureWitness {
        input_snapshot: problem.clone(),
        root,
        states,
    })
}

fn raw_to_wire(
    prepared: &PreparedCompositionInput<'_>,
    problem: &CompositionInput,
    raw: &RawComposition,
) -> Decoded<WireRawComposition> {
    let selection = match raw.selection.as_ref() {
        SelectionEvidence::AnyFeasible => WireSelectionEvidence::AnyFeasible,
        SelectionEvidence::Unique {
            closure,
            canonical_plan: _,
        } => WireSelectionEvidence::Unique {
            closure: Box::new(closure_to_wire(prepared, problem, closure)?),
            canonical_plan: canonical_plan_key(prepared, &raw.plan.root),
        },
    };
    Ok(WireRawComposition {
        plan: raw.plan.clone(),
        witness: raw.witness.clone(),
        selection: Arc::new(selection),
    })
}

pub fn signature_composition_from_native(
    library: &TypeSignatureLibrary,
    problem: &CompositionInput,
    derivation: &RawComposition,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
) -> Result<serde_json::Value, necoherence::signature_admission::AdmissionFailure> {
    use necoherence::signature_admission::AdmissionFailure;
    let problem = super::problem_codec::encode_problem(library, problem, causes)
        .map_err(AdmissionFailure::Generation)?;
    let graph = necoherence::signature_admission::check_type_signatures(library)?;
    let graph_digest = necoherence::signature_admission::canonical_digest(library)?;
    let bindings = causes
        .iter()
        .flat_map(|(function, outcomes)| {
            outcomes.iter().map(|(outcome, cause)| CauseBinding {
                function: function.clone(),
                outcome: outcome.clone(),
                cause: cause.clone(),
            })
        })
        .collect::<Vec<_>>();
    let prepared = prepare_signature_composition(
        library,
        &graph_digest,
        &graph,
        derivation.witness.input_snapshot.clone(),
        &bindings,
    )
    .map_err(AdmissionFailure::CompositionInput)?;
    let wire_derivation = raw_to_wire(&prepared, &derivation.witness.input_snapshot, derivation)
        .map_err(AdmissionFailure::Generation)?;
    let plan = super::derivation_codec::encode_composition_plan(library, &wire_derivation.plan)
        .map_err(AdmissionFailure::Generation)?;
    let witness =
        super::derivation_codec::encode_witness(library, &graph, causes, &wire_derivation.witness)
            .map_err(AdmissionFailure::Generation)?;
    let selection = super::derivation_codec::encode_selection(
        library,
        &graph,
        causes,
        &wire_derivation.selection,
    )
    .map_err(AdmissionFailure::Generation)?;
    Ok(serde_json::json!({
        "problem": problem,
        "derivation": {
            "plan": plan,
            "witness": witness,
            "selection": selection,
        },
    }))
}
