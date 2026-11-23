// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

use super::closure::*;
use super::diagnostics::check as check_diagnostic;
use super::document::{WireCompositionClosureWitness, WireSelectionEvidence};
use super::enumeration::*;
use super::lowering::{type_identity, ResourceCorrespondence};
use super::problem_codec::{encode_problem, wire_basis};
use super::search_state::*;
use super::verification::*;
use necoherence::exact_json::JsonValue as ExchangeJson;
use necoherence::semantic_composition::*;
use necoherence::semantic_exchange::{
    keys, syntax, GenerationFailure, Wire, WireDecode, WireEncode,
};
use necoherence::semantic_types::{
    PathStep, SemanticGraph, SlotContract, SlotValue, TypeRef, ValuePath,
};
use necoherence::signature_composition_codec::*;
use necoherence::signature_composition_codec::{
    array, decode_all, decode_guard_arm, decode_identifier, decode_optional, decode_pair,
    decode_resource_lot_ref, decode_slot_contract, decode_slot_value, field_path, member,
    payload_with, read, read_with, tag_of, tagged_fields, to_exchange, unit_variant, unknown_tag,
    Decoded,
};
use necoherence::signature_derivation_codec::*;
use necoherence::type_signatures::{OutcomeCause, TypeSignatureLibrary};
use necoherence::typed_mapping::{AcyclicWitness, ReachabilityWitness, SolverInput};
use num_bigint::BigUint;
use num_traits::ToPrimitive;
use serde_json::{json, Value};
use std::sync::Arc;

fn declared_shape(library: &TypeSignatureLibrary, id: &str) -> Decoded<Value> {
    declared_type_shape(library, id).and_then(native)
}

fn encode_inclusion_rule(value: &InclusionRule) -> Value {
    let name = match value {
        InclusionRule::SameDefinedType => "SameDefinedType",
        InclusionRule::EmptySource => "EmptySource",
        InclusionRule::Boolean => "Boolean",
        InclusionRule::IntegerIntersection => "IntegerIntersection",
        InclusionRule::FiniteStrings => "FiniteStrings",
        InclusionRule::StringConditions => "StringConditions",
        InclusionRule::BytesLength => "BytesLength",
        InclusionRule::Unit => "Unit",
        InclusionRule::UnfoldSource => "UnfoldSource",
        InclusionRule::UnfoldDestination => "UnfoldDestination",
        InclusionRule::Array => "Array",
        InclusionRule::Product => "Product",
        InclusionRule::SourceUnion => "SourceUnion",
        InclusionRule::DestinationUnion => "DestinationUnion",
    };
    unit_tag(name)
}

fn encode_type_pair(value: &TypePair) -> Value {
    object(vec![
        ("source", encode_slot_contract(&value.source)),
        ("destination", encode_slot_contract(&value.destination)),
        ("source_tag", optional(&value.source_tag, |tag| text(tag))),
    ])
}

fn encode_pair_entry(library: &TypeSignatureLibrary, value: &PairEntry) -> Decoded<Value> {
    Ok(object(vec![
        ("pair", encode_type_pair(&value.pair)),
        (
            "source_shape",
            declared_shape(library, &value.pair.source.type_ref.definition_name)?,
        ),
        (
            "destination_shape",
            declared_shape(library, &value.pair.destination.type_ref.definition_name)?,
        ),
        ("rule", encode_inclusion_rule(&value.rule)),
        (
            "children",
            Value::Array(value.children.iter().map(decimal).collect()),
        ),
    ]))
}

