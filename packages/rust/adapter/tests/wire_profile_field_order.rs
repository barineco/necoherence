// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::indexing_slicing,
    clippy::result_large_err
)]

use necoherence::semantic_exchange::{GenerationFailure, WireDecode};
use necoherence::semantic_types::GraphemeRules;
use necoherence::type_signatures::ValueSemanticProfile;
use serde_json::{json, Value};

const FIXTURE: &str = include_str!("fixtures/composition-budget-default.json");

fn profile() -> Value {
    let exchange: Value = serde_json::from_str(FIXTURE).expect("fixture JSON");
    exchange["signatures"]["profile"].clone()
}

fn decode(mutate: impl FnOnce(&mut Value)) -> Result<ValueSemanticProfile, GenerationFailure> {
    let mut value = profile();
    mutate(&mut value);
    let text = value.to_string();
    let exchange = necoherence::exact_json::bounded_json_parse(&text).expect("exchange value");
    ValueSemanticProfile::decode_wire(&exchange, "$")
}

#[test]
fn invalid_profile_fields_produce_typed_wire_failures() {
    for edit in [
        (|p: &mut Value| p["bytes_policy"] = json!({ "tag": "Bogus" })) as fn(&mut Value),
        |p| p["wrappers"] = json!(5),
        |p| p["tag"] = json!(5),
        |p| p["tag"] = json!({ "extra": 1 }),
    ] {
        assert!(matches!(
            decode(edit),
            Err(GenerationFailure::UnknownField { .. }
                | GenerationFailure::UnknownTag { .. }
                | GenerationFailure::Syntax { .. })
        ));
    }
}

#[test]
fn invalid_grapheme_rule_fields_produce_typed_wire_failures() {
    for (field, value) in [
        ("component", json!({ "extra": 1 })),
        ("properties", json!(5)),
    ] {
        let mut rules = json!({
            "reference": { "identity": "p", "revision": "1", "content_digest": "d" },
            "component": { "unicode_version": "16.0.0", "uax29_revision": "45", "cluster_profile": "extended" },
            "table_sha256": "t",
            "sources": [],
            "properties": [],
            "extended_pictographic": [],
            "indic_conjunct": []
        });
        rules[field] = value;
        let exchange = necoherence::exact_json::bounded_json_parse(&rules.to_string())
            .expect("exchange value");
        assert!(matches!(
            GraphemeRules::decode_wire(&exchange, "$"),
            Err(GenerationFailure::UnknownField { .. } | GenerationFailure::Syntax { .. })
        ));
    }
}
