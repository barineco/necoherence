// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

#![allow(clippy::panic)]
#![allow(clippy::indexing_slicing)]
#![allow(clippy::unwrap_used)]
use necoherence::{
    coherent, reconcile, sorted_divergences, Basis, Divergence, Nat, ResourceId, Revision,
};
use proptest::prelude::*;

fn rid(name: u32) -> ResourceId {
    ResourceId {
        kind: "test".to_string(),
        name: name.to_string(),
    }
}

fn nat(n: u64) -> Nat {
    Nat::from(n)
}

fn basis(name: u32, rev: u64) -> Option<Basis> {
    Some(Basis {
        resource: rid(name),
        revision: Revision { value: nat(rev) },
    })
}

proptest! {
    #[test]
    fn coherent_result_has_no_divergence_unbased_or_dropped(r in 0u64..10) {
        let bases = vec![basis(0, r)];
        let world = necoherence::world_of([(rid(0), Revision { value: nat(r) })]);
        let result = reconcile(&bases, &world, nat(0));
        prop_assert!(coherent(&result));
    }

    #[test]
    fn unknown_to_world_is_a_divergence(r in 0u64..10) {
        let bases = vec![basis(0, r)];
        let world = necoherence::world_of([]);
        let result = reconcile(&bases, &world, nat(0));
        prop_assert!(!coherent(&result));
        prop_assert_eq!(result.divergences.len(), 1);
        let is_unknown = matches!(result.divergences[0], Divergence::UnknownToWorld { .. });
        prop_assert!(is_unknown);
    }

    #[test]
    fn unbased_entries_are_counted(count in 0usize..5) {
        let bases: Vec<Option<Basis>> = (0..count).map(|_| None).collect();
        let world = necoherence::world_of([]);
        let result = reconcile(&bases, &world, nat(0));
        prop_assert_eq!(result.unbased, nat(count as u64));
    }

    #[test]
    fn divergences_sorted_by_kind_and_name(r0 in 0u64..5, r1 in 0u64..5) {
        let bases = vec![basis(1, r0), basis(0, r1)];
        let world = necoherence::world_of([]);
        let result = reconcile(&bases, &world, nat(0));
        let sorted = sorted_divergences(&result);
        if sorted.len() == 2 {
            let names: Vec<&str> = sorted
                .iter()
                .map(|d| match d {
                    Divergence::UnknownToWorld { resource, .. } => resource.name.as_str(),
                    Divergence::WorldAhead { resource, .. } => resource.name.as_str(),
                    Divergence::WorldBehind { resource, .. } => resource.name.as_str(),
                })
                .collect();
            prop_assert!(names[0] <= names[1]);
        }
    }
}
