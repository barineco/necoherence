// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::indexing_slicing, clippy::unwrap_used)]
use necoherence::inclusion;
use necoherence::semantic_composition as composition;
use necoherence::semantic_composition::{slot_samples, SearchBounds};
use necoherence::semantic_exchange::*;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use necoherence::signature_admission::*;
use necoherence::type_signatures::*;
use necoherence::typed_mapping as resource;
use necoherence_composition_solver::document::*;
use necoherence_composition_solver::lowering::ResourceCorrespondence;
use necoherence_composition_solver::verification::{
    BranchTrace, CompositionWitness, ResourceTraceCertificate, TraceStep,
};
use necoherence_composition_solver::wire_admission::verified_signature_derivation;
use num_bigint::{BigInt, BigUint};
use std::sync::Arc;

fn fixture_item<T>(items: &[T], index: usize) -> &T {
    items.get(index).expect("fixture item exists")
}

fn fixture_item_mut<T>(items: &mut [T], index: usize) -> &mut T {
    items.get_mut(index).expect("fixture item exists")
}

fn reference() -> ProfileRef {
    ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

fn profile() -> ValueSemanticProfile {
    ValueSemanticProfile {
        reference: reference(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference: reference(),
            range: IntegerDomain::Inclusive {
                minimum: BigInt::from(-10),
                maximum: BigInt::from(10),
            },
            forms: vec![IntegerForm::Number, IntegerForm::DecimalString],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![FormatBinding {
            name: "name".into(),
            reference: reference(),
            rule: FormatRule::Not(Box::new(FormatRule::Literal("bad".into()))),
        }],
        wrappers: vec![Wrapper {
            name: "wrapped".into(),
            key: "$value".into(),
            payload: WrapperPayload::Text { format: None },
        }],
        tag: Some(TagModel {
            key: "kind".into(),
            format: None,
            sealed: vec![SealedForm {
                tag: "sealed".into(),
                fields: vec![SealedField {
                    key: "name".into(),
                    required: true,
                    leaf: SealedLeaf::String(StringSpec {
                        format: None,
                        lengths: vec![],
                        wrapper: None,
                        const_value: None,
                        enum_values: None,
                        examples: vec![],
                        default_value: None,
                    }),
                }],
                extras: SealedExtras::Reject,
            }],
        }),
        bytes_policy: None,
    }
}

fn library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "library".into(),
        revision: "1".into(),
        profile: profile(),
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![
            TypeNodeInput {
                id: "text".into(),
                shape: Shape::String(StringSpec {
                    format: Some(FormatUse::Named("name".into())),
                    lengths: vec![LengthBound {
                        unit: StringLengthUnit::UnicodeScalars,
                        minimum: Some(BigUint::from(1u8)),
                        maximum: Some(BigUint::from(8u8)),
                    }],
                    wrapper: None,
                    const_value: None,
                    enum_values: None,
                    examples: vec!["ok".into()],
                    default_value: None,
                }),
            },
            TypeNodeInput {
                id: "never".into(),
                shape: Shape::Never,
            },
            TypeNodeInput {
                id: "sealed".into(),
                shape: Shape::Sealed {
                    tag: "sealed".into(),
                    refinements: vec![],
                },
            },
            TypeNodeInput {
                id: "choice".into(),
                shape: Shape::TaggedUnion(SignatureUnion {
                    branches: vec![
                        SignatureUnionBranch {
                            target: "sealed".into(),
                            wire_tag: "sealed".into(),
                            selector: BranchSelector::InternalTag,
                        },
                        SignatureUnionBranch {
                            target: "text".into(),
                            wire_tag: "text".into(),
                            selector: BranchSelector::Kind(ValueKind::String),
                        },
                    ],
                }),
            },
        ],
        definitions: vec![DefinitionInput {
            id: "entry".into(),
            wire_identity: "entry".into(),
            shape: SignatureDefinitionShape::Value("choice".into()),
        }],
    }
}

fn composition_fixture() -> (TypeSignatureLibrary, composition::CompositionInput) {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "record".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "flag".into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let basis = signature_basis(&library, None, &[]).unwrap();
    let basis: serde_json::Value =
        serde_json::from_str(&encode_signature_basis(&basis).unwrap()).unwrap();
    let slot = serde_json::json!({
        "type_id": "boolean", "required": true, "nullable": false
    });
    let problem = serde_json::json!({
        "identity": "composition", "revision": "2", "basis": basis,
        "signatures": [],
        "initial_inputs": [{
            "id": "initial", "contract": slot, "source": {"tag": "Argument"},
            "resource": null
        }],
        "initial_resources": [],
        "goal": {
            "outputs": [{
                "id": "output", "contract": slot,
                "source_constraint": {
                    "tag": "InitialOnly", "fields": {"input": "initial", "path": []}
                }
            }],
            "failures": [], "final_resources": []
        },
        "invocation_domain": {
            "identity": "domain", "revision": "3", "sites": [],
            "permitted_projections": [], "permitted_constructions": [],
            "permitted_transforms": [], "guards": []
        },
        "allowed_effects": [], "explicit_order": [],
        "selection_policy": {"tag": "AnyFeasible"},
        "bounds": {
            "max_expanded_states": "16", "max_binding_candidates": "16",
            "max_type_obligations": "16", "max_branch_nodes": "16",
            "resource_bounds": null, "max_sample_length": "59"
        }
    });
    let native = decode_signature_problem(&library, &problem).unwrap();
    (library, native)
}

fn solved_signature_composition(
    library: &TypeSignatureLibrary,
    problem: &composition::CompositionInput,
) -> serde_json::Value {
    let raw = solved_raw_composition(library, problem);
    signature_composition_from_native(library, problem, &raw, &[]).unwrap()
}

fn solved_raw_composition(
    library: &TypeSignatureLibrary,
    problem: &composition::CompositionInput,
) -> necoherence_composition_solver::verification::RawComposition {
    let graph = check_type_signatures(library).unwrap();
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let enumeration =
        necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
    let terminal = fixture_item(&enumeration.values, 0).clone();
    let trace = BranchTrace {
        steps: vec![],
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) =
        necoherence_composition_solver::lowering::lower_resource_trace(&prepared, &trace).unwrap();
    assert!(lowering.transitions.is_empty());
    let initial_value = if fixture_item(&problem.initial_inputs, 0)
        .contract
        .type_ref
        .definition_name
        .as_ref()
        == "record"
    {
        JsonValue::Obj(vec![("flag".into(), JsonValue::Bool(false))])
    } else {
        JsonValue::Bool(false)
    };
    let raw = necoherence_composition_solver::verification::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: problem.identity.clone(),
            input_revision: problem.revision.clone(),
            root: composition::PlanTree {
                rank: BigUint::from(0u8),
                node: composition::PlanNode::Return(terminal),
            },
        },
        witness: CompositionWitness {
            input_snapshot: problem.clone(),
            initial_membership: necoherence_composition_solver::search_state::initial_membership(
                &prepared,
            )
            .unwrap(),
            resource_traces: vec![ResourceTraceCertificate {
                trace,
                correspondence,
                reachability: resource::ReachabilityWitness {
                    path: vec![],
                    final_marking: lowering.marking.clone(),
                },
                acyclicity: resource::AcyclicWitness {
                    explored_markings: vec![lowering.marking.clone()],
                    steps: BigUint::from(1u8),
                    frontier: vec![],
                },
                lowering,
                value_sources: vec![(
                    composition::ProducerRef::Initial(composition::InputId("initial".into())),
                    SlotValue::Present(initial_value),
                )],
            }],
        },
        selection: Arc::new(
            necoherence_composition_solver::closure::SelectionEvidence::AnyFeasible,
        ),
    };
    let checked =
        necoherence_composition_solver::verification::verify_composition(&prepared, &raw).unwrap();
    let verified = checked.raw().clone();
    verified
}

fn inclusion_rule_tags(value: &serde_json::Value, tags: &mut Vec<String>) {
    match value {
        serde_json::Value::Array(items) => {
            for item in items {
                inclusion_rule_tags(item, tags);
            }
        }
        serde_json::Value::Object(fields) => {
            if fields.contains_key("pair")
                && fields.contains_key("source_shape")
                && fields.contains_key("destination_shape")
                && fields.contains_key("children")
            {
                if let Some(tag) = fields
                    .get("rule")
                    .and_then(|rule| rule.get("tag"))
                    .and_then(serde_json::Value::as_str)
                {
                    tags.push(tag.to_owned());
                }
            }
            for item in fields.values() {
                inclusion_rule_tags(item, tags);
            }
        }
        _ => {}
    }
}

