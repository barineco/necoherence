// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]
use necoherence::exact_json::{bounded_json_parse, json_size};
use necoherence::semantic_exchange::decode_exact_value;
use necoherence::semantic_types::*;
use necoherence::semantic_validation::*;
use std::sync::Arc;

const SHALLOW: usize = 1000;
const DEEP: usize = 10000;

fn nested_arrays(depth: usize) -> String {
    format!("{}{}", "[".repeat(depth), "]".repeat(depth))
}

fn nested_objects(depth: usize) -> String {
    format!(
        "{}{}{}",
        r#"{"child":"#.repeat(depth),
        "{}",
        "}".repeat(depth)
    )
}

fn nested_exchange_arrays(depth: usize) -> String {
    format!(
        "{}{}",
        r#"{"tag":"Array","items":["#.repeat(depth),
        "]}".repeat(depth)
    )
}

fn source() -> Arc<SourceRef> {
    Arc::new(SourceRef {
        repository: "repo".into(),
        revision: "rev".into(),
        path: "types.json".into(),
        content_digest: "b".repeat(64),
        document_id: "values".into(),
        declared_revision: None,
    })
}

fn named(name: &str) -> TypeRef {
    TypeRef::new(source(), name, vec![])
}

fn profile() -> VersionedSemanticProfile {
    VersionedSemanticProfile {
        reference: ProfileRef {
            identity: "profile".into(),
            revision: "1".into(),
            content_digest: "a".repeat(64),
        },
        source_refs: vec![],
        integer_domains: vec![],
        default_integer_domain: String::new(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        bytes_policy: None,
        wrappers: vec![],
        tag: None,
    }
}

fn graph_of(nodes: Vec<(&str, TypeShape)>) -> SemanticGraph {
    SemanticGraph {
        profile: profile(),
        nodes: nodes
            .into_iter()
            .map(|(name, shape)| TypeNode {
                reference: named(name),
                shape,
                description: None,
                attributes: vec![],
                extensions: vec![],
            })
            .collect(),
        source_refs: vec![],
    }
}

fn recursive_array() -> SemanticGraph {
    graph_of(vec![(
        "list",
        TypeShape::Array(ArraySpec {
            item: ElementContract {
                type_ref: named("list"),
                nullable: false,
            },
            min_length: None,
            max_length: None,
        }),
    )])
}

fn recursive_child_object() -> SemanticGraph {
    graph_of(vec![(
        "node",
        TypeShape::Product(ProductSpec {
            fields: vec![FieldSpec {
                wire_name: "child".into(),
                slot: SlotContract {
                    type_ref: named("node"),
                    required: false,
                    nullable: false,
                },
                origin: (&named("node")).into(),
            }],
            extras: ExtraMembers::Reject,
        }),
    )])
}

#[test]
fn nested_arrays_are_read_at_shallow_and_deep_depth() {
    for depth in [SHALLOW, DEEP] {
        let value = bounded_json_parse(&nested_arrays(depth)).unwrap();
        assert_eq!(json_size(&value), depth, "depth {depth}");
    }
}

#[test]
fn nested_objects_are_read_at_shallow_and_deep_depth() {
    for depth in [SHALLOW, DEEP] {
        let value = bounded_json_parse(&nested_objects(depth)).unwrap();
        assert_eq!(json_size(&value), depth + 1, "depth {depth}");
    }
}

#[test]
fn nested_arrays_round_trip_through_serialization_at_deep_depth() {
    let value = bounded_json_parse(&nested_arrays(DEEP)).unwrap();
    assert_eq!(serde_json::to_string(&value).unwrap(), nested_arrays(DEEP));
}

#[test]
fn nested_exchange_arrays_are_decoded_at_shallow_and_deep_depth() {
    for depth in [SHALLOW, DEEP] {
        let value = decode_exact_value(&nested_exchange_arrays(depth)).unwrap();
        assert_eq!(json_size(&value), depth, "depth {depth}");
    }
}

#[test]
fn nested_arrays_are_accepted_by_a_recursive_array_type_at_shallow_and_deep_depth() {
    let graph = recursive_array();
    for depth in [SHALLOW, DEEP] {
        let value = bounded_json_parse(&nested_arrays(depth)).unwrap();
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&named("list"), &value),
            ValueDecision::Accepted,
            "depth {depth}"
        );
    }
}

#[test]
fn nested_objects_are_accepted_by_a_recursive_product_type_at_shallow_and_deep_depth() {
    let graph = recursive_child_object();
    for depth in [SHALLOW, DEEP] {
        let value = bounded_json_parse(&nested_objects(depth)).unwrap();
        assert_eq!(
            PreparedValidator::new(&graph, FormatWorkspace::empty())
                .accepts_value(&named("node"), &value),
            ValueDecision::Accepted,
            "depth {depth}"
        );
    }
}

#[test]
fn nested_arrays_keep_their_shape_when_defaults_are_materialized_at_deep_depth() {
    let graph = recursive_array();
    let value = nested_arrays(DEEP);
    let defaulted = decode_with_defaults(
        &PreparedValidator::new(&graph, FormatWorkspace::empty()),
        &named("list"),
        &value,
    )
    .unwrap();
    assert_eq!(json_size(defaulted.value()), DEEP);
    assert!(defaulted.applications().is_empty());
}
