// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::semantic_exchange::{GenerationFailure, Wire};
use necoherence::semantic_types::{
    IntegerDomain, IntegerDomainBinding, IntegerForm, NumberModel, ProfileRef, TypeShape,
    VersionedSemanticProfile,
};
use necoherence_verification::semantic_graph_codec::decode_public_validation_graph;
use num_bigint::BigInt;
use serde_json::{json, Value};

fn profile() -> VersionedSemanticProfile {
    let reference = ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    };
    VersionedSemanticProfile {
        reference: reference.clone(),
        source_refs: vec![],
        integer_domains: vec![IntegerDomainBinding {
            name: "integer".into(),
            reference,
            range: IntegerDomain::Inclusive {
                minimum: BigInt::from(-10),
                maximum: BigInt::from(10),
            },
            forms: vec![IntegerForm::Number],
        }],
        default_integer_domain: "integer".into(),
        numbers: NumberModel { decimals: true },
        grapheme_rules: None,
        format_bindings: vec![],
        wrappers: vec![],
        bytes_policy: None,
        tag: None,
    }
}

fn reference(name: &str) -> Value {
    json!({
        "source": {
            "repository": "public",
            "revision": "1",
            "path": "types.json",
            "content_digest": "b".repeat(64),
            "document_id": "types",
            "declared_revision": null
        },
        "definition_name": name,
        "pointer": ["definitions", name]
    })
}

fn string_shape() -> Value {
    json!({
        "tag": "String",
        "value": {
            "format": null,
            "lengths": [],
            "wrapper": null,
            "const_value": null,
            "enum_values": null,
            "examples": [],
            "default_value": null
        }
    })
}

fn decimal_shape() -> Value {
    json!({"tag": "Decimal", "value": {"minimum": null, "maximum": null}})
}

fn node(name: &str, shape: Value) -> Value {
    json!({
        "reference": reference(name),
        "shape": shape,
        "description": null,
        "attributes": [],
        "extensions": []
    })
}

fn graph(nodes: Vec<Value>) -> Value {
    json!({
        "profile": serde_json::to_value(Wire(&profile())).unwrap(),
        "nodes": nodes,
        "source_refs": []
    })
}

fn with_member(mut value: Value, key: &str, member: Value) -> Value {
    value.as_object_mut().unwrap().insert(key.into(), member);
    value
}

fn without_member(mut value: Value, key: &str) -> Value {
    value.as_object_mut().unwrap().remove(key);
    value
}

#[test]
fn accepts_string_nodes_and_drops_the_source_refs() {
    let value = graph(vec![node("text", string_shape())]);
    let decoded = decode_public_validation_graph(&value.to_string(), "$.graph").unwrap();
    assert_eq!(decoded.nodes.len(), 1);
    assert!(matches!(
        decoded.nodes.first().map(|node| &node.shape),
        Some(TypeShape::String(_))
    ));
    assert!(decoded.source_refs.is_empty());
}

#[test]
fn rejects_a_decimal_node_at_its_shape_tag() {
    let value = graph(vec![node("decimal", decimal_shape())]);
    assert_eq!(
        decode_public_validation_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownTag {
            path: "$.graph.nodes[0].shape.tag".into(),
            tag: "Decimal".into(),
        })
    );
}

#[test]
fn reports_the_first_node_whose_shape_is_not_a_string() {
    let value = graph(vec![
        node("text", string_shape()),
        node("integer", json!({"tag": "Integer", "value": {}})),
    ]);
    assert_eq!(
        decode_public_validation_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownTag {
            path: "$.graph.nodes[1].shape.tag".into(),
            tag: "Integer".into(),
        })
    );
}

#[test]
fn reads_the_shape_before_the_reference() {
    let broken = with_member(node("decimal", decimal_shape()), "reference", json!(5));
    let value = graph(vec![broken]);
    assert_eq!(
        decode_public_validation_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownTag {
            path: "$.graph.nodes[0].shape.tag".into(),
            tag: "Decimal".into(),
        })
    );
}

#[test]
fn rejects_an_unknown_member_of_a_node_at_its_path() {
    let extra = with_member(node("text", string_shape()), "zeta", json!(1));
    let value = graph(vec![extra]);
    assert_eq!(
        decode_public_validation_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownField {
            path: "$.graph.nodes[0].zeta".into(),
            field: "zeta".into(),
        })
    );
}

#[test]
fn rejects_an_unknown_member_of_the_graph_at_its_path() {
    let value = with_member(graph(vec![]), "zeta", json!(1));
    assert_eq!(
        decode_public_validation_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownField {
            path: "$.graph.zeta".into(),
            field: "zeta".into(),
        })
    );
}

#[test]
fn requires_the_source_refs_member_but_does_not_read_its_value() {
    let without = without_member(graph(vec![]), "source_refs");
    assert!(matches!(
        decode_public_validation_graph(&without.to_string(), "$.graph"),
        Err(GenerationFailure::Syntax { path, .. }) if path == "$.graph.source_refs"
    ));

    let any = with_member(
        graph(vec![node("text", string_shape())]),
        "source_refs",
        json!(5),
    );
    assert!(decode_public_validation_graph(&any.to_string(), "$.graph").is_ok());
}

#[test]
fn does_not_read_the_members_of_a_node_that_the_reader_does_not_use() {
    let loose = with_member(node("text", string_shape()), "description", json!(5));
    let loose = with_member(loose, "attributes", json!("unused"));
    let loose = with_member(loose, "extensions", json!({}));
    let value = graph(vec![loose]);
    assert!(decode_public_validation_graph(&value.to_string(), "$.graph").is_ok());
}

#[test]
fn a_non_object_graph_is_a_syntax_failure_at_the_graph_path() {
    assert!(matches!(
        decode_public_validation_graph("[]", "$.graph"),
        Err(GenerationFailure::Syntax { path, .. }) if path == "$.graph"
    ));
}