fn replace_first_inclusion_rule(value: &mut serde_json::Value, tag: &str) -> bool {
    match value {
        serde_json::Value::Array(items) => items
            .iter_mut()
            .any(|item| replace_first_inclusion_rule(item, tag)),
        serde_json::Value::Object(fields) => {
            if fields.contains_key("pair")
                && fields.contains_key("source_shape")
                && fields.contains_key("destination_shape")
                && fields.contains_key("children")
            {
                fields.insert("rule".into(), serde_json::json!({"tag":tag}));
                true
            } else {
                fields
                    .values_mut()
                    .any(|item| replace_first_inclusion_rule(item, tag))
            }
        }
        _ => false,
    }
}

fn single_output_composition(
    library: &TypeSignatureLibrary,
    output_type: &str,
    bounds: SearchBounds,
) -> (
    SemanticGraph,
    composition::CompositionInput,
    composition::InvocationPlan,
    composition::OutcomeId,
    composition::PortId,
    SlotContract,
) {
    let graph = check_type_signatures(library).unwrap();
    let contract = SlotContract {
        type_ref: signature_type_ref(output_type),
        required: true,
        nullable: false,
    };
    let function = composition::FunctionRef {
        identity: "produce-output".into(),
        revision: "1".into(),
        content_digest: "b".repeat(64),
    };
    let site = composition::SiteId("producer-site".into());
    let outcome = composition::OutcomeId("success".into());
    let port = composition::PortId("output".into());
    let problem = composition::CompositionInput {
        identity: "first-witness-regression".into(),
        revision: "1".into(),
        basis: composition::SemanticBasis::of(&graph),
        signatures: vec![composition::FunctionSignature {
            reference: function.clone(),
            form: composition::FunctionForm::DeclaredTransform,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![composition::OutcomeContract {
                id: outcome.clone(),
                form: composition::OutcomeForm::Success,
                value_ports: vec![composition::OutputPort {
                    id: port.clone(),
                    contract: contract.clone(),
                    resource_production: None,
                }],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "inhabitation witness regression".into(),
            handles_failure: None,
        }],
        initial_inputs: vec![],
        initial_resources: vec![],
        goal: composition::GoalSpec {
            outputs: vec![composition::GoalPort {
                id: composition::GoalPortId("result".into()),
                contract: contract.clone(),
                source_constraint: composition::SourceConstraint::ProducedBy {
                    site: site.clone(),
                    outcome: outcome.clone(),
                    port: port.clone(),
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: composition::InvocationDomain {
            identity: "one-site-domain".into(),
            revision: "1".into(),
            sites: vec![composition::InvocationSite {
                id: site.clone(),
                function: function.clone(),
            }],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![function.clone()],
            guards: vec![],
        },
        allowed_effects: vec![composition::CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: Some(composition::SelectionPolicy::AnyFeasible),
        bounds,
    };
    let invocation = composition::InvocationPlan {
        site,
        function,
        bindings: vec![],
        resources: vec![],
    };
    (graph, problem, invocation, outcome, port, contract)
}

fn state_after_output(
    invocation: &composition::InvocationPlan,
    outcome: &composition::OutcomeId,
    port: &composition::PortId,
    contract: &SlotContract,
) -> necoherence_composition_solver::search_state::SearchState {
    let producer = composition::ProducerRef::InvocationOutcome {
        site: invocation.site.clone(),
        outcome: outcome.clone(),
        port: port.clone(),
    };
    necoherence_composition_solver::search_state::SearchState {
        available: vec![
            necoherence_composition_solver::search_state::AvailableValue {
                producer,
                contract: contract.clone(),
                resource: None,
            },
        ],
        used_sites: vec![invocation.site.clone()],
        used_guards: vec![],
        facts: vec![],
        trace: vec![TraceStep::Invocation {
            invocation: invocation.clone(),
            outcome: outcome.clone(),
        }],
        pending_failure: None,
    }
}

fn resource_acyclic_witness(input: &resource::SolverInput) -> resource::AcyclicWitness {
    let mut explored = vec![input.marking.clone()];
    let mut cursor = 0;
    while cursor < explored.len() {
        let marking = fixture_item(&explored, cursor).clone();
        for transition in &input.transitions {
            let bindings = resource::bindings_for(input, &transition.identity);
            if resource::transition_enabled_at(&bindings, &marking) {
                let next = resource::apply_branch_at(marking.clone(), transition, &bindings);
                if !explored.contains(&next) {
                    explored.push(next);
                }
            }
        }
        cursor += 1;
    }
    resource::AcyclicWitness {
        steps: BigUint::from(explored.len()),
        explored_markings: explored,
        frontier: vec![],
    }
}

#[allow(clippy::too_many_arguments)]
fn verify_single_output_binding(
    prepared: &composition::PreparedCompositionInput<'_>,
    problem: &composition::CompositionInput,
    invocation: &composition::InvocationPlan,
    outcome: &composition::OutcomeId,
    port: &composition::PortId,
    state: &necoherence_composition_solver::search_state::SearchState,
    terminal: composition::ReturnPlan,
    value: SlotValue,
) {
    let trace = BranchTrace {
        steps: state.trace.clone(),
        terminal: terminal.clone(),
    };
    let (lowering, correspondence) =
        necoherence_composition_solver::lowering::lower_resource_trace(prepared, &trace).unwrap();
    let mut final_marking = lowering.marking.clone();
    for identity in &correspondence.execution_order {
        let transition = lowering
            .transitions
            .iter()
            .find(|transition| transition.identity == *identity)
            .unwrap();
        let bindings = resource::bindings_for(&lowering, identity);
        assert!(resource::transition_enabled_at(&bindings, &final_marking));
        final_marking = resource::apply_branch_at(final_marking, transition, &bindings);
    }
    let producer = composition::ProducerRef::InvocationOutcome {
        site: invocation.site.clone(),
        outcome: outcome.clone(),
        port: port.clone(),
    };
    let raw = necoherence_composition_solver::verification::RawComposition {
        plan: composition::CompositionPlan {
            input_identity: problem.identity.clone(),
            input_revision: problem.revision.clone(),
            root: composition::PlanTree {
                rank: BigUint::from(0u8),
                node: composition::PlanNode::Invoke {
                    invocation: invocation.clone(),
                    arms: vec![(
                        outcome.clone(),
                        composition::PlanTree {
                            rank: BigUint::from(1u8),
                            node: composition::PlanNode::Return(terminal),
                        },
                    )],
                    empty_outcomes: vec![],
                },
            },
        },
        witness: CompositionWitness {
            input_snapshot: problem.clone(),
            initial_membership: necoherence_composition_solver::search_state::initial_membership(
                prepared,
            )
            .unwrap(),
            resource_traces: vec![ResourceTraceCertificate {
                trace,
                correspondence: correspondence.clone(),
                reachability: resource::ReachabilityWitness {
                    path: correspondence.execution_order.clone(),
                    final_marking,
                },
                acyclicity: resource_acyclic_witness(&lowering),
                lowering,
                value_sources: vec![(producer, value)],
            }],
        },
        selection: Arc::new(
            necoherence_composition_solver::closure::SelectionEvidence::AnyFeasible,
        ),
    };
    necoherence_composition_solver::verification::verify_composition(prepared, &raw).unwrap();
}

fn lowering_fixture(
    mutate: impl FnOnce(&mut composition::CompositionInput),
) -> (SemanticGraph, composition::CompositionInput) {
    let (library, mut problem) = composition_fixture();
    mutate(&mut problem);
    (check_type_signatures(&library).unwrap(), problem)
}

fn initial_lot(quantity: BigUint, revision: u8) -> composition::ResourceLot {
    composition::ResourceLot {
        id: composition::LotId("lot".into()),
        token_type: TypeRef::new(
            Arc::new(SourceRef {
                repository: "ncoh-type-signatures".into(),
                revision: "1".into(),
                path: String::new(),
                content_digest: String::new(),
                document_id: String::new(),
                declared_revision: None,
            }),
            "boolean",
            vec![],
        ),
        producer: composition::ResourceProducer::Initial {
            identity: "producer".into(),
            revision: "1".into(),
        },
        revision: BigUint::from(revision),
        quantity,
        provenance: "fixture".into(),
    }
}

#[allow(clippy::result_large_err)]
fn lower(
    graph: &SemanticGraph,
    problem: &composition::CompositionInput,
    steps: Vec<TraceStep>,
    terminal: Option<composition::ReturnPlan>,
) -> std::result::Result<
    (resource::SolverInput, ResourceCorrespondence),
    necoherence_composition_solver::lowering::LoweringFailure,
> {
    let prepared = composition::prepare_direct_composition(
        graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(graph),
    )
    .unwrap();
    let state = necoherence_composition_solver::search_state::initial_state(&prepared);
    let enumeration =
        necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
    let terminal = terminal.unwrap_or_else(|| fixture_item(&enumeration.values, 0).clone());
    necoherence_composition_solver::lowering::lower_resource_trace(
        &prepared,
        &BranchTrace { steps, terminal },
    )
}

fn invalid_lowering(reason: &str) -> necoherence_composition_solver::lowering::LoweringFailure {
    necoherence_composition_solver::lowering::LoweringFailure::Invalid(reason.into())
}

fn capacity_failure(
    required: BigUint,
    limit: BigUint,
) -> necoherence_composition_solver::lowering::LoweringFailure {
    necoherence_composition_solver::lowering::LoweringFailure::Unknown(
        composition::UnresolvedObligation::ResourceCapacityBound { required, limit },
    )
}

fn site_lowering_fixture() -> (SemanticGraph, composition::CompositionInput) {
    let function = composition::FunctionRef {
        identity: "produce-output".into(),
        revision: "1".into(),
        content_digest: "b".repeat(64),
    };
    lowering_fixture(|problem| {
        problem
            .allowed_effects
            .push(composition::CompositionEffect::PureFunction);
        problem.signatures.push(composition::FunctionSignature {
            reference: function.clone(),
            form: composition::FunctionForm::DeclaredTransform,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![composition::OutcomeContract {
                id: composition::OutcomeId("success".into()),
                form: composition::OutcomeForm::Success,
                value_ports: vec![],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "lowering fixture".into(),
            handles_failure: None,
        });
        problem
            .invocation_domain
            .sites
            .push(composition::InvocationSite {
                id: composition::SiteId("producer-site".into()),
                function: function.clone(),
            });
        problem
            .invocation_domain
            .permitted_transforms
            .push(function);
    })
}

fn producer_invocation(
    revision: &str,
    outcome: &str,
    bindings: Vec<(composition::PortId, composition::BindingExpr)>,
) -> TraceStep {
    TraceStep::Invocation {
        invocation: composition::InvocationPlan {
            site: composition::SiteId("producer-site".into()),
            function: composition::FunctionRef {
                identity: "produce-output".into(),
                revision: revision.into(),
                content_digest: "b".repeat(64),
            },
            bindings,
            resources: vec![],
        },
        outcome: composition::OutcomeId(outcome.into()),
    }
}

fn resource_lowering_library() -> TypeSignatureLibrary {
    TypeSignatureLibrary {
        schema: "ncoh-type-signatures@1".into(),
        identity: "resource-lowering-library".into(),
        revision: "1".into(),
        profile: ValueSemanticProfile {
            reference: reference(),
            source_refs: vec![],
            integer_domains: vec![IntegerDomainBinding {
                name: "integer".into(),
                reference: reference(),
                range: IntegerDomain::Inclusive {
                    minimum: BigInt::from(-10),
                    maximum: BigInt::from(10),
                },
                forms: vec![IntegerForm::Number],
            }],
            default_integer_domain: "integer".into(),
            numbers: NumberModel { decimals: false },
            grapheme_rules: None,
            format_bindings: vec![],
            wrappers: vec![],
            tag: None,
            bytes_policy: None,
        },
        sources: vec![],
        provenance: vec![],
        groups: vec![],
        annotations: vec![],
        nodes: vec![TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        }],
        definitions: vec![],
    }
}

fn boolean_slot() -> SlotContract {
    composition::present_contract(signature_type_ref("boolean"))
}

fn resource_lowering_fixture(
    mutate: impl FnOnce(&mut composition::CompositionInput),
) -> (SemanticGraph, composition::CompositionInput) {
    let graph = check_type_signatures(&resource_lowering_library()).unwrap();
    let mut problem = composition::CompositionInput {
        identity: "resource-lowering".into(),
        revision: "1".into(),
        basis: composition::SemanticBasis::of(&graph),
        signatures: vec![],
        initial_inputs: vec![composition::InitialInput {
            id: composition::InputId("initial".into()),
            contract: boolean_slot(),
            source: composition::InitialSource::Argument,
            resource: None,
        }],
        initial_resources: vec![],
        goal: composition::GoalSpec {
            outputs: vec![composition::GoalPort {
                id: composition::GoalPortId("output".into()),
                contract: boolean_slot(),
                source_constraint: composition::SourceConstraint::InitialOnly {
                    input: composition::InputId("initial".into()),
                    path: vec![],
                },
            }],
            failures: vec![],
            final_resources: vec![],
        },
        invocation_domain: composition::InvocationDomain {
            identity: "resource-lowering-domain".into(),
            revision: "1".into(),
            sites: vec![],
            permitted_projections: vec![],
            permitted_constructions: vec![],
            permitted_transforms: vec![],
            guards: vec![],
        },
        allowed_effects: vec![composition::CompositionEffect::PureFunction],
        explicit_order: vec![],
        selection_policy: None,
        bounds: SearchBounds::default(),
    };
    mutate(&mut problem);
    (graph, problem)
}

fn lowering_inclusion(graph: &SemanticGraph) -> Arc<composition::InclusionCertificate> {
    Arc::new(composition::InclusionCertificate {
        basis: composition::SemanticBasis::of(graph),
        source: boolean_slot(),
        destination: boolean_slot(),
        empty_types: vec![],
        pairs: vec![],
        root: BigUint::from(0u8),
    })
}

fn lowering_source(
    graph: &SemanticGraph,
    producer: composition::ProducerRef,
) -> composition::BindingExpr {
    composition::BindingExpr::Source {
        value: composition::ValueRef {
            producer,
            path: vec![],
        },
        projection: composition::ProjectionCertificate {
            profile: reference(),
            source_refs: vec![],
            source: boolean_slot(),
            path: vec![],
            assumptions: vec![],
            destination: boolean_slot(),
        },
        compatibility: composition::BindingCompatibility::Inclusion(lowering_inclusion(graph)),
    }
}

fn initial_value(graph: &SemanticGraph) -> composition::BindingExpr {
    lowering_source(
        graph,
        composition::ProducerRef::Initial(composition::InputId("initial".into())),
    )
}

fn lowering_function(name: &str) -> composition::FunctionRef {
    composition::FunctionRef {
        identity: name.into(),
        revision: "1".into(),
        content_digest: "b".repeat(64),
    }
}

fn lowering_port(id: &str, requirement: Option<&str>) -> composition::InputPort {
    composition::InputPort {
        id: composition::PortId(id.into()),
        contract: boolean_slot(),
        source_constraint: composition::SourceConstraint::AnyCompatible,
        resource_requirement: requirement.map(|id| composition::RequirementId(id.into())),
    }
}

fn port_id(id: &str) -> composition::PortId {
    composition::PortId(id.into())
}

fn lowering_requirement(
    id: &str,
    revision: u8,
    identity: composition::ResourceIdentityConstraint,
) -> composition::ResourceRequirement {
    composition::ResourceRequirement {
        id: composition::RequirementId(id.into()),
        token_type: signature_type_ref("boolean"),
        mode: resource::BindingMode::Read,
        multiplicity: BigUint::from(1u8),
        required_revision: BigUint::from(revision),
        identity,
    }
}

fn lowering_signature(
    name: &str,
    inputs: Vec<composition::InputPort>,
    resource_inputs: Vec<composition::ResourceRequirement>,
) -> composition::FunctionSignature {
    composition::FunctionSignature {
        reference: lowering_function(name),
        form: composition::FunctionForm::DeclaredTransform,
        effect: composition::CompositionEffect::PureFunction,
        inputs,
        outcomes: vec![composition::OutcomeContract {
            id: composition::OutcomeId("success".into()),
            form: composition::OutcomeForm::Success,
            value_ports: vec![],
            produced_resources: vec![],
        }],
        resource_inputs,
        assumption_ref: "lowering fixture".into(),
        handles_failure: None,
    }
}

fn with_lowering_site(
    problem: &mut composition::CompositionInput,
    site: &str,
    signature: composition::FunctionSignature,
) {
    problem
        .invocation_domain
        .sites
        .push(composition::InvocationSite {
            id: composition::SiteId(site.into()),
            function: signature.reference.clone(),
        });
    problem
        .invocation_domain
        .permitted_transforms
        .push(signature.reference.clone());
    problem.signatures.push(signature);
}

fn lowering_lot(id: &str, revision: u8) -> composition::ResourceLot {
    composition::ResourceLot {
        id: composition::LotId(id.into()),
        token_type: signature_type_ref("boolean"),
        producer: composition::ResourceProducer::Initial {
            identity: "producer".into(),
            revision: "1".into(),
        },
        revision: BigUint::from(revision),
        quantity: BigUint::from(1u8),
        provenance: "fixture".into(),
    }
}

fn lowering_lot_binding(
    graph: &SemanticGraph,
    requirement: &str,
    lot: composition::ResourceLotRef,
) -> composition::ResourceBinding {
    composition::ResourceBinding {
        requirement: composition::RequirementId(requirement.into()),
        lot,
        inclusion: lowering_inclusion(graph),
    }
}

fn lowering_invocation(
    site: &str,
    function: &str,
    bindings: Vec<(composition::PortId, composition::BindingExpr)>,
    resources: Vec<composition::ResourceBinding>,
) -> TraceStep {
    TraceStep::Invocation {
        invocation: composition::InvocationPlan {
            site: composition::SiteId(site.into()),
            function: lowering_function(function),
            bindings,
            resources,
        },
        outcome: composition::OutcomeId("success".into()),
    }
}

fn lowering_success(value: composition::BindingExpr) -> composition::ReturnPlan {
    composition::ReturnPlan::Success(vec![(composition::GoalPortId("output".into()), value)])
}

fn lean_operation_source() -> SourceIdentity {
    SourceIdentity {
        repository: "synthetic".into(),
        revision: "1".into(),
        path: "operation".into(),
        content_digest: "b".repeat(64),
    }
}

#[test]
fn signature_composition_from_native_returns_the_input_failure_unchanged() {
    let (library, problem) = composition_fixture();
    let mut raw = solved_raw_composition(&library, &problem);
    raw.witness
        .input_snapshot
        .signatures
        .push(composition::FunctionSignature {
            reference: composition::FunctionRef {
                identity: "pure".into(),
                revision: "1".into(),
                content_digest: "digest".into(),
            },
            form: composition::FunctionForm::Pure,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![composition::InputPort {
                id: composition::PortId("input".into()),
                contract: fixture_item(&problem.initial_inputs, 0).contract.clone(),
                source_constraint: composition::SourceConstraint::InitialOnly {
                    input: composition::InputId("missing".into()),
                    path: vec![],
                },
                resource_requirement: None,
            }],
            outcomes: vec![],
            resource_inputs: vec![],
            assumption_ref: "assumption".into(),
            handles_failure: None,
        });
    let failure = signature_composition_from_native(&library, &problem, &raw, &[]).unwrap_err();
    assert!(matches!(
        failure,
        AdmissionFailure::CompositionInput(
            composition::CompositionInputFailure::InvalidSignature { .. }
        )
    ));
}

#[test]
fn equal_primitive_and_product_inclusion_wire_roundtrip_same_defined_type() {
    let (library, mut problem) = composition_fixture();
    for type_id in ["boolean", "record"] {
        let reference = signature_type_ref(type_id);
        fixture_item_mut(&mut problem.initial_inputs, 0)
            .contract
            .type_ref = reference.clone();
        fixture_item_mut(&mut problem.goal.outputs, 0)
            .contract
            .type_ref = reference;
        let wire = solved_signature_composition(&library, &problem);
        let mut tags = vec![];
        inclusion_rule_tags(&wire["derivation"], &mut tags);
        assert!(!tags.is_empty());
        assert!(tags.iter().all(|tag| tag == "SameDefinedType"));
        let input = assemble_signature_generation(library.clone(), Some(wire), vec![]).unwrap();
        signature_generation_context(
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
            &encode_signature_generation(&input).unwrap(),
        )
        .unwrap();
    }

    let wire = solved_signature_composition(&library, &problem);
    let mut forged = wire;
    assert!(replace_first_inclusion_rule(
        &mut forged["derivation"],
        "Unit"
    ));
    let forged_input = assemble_signature_generation(library, Some(forged), vec![]).unwrap();
    let checked = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&forged_input),
        forged_input,
    )
    .unwrap();
    assert!(verified_signature_derivation(checked.input(), checked.graph()).is_err());
}

#[test]
fn permitted_projection_source_type_roundtrip_preserves_path_and_coordinates() {
    let (library, mut problem) = composition_fixture();
    let reference = signature_type_ref("record");
    problem
        .invocation_domain
        .permitted_projections
        .push(composition::PermittedProjection {
            source_type: reference.clone(),
            path: vec![PathStep::Field("flag".into())],
        });
    let wire = solved_signature_composition(&library, &problem);
    assert_eq!(
        wire["problem"]
            .pointer("/invocation_domain/permitted_projections/0/source_type")
            .and_then(serde_json::Value::as_str),
        Some("record")
    );
    let decoded = decode_signature_problem(&library, &wire["problem"]).unwrap();
    assert_eq!(decoded, problem);
    assert_eq!(
        fixture_item(&decoded.invocation_domain.permitted_projections, 0).source_type,
        reference
    );
    assert_eq!(decoded.basis, problem.basis);
    assert_eq!(
        wire["problem"]
            .pointer("/basis/library_identity")
            .and_then(serde_json::Value::as_str),
        Some(library.identity.as_str())
    );
    assert_eq!(
        wire["problem"]
            .pointer("/basis/library_revision")
            .and_then(serde_json::Value::as_str),
        Some(library.revision.as_str())
    );
}

#[test]
fn declared_guard_source_type_roundtrip_preserves_id_path_and_kind() {
    let (library, mut problem) = composition_fixture();
    let reference = signature_type_ref("record");
    problem
        .invocation_domain
        .guards
        .push(composition::DeclaredGuard {
            id: composition::GuardId("flag-guard".into()),
            source_type: reference,
            path: vec![PathStep::Field("flag".into())],
            kind: composition::GuardKind::Validate(SlotContract {
                type_ref: signature_type_ref("boolean"),
                required: true,
                nullable: false,
            }),
        });
    let wire = solved_signature_composition(&library, &problem);
    assert_eq!(
        wire["problem"]
            .pointer("/invocation_domain/guards/0/source_type")
            .and_then(serde_json::Value::as_str),
        Some("record")
    );
    let decoded = decode_signature_problem(&library, &wire["problem"]).unwrap();
    assert_eq!(
        decoded.invocation_domain.guards,
        problem.invocation_domain.guards
    );
    assert_eq!(decoded, problem);
}

#[test]
fn minimal_solved_projection_composition_public_roundtrip() {
    let (library, mut problem) = composition_fixture();
    problem
        .invocation_domain
        .permitted_projections
        .push(composition::PermittedProjection {
            source_type: signature_type_ref("boolean"),
            path: vec![],
        });
    let wire = solved_signature_composition(&library, &problem);
    let decoded = decode_signature_problem(&library, &wire["problem"]).unwrap();
    assert_eq!(decoded, problem);
    assert_eq!(solved_signature_composition(&library, &decoded), wire);
    let input = assemble_signature_generation(library, Some(wire), vec![]).unwrap();
    admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input.clone(),
    )
    .unwrap();
    let mut changed = input;
    *changed
        .composition
        .as_mut()
        .unwrap()
        .pointer_mut("/derivation/witness/input_snapshot/revision")
        .unwrap() = serde_json::json!("forged");
    changed.basis = signature_basis(
        &changed.signatures,
        changed.composition.as_ref(),
        &changed.entrypoints,
    )
    .unwrap();
    assert!(matches!(
        admit_signature_generation(
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&changed),
            changed
        ),
        Err(AdmissionFailure::Wire(_))
    ));
}

#[test]
fn invalid_supplied_composition_input_preserves_admission_failure() {
    let (library, problem) = composition_fixture();
    let mut composition = solved_signature_composition(&library, &problem);
    let invalid = serde_json::json!({
        "tag": "SuppliedValue",
        "value": {"tag": "Present", "value": {"tag": "String", "value": "invalid"}}
    });
    let problem_source = composition["problem"].pointer_mut("/initial_inputs/0/source");
    assert!(problem_source.is_some());
    if let Some(source) = problem_source {
        *source = invalid.clone();
    }
    let derivation_source =
        composition["derivation"].pointer_mut("/witness/input_snapshot/initial_inputs/0/source");
    assert!(derivation_source.is_some());
    if let Some(source) = derivation_source {
        *source = invalid;
    }
    let input = assemble_signature_generation(library, Some(composition), vec![]).unwrap();
    let result = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    );
    assert!(
        matches!(
            &result,
            Err(AdmissionFailure::CompositionInput(
                composition::CompositionInputFailure::InvalidInitialValue { .. }
            ))
        ),
        "unexpected admission result: {result:?}"
    );
}

#[test]
fn composition_without_an_object_shape_is_a_wire_failure_after_the_certificate() {
    let (library, problem) = composition_fixture();
    let composition = solved_signature_composition(&library, &problem);
    let mut input = assemble_signature_generation(library, Some(composition), vec![]).unwrap();
    input.composition = Some(serde_json::json!("x"));
    let recomputed = signature_basis(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )
    .unwrap();
    input.basis.problem_sha256 = recomputed.problem_sha256;
    input.basis.observations_sha256 = recomputed.observations_sha256;
    let result = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    );
    assert!(
        matches!(
            result,
            Err(AdmissionFailure::Wire(GenerationFailure::Syntax { .. }))
        ),
        "unexpected admission result: {result:?}"
    );
}

#[test]
fn composition_without_a_derivation_is_checked_by_the_certificate_first() {
    let (library, problem) = composition_fixture();
    let expected_input = {
        let composition = solved_signature_composition(&library, &problem);
        assemble_signature_generation(library.clone(), Some(composition), vec![]).unwrap()
    };
    let mut input = expected_input.clone();
    input
        .composition
        .as_mut()
        .and_then(serde_json::Value::as_object_mut)
        .unwrap()
        .remove("derivation");
    let result = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&expected_input),
        input,
    );
    assert!(
        matches!(result, Err(AdmissionFailure::Certificate(_))),
        "unexpected admission result: {result:?}"
    );
}