fn encode_inclusion(
    library: &TypeSignatureLibrary,
    value: &InclusionCertificate,
) -> Decoded<Value> {
    Ok(object(vec![
        ("basis", wire_basis(library)?),
        ("source", encode_slot_contract(&value.source)),
        ("destination", encode_slot_contract(&value.destination)),
        (
            "empty_types",
            Value::Array(value.empty_types.iter().map(encode_type_ref).collect()),
        ),
        (
            "pairs",
            Value::Array(
                value
                    .pairs
                    .iter()
                    .map(|pair| encode_pair_entry(library, pair))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        ("root", decimal(&value.root)),
    ]))
}

fn encode_producer_ref(value: &ProducerRef) -> Value {
    match value {
        ProducerRef::Initial(input) => tuple_tag("Initial", text(&input.0)),
        ProducerRef::InvocationOutcome {
            site,
            outcome,
            port,
        } => record_tag(
            "InvocationOutcome",
            vec![
                ("site", text(&site.0)),
                ("outcome", text(&outcome.0)),
                ("port", text(&port.0)),
            ],
        ),
    }
}

fn encode_value_ref(value: &ValueRef) -> Value {
    object(vec![
        ("producer", encode_producer_ref(&value.producer)),
        ("path", encode_value_path(&value.path)),
    ])
}

fn encode_projection_assumption(value: &ProjectionAssumption) -> Value {
    match value {
        ProjectionAssumption::Present(path) => tuple_tag("Present", encode_value_path(path)),
        ProjectionAssumption::NonNull(path) => tuple_tag("NonNull", encode_value_path(path)),
        ProjectionAssumption::Variant { path, tag } => record_tag(
            "Variant",
            vec![("path", encode_value_path(path)), ("tag", text(tag))],
        ),
        ProjectionAssumption::IndexPresent { path, index } => record_tag(
            "IndexPresent",
            vec![("path", encode_value_path(path)), ("index", decimal(index))],
        ),
    }
}

fn encode_projection(value: &ProjectionCertificate) -> Decoded<Value> {
    Ok(object(vec![
        ("profile", native(&value.profile)?),
        (
            "source_refs",
            Value::Array(
                value
                    .source_refs
                    .iter()
                    .map(native)
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        ("source", encode_slot_contract(&value.source)),
        ("path", encode_value_path(&value.path)),
        (
            "assumptions",
            Value::Array(
                value
                    .assumptions
                    .iter()
                    .map(encode_projection_assumption)
                    .collect(),
            ),
        ),
        ("destination", encode_slot_contract(&value.destination)),
    ]))
}

fn encode_binding_compatibility(
    library: &TypeSignatureLibrary,
    value: &BindingCompatibility,
) -> Decoded<Value> {
    match value {
        BindingCompatibility::Inclusion(certificate) => Ok(tuple_tag(
            "Inclusion",
            encode_inclusion(library, certificate)?,
        )),
        BindingCompatibility::SuppliedValue { value } => Ok(record_tag(
            "SuppliedValue",
            vec![("value", encode_slot_value(value)?)],
        )),
    }
}

fn encode_binding(library: &TypeSignatureLibrary, value: &BindingExpr) -> Decoded<Value> {
    match value {
        BindingExpr::Source {
            value,
            projection,
            compatibility,
        } => Ok(record_tag(
            "Source",
            vec![
                ("value", encode_value_ref(value)),
                ("projection", encode_projection(projection)?),
                (
                    "compatibility",
                    encode_binding_compatibility(library, compatibility)?,
                ),
            ],
        )),
        BindingExpr::Product {
            construction,
            type_ref,
            fields,
        } => Ok(record_tag(
            "Product",
            vec![
                ("construction", text(construction)),
                ("type_id", encode_type_ref(type_ref)),
                (
                    "fields",
                    Value::Array(
                        fields
                            .iter()
                            .map(|(name, binding)| {
                                Ok(Value::Array(vec![
                                    text(name),
                                    encode_binding(library, binding)?,
                                ]))
                            })
                            .collect::<Decoded<Vec<Value>>>()?,
                    ),
                ),
            ],
        )),
    }
}

fn encode_invocation(library: &TypeSignatureLibrary, value: &InvocationPlan) -> Decoded<Value> {
    Ok(object(vec![
        ("site", text(&value.site.0)),
        ("function", encode_function_ref(&value.function)),
        (
            "bindings",
            Value::Array(
                value
                    .bindings
                    .iter()
                    .map(|(port, binding)| {
                        Ok(Value::Array(vec![
                            text(&port.0),
                            encode_binding(library, binding)?,
                        ]))
                    })
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        (
            "resources",
            Value::Array(
                value
                    .resources
                    .iter()
                    .map(|resource| {
                        Ok(object(vec![
                            ("requirement", text(&resource.requirement.0)),
                            ("lot", encode_resource_lot_ref(&resource.lot)),
                            ("inclusion", encode_inclusion(library, &resource.inclusion)?),
                        ]))
                    })
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
    ]))
}

fn encode_return(library: &TypeSignatureLibrary, value: &ReturnPlan) -> Decoded<Value> {
    match value {
        ReturnPlan::Success(outputs) => Ok(tuple_tag(
            "Success",
            Value::Array(
                outputs
                    .iter()
                    .map(|(goal, binding)| {
                        Ok(Value::Array(vec![
                            text(&goal.0),
                            encode_binding(library, binding)?,
                        ]))
                    })
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        )),
        ReturnPlan::Failure { embedding, value } => Ok(record_tag(
            "Failure",
            vec![
                ("embedding", text(&embedding.0)),
                ("value", encode_binding(library, value)?),
            ],
        )),
    }
}

fn encode_plan_tree(library: &TypeSignatureLibrary, value: &PlanTree) -> Decoded<Value> {
    let node = match &value.node {
        PlanNode::Invoke {
            invocation,
            arms,
            empty_outcomes,
        } => record_tag(
            "Invoke",
            vec![
                ("invocation", encode_invocation(library, invocation)?),
                (
                    "arms",
                    Value::Array(
                        arms.iter()
                            .map(|(outcome, child)| {
                                Ok(Value::Array(vec![
                                    text(&outcome.0),
                                    encode_plan_tree(library, child)?,
                                ]))
                            })
                            .collect::<Decoded<Vec<Value>>>()?,
                    ),
                ),
                (
                    "empty_outcomes",
                    Value::Array(empty_outcomes.iter().map(|id| text(&id.0)).collect()),
                ),
            ],
        ),
        PlanNode::Guard {
            guard,
            inspected,
            arms,
        } => record_tag(
            "Guard",
            vec![
                ("guard", text(&guard.0)),
                ("inspected", encode_value_ref(inspected)),
                (
                    "arms",
                    Value::Array(
                        arms.iter()
                            .map(|(arm, child)| {
                                Ok(Value::Array(vec![
                                    encode_guard_arm(arm),
                                    encode_plan_tree(library, child)?,
                                ]))
                            })
                            .collect::<Decoded<Vec<Value>>>()?,
                    ),
                ),
            ],
        ),
        PlanNode::Return(terminal) => tuple_tag("Return", encode_return(library, terminal)?),
    };
    Ok(object(vec![("rank", decimal(&value.rank)), ("node", node)]))
}

pub(crate) fn encode_composition_plan(
    library: &TypeSignatureLibrary,
    value: &CompositionPlan,
) -> Decoded<Value> {
    Ok(object(vec![
        ("input_identity", text(&value.input_identity)),
        ("input_revision", text(&value.input_revision)),
        ("root", encode_plan_tree(library, &value.root)?),
    ]))
}

fn encode_trace_step(library: &TypeSignatureLibrary, value: &TraceStep) -> Decoded<Value> {
    match value {
        TraceStep::Invocation {
            invocation,
            outcome,
        } => Ok(record_tag(
            "Invocation",
            vec![
                ("invocation", encode_invocation(library, invocation)?),
                ("outcome", text(&outcome.0)),
            ],
        )),
        TraceStep::Guard {
            guard,
            inspected,
            arm,
        } => Ok(record_tag(
            "Guard",
            vec![
                ("guard", text(&guard.0)),
                ("inspected", encode_value_ref(inspected)),
                ("arm", encode_guard_arm(arm)),
            ],
        )),
    }
}

fn encode_branch_trace(library: &TypeSignatureLibrary, value: &BranchTrace) -> Decoded<Value> {
    Ok(object(vec![
        (
            "steps",
            Value::Array(
                value
                    .steps
                    .iter()
                    .map(|step| encode_trace_step(library, step))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        ("terminal", encode_return(library, &value.terminal)?),
    ]))
}

fn encode_resource_type_ids(graph: &SemanticGraph, value: &mut Value) {
    match value {
        Value::Array(values) => values
            .iter_mut()
            .for_each(|value| encode_resource_type_ids(graph, value)),
        Value::Object(fields) => {
            for (key, value) in fields.iter_mut() {
                if key == "token_type" {
                    if let Value::String(text) = value {
                        *text = resource_type_id(graph, false, text);
                    }
                } else {
                    encode_resource_type_ids(graph, value);
                }
            }
        }
        _ => {}
    }
}

fn encode_resource_trace(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    value: &ResourceTraceCertificate,
) -> Decoded<Value> {
    let mut lowering = native(&value.lowering)?;
    encode_resource_type_ids(graph, &mut lowering);
    let mut correspondence = native(&value.correspondence)?;
    if let Some(lots) = correspondence.get_mut("lots") {
        encode_resource_type_ids(graph, lots);
    }
    Ok(object(vec![
        ("trace", encode_branch_trace(library, &value.trace)?),
        ("lowering", lowering),
        ("correspondence", correspondence),
        ("reachability", native(&value.reachability)?),
        ("acyclicity", native(&value.acyclicity)?),
        ("value_sources", native(&value.value_sources)?),
    ]))
}

pub(crate) fn encode_resource_traces(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    value: &[ResourceTraceCertificate],
) -> Decoded<Value> {
    Ok(Value::Array(
        value
            .iter()
            .map(|trace| encode_resource_trace(library, graph, trace))
            .collect::<Decoded<Vec<Value>>>()?,
    ))
}

fn encode_failure_origin(value: &FailureOrigin) -> Value {
    match value {
        FailureOrigin::Function { function, outcome } => record_tag(
            "Function",
            vec![
                ("function", encode_function_ref(function)),
                ("outcome", text(&outcome.0)),
            ],
        ),
        FailureOrigin::Guard { guard, arm } => record_tag(
            "Guard",
            vec![("guard", text(&guard.0)), ("arm", encode_guard_arm(arm))],
        ),
    }
}

fn encode_available_value(value: &AvailableValue) -> Value {
    object(vec![
        ("producer", encode_producer_ref(&value.producer)),
        ("contract", encode_slot_contract(&value.contract)),
        (
            "resource",
            optional(&value.resource, encode_resource_lot_ref),
        ),
    ])
}

fn decode_available_value(value: &ExchangeJson, path: &str) -> Decoded<AvailableValue> {
    let members = keys(value, path, &["producer", "contract", "resource"])?;
    Ok(AvailableValue {
        producer: read_with(members, path, "producer", decode_producer_ref)?,
        contract: read_with(members, path, "contract", decode_slot_contract)?,
        resource: read_with(members, path, "resource", |value, path| {
            decode_optional(value, path, decode_resource_lot_ref)
        })?,
    })
}

fn encode_branch_fact(value: &BranchFact) -> Decoded<Value> {
    Ok(object(vec![
        ("guard", text(&value.guard.0)),
        ("inspected", encode_value_ref(&value.inspected)),
        ("arm", encode_guard_arm(&value.arm)),
        (
            "refinement",
            optional(&value.refinement, encode_slot_contract),
        ),
        (
            "assumptions",
            Value::Array(
                value
                    .assumptions
                    .iter()
                    .map(encode_projection_assumption)
                    .collect(),
            ),
        ),
        (
            "exact",
            match &value.exact {
                Some(exact) => encode_slot_value(exact)?,
                None => Value::Null,
            },
        ),
    ]))
}

fn encode_search_state(library: &TypeSignatureLibrary, value: &SearchState) -> Decoded<Value> {
    Ok(object(vec![
        (
            "available",
            Value::Array(value.available.iter().map(encode_available_value).collect()),
        ),
        (
            "used_sites",
            Value::Array(value.used_sites.iter().map(|site| text(&site.0)).collect()),
        ),
        (
            "used_guards",
            Value::Array(
                value
                    .used_guards
                    .iter()
                    .map(|guard| text(&guard.0))
                    .collect(),
            ),
        ),
        (
            "facts",
            Value::Array(
                value
                    .facts
                    .iter()
                    .map(encode_branch_fact)
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        (
            "trace",
            Value::Array(
                value
                    .trace
                    .iter()
                    .map(|step| encode_trace_step(library, step))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        (
            "pending_failure",
            optional(&value.pending_failure, encode_failure_origin),
        ),
    ]))
}

fn encode_choice(library: &TypeSignatureLibrary, value: &ChoiceSkeleton) -> Decoded<Value> {
    match value {
        ChoiceSkeleton::Invoke {
            invocation,
            outcomes,
            empty_outcomes,
        } => Ok(record_tag(
            "Invoke",
            vec![
                ("invocation", encode_invocation(library, invocation)?),
                (
                    "outcomes",
                    Value::Array(outcomes.iter().map(|outcome| text(&outcome.0)).collect()),
                ),
                (
                    "empty_outcomes",
                    Value::Array(
                        empty_outcomes
                            .iter()
                            .map(|outcome| text(&outcome.0))
                            .collect(),
                    ),
                ),
            ],
        )),
        ChoiceSkeleton::Guard {
            guard,
            inspected,
            arms,
        } => Ok(record_tag(
            "Guard",
            vec![
                ("guard", text(&guard.0)),
                ("inspected", encode_value_ref(inspected)),
                (
                    "arms",
                    Value::Array(arms.iter().map(encode_guard_arm).collect()),
                ),
            ],
        )),
    }
}

fn encode_choice_coverage(
    library: &TypeSignatureLibrary,
    value: &ChoiceCoverage,
) -> Decoded<Value> {
    Ok(object(vec![
        ("choice", encode_choice(library, &value.choice)?),
        (
            "children",
            Value::Array(value.children.iter().map(decimal).collect()),
        ),
    ]))
}

fn encode_terminal_coverage(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    value: &TerminalCoverage,
) -> Decoded<Value> {
    let assessment = match &value.assessment {
        TerminalAssessment::Feasible(certificate) => tuple_tag(
            "Feasible",
            encode_resource_trace(library, graph, certificate)?,
        ),
        _ => {
            return Err(syntax(
                "$.composition.derivation.selection",
                "closure terminal assessment",
            ))
        }
    };
    Ok(object(vec![
        ("terminal", encode_return(library, &value.terminal)?),
        ("assessment", assessment),
    ]))
}

fn encode_missing_supply(value: &MissingSupply) -> Value {
    object(vec![
        ("site", optional(&value.site, |site| text(&site.0))),
        ("port", text(&value.port)),
        ("contract", encode_slot_contract(&value.contract)),
    ])
}

fn encode_closed_state(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    value: &ClosedSearchState,
) -> Decoded<Value> {
    Ok(object(vec![
        ("state", encode_search_state(library, &value.state)?),
        (
            "terminals",
            Value::Array(
                value
                    .terminals
                    .iter()
                    .map(|terminal| encode_terminal_coverage(library, graph, terminal))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        (
            "choices",
            Value::Array(
                value
                    .choices
                    .iter()
                    .map(|choice| encode_choice_coverage(library, choice))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        ("rejected_connections", native(&value.rejected_connections)?),
        (
            "missing_supply",
            Value::Array(
                value
                    .missing_supply
                    .iter()
                    .map(encode_missing_supply)
                    .collect(),
            ),
        ),
    ]))
}

fn encode_closure(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
    value: &WireCompositionClosureWitness,
) -> Decoded<Value> {
    Ok(object(vec![
        (
            "input_snapshot",
            encode_problem(library, &value.input_snapshot, causes)?,
        ),
        ("root", decimal(&value.root)),
        (
            "states",
            Value::Array(
                value
                    .states
                    .iter()
                    .map(|state| encode_closed_state(library, graph, state))
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
    ]))
}

pub(crate) fn encode_selection(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
    value: &WireSelectionEvidence,
) -> Decoded<Value> {
    match value {
        WireSelectionEvidence::AnyFeasible => Ok(unit_tag("AnyFeasible")),
        WireSelectionEvidence::Unique {
            closure,
            canonical_plan,
        } => Ok(record_tag(
            "Unique",
            vec![
                ("closure", encode_closure(library, graph, causes, closure)?),
                ("canonical_plan", text(canonical_plan)),
            ],
        )),
    }
}

fn decode_resource_type_ids(graph: &SemanticGraph, value: &ExchangeJson) -> ExchangeJson {
    match value {
        ExchangeJson::Arr(values) => ExchangeJson::Arr(
            values
                .iter()
                .map(|value| decode_resource_type_ids(graph, value))
                .collect(),
        ),
        ExchangeJson::Obj(fields) => ExchangeJson::Obj(
            fields
                .iter()
                .map(|(key, value)| {
                    let mapped = match (key.as_str(), value) {
                        ("token_type", ExchangeJson::Str(text)) => {
                            ExchangeJson::Str(resource_type_id(graph, true, text))
                        }
                        ("token_type", other) => other.clone(),
                        _ => decode_resource_type_ids(graph, value),
                    };
                    (key.clone(), mapped)
                })
                .collect(),
        ),
        other => other.clone(),
    }
}

fn decode_correspondence(graph: &SemanticGraph, value: &ExchangeJson) -> ExchangeJson {
    match value {
        ExchangeJson::Obj(fields) => ExchangeJson::Obj(
            fields
                .iter()
                .map(|(key, field)| {
                    let mapped = if key == "lots" {
                        decode_resource_type_ids(graph, field)
                    } else {
                        field.clone()
                    };
                    (key.clone(), mapped)
                })
                .collect(),
        ),
        other => other.clone(),
    }
}
fn decode_trace_step(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<TraceStep> {
    match tag_of(value, path)? {
        "Invocation" => {
            let row = tagged_fields(value, path, &["invocation", "outcome"])?;
            Ok(TraceStep::Invocation {
                invocation: read_with(row, path, "invocation", |value, path| {
                    decoder.decode_invocation(value, path)
                })?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
            })
        }
        "Guard" => {
            let row = tagged_fields(value, path, &["guard", "inspected", "arm"])?;
            Ok(TraceStep::Guard {
                guard: read_with(row, path, "guard", |value, path| {
                    decode_identifier(value, path, GuardId)
                })?,
                inspected: read_with(row, path, "inspected", |value, path| {
                    decoder.decode_value_ref(value, path)
                })?,
                arm: read_with(row, path, "arm", decode_guard_arm)?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_branch_trace(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<BranchTrace> {
    let members = keys(value, path, &["steps", "terminal"])?;
    Ok(BranchTrace {
        steps: read_with(members, path, "steps", |value, path| {
            decode_all(value, path, |value, path| {
                decode_trace_step(decoder, value, path)
            })
        })?,
        terminal: read_with(members, path, "terminal", |value, path| {
            decoder.decode_return(value, path)
        })?,
    })
}

fn decode_resource_trace(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<ResourceTraceCertificate> {
    let members = keys(
        value,
        path,
        &[
            "trace",
            "lowering",
            "correspondence",
            "reachability",
            "acyclicity",
            "value_sources",
        ],
    )?;
    keys(
        member(members, path, "correspondence")?,
        &field_path(path, "correspondence"),
        &["lots", "values", "normalized_bindings", "execution_order"],
    )?;
    Ok(ResourceTraceCertificate {
        trace: read_with(members, path, "trace", |value, path| {
            decode_branch_trace(decoder, value, path)
        })?,
        lowering: read_with(members, path, "lowering", |value, path| {
            SolverInput::decode_wire(&decode_resource_type_ids(decoder.graph, value), path)
        })?,
        correspondence: read_with(members, path, "correspondence", |value, path| {
            ResourceCorrespondence::decode_wire(&decode_correspondence(decoder.graph, value), path)
        })?,
        reachability: read_with(members, path, "reachability", |value, path| {
            ReachabilityWitness::decode_wire(value, path)
        })?,
        acyclicity: read_with(members, path, "acyclicity", |value, path| {
            AcyclicWitness::decode_wire(value, path)
        })?,
        value_sources: read(members, path, "value_sources")?,
    })
}
fn decode_search_state(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<SearchState> {
    let members = keys(
        value,
        path,
        &[
            "available",
            "used_sites",
            "used_guards",
            "facts",
            "trace",
            "pending_failure",
        ],
    )?;
    let trace = read_with(members, path, "trace", |value, path| {
        decode_all(value, path, |value, path| {
            decode_trace_step(decoder, value, path)
        })
    })?;
    Ok(SearchState {
        available: read_with(members, path, "available", |value, path| {
            decode_all(value, path, decode_available_value)
        })?,
        used_sites: read_with(members, path, "used_sites", |value, path| {
            decode_all(value, path, |value, path| {
                decode_identifier(value, path, SiteId)
            })
        })?,
        used_guards: read_with(members, path, "used_guards", |value, path| {
            decode_all(value, path, |value, path| {
                decode_identifier(value, path, GuardId)
            })
        })?,
        facts: read_with(members, path, "facts", |value, path| {
            decode_all(value, path, |value, path| {
                decode_branch_fact(decoder, value, path)
            })
        })?,
        trace,
        pending_failure: read_with(members, path, "pending_failure", |value, path| {
            decode_optional(value, path, decode_failure_origin)
        })?,
    })
}

fn decode_branch_fact(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<BranchFact> {
    let members = keys(
        value,
        path,
        &[
            "guard",
            "inspected",
            "arm",
            "refinement",
            "assumptions",
            "exact",
        ],
    )?;
    Ok(BranchFact {
        guard: read_with(members, path, "guard", |value, path| {
            decode_identifier(value, path, GuardId)
        })?,
        inspected: read_with(members, path, "inspected", |value, path| {
            decoder.decode_value_ref(value, path)
        })?,
        arm: read_with(members, path, "arm", decode_guard_arm)?,
        refinement: read_with(members, path, "refinement", |value, path| {
            decode_optional(value, path, decode_slot_contract)
        })?,
        assumptions: read_with(members, path, "assumptions", |value, path| {
            decode_all(value, path, decode_projection_assumption)
        })?,
        exact: read_with(members, path, "exact", |value, path| {
            decode_optional(value, path, decode_slot_value)
        })?,
    })
}

fn decode_choice_action(
    decoder: &PlanDecoder<'_, '_>,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<LocalAction> {
    match tag_of(value, path)? {
        "Invoke" => {
            let row = tagged_fields(value, path, &["invocation", "outcomes", "empty_outcomes"])?;
            Ok(LocalAction::Invocation(read_with(
                row,
                path,
                "invocation",
                |value, path| decoder.decode_invocation(value, path),
            )?))
        }
        "Guard" => {
            let row = tagged_fields(value, path, &["guard", "inspected", "arms"])?;
            Ok(LocalAction::Guard {
                guard: read_with(row, path, "guard", |value, path| {
                    decode_identifier(value, path, GuardId)
                })?,
                inspected: read_with(row, path, "inspected", |value, path| {
                    decoder.decode_value_ref(value, path)
                })?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_closure_terminals(
    decoder: &PlanDecoder<'_, '_>,
    members: &[(String, ExchangeJson)],
    path: &str,
) -> Decoded<Vec<ResourceTraceCertificate>> {
    let terminals_path = field_path(path, "terminals");
    let mut certificates = Vec::new();
    for (index, terminal) in array(member(members, path, "terminals")?, &terminals_path)?
        .iter()
        .enumerate()
    {
        let terminal_path = format!("{terminals_path}[{index}]");
        let row = keys(terminal, &terminal_path, &["terminal", "assessment"])?;
        let plan_json = member(row, &terminal_path, "terminal")?;
        check_diagnostic(decoder.library, decoder.problem, "ReturnPlan", plan_json)?;
        let plan = decoder.decode_return(plan_json, &field_path(&terminal_path, "terminal"))?;
        let assessment = member(row, &terminal_path, "assessment")?;
        let assessment_path = field_path(&terminal_path, "assessment");
        check_diagnostic(
            decoder.library,
            decoder.problem,
            "TerminalAssessment",
            assessment,
        )?;
        if tag_of(assessment, &assessment_path)? == "Feasible" {
            let certificate = payload_with(assessment, &assessment_path, |value, path| {
                decode_resource_trace(decoder, value, path)
            })?;
            if certificate.trace.terminal != plan {
                return Err(syntax("$", "terminal assessment mismatch"));
            }
            certificates.push(certificate);
        }
    }
    Ok(certificates)
}

fn decode_closure_choices(
    decoder: &PlanDecoder<'_, '_>,
    members: &[(String, ExchangeJson)],
    path: &str,
    states: &[SearchState],
    state: &SearchState,
) -> Decoded<Vec<LocalAction>> {
    let choices_path = field_path(path, "choices");
    let mut actions = Vec::new();
    for (index, coverage) in array(member(members, path, "choices")?, &choices_path)?
        .iter()
        .enumerate()
    {
        let coverage_path = format!("{choices_path}[{index}]");
        let row = keys(coverage, &coverage_path, &["choice", "children"])?;
        check_diagnostic(decoder.library, decoder.problem, "ChoiceCoverage", coverage)?;
        let choice = member(row, &coverage_path, "choice")?;
        let action = decode_choice_action(decoder, choice, &field_path(&coverage_path, "choice"))?;
        let successors = action_successors(decoder.prepared, state, &action)
            .map_err(GenerationFailure::Composition)?;
        let expected = local_action_choice(decoder.prepared, state, &action)
            .map_err(GenerationFailure::Composition)?;
        if !necoherence::exact_json::same_json(
            choice,
            &to_exchange(&encode_choice(decoder.library, &expected)?)?,
        ) {
            return Err(syntax("$", "closure choice coverage mismatch"));
        }
        let indices: Vec<BigUint> = read(row, &coverage_path, "children")?;
        if indices.len() != successors.len() {
            return Err(syntax("$", "closure child coverage mismatch"));
        }
        for (index, (_, expected)) in indices.iter().zip(&successors) {
            let Some(supplied) = index.to_usize().and_then(|index| states.get(index)) else {
                return Err(syntax("$", "closure successor index"));
            };
            if supplied != expected {
                return Err(syntax("$", "closure successor state mismatch"));
            }
        }
        actions.push(action);
    }
    Ok(actions)
}

fn decode_closure(
    decoder: &PlanDecoder<'_, '_>,
    problem_json: &ExchangeJson,
    value: &ExchangeJson,
    path: &str,
) -> Decoded<CompositionClosureWitness> {
    let members = keys(value, path, &["input_snapshot", "root", "states"])?;
    if !necoherence::exact_json::same_json(member(members, path, "input_snapshot")?, problem_json) {
        return Err(syntax(
            &field_path(path, "input_snapshot"),
            "closure input snapshot mismatch",
        ));
    }
    let root: BigUint = read(members, path, "root")?;
    let states_path = field_path(path, "states");
    let rows = array(member(members, path, "states")?, &states_path)?;
    let row_keys: [&str; 5] = [
        "state",
        "terminals",
        "choices",
        "rejected_connections",
        "missing_supply",
    ];
    let mut states = Vec::with_capacity(rows.len());
    for (index, row) in rows.iter().enumerate() {
        let row_path = format!("{states_path}[{index}]");
        let row_members = keys(row, &row_path, &row_keys)?;
        states.push(read_with(
            row_members,
            &row_path,
            "state",
            |value, path| decode_search_state(decoder, value, path),
        )?);
    }
    let Some(root_state) = root.to_usize().and_then(|root| states.get(root)) else {
        return Err(syntax("$", "closure root index"));
    };
    if *root_state != initial_state(decoder.prepared) {
        return Err(syntax("$", "closure initial state mismatch"));
    }
    let mut nodes = Vec::with_capacity(rows.len());
    for (index, (row, state)) in rows.iter().zip(&states).enumerate() {
        let row_path = format!("{states_path}[{index}]");
        let row_members = keys(row, &row_path, &row_keys)?;
        for (name, kind) in [
            ("rejected_connections", "ConnectionFailure"),
            ("missing_supply", "MissingSupply"),
        ] {
            for element in array(
                member(row_members, &row_path, name)?,
                &field_path(&row_path, name),
            )? {
                check_diagnostic(decoder.library, decoder.problem, kind, element)?;
            }
        }
        let terminals = decode_closure_terminals(decoder, row_members, &row_path)?;
        let actions = decode_closure_choices(decoder, row_members, &row_path, &states, state)?;
        nodes.push(CompositionClosureNode {
            state: state.clone(),
            actions,
            terminals,
        });
    }
    let binding_candidates = nodes
        .iter()
        .map(|node| closure_binding_candidates(decoder.prepared, &node.state))
        .sum::<usize>();
    let mut branch_nodes = 0usize;
    for node in &nodes {
        branch_nodes += closure_branch_count(decoder.prepared, &node.state, &node.actions)
            .map_err(GenerationFailure::Composition)?;
    }
    Ok(CompositionClosureWitness {
        input_identity: decoder.problem.identity.clone(),
        input_revision: decoder.problem.revision.clone(),
        steps: BigUint::from(nodes.len().saturating_sub(1)),
        binding_candidates: BigUint::from(binding_candidates),
        branch_nodes: BigUint::from(branch_nodes),
        nodes,
        frontier: Vec::new(),
        obligations: Vec::new(),
    })
}

fn decode_selection(
    decoder: &PlanDecoder<'_, '_>,
    problem_json: &ExchangeJson,
    value: &ExchangeJson,
    path: &str,
    root: &PlanTree,
) -> Decoded<SelectionEvidence> {
    match tag_of(value, path)? {
        "AnyFeasible" => unit_variant(value, path, SelectionEvidence::AnyFeasible),
        "Unique" => {
            let row = tagged_fields(value, path, &["closure", "canonical_plan"])?;
            let _: String = read(row, path, "canonical_plan")?;
            let closure =
                decode_closure(decoder, problem_json, member(row, path, "closure")?, path)?;
            Ok(SelectionEvidence::Unique {
                closure: Box::new(closure),
                canonical_plan: canonical_plan_key(decoder.prepared, root),
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

pub(crate) fn encode_witness(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    causes: &[(FunctionRef, Vec<(OutcomeId, OutcomeCause)>)],
    value: &CompositionWitness,
) -> Decoded<Value> {
    Ok(object(vec![
        (
            "input_snapshot",
            encode_problem(library, &value.input_snapshot, causes)?,
        ),
        (
            "initial_membership",
            Value::Array(
                value
                    .initial_membership
                    .iter()
                    .map(|(input, slot)| {
                        Ok(Value::Array(vec![text(&input.0), encode_slot_value(slot)?]))
                    })
                    .collect::<Decoded<Vec<Value>>>()?,
            ),
        ),
        (
            "resource_traces",
            encode_resource_traces(library, graph, &value.resource_traces)?,
        ),
    ]))
}

pub(crate) fn decode_derivation(
    library: &TypeSignatureLibrary,
    graph: &SemanticGraph,
    prepared: &PreparedCompositionInput<'_>,
    problem: &CompositionInput,
    problem_json: &ExchangeJson,
    value: &ExchangeJson,
) -> Decoded<RawComposition> {
    let members = keys(value, "$", &["plan", "witness", "selection"])?;
    let plan = keys(
        member(members, "$", "plan")?,
        "$",
        &["input_identity", "input_revision", "root"],
    )?;
    let witness = keys(
        member(members, "$", "witness")?,
        "$",
        &["input_snapshot", "initial_membership", "resource_traces"],
    )?;
    if !necoherence::exact_json::same_json(member(witness, "$", "input_snapshot")?, problem_json) {
        return Err(syntax("$", "input snapshot mismatch"));
    }
    let library_basis = necoherence::signature_composition_codec::library_basis(library);
    let decoder = PlanDecoder {
        library,
        library_basis: &library_basis,
        graph,
        prepared,
        problem,
    };
    let root = decoder.decode_tree(member(plan, "$", "root")?, "$")?;
    let selection = decode_selection(
        &decoder,
        problem_json,
        member(members, "$", "selection")?,
        "$",
        &root,
    )?;
    let resource_traces = array(member(witness, "$", "resource_traces")?, "$")?
        .iter()
        .map(|trace| decode_resource_trace(&decoder, trace, "$"))
        .collect::<Decoded<Vec<_>>>()?;
    let input_identity = read(plan, "$", "input_identity")?;
    let input_revision = read(plan, "$", "input_revision")?;
    let initial_membership = read_with(witness, "$", "initial_membership", |value, path| {
        decode_all(value, path, |value, path| {
            decode_pair(
                value,
                path,
                |value, path| decode_identifier(value, path, InputId),
                decode_slot_value,
            )
        })
    })?;
    Ok(RawComposition {
        plan: CompositionPlan {
            input_identity,
            input_revision,
            root,
        },
        witness: CompositionWitness {
            input_snapshot: problem.clone(),
            initial_membership,
            resource_traces,
        },
        selection: Arc::new(selection),
    })
}

pub(crate) fn unit_tag(tag: &str) -> Value {
    json!({ "tag": tag })
}

pub(crate) fn tuple_tag(tag: &str, value: Value) -> Value {
    json!({ "tag": tag, "value": value })
}

pub(crate) fn record_tag(tag: &str, values: Vec<(&str, Value)>) -> Value {
    json!({ "tag": tag, "fields": object(values) })
}

pub(crate) fn optional<T>(value: &Option<T>, encode: impl Fn(&T) -> Value) -> Value {
    value.as_ref().map_or(Value::Null, encode)
}

pub(crate) fn encode_function_ref(value: &FunctionRef) -> Value {
    object(vec![
        ("identity", text(&value.identity)),
        ("revision", text(&value.revision)),
        ("content_digest", text(&value.content_digest)),
    ])
}

pub(crate) fn encode_slot_value(value: &SlotValue) -> Decoded<Value> {
    match value {
        SlotValue::Absent => Ok(unit_tag("Absent")),
        SlotValue::Null => Ok(unit_tag("Null")),
        SlotValue::Present(value) => Ok(tuple_tag("Present", native(value)?)),
    }
}

fn encode_path_step(value: &PathStep) -> Value {
    match value {
        PathStep::Field(value) => tuple_tag("Field", text(value)),
        PathStep::Index(value) => tuple_tag("Index", decimal(value)),
        PathStep::Variant(value) => tuple_tag("Variant", text(value)),
    }
}

pub(crate) fn encode_value_path(value: &ValuePath) -> Value {
    all(value, encode_path_step)
}

pub(crate) fn encode_resource_lot_ref(value: &ResourceLotRef) -> Value {
    match value {
        ResourceLotRef::Initial(lot) => tuple_tag("Initial", text(&lot.0)),
        ResourceLotRef::Produced {
            site,
            outcome,
            production,
        } => record_tag(
            "Produced",
            vec![
                ("site", text(&site.0)),
                ("outcome", text(&outcome.0)),
                ("production", text(&production.0)),
            ],
        ),
    }
}

pub(crate) fn encode_guard_arm(value: &GuardArm) -> Value {
    match value {
        GuardArm::Present => unit_tag("Present"),
        GuardArm::Absent => unit_tag("Absent"),
        GuardArm::Null => unit_tag("Null"),
        GuardArm::UnknownVariant => unit_tag("UnknownVariant"),
        GuardArm::Accepted => unit_tag("Accepted"),
        GuardArm::Rejected => unit_tag("Rejected"),
        GuardArm::Variant(value) => tuple_tag("Variant", text(value)),
    }
}

pub(crate) fn native<T: WireEncode + ?Sized>(value: &T) -> Decoded<Value> {
    serde_json::to_value(Wire(value))
        .map_err(|failure| GenerationFailure::Encoding(failure.to_string()))
}

pub(crate) fn text(value: &str) -> Value {
    Value::String(value.to_owned())
}

pub(crate) fn decimal(value: impl std::fmt::Display) -> Value {
    Value::String(value.to_string())
}

pub(crate) fn object(values: Vec<(&str, Value)>) -> Value {
    Value::Object(
        values
            .into_iter()
            .map(|(key, value)| (key.to_owned(), value))
            .collect(),
    )
}

pub(crate) fn all<T>(values: &[T], encode: impl Fn(&T) -> Value) -> Value {
    Value::Array(values.iter().map(encode).collect())
}

pub(crate) fn encode_type_ref(value: &TypeRef) -> Value {
    text(&value.definition_name)
}

pub(crate) fn encode_slot_contract(value: &SlotContract) -> Value {
    object(vec![
        ("type_id", encode_type_ref(&value.type_ref)),
        ("required", Value::Bool(value.required)),
        ("nullable", Value::Bool(value.nullable)),
    ])
}

pub(crate) fn resource_type_id(graph: &SemanticGraph, reverse: bool, value: &str) -> String {
    graph
        .nodes
        .iter()
        .find_map(|node| {
            let internal = type_identity(&node.reference);
            let id = node.reference.definition_name.as_ref();
            let (from, to) = if reverse {
                (id, internal.as_str())
            } else {
                (internal.as_str(), id)
            };
            (value == from).then(|| to.to_owned())
        })
        .unwrap_or_else(|| value.to_owned())
}

pub(crate) fn decode_failure_origin(value: &ExchangeJson, path: &str) -> Decoded<FailureOrigin> {
    match tag_of(value, path)? {
        "Function" => {
            let row = tagged_fields(value, path, &["function", "outcome"])?;
            Ok(FailureOrigin::Function {
                function: read_with(row, path, "function", decode_function_ref)?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
            })
        }
        "Guard" => {
            let row = tagged_fields(value, path, &["guard", "arm"])?;
            Ok(FailureOrigin::Guard {
                guard: read_with(row, path, "guard", |value, path| {
                    decode_identifier(value, path, GuardId)
                })?,
                arm: read_with(row, path, "arm", decode_guard_arm)?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}
