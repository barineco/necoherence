// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use crate::exact_json::JsonValue as ExchangeJson;
use crate::semantic_composition::*;
use crate::semantic_exchange::{keys, syntax, WireDecode};
use crate::semantic_types::{ProfileRef, SemanticGraph, SourceRef};
use crate::signature_composition_codec::{
    decode_all, decode_function_ref, decode_guard_arm, decode_identifier, decode_optional,
    decode_pair, decode_resource_lot_ref, decode_slot_contract, decode_slot_value, decode_type_ref,
    decode_value_path, field_path, member, payload_with, read, read_with, tag_of, tagged_fields,
    unit_variant, unknown_tag, Decoded,
};
use crate::type_signatures::{Shape, SignatureGenerationBasis, TypeSignatureLibrary};
use num_bigint::BigUint;
use std::sync::Arc;

pub fn declared_type_shape<'a>(library: &'a TypeSignatureLibrary, id: &str) -> Decoded<&'a Shape> {
    library
        .nodes
        .iter()
        .find(|node| node.id == id)
        .map(|node| &node.shape)
        .ok_or_else(|| syntax("$.composition.inclusion.pair", "declared type"))
}

fn decode_inclusion_rule(value: &ExchangeJson, path: &str) -> Decoded<InclusionRule> {
    let tag = tag_of(value, path)?;
    let rule = match tag {
        "SameDefinedType" => InclusionRule::SameDefinedType,
        "EmptySource" => InclusionRule::EmptySource,
        "Boolean" => InclusionRule::Boolean,
        "IntegerIntersection" => InclusionRule::IntegerIntersection,
        "FiniteStrings" => InclusionRule::FiniteStrings,
        "StringConditions" => InclusionRule::StringConditions,
        "BytesLength" => InclusionRule::BytesLength,
        "Unit" => InclusionRule::Unit,
        "UnfoldSource" => InclusionRule::UnfoldSource,
        "UnfoldDestination" => InclusionRule::UnfoldDestination,
        "Array" => InclusionRule::Array,
        "Product" => InclusionRule::Product,
        "SourceUnion" => InclusionRule::SourceUnion,
        "DestinationUnion" => InclusionRule::DestinationUnion,
        other => return Err(unknown_tag(path, other)),
    };
    unit_variant(value, path, rule)
}

pub struct PlanDecoder<'a, 'g> {
    pub library: &'a TypeSignatureLibrary,
    pub library_basis: &'a Decoded<SignatureGenerationBasis>,
    pub graph: &'a SemanticGraph,
    pub prepared: &'a PreparedCompositionInput<'g>,
    pub problem: &'a CompositionInput,
}

impl PlanDecoder<'_, '_> {
    pub fn decode_value_ref(&self, value: &ExchangeJson, path: &str) -> Decoded<ValueRef> {
        let members = keys(value, path, &["producer", "path"])?;
        Ok(ValueRef {
            producer: read_with(members, path, "producer", decode_producer_ref)?,
            path: read_with(members, path, "path", decode_value_path)?,
        })
    }

    fn decode_projection(
        &self,
        value: &ExchangeJson,
        path: &str,
    ) -> Decoded<ProjectionCertificate> {
        let members = keys(
            value,
            path,
            &[
                "profile",
                "source_refs",
                "source",
                "path",
                "assumptions",
                "destination",
            ],
        )?;
        Ok(ProjectionCertificate {
            profile: read_with(members, path, "profile", |value, path| {
                ProfileRef::decode_wire(value, path)
            })?,
            source_refs: read_with(members, path, "source_refs", |value, path| {
                decode_all(value, path, |value, path| {
                    SourceRef::decode_wire(value, path)
                })
            })?,
            source: read_with(members, path, "source", decode_slot_contract)?,
            path: read_with(members, path, "path", decode_value_path)?,
            assumptions: read_with(members, path, "assumptions", |value, path| {
                decode_all(value, path, decode_projection_assumption)
            })?,
            destination: read_with(members, path, "destination", decode_slot_contract)?,
        })
    }