#[test]
fn composition_without_a_derivation_is_a_wire_failure_once_the_certificate_matches() {
    let (library, problem) = composition_fixture();
    let composition = solved_signature_composition(&library, &problem);
    let mut input = assemble_signature_generation(library, Some(composition), vec![]).unwrap();
    input
        .composition
        .as_mut()
        .and_then(serde_json::Value::as_object_mut)
        .unwrap()
        .remove("derivation");
    input.basis = signature_basis(
        &input.signatures,
        input.composition.as_ref(),
        &input.entrypoints,
    )
    .unwrap();
    let result = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    );
    assert!(
        matches!(
            result,
            Err(AdmissionFailure::Wire(GenerationFailure::Syntax { .. }))
        ),
        "unexpected admission result: {result:?}"
    );
}

#[test]
fn invalid_initial_value_only_in_problem_is_a_composition_input_failure_before_snapshot_check() {
    let (library, problem) = composition_fixture();
    let mut composition = solved_signature_composition(&library, &problem);
    let problem_source = composition["problem"].pointer_mut("/initial_inputs/0/source");
    assert!(problem_source.is_some());
    if let Some(source) = problem_source {
        *source = serde_json::json!({
            "tag": "SuppliedValue",
            "value": {"tag": "Present", "value": {"tag": "String", "value": "invalid"}}
        });
    }
    let input = assemble_signature_generation(library, Some(composition), vec![]).unwrap();
    let result = admit_signature_generation(
        &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
        input,
    );
    assert!(
        matches!(
            &result,
            Err(AdmissionFailure::CompositionInput(
                composition::CompositionInputFailure::InvalidInitialValue { .. }
            ))
        ),
        "unexpected admission result: {result:?}"
    );
}

