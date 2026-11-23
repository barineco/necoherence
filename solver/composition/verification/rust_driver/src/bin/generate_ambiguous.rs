// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence_composition_solver::{closure::*, enumeration::*, search_state::*, verification::*};
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{encode_signature_generation};
use necoherence_composition_solver::document::signature_composition_from_native;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use std::io::{self, Write};
use std::sync::Arc;

fn profile() -> ValueSemanticProfile {
    let reference = ProfileRef {
        identity: "ncoh-value-semantics".into(),
        revision: "1".into(),
        content_digest: "0".repeat(64),
    };
    ValueSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference,
            range: IntegerDomain::Inclusive {
                minimum: (-10).into(),
                maximum: 10.into(),
            },
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

fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "composition.ambiguous".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![TypeNodeInput {
            id: "truth".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        }],
        definitions: vec![],
    };
    let graph = check_type_signatures(&library)?;
    let contract = SlotContract {
        type_ref: signature_type_ref("truth"),
        required: true,
        nullable: false,
    };
    let problem = CompositionInput {
        identity: "two canonical programs".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![
            InitialInput {
                id: InputId("left".into()),
                contract: contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
            InitialInput {
                id: InputId("right".into()),
                contract: contract.clone(),
                source: InitialSource::Argument,
                resource: None,
            },
        ],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract,
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::RequireUnique),
        bounds: SearchBounds::default(),
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .map_err(|failure| format!("{failure:?}"))?;
    let CompositionDecision::Ambiguous {
        candidates,
        canonical_plans,
    } = derive(&prepared).map_err(|failure| format!("{failure:?}"))?
    else {
        return Err("two distinct candidates required".into());
    };
    let terminals = candidates
        .iter()
        .map(|candidate| -> std::result::Result<ResourceTraceCertificate, Box<dyn std::error::Error>> {
            let PlanNode::Return(terminal) = &candidate.plan().root.node else {
                return Err("return candidate required".into());
            };
            let certificate = candidate
                .witness()
                .resource_traces
                .first()
                .ok_or("resource certificate required")?;
            let _ = terminal;
            Ok(certificate.clone())
        })
        .collect::<std::result::Result<Vec<_>, Box<dyn std::error::Error>>>()?;
    let node = CompositionClosureNode {
        state: initial_state(&prepared),
        terminals,
        actions: vec![],
    };
    let closure = CompositionClosureWitness {
        input_identity: problem.identity.clone(),
        input_revision: problem.revision.clone(),
        binding_candidates: closure_binding_candidates(&prepared, &node.state).into(),
        nodes: vec![node],
        steps: 0u8.into(),
        branch_nodes: 0u8.into(),
        frontier: vec![],
        obligations: vec![],
    };
    let selected = candidates.first().ok_or("candidate required")?;
    let raw = RawComposition {
        plan: selected.plan().clone(),
        witness: selected.witness().clone(),
        selection: Arc::new(SelectionEvidence::Unique {
            closure: Box::new(closure),
            canonical_plan: canonical_plans
                .first()
                .ok_or("canonical plan required")?
                .clone(),
        }),
    };
    let composition = signature_composition_from_native(&library, &problem, &raw, &[])?;
    let input = assemble_signature_generation(library, Some(composition), vec![])?;
    writeln!(
        io::stdout().lock(),
        "{}",
        encode_signature_generation(&input)?
    )?;
    Ok(())
}
