// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only
#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::semantic_exchange::{GenerationFailure, Wire};
use necoherence::semantic_types::{
    IntegerDomain, IntegerDomainBinding, IntegerForm, NumberModel, ProfileRef, SemanticGraph,
    VersionedSemanticProfile,
};
use necoherence_verification::semantic_graph_codec::decode_semantic_graph;
use num_bigint::BigInt;

fn reference() -> ProfileRef {
    ProfileRef {
        identity: "p".into(),
        revision: "1".into(),
        content_digest: "a".repeat(64),
    }
}

fn graph() -> SemanticGraph {
    SemanticGraph {
        profile: VersionedSemanticProfile {
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
            bytes_policy: None,
            tag: None,
        },
        nodes: vec![],
        source_refs: vec![],
    }
}

#[test]
fn decodes_the_graph_written_by_the_wire() {
    let graph = graph();
    let text = serde_json::to_string(&Wire(&graph)).unwrap();
    assert_eq!(decode_semantic_graph(&text, "$"), Ok(graph));
}

#[test]
fn rejects_an_unknown_member_at_the_top_level() {
    let mut value = serde_json::to_value(Wire(&graph())).unwrap();
    value
        .as_object_mut()
        .unwrap()
        .insert("zeta".into(), serde_json::json!(1));
    assert_eq!(
        decode_semantic_graph(&value.to_string(), "$"),
        Err(GenerationFailure::UnknownField {
            path: "$.zeta".into(),
            field: "zeta".into(),
        })
    );
}

#[test]
fn rejects_an_unpaired_surrogate_as_a_typed_syntax_failure() {
    assert!(matches!(
        decode_semantic_graph(r#""\ud800""#, "$"),
        Err(GenerationFailure::Syntax { path, message })
            if path == "$" && message == "unpaired Unicode surrogate"
    ));
}

#[test]
fn reports_an_unknown_member_under_the_given_root_path() {
    let mut value = serde_json::to_value(Wire(&graph())).unwrap();
    value
        .as_object_mut()
        .unwrap()
        .insert("zeta".into(), serde_json::json!(1));
    assert_eq!(
        decode_semantic_graph(&value.to_string(), "$.graph"),
        Err(GenerationFailure::UnknownField {
            path: "$.graph.zeta".into(),
            field: "zeta".into(),
        })
    );
}
