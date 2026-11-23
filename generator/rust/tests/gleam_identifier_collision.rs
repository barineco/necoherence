// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: AGPL-3.0-only

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::panic)]

use necoherence::semantic_exchange::decode_signature_generation;
use necoherence_generator::renderer::{render_signature_exchange_for, RenderFailure, Target};

#[test]
fn gleam_target_reports_identifier_collision() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/gleam-identifier-collision.exchange.json"
    ))
    .unwrap();
    let input = decode_signature_generation(&text).unwrap();
    let expected = necoherence::type_signatures::ExpectedSignatureBasis::of_input(&input);
    let failure = render_signature_exchange_for(&Target::Gleam, &expected, &text).unwrap_err();
    assert!(matches!(
        failure,
        RenderFailure::IdentifierCollision { ref namespace, ref name, .. }
            if namespace == "value" && name == "example_identity"
    ));
}