    fn decode_pair_entry(&self, value: &ExchangeJson, path: &str) -> Decoded<PairEntry> {
        let members = keys(
            value,
            path,
            &[
                "pair",
                "source_shape",
                "destination_shape",
                "rule",
                "children",
            ],
        )?;
        let pair = read_with(members, path, "pair", decode_type_pair)?;
        let source_declared =
            declared_type_shape(self.library, &pair.source.type_ref.definition_name)?;
        let destination_declared =
            declared_type_shape(self.library, &pair.destination.type_ref.definition_name)?;
        let source_supplied: Shape = read(members, path, "source_shape")?;
        let destination_supplied: Shape = read(members, path, "destination_shape")?;
        if &source_supplied != source_declared || &destination_supplied != destination_declared {
            return Err(syntax(
                "$.composition.inclusion",
                "inclusion shape mismatch",
            ));
        }
        let source_shape = self.semantic_shape(&pair.source.type_ref.definition_name)?;
        let destination_shape = self.semantic_shape(&pair.destination.type_ref.definition_name)?;
        Ok(PairEntry {
            pair,
            source_shape,
            destination_shape,
            rule: read_with(members, path, "rule", decode_inclusion_rule)?,
            children: read_with(members, path, "children", |value, path| {
                decode_all(value, path, BigUint::decode_wire)
            })?,
        })
    }

    fn semantic_shape(&self, id: &str) -> Decoded<crate::semantic_types::TypeShape> {
        self.graph
            .nodes
            .iter()
            .find(|node| node.reference.definition_name.as_ref() == id)
            .map(|node| node.shape.clone())
            .ok_or_else(|| syntax("$.composition.inclusion.pair", "declared type"))
    }

    fn decode_inclusion(&self, value: &ExchangeJson, path: &str) -> Decoded<InclusionCertificate> {
        let members = keys(
            value,
            path,
            &[
                "basis",
                "source",
                "destination",
                "empty_types",
                "pairs",
                "root",
            ],
        )?;
        let supplied: SignatureGenerationBasis = read(members, path, "basis")?;
        if &supplied != self.library_basis.as_ref().map_err(Clone::clone)? {
            return Err(syntax(
                &field_path(path, "basis"),
                "inclusion basis mismatch",
            ));
        }
        let pairs = read_with(members, path, "pairs", |value, path| {
            decode_all(value, path, |value, path| {
                self.decode_pair_entry(value, path)
            })
        })?;
        Ok(InclusionCertificate {
            basis: SemanticBasis::of(self.graph),
            source: read_with(members, path, "source", decode_slot_contract)?,
            destination: read_with(members, path, "destination", decode_slot_contract)?,
            empty_types: read_with(members, path, "empty_types", |value, path| {
                decode_all(value, path, decode_type_ref)
            })?,
            pairs,
            root: read(members, path, "root")?,
        })
    }

    fn decode_binding_compatibility(
        &self,
        value: &ExchangeJson,
        path: &str,
    ) -> Decoded<BindingCompatibility> {
        match tag_of(value, path)? {
            "Inclusion" => payload_with(value, path, |value, path| {
                self.decode_inclusion(value, path).map(Arc::new)
            })
            .map(BindingCompatibility::Inclusion),
            "SuppliedValue" => {
                let row = tagged_fields(value, path, &["value"])?;
                Ok(BindingCompatibility::SuppliedValue {
                    value: read_with(row, path, "value", decode_slot_value)?,
                })
            }
            tag => Err(unknown_tag(path, tag)),
        }
    }

    fn decode_binding(&self, value: &ExchangeJson, path: &str) -> Decoded<BindingExpr> {
        match tag_of(value, path)? {
            "Source" => {
                let row = tagged_fields(value, path, &["value", "projection", "compatibility"])?;
                let compatibility = read_with(row, path, "compatibility", |value, path| {
                    self.decode_binding_compatibility(value, path)
                })?;
                Ok(BindingExpr::Source {
                    value: read_with(row, path, "value", |value, path| {
                        self.decode_value_ref(value, path)
                    })?,
                    projection: read_with(row, path, "projection", |value, path| {
                        self.decode_projection(value, path)
                    })?,
                    compatibility,
                })
            }
            "Product" => {
                let row = tagged_fields(value, path, &["construction", "type_id", "fields"])?;
                let fields = read_with(row, path, "fields", |value, path| {
                    decode_all(value, path, |value, path| {
                        decode_pair(value, path, String::decode_wire, |value, path| {
                            self.decode_binding(value, path)
                        })
                    })
                })?;
                Ok(BindingExpr::Product {
                    construction: read(row, path, "construction")?,
                    type_ref: read_with(row, path, "type_id", decode_type_ref)?,
                    fields,
                })
            }
            tag => Err(unknown_tag(path, tag)),
        }
    }

