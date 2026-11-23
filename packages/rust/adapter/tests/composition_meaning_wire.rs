// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::semantic_exchange::decode_unresolved_obligations;

#[test]
fn meaning_tag_decodes_as_unresolved_meaning_obligations() {
    let decoded = decode_unresolved_obligations(r#"[{"tag":"Meaning","value":[]}]"#);
    assert!(
        decoded.is_ok(),
        "the Meaning tag is the single wire tag of unresolved meaning obligations"
    );
}

#[test]
fn semantic_meaning_tag_is_rejected_on_the_composition_wire() {
    let decoded = decode_unresolved_obligations(r#"[{"tag":"SemanticMeaning","value":[]}]"#);
    assert!(
        decoded.is_err(),
        "the legacy SemanticMeaning tag must not decode on the composition wire"
    );
}
