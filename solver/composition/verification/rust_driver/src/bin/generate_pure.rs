// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use necoherence_composition_solver::{closure::*};
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{encode_signature_generation};
use necoherence_composition_solver::document::signature_composition_from_native;
use necoherence::semantic_types::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence_composition_solver::composition_search::derive;
use std::io::{self, Write};

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
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
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

fn generate() -> std::result::Result<String, Box<dyn std::error::Error>> {
    let source = SourceIdentity {
        repository: "comparison".into(),
        revision: "1".into(),
        path: "execution".into(),
        content_digest: "0".repeat(64),
    };
    let origin = Origin {
        source: source.clone(),
        locator: vec!["operation".into()],
    };
    let port = |id: &str, ty: &str| SignaturePort {
        id: id.into(),
        contract: SignatureSlot {
            type_id: ty.into(),
            required: true,
            nullable: false,
        },
    };
    let library = TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "execution.signatures".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![source],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "truth".into(),
                shape: Shape::Boolean(BooleanSpec {
                    const_value: None,
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "unit".into(),
                shape: Shape::Unit,
            },
        ],
        definitions: vec![DefinitionInput {
            id: "operation".into(),
            wire_identity: "ExecutionOperation".into(),
            shape: SignatureDefinitionShape::Operation(OperationContract {
                effect: EffectPoint::DataOnly,
                inputs: vec![port("input", "truth")],
                outcomes: vec![
                    SignatureOutcome {
                        id: "success".into(),
                        form: necoherence::type_signatures::OutcomeForm::Success,
                        cause: OutcomeCause::ValueContract {
                            origin: origin.clone(),
                        },
                        value_ports: vec![port("output", "truth")],
                        produced_resources: vec![],
                    },
                    SignatureOutcome {
                        id: "refused".into(),
                        form: necoherence::type_signatures::OutcomeForm::DeclaredFailure,
                        cause: OutcomeCause::ExternalCondition {
                            specification: origin,
                        },
                        value_ports: vec![port("reason", "unit")],
                        produced_resources: vec![],
                    },
                ],
            }),
        }],
    };
    let graph = check_type_signatures(&library)?;
    let digest = signature_basis(&library, None, &[])?.graph_sha256;
    let slot = |id: &str| SlotContract {
        type_ref: signature_type_ref(id),
        required: true,
        nullable: false,
    };
    let function = FunctionRef {
        identity: "ExecutionOperation".into(),
        revision: "1".into(),
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
    let problem = CompositionInput {
        identity: "execution comparison".into(),
        revision: "1".into(),
        basis: SemanticBasis::of(&graph),
        signatures: vec![FunctionSignature {
            reference: function.clone(),
            form: FunctionForm::Operation(signature_definition_ref("operation")),
            effect: CompositionEffect::DataOnly,
            inputs: vec![InputPort {
                id: PortId("input".into()),
                contract: slot("truth"),
                source_constraint: SourceConstraint::InitialOnly {
                    input: InputId("argument".into()),
                    path: vec![],
                },
                resource_requirement: None,
            }],
            outcomes: vec![success, refused],
            resource_inputs: vec![],
            assumption_ref: "comparison provider".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![InitialInput {
            id: InputId("argument".into()),
            contract: slot("truth"),
            source: InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: GoalSpec {
            outputs: vec![GoalPort {
                id: GoalPortId("result".into()),
                contract: slot("truth"),
                source_constraint: SourceConstraint::ProducedBy {
                    site: SiteId("operation".into()),
                    outcome: OutcomeId("success".into()),
                    port: PortId("output".into()),
                    path: vec![],
                },
            }],
            failures: vec![FailureEmbedding {
                id: FailureEmbeddingId("refusal".into()),
                origin: FailureOrigin::Function {
                    function: function.clone(),
                    outcome: OutcomeId("refused".into()),
                },
                contract: slot("unit"),
                final_resources: vec![],
            }],
            final_resources: vec![],
        },
        invocation_domain: InvocationDomain {
            identity: "finite".into(),
            revision: "1".into(),
            sites: vec![InvocationSite {
                id: SiteId("operation".into()),
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![CompositionEffect::DataOnly],
        explicit_order: vec![],
        selection_policy: Some(SelectionPolicy::AnyFeasible),
        bounds: SearchBounds::default(),
    };
    let prepared = prepare_direct_composition(
        &graph,
        problem.clone(),
        operation_checker_without_library(),
        operation_meaning_of(&graph),
    )
    .map_err(|failure| format!("{failure:?}"))?;
    let CompositionDecision::Solved(checked, _) =
        derive(&prepared).map_err(|failure| format!("{failure:?}"))?
    else {
        return Err("pure comparison composition was not solved".into());
    };
    let causes = vec![(
        function,
        vec![
            (
                OutcomeId("success".into()),
                OutcomeCause::ValueContract {
                    origin: Origin {
                        source: library.sources[0].clone(),
                        locator: vec!["operation".into()],
                    },
                },
            ),
            (
                OutcomeId("refused".into()),
                OutcomeCause::ExternalCondition {
                    specification: Origin {
                        source: library.sources[0].clone(),
                        locator: vec!["operation".into()],
                    },
                },
            ),
        ],
    )];
    let composition =
        signature_composition_from_native(&library, &problem, checked.raw(), &causes)?;
    let input = assemble_signature_generation(
        library,
        Some(composition),
        vec![SignatureEntrypoint {
            identity: "operation".into(),
            definition: "operation".into(),
        }],
    )?;
    Ok(encode_signature_generation(&input)?)
}

fn main() -> std::result::Result<(), Box<dyn std::error::Error>> {
    writeln!(io::stdout().lock(), "{}", generate()?)?;
    Ok(())
}