    pub fn decode_invocation(&self, value: &ExchangeJson, path: &str) -> Decoded<InvocationPlan> {
        let members = keys(value, path, &["site", "function", "bindings", "resources"])?;
        let resources = read_with(members, path, "resources", |value, path| {
            decode_all(value, path, |value, path| {
                let members = keys(value, path, &["requirement", "lot", "inclusion"])?;
                Ok(ResourceBinding {
                    requirement: read_with(members, path, "requirement", |value, path| {
                        decode_identifier(value, path, RequirementId)
                    })?,
                    lot: read_with(members, path, "lot", decode_resource_lot_ref)?,
                    inclusion: read_with(members, path, "inclusion", |value, path| {
                        self.decode_inclusion(value, path).map(Arc::new)
                    })?,
                })
            })
        })?;
        let bindings = read_with(members, path, "bindings", |value, path| {
            decode_all(value, path, |value, path| {
                decode_pair(
                    value,
                    path,
                    |value, path| decode_identifier(value, path, PortId),
                    |value, path| self.decode_binding(value, path),
                )
            })
        })?;
        Ok(InvocationPlan {
            site: read_with(members, path, "site", |value, path| {
                decode_identifier(value, path, SiteId)
            })?,
            function: read_with(members, path, "function", decode_function_ref)?,
            bindings,
            resources,
        })
    }

    pub fn decode_return(&self, value: &ExchangeJson, path: &str) -> Decoded<ReturnPlan> {
        match tag_of(value, path)? {
            "Success" => payload_with(value, path, |value, path| {
                decode_all(value, path, |value, path| {
                    decode_pair(
                        value,
                        path,
                        |value, path| decode_identifier(value, path, GoalPortId),
                        |value, path| self.decode_binding(value, path),
                    )
                })
            })
            .map(ReturnPlan::Success),
            "Failure" => {
                let row = tagged_fields(value, path, &["embedding", "value"])?;
                Ok(ReturnPlan::Failure {
                    embedding: read_with(row, path, "embedding", |value, path| {
                        decode_identifier(value, path, FailureEmbeddingId)
                    })?,
                    value: read_with(row, path, "value", |value, path| {
                        self.decode_binding(value, path)
                    })?,
                })
            }
            tag => Err(unknown_tag(path, tag)),
        }
    }

    pub fn decode_tree(&self, value: &ExchangeJson, path: &str) -> Decoded<PlanTree> {
        let members = keys(value, path, &["rank", "node"])?;
        let rank = read(members, path, "rank")?;
        let node_value = member(members, path, "node")?;
        let node_path = field_path(path, "node");
        let node = match tag_of(node_value, &node_path)? {
            "Return" => PlanNode::Return(payload_with(node_value, &node_path, |value, path| {
                self.decode_return(value, path)
            })?),
            "Invoke" => {
                let row = tagged_fields(
                    node_value,
                    &node_path,
                    &["invocation", "arms", "empty_outcomes"],
                )?;
                PlanNode::Invoke {
                    arms: read_with(row, &node_path, "arms", |value, path| {
                        decode_all(value, path, |value, path| {
                            decode_pair(
                                value,
                                path,
                                |value, path| decode_identifier(value, path, OutcomeId),
                                |value, path| self.decode_tree(value, path),
                            )
                        })
                    })?,
                    invocation: read_with(row, &node_path, "invocation", |value, path| {
                        self.decode_invocation(value, path)
                    })?,
                    empty_outcomes: read_with(row, &node_path, "empty_outcomes", |value, path| {
                        decode_all(value, path, |value, path| {
                            decode_identifier(value, path, OutcomeId)
                        })
                    })?,
                }
            }
            "Guard" => {
                let row = tagged_fields(node_value, &node_path, &["guard", "inspected", "arms"])?;
                PlanNode::Guard {
                    arms: read_with(row, &node_path, "arms", |value, path| {
                        decode_all(value, path, |value, path| {
                            decode_pair(value, path, decode_guard_arm, |value, path| {
                                self.decode_tree(value, path)
                            })
                        })
                    })?,
                    guard: read_with(row, &node_path, "guard", |value, path| {
                        decode_identifier(value, path, GuardId)
                    })?,
                    inspected: read_with(row, &node_path, "inspected", |value, path| {
                        self.decode_value_ref(value, path)
                    })?,
                }
            }
            tag => return Err(unknown_tag(&node_path, tag)),
        };
        Ok(PlanTree { rank, node })
    }
}

