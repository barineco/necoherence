// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(
    clippy::expect_used,
    clippy::panic,
    clippy::unwrap_used,
    clippy::indexing_slicing
)]

use necoherence::semantic_composition as composition;
use necoherence::semantic_types::SourceIdentity;
use necoherence::signature_admission::check_type_signatures;
use necoherence::type_signatures::*;

#[allow(dead_code, unused_imports)]
#[path = "fixtures/semantic_execution_samples.rs"]
mod samples;
#[allow(unused_imports)]
use samples::*;

fn library_with_source() -> TypeSignatureLibrary {
    let mut library = library();
    library.sources = vec![SourceIdentity {
        repository: "example".into(),
        revision: "1".into(),
        path: "types.json".into(),
        content_digest: "c".repeat(64),
    }];
    library
}

#[test]
fn checked_type_signature_graph_carries_no_source_refs_like_lean() {
    let library = library_with_source();
    let graph = check_type_signatures(&library).unwrap();
    assert!(
        graph.source_refs.is_empty(),
        "the exchange graph keeps no source refs: {:?}",
        graph.source_refs
    );
}

#[test]
fn semantic_basis_sources_are_the_graph_source_refs() {
    let library = library_with_source();
    let graph = check_type_signatures(&library).unwrap();
    let basis = composition::SemanticBasis::of(&graph);
    assert_eq!(basis.sources, graph.source_refs);
}
