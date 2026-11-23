// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT
#![allow(clippy::expect_used, clippy::unwrap_used)]

use necoherence::semantic_types::{
    FormatRule, GraphemeComponent, GraphemeProperty, GraphemeRange, GraphemeRules, ProfileRef,
    StringLengthUnit,
};
use necoherence::semantic_validation::recognize_format;
use num_bigint::BigUint;

fn one_grapheme_at_most() -> FormatRule {
    FormatRule::Bounded {
        unit: StringLengthUnit::Graphemes,
        maximum: 1u8.into(),
        rule: Box::new(FormatRule::Text),
    }
}

fn combining_mark_rules() -> GraphemeRules {
    GraphemeRules {
        reference: ProfileRef {
            identity: "graphemes".into(),
            revision: "1".into(),
            content_digest: "c".repeat(64),
        },
        properties: vec![GraphemeRange {
            first: BigUint::from(0x0301u32),
            last: BigUint::from(0x0301u32),
            property: GraphemeProperty::Extend,
        }],
        extended_pictographic: vec![],
        indic_conjunct: vec![],
        component: GraphemeComponent {
            unicode_version: "16.0.0".into(),
            uax29_revision: "45".into(),
            cluster_profile: "extended".into(),
        },
        table_sha256: String::new(),
        sources: vec![],
    }
}

#[test]
fn grapheme_bound_without_profile_rules_is_not_satisfied() {
    assert!(!recognize_format(&one_grapheme_at_most(), None, "a"));
}

#[test]
fn grapheme_bound_counts_a_base_with_its_combining_mark_as_one() {
    let rules = combining_mark_rules();
    assert!(recognize_format(
        &one_grapheme_at_most(),
        Some(&rules),
        "e\u{0301}"
    ));
    assert!(!recognize_format(
        &one_grapheme_at_most(),
        Some(&rules),
        "ea"
    ));
}