pub fn decode_producer_ref(value: &ExchangeJson, path: &str) -> Decoded<ProducerRef> {
    match tag_of(value, path)? {
        "Initial" => payload_with(value, path, |value, path| {
            decode_identifier(value, path, InputId)
        })
        .map(ProducerRef::Initial),
        "InvocationOutcome" => {
            let row = tagged_fields(value, path, &["site", "outcome", "port"])?;
            Ok(ProducerRef::InvocationOutcome {
                site: read_with(row, path, "site", |value, path| {
                    decode_identifier(value, path, SiteId)
                })?,
                outcome: read_with(row, path, "outcome", |value, path| {
                    decode_identifier(value, path, OutcomeId)
                })?,
                port: read_with(row, path, "port", |value, path| {
                    decode_identifier(value, path, PortId)
                })?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

pub fn decode_projection_assumption(
    value: &ExchangeJson,
    path: &str,
) -> Decoded<ProjectionAssumption> {
    match tag_of(value, path)? {
        "Present" => {
            payload_with(value, path, decode_value_path).map(ProjectionAssumption::Present)
        }
        "NonNull" => {
            payload_with(value, path, decode_value_path).map(ProjectionAssumption::NonNull)
        }
        "Variant" => {
            let row = tagged_fields(value, path, &["path", "tag"])?;
            Ok(ProjectionAssumption::Variant {
                path: read_with(row, path, "path", decode_value_path)?,
                tag: read(row, path, "tag")?,
            })
        }
        "IndexPresent" => {
            let row = tagged_fields(value, path, &["path", "index"])?;
            Ok(ProjectionAssumption::IndexPresent {
                path: read_with(row, path, "path", decode_value_path)?,
                index: read(row, path, "index")?,
            })
        }
        tag => Err(unknown_tag(path, tag)),
    }
}

fn decode_type_pair(value: &ExchangeJson, path: &str) -> Decoded<TypePair> {
    let members = keys(value, path, &["source", "destination", "source_tag"])?;
    Ok(TypePair {
        source: read_with(members, path, "source", decode_slot_contract)?,
        destination: read_with(members, path, "destination", decode_slot_contract)?,
        source_tag: read_with(members, path, "source_tag", |value, path| {
            decode_optional(value, path, String::decode_wire)
        })?,
    })
}

pub(crate) fn decode_plan(
    library: &TypeSignatureLibrary,
    library_basis: &Decoded<SignatureGenerationBasis>,
    graph: &SemanticGraph,
    prepared: &PreparedCompositionInput<'_>,
    problem: &CompositionInput,
    problem_json: &ExchangeJson,
    value: &ExchangeJson,
) -> Decoded<CompositionPlan> {
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
    if !crate::exact_json::same_json(member(witness, "$", "input_snapshot")?, problem_json) {
        return Err(syntax("$", "input snapshot mismatch"));
    }
    let decoder = PlanDecoder {
        library,
        library_basis,
        graph,
        prepared,
        problem,
    };
    let root = decoder.decode_tree(member(plan, "$", "root")?, "$")?;
    let selection = member(members, "$", "selection")?;
    match tag_of(selection, "$")? {
        "AnyFeasible" => unit_variant(selection, "$", ())?,
        "Unique" => {}
        tag => return Err(unknown_tag("$", tag)),
    }
    Ok(CompositionPlan {
        input_identity: read(plan, "$", "input_identity")?,
        input_revision: read(plan, "$", "input_revision")?,
        root,
    })
}
