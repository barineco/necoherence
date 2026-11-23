// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::{has_edge, record_of, record_on_basis, Basis, Nat, ResourceId, Revision};
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

proptest! {
    #[test]
    fn record_of_has_no_basis(input in 0i64..100, product in 0i64..100) {
        let r = record_of("decl", input, product);
        prop_assert_eq!(r.basis, None);
    }

    #[test]
    fn edge_holds_when_resources_match(r0 in 0u64..10, r1 in 0u64..10) {
        let earlier = record_on_basis("settle", (), 1i64, Basis { resource: rid(0), revision: Revision { value: nat(r0) } });
        let later = record_on_basis("read", (), 2i64, Basis { resource: rid(0), revision: Revision { value: nat(r1) } });
        prop_assert!(has_edge(&earlier, &later));
    }

    #[test]
    fn edge_absent_across_disjoint_resources(r0 in 0u64..10, r1 in 0u64..10) {
        let earlier = record_on_basis("settle", (), 1i64, Basis { resource: rid(0), revision: Revision { value: nat(r0) } });
        let later = record_on_basis("read", (), 2i64, Basis { resource: rid(1), revision: Revision { value: nat(r1) } });
        prop_assert!(!has_edge(&earlier, &later));
    }

    #[test]
    fn edge_absent_without_basis(product in 0i64..100) {
        let earlier = record_of("settle", (), product);
        let later = record_on_basis("read", (), 2i64, Basis { resource: rid(0), revision: Revision { value: nat(0) } });
        prop_assert!(!has_edge(&earlier, &later));
    }
}