#[test]
fn unknown_source_type_is_a_typed_composition_input_failure() {
    for role in ["permitted_projections", "guards"] {
        let (library, problem) = composition_fixture();
        let mut wire = solved_signature_composition(&library, &problem);
        let entry = if role == "guards" {
            serde_json::json!({
                "id": "unknown-guard", "source_type": "unknown", "path": [],
                "kind": {"tag": "Presence"}
            })
        } else {
            serde_json::json!({"source_type": "unknown", "path": []})
        };
        *wire["problem"]
            .get_mut("invocation_domain")
            .and_then(|domain| domain.get_mut(role))
            .expect("declared source type role exists") = serde_json::json!([entry]);
        assert!(matches!(
            decode_signature_problem(&library, &wire["problem"]),
            Err(AdmissionFailure::CompositionInput(
                composition::CompositionInputFailure::UnresolvedType(_)
            ))
        ));
        let input = assemble_signature_generation(library, Some(wire), vec![]).unwrap();
        let result = admit_signature_generation(
            &necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input),
            input,
        );
        assert!(
            matches!(&result, Err(AdmissionFailure::CompositionInput(_))),
            "{role}: {result:?}"
        );
    }
}

#[test]
fn bounded_scalar_product_inclusion_and_composition() {
    for (text, cid) in [
        ("generic".to_owned(), false),
        (format!("bafkrei{}", "a".repeat(52)), true),
    ] {
        let (mut library, mut problem) = composition_fixture();
        if cid {
            let preset = decode_value_profile(include_str!(
                "../../../../verification/presets/atproto-data-model/profile.json"
            ))
            .unwrap();
            let rule = preset
                .format_bindings
                .iter()
                .find(|binding| binding.name == "cid")
                .unwrap()
                .rule
                .clone();
            library.profile.format_bindings.push(FormatBinding {
                name: "cid".into(),
                reference: reference(),
                rule,
            });
        }
        library.nodes.push(TypeNodeInput {
            id: "bounded-scalar".into(),
            shape: Shape::String(StringSpec {
                format: if cid {
                    Some(FormatUse::Named("cid".into()))
                } else {
                    Some(FormatUse::Inline(FormatRule::Literal(text.clone())))
                },
                lengths: vec![],
                wrapper: None,
                const_value: None,
                enum_values: None,
                examples: vec![],
                default_value: None,
            }),
        });
        for (id, names) in [
            (
                "getRecord-parameters",
                vec![
                    ("repo", true),
                    ("collection", true),
                    ("rkey", true),
                    ("cid", false),
                ],
            ),
            ("errorBody", vec![("error", true), ("message", false)]),
            ("cid-holder", vec![("cid", true)]),
        ] {
            library.nodes.push(TypeNodeInput {
                id: id.into(),
                shape: Shape::Product(SignatureProduct {
                    fields: names
                        .into_iter()
                        .map(|(name, required)| SignatureField {
                            wire_name: name.into(),
                            slot: SignatureSlot {
                                type_id: "bounded-scalar".into(),
                                required,
                                nullable: false,
                            },
                        })
                        .collect(),
                    extras: SignatureExtraMembers::Reject,
                }),
            });
        }
        let graph = check_type_signatures(&library).unwrap();
        let slot = |id| SlotContract {
            type_ref: signature_type_ref(id),
            required: true,
            nullable: false,
        };
        let source = slot("bounded-scalar");
        let length = text.len();
        if cid {
            assert_eq!(length, 59);
        }
        for maximum in [length - 1, length] {
            let bounds = composition::SearchBounds {
                max_sample_length: BigUint::from(maximum),
                ..Default::default()
            };
            for destination in ["getRecord-parameters", "errorBody"] {
                let destination = slot(destination);
                let samples = composition::inclusion_samples_bounded(
                    &graph,
                    &source.type_ref,
                    &destination.type_ref,
                    &bounds,
                );
                let decision =
                    composition::check_assignable_bounded(&graph, &source, &destination, &bounds);
                if maximum < length {
                    assert!(samples.values.is_empty());
                    assert!(samples
                        .obligations
                        .contains(&composition::SampleObligation::SampleBound));
                    assert!(matches!(
                        decision,
                        composition::CompatibilityDecision::Unknown(_)
                    ));
                } else {
                    assert!(samples.values.contains(&JsonValue::Str(text.clone())));
                    let certificate = match decision {
                        composition::CompatibilityDecision::Incompatible(checked) => {
                            Some(checked.clone())
                        }
                        _ => None,
                    }
                    .expect("expected counterexample");
                    assert!(
                        matches!(certificate.value, SlotValue::Present(JsonValue::Str(ref value)) if value.len() == length)
                    );
                    assert_eq!(
                        certificate.destination_failure.condition,
                        ValueCondition::WrongValueKind("object".into())
                    );
                    inclusion::verify_counterexample(
                        &graph,
                        &certificate.source,
                        &certificate.destination,
                        &certificate,
                    )
                    .unwrap();
                }
            }
            let holder = slot("cid-holder");
            let validator = necoherence::semantic_validation::PreparedValidator::new(
                &graph,
                necoherence::semantic_validation::FormatWorkspace::empty(),
            );
            let projection = composition::project_slot(
                validator.metadata(),
                &holder,
                &[PathStep::Field("cid".into())],
                &[],
            )
            .unwrap();
            assert!(matches!(
                composition::check_assignable_bounded(
                    &graph,
                    &projection.destination,
                    &source,
                    &bounds
                ),
                composition::CompatibilityDecision::Compatible(_)
            ));
            problem.basis = composition::SemanticBasis::of(&graph);
            fixture_item_mut(&mut problem.initial_inputs, 0).contract = source.clone();
            fixture_item_mut(&mut problem.goal.outputs, 0).contract = slot("getRecord-parameters");
            problem.goal.outputs.push(composition::GoalPort {
                id: composition::GoalPortId("error".into()),
                contract: slot("errorBody"),
                source_constraint: composition::SourceConstraint::AnyCompatible,
            });
            problem.bounds = bounds;
            let prepared = composition::prepare_direct_composition(
                &graph,
                problem.clone(),
                composition::operation_checker_without_library(),
                composition::operation_meaning_of(&graph),
            )
            .unwrap();
            let state = necoherence_composition_solver::search_state::initial_state(&prepared);
            let enumeration =
                necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
            assert!(enumeration.values.is_empty());
            if maximum < length {
                assert!(!enumeration.obligations.is_empty());
            } else {
                assert!(enumeration.obligations.is_empty());
                for output in &prepared.input().goal.outputs {
                    let rejected = necoherence_composition_solver::enumeration::enumerate_bindings(
                        &prepared,
                        &state,
                        &output.contract,
                        &output.source_constraint,
                    );
                    assert!(rejected.values.is_empty());
                    assert!(rejected.obligations.is_empty());
                }
            }
            problem.goal.outputs.truncate(1);
        }
    }
}

