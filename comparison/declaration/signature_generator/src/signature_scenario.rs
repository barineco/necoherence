// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_tools::composition_search::derive;

enum Scenario {
    Input(Box<SignatureGenerationInput>),
    Decision(serde_json::Value),
}
pub fn composition(
    library: TypeSignatureLibrary,
) -> std::result::Result<SignatureGenerationInput, Box<dyn std::error::Error>> {
    match build(library, true)? {
        Scenario::Input(input) => Ok(*input),
        Scenario::Decision(_) => Err("covered composition required".into()),
    }
}
pub fn without_handler(
    library: TypeSignatureLibrary,
) -> std::result::Result<serde_json::Value, Box<dyn std::error::Error>> {
    match build(library, false)? {
        Scenario::Decision(decision) => Ok(decision),
        Scenario::Input(_) => Err("unhandled failure unexpectedly composed".into()),
    }
}
fn build(
    mut library: TypeSignatureLibrary,
    with_handler: bool,
) -> std::result::Result<Scenario, Box<dyn std::error::Error>> {
    let SignatureDefinitionShape::Operation(operation) = &mut library.definitions[1].shape else {
        return Err("operation input required".into());
    };
    operation.inputs.clear();
    let graph = check_type_signatures(&library)?;
    let digest = signature_basis(&library, None, &[])?.graph_sha256;
    let slot = |id: &str| SlotContract {
        type_ref: signature_type_ref(&library, &digest, id),
        required: true,
        nullable: false,
    };
    let reference = signature_definition_ref(&library, &digest, "operation");
    let function = FunctionRef {
        identity: "ExampleOperation".into(),
        revision: library.revision.clone(),
        content_digest: digest.clone(),
    };
    let success = OutcomeContract {
        id: OutcomeId("success".into()),
        form: necoherence::semantic_composition::OutcomeForm::Success,
        value_ports: vec![OutputPort {
            id: PortId("output".into()),
            contract: slot("truth"),
            resource_production: None,
        }],
        produced_resources: vec![],
    };
    let refused = OutcomeContract {
        id: OutcomeId("refused".into()),
        form: necoherence::semantic_composition::OutcomeForm::DeclaredFailure,
        value_ports: vec![OutputPort {
            id: PortId("reason".into()),
            contract: slot("unit"),
            resource_production: None,
        }],
        produced_resources: vec![],
    };
    let handler = FunctionRef {
        identity: "handler".into(),
        revision: "1".into(),
        content_digest: "2".repeat(64),
    };
    let signatures = vec![
        FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::Operation(reference),
            effect: CompositionEffect::HttpRequestResponse,
            inputs: vec![],
            outcomes: vec![success, refused],
            resource_inputs: vec![],
            assumption_ref: "adapter operation".into(),
            handles_failure: None,
        },
        FunctionSignature {
            reference: handler.clone(),
            form: FunctionForm::DeclaredTransform,
            effect: CompositionEffect::PureFunction,
            inputs: vec![InputPort {
                id: PortId("reason".into()),
                contract: slot("unit"),
                source_constraint: SourceConstraint::ProducedBy {
                    site: SiteId("operation".into()),
                    outcome: OutcomeId("refused".into()),
                    port: PortId("reason".into()),
                    path: vec![],
                },
                resource_requirement: None,
            }],
            outcomes: vec![OutcomeContract {
                id: OutcomeId("handled".into()),
                form: necoherence::semantic_composition::OutcomeForm::Success,
                value_ports: vec![OutputPort {
                    id: PortId("output".into()),
                    contract: slot("truth"),
                    resource_production: None,
                }],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "declared recovery".into(),
            handles_failure: Some(FailureOrigin::Function {
                function: function.clone(),
                outcome: OutcomeId("refused".into()),
            }),
        },
    ];
    let sites = vec![
        InvocationSite {
            id: SiteId("operation".into()),
            function: function.clone(),
        },
        InvocationSite {
            id: SiteId("handler".into()),
            function: handler.clone(),
        },
    ];
    let SignatureDefinitionShape::Operation(base) = &library.definitions[1].shape else {
        return Err("operation input required".into());
    };
    let causes = vec![
        (
            function,
            base.outcomes
                .iter()
                .map(|o| (OutcomeId(o.id.clone()), o.cause.clone()))
                .collect(),
        ),
        (
            handler.clone(),
            vec![(OutcomeId("handled".into()), base.outcomes[0].cause.clone())],
        ),
    ];
    let mut problem = CompositionInput {
        identity: "covered branches".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures,
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: slot("truth"),
                source_constraint: SourceConstraint::AnyCompatible,
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites,
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![handler],
            guards: vec![],
        },
        allowed_effects: vec![
            CompositionEffect::PureFunction,
            CompositionEffect::HttpRequestResponse,
        ],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    if !with_handler {
        problem.signatures.pop();
        problem.invocation_domain.sites.pop();
        problem.invocation_domain.permitted_transforms.clear();
        let prepared = prepare_composition(&graph, problem).map_err(|e| format!("{e:?}"))?;
        let status = match derive(&prepared).map_err(|e| format!("{e:?}"))? {
            CompositionDecision::Unreachable(_) => "Unreachable",
            CompositionDecision::Unknown { .. } => "Unknown",
            _ => return Err("external failure without handler composed".into()),
        };
        return Ok(Scenario::Decision(
            serde_json::json!({"status":status,"handler":false}),
        ));
    }
    let prepared = prepare_composition(&graph, problem.clone()).map_err(|e| format!("{e:?}"))?;
    let CompositionDecision::Solved(checked, _) =
        derive(&prepared).map_err(|e| format!("{e:?}"))?
    else {
        return Err("all branches did not compose".into());
    };
    let composition =
        signature_composition_from_native(&library, &problem, checked.raw(), &causes)?;
    assemble_signature_generation(
        library,
        Some(composition),
        vec![SignatureEntrypoint {
            identity: "example".into(),
            definition: "value".into(),
        }],
    )
    .map(|input| Scenario::Input(Box::new(input)))
    .map_err(Into::into)
}
