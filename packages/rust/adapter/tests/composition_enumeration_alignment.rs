// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::unwrap_used,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition as composition;
use necoherence::semantic_types::*;
use necoherence::signature_admission::{check_type_signatures, signature_type_ref};
use necoherence::type_signatures::*;

#[allow(dead_code, unused_imports)]
#[path = "fixtures/semantic_execution_samples.rs"]
mod samples;
#[allow(unused_imports)]
use samples::*;

fn slot(node: &str) -> SlotContract {
    SlotContract {
        type_ref: signature_type_ref(node),
        required: true,
        nullable: false,
    }
}

#[test]
fn composition_failure_payload_has_only_the_lean_failed_fields() {
    let provenance = composition::CompositionProvenance {
        operation: "classify".into(),
        input_identity: "input".into(),
        input_revision: "1".into(),
    };
    let failure =
        composition::classify_unresolved_obligations(provenance.clone(), Vec::new()).unwrap_err();
    let composition::CompositionReasonFailure {
        provenance: actual,
        obligations,
        residuals: _,
        classifications: _,
    } = failure;
    assert_eq!(actual, provenance);
    assert!(obligations.is_empty());
}

#[test]
fn nested_construction_gap_is_reported_at_the_nesting_rule_like_lean() {
    let mut library = library();
    let product = |id: &str, field: &str, type_id: &str| TypeNodeInput {
        id: id.into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![SignatureField {
                wire_name: field.into(),
                slot: SignatureSlot {
                    type_id: type_id.into(),
                    required: true,
                    nullable: false,
                },
            }],
            extras: SignatureExtraMembers::Reject,
        }),
    };
    library.nodes.push(product("leaf", "value", "boolean"));
    library.nodes.push(product("middle", "next", "leaf"));
    library.nodes.push(product("outer", "next", "middle"));
    let graph = check_type_signatures(&library).unwrap();
    let outer = slot("outer");
    let middle = slot("middle");
    let mut problem =
        invocation_problem(&graph, &outer, composition::CompositionEffect::PureFunction);
    let rule = |identity: &str, type_ref: &TypeRef, nested: &str| composition::ConstructionRule {
        identity: identity.into(),
        type_ref: type_ref.clone(),
        nested_fields: vec![("next".into(), nested.into())],
        field_constraints: Vec::new(),
    };
    problem.invocation_domain.permitted_constructions = vec![
        rule("outer-rule", &outer.type_ref, "middle-rule"),
        rule("middle-rule", &middle.type_ref, "leaf-rule"),
    ];
    let failure = composition::prepare_direct_composition(
        &graph,
        problem,
        composition::operation_checker_without_library(),
        composition::operation_meaning_of(&graph),
    )
    .err()
    .expect("the nested rule gap is rejected");
    let composition::CompositionInputFailure::NestedConstructionMismatch {
        identity,
        field,
        nested,
        type_ref,
    } = failure
    else {
        panic!("the nested rule gap is a nested construction mismatch: {failure:?}");
    };
    assert_eq!(identity, "middle-rule");
    assert_eq!(field, "next");
    assert_eq!(nested, "leaf-rule");
    assert_eq!(type_ref, slot("leaf").type_ref);
}

fn tagged_union_library(tag: Option<TagModel>, selector: BranchSelector) -> TypeSignatureLibrary {
    let mut library = library();
    library.profile.tag = tag;
    library.nodes.push(TypeNodeInput {
        id: "tag-a".into(),
        shape: Shape::String(StringSpec {
            format: None,
            lengths: vec![],
            wrapper: None,
            const_value: Some("a".into()),
            enum_values: None,
            examples: vec![],
            default_value: None,
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "pair".into(),
        shape: Shape::Product(SignatureProduct {
            fields: vec![
                SignatureField {
                    wire_name: "kind".into(),
                    slot: SignatureSlot {
                        type_id: "tag-a".into(),
                        required: true,
                        nullable: false,
                    },
                },
                SignatureField {
                    wire_name: "x".into(),
                    slot: SignatureSlot {
                        type_id: "boolean".into(),
                        required: true,
                        nullable: false,
                    },
                },
            ],
            extras: SignatureExtraMembers::Reject,
        }),
    });
    library.nodes.push(TypeNodeInput {
        id: "choice".into(),
        shape: Shape::TaggedUnion(SignatureUnion {
            branches: vec![SignatureUnionBranch {
                target: "pair".into(),
                wire_tag: "a".into(),
                selector,
            }],
        }),
    });
    library
}

fn union_projection_is_defined(library: &TypeSignatureLibrary) -> bool {
    let graph = check_type_signatures(library).unwrap();
    let source = slot("choice");
    let path = [PathStep::Variant("a".into()), PathStep::Field("x".into())];
    let assumptions = [composition::ProjectionAssumption::Variant {
        path: Vec::new(),
        tag: "a".into(),
    }];
    let validator = necoherence::semantic_validation::PreparedValidator::new(
        &graph,
        necoherence::semantic_validation::FormatWorkspace::empty(),
    );
    composition::project_slot(validator.metadata(), &source, &path, &assumptions).is_ok()
}

#[test]
fn union_projection_without_tag_model_is_undefined_like_lean() {
    let library = tagged_union_library(None, BranchSelector::Kind(ValueKind::Object));
    assert!(!union_projection_is_defined(&library));
}

#[test]
fn union_projection_needs_an_internal_tag_branch_like_lean() {
    let tag = TagModel {
        key: "kind".into(),
        format: None,
        sealed: Vec::new(),
    };
    assert!(union_projection_is_defined(&tagged_union_library(
        Some(tag.clone()),
        BranchSelector::InternalTag,
    )));
    assert!(!union_projection_is_defined(&tagged_union_library(
        Some(tag),
        BranchSelector::Kind(ValueKind::Object),
    )));
}