#[test]
fn first_witness_binds_optional_nested_product_union_absence() {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "boolean".into(),
            shape: Shape::Boolean(BooleanSpec {
                const_value: None,
                default_value: None,
            }),
        },
        TypeNodeInput {
            id: "record".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "flag".into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    library.nodes.push(TypeNodeInput {
        id: "record-choice".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![
                SignatureUnionBranch {
                    target: "record".into(),
                    wire_tag: "record".into(),
                    selector: BranchSelector::Kind(ValueKind::Object),
                },
                SignatureUnionBranch {
                    target: "text".into(),
                    wire_tag: "text".into(),
                    selector: BranchSelector::Kind(ValueKind::String),
                },
            ],
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "optional-envelope".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: "nested".into(),
                slot: SignatureSlot {
                    type_id: "record-choice".into(),
                    required: false,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "optional-envelope", SearchBounds::default());
    let samples = slot_samples(&graph, &problem.bounds, &contract);
    assert_eq!(
        samples.values.first(),
        Some(&SlotValue::Present(JsonValue::Obj(vec![])))
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
    assert!(enumeration.obligations.is_empty());
    let terminal = fixture_item(&enumeration.values, 0).clone();
    assert!(matches!(
        &terminal,
        composition::ReturnPlan::Success(bindings)
            if matches!(&fixture_item(bindings, 0).1,
                composition::BindingExpr::Source {
                    value: composition::ValueRef {
                        producer: composition::ProducerRef::InvocationOutcome { .. },
                        path,
                    },
                    ..
                } if path.is_empty())
    ));
    verify_single_output_binding(
        &prepared,
        &problem,
        &invocation,
        &outcome,
        &port,
        &state,
        terminal,
        SlotValue::Present(JsonValue::Obj(vec![])),
    );
}

#[test]
fn accepted_constant_beyond_sample_bound_produces_verified_source_binding() {
    let mut library = library();
    let constant = "x".repeat(64);
    library.nodes.push(TypeNodeInput {
        id: "oversized-constant".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: Some(constant.clone()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    let bounds = SearchBounds {
        max_sample_length: BigUint::from(59u32),
        ..SearchBounds::default()
    };
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "oversized-constant", bounds);
    let bounded = slot_samples(&graph, &problem.bounds, &contract);
    assert!(bounded.values.is_empty());
    assert!(bounded
        .obligations
        .contains(&composition::SampleObligation::SampleBound));
    let reference = contract.type_ref.clone();
    let value = JsonValue::Str(constant);
    assert_eq!(
        PreparedValidator::new(&graph, FormatWorkspace::empty()).accepts_value(&reference, &value),
        ValueDecision::Accepted
    );
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
    assert!(enumeration.obligations.is_empty());
    assert!(enumeration.values.iter().any(|terminal| matches!(
        terminal,
        composition::ReturnPlan::Success(bindings)
            if matches!(&fixture_item(bindings, 0).1,
                composition::BindingExpr::Source {
                    value: composition::ValueRef {
                        producer: composition::ProducerRef::InvocationOutcome { .. },
                        path,
                    },
                    ..
                } if path.is_empty())
    )));
    verify_single_output_binding(
        &prepared,
        &problem,
        &invocation,
        &outcome,
        &port,
        &state,
        fixture_item(&enumeration.values, 0).clone(),
        SlotValue::Present(value),
    );
}

#[test]
fn shallow_product_fuel_without_samples_leaves_no_possible_binding() {
    let mut library = library();
    library.nodes.extend([
        TypeNodeInput {
            id: "deep-one".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "flag".into(),
                    slot: SignatureSlot {
                        type_id: "text".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "deep-two".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "child".into(),
                    slot: SignatureSlot {
                        type_id: "deep-one".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
        TypeNodeInput {
            id: "deep-three".into(),
            shape: Shape::Product(SignatureProduct {
                fields: vec![SignatureField {
                    wire_name: "child".into(),
                    slot: SignatureSlot {
                        type_id: "deep-two".into(),
                        required: true,
                        nullable: false,
                    },
                }],
                extras: SignatureExtraMembers::Reject,
            }),
        },
    ]);
    let bounds = SearchBounds {
        max_type_obligations: BigUint::from(1u32),
        ..SearchBounds::default()
    };
    let (graph, problem, invocation, outcome, port, contract) =
        single_output_composition(&library, "deep-three", bounds);
    let samples = slot_samples(&graph, &problem.bounds, &contract);
    assert!(samples.values.is_empty());
    assert!(!samples
        .obligations
        .contains(&composition::SampleObligation::SampleBound));
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let state = state_after_output(&invocation, &outcome, &port, &contract);
    let enumeration =
        necoherence_composition_solver::enumeration::enumerate_returns(&prepared, &state);
    assert!(enumeration.values.is_empty());
}

#[test]
fn lowering_compares_lot_quantity_with_the_natural_token_capacity() {
    let huge = BigUint::from(1u8) << 70usize;
    let (graph, problem) = lowering_fixture(|problem| {
        problem.initial_resources.push(initial_lot(huge.clone(), 1));
    });
    assert_eq!(
        lower(&graph, &problem, vec![], None).unwrap_err(),
        capacity_failure(huge.clone(), BigUint::from(100_000u32))
    );
    let limit = BigUint::from(1u8) << 80usize;
    let (graph, problem) = lowering_fixture(|problem| {
        problem.initial_resources.push(initial_lot(huge.clone(), 1));
        problem.bounds.resource_bounds = Some(composition::ResourceBounds {
            max_bindings: BigUint::from(16u8),
            max_search_steps: BigUint::from(16u8),
            max_tokens: limit.clone(),
        });
    });
    assert_eq!(
        lower(&graph, &problem, vec![], None).unwrap_err(),
        capacity_failure(huge, limit)
    );
    let (graph, problem) = lowering_fixture(|problem| {
        problem
            .initial_resources
            .push(initial_lot(BigUint::from(6u8), 1));
        problem.bounds.resource_bounds = Some(composition::ResourceBounds {
            max_bindings: BigUint::from(16u8),
            max_search_steps: BigUint::from(16u8),
            max_tokens: BigUint::from(5u8),
        });
    });
    assert_eq!(
        lower(&graph, &problem, vec![], None).unwrap_err(),
        capacity_failure(BigUint::from(6u8), BigUint::from(5u8))
    );
}

#[test]
fn lowering_counts_all_tokens_against_the_capacity() {
    let (graph, problem) = lowering_fixture(|problem| {
        problem
            .initial_resources
            .push(initial_lot(BigUint::from(2u8), 1));
        problem.bounds.resource_bounds = Some(composition::ResourceBounds {
            max_bindings: BigUint::from(16u8),
            max_search_steps: BigUint::from(16u8),
            max_tokens: BigUint::from(3u8),
        });
    });
    assert_eq!(
        lower(&graph, &problem, vec![], None).unwrap_err(),
        capacity_failure(BigUint::from(4u8), BigUint::from(3u8))
    );
}

#[test]
fn lowering_rejects_steps_that_do_not_belong_to_the_branch() {
    let (graph, problem) = lowering_fixture(|_| {});
    let initial = composition::ValueRef {
        producer: composition::ProducerRef::Initial(composition::InputId("initial".into())),
        path: vec![],
    };
    let guard = TraceStep::Guard {
        guard: composition::GuardId("absent".into()),
        inspected: initial,
        arm: composition::GuardArm::Accepted,
    };
    assert_eq!(
        lower(&graph, &problem, vec![guard], None).unwrap_err(),
        invalid_lowering("guard declaration or producer")
    );
    let invocation = TraceStep::Invocation {
        invocation: composition::InvocationPlan {
            site: composition::SiteId("absent".into()),
            function: composition::FunctionRef {
                identity: "f".into(),
                revision: "1".into(),
                content_digest: "d".into(),
            },
            bindings: vec![],
            resources: vec![],
        },
        outcome: composition::OutcomeId("done".into()),
    };
    assert_eq!(
        lower(&graph, &problem, vec![invocation], None).unwrap_err(),
        invalid_lowering("site signature")
    );
}

#[test]
fn lowering_resolves_the_terminal_goals() {
    let (graph, problem) = lowering_fixture(|problem| {
        problem
            .initial_resources
            .push(initial_lot(BigUint::from(1u8), 3));
        problem
            .goal
            .final_resources
            .push(composition::ResourceGoal {
                lot: composition::ResourceLotRef::Initial(composition::LotId("lot".into())),
                multiplicity: BigUint::from(1u8),
                revision: BigUint::from(4u8),
            });
    });
    assert_eq!(
        lower(&graph, &problem, vec![], None).unwrap_err(),
        invalid_lowering("terminal resource revision")
    );
    let (graph, matching) = lowering_fixture(|problem| {
        problem
            .initial_resources
            .push(initial_lot(BigUint::from(1u8), 3));
        problem
            .goal
            .final_resources
            .push(composition::ResourceGoal {
                lot: composition::ResourceLotRef::Initial(composition::LotId("lot".into())),
                multiplicity: BigUint::from(1u8),
                revision: BigUint::from(3u8),
            });
    });
    let (lowered, correspondence) = lower(&graph, &matching, vec![], None).unwrap();
    assert_eq!(correspondence.lots.len(), 1);
    assert!(lowered.transitions.len() <= 1);
    let embedding = composition::ReturnPlan::Failure {
        embedding: composition::FailureEmbeddingId("absent".into()),
        value: composition::BindingExpr::Product {
            construction: "none".into(),
            type_ref: fixture_item(&matching.initial_inputs, 0)
                .contract
                .type_ref
                .clone(),
            fields: vec![],
        },
    };
    assert_eq!(
        lower(&graph, &matching, vec![], Some(embedding)).unwrap_err(),
        invalid_lowering("failure embedding")
    );
}

#[test]
fn lowering_names_the_invocation_failures_as_lean_does() {
    let (graph, problem) = site_lowering_fixture();
    assert!(lower(
        &graph,
        &problem,
        vec![producer_invocation("1", "success", vec![])],
        None
    )
    .is_ok());
    assert_eq!(
        lower(
            &graph,
            &problem,
            vec![producer_invocation("2", "success", vec![])],
            None
        )
        .unwrap_err(),
        invalid_lowering("function revision")
    );
    assert_eq!(
        lower(
            &graph,
            &problem,
            vec![producer_invocation("1", "absent", vec![])],
            None
        )
        .unwrap_err(),
        invalid_lowering("invocation outcome")
    );
    let argument = composition::BindingExpr::Product {
        construction: "none".into(),
        type_ref: fixture_item(&problem.initial_inputs, 0)
            .contract
            .type_ref
            .clone(),
        fields: vec![],
    };
    assert_eq!(
        lower(
            &graph,
            &problem,
            vec![producer_invocation(
                "1",
                "success",
                vec![(composition::PortId("input".into()), argument)]
            )],
            None
        )
        .unwrap_err(),
        invalid_lowering("binding coverage")
    );
    assert_eq!(
        lower(
            &graph,
            &problem,
            vec![
                producer_invocation("1", "success", vec![]),
                producer_invocation("1", "success", vec![]),
            ],
            None
        )
        .unwrap_err(),
        invalid_lowering("site fired twice")
    );
}

#[test]
fn lowering_names_the_port_binding_failures_as_lean_does() {
    let (graph, consume) = resource_lowering_fixture(|problem| {
        with_lowering_site(
            problem,
            "consumer",
            lowering_signature("consume", vec![lowering_port("input", None)], vec![]),
        );
    });
    let success = lowering_success(initial_value(&graph));
    let later = lowering_source(
        &graph,
        composition::ProducerRef::InvocationOutcome {
            site: composition::SiteId("later-site".into()),
            outcome: composition::OutcomeId("success".into()),
            port: port_id("out"),
        },
    );
    assert_eq!(
        lower(
            &graph,
            &consume,
            vec![lowering_invocation(
                "consumer",
                "consume",
                vec![(port_id("input"), later)],
                vec![]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("value producer is not earlier")
    );
    assert_eq!(
        lower(
            &graph,
            &consume,
            vec![lowering_invocation(
                "consumer",
                "consume",
                vec![(port_id("other"), initial_value(&graph))],
                vec![]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("input binding")
    );
    let (graph, backed) = resource_lowering_fixture(|problem| {
        with_lowering_site(
            problem,
            "consumer",
            lowering_signature(
                "consume-backed",
                vec![lowering_port("input", Some("req"))],
                vec![lowering_requirement(
                    "req",
                    1,
                    composition::ResourceIdentityConstraint::Any,
                )],
            ),
        );
        problem.initial_resources.push(lowering_lot("lot", 1));
    });
    let success = lowering_success(initial_value(&graph));
    let lot = composition::ResourceLotRef::Initial(composition::LotId("lot".into()));
    assert_eq!(
        lower(
            &graph,
            &backed,
            vec![lowering_invocation(
                "consumer",
                "consume-backed",
                vec![(port_id("input"), initial_value(&graph))],
                vec![lowering_lot_binding(&graph, "other", lot.clone())]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("backing requirement")
    );
    assert_eq!(
        lower(
            &graph,
            &backed,
            vec![lowering_invocation(
                "consumer",
                "consume-backed",
                vec![(port_id("input"), initial_value(&graph))],
                vec![lowering_lot_binding(&graph, "req", lot.clone())]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("port resource backing differs")
    );
    assert_eq!(
        lower(
            &graph,
            &backed,
            vec![lowering_invocation(
                "consumer",
                "consume-backed",
                vec![(
                    port_id("input"),
                    composition::BindingExpr::Product {
                        construction: "none".into(),
                        type_ref: signature_type_ref("boolean"),
                        fields: vec![],
                    }
                )],
                vec![lowering_lot_binding(&graph, "req", lot)]
            )],
            Some(success)
        )
        .unwrap_err(),
        invalid_lowering("resource backed input must have one producer")
    );
}

#[test]
fn lowering_names_the_resource_binding_failures_as_lean_does() {
    let (graph, resourced) = resource_lowering_fixture(|problem| {
        with_lowering_site(
            problem,
            "consumer",
            lowering_signature(
                "resourced",
                vec![],
                vec![lowering_requirement(
                    "req",
                    1,
                    composition::ResourceIdentityConstraint::Any,
                )],
            ),
        );
    });
    let success = lowering_success(initial_value(&graph));
    let lot = composition::ResourceLotRef::Initial(composition::LotId("lot".into()));
    assert_eq!(
        lower(
            &graph,
            &resourced,
            vec![lowering_invocation(
                "consumer",
                "resourced",
                vec![],
                vec![lowering_lot_binding(&graph, "other", lot.clone())]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("resource binding")
    );
    let absent = composition::ResourceLotRef::Initial(composition::LotId("absent".into()));
    assert_eq!(
        lower(
            &graph,
            &resourced,
            vec![lowering_invocation(
                "consumer",
                "resourced",
                vec![],
                vec![lowering_lot_binding(&graph, "req", absent)]
            )],
            Some(success.clone())
        )
        .unwrap_err(),
        invalid_lowering("resource producer unavailable")
    );
    let stale = [
        lowering_requirement("req", 2, composition::ResourceIdentityConstraint::Any),
        lowering_requirement(
            "req",
            1,
            composition::ResourceIdentityConstraint::Exactly(
                composition::ResourceProducer::Initial {
                    identity: "other".into(),
                    revision: "1".into(),
                },
            ),
        ),
    ];
    for requirement in stale {
        let (graph, with_lot) = resource_lowering_fixture(|problem| {
            with_lowering_site(
                problem,
                "consumer",
                lowering_signature("resourced", vec![], vec![requirement]),
            );
            problem.initial_resources.push(lowering_lot("lot", 1));
        });
        let success = lowering_success(initial_value(&graph));
        assert_eq!(
            lower(
                &graph,
                &with_lot,
                vec![lowering_invocation(
                    "consumer",
                    "resourced",
                    vec![],
                    vec![lowering_lot_binding(
                        &graph,
                        "req",
                        composition::ResourceLotRef::Initial(composition::LotId("lot".into()))
                    )]
                )],
                Some(success)
            )
            .unwrap_err(),
            invalid_lowering("resource identity or revision")
        );
    }
    let (graph, typed) = resource_lowering_fixture(|problem| {
        with_lowering_site(
            problem,
            "consumer",
            lowering_signature(
                "resourced",
                vec![],
                vec![lowering_requirement(
                    "req",
                    1,
                    composition::ResourceIdentityConstraint::Any,
                )],
            ),
        );
        problem.initial_resources.push(lowering_lot("lot", 1));
    });
    let success = lowering_success(initial_value(&graph));
    assert_eq!(
        lower(
            &graph,
            &typed,
            vec![lowering_invocation(
                "consumer",
                "resourced",
                vec![],
                vec![lowering_lot_binding(&graph, "req", lot)]
            )],
            Some(success)
        )
        .unwrap_err(),
        invalid_lowering("resource type inclusion")
    );
}

#[test]
fn lowering_names_the_return_value_failure_as_lean_does() {
    let (graph, plain) = resource_lowering_fixture(|_| {});
    let absent = lowering_source(
        &graph,
        composition::ProducerRef::InvocationOutcome {
            site: composition::SiteId("absent-site".into()),
            outcome: composition::OutcomeId("success".into()),
            port: port_id("out"),
        },
    );
    assert_eq!(
        lower(&graph, &plain, vec![], Some(lowering_success(absent))).unwrap_err(),
        invalid_lowering("return value producer")
    );
}

#[test]
fn closure_encoding_keeps_an_undeclared_guard_as_a_composition_failure() {
    let (library, problem) = composition_fixture();
    let graph = check_type_signatures(&library).unwrap();
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    let mut raw = solved_raw_composition(&library, &problem);
    raw.selection = Arc::new(
        necoherence_composition_solver::closure::SelectionEvidence::Unique {
            closure: Box::new(
                necoherence_composition_solver::closure::CompositionClosureWitness {
                    input_identity: problem.identity.clone(),
                    input_revision: problem.revision.clone(),
                    nodes: vec![
                        necoherence_composition_solver::closure::CompositionClosureNode {
                            state: necoherence_composition_solver::search_state::initial_state(
                                &prepared,
                            ),
                            actions: vec![
                                necoherence_composition_solver::closure::LocalAction::Guard {
                                    guard: composition::GuardId("undeclared".into()),
                                    inspected: composition::ValueRef {
                                        producer: composition::ProducerRef::Initial(
                                            composition::InputId("input".into()),
                                        ),
                                        path: vec![],
                                    },
                                },
                            ],
                            terminals: vec![],
                        },
                    ],
                    steps: BigUint::from(0u8),
                    binding_candidates: BigUint::from(0u8),
                    branch_nodes: BigUint::from(0u8),
                    frontier: vec![],
                    obligations: vec![],
                },
            ),
            canonical_plan: String::new(),
        },
    );
    assert!(matches!(
        signature_composition_from_native(&library, &problem, &raw, &[]),
        Err(AdmissionFailure::Generation(
            GenerationFailure::Composition(composition::WitnessFailure::GuardNotDominating(_))
        ))
    ));
}

#[test]
fn initial_membership_shortfall_is_reported_as_initial_member_coverage_as_lean_does() {
    let (library, problem) = composition_fixture();
    let mut raw = solved_raw_composition(&library, &problem);
    raw.witness.initial_membership.clear();
    let graph = check_type_signatures(&library).unwrap();
    let prepared = composition::prepare_direct_composition(
        &graph,
        problem.clone(),
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .unwrap();
    assert!(matches!(
        necoherence_composition_solver::verification::verify_composition(&prepared, &raw),
        Err(composition::WitnessFailure::MissingEvidence(reason))
            if reason == "initial member coverage"
    ));
}

#[test]
fn external_outcome_without_value_ports_is_rejected_for_every_function() {
    let (mut library, problem) = composition_fixture();
    library.sources = vec![lean_operation_source()];
    let mut raw = solved_raw_composition(&library, &problem);
    let reference = composition::FunctionRef {
        identity: "pure".into(),
        revision: "1".into(),
        content_digest: "digest".into(),
    };
    raw.witness
        .input_snapshot
        .signatures
        .push(composition::FunctionSignature {
            reference: reference.clone(),
            form: composition::FunctionForm::Pure,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![composition::OutcomeContract {
                id: composition::OutcomeId("external".into()),
                form: composition::OutcomeForm::DeclaredFailure,
                value_ports: vec![],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "assumption".into(),
            handles_failure: None,
        });
    let causes = [(
        reference.clone(),
        vec![(
            composition::OutcomeId("external".into()),
            OutcomeCause::ExternalCondition {
                specification: Origin {
                    source: lean_operation_source(),
                    locator: vec!["external".into()],
                },
            },
        )],
    )];
    let failure = signature_composition_from_native(&library, &problem, &raw, &causes).unwrap_err();
    assert!(matches!(
        failure,
        AdmissionFailure::CompositionInput(composition::CompositionInputFailure::InvalidSignature {
            ref function,
            ref reason,
        }) if *function == reference
            && *reason == composition::InvalidSignatureReason::OutcomeCauseOrExternalFailureValue
    ));
}

#[test]
fn outcome_without_a_cause_names_the_function_and_outcome() {
    let (mut library, problem) = composition_fixture();
    library.sources = vec![lean_operation_source()];
    let mut raw = solved_raw_composition(&library, &problem);
    let reference = composition::FunctionRef {
        identity: "pure".into(),
        revision: "1".into(),
        content_digest: "digest".into(),
    };
    raw.witness
        .input_snapshot
        .signatures
        .push(composition::FunctionSignature {
            reference: reference.clone(),
            form: composition::FunctionForm::Pure,
            effect: composition::CompositionEffect::PureFunction,
            inputs: vec![],
            outcomes: vec![composition::OutcomeContract {
                id: composition::OutcomeId("external".into()),
                form: composition::OutcomeForm::DeclaredFailure,
                value_ports: vec![],
                produced_resources: vec![],
            }],
            resource_inputs: vec![],
            assumption_ref: "assumption".into(),
            handles_failure: None,
        });
    let causes = [(
        reference.clone(),
        vec![(
            composition::OutcomeId("other".into()),
            OutcomeCause::ExternalCondition {
                specification: Origin {
                    source: lean_operation_source(),
                    locator: vec!["external".into()],
                },
            },
        )],
    )];
    let failure = signature_composition_from_native(&library, &problem, &raw, &causes).unwrap_err();
    assert!(matches!(
        failure,
        AdmissionFailure::CompositionInput(composition::CompositionInputFailure::InvalidSignature {
            ref function,
            ref reason,
        }) if *function == reference
            && *reason
                == composition::InvalidSignatureReason::Contract(
                    composition::SignatureContractFailure::MissingOutcomeCause {
                        function: reference.clone(),
                        outcome: composition::OutcomeId("external".into()),
                    }
                )
    ));
}
