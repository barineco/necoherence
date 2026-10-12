// SPDX-FileCopyrightText: 2026 barineco
// SPDX-License-Identifier: MIT

use necoherence::{
    lookup, observe, store::apply, store_of, world_of_store, Basis, Command, Nat, Observed,
    ResourceId, Revision,
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

proptest! {
    #[test]
    fn observe_returns_stored_payload(r in 0u64..10, payload in 0i64..100) {
        let s = store_of([(rid(0), Revision { value: nat(r) }, payload)]);
        match observe(&s, &rid(0)) {
            Observed::Found(rev, p) => {
                prop_assert_eq!(rev, Revision { value: nat(r) });
                prop_assert_eq!(p, payload);
            }
            Observed::Unknown(_) => prop_assert!(false, "expected found"),
        }
    }

    #[test]
    fn world_of_store_projects_revisions(r0 in 0u64..10, r1 in 0u64..10) {
        let s = store_of([
            (rid(0), Revision { value: nat(r0) }, "a".to_string()),
            (rid(1), Revision { value: nat(r1) }, "b".to_string()),
        ]);
        let w = world_of_store(&s);
        prop_assert_eq!(lookup(&w, &rid(0)), necoherence::Lookup::Found(Revision { value: nat(r0) }));
        prop_assert_eq!(lookup(&w, &rid(1)), necoherence::Lookup::Found(Revision { value: nat(r1) }));
    }

    #[test]
    fn apply_bumps_revision_and_replaces_payload(r in 0u64..10) {
        let s = store_of([(rid(0), Revision { value: nat(r) }, "old".to_string())]);
        let command = Command { intent: "new".to_string(), basis: Basis { resource: rid(0), revision: Revision { value: nat(r) } } };
        match apply(&s, command) {
            necoherence::Outcome::Applied((intent, s2)) => {
                prop_assert_eq!(intent, "new".to_string());
                match observe(&s2, &rid(0)) {
                    Observed::Found(rev, p) => {
                        prop_assert_eq!(rev, Revision { value: nat(r + 1) });
                        prop_assert_eq!(p, "new".to_string());
                    }
                    Observed::Unknown(_) => prop_assert!(false),
                }
            }
            _ => prop_assert!(false, "expected applied"),
        }
    }
}
